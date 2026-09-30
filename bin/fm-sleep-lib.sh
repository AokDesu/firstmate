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
# SIGNAL OPT-IN. `read -t` is used only in the process that armed it with
# fm_sleep_arm <prefix>, which names FM_SLEEP_SIGPREFIX and installs flag-file
# traps for HUP, TERM, INT and QUIT: a fatal signal interrupting read -t
# re-raises through kill_shell, which this bash build can fault, and an
# 'exit' inside a handler takes the same path. The flag survives even a trap
# fired inside a command substitution subshell, and fm_sleep_signal_check
# exits through the ordinary path with the matching 128+sig status
# (overridable per signal via FM_SLEEP_SIGEXIT_<sig>). The opt-in is bound to
# the arming shell's BASH_SUBSHELL level: a subshell, background job or
# command substitution inherits the prefix but not the caught traps, so it
# keeps external sleep unless it arms again itself. A process that never
# arms keeps external sleep, so library code is safe under every caller
# disposition.
#
# MECHANISM. A private FIFO at FM_SLEEP_FIFO (default
# ${TMPDIR:-/tmp}/fm-sleep.<uid>.fifo) is opened O_RDWR, which makes its read
# side never readable and never at end-of-file, so `read -t` blocks for the
# requested time and nothing else. The descriptor is opened and closed inside
# each call, so no descriptor is ever held across a child spawn - bash marks
# no ordinary descriptor close-on-exec, and leaking one into every child is
# not acceptable. The FIFO is shared per user and lazily created; every
# anomaly (a path held by anything but a FIFO, a FIFO another user owns or
# can open, an uncreatable path, an unavailable descriptor, a shell that
# rejects the requested precision) falls back to external sleep rather than
# failing, shortening the wait, or touching the foreign file. A stray
# same-user write to the FIFO ends a wait early exactly like a signal ends
# sleep early; nothing in this repo writes to it, and the file is
# user-private by creation.
#
# BASH SUPPORT. Integer waits run fork-free on every supported Bash,
# including stock macOS Bash 3.2. Fractional waits need a shell whose
# `read -t` accepts a decimal timeout; the first fractional call per process
# probes that once, in-shell against the wait descriptor, and caches the
# verdict either way. On a refusal (stock 3.2 accepts only integers) the call
# takes the sanctioned external-sleep fallback instead of rounding the
# interval, which would change the caller's timing contract.
#
# SET -U / SET -E SAFE. Every global is read with a default, and the
# timing-out `read` - whose nonzero status is the normal path - is always
# consumed, so a caller under `set -e` waits exactly as it did with `sleep`.
# The no-fork path returns 0; the fallback path propagates external sleep's
# own status, so `sleep` and `fm_sleep` stay interchangeable in `&&`, `||`,
# and errexit contexts. Both paths check the stop flags after the wait.
#
# Per-process state, none exported:
#   _FM_SLEEP_FRAC       '' unprobed, 1 fractions accepted, 0 integers only
#   _FM_SLEEP_FIFO_SEEN  "ok|bad <path>": the wait FIFO's privacy verdict
#   _FM_SLEEP_FD         descriptor number bound for the current wait
#   _FM_SLEEP_ARMED_AT   BASH_SUBSHELL level fm_sleep_arm ran at, '' unarmed

# Source-idempotent: backend adapters source this file lazily at dispatch time,
# so without a guard a late `. fm-sleep-lib.sh` would redefine fm_sleep over an
# override a caller deliberately installed (tests rely on this) and reset the
# per-process state.
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
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 1 ]; }; then
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
_FM_SLEEP_FRAC=
_FM_SLEEP_FIFO_SEEN=
_FM_SLEEP_ARMED_AT=

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
# is recreated the next call if removed. mkfifo forks only on this cold path -
# typically once per boot per user - and only ever inside a call that was
# already going to wait. It never replaces an existing path: only a FIFO
# this user owns and no one else can open is used, and anything else falls
# back to external sleep. A FIFO this process did not create has its mode
# read once, before any descriptor is open, and the verdict is kept.
_fm_sleep_open_wait_target() {
  local _fm_s_fifo
  [ -n "${FM_SLEEP_FIFO:-}" ] || FM_SLEEP_FIFO="${TMPDIR:-/tmp}/fm-sleep.${UID:-0}.fifo"
  _fm_s_fifo=$FM_SLEEP_FIFO
  if [ ! -p "$_fm_s_fifo" ] && ( umask 077; mkfifo "$_fm_s_fifo" ) 2>/dev/null; then
    _FM_SLEEP_FIFO_SEEN="ok $_fm_s_fifo"
  fi
  [ -p "$_fm_s_fifo" ] && [ -O "$_fm_s_fifo" ] || return 1
  case "${_FM_SLEEP_FIFO_SEEN:-}" in
    "ok $_fm_s_fifo") ;;
    "bad $_fm_s_fifo") return 1 ;;
    *)
      case $(ls -ld -- "$_fm_s_fifo" 2>/dev/null) in
        prw-------[\ @.]*) _FM_SLEEP_FIFO_SEEN="ok $_fm_s_fifo" ;;
        *) _FM_SLEEP_FIFO_SEEN="bad $_fm_s_fifo"; return 1 ;;
      esac
      ;;
  esac
  _fm_sleep_open
}

