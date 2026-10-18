#!/usr/bin/env bash
# Behavioural tests for scripts/sub-retire.sh branch cleanup and missing leases.
# Scenarios live in specs/branch-cleanup-retire/ and specs/retire-missing-lease/.
#
# Each test sandboxes a fake origin (bare repo), a main checkout with a
# development branch, a linked task worktree, and stub treehouse/tmux/gh
# binaries placed first on PATH — no real tmux sessions, treehouse pool, or
# GitHub access is touched.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RETIRE="$ROOT/scripts/sub-retire.sh"
TASK=demo-task
BRANCH="task/$TASK"

failures=0

fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

setup() {
  SB=$(mktemp -d)
  trap 'rm -rf "$SB"' EXIT
  export STUB_WT="$SB/wt" STUB_TASK="$TASK"
  export STUB_TREEHOUSE_LOG="$SB/treehouse.log" STUB_TMUX_LOG="$SB/tmux.log"
  export STUB_LEASE=1 STUB_STATUS_FAIL=0 STUB_STATUS_INVALID=0 STUB_STATUS_SHAPE=0 STUB_TMUX_EXISTS=0
  export SCRATCH_DIR=tmp/pi-sub
  export GH_PR_STATE=none GH_PR_FAIL=0
  # Test hygiene: retirement now logs the session cost — sandbox the log so
  # no test entry can reach the real conversation log.
  export CONVERSATION_LOG_DIR="$SB/logs"
  mkdir -p "$SB/bin"

  cat > "$SB/bin/treehouse" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  status)
    printf 'status\n' >> "$STUB_TREEHOUSE_LOG"
    [ "${STUB_STATUS_FAIL:-0}" = 1 ] && exit 2
    if [ "${STUB_STATUS_INVALID:-0}" = 1 ]; then
      printf 'not-json\n'
    elif [ "${STUB_STATUS_SHAPE:-0}" = 1 ]; then
      printf '[{}]\n'
    elif [ "${STUB_LEASE:-1}" = 1 ]; then
      printf '[{"path":"%s","lease_holder":"%s"}]\n' "$STUB_WT" "$STUB_TASK"
    else
      printf '[]\n'
    fi
    ;;
  return)
    printf 'return\n' >> "$STUB_TREEHOUSE_LOG"
    shift
    [ "${1:-}" = "--force" ] && shift
    # The real 'treehouse return --force' cleans, resets and detaches HEAD.
    git -C "$1" checkout --detach -q 2>/dev/null || true
    ;;
esac
exit 0
EOS

  cat > "$SB/bin/tmux" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  has-session)
    [ "${STUB_TMUX_EXISTS:-0}" = 1 ] && exit 0
    exit 1
    ;;
  kill-session)
    printf 'kill-session\n' >> "$STUB_TMUX_LOG"
    ;;
esac
exit 0
EOS

  cat > "$SB/bin/gh" <<'EOS'
#!/usr/bin/env bash
[ "${GH_PR_FAIL:-0}" = 1 ] && exit 1
state= prev=
for a in "$@"; do
  [ "$prev" = "--state" ] && state=$a
  prev=$a
done
case "${GH_PR_STATE:-none}:$state" in
  merged:merged) printf '[{"number":1}]\n' ;;
  open:open)     printf '[{"number":1}]\n' ;;
  *)             printf '[]\n' ;;
esac
exit 0
EOS
  chmod +x "$SB/bin/treehouse" "$SB/bin/tmux" "$SB/bin/gh"
  export PATH="$SB/bin:$PATH"

  git init -q --bare "$SB/origin.git"
  git init -q -b development "$SB/main"
  git -C "$SB/main" config user.email "test@example.com"
  git -C "$SB/main" config user.name "test"
  git -C "$SB/main" config commit.gpgsign false
  echo base > "$SB/main/README"
  git -C "$SB/main" add README
  git -C "$SB/main" commit -qm "base"
  git -C "$SB/main" remote add origin "$SB/origin.git"
  git -C "$SB/main" push -q -u origin development

  git -C "$SB/main" branch "$BRANCH" development
  git -C "$SB/main" worktree add -q "$SB/wt" "$BRANCH"
  echo feature > "$SB/wt/feature"
  git -C "$SB/wt" add feature
  git -C "$SB/wt" commit -qm "task work"
}

# --- scenario helpers -------------------------------------------------------

push_branch() { git -C "$SB/main" push -q origin "$BRANCH"; }

merge_into_development() { # make development fully contain the task branch
  git -C "$SB/main" switch -q development
  git -C "$SB/main" merge -q --ff-only "$BRANCH"
}

push_development() { git -C "$SB/main" push -q origin development; }

stale_remote_tracking_ref() { # origin/<branch> ref without the branch on origin
  git -C "$SB/main" update-ref "refs/remotes/origin/$BRANCH" "$(git -C "$SB/main" rev-parse "$BRANCH")"
}

