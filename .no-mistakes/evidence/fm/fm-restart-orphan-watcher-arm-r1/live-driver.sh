#!/usr/bin/env bash
set -eu
ROOT=$PWD
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SUPERVISION_HOST_PRIMARY=claude
STATE="$FM_HOME/state"
exec > >(tee "$FM_HOME/live-$1.log") 2>&1
waitfor() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -lt 200 ] || { echo "FAILED waiting: $*"; exit 1; }; sleep .1; done; }
livewatch() { [ -f "$STATE/.watch.lock/pid" ] && kill -0 "$(<"$STATE/.watch.lock/pid")" 2>/dev/null && [ -f "$STATE/.last-watcher-beat" ]; }
closed() { [ -f "$FM_HOME/host.rc" ]; }
start() { rm -f "$FM_HOME/host.rc"; (set +e; bin/fm-supervision-host.sh park > "$FM_HOME/host.out" 2>&1; echo $? > "$FM_HOME/host.rc") & }
append() { printf 'needs-decision [at=%s]: %s\n' "$(date +%s)" "$1" >> "$STATE/demo.status"; }
ack() { local out args; out=$(bin/fm-wake-drain.sh 2>&1); printf '%s\n' "$out"; args=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1); [ -z "$args" ] || bin/fm-wake-drain.sh $args; }
owned() { local h a w; h=$(awk -F '\t' '$1=="host"{print $2;exit}' "$STATE/.supervision-host" 2>/dev/null); w=$(cat "$STATE/.watch.lock/pid" 2>/dev/null); [ -n "$h" ] && [ -n "$w" ] || return 1; a=$(ps -o ppid= -p "$w" | tr -d ' '); [ "$(ps -o ppid= -p "$a" | tr -d ' ')" = "$h" ] && [ "$a" != "$(cat "$FM_HOME/left-arm" 2>/dev/null)" ]; }
show() { echo '--- host ledger'; tail -20 "$STATE/.supervision-host.log"; echo '--- process topology'; local h w a; h=$(awk -F '\t' '$1=="host"{print $2;exit}' "$STATE/.supervision-host" 2>/dev/null || true); w=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true); a=$(ps -o ppid= -p "${w:-0}" 2>/dev/null | tr -d ' '); ps -o pid=,ppid=,command= -p "${h:-0},${a:-0},${w:-0}" || true; }
bin/fm-lock.sh
case "$1" in
leave)
 printf 'project=demo\nwindow=primary:nonexistent\nharness=claude\n' > "$STATE/demo.meta"
 start; waitfor livewatch; append 'which export format?'; waitfor closed
 cat "$FM_HOME/host.out"; show
 [ -s "$STATE/.supervision-host-left" ]
 IFS=$'\t' read -r a id < "$STATE/.supervision-host-left"
 echo "$a" > "$FM_HOME/left-arm"; cat "$STATE/.watch.lock/pid" > "$FM_HOME/left-watcher"
 ack
 echo "LEFT arm=$a identity=$id watcher=$(<"$FM_HOME/left-watcher")"
 ;;
takeover)
 old=$(<"$FM_HOME/left-arm"); oldw=$(<"$FM_HOME/left-watcher")
 kill -0 "$old"; echo "Old arm survived real primary restart: $old"
 ack
 start; waitfor owned; sleep 2
 ! kill -0 "$old" 2>/dev/null; ! kill -0 "$oldw" 2>/dev/null
 [ ! -f "$FM_HOME/host.rc" ]; show; cat "$STATE/.watcher-down"
 append 'which region?'; waitfor closed; cat "$FM_HOME/host.out"; show
 echo 'PASS actual-primary restart takes over and delivers next decision'
 ;;
