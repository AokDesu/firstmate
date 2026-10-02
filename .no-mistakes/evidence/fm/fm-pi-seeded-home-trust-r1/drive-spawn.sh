#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/kunchen/.no-mistakes/evidence/01M3XVFN3SMD5SSXBTPDBXVGJ3
D="$ROOT/.live-tmp"
P="$D/product"
LAB="$D/home"
SOCK="$ROOT/.live-tmp/s"
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null || true; chmod -R u+w "$D/home" 2>/dev/null || true; rm -rf "$D/product" "$D/home" "$D/mate-pi" "$D/mate-pi-signed" "$D/pi-agent" "$D/os-home"; }
trap cleanup EXIT
mkdir -p "$P" "$D/pi-agent" "$D/os-home"
printf '# Disposable shell configuration: skip zsh first-run wizard.\n' > "$D/os-home/.zshrc"
git archive HEAD | tar -x -C "$P"
git -C "$P" init -q -b main
git -C "$P" add .
git -C "$P" -c user.name=Lab -c user.email=lab@example.invalid commit -qm snapshot
"$P/bin/fm-lab-home.sh" create "$LAB"
printf '{}\n' > "$D/pi-agent/trust.json"
export HOME="$D/os-home" PI_CODING_AGENT_DIR="$D/pi-agent" PI_OFFLINE=1 FM_HOME="$LAB" TMPDIR="$D"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE TASKS_AXI_FILE TASKS_AXI_BACKEND
printf 'pi\n' > "$LAB/config/secondmate-harness"
touch "$LAB/state/.last-watcher-beat"
tmux -S "$SOCK" new-session -d -s lab -x 120 -y 40 -c "$P" /bin/bash
export TMUX="$(tmux -S "$SOCK" display-message -p -t lab '#{socket_path}'),$(tmux -S "$SOCK" display-message -p '#{pid}'),0"
for H in pi pi-signed; do
  ID="trust-${H}-lab"
  M="$D/mate-$H"
  git clone -q "$P" "$M"
  FM_SECONDMATE_CHARTER='For the trust launch check only: reply TRUST_LAUNCH_READY and wait. Do not run tools or change files.' FM_SECONDMATE_SCOPE='Disposable trust launch verification' "$P/bin/fm-home-seed.sh" "$ID" "$M" --no-projects
  # Reproduce through the pre-change real spawn executable on the same seeded home.
  printf '%s\n' "$H" > "$LAB/config/secondmate-harness"
  git -C "$ROOT" show 65e2aa443a42108689eee260a0d792608ec3540b:bin/fm-spawn.sh > "$P/bin/fm-spawn.sh"
  "$P/bin/fm-spawn.sh" "$ID" "$M" --secondmate > "$E/baseline-spawn-$H.txt" 2>&1
  BASE_WINDOW=$(awk -F= '$1=="window"{print substr($0,8)}' "$LAB/state/$ID.meta")
  for i in $(seq 1 75); do
    tmux -S "$SOCK" capture-pane -p -t "$BASE_WINDOW" > "$E/baseline-$H.txt"
    grep -qi 'Trust project folder' "$E/baseline-$H.txt" && break
    sleep .2
  done
  grep -qi 'Trust project folder' "$E/baseline-$H.txt"
  tmux -S "$SOCK" capture-pane -e -p -t "$BASE_WINDOW" > "$E/baseline-$H.ansi"
  tmux -S "$SOCK" kill-window -t "$BASE_WINDOW"
  rm -f "$LAB/state/$ID.meta"
  git -C "$ROOT" show HEAD:bin/fm-spawn.sh > "$P/bin/fm-spawn.sh"
  printf '%s\n' "$H" > "$LAB/config/secondmate-harness"
  "$P/bin/fm-spawn.sh" "$ID" "$M" --secondmate > "$E/spawn-$H.txt" 2>&1
  cat "$E/spawn-$H.txt"
  WINDOW=$(awk -F= '$1=="window"{print substr($0,8)}' "$LAB/state/$ID.meta")
  for i in $(seq 1 75); do
    tmux -S "$SOCK" capture-pane -p -t "$WINDOW" > "$E/launched-$H.txt"
    grep -qiE 'No models available|No API key|escape interrupt|TRUST_LAUNCH_READY|Error:' "$E/launched-$H.txt" && break
    sleep .2
  done
  ! grep -qi 'Trust project folder' "$E/launched-$H.txt"
  grep -qiE 'No models available|No API key|escape interrupt|TRUST_LAUNCH_READY|Error:' "$E/launched-$H.txt"
  tmux -S "$SOCK" capture-pane -e -p -t "$WINDOW" > "$E/launched-$H.ansi"
  cat "$E/launched-$H.txt"
  cat "$D/pi-agent/trust.json" > "$E/trust-after-$H.json"
  python3 - "$D/pi-agent/trust.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1])) == {}, 'session approval must not persist trust'
PY
  cp "$LAB/state/$ID.meta" "$E/metadata-$H.txt"
  tmux -S "$SOCK" kill-window -t "$WINDOW"
done
# An arbitrary unseeded path must refuse before adding an endpoint.
U="$D/mate-pi"
rm "$U/.fm-secondmate-home"
BEFORE=$(tmux -S "$SOCK" list-windows -t lab | wc -l)
if "$P/bin/fm-spawn.sh" unseeded-lab "$U" --secondmate > "$E/unseeded-refusal.txt" 2>&1; then exit 1; fi
grep -q 'not a seeded secondmate home' "$E/unseeded-refusal.txt"
AFTER=$(tmux -S "$SOCK" list-windows -t lab | wc -l)
[ "$BEFORE" = "$AFTER" ]
cat "$E/unseeded-refusal.txt"
printf 'Unseeded refusal kept endpoint count unchanged: %s\n' "$AFTER"
