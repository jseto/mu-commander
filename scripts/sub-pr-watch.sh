#!/usr/bin/env bash
# Watch a child's pull request and push verified event notices to the
# orchestrator (see specs/pr-action-watch/pr-action-watch.feature).
#
# A child opens a PR for its task branch and then goes idle, so GitHub-side
# events on that PR wait for a manual check. Three events need the
# orchestrator while the child is still alive: the PR was merged (retire the
# child), it was closed without merging, and a review was submitted
# (especially "request changes", which must reach the child). This watcher
# polls the branch read-only with `gh` from a `pr-watch` window of the
# child's tmux session and pushes each event through the same verified notice
# path every child notice uses (`sub-report.sh` -> tmux_send_line into the
# orchestrator session). It never mutates GitHub and never types into the
# child's pane; it exits when the child's tmux session or its worktree lease
# disappears, or right after the confirmed notice for a terminal PR state.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir] [branch]"; }

# ---------------------------------------------------------------------------
# Pure seams
# ---------------------------------------------------------------------------

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
_LAST_EPOCH=0
PR_WATCH_EPOCH=0

# Set PR_WATCH_EPOCH to a fresh epoch for one notice attempt.
new_epoch() {
  local e
  e=$(date +%s)
  if [ "$e" -le "$_LAST_EPOCH" ]; then e=$((_LAST_EPOCH + 1)); fi
  _LAST_EPOCH=$e
  PR_WATCH_EPOCH=$e
}

# ---------------------------------------------------------------------------
# Notice composition (sub-report.sh prefixes `[<task>] `)
# ---------------------------------------------------------------------------

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

# Deliver one composed notice into the orchestrator session through the
# verified send. Returns 0 only after sub-report.sh confirmed the
# submission; an unconfirmed notice is never recorded as delivered.
send_notice() { # $1=task $2=composed message
  local task=$1 msg=$2
  if "$SCRIPT_DIR/sub-report.sh" "$task" "$msg" >/dev/null; then
    info "notice delivered for '$task': $msg"
    return 0
  fi
  warn "could not confirm the PR notice for '$task'; will retry"
  return 1
}

# ---------------------------------------------------------------------------
# Watcher loop
# ---------------------------------------------------------------------------

