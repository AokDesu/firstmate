#!/bin/bash
# Run from the gate worktree. Disposable local execution, no SSH or fleet state.
set -u
ROOT=$PWD
. "$ROOT/tests/git-config-helpers.sh"
BASE=23e5584714e6765cc223a1740d385d0e85f8ad8e
EVIDENCE=/Users/kunchen/.no-mistakes/evidence/01M3SXXW42FAV5829FPZ1WMTYM
PY=$(command -v python3)
for variant in baseline candidate; do
 (
  W="$ROOT/.test-p1/measure-$variant"
  mkdir -p "$W/root/bin" "$W/account" "$W/home" "$W/wrappers"
  for script in fm-remote-job-lib.sh fm-remote-job-worker.sh; do
   if [ "$variant" = baseline ]; then git show "$BASE:bin/$script" > "$W/root/bin/$script"; else cp "$ROOT/bin/$script" "$W/root/bin/$script"; fi
  done
  printf '#!/bin/bash\nsleep 3\nprintf "completed payload\\n"\n"%s" -c '\''import time,sys;open(sys.argv[1],"w").write(str(time.monotonic()))'\'' "$1"\n' "$PY" > "$W/root/bin/fm-measure-job.sh"
  cp "$ROOT/AGENTS.md" "$W/root/AGENTS.md"
  chmod +x "$W/root/bin/"*.sh
  git -C "$W/root" init -q
  git -C "$W/root" config user.name Test
  git -C "$W/root" config user.email test@example.com
  git -C "$W/root" add bin
  git -C "$W/root" commit --allow-empty -qm measurement
  for tool in sleep wc tr tail date; do
   real=$(command -v "$tool")
   printf '#!/bin/bash\nprintf "%s\\n" >> "%s"\nexec "%s" "$@"\n' "$tool" "$W/calls" "$real" > "$W/wrappers/$tool"
   chmod +x "$W/wrappers/$tool"
  done
  unset FM_REMOTE_JOB_POLL_SECONDS FM_REMOTE_JOB_ACTIVE_POLL_SECONDS FM_REMOTE_JOB_PLATFORM_OVERRIDE
  export FM_ROOT_OVERRIDE="$W/root" FM_REMOTE_JOB_STATE_ROOT="$W/state" FM_REMOTE_JOB_QUEUE_TIMEOUT=60 FM_REMOTE_JOB_TIMEOUT=30
  . "$W/root/bin/fm-remote-job-lib.sh"
  . "$W/root/bin/fm-remote-job-lib.sh"
  fm_remote_job_stage "$W/account" "$W/root" "$W/home" fm-measure-job.sh "$W/completed" </dev/null >/dev/null
  export PATH="$W/wrappers:$PATH"
  : > "$W/calls"
  start=$("$PY" -c 'import time;print(time.monotonic())')
  HOME="$W/account" /bin/bash "$W/root/bin/fm-remote-job-worker.sh" --lane "$FM_REMOTE_JOB_ID" > "$W/lane.log" 2>&1 &
  lane=$!
  trap 'kill -TERM "$lane" 2>/dev/null || true; wait "$lane" 2>/dev/null || true' EXIT
  fm_remote_job_wait "$W/account" "$FM_REMOTE_JOB_ID" || { printf 'wait failed: %s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
  end=$("$PY" -c 'import time;print(time.monotonic())')
  wait "$lane"
  trap - EXIT
  [ "$FM_REMOTE_JOB_EXIT" = 0 ] || exit 1
  grep -qx 'completed payload' "$FM_REMOTE_JOB_STDOUT" || exit 1
  "$PY" - "$variant" "$start" "$end" "$W/completed" "$W/calls" <<'PY'
import sys,collections,json
variant,start,end,completed,calls=sys.argv[1:]
duration=float(end)-float(start)
counts=collections.Counter(open(calls).read().splitlines())
print(json.dumps(dict(variant=variant,seconds=round(duration,3),completion_to_result_ms=round((float(end)-float(open(completed).read()))*1000),instrumented_exec_total=sum(counts.values()),instrumented_exec_per_second=round(sum(counts.values())/duration,2),by_tool=dict(counts),exit=0,payload='completed payload')))
PY
  cp "$W/calls" "$EVIDENCE/$variant-exec-calls.log"
 ) || exit 1
done
printf '%s\n' 'Counts cover actual sleep/wc/tr/tail/date executable invocations in real lane + public result wait, not all forks or host pidversion. One sequential 3-second job per variant; instrumentation overhead and scheduling apply; no fleet-wide benefit inferred.'
