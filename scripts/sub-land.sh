#!/usr/bin/env bash
# Inspect a subsession's work and print how to publish it. Read-only by design:
# publishing (push + pull request) happens in YOUR checkout, so this script
# never merges or pushes for you. Never merge into development.
# Use --patch to also export the work as a patch file.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir] [--patch]" ; }

need git treehouse jq
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then usage; fi

TASK=$1
REPO=$PWD
PATCH=0
for a in "$@"; do
  if [ "$a" = "--patch" ]; then PATCH=1; fi
done
# first non-flag arg after task = repo
if [ "$#" -ge 2 ] && [ "$2" != "--patch" ]; then REPO=$2; fi

valid_task "$TASK" || usage
ROOT=$(repo_root "$REPO")

WT=$(wt_for_task "$TASK" "$ROOT")
[ -n "$WT" ] || die "no worktree leased for '$TASK' (in $ROOT)"

BRANCH=$(git -C "$WT" branch --show-current || true)
BASE_REF=$(resolve_base_ref "$WT")
BASE_BRANCH=${BASE_REF#origin/}
info "== worktree: $WT"
info "== branch:   ${BRANCH:-detached}"

info "--- status ---"
git -C "$WT" status -sb

info "--- what would be lost if returned without publishing ---"
if [ "$BRANCH" = "$BASE_BRANCH" ] || [ -z "$BRANCH" ]; then
  UNLANDED=0
elif ! UNLANDED=$(unlanded_count "$WT" "$BASE_REF"); then
  die "cannot count commits not on '$BASE_REF' for '$BRANCH' (in $WT)"
fi
DIRTY=$(git -C "$WT" status --porcelain | wc -l)
info "uncommitted files: $DIRTY | commits not on $BASE_BRANCH: $UNLANDED"

if [ "$BRANCH" != "$BASE_BRANCH" ] && [ -n "$BRANCH" ]; then
  info "--- commits to publish ---"
  git -C "$WT" log --stat --oneline "$BASE_REF"..HEAD
  info ""
  info "Publish as a pull request from your checkout ($ROOT) — never merge into $BASE_BRANCH:"
  info "  git push -u origin $BRANCH"
  info "  gh pr create --base $BASE_BRANCH --head $BRANCH"
  info "  # patch-only rescue:  ${0##*/} $TASK --patch"
fi

if [ "$PATCH" = 1 ]; then
  OUT=$(patch_file "$ROOT" "$TASK")
  git -C "$WT" diff "$BASE_REF"...HEAD > "$OUT" 2>/dev/null || true
  # HEAD includes both staged and unstaged changes; plain `git diff` misses
  # staged files and could produce an incomplete rescue patch.
  git -C "$WT" diff HEAD >> "$OUT" 2>/dev/null || true
  info "patch written: $OUT"
fi

if [ "$UNLANDED" -eq 0 ] && [ "$DIRTY" -eq 0 ]; then
  info "Nothing to publish — worktree is clean."
fi
