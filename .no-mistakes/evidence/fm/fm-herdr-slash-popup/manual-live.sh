#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
BASE=$ROOT/.test-slash-popup
EVIDENCE=/home/symphony/.no-mistakes/evidence/01M5W4BVV35QDEMTPR1Y1SJ8PZ
ORIGINAL_PATH=$PATH
export FM_HOME=$BASE/manual-home-fixed FM_HERDR_LAB_STATE_DIR=$BASE/lab-state
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
touch "$FM_HOME/config/supervision-host-off"
HELPER=$BASE/evidence-lab.sh
SESSION=$("$HELPER" name slash-manual)
cleanup() {
  rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1
  printf 'lab teardown rc=%s\n' "$rc"
  exit "$rc"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION"
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
ws=$(lab workspace create --cwd "$ROOT" --label fm-slash-manual --no-focus)
PANE=$(jq -er '.result.root_pane.pane_id' <<< "$ws")
TAB=$(lab pane get "$PANE" | jq -er '.result.pane.tab_id // .result.tab_id')
WORKSPACE=$(jq -er '.result.workspace.workspace_id // .result.workspace_id' <<< "$ws")
mkdir -p "$BASE/real-bin"
cat > "$BASE/real-bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[n-2]}" = --session ] && [ "\${args[n-1]}" = "$SESSION" ] || { echo 'refused unscoped Herdr call' >&2; exit 97; }
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "\${args[@]:0:n-2}"
EOF
chmod +x "$BASE/real-bin/herdr"
export PATH="$BASE/real-bin:$ORIGINAL_PATH"
. "$ROOT/bin/backends/herdr.sh"
TARGET=$SESSION:$PANE
cat > "$FM_HOME/state/slash-live.meta" <<EOF
window=$TARGET
endpoint_task_id=slash-live
worktree=$ROOT
project=$ROOT
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"disableAllHooks\":true,\"feedbackDrafts\":\"off\"}'" >/dev/null
ready=0
for i in $(seq 1 60); do
  screen=$(lab pane read "$PANE" --source visible)
  if [[ $screen == *'bypass permissions on'* ]]; then ready=1; break; fi
  if [[ $screen == *'Yes, I trust this folder'* ]]; then lab pane send-keys "$PANE" down enter >/dev/null; fi
  sleep 1
done
[ "$ready" = 1 ] || { printf 'Claude did not render composer\n'; exit 1; }
for typed in '/' '/no-mistakes'; do
  lab pane send-text "$PANE" "$typed" >/dev/null
  sleep 1.2
  state=$(fm_backend_herdr_composer_state "$TARGET")
  content=$(fm_backend_herdr_composer_content "$TARGET")
  printf 'typed=%q state=%q content=%q\n' "$typed" "$state" "$content"
  [ "$state" = pending ] && [ "$content" = "$typed" ]
  lab pane read "$PANE" --source visible --format ansi > "$EVIDENCE/manual-${typed//\//slash}.ansi"
  if [ "$typed" = /no-mistakes ]; then
    before=$(lab pane read "$PANE" --source visible)
    if "$ROOT/bin/fm-send.sh" slash-live /context; then printf 'unexpected overwrite success\n'; exit 1; else printf 'fm-send refused an overwrite of the pending slash draft\n'; fi
    after=$(lab pane read "$PANE" --source visible)
    [ "$before" = "$after" ] || { printf 'pending composer changed after refusal\n'; exit 1; }
    printf 'pending /no-mistakes draft unchanged; no command executed\n'
  fi
  lab pane send-keys "$PANE" ctrl+u >/dev/null
  sleep 0.4
done
"$ROOT/bin/fm-send.sh" slash-live /context
rendered=0
for i in $(seq 1 30); do
  screen=$(lab pane read "$PANE" --source recent --lines 1000)
  if [[ $screen == *'Context Usage'* ]]; then rendered=1; break; fi
  sleep 1
done
[ "$rendered" = 1 ]
printf '%s\n' "$screen" > "$EVIDENCE/manual-context-report.txt"
printf 'fm-send slash-live /context: rendered Context Usage; registered agent survives\n'
lab agent get "$PANE"
"$ROOT/bin/fm-control.sh" slash-live exit
if lab agent get "$PANE" >/dev/null 2>&1; then printf 'agent still registered after exit\n'; exit 1; fi
lab pane read "$PANE" --source recent --lines 70 > "$EVIDENCE/manual-exited.txt"
printf 'fm-control slash-live exit: agent absent; endpoint preserved\n'
lab pane get "$PANE" >/dev/null
