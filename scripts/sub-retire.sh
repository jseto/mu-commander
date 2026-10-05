#!/usr/bin/env bash
# Retire a subsession: kill its tmux session, return the worktree, clean up
# the task's branches (best effort; see --no-branch-cleanup), and append the
# retirement with its session cost to the conversation log.
# Refuses (without --force) when unlanded work would be destroyed.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir] [--force] [--keep-files] [--no-branch-cleanup]" ; }

need git tmux treehouse jq
if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then usage; fi

TASK=$1
REPO=$PWD
FORCE=0
KEEP_FILES=0
CLEANUP=1
for a in "$@"; do
  case "$a" in
    --force)             FORCE=1 ;;
    --keep-files)        KEEP_FILES=1 ;;
    --no-branch-cleanup) CLEANUP=0 ;;
  esac
done
if [ "$#" -ge 2 ] && [[ "$2" != --* ]]; then REPO=$2; fi

valid_task "$TASK" || usage
ROOT=$(repo_root "$REPO")
SESS=$(session_of "$TASK")

cd "$ROOT"
WT=$(wt_for_task "$TASK" "$ROOT")
[ -n "$WT" ] || die "no worktree leased for '$TASK' (in $ROOT)"
# Capture the task branch before 'treehouse return' detaches the worktree HEAD.
BRANCH=$(git -C "$WT" branch --show-current 2>/dev/null || true)
# The base the task is compared against, resolved through the shared helper so
# a repository that deleted $DEV_BRANCH still retires (loudly if none exists).
BASE_REF=$(resolve_base_ref "$WT")
BASE_BRANCH=${BASE_REF#origin/}

# A branch is "published" (safe to retire) when its tip is already reachable
# from a remote branch, i.e. the task branch was pushed for a PR or the work
# was merged into the remote development branch. The remote copy is durable,
# so returning the worktree cannot lose it.
is_published() {
  local branch=$1 tip
  tip=$(git -C "$WT" rev-parse HEAD)
  if git -C "$ROOT" rev-parse --verify --quiet "origin/$BASE_BRANCH" >/dev/null \
     && git -C "$ROOT" merge-base --is-ancestor "$tip" "origin/$BASE_BRANCH" 2>/dev/null; then
    return 0
  fi
  if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch" \
     && git -C "$ROOT" merge-base --is-ancestor "$tip" "origin/$branch" 2>/dev/null; then
    return 0
  fi
  return 1
}

# State of a branch's pull request: merged | open | none | unknown.
# A missing/failing gh degrades to 'unknown' — never an error.
pr_state() { # $1=branch
  local branch=$1 out
  command -v gh >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  if ! out=$(gh pr list --state merged --head "$branch" --json number 2>/dev/null); then
    printf 'unknown'; return 0
  fi
  if [ -n "$out" ] && [ "$out" != "[]" ]; then printf 'merged'; return 0; fi
  if ! out=$(gh pr list --state open --head "$branch" --json number 2>/dev/null); then
    printf 'unknown'; return 0
  fi
  if [ -n "$out" ] && [ "$out" != "[]" ]; then printf 'open'; return 0; fi
  printf 'none'
}

# True when origin/<branch> is fully merged into origin/<dev-base>.
remote_merged() { # $1=branch
  git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/origin/$BASE_BRANCH" >/dev/null \
    && git -C "$ROOT" merge-base --is-ancestor "refs/remotes/origin/$1" "refs/remotes/origin/$BASE_BRANCH" 2>/dev/null
}

# Best-effort cleanup of the task's branches, run only after the retirement
# itself succeeded. Every deletion is gated and guarded: failures are warnings,
# never errors — retiring must not break because a branch was already gone.
cleanup_branches() { # $1=branch
  local branch=$1 pr
  [ -n "$branch" ] || return 0
  case "$branch" in task/*) ;; *) return 0 ;; esac

  # Local: only ever 'branch -d' (fully merged into the dev base), never -D.
  if git -C "$ROOT" merge-base --is-ancestor "refs/heads/$branch" "$BASE_REF" 2>/dev/null; then
    if git -C "$ROOT" branch -d "$branch" >/dev/null 2>&1; then
      info "deleted local branch $branch (merged into $BASE_BRANCH)"
    else
      warn "could not delete local branch $branch"
    fi
  else
    warn "local branch $branch is not merged into $BASE_BRANCH; keeping it"
  fi

  # Remote: delete only for a merged PR, or — with no open PR — when the tip
  # is merged into origin/<dev-base>. An open PR always keeps the branch.
  git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch" || return 0
  pr=$(pr_state "$branch")
  if [ "$pr" = "open" ]; then
    info "remote branch origin/$branch has an open PR; keeping it"
    return 0
  fi
  if [ "$pr" != "merged" ] && ! remote_merged "$branch"; then
    info "remote branch origin/$branch is not merged; keeping it"
    return 0
  fi
  if git -C "$ROOT" push --delete origin "$branch" >/dev/null 2>&1; then
    info "deleted remote branch origin/$branch"
  else
    warn "could not delete remote branch origin/$branch"
  fi
  return 0
}

# Total cost of the child's pi session records: the sum of the per-message
# usage.cost.total values in <agent-dir>/sessions/**/*.jsonl. Those records
# live in the per-task isolated agent directory, so the sum is attributable
# to this child only. Echoes e.g. "0.1234"; echoes nothing when no (readable)
# records exist — jq failing on a corrupt file yields nothing as well, so a
# total is either right or absent, never wrong.
session_cost() { # $1=agent dir
  local dir=$1/sessions f total
  local files=()
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.jsonl "$dir"/*/*.jsonl; do
    [ -f "$f" ] || continue
    files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  total=$(jq -s -r '.[] | .message? | objects | .usage? | objects
                    | .cost? | objects | .total? | numbers' "${files[@]}" 2>/dev/null \
    | awk '{ s += $1 } END { printf "%.4f", s }') || return 0
  printf '%s' "$total"
}

# Best-effort: record the retirement (task + session cost) in the
# conversation log. Every failure mode — script missing, append failing —
# degrades to a warning; the retirement's exit status must never change.
log_retirement() { # $1=cost label ("$0.1234" or "unknown")
  local label=$1 script="$SCRIPT_DIR/conversation-log.sh" out
  if [ ! -f "$script" ]; then
    warn "conversation-log.sh not found; retirement of '$TASK' was not logged"
    return 0
  fi
  if out=$("$script" append operation "retired $TASK | session cost: $label" 2>&1); then
    info "logged retirement of '$TASK' in the conversation log (session cost: $label)"
  else
    warn "could not append retirement of '$TASK' to the conversation log: ${out%%$'\n'*}"
  fi
  return 0
}

# Safety: 'treehouse return --force' clean-resets the worktree.
if [ "$FORCE" != 1 ]; then
  DIRTY=$(git -C "$WT" status --porcelain | wc -l)
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "$BASE_BRANCH" ]; then
    if ! UNLANDED=$(unlanded_count "$WT" "$BASE_REF"); then
      die "cannot count commits not on '$BASE_REF' for '$BRANCH' — refusing to discard work blindly"
    fi
  else
    UNLANDED=0
  fi
  if [ "$DIRTY" -gt 0 ]; then
    warn "refusing to destroy uncommitted work: $DIRTY uncommitted file(s) in $WT"
    info "commit & push first:  ${0%/*}/sub-land.sh $TASK"
    info "then retry:  ${0##*/} $TASK --force   (only after publishing, or to discard)"
    exit 1
  fi
  if [ "$UNLANDED" -gt 0 ] && ! is_published "$BRANCH"; then
    warn "refusing to destroy unpublished work: $UNLANDED commit(s) on '$BRANCH' not on $BASE_BRANCH or any origin branch"
    info "publish first:  push the branch and open a PR (see ${0%/*}/sub-land.sh $TASK)"
    info "then retry:    ${0##*/} $TASK --force   (only after publishing, or to discard)"
    exit 1
  fi
fi

# Session cost from the child's own pi session records. Captured now — after
# the refusal checks, so a refused retirement logs nothing — and before the
# tmux session is killed and the scratch cleanup deletes the agent directory
# that holds the records (REQ-3). Missing source only warns (REQ-4).
COST=$(session_cost "$(scratch_root "$ROOT")/agent-dirs/$TASK")
if [ -n "$COST" ]; then
  COST="\$$COST"   # label as it appears in the entry: $0.1234
else
  COST=unknown
  warn "no readable session cost for '$TASK'; logging 'session cost: unknown'"
fi

if tmux has-session -t "$SESS" 2>/dev/null; then
  tmux kill-session -t "$SESS"
  info "killed tmux session $SESS"
else
  info "tmux session $SESS not running"
fi

treehouse return --force "$WT"
info "returned worktree $WT"

# Drop the scratch brief/report/patch now that the worktree is gone; the pushed
# branch/PR is the durable copy. Use --keep-files to retain them.
if [ "$KEEP_FILES" != 1 ]; then
  removed=0
  agent_dir="$(scratch_root "$ROOT")/agent-dirs/$TASK"
  if [ -d "$agent_dir" ]; then
    rm -rf "$agent_dir"
    removed=$((removed + 1))
  fi
  for f in "$(task_file "$ROOT" "$TASK")" "$(report_file "$ROOT" "$TASK")" "$(patch_file "$ROOT" "$TASK")"; do
    if [ -e "$f" ]; then
      rm -f "$f"
      removed=$((removed + 1))
    fi
  done
  # remove scratch subdirectories when no other task still uses them
  rmdir "$(scratch_root "$ROOT")/tasks" "$(scratch_root "$ROOT")/reports" "$(scratch_root "$ROOT")/agent-dirs" 2>/dev/null || true
  rmdir "$(scratch_root "$ROOT")" 2>/dev/null || true
  if [ "$removed" -gt 0 ]; then
    info "removed $removed scratch file(s) for '$TASK'"
  fi
fi

# Best-effort branch cleanup after a successful retirement (REQ-1..REQ-6).
if [ "$CLEANUP" = 1 ]; then
  cleanup_branches "$BRANCH" || true
else
  info "branch cleanup skipped (--no-branch-cleanup)"
fi

info "retired task '$TASK'"

# Last step of a successful retirement: append the conversation-log entry.
# Independent of (and no less best-effort than) the branch cleanup above.
log_retirement "$COST"
