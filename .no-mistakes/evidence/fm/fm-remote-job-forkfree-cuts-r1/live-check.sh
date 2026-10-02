#!/bin/bash
set -eu
ROOT=$PWD
E=/Users/kunchen/.no-mistakes/evidence/01M3X87JCXGHSTVGY8A17KH722
F="$ROOT/.test-phase-tmp/manual"
mkdir -p "$F/home/state" "$F/account" "$F/shim" "$F/old"
export TMPDIR="$ROOT/.test-phase-tmp"
trap 'rm -rf "$F"' EXIT
EMPTY=$(printf '' | shasum -a 256 | awk '{print $1}')
LOG="$F/home/state/replies"
READER="$ROOT/bin/fm-remote-delta-read.sh"
run() { FM_HOME="$F/home" FM_REMOTE_DELTA_POLL_SECONDS=0.05 "$READER" state/replies "$@"; }
{
printf '=== Atomic rotation to different same-length contents ===\n'
printf 'alpha\nbeta\n' > "$LOG"
HASH=$(shasum -a 256 "$LOG" | awk '{print $1}')
run 11 "$HASH" 3 > "$F/rotation" & pid=$!
sleep 0.3
printf 'OMEGA\nbeta\n' > "$LOG.new"; mv "$LOG.new" "$LOG"
wait "$pid"
cat "$F/rotation"
grep -qx 'reason=prefix-changed' "$F/rotation"
printf '\n=== Unchanged log closes its wait without payload ===\n'
: > "$LOG"
rc=0; run 0 "$EMPTY" 1 > "$F/idle" || rc=$?
printf 'empty-log exit=%s output_bytes=%s\n' "$rc" "$(wc -c < "$F/idle")"
[ "$rc" -eq 75 ]
printf '\n=== Consumer runs real worker lane and collects delta ===\n'
export FM_REMOTE_JOB_STATE_ROOT="$F/jobs" FM_REMOTE_JOB_QUEUE_TIMEOUT=10 FM_REMOTE_JOB_TIMEOUT=10 FM_REMOTE_JOB_WAIT_GRACE=0 FM_ROOT_OVERRIDE="$ROOT"
. "$ROOT/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$F/account" "$ROOT" "$F/home" fm-remote-delta-read.sh state/replies 0 "$EMPTY" 3 < /dev/null > /dev/null
ID=$FM_REMOTE_JOB_ID
HOME="$F/account" /bin/bash "$ROOT/bin/fm-remote-job-worker.sh" --lane "$ID" > "$F/lane.log" 2>&1 & lane=$!
(sleep 0.5; printf 'live lane payload\n' >> "$LOG") & producer=$!
fm_remote_job_wait "$F/account" "$ID"
wait "$lane"; wait "$producer"
printf 'job=%s state=%s exit=%s\n' "$ID" "$(fm_remote_job_read_state "$F/jobs/jobs/$ID")" "$FM_REMOTE_JOB_EXIT"
cat "$FM_REMOTE_JOB_STDOUT"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ]
printf '\n=== Waiting consumer invokes date once, not per sample ===\n'
cat > "$F/shim/date" <<SH
#!/bin/bash
printf 'date\n' >> '$F/date.log'
exec /bin/date "\$@"
SH
chmod +x "$F/shim/date"
fm_remote_job_stage "$F/account" "$ROOT" "$F/home" fm-remote-delta-read.sh state/replies 0 "$EMPTY" 1 < /dev/null > /dev/null
job="$F/jobs/jobs/$FM_REMOTE_JOB_ID"
(sleep 1.3; : > "$job/stdout"; : > "$job/stderr"; printf '0\n' > "$job/exit"; fm_remote_job_write_state "$job" done) & producer=$!
: > "$F/date.log"
PATH="$F/shim:$PATH" fm_remote_job_wait "$F/account" "$FM_REMOTE_JOB_ID"
wait "$producer"
printf 'consumer exit=%s date_calls=%s\n' "$FM_REMOTE_JOB_EXIT" "$(wc -l < "$F/date.log")"
[ "$(wc -l < "$F/date.log")" -eq 1 ]
printf '\n=== Expired consumer deadline refuses further waiting ===\n'
fm_remote_job_stage "$F/account" "$ROOT" "$F/home" fm-remote-delta-read.sh state/replies 0 "$EMPTY" 1 < /dev/null > /dev/null
printf '1\n' > "$F/jobs/jobs/$FM_REMOTE_JOB_ID/queue_deadline"
rc=0; fm_remote_job_wait "$F/account" "$FM_REMOTE_JOB_ID" || rc=$?
printf 'exit=%s error=%s\n' "$rc" "$FM_REMOTE_JOB_ERROR"
[ "$rc" -eq 1 ]
printf '\n=== Consumer actively rejects malformed serialized state ===\n'
fm_remote_job_stage "$F/account" "$ROOT" "$F/home" fm-remote-delta-read.sh state/replies 0 "$EMPTY" 1 < /dev/null > /dev/null
job="$F/jobs/jobs/$FM_REMOTE_JOB_ID"
for kind in multiline oversize unknown unterminated nul utf8; do
  case "$kind" in
    multiline) printf 'queued\nextra\n' > "$job/state" ;;
    oversize) printf 'queued\n%080d' 0 > "$job/state" ;;
    unknown) printf 'invalid\n' > "$job/state" ;;
    unterminated) printf 'queued' > "$job/state" ;;
    nul) printf 'queued\n\0tail' > "$job/state" ;;
    utf8) perl -e 'print "queued\n", "\xc3\xa9" x 30' > "$job/state" ;;
  esac
  rc=0; LC_ALL=en_US.UTF-8 fm_remote_job_wait "$F/account" "$FM_REMOTE_JOB_ID" || rc=$?
  printf '%s: consumer exit=%s error=%s\n' "$kind" "$rc" "$FM_REMOTE_JOB_ERROR"
  [ "$rc" -eq 1 ]; [ "$FM_REMOTE_JOB_ERROR" = 'remote job state is invalid' ]
