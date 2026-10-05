#!/usr/bin/env bash
# Behavioural tests for the child task-levels feature (config-driven
# resolve_child_launch_flags, pi_launch_command, thinking/trust inheritance,
# sub-spawn flag parsing).
# One test per Scenario in specs/child-task-levels/child-task-levels.feature.
#
# Hermetic by construction: resolver tests clear SUB_LEVEL/SUB_MODEL/
# SUB_THINKING/SUB_LEVELS_CONFIG from the environment and re-add exactly what
# the scenario needs. Level resolution is driven by a fixture config written
# under $SCRATCH — the shipped root config.json is never the subject under
# test (tests never assert document/config contents).
# The inheritance test redirects $HOME to a scratch fixture, like
# tests/sub-common.test.sh, so no real ~/.pi state is read or touched.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON=${SUB_COMMON_UNDER_TEST:-$ROOT/scripts/_sub-common.sh}
SPAWN=${SUB_SPAWN_UNDER_TEST:-$ROOT/scripts/sub-spawn.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

jq_ok() { command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not on PATH\n' >&2; return 0; }; }

# Level-resolution fixture: the resolver is driven by this file, never by the
# shipped root config.json (tests never assert shipped config contents).
LEVELS_FIXTURE="$SCRATCH/levels.json"
cat > "$LEVELS_FIXTURE" <<'JSON'
{
  "taskLevels": {
    "default": "standard",
    "levels": {
      "easy":     { "model": "fixture/easy",     "thinking": "high" },
      "standard": { "model": "fixture/standard", "thinking": "medium" },
      "hard":     { "model": "fixture/hard",     "thinking": "max" }
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Harness: resolve <level> <model> <thinking> [ENV=VALUE ...]
# Runs resolve_child_launch_flags with SUB_* cleared, plus the given extras.
# Sets: RC, OUT (stdout), RERR (stderr).
# ---------------------------------------------------------------------------
resolve() {
  local level=$1 model=$2 thinking=$3
  shift 3
  local args
  args=$(printf '%q ' "$level" "$model" "$thinking")
  RC=0
  OUT=$(env -u SUB_LEVEL -u SUB_MODEL -u SUB_THINKING -u SUB_LEVELS_CONFIG \
        "$@" bash -c "source '$COMMON'; resolve_child_launch_flags $args" \
        2>"$SCRATCH/stderr") || RC=$?
  RERR=$(cat "$SCRATCH/stderr")
}

# launch <flags> — pi_launch_command with a fixed bin/task/kickoff. Sets: RC, OUT.
launch() {
  local kickoff="Read the task brief at /tmp/x.md and complete it."
  RC=0
  OUT=$(bash -c "source '$COMMON'; pi_launch_command pi demo $(printf '%q' "$1") $(printf '%q' "$kickoff")") \
    || RC=$?
  LAUNCH_KICKOFF=$kickoff
}

# spawn_bad <arg...> — run sub-spawn with the args, no work must happen.
# Sets: RC, RERR (stderr).
spawn_bad() {
  RC=0
  env -u SUB_LEVEL -u SUB_MODEL -u SUB_THINKING \
    bash "$SPAWN" "$@" >/dev/null 2>"$SCRATCH/stderr" || RC=$?
  RERR=$(cat "$SCRATCH/stderr")
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

t_req2_named_levels_select_their_mapping() {
  jq_ok || return 0
  resolve easy "" "" SUB_LEVELS_CONFIG="$LEVELS_FIXTURE"
  [ "$RC" -eq 0 ] || fail "expected exit 0, got $RC ($RERR)"
  [ "$OUT" = "--model fixture/easy --thinking high" ] \
    || fail "easy should resolve to fixture/easy @ high, got: $OUT"
  resolve hard "" "" SUB_LEVELS_CONFIG="$LEVELS_FIXTURE"
  [ "$OUT" = "--model fixture/hard --thinking max" ] \
    || fail "hard should resolve to fixture/hard @ max, got: $OUT"
}

t_req3_explicit_flags_beat_the_level_mapping() {
  jq_ok || return 0
  resolve "" "" low SUB_LEVELS_CONFIG="$LEVELS_FIXTURE"
  [ "$OUT" = "--model fixture/standard --thinking low" ] \
    || fail "thinking flag should keep the default level's model, got: $OUT"
  resolve "" custom/m "" SUB_LEVELS_CONFIG="$LEVELS_FIXTURE"
  [ "$OUT" = "--model custom/m --thinking medium" ] \
    || fail "model flag should keep the default level's thinking, got: $OUT"
}

t_req4_env_overrides_and_flag_precedence() {
  jq_ok || return 0
  resolve "" "" "" SUB_LEVELS_CONFIG="$LEVELS_FIXTURE" SUB_LEVEL=easy
  [ "$OUT" = "--model fixture/easy --thinking high" ] \
    || fail "SUB_LEVEL=easy should win over the default level, got: $OUT"
  resolve "" "" "" SUB_LEVELS_CONFIG="$LEVELS_FIXTURE" SUB_LEVEL=easy SUB_MODEL=env/m
  [ "$OUT" = "--model env/m --thinking high" ] \
    || fail "SUB_MODEL should win over the level mapping, got: $OUT"
  resolve "" flag/m "" SUB_LEVELS_CONFIG="$LEVELS_FIXTURE" SUB_LEVEL=easy SUB_MODEL=env/m
  [ "$OUT" = "--model flag/m --thinking high" ] \
    || fail "--model flag should win over SUB_MODEL, got: $OUT"
}

t_req5_missing_config_degrades_to_no_flags() {
  resolve "" "" "" SUB_LEVELS_CONFIG="$SCRATCH/does-not-exist.json"
  [ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
  [ -z "$OUT" ] || fail "expected no flags, got: $OUT"
  case $RERR in
    *"config.json not found"*) ;;
    *) fail "expected a 'config.json not found' warning, got: $RERR" ;;
  esac
}

t_req6_unknown_level_degrades_to_no_flags() {
  jq_ok || return 0
  resolve bogus "" ""
  [ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
  [ -z "$OUT" ] || fail "expected no flags, got: $OUT"
  case $RERR in
    *"unknown level"*) ;;
    *) fail "expected an 'unknown level' warning, got: $RERR" ;;
  esac
}

t_req7_malformed_config_degrades_to_no_flags() {
  printf '{not valid json' > "$SCRATCH/broken.json"
  resolve "" "" "" SUB_LEVELS_CONFIG="$SCRATCH/broken.json"
  [ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
  [ -z "$OUT" ] || fail "expected no flags, got: $OUT"
  case $RERR in
    *"config.json invalid"*) ;;
    *) fail "expected a 'config.json invalid' warning, got: $RERR" ;;
  esac
}

t_req8_child_settings_inherit_thinking_and_trust_baseline() {
  jq_ok || return 0
  local sb home
  sb=$(mktemp -d "$SCRATCH/case.XXXXXX")
  home=$sb/home
  mkdir -p "$home/.pi/agent"
  cat > "$home/.pi/agent/settings.json" <<'JSON'
{"defaultProvider":"opencode-zen-free","defaultModel":"opencode-zen-free/mimo-v2.6-flash-free","enabledModels":["opencode-zen-free/mimo-v2.6-flash-free"],"defaultThinkingLevel":"high","modelThinkingLevels":{"opencode-zen-free/mimo-v2.6-flash-free":"xhigh"},"defaultProjectTrust":"always"}
JSON
  env HOME="$home" bash -c \
    "source '$COMMON'; prepare_child_agent_dir '$sb/agent-dir'" >/dev/null \
    || fail "prepare_child_agent_dir failed"
  jq -e '.defaultThinkingLevel == "high"
         and .modelThinkingLevels["opencode-zen-free/mimo-v2.6-flash-free"] == "xhigh"
         and .defaultProjectTrust == "always"
         and .defaultModel == "opencode-zen-free/mimo-v2.6-flash-free"
         and (.packages == [])' "$sb/agent-dir/settings.json" >/dev/null \
    || fail "thinking/trust baseline not inherited: $(cat "$sb/agent-dir/settings.json")"
}

t_req9_launch_line_carries_options_ahead_of_kickoff() {
  launch "--model a/b --thinking xhigh"
  [ "$RC" -eq 0 ] || fail "pi_launch_command failed (rc=$RC)"
  local want
  want="pi -n demo --no-extensions --model a/b --thinking xhigh --approve $(printf '%q' "$LAUNCH_KICKOFF")"
  [ "$OUT" = "$want" ] || fail "expected: $want
     got: $OUT"
  launch ""
  want="pi -n demo --no-extensions --approve $(printf '%q' "$LAUNCH_KICKOFF")"
  [ "$OUT" = "$want" ] || fail "expected: $want
     got: $OUT"
}

t_req10_bad_spawn_invocations_die_early() {
  spawn_bad
  [ "$RC" -ne 0 ] || fail "no-arg invocation should fail"
  case $RERR in *"usage:"*) ;; *) fail "expected usage line, got: $RERR" ;; esac
  spawn_bad demo /nonexistent --bogus
  [ "$RC" -ne 0 ] || fail "unknown option should fail"
  case $RERR in *"unknown option"*) ;; *) fail "expected unknown-option error, got: $RERR" ;; esac
  spawn_bad demo /nonexistent --level
  [ "$RC" -ne 0 ] || fail "--level without a value should fail"
  case $RERR in *"--level"*) ;; *) fail "expected --level value error, got: $RERR" ;; esac
}

