#!/usr/bin/env bash
set -u
helper="$PWD/bin/fm-herdr-lab.sh"
evidence=/home/symphony/.no-mistakes/evidence/01M5W4BVV35QDEMTPR1Y1SJ8PZ
if [ "${1:-}" = run ] && [ "${3:-}" = pane ] && [ "${4:-}" = read ]; then
  capture=$(mktemp "$evidence/live-pane-XXXXXX.ansi")
  "$helper" "$@" > "$capture"
  rc=$?
  printf 'capture=%s command=' "${capture##*/}" >> "$evidence/lab-commands.log"
  printf '%q ' "$@" >> "$evidence/lab-commands.log"
  printf 'rc=%s\n' "$rc" >> "$evidence/lab-commands.log"
  cat "$capture"
  exit "$rc"
fi
printf '%q ' "$@" >> "$evidence/lab-commands.log"
printf '\n' >> "$evidence/lab-commands.log"
exec "$helper" "$@"
