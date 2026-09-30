#!/usr/bin/env bash
# fm-sleep-lib.sh - the single owner of the no-fork poll wait.
#
# Sourced, never executed.
#
#   fm_sleep <seconds>
#
# fm_sleep is a drop-in for `sleep <seconds>` inside Firstmate's polling and
# retry loops that does not fork a process per call. Every pause used to exec
# an external /bin/sleep, and on macOS each exec also crosses syspolicyd and
# XProtect evaluation, so the fleet's steady-state watchers alone produced a
# process-creation rate in the thousands per second under test load. The wait
# itself costs a few syscalls: `read -t` against a descriptor that can never
# deliver input.
#
# SIGNAL OPT-IN. `read -t` is used only in a process that names
# FM_SLEEP_SIGPREFIX and arms flag-file traps for its stop signals
# (`trap ': >"$FM_SLEEP_SIGPREFIX.term"' TERM`, likewise .int/.hup/.quit):
# a fatal signal interrupting read -t re-raises through kill_shell, which
# this bash build can fault, and an 'exit' inside a handler takes the same
# path. The flag survives even a trap fired inside a command substitution
# subshell, and fm_sleep_signal_check exits through the ordinary path with
# the matching 128+sig status (overridable per signal via
# FM_SLEEP_SIGEXIT_<sig>). A process without the prefix keeps external sleep,
# so library code is safe under every caller disposition.
#
# MECHANISM. A private FIFO at FM_SLEEP_FIFO (default
# ${TMPDIR:-/tmp}/fm-sleep.<uid>.fifo) is opened O_RDWR, which makes its read
# side never readable and never at end-of-file, so `read -t` blocks for the
# requested time and nothing else. The descriptor is opened and closed inside
# each call, so no descriptor is ever held across a child spawn - bash marks
# no ordinary descriptor close-on-exec, and leaking one into every child is
# not acceptable. The FIFO is shared per user and lazily created; every
# anomaly (missing path, foreign file, unavailable descriptor, a shell that
# rejects the requested precision) falls back to external sleep rather than
# failing or shortening the wait. A stray same-user write to the FIFO ends a
# wait early exactly like a signal ends sleep early; nothing in this repo
# writes to it, and the file is user-private by creation.
#
# BASH SUPPORT. Integer waits run fork-free on every supported Bash,
# including stock macOS Bash 3.2. Fractional waits need a shell whose
# `read -t` accepts a decimal timeout; the first fractional call per process
# probes that once, and on a refusal (stock 3.2 accepts only integers) the
# call takes the sanctioned external-sleep fallback instead of rounding the
# interval, which would change the caller's timing contract.
#
# SET -U / SET -E SAFE. Every global is read with a default, and the
# timing-out `read` - whose nonzero status is the normal path - is always
# consumed, so a caller under `set -e` waits exactly as it did with `sleep`.
# The no-fork path returns 0; the fallback path propagates external sleep's
# own status, so `sleep` and `fm_sleep` stay interchangeable in `&&`, `||`,
# and errexit contexts.
#
# Per-process state, none exported:
#   _FM_SLEEP_FRAC   '' unprobed, 1 fractions accepted, 0 integers only
#   _FM_SLEEP_FD     descriptor number bound for the current wait

# Source-idempotent: backend adapters source this file lazily at dispatch time,
# so without a guard a late `. fm-sleep-lib.sh` would redefine fm_sleep over an
# override a caller deliberately installed (tests rely on this) and reset the
# per-process probe state.
if [ -n "${_FM_SLEEP_LIB_SOURCED:-}" ]; then
  return 0
fi
_FM_SLEEP_LIB_SOURCED=1

# The wait descriptor is held only for the duration of one read, but it must
# still come from outside the low numbers callers reserve (this repo uses at
# most fd 9). Bash >= 4.1 auto-allocates a free descriptor >= 10 via {var},
# which is collision-proof. Older shells - including stock 3.2, which parses
# the {var} token but cannot execute it - use fixed fd 42, and only after
# proving it closed so an occupied descriptor forces the external fallback
# rather than being silently retargeted mid-call.
if [ -z "${FM_SLEEP_FIXED_FD:-}" ] && { [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 1 ]; }; }; then
  _fm_sleep_open() {
    # The 2>/dev/null lives on the group, not the exec: an error redirect on a
    # bare exec would permanently retarget the shell's own stderr.
    { exec {_FM_SLEEP_FD}<>"$FM_SLEEP_FIFO"; } 2>/dev/null
  }
  _fm_sleep_close() {
    exec {_FM_SLEEP_FD}<&-
  }
else
  _fm_sleep_open() {
    _fm_sleep_fd_free 42 || return 1
    { exec 42<>"$FM_SLEEP_FIFO"; } 2>/dev/null || return 1
    _FM_SLEEP_FD=42
  }
  _fm_sleep_close() {
    exec 42<&-
  }
fi

# 0 when <fd> is closed in this shell. /dev/fd is one stat on macOS and
# Linux; where it is absent the only fork-free-safe alternative is a subshell
# dup probe, paid once per call only on hosts that lack the interface.
_fm_sleep_fd_free() {
  if [ -d /dev/fd ]; then
    [ -e "/dev/fd/$1" ] && return 1
    return 0
  fi
  ( : <&"$1" ) 2>/dev/null && return 1
  return 0
}

