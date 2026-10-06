#!/usr/bin/env bash
# Live scenario driver: real Claude Code in an isolated fm-lab-* Herdr session,
# driven through firstmate's own entrypoints (fm-send.sh, fm-control.sh) and
# adapter composer reads, at HEAD and at base 5838f105.
# Usage: drive.sh <head-root> <base-root> <evidence-dir>
set -u
ROOT=$1
BASE=$2
EV=$3
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
ORIGINAL_PATH=$PATH
LOG=$EV/scenarios.log
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
RESULTS=$EV/scenario-results.txt
: > "$RESULTS"
verdict() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$RESULTS" >> "$LOG"; }

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION=$("$LAB_HELPER" name popupscn)
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-popup-scn.XXXXXX")
LAB=$TMP/home
FAKEBIN=$TMP/fakebin
mkdir -p "$FAKEBIN"

cleanup() {
  local rc=$?
  trap - EXIT
  [ -s "$TMP/wrapper-refusals.log" ] && { say "wrapper refusals:"; cat "$TMP/wrapper-refusals.log" | tee -a "$LOG"; }
  say "--- teardown $SESSION"
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" >> "$LOG" 2>&1 && say "teardown ok" || { say "TEARDOWN FAILED"; rc=1; }
  chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"
  say "sessions after: $(PATH="$ORIGINAL_PATH" herdr session list --json 2>/dev/null | jq -c '[.sessions[] | {name,default,running}]')"
  exit "$rc"
}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { say "lab home create failed"; exit 1; }

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
elif [ "\${args[0]:-}" = status ]; then
  # read-only protocol-floor probe without --session: pin it to the lab session
  :
else
  echo "wrapper requires trailing --session $SESSION: \$*" >> "$TMP/wrapper-refusals.log"
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" >> "$LOG" 2>&1 || { say "provision failed"; exit 1; }
say "lab session: $SESSION  lab home: $LAB"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export FM_HOME=$LAB
export HERDR_SESSION=$SESSION
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

# Disposable project + task worktree; an inert project-local slash command.
PROJ=$TMP/proj
WT=$TMP/wt
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b wkr "$WT"
mkdir -p "$WT/.claude/commands"
cat > "$WT/.claude/commands/fmprobe.md" <<'EOF'
---
description: Inert firstmate popup probe
---
Do not use any tools. Reply with only the uppercase form of this text: fmprobe-ok
EOF
mkdir -p "$LAB/data/wkr"
cat > "$LAB/data/wkr/brief.md" <<'EOF'
# Task
## Captain's intent
Live popup validation worker. Do not run tools or change files.

## Firstmate spec
Reply with exactly RELAUNCH-OK and then stop. Do not use any tools.
EOF

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { say "fm_backend_source herdr failed"; exit 1; }
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || { say "container_ensure failed"; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-wkr "$WT" "$SEEDED_TAB_ID") || { say "create_task failed"; exit 1; }
read -r TAB_ID PANE <<EOF
$TASK_IDS
EOF
TARGET="$SESSION:$PANE"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=wkr"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE"
} > "$LAB/state/wkr.meta"
say "task wkr -> $TARGET (tab $TAB_ID)"
say "versions: $(PATH="$ORIGINAL_PATH" claude --version | head -1) / $(PATH="$ORIGINAL_PATH" herdr --version | head -1)"

printf -v WT_Q '%q' "$WT"
CLAUDE_CMD="unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_EFFORT CLAUDE_CODE_MESSAGING_SOCKET CLAUDECODE CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_MESSAGING_TOKEN; cd $WT_Q && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'"

agent_status() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }
head_state() { fm_backend_herdr_composer_state "$TARGET"; }
head_content() { fm_backend_herdr_composer_content "$TARGET" 2>/dev/null || printf '<extract failed>'; }
base_read() {  # state|content
  env -u FM_ROOT PATH="$PATH" FM_HOME="$LAB" HERDR_SESSION="$SESSION" bash -c '
    . "$1/bin/backends/herdr.sh"
    case "$2" in
      state) fm_backend_herdr_composer_state "$3" ;;
      content) fm_backend_herdr_composer_content "$3" 2>/dev/null || printf "<extract failed>" ;;
    esac' _ "$BASE" "$1" "$TARGET"
}
snap() {  # <name>
  lab pane read "$PANE" --source visible --format ansi > "$EV/$1.ansi" 2>/dev/null
  lab pane read "$PANE" --source visible > "$EV/$1.txt" 2>/dev/null
}
wait_idle_composer() {
  local i=0 st
  while [ "$i" -lt 60 ]; do
    st=$(agent_status)
    case "$st" in idle|done)
      [ "$(head_state)" = empty ] && return 0 ;;
    esac
    i=$((i + 1)); sleep 1
  done
  return 1
}
clear_composer() {
  local i=0
  while [ "$i" -lt 6 ]; do
    [ "$(head_state)" = empty ] && return 0
    fm_backend_herdr_send_key "$TARGET" C-u
    sleep 0.5
    i=$((i + 1))
  done
  [ "$(head_state)" = empty ]
}
launch_claude() {
  lab pane run "$PANE" "$CLAUDE_CMD" >/dev/null || return 1
  local i=0 screen trusted=0 st
  while [ "$i" -lt 90 ]; do
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    case "$screen" in
      *'bypass permissions on'*)
        st=$(agent_status)
        case "$st" in idle|done) return 0 ;; esac ;;
      *'Yes, I trust this folder'*)
        if [ "$trusted" = 0 ]; then trusted=1; lab pane send-keys "$PANE" down enter >/dev/null; fi ;;
      *'Yes, proceed'*|*'Do you want to proceed'*)
        : ;;
    esac
    i=$((i + 1)); sleep 1
  done
  return 1
}
run_send() {  # <root> <args...>  (runbook env hygiene)
  local r=$1; shift
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ROOT \
    FM_HOME="$LAB" "$r/bin/fm-send.sh" "$@"
}
run_control() {  # <root> <args...>
  local r=$1; shift
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_ROOT \
    FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.3 FM_CONTROL_EXIT_WAIT=20 \
    "$r/bin/fm-control.sh" "$@"
}

