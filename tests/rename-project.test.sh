#!/usr/bin/env bash
# Behavioural tests for the ai-orchestrator/ai-commander -> mu-commander
# project rename (this suite's original task renamed ai-orchestrator ->
# ai-commander; the follow-up task finished the rename to mu-commander and
# updated this suite to the end state).
# One test per Scenario in specs/rename-ai-commander/rename-ai-commander.feature.
#
# [REQ-1] always runs against the tracked files of this checkout.
# The machine-specific assertions ([REQ-4], [REQ-5], [REQ-7]) check real
# state outside the repository; they fail loudly when the state exists but is
# wrong, and skip when it does not exist at all, so the suite stays runnable
# on machines that never had the old state. The machine-level holders are
# renamed only after the checkout-folder rename, so [REQ-4]/[REQ-5] expect
# the mu-commander paths and stay green (skip) until that happens.
# The pi.sh session default ([REQ-2]) is historical: development dropped
# pi.sh in favour of the mu launcher, and its coverage (tests/test-pi-sh.sh)
# was removed with it. The managed path used by worktree-setup ([REQ-3]) is
# covered by tests/worktree-setup.test.sh.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OLD_ID=ai-orchestrator
MID_ID=ai-commander
NEW_ID=mu-commander
# The GitHub repository was renamed ai-orchestrator -> ai-commander and then
# again to mu-commander. [REQ-7] pins the actual current repository name and
# the absence of both earlier identifiers, not the intermediate name.
CURRENT_REPO=mu-commander

passed=0 failed=0 skipped=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; failed=$((failed + 1)); exit 1; }
ok() { passed=$((passed + 1)); }
skip() { printf '  skipped: %s\n' "$*"; skipped=$((skipped + 1)); }

# ---------------------------------------------------------------------------
# [REQ-1] No tracked file contains an earlier project identifier.
# The rename's own specification and test documents are exempt: they must
# name the old identifiers to define what is being renamed. Both rename spec
# folders and both suites are exempt so this check stays green whichever
# branch/merge order brought them in.
# ---------------------------------------------------------------------------
echo 'test: No tracked file contains an earlier project identifier [REQ-1]'
if hits=$(git -C "$ROOT" grep -n -i -E "$OLD_ID|$MID_ID" -- . \
  ':(exclude)specs/rename-ai-commander/*' \
  ':(exclude)specs/rename-mu-commander/*' \
  ':(exclude)tests/rename-project.test.sh' \
  ':(exclude)tests/rename-mu-commander.test.sh'); then
  fail "[REQ-1] tracked files still reference an earlier identifier:"$'\n'"$hits"
fi
ok

# ---------------------------------------------------------------------------
# [REQ-4] On this machine the provisioned shellcheck lives at the new path.
# The intermediate ai-commander directory and the ai-orchestrator one must be
# gone once the mu-commander install exists.
# ---------------------------------------------------------------------------
echo 'test: On this machine the provisioned shellcheck lives at the new path [REQ-4]'
OLD_MANAGED="$HOME/.local/share/$OLD_ID"
MID_MANAGED="$HOME/.local/share/$MID_ID"
NEW_MANAGED="$HOME/.local/share/$NEW_ID/shellcheck"
SLOT="$HOME/.local/bin/shellcheck"
PIN=$(awk -F= '/^SHELLCHECK_VERSION=/{print $2}' "$ROOT/scripts/worktree-setup.sh")
if [ -d "$NEW_MANAGED" ]; then
  [ -e "$OLD_MANAGED" ] && fail "[REQ-4] old managed directory still exists: $OLD_MANAGED"
  [ -e "$MID_MANAGED" ] && fail "[REQ-4] earlier managed directory still exists: $MID_MANAGED"
  [ -e "$SLOT" ] || fail "[REQ-4] $SLOT is missing"
  resolved=$(readlink -f "$SLOT" 2>/dev/null || true)
  case "$resolved" in
    "$NEW_MANAGED"/*) ;;
    *) fail "[REQ-4] $SLOT resolves to '$resolved', expected under $NEW_MANAGED" ;;
  esac
  got=$("$SLOT" --version 2>/dev/null | awk '/^version:/{print $2; exit}')
  [ "$got" = "$PIN" ] || fail "[REQ-4] $SLOT reports '${got:-unreadable}', pinned is $PIN"
  # Idempotency: running the setup must recognise the install and not
  # re-download (no "installing pinned" line, an "already installed" line).
  if ! setup_out=$(cd "$ROOT" && ./scripts/worktree-setup.sh 2>&1); then
    fail "[REQ-4] worktree-setup.sh exited non-zero:"$'\n'"$setup_out"
  fi
  case "$setup_out" in
    *"shellcheck: already installed"*) ;;
    *) fail "[REQ-4] worktree-setup.sh did not report the shellcheck as already installed:"$'\n'"$setup_out" ;;
  esac
  case "$setup_out" in
    *"shellcheck: installing pinned"*)
      fail "[REQ-4] worktree-setup.sh re-downloaded shellcheck:"$'\n'"$setup_out" ;;
  esac
  ok
else
  skip "[REQ-4] no managed shellcheck at $NEW_MANAGED yet (machine rename pending)"
fi

# ---------------------------------------------------------------------------
# [REQ-5] The treehouse post_create hook points at the renamed checkout.
# Checked only once the mu-commander checkout exists (after the folder
# rename); before that the hook is expected to name the intermediate path.
# ---------------------------------------------------------------------------
echo 'test: The treehouse post_create hook points at the renamed checkout [REQ-5]'
TREEHOUSE_CFG="$HOME/.config/treehouse/config.toml"
NEW_CHECKOUT="$HOME/programming-projects/$NEW_ID"
if [ -f "$TREEHOUSE_CFG" ] && [ -d "$NEW_CHECKOUT" ]; then
  hook=$(grep -E '^\s*post_create' "$TREEHOUSE_CFG" || true)
  case "$hook" in
    *"/programming-projects/$NEW_ID/scripts/worktree-setup.sh"*) ;;
    *) fail "[REQ-5] post_create does not point at the $NEW_ID checkout: $hook" ;;
  esac
  case "$hook" in
    *"$OLD_ID"* | *"$MID_ID"*) fail "[REQ-5] post_create still references an earlier identifier: $hook" ;;
  esac
  ok
else
  skip "[REQ-5] $NEW_CHECKOUT or $TREEHOUSE_CFG not present yet (machine rename pending)"
fi

# ---------------------------------------------------------------------------
# [REQ-7] The origin remote carries the current repository name.
# ---------------------------------------------------------------------------
echo 'test: The origin remote carries the current repository name [REQ-7]'
if url=$(git -C "$ROOT" remote get-url origin 2>/dev/null) && [ -n "$url" ]; then
  case "$url" in
    *"/$CURRENT_REPO.git" | *"/$CURRENT_REPO") ;;
    *) fail "[REQ-7] origin points at '$url', expected .../$CURRENT_REPO" ;;
  esac
  case "$url" in
    *"$OLD_ID"* | *"$MID_ID"*) fail "[REQ-7] origin still references an earlier identifier: $url" ;;
  esac
  ok
else
  skip "[REQ-7] no origin remote on this machine"
fi

# ---------------------------------------------------------------------------
echo "results: $passed passed, $failed failed, $skipped skipped"
[ "$failed" = 0 ] || exit 1
