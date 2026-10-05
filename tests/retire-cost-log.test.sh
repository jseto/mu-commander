#!/usr/bin/env bash
# Behavioural tests for the retirement cost logging in scripts/sub-retire.sh.
# One test per Scenario in specs/retire-cost-log/retire-cost-log.feature.
#
# Self-contained sandbox following tests/sub-retire.test.sh: a fake origin
# (bare repo), a main checkout with a development branch, a linked task
# worktree, and stub treehouse/tmux/gh binaries first on PATH — no real tmux
# sessions, treehouse pool, or GitHub access is touched. CONVERSATION_LOG_DIR
# is always sandboxed, so no test entry can reach the real conversation log.
#
# SC2317: test functions are invoked indirectly via run; SC2016: stub scripts
# are deliberately single-quoted and expand in the child process.
# shellcheck disable=SC2317,SC2016
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
  export GH_PR_STATE=none GH_PR_FAIL=0
  # Test hygiene: every run writes to the sandboxed log, never the real one.
  export CONVERSATION_LOG_DIR="$SB/logs"
  mkdir -p "$SB/bin"

  cat > "$SB/bin/treehouse" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  status) printf '[{"path":"%s","lease_holder":"%s"}]\n' "$STUB_WT" "$STUB_TASK" ;;
  return)
    shift
    [ "${1:-}" = "--force" ] && shift
    git -C "$1" checkout --detach -q 2>/dev/null || true
    ;;
esac
exit 0
EOS

  cat > "$SB/bin/tmux" <<'EOS'
#!/usr/bin/env bash
# No tmux session ever exists in the sandbox.
[ "$1" = "has-session" ] && exit 1
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

  AGENT_DIR="$SB/main/tmp/pi-sub/agent-dirs/$TASK"
}

# --- scenario helpers -------------------------------------------------------

merge_into_development() {
  git -C "$SB/main" switch -q development
  git -C "$SB/main" merge -q --ff-only "$BRANCH"
}
push_development() { git -C "$SB/main" push -q origin development; }

# Seed pi session records (assistant messages with usage costs) for a task,
# mirroring <agent-dir>/sessions/<cwd-slug>/<session>.jsonl.
seed_session_cost() { # $1=task, rest=per-message costs
  local task=$1 dir f c
  shift
  dir="$SB/main/tmp/pi-sub/agent-dirs/$task/sessions/--fake-cwd--"
  mkdir -p "$dir"
  f="$dir/2026-09-26T00-00-00-000Z_seed0000-0000-0000-0000-000000000000.jsonl"
  : > "$f"
  for c in "$@"; do
    printf '%s\n' \
      "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"usage\":{\"cost\":{\"total\":$c}}}}" \
      >> "$f"
  done
}

run_retire() { # stdout/stderr captured separately; RC in RET_RC
  local rc=0
  RET_OUT=$("$RETIRE" "$TASK" "$SB/main" 2>"$SB/err") || rc=$?
  RET_RC=$rc
  RET_ERR=$(<"$SB/err")
}

log_files()  { find "$SB/logs" -type f -name '*.log' 2>/dev/null; }
log_entries() {
  local f
  for f in "$SB/logs"/*.log; do
    [ -f "$f" ] || continue
    cat "$f"
  done
  return 0
}

expect_rc0() { [ "$RET_RC" -eq 0 ] || fail "expected exit 0, got $RET_RC: out=$RET_OUT err=$RET_ERR"; }
expect_rc1() { [ "$RET_RC" -ne 0 ] || fail "expected non-zero exit: $RET_OUT $RET_ERR"; }
expect_out() { printf '%s' "$RET_OUT" | grep -qF -- "$1" || fail "stdout lacks '$1': $RET_OUT"; }
expect_err() { printf '%s' "$RET_ERR" | grep -qF -- "$1" || fail "stderr lacks '$1': $RET_ERR"; }

# ---------------------------------------------------------------------------
# Tests — one per [REQ-n]
# ---------------------------------------------------------------------------

t_req1_log_retirement_with_cost() {
  setup
  merge_into_development
  push_development
  seed_session_cost "$TASK" 0.1 0.05
  run_retire
  expect_rc0
  local entries
  entries=$(log_entries)
  printf '%s' "$entries" | grep -qP '\toperation\t' \
    || fail "conversation log lacks an operation entry: $entries"
  printf '%s' "$entries" | grep -qF "retired $TASK" \
    || fail "entry does not name the retirement: $entries"
  printf '%s' "$entries" | grep -qF 'session cost: $0.1500' \
    || fail "entry lacks the total session cost: $entries"
}

t_req2_total_only_own_records() {
  setup
  merge_into_development
  push_development
  seed_session_cost "$TASK" 0.1
  seed_session_cost other-task 5.0     # another child's sessions: must not count
  run_retire
  expect_rc0
  local entries
  entries=$(log_entries)
  printf '%s' "$entries" | grep -qF 'session cost: $0.1000' \
    || fail "logged cost is not this task's sum only: $entries"
  printf '%s' "$entries" | grep -qF '$5.0000' \
    && fail "another task's cost leaked into the entry: $entries"
  return 0
}

t_req3_cost_captured_before_records_removed() {
  setup
  merge_into_development
  push_development
  seed_session_cost "$TASK" 0.25
  run_retire
  expect_rc0
  [ ! -d "$AGENT_DIR" ] || fail "agent dir (session records) should be removed on retire"
  printf '%s' "$(log_entries)" | grep -qF 'session cost: $0.2500' \
    || fail "logged entry lost the cost captured before cleanup"
}

t_req4_missing_cost_source_warns_and_logs_unknown() {
  setup
  merge_into_development
  push_development
  # no session records at all
  run_retire
  expect_rc0
  expect_err "no readable session cost"
  local entries
  entries=$(log_entries)
  printf '%s' "$entries" | grep -qF "retired $TASK | session cost: unknown" \
    || fail "entry should record the cost as unknown: $entries"
}

t_req5_log_failure_never_fails_retire() {
  setup
  merge_into_development
  push_development
  seed_session_cost "$TASK" 0.5
  : > "$SB/notadir"                    # parent of CONVERSATION_LOG_DIR is a file
  export CONVERSATION_LOG_DIR="$SB/notadir/logs"
  run_retire
  expect_rc0
  expect_err "could not append retirement of '$TASK' to the conversation log"
  expect_out "retired task '$TASK'"     # retirement itself still completed
}

t_req6_refused_retirement_logs_nothing() {
  setup
  seed_session_cost "$TASK" 0.75
  echo dirty >> "$SB/wt/feature"        # uncommitted work → retirement refuses
  run_retire
  expect_rc1
  [ -z "$(log_files)" ] || fail "conversation log gained an entry despite refusal"
}

t_req8_shellcheck_clean() {
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

run "[REQ-1] log a successful retirement with its session cost"  t_req1_log_retirement_with_cost
run "[REQ-2] total only the retiring child's own records"        t_req2_total_only_own_records
run "[REQ-3] capture cost before records are removed"            t_req3_cost_captured_before_records_removed
run "[REQ-4] warn when the session cost source is missing"       t_req4_missing_cost_source_warns_and_logs_unknown
run "[REQ-5] log failure never fails retire"                     t_req5_log_failure_never_fails_retire
run "[REQ-6] refused retirement logs nothing"                    t_req6_refused_retirement_logs_nothing
run "[REQ-8] shellcheck scripts/sub-retire.sh"                   t_req8_shellcheck_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