say "=== launch real Claude in task pane"
launch_claude || { snap launch-failed; say "Claude never reached an idle composer"; exit 1; }
wait_idle_composer || { snap launch-failed; say "composer never read empty"; exit 1; }
snap s0-idle
say "pane geometry: $(lab pane get "$PANE" 2>/dev/null | jq -c '.result.pane | {rows, cols, columns, width, height} // .result' 2>/dev/null | head -c 300)"
say "idle composer: head=$(head_state) base=$(base_read state)"

# --- S1: live composer read of a typed slash command behind the popup -------
for cmd in /exit /no-mistakes /cont; do
  name=s1-typed-${cmd#/}
  wait_idle_composer || say "warn: composer not empty before $cmd"
  lab pane send-text "$PANE" "$cmd" >/dev/null
  sleep 1.5
  snap "$name"
  hs=$(head_state); hc=$(head_content); bs=$(base_read state); bc=$(base_read content)
  marked=$(grep -c "❯.\{1,2\}$cmd" "$EV/$name.txt" || true)
  notice=$(grep -c '⚠' "$EV/$name.txt" || true)
  say "S1 $cmd typed (no Enter): rows-leading-'❯ $cmd'=$marked notice-rows=$notice"
  say "   HEAD state=$hs content=[$hc]"
  say "   BASE state=$bs content=[$bc]"
  if [ "$hs" = pending ] && [ "$hc" = "$cmd" ] && [ "$bc" != "$cmd" ] && [ "$marked" -ge 2 ]; then
    verdict "S1 $cmd" pass "notice-rows=$notice; head reads typed command; base reads popup ($bc)"
  else
    verdict "S1 $cmd" fail "head=$hs/[$hc] base=$bs/[$bc] marked=$marked"
  fi
  clear_composer || say "warn: could not clear composer after $cmd"
  sleep 0.5
done

# --- S2: fm-send typed plane, base then HEAD ---------------------------------
wait_idle_composer
say "=== S2 BASE fm-send wkr /context"
out=$(run_send "$BASE" wkr /context 2>&1); rc=$?
say "rc=$rc"; say "$out"
snap s2-base-fm-send-context-after
say "after: composer=$(head_state) agent=$(agent_status)"
[ "$rc" -ne 0 ] && verdict "S2 base fm-send /context" reproduced "rc=$rc" || verdict "S2 base fm-send /context" not-reproduced "rc=$rc"
clear_composer
wait_idle_composer
say "=== S2 HEAD fm-send wkr /context"
out=$(run_send "$ROOT" wkr /context 2>&1); rc=$?
say "rc=$rc"; say "$out"
sleep 2
snap s2-head-fm-send-context-after
alive=$(agent_status)
hs=$(head_state)
ctx=$(grep -c -i 'context usage\|tokens' "$EV/s2-head-fm-send-context-after.txt" || true)
say "after: composer=$hs agent=$alive context-output-lines=$ctx"
if [ "$rc" = 0 ] && [ -n "$alive" ] && [ "$hs" = empty ] && [ "$ctx" -ge 1 ]; then
  verdict "S2 head fm-send /context" pass "rc=0, /context rendered, agent alive, composer empty"
else
  verdict "S2 head fm-send /context" fail "rc=$rc composer=$hs agent=$alive ctx=$ctx"
fi

# --- S2b: HEAD fm-send of a skill-style project command ----------------------
lab pane send-keys "$PANE" escape >/dev/null 2>&1
wait_idle_composer
say "=== S2b HEAD fm-send wkr /fmprobe (inert project command, stands in for /no-mistakes)"
out=$(run_send "$ROOT" wkr /fmprobe 2>&1); rc=$?
say "rc=$rc"; say "$out"
landed=0; i=0
while [ "$i" -lt 60 ]; do
  if lab pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -q 'FMPROBE-OK'; then landed=1; break; fi
  i=$((i + 1)); sleep 1
done
snap s2b-head-fm-send-fmprobe-after
if [ "$rc" = 0 ] && [ "$landed" = 1 ]; then
  verdict "S2b head fm-send /fmprobe" pass "rc=0 and the command's reply FMPROBE-OK rendered"
else
  verdict "S2b head fm-send /fmprobe" fail "rc=$rc landed=$landed"
fi

# --- S3: adversarial - an operator's typed slash draft must never read empty --
wait_idle_composer
say "=== S3 operator draft '/cont' left in composer (popup open)"
lab pane send-text "$PANE" /cont >/dev/null
sleep 1.5
snap s3-draft-before
say "draft composer: HEAD state=$(head_state) content=[$(head_content)]"
out=$(run_send "$ROOT" wkr /context 2>&1); rc_send=$?
say "S3 fm-send wkr /context over draft: rc=$rc_send"; say "$out"
c1=$(head_content)
out=$(run_send "$ROOT" wkr "ordinary steer during draft" 2>&1); rc_inbox=$?
say "S3 fm-send wkr <plain steer> over draft: rc=$rc_inbox"; say "$out"
inbox_note=$(printf '%s' "$out" | grep -c 'doorbell skipped (composer visibly holds pending text)' || true)
c2=$(head_content)
out=$(run_control "$ROOT" wkr exit 2>&1); rc_exit=$?
say "S3 fm-control wkr exit over draft: rc=$rc_exit"; say "$out"
exit_refused=$(printf '%s' "$out" | grep -c 'visibly holds pending text' || true)
sleep 0.5
snap s3-draft-after
c3=$(head_content); alive=$(agent_status)
say "draft after each call: [$c1] [$c2] [$c3] agent=$alive"
if [ "$rc_send" -ne 0 ] && [ "$inbox_note" -ge 1 ] && [ "$rc_exit" -ne 0 ] && [ "$exit_refused" -ge 1 ] \
   && [ "$c1" = /cont ] && [ "$c2" = /cont ] && [ "$c3" = /cont ] && [ -n "$alive" ]; then
  verdict "S3 draft guard" pass "typed send refused, doorbell skipped, exit refused; draft '/cont' intact; agent alive"
else
  verdict "S3 draft guard" fail "send=$rc_send inbox_note=$inbox_note exit=$rc_exit refused=$exit_refused drafts=[$c1][$c2][$c3] agent=$alive"
fi
clear_composer || say "warn: draft not cleared"

# --- S4: fm-control exit, base then HEAD --------------------------------------
wait_idle_composer
say "=== S4 BASE fm-control wkr exit"
out=$(run_control "$BASE" wkr exit 2>&1); rc=$?
say "rc=$rc"; say "$out"
snap s4-base-fm-control-exit-after
alive=$(agent_status)
say "after: agent=$alive composer=$(head_state)"
case "$out" in *'the exit command could not be sent to task wkr on herdr'*) verdict "S4 base fm-control exit" reproduced "rc=$rc agent=$alive" ;; *) verdict "S4 base fm-control exit" not-reproduced "rc=$rc" ;; esac
clear_composer
wait_idle_composer
say "=== S4 HEAD fm-control wkr exit"
out=$(run_control "$ROOT" wkr exit 2>&1); rc=$?
say "rc=$rc"; say "$out"
sleep 1
snap s4-head-fm-control-exit-after
if lab agent get "$PANE" >/dev/null 2>&1; then gone=0; else gone=1; fi
say "after: agent-registered=$((1 - gone)) state=$(fm_backend_agent_state herdr "$TARGET" 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$gone" = 1 ]; then
  verdict "S4 head fm-control exit" pass "stopped; agent deregistered"
