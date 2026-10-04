#!/bin/bash
set -eu
ROOT=$PWD
LAB="$ROOT/.test-validation/live"
EVIDENCE=/Users/kunchen/.no-mistakes/evidence/01M42J0Z1HCF8ARJVYD33JKGJD
mkdir -p "$LAB/account" "$LAB/bin"
export HOME="$LAB/account" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_STATE_ROOT="$LAB/state"
. "$ROOT/bin/fm-remote-job-lib.sh"
PID=
cleanup() {
  if [ -n "$PID" ]; then
    kill -CONT "$PID" 2>/dev/null || true
    fm_remote_job_stop_worker_tree "$PID" || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT
fm_remote_job_prepare_state "$HOME"
python3 - "$LAB/state/.seq-claims" <<'PY'
import os,sys
for n in range(1,17401):
    p=f'{sys.argv[1]}/{n}'
    os.mkdir(p)
    os.utime(p,(946684800,946684800))
PY
printf 'Launching real worker from %s; state=%s; 17400 expired sequence claims\n' "$ROOT" "$FM_REMOTE_JOB_STATE_ROOT"
"$ROOT/bin/fm-remote-job-worker.sh" > "$EVIDENCE/live-worker.stderr.log" 2>&1 &
PID=$!
for n in $(seq 1 200); do
  fm_remote_job_probe "$HOME" && break
  sleep .1
done
fm_remote_job_probe "$HOME"
[ "$(< "$LAB/state/worker.lock/pid")" = "$PID" ]
printf 'Serving PID=%s; start=%s\n' "$PID" "$(fm_remote_job_process_start "$PID")"
# Observe real sweep progress before stopping the serving loop; no filesystem
# commands or product processes are substituted by fixtures.
for n in $(seq 1 100); do
  [ ! -d "$LAB/state/.seq-claims/1" ] && break
  sleep .1
done
[ ! -d "$LAB/state/.seq-claims/1" ]
kill -STOP "$PID"
printf 'Paused serving PID=%s during actual claim removal; independent heartbeat must remain available\n' "$PID"
rm "$LAB/state/worker.ready"
for n in $(seq 1 100); do
  [ -f "$LAB/state/worker.ready" ] && break
  sleep .1
done
fm_remote_job_probe "$HOME"
[ "$(< "$LAB/state/worker.ready")" = "$PID" ]
[ "$(stat -f %Lp "$LAB/state/worker.ready")" = 600 ]
printf 'Missing worker.ready recreated: content=%s; mode=%s; public probe=available\n' "$(< "$LAB/state/worker.ready")" "$(stat -f %Lp "$LAB/state/worker.ready")"
for n in $(seq 1 13); do
  sleep 2
  fm_remote_job_probe "$HOME"
  printf 'Blocked-pass sample %s: serving=%s; ready=%s; age=%ss; probe=available\n' "$n" "$PID" "$(< "$LAB/state/worker.ready")" "$(( $(date +%s) - $(stat -f %m "$LAB/state/worker.ready") ))"
done
kill -CONT "$PID"
printf 'Resumed actual 17400-directory sweep\n'
START=$SECONDS
while [ -d "$LAB/state/.seq-claims/9999" ]; do
  [ $((SECONDS - START)) -lt 240 ]
  sleep 2
  fm_remote_job_probe "$HOME"
  [ "$(< "$LAB/state/worker.lock/pid")" = "$PID" ]
  remaining=$(python3 - "$LAB/state/.seq-claims" <<'PY'
import os,sys
print(len(os.listdir(sys.argv[1])))
PY
)
  printf 'Sweep sample: remaining=%s; owner=%s; ready=%s; age=%ss; probe=available\n' "$remaining" "$PID" "$(< "$LAB/state/worker.ready")" "$(( $(date +%s) - $(stat -f %m "$LAB/state/worker.ready") ))"
done
printf 'All expired claims removed; unchanged owner=%s; public probe=available\n' "$PID"
# Exercise ownership guard adversarially without replacing the running product.
rm "$LAB/state/worker.lock/pid"
sleep 12
for n in $(seq 1 80); do
  if ! fm_remote_job_probe "$HOME"; then break; fi
  sleep .25
done
if fm_remote_job_probe "$HOME"; then
  printf 'ERROR: removed ownership still kept readiness available\n'; exit 1
fi
printf 'Removed ownership record: serving PID still alive=%s; public probe=unavailable; readiness age=%ss\n' "$(kill -0 "$PID" && printf yes)" "$(( $(date +%s) - $(stat -f %m "$LAB/state/worker.ready") ))"
# Restore our recorded PID only for identity-safe worker shutdown.
printf '%s\n' "$PID" > "$LAB/state/worker.lock/pid"