main() {
  need git tmux treehouse jq
  if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then usage; fi

  local task=$1 repo=${2:-$PWD} branch_arg=${3:-}
  valid_task "$task" || usage
  local root sess wt branch
  root=$(repo_root "$repo")
  sess=$(session_of "$task")
  wt=$(wt_for_task "$task" "$root")

  # Branch: the explicit argument first, else the worktree's checked-out
  # branch. No branch means either the lease is already gone (the watcher's
  # stop condition — stop quietly) or the caller gave it nothing to watch
  # (a usage error).
  branch=""
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

  local interval=${PR_WATCH_INTERVAL:-30}
  local retry=${PR_WATCH_RETRY_SECONDS:-5}
  local max_ticks=${PR_WATCH_TICKS:-0}
  # The retry (and the tick bound) feeds integer arithmetic, so a fractional
  # value must be rejected at startup: accepting it would abort the watcher on
  # the first unconfirmed notice — exactly when the retry exists.
  if [[ ! $interval =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "PR_WATCH_INTERVAL must be a non-negative number: $interval"
  fi
  if [[ ! $retry =~ ^[0-9]+$ ]]; then
    die "PR_WATCH_RETRY_SECONDS must be a non-negative integer: $retry"
  fi
  if [[ ! $max_ticks =~ ^[0-9]+$ ]]; then
    die "PR_WATCH_TICKS must be a non-negative integer: $max_ticks"
  fi
  local -A seen_reviews=()
  local -A review_retry_after=()   # sig -> epoch before which an unreadable review is not re-read
  local next_attempt=0 ticks=0 warned_read=0 warned_lease=0 warned_review=0
  local pr state number url now review sig login rstate rid disposition
  local -a reviews=()

  info "watching PR for '$task' on branch '$branch' (session $sess)"

  while :; do
    # Stop with the child: a killed session (retirement kills the watcher
    # window with it) or a returned lease leaves nothing to notify about.
    if ! tmux has-session -t "$sess" 2>/dev/null; then
      info "child session '$sess' is not running; watcher stopping"
      return 0
    fi
    case $(lease_alive "$task" "$root") in
      gone)
        info "no worktree lease for '$task'; watcher stopping"
        return 0 ;;
      unknown)
        if [ "$warned_lease" = 0 ]; then
          warn "could not read treehouse status in $root; will keep watching"
          warned_lease=1
        fi ;;
      alive)
        warned_lease=0 ;;
    esac

    # A failed read (gh missing, not authenticated, network) is transient:
    # warn once, keep scanning, and never compose a notice from unreadable
    # data.
    pr=''
    if ! pr=$(read_pr "$branch" "$root"); then
      if [ "$warned_read" = 0 ]; then
        warn "could not read the PR state for branch '$branch' (gh missing or failed); will retry"
        warned_read=1
      fi
      pr=''
    else
      warned_read=0
    fi

    if [ -n "$pr" ]; then
      state=$(jq -r '.state' <<<"$pr")
      number=$(jq -r '.number' <<<"$pr")
      url=$(jq -r '.url' <<<"$pr")
      if [ "$state" = MERGED ] || [ "$state" = CLOSED ]; then
        # Terminal: exactly one notice, and the watcher only exits after the
        # submission is confirmed. Reviews still pending on that PR are not
        # notified — the PR is done, the orchestrator reacts to it, and a
        # merged PR needs no route back to the child.
        now=$(date +%s)
        if [ "$now" -ge "$next_attempt" ]; then
          new_epoch
          if send_notice "$task" "$(compose_terminal_notice "$task" "$number" "$url" "$state" "$PR_WATCH_EPOCH")"; then
            return 0
          fi
          next_attempt=$(( now + retry ))
        fi
      else
        mapfile -t reviews < <(jq -c '.reviews[]' <<<"$pr")
        for review in ${reviews[@]+"${reviews[@]}"}; do
          sig=$(review_signature "$review")
          if [ -n "${seen_reviews[$sig]:-}" ]; then continue; fi
          now=$(date +%s)
          if [ "$now" -lt "$next_attempt" ]; then break; fi
          if [ "${review_retry_after[$sig]:-0}" -gt "$now" ]; then continue; fi
          # A COMMENTED review that is only a reply to an existing thread is
          # the child's own words (or any in-thread reply): nothing to route,
          # and notifying it would loop the child back onto itself. Record it
          # handled so later scans neither notify nor re-read it. An
          # unreadable attribution is never a notice and stays unrecorded; it
          # is retried after the retry delay, and only it — a poisoned read
          # must not stop the later reviews of the same scan from being
          # notified (they need no attribution read at all).
          disposition=$(review_disposition "$review" "$root")
          case $disposition in
            self-reply)
              rid=$(jq -r '.id // ""' <<<"$review")
              seen_reviews[$sig]=1
              info "review ${rid:-$sig} is a reply to an existing thread; not notifying"
              warned_review=0
              continue ;;
            unreadable)
              if [ "$warned_review" = 0 ]; then
                warn "could not read the review comments for '$task'; will retry"
                warned_review=1
              fi
              review_retry_after[$sig]=$(( now + retry ))
              continue ;;
            *)
              warned_review=0 ;;
          esac
          login=$(jq -r '.login' <<<"$review")
          rstate=$(jq -r '.state' <<<"$review")
          new_epoch
          if send_notice "$task" "$(compose_review_notice "$task" "$number" "$url" "$login" "$rstate" "$PR_WATCH_EPOCH")"; then
            seen_reviews[$sig]=1
          else
            next_attempt=$(( now + retry ))
            break
          fi
        done
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