# Create the shared never-readable FIFO once; it outlives any one caller and
# is recreated the next call if removed. rm and mkfifo fork only on this cold
# path - typically once per boot per user - and only ever inside a call that
# was already going to wait.
_fm_sleep_make_fifo() {
  rm -f -- "$FM_SLEEP_FIFO" 2>/dev/null || true
  ( umask 077; mkfifo "$FM_SLEEP_FIFO" ) 2>/dev/null || return 1
  [ -p "$FM_SLEEP_FIFO" ]
}

_fm_sleep_open_wait_target() {
  [ -n "${FM_SLEEP_FIFO:-}" ] || FM_SLEEP_FIFO="${TMPDIR:-/tmp}/fm-sleep.${UID:-0}.fifo"
  [ -p "$FM_SLEEP_FIFO" ] || _fm_sleep_make_fifo || return 1
  _fm_sleep_open
}

# Probe once whether this shell's `read -t` accepts a decimal timeout. The
# probe reads the already-open wait descriptor inside one command
# substitution, so it costs a single fork on the first fractional call per
# process and nothing after. Stock 3.2 answers "invalid timeout
# specification" instantly while capable shells just time out, so the verdict
# keys on the diagnostic text.
_fm_sleep_frac_probe() {
  local _fm_s_probe
  _fm_s_probe=$(read -r -t 0.02 -u "$_FM_SLEEP_FD" 2>&1)
  case "$_fm_s_probe" in
    *invalid*) _FM_SLEEP_FRAC=0; return 1 ;;
    *) _FM_SLEEP_FRAC=1; return 0 ;;
  esac
}

fm_sleep() {
  local _fm_s_secs=${1-}
  fm_sleep_signal_check
  # The in-shell wait is only signal-safe when this process opts in by naming
  # a flag prefix and arming flag-file traps for its stop signals; without it,
  # a fatal signal interrupting `read -t` re-raises through kill_shell, which
  # this bash build can fault. Callers that do not opt in keep external sleep.
  [ -n "${FM_SLEEP_SIGPREFIX:-}" ] || {
    command sleep "$_fm_s_secs"
    return
  }
  # Only a plain non-negative decimal can go through `read -t`; anything else
  # stays with external sleep so its validation and diagnostics are unchanged.
  case "$_fm_s_secs" in
    ''|*.*.*|*[!0-9.]*|.|*.)
      command sleep "$_fm_s_secs"
      return
      ;;
  esac
  # A fractional request on a shell already proven integer-only short-
  # circuits to the fallback without opening anything.
  case "$_fm_s_secs" in
    *.*)
      case "${_FM_SLEEP_FRAC:-}" in
        0)
          command sleep "$_fm_s_secs"
          return
          ;;
      esac
      ;;
  esac
  _fm_sleep_open_wait_target || {
    command sleep "$_fm_s_secs"
    return
  }
  case "$_fm_s_secs" in
    *.*)
      _fm_sleep_frac_probe || {
        _fm_sleep_close
        command sleep "$_fm_s_secs"
        return
      }
      ;;
  esac
  read -r -t "$_fm_s_secs" -u "$_FM_SLEEP_FD" 2>/dev/null || :
  _fm_sleep_close
  fm_sleep_signal_check
  return 0
}

# Callers that must not die inside the wait point FM_SLEEP_SIGPREFIX at a
# per-process file prefix and arm flag-file traps like
#   trap ': >"$FM_SLEEP_SIGPREFIX.term"' TERM
# for each fatal signal. The handler is a bare builtin writing a file, so it
# takes effect even when bash runs the pending trap inside a command
# substitution subshell, and this check then exits through the ordinary path
# with the conventional 128+sig status. Either `exit` inside the handler or
# the untrapped disposition can crash this bash build (kill_shell faulting
# while it re-raises a signal that interrupted read -t), so the flag +
# normal-flow exit is the only signal-safe wait shape. Signal delivery is
# still exact: the file appears the moment the signal lands, and it is
# noticed no later than the end of the wait already in flight.
# Teardown paths clear FM_SLEEP_SIGPREFIX before any cleanup that can reach
# fm_sleep, disarm the flag traps (a signal during teardown then kills
# promptly through the restored default disposition instead of dropping a
# flag under an empty prefix as a stray `.term` file), and remove the flag
# files.
fm_sleep_signal_check() {
  [ -n "${FM_SLEEP_SIGPREFIX:-}" ] || return 0
  [ -f "$FM_SLEEP_SIGPREFIX.term" ] && exit "${FM_SLEEP_SIGEXIT_term:-143}"
  [ -f "$FM_SLEEP_SIGPREFIX.int" ] && exit "${FM_SLEEP_SIGEXIT_int:-130}"
  [ -f "$FM_SLEEP_SIGPREFIX.hup" ] && exit "${FM_SLEEP_SIGEXIT_hup:-129}"
  [ -f "$FM_SLEEP_SIGPREFIX.quit" ] && exit "${FM_SLEEP_SIGEXIT_quit:-131}"
  return 0
}