# Probe once per process, on the first fractional call and against the
# already-open wait descriptor, whether `read -t` accepts a decimal timeout. A
# capable shell times out with a status above 128; stock 3.2 rejects the
# timeout at once with status 1, the same status its own integer timeouts
# return, so only the capable verdict is positive evidence.
_fm_sleep_frac_probe() {
  local _fm_s_rc=0
  read -r -t 0.001 -u "$_FM_SLEEP_FD" 2>/dev/null || _fm_s_rc=$?
  if [ "$_fm_s_rc" -gt 128 ]; then
    _FM_SLEEP_FRAC=1
  else
    _FM_SLEEP_FRAC=0
  fi
}

# Wait <seconds> in-shell and return 0, or return 1 without waiting when this
# call must take external sleep: the process has not armed at this subshell
# level, the argument is not a plain non-negative decimal (external sleep
# keeps its own validation and diagnostics), the shell cannot honor a
# fraction, or the FIFO or a descriptor is unavailable.
_fm_sleep_in_shell() {
  [ -n "${FM_SLEEP_SIGPREFIX:-}" ] && [ "${_FM_SLEEP_ARMED_AT:-}" = "$BASH_SUBSHELL" ] || return 1
  case "$1" in
    ''|*.*.*|*[!0-9.]*|.|*.) return 1 ;;
    *.*) [ "${_FM_SLEEP_FRAC:-}" != 0 ] || return 1 ;;
  esac
  _fm_sleep_open_wait_target || return 1
  case "$1" in
    *.*)
      [ -n "${_FM_SLEEP_FRAC:-}" ] || _fm_sleep_frac_probe
      [ "$_FM_SLEEP_FRAC" = 1 ] || { _fm_sleep_close; return 1; }
      ;;
  esac
  read -r -t "$1" -u "$_FM_SLEEP_FD" 2>/dev/null || :
  _fm_sleep_close
}

fm_sleep() {
  local _fm_s_rc=0
  fm_sleep_signal_check
  if ! _fm_sleep_in_shell "${1-}"; then
    sleep "${1-}" || _fm_s_rc=$?
  fi
  fm_sleep_signal_check
  return "$_fm_s_rc"
}

# fm_sleep_arm <prefix>: opt this shell into the in-shell wait. Stale flags
# under <prefix> (a recycled pid's leftovers) are swept first.
fm_sleep_arm() {
  FM_SLEEP_SIGPREFIX=$1
  _FM_SLEEP_ARMED_AT=$BASH_SUBSHELL
  rm -f "$FM_SLEEP_SIGPREFIX".* 2>/dev/null || true
  fm_sleep_trap_flags
}

# Re-install the flag-file traps after a window that temporarily replaced
# them, keeping the prefix and any flag already raised.
fm_sleep_trap_flags() {
  trap ': >"$FM_SLEEP_SIGPREFIX.hup"' HUP
  trap ': >"$FM_SLEEP_SIGPREFIX.term"' TERM
  trap ': >"$FM_SLEEP_SIGPREFIX.int"' INT
  trap ': >"$FM_SLEEP_SIGPREFIX.quit"' QUIT
}

# fm_sleep_disarm: the teardown half. The prefix is cleared before any
# cleanup that can reach fm_sleep, so a flag left by the signal that ended
# the wait does not re-exit the teardown; the traps are restored to the
# default so a late signal kills promptly instead of dropping a flag under an
# empty prefix as a stray `.term` file; and the flag files are removed.
fm_sleep_disarm() {
  local _fm_s_prefix=${FM_SLEEP_SIGPREFIX:-}
  FM_SLEEP_SIGPREFIX=
  _FM_SLEEP_ARMED_AT=
  trap - HUP TERM INT QUIT
  [ -z "$_fm_s_prefix" ] || rm -f "$_fm_s_prefix".* 2>/dev/null || true
}

# The traps fm_sleep_arm installs are a bare builtin writing a file, so they
# take effect even when bash runs the pending trap inside a command
# substitution subshell, and this check then exits through the ordinary path
# with the conventional 128+sig status. Either `exit` inside the handler or
# the untrapped disposition can crash this bash build (kill_shell faulting
# while it re-raises a signal that interrupted read -t), so the flag +
# normal-flow exit is the only signal-safe wait shape. Signal delivery is
# still exact: the file appears the moment the signal lands, and it is
# noticed no later than the end of the wait already in flight.
fm_sleep_signal_check() {
  [ -n "${FM_SLEEP_SIGPREFIX:-}" ] || return 0
  [ -f "$FM_SLEEP_SIGPREFIX.term" ] && exit "${FM_SLEEP_SIGEXIT_term:-143}"
  [ -f "$FM_SLEEP_SIGPREFIX.int" ] && exit "${FM_SLEEP_SIGEXIT_int:-130}"
  [ -f "$FM_SLEEP_SIGPREFIX.hup" ] && exit "${FM_SLEEP_SIGEXIT_hup:-129}"
  [ -f "$FM_SLEEP_SIGPREFIX.quit" ] && exit "${FM_SLEEP_SIGEXIT_quit:-131}"
  return 0
}