done
printf '\n=== Disconnected consumer cancels queued job ===\n'
fm_remote_job_stage "$F/account" "$ROOT" "$F/home" fm-remote-delta-read.sh state/replies 0 "$EMPTY" 1 < /dev/null > /dev/null
connection_probe() { return 1; }
rc=0; FM_REMOTE_JOB_DISCONNECT_PROBE=connection_probe fm_remote_job_wait "$F/account" "$FM_REMOTE_JOB_ID" || rc=$?
printf 'consumer exit=%s error=%s cancel_marker=%s\n' "$rc" "$FM_REMOTE_JOB_ERROR" "$(test -f "$F/jobs/jobs/$FM_REMOTE_JOB_ID/cancel" && echo present || echo absent)"
[ "$rc" -eq 1 ]; [ "$FM_REMOTE_JOB_ERROR" = 'remote job caller disconnected; the job was cancelled' ]
printf '\n=== UTF-8 state regression: original versus fixed reader ===\n'
git show 3b0b31d8:bin/fm-remote-job-lib.sh > "$F/old/lib.sh"
mkdir "$F/state-record"
perl -e 'print "queued\n", "\xc3\xa9" x 30' > "$F/state-record/state"
for version in old fixed; do
  lib="$ROOT/bin/fm-remote-job-lib.sh"; [ "$version" != old ] || lib="$F/old/lib.sh"
  LC_ALL=en_US.UTF-8 bash -c '. "$1"; rc=0; value=$(fm_remote_job_read_state "$2") || rc=$?; printf "%s: bytes=67 exit=%s value=%s\n" "$3" "$rc" "$value"; if [ "$3" = fixed ]; then [ "$rc" -eq 1 ]; else [ "$rc" -eq 0 ]; fi' _ "$lib" "$F/state-record" "$version"
done
} > "$E/live-product-transcript.log" 2>&1
