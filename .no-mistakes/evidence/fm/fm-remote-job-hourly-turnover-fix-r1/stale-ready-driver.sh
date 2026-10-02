#!/bin/bash
set -eu
ROOT=$PWD
LAB="$ROOT/.test-tmp/stale-ready"
EVIDENCE=/Users/kunchen/.no-mistakes/evidence/01M3YTSQWRN3AMJ7ZG7ERG1T76
mkdir -p "$LAB/home" "$LAB/bin"
export HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_STATE_ROOT="$LAB/state"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Darwin
. "$ROOT/bin/fm-remote-job-lib.sh"
PID= HEARTBEAT=
cleanup() {
  [ -z "$HEARTBEAT" ] || kill -CONT "$HEARTBEAT" 2>/dev/null || true
  [ -z "$PID" ] || { kill -CONT "$PID" 2>/dev/null || true; fm_remote_job_stop_worker_tree "$PID" || true; }
  rm -rf "$LAB"
}
trap cleanup EXIT
fm_remote_job_prepare_state "$HOME"
fm_remote_job_write_launchagent "$ROOT" "$HOME"
"$ROOT/bin/fm-remote-job-worker.sh" > "$EVIDENCE/stale-ready-worker.log" 2>&1 & PID=$!
for _ in $(seq 1 100); do [ ! -f "$LAB/state/worker.ready" ] || break; sleep .1; done
export TEST_PID="$PID" TEST_PLIST="$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST" TEST_WORKER="$ROOT/bin/fm-remote-job-worker.sh" TEST_CALLS="$LAB/calls"
cat > "$LAB/bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$1:$2" in
  print:gui/*/dev.firstmate.remote-job)
    printf 'path = %s\nprogram = %s\nlabel = dev.firstmate.remote-job\npid = %s\n' "$TEST_PLIST" "$TEST_WORKER" "$TEST_PID" ;;
  print:gui/*) exit 0 ;;
  *) exit 99 ;;
esac
SH
chmod +x "$LAB/bin/launchctl"
export PATH="$LAB/bin:$PATH"
HEARTBEAT=$(ps -axo pid=,ppid=,command= | awk -v p="$PID" '$2==p && /fm-remote-job-worker.sh/ {print $1; exit}')
[ -n "$HEARTBEAT" ]
kill -STOP "$PID" "$HEARTBEAT"
sleep 11
printf 'Real worker PID %s and heartbeat PID %s paused; ready age %s seconds\n' "$PID" "$HEARTBEAT" "$(( $(date +%s) - $(stat -f %m "$LAB/state/worker.ready") ))"
start=$SECONDS
status=0
fm_remote_job_ensure_worker "$ROOT" "$HOME" > "$LAB/ensure-output" 2>&1 || status=$?
cat "$LAB/ensure-output"
printf 'ensure exit=%s, elapsed=%s, error=%s\n' "$status" "$((SECONDS-start))" "$FM_REMOTE_JOB_ERROR"
printf 'Simulated launchd calls:\n'; cat "$TEST_CALLS"
[ "$status" -ne 0 ]
grep -q 'ready heartbeat stale while verified worker lock owner is alive' "$LAB/ensure-output"
! grep -Eq '^(bootout|bootstrap|kickstart) ' "$TEST_CALLS"
kill -0 "$PID"
kill -CONT "$PID" "$HEARTBEAT"
printf 'Worker survived stale-ready diagnostic without a reload.\n'