t_req11_shellcheck_and_bash_n_clean() {
  bash -n "$COMMON" || fail "bash -n reported syntax errors in $COMMON"
  bash -n "$SPAWN" || fail "bash -n reported syntax errors in $SPAWN"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$COMMON" "$SPAWN" || fail "shellcheck reported findings"
}

# [REQ-12] generic guarantee: config.json is a generic root-level file —
# unknown sibling top-level keys must be ignored by level resolution.
t_req12_unknown_sibling_top_level_keys_are_ignored() {
  jq_ok || return 0
  cat > "$SCRATCH/generic.json" <<'JSON'
{
  "notifications": { "channel": "telegram", "quietHours": [22, 7] },
  "taskLevels": {
    "default": "standard",
    "levels": {
      "easy":     { "model": "mimo/free", "thinking": "medium" },
      "standard": { "model": "mimo/free", "thinking": "xhigh" }
    }
  },
  "featureFlags": { "newStream": true }
}
JSON
  resolve "" "" "" SUB_LEVELS_CONFIG="$SCRATCH/generic.json"
  [ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
  [ -z "$RERR" ] || fail "expected no warning, got: $RERR"
  [ "$OUT" = "--model mimo/free --thinking xhigh" ] \
    || fail "unknown sibling keys must be ignored, got: $OUT"
  resolve "" "" "" SUB_LEVELS_CONFIG="$SCRATCH/generic.json" SUB_LEVEL=standard
  [ -z "$RERR" ] || fail "expected no warning for a named level, got: $RERR"
  [ "$OUT" = "--model mimo/free --thinking xhigh" ] \
    || fail "named level must resolve past sibling keys, got: $OUT"
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

run "[REQ-2]  named levels select their configured mapping"        t_req2_named_levels_select_their_mapping
run "[REQ-3]  explicit flags beat the level mapping"               t_req3_explicit_flags_beat_the_level_mapping
run "[REQ-4]  env overrides apply, flags win over env"             t_req4_env_overrides_and_flag_precedence
run "[REQ-5]  missing config degrades to no flags"                 t_req5_missing_config_degrades_to_no_flags
run "[REQ-6]  unknown level degrades to no flags"                  t_req6_unknown_level_degrades_to_no_flags
run "[REQ-7]  malformed config degrades to no flags"               t_req7_malformed_config_degrades_to_no_flags
run "[REQ-8]  child settings inherit thinking/trust baseline"      t_req8_child_settings_inherit_thinking_and_trust_baseline
run "[REQ-9]  launch line carries options ahead of the kickoff"    t_req9_launch_line_carries_options_ahead_of_kickoff
run "[REQ-10] bad spawn invocations die before any work"           t_req10_bad_spawn_invocations_die_early
run "[REQ-11] touched scripts shellcheck-clean"                    t_req11_shellcheck_and_bash_n_clean
run "[REQ-12] unknown sibling top-level keys are ignored"      t_req12_unknown_sibling_top_level_keys_are_ignored

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
