#!/usr/bin/env bash
# Behavioural tests for the child's allowed extensions — the extensions a
# spawned child loads explicitly on its launch line so package-provided model
# providers resolve (specs/child-model-resolution/child-model-resolution.feature).
# One test per Scenario, labels [REQ-n].
#
# Hermetic: every config is a fixture under $SCRATCH, and $HOME is redirected
# to a scratch agent directory with (or without) a fixture npm package, so the
# shipped config.json and the real pi install are never the subject under test.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON=${SUB_COMMON_UNDER_TEST:-$ROOT/scripts/_sub-common.sh}
SPAWN=${SUB_SPAWN_UNDER_TEST:-$ROOT/scripts/sub-spawn.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

jq_ok() { command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not on PATH\n' >&2; return 0; }; }

LAUNCH_KICKOFF="Read the task brief at /tmp/x.md and complete it."

# A user agent directory with one installed npm package and nothing else.
make_home() { # <dir> [<package-name>...]
  local home=$1 pkg
  shift
  mkdir -p "$home/.pi/agent"
  for pkg in "$@"; do
    mkdir -p "$home/.pi/agent/npm/node_modules/$pkg"
    printf '{"name":"%s"}\n' "${pkg##*/}" > "$home/.pi/agent/npm/node_modules/$pkg/package.json"
  done
  printf '%s\n' "$home"
}

HOME_FIX=$(make_home "$SCRATCH/home" fixture-pkg)

# Fixture levels configs — the shipped config.json is never read as the subject
# under test (the resolver is always pointed at one of these).
CFG_NONE="$SCRATCH/none.json"
cat > "$CFG_NONE" <<'JSON'
{ "taskLevels": { "default": "standard",
    "levels": { "standard": { "model": "fixture/model", "thinking": "high" } } } }
JSON
CFG_LIST="$SCRATCH/list.json"
cat > "$CFG_LIST" <<'JSON'
{ "childrenAllowedExtensions": ["npm:fixture-pkg", "/opt/ext/fixture.ts"],
  "taskLevels": { "default": "standard",
    "levels": { "standard": { "model": "fixture/model", "thinking": "high" } } } }
JSON
CFG_UNINSTALLED="$SCRATCH/uninstalled.json"
cat > "$CFG_UNINSTALLED" <<'JSON'
{ "childrenAllowedExtensions": ["npm:not-installed-pkg@1.2.3"] }
JSON
CFG_OTHER="$SCRATCH/other.json"
cat > "$CFG_OTHER" <<'JSON'
{ "childrenAllowedExtensions": ["npm:fixture-pkg"],
  "taskLevels": { "default": "standard",
    "levels": { "standard": { "model": "fixture/model", "thinking": "high" } } } }
JSON
CFG_BROKEN="$SCRATCH/broken.json"
printf '{ not json\n' > "$CFG_BROKEN"
CFG_NOT_ARRAY="$SCRATCH/not-array.json"
printf '{ "childrenAllowedExtensions": "npm:fixture-pkg" }\n' > "$CFG_NOT_ARRAY"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

RC=0; OUT=; RERR=

# launch <flags> [VAR=value ...] — pi_launch_command with a fixed bin, task and
# kickoff, run against a fixture HOME and fixture config. Sets RC/OUT/RERR.
launch() {
  local flags=$1
  local home=${LAUNCH_HOME:-$HOME_FIX}
  shift
  RC=0
  OUT=$(env -u SUB_CHILD_ALLOWED_EXTENSIONS HOME="$home" \
        SUB_LEVELS_CONFIG="$CFG_NONE" "$@" \
        bash -c "source '$COMMON'; pi_launch_command pi demo $(printf '%q' "$flags") $(printf '%q' "$LAUNCH_KICKOFF")") \
        || RC=$?
  RERR=${OUT##*$'\n'}
}

# allowed <VAR=value ...> — the raw resolver output lines.
allowed() { # [VAR=value ...]
  RC=0
  OUT=$(env -u SUB_CHILD_ALLOWED_EXTENSIONS HOME="$HOME_FIX" SUB_LEVELS_CONFIG="$CFG_NONE" "$@" \
        bash -c "source '$COMMON'; resolve_child_allowed_extensions" 2>"$SCRATCH/stderr") || RC=$?
  RERR=$(cat "$SCRATCH/stderr")
}

# launch_with_stderr <flags> [VAR=value ...] — like launch, keeping stderr.
launch_with_stderr() {
  local flags=$1
  shift
  RC=0
  OUT=$(env -u SUB_CHILD_ALLOWED_EXTENSIONS HOME="$HOME_FIX" \
        SUB_LEVELS_CONFIG="$CFG_NONE" "$@" \
        bash -c "source '$COMMON'; pi_launch_command pi demo $(printf '%q' "$flags") $(printf '%q' "$LAUNCH_KICKOFF")" \
        2>"$SCRATCH/stderr") || RC=$?
  RERR=$(cat "$SCRATCH/stderr")
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

# [REQ-37] every configured entry becomes `-e <source>` ahead of the
# model/thinking options and the kickoff.
t_req37_configured_extensions_are_loaded() {
  jq_ok || return 0
  launch "" SUB_LEVELS_CONFIG="$CFG_LIST"
  [ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
  grep -Fq -- "-e $HOME_FIX/.pi/agent/npm/node_modules/fixture-pkg -e /opt/ext/fixture.ts" <<<"$OUT" \
    || fail "both entries must be loaded with -e, got: $OUT"
  grep -Fq -- '--no-extensions' <<<"$OUT" \
    || fail "the isolation switch must remain, got: $OUT"
  # Order: -e options, then the model options, then --approve and the kickoff.
  local line=$OUT
  [[ $line == *"-e /opt/ext/fixture.ts --approve $(printf '%q' "$LAUNCH_KICKOFF")" ]] \
    || fail "the -e options must come before the kickoff, got: $line"

  launch "--model a/b --thinking high" SUB_LEVELS_CONFIG="$CFG_LIST"
  [[ $OUT == *"-e /opt/ext/fixture.ts --model a/b --thinking high --approve"* ]] \
    || fail "the -e options must come before the model options, got: $OUT"
}

# [REQ-38] without the key the line is exactly the one the child always had.
t_req38_no_key_leaves_the_line_unchanged() {
  jq_ok || return 0
  launch "" SUB_LEVELS_CONFIG="$CFG_NONE"
  [ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
  [ "$OUT" = "pi -n demo --no-extensions --approve $(printf '%q' "$LAUNCH_KICKOFF")" ] \
    || fail "the launch line must be unchanged without the key, got: $OUT"
}

# [REQ-39] an installed npm entry loads from its install; an uninstalled one is
# passed to pi verbatim.
t_req39_installed_npm_loads_from_its_install() {
  jq_ok || return 0
  allowed SUB_LEVELS_CONFIG="$CFG_LIST"
  [ "$RC" -eq 0 ] || fail "expected exit 0, got $RC"
  [ "$OUT" = "$HOME_FIX/.pi/agent/npm/node_modules/fixture-pkg
/opt/ext/fixture.ts" ] || fail "installed npm entry must resolve to its install dir, got: $OUT"

  allowed SUB_LEVELS_CONFIG="$CFG_UNINSTALLED"
  [ "$OUT" = "npm:not-installed-pkg@1.2.3" ] \
    || fail "an uninstalled spec must be passed through unchanged, got: $OUT"
}

# [REQ-40] a broken config or a non-array key warns and adds nothing.
t_req40_malformed_config_degrades() {
  jq_ok || return 0
  launch_with_stderr "" SUB_LEVELS_CONFIG="$CFG_BROKEN"
  [ "$RC" -eq 0 ] || fail "a broken config must not fail the launch line, got $RC"
  [ "$OUT" = "pi -n demo --no-extensions --approve $(printf '%q' "$LAUNCH_KICKOFF")" ] \
    || fail "a broken config must add no -e, got: $OUT"
  grep -Fq 'WARNING: config.json invalid' <<<"$RERR" \
    || fail "a broken config must warn on stderr, got: $RERR"

  launch_with_stderr "" SUB_LEVELS_CONFIG="$CFG_NOT_ARRAY"
  [ "$RC" -eq 0 ] || fail "a non-array key must not fail the launch line, got $RC"
  [ "$OUT" = "pi -n demo --no-extensions --approve $(printf '%q' "$LAUNCH_KICKOFF")" ] \
    || fail "a non-array key must add no -e, got: $OUT"
  grep -Fq 'childrenAllowedExtensions is not an array' <<<"$RERR" \
    || fail "a non-array key must warn on stderr, got: $RERR"
}

# [REQ-41] the env override replaces the configured list entirely.
t_req41_env_override_replaces_the_list() {
  jq_ok || return 0
  allowed SUB_LEVELS_CONFIG="$CFG_OTHER" SUB_CHILD_ALLOWED_EXTENSIONS="/env/only.ts"
  [ "$OUT" = "/env/only.ts" ] \
    || fail "the env override must replace the configured list, got: $OUT"

  allowed SUB_LEVELS_CONFIG="$CFG_OTHER" SUB_CHILD_ALLOWED_EXTENSIONS=
  [ -z "$OUT" ] || fail "an empty env override must load nothing, got: $OUT"
}

# [REQ-42] the isolated agent directory still carries no packages of its own.
t_req42_child_agent_dir_stays_isolated() {
  jq_ok || return 0
  local home agent_dir
  home=$(make_home "$SCRATCH/iso-home")
  cat > "$home/.pi/agent/settings.json" <<'JSON'
{ "defaultProvider": "fixture/provider", "defaultModel": "fixture/model",
  "packages": ["npm:fixture-pkg"], "extensions": ["./leak.ts"] }
JSON
  agent_dir="$SCRATCH/iso-agent-dir"
  env -u SUB_CHILD_ALLOWED_EXTENSIONS HOME="$home" \
    bash -c "source '$COMMON'; prepare_child_agent_dir '$agent_dir'" >/dev/null \
    || fail "prepare_child_agent_dir failed"
  jq -e '.packages == []' "$agent_dir/settings.json" >/dev/null \
    || fail "the child settings must keep packages empty: $(cat "$agent_dir/settings.json")"
  jq -e '.extensions == null' "$agent_dir/settings.json" >/dev/null \
    || fail "the child settings must not inherit the configured extensions: $(cat "$agent_dir/settings.json")"

  launch "" SUB_LEVELS_CONFIG="$CFG_OTHER"
  grep -Fq -- '--no-extensions' <<<"$OUT" \
    || fail "the child launch line must keep --no-extensions, got: $OUT"
}

# [REQ-48] bash -n and shellcheck on every shell file this change touches.
t_req48_shellcheck_and_bash_n_clean() {
  local f
  for f in "$COMMON" "$SPAWN" "$ROOT/scripts/main-watch.sh" "${BASH_SOURCE[0]}"; do
    bash -n "$f" || fail "bash -n reported syntax errors in $f"
  done
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$COMMON" "$SPAWN" "$ROOT/scripts/main-watch.sh" "${BASH_SOURCE[0]}" \
    || fail "shellcheck reported findings"
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

run "[REQ-37] configured allowed extensions are loaded"  t_req37_configured_extensions_are_loaded
run "[REQ-38] no key leaves the launch line unchanged"   t_req38_no_key_leaves_the_line_unchanged
run "[REQ-39] installed npm entry loads from install"    t_req39_installed_npm_loads_from_its_install
run "[REQ-40] malformed config degrades with a warning"  t_req40_malformed_config_degrades
run "[REQ-41] env override replaces the list"            t_req41_env_override_replaces_the_list
run "[REQ-42] child agent dir stays isolated"            t_req42_child_agent_dir_stays_isolated
run "[REQ-48] touched scripts shellcheck-clean"          t_req48_shellcheck_and_bash_n_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
