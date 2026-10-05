#!/usr/bin/env bash
# Behavioural tests for the ai-orchestrator/ai-commander -> mu-commander
# project rename. One test per Scenario in
# specs/rename-mu-commander/rename-mu-commander.feature.
#
# [REQ-1] and [REQ-3] run against the tracked files of this checkout. The
# origin assertion ([REQ-6]) checks repository state; it fails loudly when the
# remote exists but is wrong and skips when there is no origin at all, so the
# suite stays runnable on machines that never had the old repository name.
#
# Exempt from the identifier grep are the documents that must literally name
# the old identifiers to define the renames: this suite's own spec folder and
# test file, plus the earlier rename's documents (specs/rename-ai-commander/,
# tests/rename-project.test.sh) that arrived with the now-merged PR #10 and
# were updated to the same final state here.
#
# [REQ-3]'s path used by worktree-setup.sh is exercised end-to-end by
# tests/worktree-setup.test.sh; this suite asserts the expected literals.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NEW_ID=mu-commander
OLD_ID_RE='ai[-_]orchestrator|ai[-_]commander'

passed=0 failed=0 skipped=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; failed=$((failed + 1)); exit 1; }
ok() { passed=$((passed + 1)); }
skip() { printf '  skipped: %s\n' "$*"; skipped=$((skipped + 1)); }

# ---------------------------------------------------------------------------
# [REQ-1] No tracked file or path contains an old project identifier.
# ---------------------------------------------------------------------------
echo 'test: No tracked file or path contains an old project identifier [REQ-1]'
if hits=$(git -C "$ROOT" grep -n -i -E "$OLD_ID_RE" -- . \
  ':(exclude)specs/rename-mu-commander/*' \
  ':(exclude)tests/rename-mu-commander.test.sh' \
  ':(exclude)specs/rename-ai-commander/*' \
  ':(exclude)tests/rename-project.test.sh'); then
  fail "[REQ-1] tracked files still reference an old identifier:"$'\n'"$hits"
fi
if bad_paths=$(git -C "$ROOT" ls-files | grep -i -E "$OLD_ID_RE" | grep -v -E '^(specs/rename-ai-commander/|tests/rename-project\.test\.sh$)'); then
  fail "[REQ-1] tracked paths still contain an old identifier:"$'\n'"$bad_paths"
fi
ok

# ---------------------------------------------------------------------------
# [REQ-3] The managed shellcheck directory uses the new project name.
# ---------------------------------------------------------------------------
echo 'test: The managed shellcheck directory uses the new project name [REQ-3]'
grep -Fq "$NEW_ID/shellcheck" "$ROOT/scripts/worktree-setup.sh" \
  || fail "[REQ-3] worktree-setup.sh does not manage $NEW_ID/shellcheck"
grep -Fq "$NEW_ID/shellcheck" "$ROOT/tests/worktree-setup.test.sh" \
  || fail "[REQ-3] tests/worktree-setup.test.sh does not sandbox $NEW_ID/shellcheck"
ok

# ---------------------------------------------------------------------------
# [REQ-6] The origin remote carries the new repository name.
# ---------------------------------------------------------------------------
echo 'test: The origin remote carries the new repository name [REQ-6]'
if url=$(git -C "$ROOT" remote get-url origin 2>/dev/null) && [ -n "$url" ]; then
  case "$url" in
    *"/$NEW_ID.git" | *"/$NEW_ID") ;;
    *) fail "[REQ-6] origin points at '$url', expected .../$NEW_ID" ;;
  esac
  case "$url" in
    *ai-orchestrator* | *ai-commander*) fail "[REQ-6] origin still references an old identifier: $url" ;;
  esac
  ok
else
  skip "[REQ-6] no origin remote on this machine"
fi

# ---------------------------------------------------------------------------
# [supp] The rename suite itself is shellcheck-clean.
# ---------------------------------------------------------------------------
echo 'test: The rename suite is shellcheck-clean [supp]'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$ROOT/tests/rename-mu-commander.test.sh" \
    || fail "[supp] shellcheck reported findings in tests/rename-mu-commander.test.sh"
  ok
else
  skip "[supp] shellcheck not on PATH"
fi

# ---------------------------------------------------------------------------
echo "results: $passed passed, $failed failed, $skipped skipped"
[ "$failed" = 0 ] || exit 1