interrupt)
 ack
 IFS=$'\t' read -r old id < "$STATE/.supervision-host-left"
 echo "$old" > "$FM_HOME/left-arm"
 . bin/fm-wake-lib.sh
 (fm_lock_acquire_wait "$STATE/.watcher-down.lock"; touch "$FM_HOME/held"; while [ ! -f "$FM_HOME/release" ]; do sleep .1; done; fm_lock_release "$STATE/.watcher-down.lock") & holder=$!
 waitfor test -f "$FM_HOME/held"
 start
 waitfor test -f "$STATE/.supervision-host"
 h=$(awk -F '\t' '$1=="host"{print $2;exit}' "$STATE/.supervision-host")
 sleep 1
 kill -0 "$old"
 kill -TERM "$h"
 waitfor closed
 IFS=$'\t' read -r kept keptid < "$STATE/.supervision-host-left"
 [ "$kept" = "$old" ]; [ "$keptid" = "$id" ]; kill -0 "$old"
 echo "Interrupted host $h retained identity-bound reference: $kept $keptid"
 touch "$FM_HOME/release"; wait "$holder"
 start; waitfor owned; sleep 1; ! kill -0 "$old" 2>/dev/null
 show
 append 'decision after interrupted takeover'; waitfor closed; cat "$FM_HOME/host.out"
 echo 'PASS interrupted takeover is retried by next park'
 ;;
directory)
 bin/fm-watch-arm.sh --stop
 sleep 2
 python3 - "$STATE" <<'CLEAN'
import pathlib,shutil,sys
for p in pathlib.Path(sys.argv[1]).iterdir():
 if p.name in ('.fm-lab-tmux-dir','.lock','.lock-session'): continue
 if p.is_dir(): shutil.rmtree(p)
 else: p.unlink()
CLEAN
 printf 'project=demo\nwindow=primary:nonexistent\nharness=claude\n' > "$STATE/demo.meta"
 mkdir "$STATE/.supervision-host-left"
 start; waitfor livewatch; append 'directory destination decision'; waitfor closed
 cat "$FM_HOME/host.out"; show
 grep -q 'successor-unrecorded' "$STATE/.supervision-host.log"
 [ ! -f "$STATE/.watch.lock/pid" ]
 rmdir "$STATE/.supervision-host-left"
 echo 'Directory record rejected; temporary record removed; successor watcher stopped'
 ack
 start; waitfor livewatch; sleep 2
 h=$(awk -F '\t' '$1=="host"{print $2;exit}' "$STATE/.supervision-host")
 w=$(cat "$STATE/.watch.lock/pid"); a=$(ps -o ppid= -p "$w" | tr -d ' ')
 [ "$(ps -o ppid= -p "$a" | tr -d ' ')" = "$h" ]
 show
 kill -TERM "$h"; waitfor closed
 echo 'PASS unrecorded successor is cleaned up and next park owns fresh cycle'
 ;;
foreign)
 bin/fm-watch-arm.sh --stop; sleep 2
 python3 - "$STATE" <<'CLEAN'
import pathlib,shutil,sys
for p in pathlib.Path(sys.argv[1]).iterdir():
 if p.name in ('.fm-lab-tmux-dir','.lock','.lock-session'): continue
 if p.is_dir(): shutil.rmtree(p)
 else: p.unlink()
CLEAN
 printf 'project=demo\nwindow=primary:nonexistent\nharness=claude\n' > "$STATE/demo.meta"
 bin/fm-watch-arm.sh > "$FM_HOME/owner.out" 2>&1 & owner=$!
 waitfor livewatch; sleep 1
 before=$(cat "$STATE/.watch.lock/pid")
 bin/fm-watch-arm.sh --take-over "$$" > "$FM_HOME/foreign.out" 2>&1 & attached=$!
 waitfor grep -q 'watcher: attached' "$FM_HOME/foreign.out"
 [ "$(cat "$STATE/.watch.lock/pid")" = "$before" ]; kill -0 "$before"
 echo "Unrelated takeover attached without stopping watcher $before:"
 cat "$FM_HOME/foreign.out"
 ps -o pid=,ppid=,command= -p "$owner,$attached,$before"
 kill -TERM "$attached"; wait "$attached" || true
 kill -0 "$before"
 append 'foreign takeover must still deliver'
 wait "$owner"; cat "$FM_HOME/owner.out"
 echo 'PASS wrong owner cannot take over and owning arm still delivers next wake'
 ;;
*) exit 2;;
esac
