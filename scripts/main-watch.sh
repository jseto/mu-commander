#!/usr/bin/env bash
# Watch the orchestrator's own pi session and recover it from a free-provider
# failure (specs/orchestrator-stall-recovery). pi's own rendered provider error
# — the usage-limit rejection or the free-tier rejection — stops the session
# from answering, and nothing else in the pattern watches it: the child watcher
# is deliberately notify-only and sub-fallback.sh recovers a child. start-main.sh
# arms exactly ONE detached `watch` window running this script when it creates
# the session; the watcher dies with the session it watches.
#
# Strict detection: only a pane line whose trimmed text starts with "Error: "
# is a failure banner, and only that line or its wrapped continuation lines are
# matched against the shared free-provider signature. A signature quoted in
# prose, echoed by a tool, or delivered as a child's STUCK: notice can never
# trigger a recovery — the watcher never mistakes its own notification traffic
# for an incident.
#
# The watched pane is pinned to pi's WINDOW, never to the session's current
# window: `=SESS:` follows whatever window the operator has selected, so a
# session whose `watch` window is selected would have the watcher capture its
# own pane — blind to the very incidents it exists to catch, and its own quiet
# pane would keep the not-pi warning from ever clearing. `=SESS:<index>` cannot
# follow a selection — but only a VERIFIED index helps: tmux resolves a missing
# index (and `=SESS:0` on a base-index-1 server) to the session's selected
# window, so a guessed literal re-creates the blindness it was meant to remove.
# start-main.sh therefore resolves pi's window index before it arms this
# watcher and passes it as the second argument; a pin is used only when
# `#{window_index}` proves the index exists. Without a usable argument the
# index comes from the session's own window list — the first pi-like window,
# else the first listed one, never a literal — and is verified the same way.
# It is re-resolved from that list whenever the pinned pane is not pi-like, so
# a session that runs pi in another window is still followed.
#
# A pane is pi-like when its `#{pane_current_command}` is non-empty and is not a
# shell or another interactive non-TUI program: pi is a launcher symlink on
# some hosts (`pi`) and a node/bun-exec'd process on others (`node`), so an
# `== pi` test would make this watcher inert there. A shell pane is never typed
# into (warned once per incident) and the watcher keeps watching.
#
# The recovery reuses the shared sub-fallback mechanics (_sub-common.sh): the
# fallback model and thinking level come from config.json, the switch is the
# verified tmux send, the status bar is the only confirmation. A confirmed
# switch (or a session already on the fallback) then gets exactly one wake line
# per incident, because the switch alone never retries the turn the provider
# error killed. Every key it sends goes to the watched session's pane — never to
# a child, and never through sub-report.sh: the watcher never reports to itself.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} [session] [window]"; }

# Knobs — cadence and arming only, never a model id or a thinking level (those
# come from config.json, like the child's recovery):
#   MAIN_WATCH_INTERVAL        seconds between scans (default 30)
#   MAIN_WATCH_RETRY_SECONDS   retry an unfinished attempt after this (30)
#   MAIN_WATCH_REWAKE_SECONDS  re-wake an unchanged incident after this (900)
#   MAIN_WATCH_SCAN_LINES      pane lines scanned per tick (50)
#   MAIN_WATCH_TICKS           scans before exiting, 0 = unbounded (test bound)
: "${MAIN_WATCH_INTERVAL:=30}"
: "${MAIN_WATCH_RETRY_SECONDS:=30}"
: "${MAIN_WATCH_REWAKE_SECONDS:=900}"
: "${MAIN_WATCH_SCAN_LINES:=50}"
: "${MAIN_WATCH_TICKS:=0}"

# How many wrapped continuation lines after an `Error: ` banner are matched: pi
# wraps a provider error onto a few rows, and stopping at the first blank line
# or the next banner keeps the window from swallowing unrelated prose.
_MAIN_ERR_CONT_LINES=4

