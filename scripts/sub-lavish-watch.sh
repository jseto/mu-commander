#!/usr/bin/env bash
# Wake a child when Lavish feedback is queued for one of its artifacts.
#
# Children open Lavish review artifacts and go idle; browser feedback then
# stays queued on the Lavish server (`pending_prompts` in its state file)
# until a poll consumes it. This watcher never runs `lavish-axi poll` and
# never consumes feedback: it scans the state file read-only for sessions
# whose artifact lives under the child's leased worktree and whose queued
# prompts are pending, then wakes the child through the shared verified tmux
# send so the child can drain the queue itself. Wakes are deduplicated per
# queued batch and retried when the send cannot be confirmed; the watcher
# exits when the child's tmux session goes away (retirement kills it).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir]"; }

# Read-only scan of the Lavish state: the queued-prompt sessions whose
# artifact lives under the child's worktree and that were last updated at or
# after `since` (the watcher's start minus a margin, so sessions left open by
# a previous user of a pooled worktree are ignored). Emits a compact JSON
# array; a missing/unreadable/reshaped state is treated as empty by the
# caller, never as an error.
lavish_pending_sessions() { # $1=state-file $2=worktree-prefix $3=since
  local state=$1 prefix=$2 since=$3
  [ -f "$state" ] || { printf '[]'; return 0; }
  jq -c --arg prefix "$prefix" --arg since "$since" '
    [ (.sessions // {}) | to_entries[]
      | select(.value.status != "ended")
      | select((.value.pending_prompts // 0) > 0)
      | select((.value.updated_at // "") >= $since)
      | select((.value.file // "") | startswith($prefix))
      | { key: .key, file: .value.file,
          count: (.value.pending_prompts // 0),
          prompts: (.value.prompts // []) }
    ]' "$state" 2>/dev/null
}

# One-line instruction for the child, from the pending-session JSON on stdin.
# The batch epoch keeps every wake text unique: tmux_send_line refuses a
# send whose probe is already visible in the transcript, so a re-wake of the
# same queued batch must not reuse the earlier line verbatim.
compose_wake_message() {
  local list
  list=$(jq -r '
    [ .[] | "\(.file) (\(.count) \(if .count == 1 then "prompt" else "prompts" end))" ]
    | join(", ")' 2>/dev/null) || list=""
  printf 'Lavish feedback queued: %s. Run "lavish-axi poll <file>" for each artifact, apply and reply to the feedback, then keep polling as usual. [auto-wake lavish-watch %s]' "$list" "$(date +%s)"
}

# Wake the child for the pending JSON in $3. Returns 0 only when the
# verified send (type, Enter, confirm in the transcript) succeeded; a pane
# that is not running pi is never typed into.
wake_child() { # $1=task $2=tmux session $3=pending JSON
  local task=$1 sess=$2 pending=$3 msg pane_cmd
  pane_cmd=$(tmux display-message -p -t "$sess" '#{pane_current_command}' 2>/dev/null || true)
  if [ "$pane_cmd" != pi ]; then
    warn "child pane in '$sess' is not running pi (pane command: ${pane_cmd:-unknown}); not waking"
    return 1
  fi
  msg=$(compose_wake_message <<<"$pending")
  if ! "$SCRIPT_DIR/sub-send.sh" "$task" "$msg" >/dev/null; then
    warn "could not confirm the Lavish wake for '$task'; will retry"
    return 1
  fi
  info "woke '$task' for Lavish feedback: $msg"
  return 0
}

main() {
  need git tmux treehouse jq
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then usage; fi

  local task=$1 repo=${2:-$PWD}
  valid_task "$task" || usage
  local root sess wt
  root=$(repo_root "$repo")
  sess=$(session_of "$task")
  wt=$(wt_for_task "$task" "$root")
  [ -n "$wt" ] || die "no worktree leased for '$task' (in $root)"

  local state_dir=${LAVISH_AXI_STATE_DIR:-${HOME:-}/.lavish-axi}
  local state=$state_dir/state.json
  local interval=${LAVISH_WATCH_INTERVAL:-2}
  local retry=${LAVISH_WATCH_RETRY_SECONDS:-5}
  local rewake=${LAVISH_WATCH_REWAKE_SECONDS:-60}
  local max_ticks=${LAVISH_WATCH_TICKS:-0}
  local since
  since=$(date -u -d "@$(( $(date +%s) - ${LAVISH_WATCH_START_MARGIN:-60} ))" +%Y-%m-%dT%H:%M:%SZ)

  info "watching Lavish feedback for '$task' in $state (worktree $wt)"

  local pending='[]' last_sig='' last_attempt=0 ticks=0 warned_state=0
  local now sig due read_ok
  while :; do
    if ! tmux has-session -t "$sess" 2>/dev/null; then
      info "child session '$sess' is not running; watcher stopping"
      return 0
    fi

    # A failed read must not look like "the queue drained": keep the dedupe
    # state so a transiently unreadable state file cannot re-wake a batch.
    read_ok=1
    if ! pending=$(lavish_pending_sessions "$state" "$wt/" "$since"); then
      read_ok=0
      if [ "$warned_state" = 0 ]; then
        warn "cannot read Lavish state at $state; skipping this scan and retrying"
        warned_state=1
      fi
    else
      warned_state=0
    fi

    if [ "$read_ok" = 0 ]; then
      : # no decision this scan
    elif [ "$pending" = '[]' ]; then
      last_sig=''
      last_attempt=0
    else
      sig=$pending
      now=$(date +%s)
      due=0
      if [ "$sig" != "$last_sig" ]; then
        if [ $(( now - last_attempt )) -ge "$retry" ]; then due=1; fi
      else
        if [ $(( now - last_attempt )) -ge "$rewake" ]; then due=1; fi
      fi
      if [ "$due" = 1 ]; then
        last_attempt=$now
        if wake_child "$task" "$sess" "$pending"; then
          last_sig=$sig
        fi
      fi
    fi

    ticks=$((ticks + 1))
    if [ "$max_ticks" -gt 0 ] && [ "$ticks" -ge "$max_ticks" ]; then
      return 0
    fi
    sleep "$interval"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