local_branch_exists()  { git -C "$SB/main" show-ref --verify --quiet "refs/heads/$BRANCH"; }
remote_branch_exists() { git -C "$SB/main" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; }

run_retire() {
  RET_OUT=$("$RETIRE" "$TASK" "$SB/main" "$@" 2>&1)
  RET_RC=$?
}

make_task_scratch() {
  mkdir -p "$SB/main/$SCRATCH_DIR/tasks" "$SB/main/$SCRATCH_DIR/reports"
  printf 'brief\n' > "$SB/main/$SCRATCH_DIR/tasks/$TASK.md"
  printf 'report\n' > "$SB/main/$SCRATCH_DIR/reports/$TASK.md"
}

expect_no_treehouse_return() {
  if grep -q '^return$' "$STUB_TREEHOUSE_LOG"; then
    fail "treehouse return was called: $(cat "$STUB_TREEHOUSE_LOG")"
  fi
}

expect_no_tmux_kill() {
  if grep -q '^kill-session$' "$STUB_TMUX_LOG"; then
    fail "tmux session was killed: $(cat "$STUB_TMUX_LOG")"
  fi
}

expect_rc0() { [ "$RET_RC" -eq 0 ] || fail "expected exit 0, got $RET_RC: $RET_OUT"; }
expect_rc1() { [ "$RET_RC" -ne 0 ] || fail "expected non-zero exit: $RET_OUT"; }
expect_out() { printf '%s' "$RET_OUT" | grep -q -- "$1" || fail "output lacks '$1': $RET_OUT"; }

# ---------------------------------------------------------------------------
# Tests — one per [REQ-n]
# ---------------------------------------------------------------------------

t_req1_local_merged_deleted() {
  setup
  merge_into_development
  push_development            # tip published via origin/development
  run_retire
  expect_rc0
  local_branch_exists && fail "local branch still exists"
  expect_out "deleted local branch $BRANCH"
}

t_req2_local_unmerged_kept() {
  setup
  push_branch                 # published, so retirement succeeds
  run_retire
  expect_rc0
  local_branch_exists || fail "unmerged local branch was deleted"
  expect_out "not merged into development; keeping it"
}

t_req3_remote_pr_merged_deleted() {
  setup
  push_branch
  export GH_PR_STATE=merged   # squash-merge: tip is NOT an ancestor of development
  run_retire
  expect_rc0
  remote_branch_exists && fail "remote branch still exists"
  expect_out "deleted remote branch origin/$BRANCH"
}

t_req4_remote_pr_open_kept() {
  setup
  push_branch
  merge_into_development
  push_development            # even fully merged remotely, an open PR keeps it
  export GH_PR_STATE=open
  run_retire
  expect_rc0
  remote_branch_exists || fail "remote branch deleted despite open PR"
  expect_out "has an open PR; keeping it"
}

t_req5_remote_merged_no_pr_deleted() {
  setup
  push_branch
  merge_into_development
  push_development
  export GH_PR_STATE=none
  run_retire
  expect_rc0
  remote_branch_exists && fail "remote branch still exists"
  expect_out "deleted remote branch origin/$BRANCH"
}

t_req6_deletion_error_is_nonfatal() {
  setup
  merge_into_development
  push_development
  stale_remote_tracking_ref    # ref claims the branch exists on origin…
  export GH_PR_STATE=merged    # …gh says the PR is merged, so we try to delete…
  run_retire                   # …but origin does not have it: push --delete fails
  expect_rc0
  expect_out "could not delete remote branch origin/$BRANCH"
}

t_req6_supplementary_gh_failure_nonfatal() {
  setup
  push_branch                  # remote unmerged, gh unavailable
  export GH_PR_FAIL=1
  run_retire
  expect_rc0
  remote_branch_exists || fail "remote branch deleted despite gh failure and no merge evidence"
  expect_out "keeping it"
}

t_req7_no_branch_cleanup_flag() {
  setup
  push_branch
  merge_into_development
  push_development
  run_retire --no-branch-cleanup
  expect_rc0
  local_branch_exists  || fail "local branch deleted despite --no-branch-cleanup"
  remote_branch_exists || fail "remote branch deleted despite --no-branch-cleanup"
}

t_req8_refused_retirement_touches_nothing() {
  setup
  push_branch
  echo dirty >> "$SB/wt/feature"     # uncommitted work → retirement refuses
  run_retire
  expect_rc1
  local_branch_exists  || fail "local branch deleted by a refused retirement"
  remote_branch_exists || fail "remote branch deleted by a refused retirement"
}

