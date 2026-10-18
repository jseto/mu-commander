#!/usr/bin/env bash
# Behavioural tests for the model-agnostic-tests feature: the suite must never
# depend on the model ids or thinking levels the repository's config.json
# happens to name (user directive, 2026-10-18 — the owner retunes that file by
# hand and everything must still pass).
#
# The guard is the mutation, demonstrated rather than claimed: every suite that
# builds or parses a child pi launch line is re-run with SUB_LEVELS_CONFIG
# pointed at a scratch mapping naming a model id and a thinking level that
# exist nowhere in the repository. A suite that had built an expectation out
# of the shipped mapping goes red under it.
#
# One test per Scenario in specs/model-agnostic-tests/model-agnostic-tests.feature
# ([REQ-1]…[REQ-3] are carried by specs/fix-worktree-trust-prompt/test_spawn_trust.sh,
# whose pi stub is the only one that parses a real launch line).
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON=${SUB_COMMON_UNDER_TEST:-$ROOT/scripts/_sub-common.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# The mutated mapping. Its model id exists nowhere else in the repository — the
# suite asserts that below — so it cannot become "already true" the way a
# copied shipped value could.
MUTANT_MODEL="nowhere/guard suite model"
MUTANT_THINKING="nonexistent"
MUTANT_CONFIG="$SCRATCH/mutant-levels.json"
cat > "$MUTANT_CONFIG" <<JSON
{
  "taskLevels": {
    "default": "guarded",
    "levels": {
      "guarded": { "model": "$MUTANT_MODEL", "thinking": "$MUTANT_THINKING" }
    }
  }
}
JSON

# Every suite that builds or parses a child pi launch line: it resolves the
# level mapping into --model/--thinking words, or reads them off a pane. The
# trust harness is in the list for the other half of the same rule: it pins
# its own two mappings and ignores an ambient SUB_LEVELS_CONFIG, so it must
# stay green under one too.
LAUNCH_SUITES="task-levels launch-confirm spawn-base-fallback free-limit-fallback sub-common"
TRUST_HARNESS=specs/fix-worktree-trust-prompt/test_spawn_trust.sh

run_under_mutation() { # <path-to-suite>
  local path=$1 out
  if out=$(env -u SUB_LEVEL -u SUB_MODEL -u SUB_THINKING \
                -u SUB_COMMON_UNDER_TEST -u SUB_SPAWN_UNDER_TEST \
                -u SUB_FALLBACK_UNDER_TEST \
                SUB_LEVELS_CONFIG="$MUTANT_CONFIG" \
                bash "$ROOT/$path" 2>&1); then
    return 0
  fi
  printf '  --- %s under the mutated mapping ---\n%s\n' "$path" "$out" >&2
  return 1
}

# [REQ-4] No suite builds an expectation out of the shipped config.json: each
# one still passes when the level mapping is replaced by a model id and a
# thinking level that exist nowhere in the repository.
t_req4_launch_suites_stay_green_under_a_mutated_mapping() {
  local suite bad=()
  for suite in $LAUNCH_SUITES; do
    [ -f "$ROOT/tests/$suite.test.sh" ] || fail "no such suite: tests/$suite.test.sh"
    run_under_mutation "tests/$suite.test.sh" || bad+=("$suite")
  done
  [ "${#TRUST_HARNESS}" -gt 0 ] || fail "TRUST_HARNESS must name the trust harness"
  run_under_mutation "$TRUST_HARNESS" || bad+=("$TRUST_HARNESS")
  [ "${#bad[@]}" -eq 0 ] \
    || fail "these suites depend on the shipped level mapping: ${bad[*]}"
  return 0
}

# [REQ-4, first half] The canary: the mutation is a live input, not a setting
# every suite happens to ignore. Level resolution must follow
# SUB_LEVELS_CONFIG, and must produce something else without it — otherwise
# the guard above could be green because it moves nothing.
t_req4a_the_mutation_reaches_level_resolution() {
  local under_override without_override want
  printf -v want '%q %q %q %q' --model "$MUTANT_MODEL" --thinking "$MUTANT_THINKING"
  under_override=$(env -u SUB_LEVEL -u SUB_MODEL -u SUB_THINKING \
    SUB_LEVELS_CONFIG="$MUTANT_CONFIG" \
    bash -c "source '$COMMON'; resolve_child_launch_flags '' '' ''" 2>/dev/null)
  [ "$under_override" = "$want" ] \
    || fail "SUB_LEVELS_CONFIG did not reach resolve_child_launch_flags:
expected: $want
got:      $under_override"
  without_override=$(env -u SUB_LEVEL -u SUB_MODEL -u SUB_THINKING \
    -u SUB_LEVELS_CONFIG \
    bash -c "source '$COMMON'; resolve_child_launch_flags '' '' ''" 2>/dev/null)
  [ -n "$without_override" ] \
    || fail "the shipped mapping resolved to no options at all; the canary has nothing to differ from"
  [ "$without_override" != "$under_override" ] \
    || fail "the shipped mapping and the mutated one resolved identically, so the guard cannot bite"
  return 0
}

# [REQ-4, second half] The mutation is only a test if the repository really
# knows nothing about it: the made-up model id must be written nowhere else,
# so it cannot be satisfied by a config.json retune or by a fixture copied in.
t_req4b_mutated_model_id_exists_nowhere_else() {
  local hits
  hits=$(grep -rlF -- "$MUTANT_MODEL" "$ROOT" \
           --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tmp \
           2>/dev/null | grep -v "^$ROOT/tests/model-agnostic-tests.test.sh$" || true)
  [ -z "$hits" ] \
    || fail "the mutated model id leaked into:
$hits"
  return 0
}

# [REQ-5] The changed scripts and tests are shellcheck- and bash -n-clean.
t_req5_changed_scripts_are_shellcheck_clean() {
  local f
  for f in tests/model-agnostic-tests.test.sh \
           tests/task-levels.test.sh \
           tests/sub-common.test.sh \
           specs/fix-worktree-trust-prompt/test_spawn_trust.sh; do
    bash -n "$ROOT/$f" || fail "bash -n reported syntax errors in $f"
  done
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck -S warning \
    "$ROOT/tests/model-agnostic-tests.test.sh" \
    "$ROOT/tests/task-levels.test.sh" \
    "$ROOT/tests/sub-common.test.sh" \
    "$ROOT/specs/fix-worktree-trust-prompt/test_spawn_trust.sh" \
    || fail "shellcheck reported findings"
  return 0
}

run() {
  local name=$1 fn=$2 out
  if out=$( "$fn" 2>&1 ); then
    printf 'ok     %s\n' "$name"
  else
    printf 'NOT OK %s\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  fi
}

run "[REQ-4] launch-line suites stay green under a mutated mapping" t_req4_launch_suites_stay_green_under_a_mutated_mapping
run "[REQ-4] the mutated mapping really reaches level resolution"    t_req4a_the_mutation_reaches_level_resolution
run "[REQ-4] the mutated model id exists nowhere else in the repo"     t_req4b_mutated_model_id_exists_nowhere_else
run "[REQ-5] changed scripts shellcheck- and bash -n-clean"          t_req5_changed_scripts_are_shellcheck_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'