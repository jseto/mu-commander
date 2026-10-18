#!/usr/bin/env bash
# Shared engine and services for the per-child watcher
# (specs/unified-child-watcher/unified-child-watcher.feature).
#
# One process runs three watching services in one loop: the Lavish wake-up,
# the PR action watch, and the free-provider stall detector. The engine owns
# the child's lifetime (session and lease), the per-service scheduling, and
# the per-service tick bounds; each service owns its scan, dedupe, and
# delivery. `scripts/sub-watch.sh` selects all services; the historical
# single-service entry points (`sub-lavish-watch.sh`, `sub-pr-watch.sh`)
# select one and keep their behaviour, so their suites stay valid.
#
# Source this file; don't execute it. It expects `_sub-common.sh` to be
# sourced first (pane_tail, pane_has_free_limit_error, _FALLBACK_ERROR_RE,
# info/warn/die, repo_root, session_of, wt_for_task).
# shellcheck shell=bash

# This script's own directory: anchors the sibling helpers (sub-report.sh,
# sub-send.sh) for every wrapper. Pure parameter expansion — no external
# dirname at source time.
_SUB_WATCH_DIR=${BASH_SOURCE[0]%/*}
if [ -z "$_SUB_WATCH_DIR" ] || [ "$_SUB_WATCH_DIR" = "${BASH_SOURCE[0]}" ]; then
  _SUB_WATCH_DIR=.
fi

# Pane window searched for the free-provider signature. Deliberately the
# STALL_WATCH_* family's own knob (sub-fallback.sh's FALLBACK_SCAN_LINES is
# its separate operator surface).
: "${STALL_WATCH_SCAN_LINES:=50}"

# ---------------------------------------------------------------------------
# Engine state
# ---------------------------------------------------------------------------

W_TASK='' W_ROOT='' W_SESS='' W_WT='' W_BRANCH=''
W_SERVICES=()
W_LEASE_WARNED=0 W_TICK_DONE=0
declare -A W_INTERVAL_MS=() W_PERIOD=() W_BOUND=() W_RAN=() W_DONE=()
declare -A W_RETRY=() W_REWAKE=()

# ---------------------------------------------------------------------------
# Service knobs
# ---------------------------------------------------------------------------

# Echo the knob name for one service setting, for validation messages.
watch_service_knob() { # $1=service $2=kind
  case "$1:$2" in
    lavish:interval) printf 'LAVISH_WATCH_INTERVAL' ;;
    lavish:retry)    printf 'LAVISH_WATCH_RETRY_SECONDS' ;;
    lavish:rewake)   printf 'LAVISH_WATCH_REWAKE_SECONDS' ;;
    lavish:ticks)    printf 'LAVISH_WATCH_TICKS' ;;
    pr:interval)     printf 'PR_WATCH_INTERVAL' ;;
    pr:retry)        printf 'PR_WATCH_RETRY_SECONDS' ;;
    pr:ticks)        printf 'PR_WATCH_TICKS' ;;
    stall:interval)  printf 'STALL_WATCH_INTERVAL' ;;
    stall:retry)     printf 'STALL_WATCH_RETRY_SECONDS' ;;
    stall:rewake)    printf 'STALL_WATCH_REWAKE_SECONDS' ;;
    stall:ticks)     printf 'STALL_WATCH_TICKS' ;;
  esac
}

# Echo one service setting's configured value (its default when unset).
watch_service_value() { # $1=service $2=kind
  case "$1:$2" in
    lavish:interval) printf '%s' "${LAVISH_WATCH_INTERVAL:-2}" ;;
    lavish:retry)    printf '%s' "${LAVISH_WATCH_RETRY_SECONDS:-5}" ;;
    lavish:rewake)   printf '%s' "${LAVISH_WATCH_REWAKE_SECONDS:-60}" ;;
    lavish:ticks)    printf '%s' "${LAVISH_WATCH_TICKS:-0}" ;;
    pr:interval)     printf '%s' "${PR_WATCH_INTERVAL:-30}" ;;
    pr:retry)        printf '%s' "${PR_WATCH_RETRY_SECONDS:-5}" ;;
    pr:ticks)        printf '%s' "${PR_WATCH_TICKS:-0}" ;;
    stall:interval)  printf '%s' "${STALL_WATCH_INTERVAL:-30}" ;;
    stall:retry)     printf '%s' "${STALL_WATCH_RETRY_SECONDS:-30}" ;;
    stall:rewake)    printf '%s' "${STALL_WATCH_REWAKE_SECONDS:-900}" ;;
    stall:ticks)     printf '%s' "${STALL_WATCH_TICKS:-0}" ;;
  esac
}

# Echo a non-negative number as whole milliseconds (fractions truncate), or
# die naming the knob. Pure bash: the watcher must not gain a runtime
# dependency for its own scheduling.
watch_interval_ms() { # $1=value $2=knob-name
  local value=$1 knob=$2 int frac ms
  [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || die "$knob must be a non-negative number: $value"
  int=${value%%.*}
  ms=$(( 10#$int * 1000 ))
  if [[ $value == *.* ]]; then
    frac=${value#*.}
    frac=${frac}000
    frac=${frac:0:3}
    ms=$(( ms + 10#$frac ))
  fi
  printf '%s' "$ms"
}

# Die unless $2 is a non-negative integer; $1 is the knob name.
watch_validate_int() { # $1=knob-name $2=value
  [[ $2 =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer: $2"
}

watch_service_active() { # $1=service
  local svc
  for svc in ${W_SERVICES[@]+"${W_SERVICES[@]}"}; do
    [ "$svc" = "$1" ] && return 0
  done
  return 1
}

# True when the service has a rewake interval (re-notifying an unchanged
# incident after a long silence). The PR service has none: its notices are
# deduplicated permanently per event.
watch_service_has_rewake() { # $1=service
  case $1 in
    lavish|stall) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve and validate one service's knobs into the engine tables, then
# initialise its own state.
watch_service_init() { # $1=service
  local svc=$1 value
  value=$(watch_service_value "$svc" interval)
  W_INTERVAL_MS[$svc]=$(watch_interval_ms "$value" "$(watch_service_knob "$svc" interval)")
  value=$(watch_service_value "$svc" retry)
  watch_validate_int "$(watch_service_knob "$svc" retry)" "$value"
  W_RETRY[$svc]=$value
  if watch_service_has_rewake "$svc"; then
    value=$(watch_service_value "$svc" rewake)
    watch_validate_int "$(watch_service_knob "$svc" rewake)" "$value"
    W_REWAKE[$svc]=$value
  else
    W_REWAKE[$svc]=0
  fi
  value=$(watch_service_value "$svc" ticks)
  watch_validate_int "$(watch_service_knob "$svc" ticks)" "$value"
  W_BOUND[$svc]=$value
  W_RAN[$svc]=0
  W_DONE[$svc]=0
  case $svc in
    lavish) lavish_init ;;
    pr)     pr_init ;;
    stall)  stall_init ;;
  esac
}

# Echo the smallest configured interval among the active services.
watch_min_interval_ms() {
  local svc min='' value
  for svc in ${W_SERVICES[@]+"${W_SERVICES[@]}"}; do
    value=${W_INTERVAL_MS[$svc]}
    if [ -z "$min" ] || [ "$value" -lt "$min" ]; then min=$value; fi
  done
  printf '%s' "${min:-50}"
}

# Whole milliseconds as a `sleep` argument (`0.200`), so fractional test
# intervals and whole-second defaults share one code path.
watch_seconds() { # $1=milliseconds
  printf '%d.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"
}

# Parse SUB_WATCH_SERVICES into W_SERVICES: a comma-separated selection of
# lavish, pr, stall (default all three). Unknown names warn and are ignored;
# duplicates collapse; an empty selection leaves W_SERVICES empty and the
# engine exits without watching. The unset-vs-empty distinction is
# deliberate (`${VAR-default}`): unset means the default set, empty means
# "nothing".
watch_parse_services() {
  local raw=${SUB_WATCH_SERVICES-lavish,pr,stall} item existing known
  local -a items=()
  W_SERVICES=()
  IFS=',' read -r -a items <<<"$raw" || true
  for item in ${items[@]+"${items[@]}"}; do
    item=${item//[[:space:]]/}
    [ -n "$item" ] || continue
    case $item in
      lavish|pr|stall) ;;
      *) warn "unknown watch service '$item' in SUB_WATCH_SERVICES (known: lavish, pr, stall)"
         continue ;;
    esac
    known=0
    for existing in ${W_SERVICES[@]+"${W_SERVICES[@]}"}; do
      [ "$existing" = "$item" ] && known=1
    done
    [ "$known" = 0 ] && W_SERVICES+=("$item")
  done
  return 0
}

# ---------------------------------------------------------------------------
# Shared notice delivery
# ---------------------------------------------------------------------------

# Deliver one composed notice into the orchestrator session through the
# verified send. Returns 0 only after sub-report.sh confirmed the
# submission; an unconfirmed notice is never recorded as delivered. $3 is
# the label used in the failure warning (PR, stall).
send_notice() { # $1=task $2=composed message $3=label
  local task=$1 msg=$2 label=${3:-watcher}
  if "$_SUB_WATCH_DIR/sub-report.sh" "$task" "$msg" >/dev/null; then
    info "notice delivered for '$task': $msg"
    return 0
  fi
  warn "could not confirm the $label notice for '$task'; will retry"
  return 1
}

# ---------------------------------------------------------------------------
# Lavish service: wake the child when its artifact has queued feedback
# ---------------------------------------------------------------------------

LAVISH_LAST_SIG='' LAVISH_LAST_ATTEMPT=0 LAVISH_WARNED_STATE=0
W_LAVISH_STATE='' W_LAVISH_SINCE=''

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

# Wake the child for the pending JSON in $1. Returns 0 only when the
# verified send (type, Enter, confirm in the transcript) succeeded; a pane
# that is not running pi is never typed into.
lavish_wake_child() { # $1=pending JSON
  local pending=$1 msg pane_cmd
  pane_cmd=$(tmux display-message -p -t "$W_SESS" '#{pane_current_command}' 2>/dev/null || true)
  if [ "$pane_cmd" != pi ]; then
    warn "child pane in '$W_SESS' is not running pi (pane command: ${pane_cmd:-unknown}); not waking"
    return 1
  fi
  msg=$(compose_wake_message <<<"$pending")
  if ! "$_SUB_WATCH_DIR/sub-send.sh" "$W_TASK" "$msg" >/dev/null; then
    warn "could not confirm the Lavish wake for '$W_TASK'; will retry"
    return 1
  fi
  info "woke '$W_TASK' for Lavish feedback: $msg"
  return 0
}

lavish_init() {
  local state_dir
  state_dir=${LAVISH_AXI_STATE_DIR:-${HOME:-}/.lavish-axi}
  W_LAVISH_STATE=$state_dir/state.json
  W_LAVISH_SINCE=$(date -u -d "@$(( $(date +%s) - ${LAVISH_WATCH_START_MARGIN:-60} ))" +%Y-%m-%dT%H:%M:%SZ)
  LAVISH_LAST_SIG=''
  LAVISH_LAST_ATTEMPT=0
  LAVISH_WARNED_STATE=0
  info "watching Lavish feedback for '$W_TASK' in $W_LAVISH_STATE (worktree $W_WT)"
}

# One scan of the Lavish state: wake on a new queued batch, retry an
# unconfirmed wake, re-wake an unchanged batch only after the rewake
# interval. A failed read keeps the dedupe state (a transiently unreadable
# state must not look like "the queue drained").
lavish_tick() {
  local pending read_ok now sig due
  read_ok=1
  if ! pending=$(lavish_pending_sessions "$W_LAVISH_STATE" "$W_WT/" "$W_LAVISH_SINCE"); then
    read_ok=0
    if [ "$LAVISH_WARNED_STATE" = 0 ]; then
      warn "cannot read Lavish state at $W_LAVISH_STATE; skipping this scan and retrying"
      LAVISH_WARNED_STATE=1
    fi
  else
    LAVISH_WARNED_STATE=0
  fi

  if [ "$read_ok" = 0 ]; then
    return 0
  elif [ "$pending" = '[]' ]; then
    LAVISH_LAST_SIG=''
    LAVISH_LAST_ATTEMPT=0
    return 0
  fi

  sig=$pending
  now=$(date +%s)
  due=0
  if [ "$sig" != "$LAVISH_LAST_SIG" ]; then
    if [ $(( now - LAVISH_LAST_ATTEMPT )) -ge "${W_RETRY[lavish]}" ]; then due=1; fi
  else
    if [ $(( now - LAVISH_LAST_ATTEMPT )) -ge "${W_REWAKE[lavish]}" ]; then due=1; fi
  fi
  if [ "$due" = 1 ]; then
    LAVISH_LAST_ATTEMPT=$now
    if lavish_wake_child "$pending"; then
      LAVISH_LAST_SIG=$sig
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# PR service: notify the orchestrator of merge/close/review events
# ---------------------------------------------------------------------------

declare -A PR_SEEN_REVIEWS=()
# sig -> epoch before which an unreadable attribution read is not repeated:
# a poisoned read defers only its own review, never the later reviews of the
# same scan (they need no attribution read at all).
declare -A PR_REVIEW_RETRY_AFTER=()
PR_NEXT_ATTEMPT=0 PR_WARNED_READ=0 PR_WARNED_REVIEW=0

# Lease state for a task in a treehouse status document: alive | gone |
# unknown. An unparsable document is 'unknown', never 'gone': only a
# successful read that lacks the task's lease means the lease was returned.
# wt_for_task collapses failure and absence (best effort for lookups), so the
# repeated lifecycle check cannot use it.
lease_state() { # $1=status JSON $2=task
  local out=$1 task=$2 n
  if ! n=$(jq -r --arg h "$task" '
        if type == "array"
        then ([ .[] | select(.lease_holder? == $h) ] | length)
        else null end' <<<"$out" 2>/dev/null); then
    printf 'unknown'; return 0
  fi
  case $n in
    ''|null|*[!0-9]*) printf 'unknown' ;;
    0)                printf 'gone' ;;
    *)                printf 'alive' ;;
  esac
  return 0
}

# Read the current lease state for a task: alive | gone | unknown. A failed
# `treehouse status` is 'unknown' — the caller warns once and keeps watching;
# only a successful read without the task's lease stops the watcher.
lease_alive() { # $1=task $2=repo-root
  local task=$1 root=$2 out
  if ! out=$(cd "$root" && treehouse status --json 2>/dev/null); then
    printf 'unknown'; return 0
  fi
  lease_state "$out" "$task"
}

# Read the branch's most relevant PR (an open one first, else the first
# listed) as compact JSON
# `{number,url,state,reviews:[{id,login,state,submittedAt,body}]}`; nothing
# when the branch has no PR. Returns non-zero only when gh is missing or the
# read failed — "no PR yet" is a valid state the watcher keeps watching. Only
# read-only `gh pr list` queries; nothing here mutates GitHub.
read_pr() { # $1=branch $2=repo-root
  local branch=$1 root=$2 out pr
  command -v gh >/dev/null 2>&1 || return 1
  if ! out=$(cd "$root" && gh pr list --head "$branch" --state all --limit 10 \
               --json number,url,state,mergedAt,reviews,headRefName 2>/dev/null); then
    return 1
  fi
  # `--head` already filters server-side; the local filter repeats it so a
  # reader that ignores the argument (a test double, a future gh) still
  # never watches another branch's PR. The field is only trusted when
  # present (a real gh always returns it because it was requested).
  if ! pr=$(jq -c --arg b "$branch" '
        [ .[] | select((.headRefName // $b) == $b) ]
        | (map(select(.state == "OPEN")) + .)
        | if length == 0 then empty else .[0] end' <<<"$out" 2>/dev/null); then
    return 1
  fi
  [ -n "$pr" ] || return 0   # no PR for this branch (yet)
  jq -c '{
      number,
      url,
      state: (if .state == "MERGED" or (.mergedAt // null) != null
              then "MERGED" else .state end),
      reviews: [ (.reviews // [])[]
                 | select(.state == "APPROVED"
                          or .state == "CHANGES_REQUESTED"
                          or .state == "COMMENTED")
                 | { id: (.id // ""),
                     login: (.author.login // "unknown"),
                     state,
                     submittedAt: (.submittedAt // ""),
                     body: (.body // "") } ] }' <<<"$pr"
}

# Identity of one submitted review for deduplication. A reviewer's later
# review of the same state has a different submittedAt, so it is notified
# again — only the exact same submission is one notice.
review_signature() { # $1=review JSON
  jq -r '"\(.login)|\(.state)|\(.submittedAt)"' <<<"$1"
}

# Read-only GraphQL query for one review's comments: the watcher needs to
# know whether any comment is top-level (no replyTo). $id is a GraphQL
# variable placeholder, not a shell expansion.
# shellcheck disable=SC2016
_PR_REVIEW_COMMENTS_QUERY='query=query($id: ID!) { node(id: $id) { ... on PullRequestReview { comments(first: 100) { nodes { replyTo { id } } } } } }'

# Classify one submitted review for the watcher: actionable | self-reply |
# unreadable.
#
# The child and the reviewer share the `gh` identity, so author login cannot
# attribute a review. What the API does distinguish is a *submitted review*
# from a *reply to an existing review thread*: GitHub records a reply as a
# synthetic COMMENTED review with an empty body whose only comment carries
# `replyTo`. Notifying such a review routes the child's own words back to the
# child, which replies again — a self-sustaining loop (2026-10-18, riak-t
# PR #263). APPROVED / CHANGES_REQUESTED are never produced by a reply; a
# COMMENTED review with a non-empty body is a submission; a COMMENTED review
# with an empty body is decided by one read-only GraphQL query for its
# comments. A failed or unparsable read is 'unreadable' — never a notice.
review_disposition() { # $1=review JSON $2=repo-root
  local state body id top
  state=$(jq -r '.state' <<<"$1")
  if [ "$state" != COMMENTED ]; then printf 'actionable'; return 0; fi
  body=$(jq -r '.body // ""' <<<"$1")
  if [ -n "${body//[[:space:]]/}" ]; then printf 'actionable'; return 0; fi
  id=$(jq -r '.id // ""' <<<"$1")
  if [ -z "$id" ]; then printf 'unreadable'; return 0; fi
  # Read-only node query: how many of the review's comments are top-level
  # (no replyTo)? A page is enough — a review with more than 100 comments is
  # not a shape the review workflow produces.
  if ! top=$(cd "$2" && gh api graphql \
               -f "$_PR_REVIEW_COMMENTS_QUERY" \
               -f "id=$id" \
               --jq '[.data.node.comments.nodes[] | select(.replyTo == null)] | length' \
               2>/dev/null); then
    printf 'unreadable'; return 0
  fi
  case $top in
    ''|*[!0-9]*) printf 'unreadable' ;;
    0)           printf 'self-reply' ;;
    *)           printf 'actionable' ;;
  esac
}

# Epoch of the last notice attempt, kept monotonic (two attempts can land in
# the same second) so a retry always carries a fresh `[pr-watch <epoch>]`
# marker. tmux_send_line confirms a send by looking for the notice tail in
# the transcript, so an identical earlier copy must never satisfy a retry.
_PR_LAST_EPOCH=0
PR_WATCH_EPOCH=0

# Set PR_WATCH_EPOCH to a fresh epoch for one notice attempt.
new_epoch() {
  local e
  e=$(date +%s)
  if [ "$e" -le "$_PR_LAST_EPOCH" ]; then e=$((_PR_LAST_EPOCH + 1)); fi
  _PR_LAST_EPOCH=$e
  PR_WATCH_EPOCH=$e
}

# Terminal notice: a MERGED PR retires the child; a PR CLOSED without
# merging goes back to the child. Any non-MERGED terminal state reads as
# closed, matching gh's MERGED/CLOSED vocabulary.
compose_terminal_notice() { # $1=task $2=number $3=url $4=state $5=epoch
  local task=$1 number=$2 url=$3 state=$4 epoch=$5
  if [ "$state" = MERGED ]; then
    printf 'PR #%s (%s) was MERGED - retire the child now. [pr-watch %s]' \
      "$number" "$url" "$epoch"
  else
    printf 'PR #%s (%s) was CLOSED without merging - route it to the child with sub-send.sh %s. [pr-watch %s]' \
      "$number" "$url" "$task" "$epoch"
  fi
}

# Submitted-review notice.
compose_review_notice() { # $1=task $2=number $3=url $4=login $5=state $6=epoch
  printf 'PR #%s (%s) got a %s review from %s - route it to the child with sub-send.sh %s. [pr-watch %s]' \
    "$2" "$3" "$5" "$4" "$1" "$6"
}

pr_init() {
  PR_SEEN_REVIEWS=()
  PR_REVIEW_RETRY_AFTER=()
  PR_NEXT_ATTEMPT=0
  PR_WARNED_READ=0
  PR_WARNED_REVIEW=0
  info "watching PR for '$W_TASK' on branch '$W_BRANCH' (session $W_SESS)"
}

# One PR scan. Sets W_TICK_DONE=1 after the confirmed terminal notice: the
# PR service is done, but the engine keeps the other services watching (the
# child stays alive until the orchestrator retires it).
pr_tick() {
  local pr state number url now review sig login rstate rid disposition
  local -a reviews=()

  # A failed read (gh missing, not authenticated, network) is transient:
  # warn once, keep scanning, and never compose a notice from unreadable
  # data.
  pr=''
  if ! pr=$(read_pr "$W_BRANCH" "$W_ROOT"); then
    if [ "$PR_WARNED_READ" = 0 ]; then
      warn "could not read the PR state for branch '$W_BRANCH' (gh missing or failed); will retry"
      PR_WARNED_READ=1
    fi
    pr=''
  else
    PR_WARNED_READ=0
  fi
  [ -n "$pr" ] || return 0

  state=$(jq -r '.state' <<<"$pr")
  number=$(jq -r '.number' <<<"$pr")
  url=$(jq -r '.url' <<<"$pr")
  if [ "$state" = MERGED ] || [ "$state" = CLOSED ]; then
    # Terminal: exactly one notice, and the service is done only after the
    # submission is confirmed. Reviews still pending on that PR are not
    # notified — the PR is done, the orchestrator reacts to it, and a merged
    # PR needs no route back to the child.
    now=$(date +%s)
    if [ "$now" -ge "$PR_NEXT_ATTEMPT" ]; then
      new_epoch
      if send_notice "$W_TASK" "$(compose_terminal_notice "$W_TASK" "$number" "$url" "$state" "$PR_WATCH_EPOCH")" PR; then
        W_TICK_DONE=1
      else
        PR_NEXT_ATTEMPT=$(( now + W_RETRY[pr] ))
      fi
    fi
    return 0
  fi

  mapfile -t reviews < <(jq -c '.reviews[]' <<<"$pr")
  for review in ${reviews[@]+"${reviews[@]}"}; do
    sig=$(review_signature "$review")
    if [ -n "${PR_SEEN_REVIEWS[$sig]:-}" ]; then continue; fi
    now=$(date +%s)
    if [ "$now" -lt "$PR_NEXT_ATTEMPT" ]; then break; fi
    if [ "${PR_REVIEW_RETRY_AFTER[$sig]:-0}" -gt "$now" ]; then continue; fi
    # A COMMENTED review that is only a reply to an existing thread is the
    # child's own words (or any in-thread reply): nothing to route, and
    # notifying it would loop the child back onto itself. Record it handled
    # so later scans neither notify nor re-read it. An unreadable
    # attribution is never a notice and stays unrecorded; it is retried
    # after the retry delay, and only it — a poisoned read must not stop the
    # later reviews of the same scan from being notified.
    disposition=$(review_disposition "$review" "$W_ROOT")
    case $disposition in
      self-reply)
        rid=$(jq -r '.id // ""' <<<"$review")
        PR_SEEN_REVIEWS[$sig]=1
        info "review ${rid:-$sig} is a reply to an existing thread; not notifying"
        PR_WARNED_REVIEW=0
        continue ;;
      unreadable)
        if [ "$PR_WARNED_REVIEW" = 0 ]; then
          warn "could not read the review comments for '$W_TASK'; will retry"
          PR_WARNED_REVIEW=1
        fi
        PR_REVIEW_RETRY_AFTER[$sig]=$(( now + W_RETRY[pr] ))
        continue ;;
      *)
        PR_WARNED_REVIEW=0 ;;
    esac
    login=$(jq -r '.login' <<<"$review")
    rstate=$(jq -r '.state' <<<"$review")
    new_epoch
    if send_notice "$W_TASK" "$(compose_review_notice "$W_TASK" "$number" "$url" "$login" "$rstate" "$PR_WATCH_EPOCH")" PR; then
      PR_SEEN_REVIEWS[$sig]=1
    else
      PR_NEXT_ATTEMPT=$(( now + W_RETRY[pr] ))
      break
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Stall service: surface a free-provider failure visible in the child's pane
# ---------------------------------------------------------------------------

STALL_KIND='' STALL_COUNT=0
STALL_LAST_SIG='' STALL_LAST_ATTEMPT=0
_STALL_LAST_EPOCH=0
STALL_WATCH_EPOCH=0

# Set STALL_KIND to the visible free-provider failure (FreeUsageLimitError,
# FreeTierError, or "HTTP 429 rate limit") and STALL_COUNT to the number of
# matching pane lines, or leave both empty/zero when the pane is clean. The
# boolean detection is the shared pane_has_free_limit_error (the same
# signature sub-fallback.sh re-checks); the kind and count are read from the
# same bounded window for the dedupe signature.
stall_scan() {
  local text
  STALL_KIND=''
  STALL_COUNT=0
  pane_has_free_limit_error "$W_TASK" "${STALL_WATCH_SCAN_LINES:-50}" || return 0
  text=$(pane_tail "$W_TASK" "${STALL_WATCH_SCAN_LINES:-50}")
  # The pane can change between the detection read and this one; a failure
  # that vanished in between is a cleared incident, never a notice composed
  # from the fallback kind.
  grep -qE -- "$_FALLBACK_ERROR_RE" <<<"$text" || return 0
  STALL_COUNT=$(grep -cE -- "$_FALLBACK_ERROR_RE" <<<"$text" || true)
  if grep -qF -- 'FreeUsageLimitError' <<<"$text"; then
    STALL_KIND=FreeUsageLimitError
  elif grep -qF -- 'FreeTierError' <<<"$text"; then
    STALL_KIND=FreeTierError
  else
    STALL_KIND='HTTP 429 rate limit'
  fi
}

# Set STALL_WATCH_EPOCH to a fresh epoch for one notice attempt (same
# monotonicity rule as the PR marker).
new_stall_epoch() {
  local e
  e=$(date +%s)
  if [ "$e" -le "$_STALL_LAST_EPOCH" ]; then e=$((_STALL_LAST_EPOCH + 1)); fi
  _STALL_LAST_EPOCH=$e
  STALL_WATCH_EPOCH=$e
}

# Notify-only stall notice: the watcher never switches the model itself —
# the never-speculative sub-fallback.sh re-checks the pane and performs the
# switch, and the orchestrator supplies the continue nudge the switch alone
# does not.
compose_stall_notice() { # $1=task $2=kind $3=epoch
  printf 'STUCK: free-provider failure in the child pane (%s) - run sub-fallback.sh %s (it re-checks the pane) and nudge the child to continue. [stall-watch %s]' \
    "$2" "$1" "$3"
}

stall_init() {
  STALL_KIND=''
  STALL_COUNT=0
  STALL_LAST_SIG=''
  STALL_LAST_ATTEMPT=0
  info "watching the child pane of '$W_TASK' for free-provider stalls (session $W_SESS)"
}

# One stall scan: notify once per failure signature, retry an unconfirmed
# notice, re-wake an unchanged signature only after the rewake interval, and
# reset when the failure is no longer visible so a later stall notifies
# again.
stall_tick() {
  local sig now due
  stall_scan
  if [ -z "$STALL_KIND" ]; then
    STALL_LAST_SIG=''
    STALL_LAST_ATTEMPT=0
    return 0
  fi

  sig="$STALL_KIND|$STALL_COUNT"
  now=$(date +%s)
  due=0
  if [ "$sig" != "$STALL_LAST_SIG" ]; then
    if [ $(( now - STALL_LAST_ATTEMPT )) -ge "${W_RETRY[stall]}" ]; then due=1; fi
  else
    if [ $(( now - STALL_LAST_ATTEMPT )) -ge "${W_REWAKE[stall]}" ]; then due=1; fi
  fi
  if [ "$due" = 1 ]; then
    STALL_LAST_ATTEMPT=$now
    new_stall_epoch
    if send_notice "$W_TASK" "$(compose_stall_notice "$W_TASK" "$STALL_KIND" "$STALL_WATCH_EPOCH")" stall; then
      STALL_LAST_SIG=$sig
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

# Run the selected services in one loop for one child. $1=task,
# $2=repo-root (default $PWD), $3=branch argument for the PR service
# (optional; the worktree's checked-out branch is the fallback).
watch_engine() {
  local task=$1 repo=${2:-$PWD} branch_arg=${3:-}
  local root sess wt svc branch='' tick=0 loop_ms min_ms period all_done sleep_s

  W_TASK=$task
  root=$(repo_root "$repo")
  W_ROOT=$root
  sess=$(session_of "$task")
  W_SESS=$sess

  watch_parse_services
  if [ "${#W_SERVICES[@]}" -eq 0 ]; then
    info "no watch service selected (SUB_WATCH_SERVICES='${SUB_WATCH_SERVICES-}'); watcher exiting"
    return 0
  fi
  info "watching '$task' with services: ${W_SERVICES[*]}"

  need tmux
  if watch_service_active lavish || watch_service_active pr; then
    need git treehouse jq
  fi

  wt=$(wt_for_task "$task" "$root")
  W_WT=$wt
  # The Lavish artifacts live under the child's leased worktree, so that
  # service cannot run without one. A lease that is really gone stops the
  # watcher (the child is being retired); an unreadable lease is a startup
  # error, as the standalone Lavish watcher has always treated it.
  if watch_service_active lavish && [ -z "$wt" ]; then
    if [ "$(lease_alive "$task" "$root")" = gone ]; then
      info "no worktree lease for '$task'; watcher stopping"
      return 0
    fi
    die "no worktree leased for '$task' (in $root)"
  fi

  # Branch for the PR service: the explicit argument first, else the
  # worktree's checked-out branch. No branch means either the lease is
  # already gone (the watcher's stop condition — stop quietly) or the caller
  # gave it nothing to watch (a usage error).
  if watch_service_active pr; then
    if [ -n "$branch_arg" ]; then
      branch=$branch_arg
    elif [ -n "$wt" ]; then
      branch=$(git -C "$wt" branch --show-current 2>/dev/null || true)
    fi
    if [ -z "$branch" ]; then
      if [ "$(lease_alive "$task" "$root")" = gone ]; then
        info "no worktree lease for '$task'; watcher stopping"
        return 0
      fi
      die "cannot determine the branch for '$task' (no <branch> argument and no worktree branch)"
    fi
  fi
  W_BRANCH=$branch

  for svc in ${W_SERVICES[@]+"${W_SERVICES[@]}"}; do
    watch_service_init "$svc"
  done

  # The loop sleeps the smallest active interval (floored so an interval of
  # zero cannot spin a core) and runs each service every ceil(interval /
  # sleep) ticks: one clock, each service still polled at its own cadence.
  min_ms=$(watch_min_interval_ms)
  loop_ms=$min_ms
  [ "$loop_ms" -lt 50 ] && loop_ms=50
  for svc in ${W_SERVICES[@]+"${W_SERVICES[@]}"}; do
    period=$(( (W_INTERVAL_MS[$svc] + loop_ms - 1) / loop_ms ))
    [ "$period" -ge 1 ] || period=1
    W_PERIOD[$svc]=$period
  done
  sleep_s=$(watch_seconds "$loop_ms")

  W_LEASE_WARNED=0
  while :; do
    # Stop with the child: a killed session (retirement kills the watcher
    # window with it) leaves nothing to watch.
    if ! tmux has-session -t "$sess" 2>/dev/null; then
      info "child session '$sess' is not running; watcher stopping"
      return 0
    fi
    # A returned lease means the worktree is gone; a failed read is
    # transient and only warns once. The probe runs at the PR service's
    # cadence, not the loop's: treehouse status is not read-only (it
    # reconciles missing worktree paths and may rewrite its state file), and
    # the PR service is the one whose lifetime rule the lease is.
    for svc in ${W_SERVICES[@]+"${W_SERVICES[@]}"}; do
      [ "${W_DONE[$svc]}" = 1 ] && continue
      if [ $(( tick % ${W_PERIOD[$svc]} )) -ne 0 ]; then continue; fi
      if [ "$svc" = pr ]; then
        case $(lease_alive "$task" "$root") in
          gone)
            info "no worktree lease for '$task'; watcher stopping"
            return 0 ;;
          unknown)
            if [ "$W_LEASE_WARNED" = 0 ]; then
              warn "could not read treehouse status in $root; will keep watching"
              W_LEASE_WARNED=1
            fi ;;
          alive) W_LEASE_WARNED=0 ;;
        esac
      fi
      W_TICK_DONE=0
      watch_service_tick "$svc"
      W_RAN[$svc]=$(( W_RAN[$svc] + 1 ))
      if [ "$W_TICK_DONE" = 1 ]; then W_DONE[$svc]=1; fi
      if [ "${W_BOUND[$svc]}" -gt 0 ] && [ "${W_RAN[$svc]}" -ge "${W_BOUND[$svc]}" ]; then
        W_DONE[$svc]=1
      fi
    done

    all_done=1
    for svc in ${W_SERVICES[@]+"${W_SERVICES[@]}"}; do
      [ "${W_DONE[$svc]}" = 1 ] || all_done=0
    done
    [ "$all_done" = 1 ] && return 0

    tick=$((tick + 1))
    sleep "$sleep_s"
  done
}

# Run one service's tick.
watch_service_tick() { # $1=service
  case $1 in
    lavish) lavish_tick ;;
    pr)     pr_tick ;;
    stall)  stall_tick ;;
  esac
}