# Watcher state, mirroring the child services' idiom. MW_SIG is the identity of
# the incident being handled (kind plus the flattened matched error block) and
# is only recorded once an attempt completed; MW_FOUND is what the current scan
# sees.
MW_SESS='' MW_WINDOW='' MW_TARGET='' MW_SESSION_TARGET=''
MW_KIND='' MW_FOUND='' MW_SIG=''
MW_STATUS=none
MW_LAST_ATTEMPT=0
MW_WARNED_CONFIG=0 MW_WARNED_NOT_PI=0
MW_EPOCH=0 _MW_LAST_EPOCH=0
MW_SCANS=0
MW_SLEEP=0.050

# Die unless $2 is a non-negative integer; $1 is the knob name.
mw_nonneg_int() { # $1=knob-name $2=value
  [[ $2 =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer: $2"
}

# Validate the knob family once at start (the family's precedent: a bad value
# dies naming its knob, so a typo cannot turn into a spinning loop), and build
# the sleep argument — whole milliseconds floored at 50, so an interval of 0
# cannot spin a core.
mw_validate_knobs() {
  local int frac ms
  [[ $MAIN_WATCH_INTERVAL =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || die "MAIN_WATCH_INTERVAL must be a non-negative number: $MAIN_WATCH_INTERVAL"
  mw_nonneg_int MAIN_WATCH_RETRY_SECONDS "$MAIN_WATCH_RETRY_SECONDS"
  mw_nonneg_int MAIN_WATCH_REWAKE_SECONDS "$MAIN_WATCH_REWAKE_SECONDS"
  mw_nonneg_int MAIN_WATCH_SCAN_LINES "$MAIN_WATCH_SCAN_LINES"
  mw_nonneg_int MAIN_WATCH_TICKS "$MAIN_WATCH_TICKS"
  int=${MAIN_WATCH_INTERVAL%%.*}
  ms=$(( 10#$int * 1000 ))
  if [[ $MAIN_WATCH_INTERVAL == *.* ]]; then
    frac=${MAIN_WATCH_INTERVAL#*.}
    frac=${frac}000
    frac=${frac:0:3}
    ms=$(( ms + 10#$frac ))
  fi
  [ "$ms" -ge 50 ] || ms=50
  MW_SLEEP=$(printf '%d.%03d' "$(( ms / 1000 ))" "$(( ms % 1000 ))")
}

# Resolve the watched session, validate the knobs, pin the pane target to pi's
# window, and seed the state. $1 is the session name (default $MAIN_SESSION) and
# $2 the window index start-main.sh resolved before arming this watcher. The
# exact-name session forms are the ones sub-report.sh uses, so a session whose
# name merely extends this one is never addressed.
mw_init() { # [$1=session] [$2=window index]
  MW_SESS=${1:-$MAIN_SESSION}
  MW_WINDOW=${2:-}
  MW_SESSION_TARGET="=$MW_SESS"   # session target: has-session / list-windows
  mw_validate_knobs
  if [ -n "$MW_WINDOW" ] && [[ ! $MW_WINDOW =~ ^[0-9]+$ ]]; then
    usage   # a caller contract violation: never fall back on a malformed index
  fi
  mw_pin_target                   # pane target: capture-pane / send-keys
  MW_KIND='' MW_FOUND='' MW_SIG=''
  MW_STATUS=none MW_LAST_ATTEMPT=0
  MW_WARNED_CONFIG=0 MW_WARNED_NOT_PI=0
  MW_EPOCH=0 _MW_LAST_EPOCH=0 MW_SCANS=0
  info "watching the orchestrator pane of '$MW_SESS' for free-provider stalls (interval ${MAIN_WATCH_INTERVAL}s, rewake ${MAIN_WATCH_REWAKE_SECONDS}s)"
}

# True when window $1 exists in the watched session. tmux resolves a missing
# index — and `=SESS:0` on a base-index-1 server — to the session's SELECTED
# window, so the index tmux reports back is the only proof that the pin is the
# window we asked for. `display-message` succeeds either way; only the value
# tells them apart.
mw_window_exists() { # [$1=window index]
  local got
  [ -n "${1:-}" ] || return 1
  got=$(tmux display-message -p -t "=$MW_SESS:$1" '#{window_index}' 2>/dev/null || true)
  [ "$got" = "$1" ]
}

# Set the pane target to the verified window $1, or to the session-level target
# when that index does not verify. The session target is the documented last
# resort (no index could be proven to exist); an unverified index is never
# pinned, because it silently means "whatever window is selected".
mw_set_pin() { # [$1=window index]
  if mw_window_exists "${1:-}"; then
    MW_TARGET="=$MW_SESS:$1"
  else
    MW_TARGET="$MW_SESSION_TARGET:"
  fi
}

# Echo the window index to pin from the session's own window list: the first
# pi-like window, else the first listed one (never a literal — on a base-index-1
# server index 0 does not exist). Empty when the session lists no window.
mw_resolve_window() {
  local raw idx cmd first='' best=''
  raw=$(tmux list-windows -t "$MW_SESSION_TARGET" \
          -F '#{window_index} #{pane_current_command}' 2>/dev/null || true)
  while read -r idx cmd; do
    [ -n "$idx" ] || continue
    if [ -z "$first" ]; then first=$idx; fi
    if [ -z "$best" ] && mw_command_is_pi "$cmd"; then best=$idx; fi
  done <<<"$raw"
  printf '%s' "${best:-$first}"
}

# Pin the pane target to pi's *window*: `=SESS:` tracks the session's current
# window, which an operator selecting the `watch` window moves onto this script
# itself. The pinned form cannot move under a selection. The window index from
# start-main.sh is preferred, but only while it verifies; otherwise it is
# resolved from the live window list. Neither path may pin an unverified index.
mw_pin_target() {
  if mw_window_exists "$MW_WINDOW"; then
    mw_set_pin "$MW_WINDOW"
    return 0
  fi
  mw_set_pin "$(mw_resolve_window)"
}

# True while the watched session exists. The watcher stops with it.
mw_session_alive() { tmux has-session -t "$MW_SESSION_TARGET" 2>/dev/null; }

# Shells and other interactive non-TUI programs a pane may run instead of pi.
# A deny-list, not `== pi`: pi is a launcher symlink on some hosts and a
# node/bun-exec'd process on others, where `pane_current_command` is `node`.
_MW_NOT_PI_RE='^(sh|bash|zsh|fish|dash|ksh|tcsh|csh|nu|elvish|xonsh|tmux|screen)$'

# True when a pane command is pi-like: non-empty and not on the deny-list
# (case-insensitive), so every other command counts as pi.
mw_command_is_pi() { # $1=pane_current_command
  local cmd=${1,,}
  [ -n "$cmd" ] || return 1
  [[ ! $cmd =~ $_MW_NOT_PI_RE ]]
}

# True when the pinned window's pane is pi-like (the probe lavish_wake_child
# uses, widened for the installs where pi is not literally `pi`). A pane running
# a shell is never typed into — the watcher keeps watching instead of exiting,
# because pi may still come back.
mw_pane_is_pi() {
  local cmd
  cmd=$(tmux display-message -p -t "$MW_TARGET" '#{pane_current_command}' 2>/dev/null || true)
  mw_command_is_pi "$cmd"
}

# Re-pin from the same resolver once and report whether that pane is pi-like.
# Called before each scan, so a session that runs pi in another window is
# followed rather than watched through a stale pin. MW_WARNED_NOT_PI is never
# touched here: a re-pin that finds no pi-like window must not turn into one
# warning per scan.
mw_follow_pi_pane() {
  mw_pane_is_pi && return 0
  mw_set_pin "$(mw_resolve_window)"
  mw_pane_is_pi
}

# True when a pane line is pi's own error banner: its leading-whitespace
# trimmed text starts with "Error: " (the trim idiom _pi_pending_row uses).
# This is the whole of the strict rule — a signature on any other line is
# analysis prose, tool output, or a delivered child notice, never a failure.
mw_is_banner() { # $1=pane line
  local s=${1#"${1%%[![:space:]]*}"}
  [[ $s == 'Error: '* ]]
}

# True when a line carries one entry of the shared free-provider signature.
# Each candidate line is matched on its own, so the vocabulary keeps its
# documented line-scoped meaning.
mw_line_matches() { # $1=pane line
  grep -qE -- "$_FALLBACK_ERROR_RE" <<<"$1"
}

# Echo the failure kind of an error block, classified the way the child stall
# service does, so the incident identity is stable across scans.
mw_kind_of() { # $1=error block
  if grep -qF -- 'FreeUsageLimitError' <<<"$1"; then
    printf 'FreeUsageLimitError'
  elif grep -qF -- 'FreeTierError' <<<"$1"; then
    printf 'FreeTierError'
  else
    printf 'HTTP 429 rate limit'
  fi
}

# Set MW_KIND and MW_FOUND for the failure pi itself rendered in the pane, or
# clear them when there is none. Scans the bounded tail only (the scrollback of
# a long session is not evidence); for each banner, matches the banner and then
# up to _MAIN_ERR_CONT_LINES of its continuation lines, stopping at a blank line
# or at the next banner. The first hit fixes the incident identity: the kind
# plus the flattened matched block, so a cleared and re-shown failure is a new
# incident while a redraw of the same one is not.
mw_scan_strict() {
  local -a L=()
  local i j n block hit
  MW_KIND='' MW_FOUND=''
  mapfile -t L < <(pane_tail_in "$MW_TARGET" "$MAIN_WATCH_SCAN_LINES")
  n=${#L[@]}
  for (( i = 0; i < n; i++ )); do
    mw_is_banner "${L[i]}" || continue
    block=${L[i]}
    hit=0
    if mw_line_matches "${L[i]}"; then
      hit=1
    else
      for (( j = i + 1; j < n && j <= i + _MAIN_ERR_CONT_LINES; j++ )); do
        if [ -z "${L[j]//[[:space:]]/}" ]; then break; fi   # blank line ends it
        if mw_is_banner "${L[j]}"; then break; fi           # a banner ends it
        block+=" ${L[j]}"
        if mw_line_matches "${L[j]}"; then hit=1; break; fi
      done
    fi
    if [ "$hit" = 1 ]; then
      MW_KIND=$(mw_kind_of "$block")
      MW_FOUND="$MW_KIND|$(_flatten "$block")"
      return 0
    fi
  done
  return 0
}

# Fresh epoch for one wake attempt: strictly increasing even when two attempts
# fall in the same second (the pr-watch/stall-watch rule), so the wake line is
# unique per attempt — tmux_send_line refuses to trust a probe that is already
# visible in the pane, and a re-wake must not reuse the earlier text.
mw_new_epoch() {
  local e
  e=$(date +%s)
  if [ "$e" -le "$_MW_LAST_EPOCH" ]; then e=$((_MW_LAST_EPOCH + 1)); fi
  _MW_LAST_EPOCH=$e
  MW_EPOCH=$e
}

# The one wake line: it tells the orchestrator to resume the interrupted turn
# without repeating finished work, and carries a unique marker so a wake is
# confirmed as THIS copy. One physical line, naming no model and no level.
mw_compose_wake() {
  printf 'Resume the interrupted turn: the free-provider failure that stopped it is recovered. Do not repeat work already done — continue from where the turn stopped. [main-watch %s]' "$MW_EPOCH"
}

# Type the wake line into the watched pane through the shared verified send: 0
# only when the submission was confirmed, never assumed.
mw_wake() { tmux_send_line "$MW_TARGET" "$(mw_compose_wake)"; }

# One recovery attempt for the visible incident: resolve the configured
# fallback pair and let the shared mechanics switch, confirm and think, then
# translate the outcome into MW_STATUS plus the operator message. MW_SIG is
# recorded only by the caller, once the attempt completed.
mw_recover() {
  local model thinking rc=0
  model=$(resolve_fallback_model)
  thinking=$(resolve_fallback_thinking)
  free_provider_recover "$MW_TARGET" "$model" "$thinking" "$MAIN_WATCH_SCAN_LINES" || rc=$?
  case $rc in
    0)
      MW_STATUS=switched ;;
    2|4)
      # The switch was confirmed (the shared call returns these only after
      # that), so the incident is recovered and only the level is a config
      # problem: report it, never claim the level was set.
      MW_STATUS=switched
      warn "$(free_provider_failure_message "$rc" "$MW_TARGET" "$model" session "$thinking")" ;;
    5)
      MW_STATUS=already_on ;;
    3)
      # A config problem is never fatal here: warn once per incident, nothing
      # was sent, and the watcher keeps watching.
      MW_STATUS=no_fallback
      if [ "$MW_WARNED_CONFIG" = 0 ]; then
        warn "$(free_provider_failure_message 3 "$MW_TARGET" "$model")"
        MW_WARNED_CONFIG=1
      fi ;;
    *)
      MW_STATUS=unconfirmed
      warn "$(free_provider_failure_message 1 "$MW_TARGET" "$model" session)" ;;
  esac
  return 0
}

# One verified wake for the incident, recorded only when the send was
# confirmed. An unconfirmed wake is never claimed: the incident stays due, so
# the retry interval governs and the next attempt finds the fallback already in
# place and wakes again — never a second /model.
mw_attempt_wake() {
  mw_new_epoch
  if mw_wake; then
    MW_SIG=$MW_FOUND
  else
    MW_SIG=''
    MW_STATUS=none
  fi
  return 0
}

# One scan: detect, reset on a clean pane, apply the due rule, then recover or
# (for an already-recovered incident) wake only.
mw_tick() {
  local now due same=0
  # Follow pi's window before capturing, so a pin that no longer points at pi
  # never makes the scan blind to the session's real pane.
  mw_follow_pi_pane || true
  mw_scan_strict
  if [ -z "$MW_KIND" ]; then
    # No error render in the pane: the incident is over, so pi's next failure
    # is a new one, and the warn-once flags start over.
    MW_SIG='' MW_STATUS=none MW_LAST_ATTEMPT=0
    MW_WARNED_CONFIG=0 MW_WARNED_NOT_PI=0
    return 0
  fi
  now=$(date +%s)
  if [ "$MW_FOUND" = "$MW_SIG" ]; then same=1; fi
  due=0
  # An incident that was already recovered gets a re-wake only, and only after
  # the rewake interval. Anything else — a new incident, or one whose attempt
  # never completed — retries on the retry interval. `same` is load-bearing:
  # a stale `switched`/`already_on` from an earlier incident must never turn a
  # new one into a wake-only (its model would never be switched), which is
  # exactly what an identity-blind check on MW_STATUS alone would do.
  if [ "$same" = 1 ] && { [ "$MW_STATUS" = switched ] || [ "$MW_STATUS" = already_on ]; }; then
    if [ $(( now - MW_LAST_ATTEMPT )) -ge "$MAIN_WATCH_REWAKE_SECONDS" ]; then due=1; fi
  else
    if [ $(( now - MW_LAST_ATTEMPT )) -ge "$MAIN_WATCH_RETRY_SECONDS" ]; then due=1; fi
  fi
  [ "$due" = 1 ] || return 0
  # Nothing is typed into a pane that is not running pi: keep watching, and say
  # so once per incident.
  if ! mw_pane_is_pi; then
    if [ "$MW_WARNED_NOT_PI" = 0 ]; then
      warn "the pane of '$MW_SESS' is not running pi; leaving it alone — the watcher keeps watching"
      MW_WARNED_NOT_PI=1
    fi
    return 0
  fi
  MW_LAST_ATTEMPT=$now
  if [ "$same" = 1 ] && { [ "$MW_STATUS" = switched ] || [ "$MW_STATUS" = already_on ]; }; then
    # Already on the fallback (or switched by an earlier attempt for THIS
    # incident): the visible failure needs the wake only, never another /model.
    mw_attempt_wake
    return 0
  fi
  mw_recover
  case $MW_STATUS in
    switched|already_on) mw_attempt_wake ;;
  esac
  return 0
}

# The single-clock loop. A recovery attempt blocks the loop for its status-bar
# poll, so scans never overlap and never pile up; a session that goes away ends
# the watcher (it dies with the session it watches), and MAIN_WATCH_TICKS > 0
# bounds the number of scans.
mw_loop() {
  while :; do
    if ! mw_session_alive; then
      info "watched session '$MW_SESS' is not running; watch stopped"
      return 0
    fi
    if [ "$MAIN_WATCH_TICKS" -gt 0 ] && [ "$MW_SCANS" -ge "$MAIN_WATCH_TICKS" ]; then
      return 0
    fi
    mw_tick
    MW_SCANS=$((MW_SCANS + 1))
    sleep "$MW_SLEEP"
  done
}

main() {
  if [ "$#" -gt 2 ]; then usage; fi
  need tmux jq
  mw_init "${1:-}" "${2:-}"
  mw_loop
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
