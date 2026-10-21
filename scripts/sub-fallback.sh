#!/usr/bin/env bash
# Recover a CHILD stuck on a free-provider failure: the usage limit
# (FreeUsageLimitError / HTTP 429) or the free-tier rejection that blocks
# pi's compaction calls (FreeTierError / HTTP 403). Switches the running
# child's pi TUI to the fallback model from config.json
# (taskLevels.fallbackModel) through the shared verified send, and confirms
# the switch in the child's status bar.
#
# The switch/confirm/thinking mechanics live in _sub-common.sh
# (free_provider_recover) because the orchestrator watcher applies the same
# rules to the main session; this helper keeps the child's policy: only a
# child session, only on a visible failure, and the messages/exit codes below.
#
# Never speculative: the child's pane must already show the provider
# failure, and the child must not already be on the fallback model — the
# status-bar probe matches the model id as a delimited token, so an id that
# merely
# extends it (the free "…-free" variant of the fallback id) is not "already
# on". No error (or no configured fallback) means no switch is sent.
#
# The model switch is the recovery. A fallbackThinking the model does not
# accept is pi's 'Error: Unknown thinking level' answer: it degrades to a
# config-problem warning (exit 0) instead of failing the recovered child or
# loop-nudging a command the TUI will never take.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name>"; }

need tmux jq
[ "$#" -eq 1 ] || usage
TASK=$1
valid_task "$TASK" || usage
SESS=$(session_of "$TASK")

# Pane window searched for the error, and the status-bar poll after a switch
# (attempts × delay). The overrides exist mainly so tests need not wait.
: "${FALLBACK_SCAN_LINES:=50}"
: "${FALLBACK_PROBE_ATTEMPTS:=10}"
: "${FALLBACK_PROBE_DELAY:=0.5}"
: "${FALLBACK_SEND_ATTEMPTS:=4}"   # extra Enter nudges after the verified send

tmux has-session -t "$SESS" 2>/dev/null \
  || die "child session '$SESS' is not running"

# Detect first: a switch is only ever sent once the pane shows the provider
# failure, so a healthy child is never moved off its model.
if ! pane_has_free_limit_error "$TASK" "$FALLBACK_SCAN_LINES"; then
  info "no free-provider failure (FreeUsageLimitError/429, FreeTierError/403) in $SESS — no model switch performed"
  exit 0
fi

# The mechanics (already-on no-op, verified /model, status-bar confirmation,
# then /thinking) are shared with the orchestrator watcher; this file owns what
# an outcome means for the child: an unconfirmed switch is a loud failure, a
# rejected or unconfirmed /thinking a warning, and the model switch alone is
# always the recovery.
MODEL=$(resolve_fallback_model)
THINKING=$(resolve_fallback_thinking)
rc=0
free_provider_recover "$SESS" "$MODEL" "$THINKING" "$FALLBACK_SCAN_LINES" || rc=$?
case $rc in
  0|5) exit 0 ;;   # 5 already reported "already on fallback model …"
  2|4) warn "$(free_provider_failure_message "$rc" "$SESS" "$MODEL" child "$THINKING")" ;;
  3)   die  "$(free_provider_failure_message 3 "$SESS" "$MODEL")" ;;
  *)   die  "$(free_provider_failure_message 1 "$SESS" "$MODEL")" ;;
esac