else
  verdict "S4 head fm-control exit" fail "rc=$rc gone=$gone"
fi

# --- S5: fm-control relaunch on HEAD ------------------------------------------
say "=== S5 relaunch: start Claude again, then HEAD fm-control wkr relaunch"
launch_claude || say "warn: second launch never idle"
wait_idle_composer || say "warn: composer not empty before relaunch"
snap s5-before-relaunch
old_pid=$(lab pane process-info "$PANE" 2>/dev/null | jq -c '.' | head -c 400)
say "process before: $old_pid"
out=$(run_control "$ROOT" wkr relaunch --note "live slash-popup validation relaunch" 2>&1); rc=$?
say "rc=$rc"; say "$out"
landed=0; i=0
while [ "$i" -lt 90 ]; do
  if lab pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -q 'RELAUNCH-OK'; then landed=1; break; fi
  i=$((i + 1)); sleep 1
done
snap s5-after-relaunch
st=$(agent_status)
say "after relaunch: agent_status=$st brief-reply=$landed"
say "meta after: $(grep -E '^(window|harness|control_)' "$LAB/state/wkr.meta" | tr '\n' ' ')"
if [ "$rc" = 0 ] && [ -n "$st" ]; then
  verdict "S5 head fm-control relaunch" pass "rc=0; replacement Claude registered ($st); brief reply rendered=$landed"
else
  verdict "S5 head fm-control relaunch" fail "rc=$rc agent=$st landed=$landed"
fi
say "=== done"
