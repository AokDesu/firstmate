#!/bin/bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.test-tmp/live-worker.XXXXXX")
PID=
cleanup() {
  [ ! -f "$LAB/worker.log" ] || { printf 'Cleanup worker log:\n'; cat "$LAB/worker.log"; }
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    # Only our directly launched child; never any discovered/shared process.
    kill -CONT "$PID" 2>/dev/null || true
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/root/bin" "$LAB/account"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$LAB/root/bin/"
printf 'disposable worker fixture\n' > "$LAB/root/AGENTS.md"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
 git -C "$LAB/root" init -q -b main
 git -C "$LAB/root" -c user.name=Test -c user.email=test@example.com add .
 git -C "$LAB/root" -c user.name=Test -c user.email=test@example.com commit -qm fixture
export FM_ROOT_OVERRIDE="$LAB/root" FM_REMOTE_JOB_STATE_ROOT="$LAB/state"
unset FM_REMOTE_JOB_PLATFORM_OVERRIDE
. "$ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_prepare_state "$LAB/account"
python3 - "$LAB/state/.seq-claims" <<'PY'
import os,sys
for i in range(1,17401):
    path=os.path.join(sys.argv[1],str(i))
    os.mkdir(path,0o700)
    os.utime(path,(946684800,946684800))
PY
printf 'Starting real worker with 17400 expired claim directories; no launchctl or filesystem-command stubs.\n'
HOME="$LAB/account" "$LAB/root/bin/fm-remote-job-worker.sh" > "$LAB/worker.log" 2>&1 &
PID=$!
for i in $(seq 1 100); do
  [ -f "$LAB/state/.seq-claims-reaped" ] && [ -f "$LAB/state/worker.ready" ] && break
  sleep 0.1
done
fm_remote_job_lock_owner_matches_process "$LAB/account"
[ "$FM_REMOTE_JOB_OWNER_PID" = "$PID" ]
[ -d "$LAB/state/.seq-claims/9999" ]
printf 'Actual sweep underway: verified lock owner PID=%s ready-owner=%s\n' "$PID" "$(< "$LAB/state/worker.ready")"
rm "$LAB/state/worker.ready"
for i in $(seq 1 40); do
  [ -f "$LAB/state/worker.ready" ] && break
  sleep 0.1
done
[ "$(< "$LAB/state/worker.ready")" = "$PID" ]
[ "$(stat -f %Lp "$LAB/state/worker.ready")" = 600 ]
fm_remote_job_probe "$LAB/account"
printf 'Removed worker.ready during actual sweep: independent heartbeat recreated PID record, mode=600; public probe succeeds.\n'
START=$(date +%s)
MAXAGE=0
for i in $(seq 1 180); do
  sleep 2
  fm_remote_job_probe "$LAB/account" || { cat "$LAB/worker.log"; exit 1; }
  fm_remote_job_lock_owner_matches_process "$LAB/account"
  [ "$FM_REMOTE_JOB_OWNER_PID" = "$PID" ]
  AGE=$(($(date +%s) - $(stat -f %m "$LAB/state/worker.ready")))
  [ "$AGE" -le "$MAXAGE" ] || MAXAGE=$AGE
  NOW=$(date +%s)
  if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
    printf 'sweep elapsed=%ss same-owner=%s heartbeat-age=%ss public-probe=available\n' "$((NOW-START))" "$PID" "$AGE"
  fi
  if [ ! -d "$LAB/state/.seq-claims/9999" ]; then break; fi
done
ELAPSED=$(($(date +%s)-START))
[ ! -d "$LAB/state/.seq-claims/9999" ]
[ "$ELAPSED" -gt 20 ]
printf 'Full 17400-claim sweep completed in %ss; unchanged PID=%s; maximum sampled heartbeat age=%ss.\n' "$ELAPSED" "$PID" "$MAXAGE"
# Simulate lost recorded ownership without replacing or signalling another PID.
printf '1\n' > "$LAB/state/worker.lock/pid"
sleep 3
BEFORE=$(stat -f %m "$LAB/state/worker.ready")
sleep 12
AFTER=$(stat -f %m "$LAB/state/worker.ready")
[ "$BEFORE" = "$AFTER" ]
if fm_remote_job_probe "$LAB/account"; then
  printf 'ERROR probe accepted lost ownership\n'; exit 1
fi
printf 'Adversarial lost lock ownership: heartbeat timestamp stopped advancing; public probe refuses readiness.\n'
printf 'Worker output:\n'
cat "$LAB/worker.log"
