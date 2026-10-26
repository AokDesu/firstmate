#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.x
EVIDENCE=/home/symphony/.no-mistakes/evidence/01M5W4BVV35QDEMTPR1Y1SJ8PZ
TMUX_BIN=$(command -v tmux)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/bin"
touch "$LAB/config/supervision-host-off"
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
cat > "$LAB/bin/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_BIN" -L fm-lab "\$@"
EOF
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH"
cleanup() {
 rc=$?
 trap - EXIT
 "$TMUX_BIN" -L fm-lab kill-server || rc=1
 printf 'private tmux server teardown rc=%s\n' "$rc"
 exit "$rc"
}
trap cleanup EXIT
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" "$TMUX_BIN" -L fm-lab new-session -d -x 120 -y 40 -s primary -n fm-tmuxlive -c "$PWD" -e FM_HOME="$LAB" "bash --noprofile --norc"
tmux send-keys -t primary -l "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"disableAllHooks\":true,\"feedbackDrafts\":\"off\"}'"
tmux send-keys -t primary Enter
tmux set-option -w -t primary remain-on-exit on
tmux set-option -w -t primary automatic-rename off
tmux set-option -w -t primary allow-rename off
tmux rename-window -t primary fm-tmuxlive
cat > "$LAB/state/tmuxlive.meta" <<EOF
window=primary:fm-tmuxlive
endpoint_task_id=tmuxlive
worktree=$ROOT
project=$ROOT
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=tmux
EOF
ready=0
for i in $(seq 1 60); do
 screen=$(tmux capture-pane -p -t primary)
 if [[ $screen == *'bypass permissions on'* ]]; then ready=1; break; fi
 sleep 1
done
[ "$ready" = 1 ]
. "$ROOT/bin/fm-tmux-lib.sh"
tmux send-keys -t primary -l '/exit'
sleep 1.2
state=$(fm_tmux_composer_state primary:fm-tmuxlive)
printf 'tmux typed /exit state=%s\n' "$state"
tmux capture-pane -e -p -t primary > "$EVIDENCE/tmux-exit-popup.ansi"
tmux display-message -p -t primary 'cursor=#{cursor_y},#{cursor_x} pane=#{pane_width}x#{pane_height} command=#{pane_current_command}'
[ "$state" != empty ]
tmux capture-pane -e -p -t primary > "$EVIDENCE/tmux-exit-popup.ansi"
tmux send-keys -t primary C-u
sleep 0.4
"$ROOT/bin/fm-send.sh" tmuxlive /context
rendered=0
for i in $(seq 1 30); do
 screen=$(tmux capture-pane -p -t primary -S -1500)
 if [[ $screen == *'Context Usage'* ]]; then rendered=1; break; fi
 sleep 1
done
[ "$rendered" = 1 ]
printf '%s\n' "$screen" > "$EVIDENCE/tmux-context-report.txt"
printf 'tmux fm-send /context rendered Context Usage\n'
"$ROOT/bin/fm-control.sh" tmuxlive exit
screen=$(tmux capture-pane -p -t primary -S -60)
printf '%s\n' "$screen" > "$EVIDENCE/tmux-exited.txt"
printf 'tmux fm-control exit stopped Claude\n'