t_req_missing_lease_refuses_without_force() {
  setup
  export STUB_LEASE=0 STUB_TMUX_EXISTS=1
  make_task_scratch
  run_retire
  expect_rc1
  expect_out "verify all work is published"
  expect_no_tmux_kill
  expect_no_treehouse_return
  [ -f "$SB/main/$SCRATCH_DIR/tasks/$TASK.md" ] || fail "brief removed by refused retirement"
  [ -f "$SB/main/$SCRATCH_DIR/reports/$TASK.md" ] || fail "report removed by refused retirement"
  local_branch_exists || fail "local branch deleted by refused retirement"
}

t_req_missing_lease_force_retires_without_return() {
  setup
  export STUB_LEASE=0 STUB_TMUX_EXISTS=1
  make_task_scratch
  run_retire --force
  expect_rc0
  expect_out "skipped treehouse return"
  expect_out "branch cleanup skipped"
  grep -q '^kill-session$' "$STUB_TMUX_LOG" || fail "tmux session was not killed"
  expect_no_treehouse_return
  local_branch_exists || fail "local branch was cleaned without a worktree lease"
  [ -e "$SB/wt" ] || fail "worktree directory was changed without a lease"
  [ ! -e "$SB/main/$SCRATCH_DIR/tasks/$TASK.md" ] || fail "brief not removed"
  [ ! -e "$SB/main/$SCRATCH_DIR/reports/$TASK.md" ] || fail "report not removed"
}

t_req_missing_lease_force_keeps_scratch() {
  setup
  export STUB_LEASE=0
  make_task_scratch
  run_retire --force --keep-files
  expect_rc0
  [ -f "$SB/main/$SCRATCH_DIR/tasks/$TASK.md" ] || fail "brief removed despite --keep-files"
  [ -f "$SB/main/$SCRATCH_DIR/reports/$TASK.md" ] || fail "report removed despite --keep-files"
  expect_no_treehouse_return
}

t_req_untrusted_treehouse_status_refuses_force() {
  setup
  export STUB_TMUX_EXISTS=1
  make_task_scratch

  export STUB_STATUS_FAIL=1
  run_retire --force
  expect_rc1
  expect_out "could not read treehouse status"
  expect_no_tmux_kill
  expect_no_treehouse_return
  [ -f "$SB/main/$SCRATCH_DIR/reports/$TASK.md" ] || fail "report removed after status failure"

  export STUB_STATUS_FAIL=0 STUB_STATUS_INVALID=1
  run_retire --force
  expect_rc1
  expect_out "invalid treehouse status JSON"
  expect_no_tmux_kill
  expect_no_treehouse_return
  [ -f "$SB/main/$SCRATCH_DIR/reports/$TASK.md" ] || fail "report removed after invalid JSON"

  export STUB_STATUS_INVALID=0 STUB_STATUS_SHAPE=1
  run_retire --force
  expect_rc1
  expect_out "invalid treehouse status JSON"
  expect_no_tmux_kill
  expect_no_treehouse_return
  [ -f "$SB/main/$SCRATCH_DIR/reports/$TASK.md" ] || fail "report removed after invalid status shape"
}

t_req10_shellcheck_clean() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$RETIRE" || fail "shellcheck reported findings"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run() {
  local name=$1 fn=$2 out
  if out=$( "$fn" 2>&1 ); then
    printf 'ok     %s\n' "$name"
  else
    printf 'NOT OK %s\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  fi
}

run "[REQ-1] delete merged local branch"            t_req1_local_merged_deleted
run "[REQ-2] keep unmerged local branch"            t_req2_local_unmerged_kept
run "[REQ-3] delete remote branch with merged PR"   t_req3_remote_pr_merged_deleted
run "[REQ-4] keep remote branch with open PR"       t_req4_remote_pr_open_kept
run "[REQ-5] delete remote branch merged w/o PR"    t_req5_remote_merged_no_pr_deleted
run "[REQ-6] deletion errors never fail retire"     t_req6_deletion_error_is_nonfatal
run "[REQ-6] gh failure never fails retire"         t_req6_supplementary_gh_failure_nonfatal
run "[REQ-7] --no-branch-cleanup skips cleanup"     t_req7_no_branch_cleanup_flag
run "[REQ-8] refused retirement touches no branches" t_req8_refused_retirement_touches_nothing
run "Refuse missing-lease retirement without changing child state [REQ-1]" t_req_missing_lease_refuses_without_force
run "Force-retire the child without returning an unleased worktree [REQ-2]" t_req_missing_lease_force_retires_without_return
run "Preserve task files during forced missing-lease retirement when requested [REQ-3]" t_req_missing_lease_force_keeps_scratch
run "Refuse forced retirement when treehouse status cannot be trusted [REQ-4]" t_req_untrusted_treehouse_status_refuses_force
run "[REQ-10] shellcheck scripts/sub-retire.sh"     t_req10_shellcheck_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
