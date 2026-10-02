#!/bin/bash
set -eu
ROOT=$PWD
E=/Users/kunchen/.no-mistakes/evidence/01M3X87JCXGHSTVGY8A17KH722
F="$ROOT/.test-phase-tmp/delta-regressions"
mkdir -p "$F/home/state" "$F/shim"
export TMPDIR="$ROOT/.test-phase-tmp" FM_HOME="$F/home" FM_REMOTE_DELTA_POLL_SECONDS=0.05
trap 'rm -rf "$F"' EXIT
LOG="$F/home/state/log"
HASH=$(printf 'alpha\nbeta\n' | shasum -a 256 | awk '{print $1}')
git show 3b0b31d8:bin/fm-remote-delta-read.sh > "$F/pre-fix.sh"
git show 8690c411:bin/fm-remote-delta-read.sh > "$F/base.sh"
cat > "$F/shim/perl" <<'SH'
#!/bin/bash
if [ -n "${DELETE_ON_CAPTURE:-}" ]; then rm -f "$DELETE_ON_CAPTURE"; fi
/usr/bin/perl "$@"
rc=$?
[ -z "${CAPTURE_READY:-}" ] || touch "$CAPTURE_READY"
exit "$rc"
SH
chmod +x "$F/shim/perl"
{
printf '=== Same-second same-size same-inode rewrite: pre-fix versus fixed ===\n'
for version in pre-fix fixed; do
  reader="$ROOT/bin/fm-remote-delta-read.sh"; [ "$version" != pre-fix ] || reader="$F/pre-fix.sh"
  /usr/bin/perl -MTime::HiRes=time,sleep -e 'sleep(1 - (time - int(time)))'
  printf 'alpha\nbeta\n' > "$LOG"
  before=$(stat -f '%c:%i:%z' "$LOG")
  rm -f "$F/ready"
  CAPTURE_READY="$F/ready" PATH="$F/shim:/usr/bin:/bin" /bin/bash "$reader" state/log 11 "$HASH" 2 > "$F/$version.out" 2> "$F/$version.err" & pid=$!
  for ((i=0;i<80;i++)); do [ ! -f "$F/ready" ] || break; sleep 0.01; done
  [ -f "$F/ready" ]; sleep 0.1
  printf 'OMEGA\nbeta\n' > "$LOG"
  after=$(stat -f '%c:%i:%z' "$LOG")
  [ "$before" = "$after" ]
  rc=0; wait "$pid" || rc=$?
  printf '%s: identity_before=%s identity_after=%s exit=%s\n' "$version" "$before" "$after" "$rc"
  cat "$F/$version.out" "$F/$version.err"
  if [ "$version" = fixed ]; then [ "$rc" -eq 0 ]; grep -qx 'reason=prefix-changed' "$F/$version.out"; else [ "$rc" -eq 75 ]; fi
done
printf '\n=== Coarse host stat cannot mask same-second rewrite ===\n'
cat > "$F/shim/stat" <<'SH'
#!/bin/bash
if [ "${1:-}" = -f ] && [ "${2:-}" = '%z:%Fm:%Fc:%i:%d' ]; then
  exec /usr/bin/stat -f '%z:%m:%c:%i:%d' "$3"
fi
exec /usr/bin/stat "$@"
SH
chmod +x "$F/shim/stat"
printf 'alpha\nbeta\n' > "$LOG"
rm -f "$F/ready"
CAPTURE_READY="$F/ready" PATH="$F/shim:/usr/bin:/bin" /bin/bash "$ROOT/bin/fm-remote-delta-read.sh" state/log 11 "$HASH" 2 > "$F/coarse.out" & pid=$!
for ((i=0;i<80;i++)); do [ ! -f "$F/ready" ] || break; sleep 0.01; done
sleep 0.1; printf 'OMEGA\nbeta\n' > "$LOG"
wait "$pid"
cat "$F/coarse.out"
grep -qx 'reason=prefix-changed' "$F/coarse.out"
rm "$F/shim/stat"
printf '\n=== Unlink during safe capture: baseline versus fixed ===\n'
for version in base fixed; do
  reader="$ROOT/bin/fm-remote-delta-read.sh"; [ "$version" != base ] || reader="$F/base.sh"
  printf 'alpha\nbeta\n' > "$LOG"
  rc=0
  DELETE_ON_CAPTURE="$LOG" PATH="$F/shim:/usr/bin:/bin" /bin/bash "$reader" state/log 11 "$HASH" 1 > "$F/delete.out" 2> "$F/delete.err" || rc=$?
  printf '%s unlink-during-capture exit=%s\n' "$version" "$rc"
  cat "$F/delete.out" "$F/delete.err"
  [ "$rc" -eq 1 ]
done
} > "$E/delta-regression-transcript.log" 2>&1
