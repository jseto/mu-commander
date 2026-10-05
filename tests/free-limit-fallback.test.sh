#!/usr/bin/env bash
# shellcheck disable=SC1090  # sources the implementation under test by variable path
# Behavioural tests for the free-limit fallback feature: the taskLevels
# fallback resolvers, the pane probes, and scripts/sub-fallback.sh.
# One test per Scenario in
# specs/free-limit-fallback/free-limit-fallback.feature.
#
# The resolver tests source scripts/_sub-common.sh with SUB_FALLBACK_*/
# SUB_LEVELS_CONFIG cleared (like tests/task-levels.test.sh); a test that
# needs a config writes a fixture under $SCRATCH or $SB — the shipped root
# config.json is never the subject under test. The pane tests
# sandbox a stateful fake tmux binary placed first on PATH — pane/footer/
# session state lives in a per-test temp dir and no real tmux session is ever
# touched.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON=${SUB_COMMON_UNDER_TEST:-$ROOT/scripts/_sub-common.sh}
FALLBACK=${SUB_FALLBACK_UNDER_TEST:-$ROOT/scripts/sub-fallback.sh}
TASK=demo-task
SESS="pi-$TASK"

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }
jq_ok() { command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not on PATH\n' >&2; return 0; }; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# Resolver fixture: the shipped root config.json is never the subject under
# test, so resolver tests that need a config point at this fixture.
FB_FIXTURE="$SCRATCH/fixture-config.json"
cat > "$FB_FIXTURE" <<'JSON'
{"taskLevels":{"default":"standard","fallbackModel":"opencode-go/mimo-v2.6-flash","fallbackThinking":"high","levels":{"standard":{"model":"m","thinking":"high"}}}}
JSON

# ---------------------------------------------------------------------------
# Config-resolver harness
# ---------------------------------------------------------------------------

# resolve_fallback <fn> [ENV=VALUE ...]
# Sources the common file with the fallback env overrides and the config path
# cleared, applies the extras, and calls <fn>.
# Sets: RC, OUT (stdout), RERR (stderr).
resolve_fallback() {
  local fn=$1
  shift
  RC=0
  OUT=$(env -u SUB_FALLBACK_MODEL -u SUB_FALLBACK_THINKING -u SUB_LEVELS_CONFIG \
        "$@" bash -c "source '$COMMON'; $fn" 2>"$SCRATCH/stderr") || RC=$?
  RERR=$(cat "$SCRATCH/stderr")
}

# ---------------------------------------------------------------------------
# Fake-tmux sandbox
# ---------------------------------------------------------------------------

setup() {
  SB=$(mktemp -d)
  trap 'rm -rf "$SB"' EXIT
  export FAKE_TMUX_DIR="$SB/tmux-state"
  mkdir -p "$SB/bin" "$FAKE_TMUX_DIR"

  cat > "$SB/bin/tmux" <<'EOS'
#!/usr/bin/env bash
# Stateful fake tmux for sub-fallback tests.
#   $FAKE_TMUX_DIR/pane   transcript text (accumulated)
#   $FAKE_TMUX_DIR/footer status-bar lines, appended after the transcript
#   $FAKE_TMUX_DIR/log    every send-keys invocation
#   current-model/current-level: applied switch state
#   pending-model/pending-thinking: last literal /model, /thinking send
# FAKE_TMUX_MODE:
#   ok         literal text lands; Enter submits and applies pending switches
#   popup      first Enter only dismisses pi's completion popup (pane changes,
#              no submission); a later Enter submits and applies
#   no-apply   literal text lands; Enter submits but never updates the footer
#   drop-enter literal text lands; Enter is swallowed
#   drop-text  literal text never lands
#   reject-thinking  Enter applies the pending /model but answers a pending
#              /thinking with pi's validation error (Error: Unknown thinking
#              level …) instead of changing the level; C-u does nothing
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S"
[ -f "$S/sessions" ] || : > "$S/sessions"
[ -f "$S/log" ]      || : > "$S/log"
[ -f "$S/pane" ]     || : > "$S/pane"
[ -f "$S/footer" ]   || {
  printf '%s\n' '/home/tester/repo (task/demo)' > "$S/footer"
  printf '%s\n' '0.0%/200k (auto)          (opencode-zen-free) mimo-v2.6-flash-free • xhigh' >> "$S/footer"
}

session_exists() {
  local t=${1#=}
  t=${t%:}
  grep -Fxq -- "$t" "$S/sessions"
}

rewrite_footer() {
  local model id provider level
  model=$(cat "$S/current-model" 2>/dev/null || true)
  [ -n "$model" ] || return 0
  id=${model##*/}
  provider=${model%%/*}
  level=$(cat "$S/current-level" 2>/dev/null || true)
  {
    printf '%s\n' '/home/tester/repo (task/demo)'
    printf '0.0%%/1.0M (auto)          (%s) %s • %s\n' "$provider" "$id" "${level:-max}"
  } > "$S/footer"
}

apply_pending() {
  printf '\n<<submitted>>\n' >> "$S/pane"
  if [ -s "$S/pending-model" ]; then
    cp "$S/pending-model" "$S/current-model"
    rm -f "$S/pending-model"
    # Pi clamps the session's thinking level to the new model's range on
    # /model; FAKE_TMUX_LEVEL_AFTER_MODEL models that (default max — an xhigh
    # child landing on a model whose ceiling is max).
    if [ -n "${FAKE_TMUX_LEVEL_AFTER_MODEL:-}" ]; then
      printf '%s' "$FAKE_TMUX_LEVEL_AFTER_MODEL" > "$S/current-level"
    fi
  fi
  if [ -s "$S/pending-thinking" ]; then
    cp "$S/pending-thinking" "$S/current-level"
    rm -f "$S/pending-thinking"
  fi
  rewrite_footer
}

case "${1:-}" in
  has-session)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    session_exists "$target"
    ;;
  send-keys)
    shift
    printf 'send-keys %s\n' "$*" >> "$S/log"
    literal=0 text=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) text=$1; shift ;;
      esac
    done
    mode=${FAKE_TMUX_MODE:-ok}
    if [ "$literal" = 1 ]; then
      [ "$mode" = drop-text ] || printf '%s' "$text" >> "$S/pane"
      case "$text" in
        '/model '*)    printf '%s' "${text#/model }"    > "$S/pending-model" ;;
        '/thinking '*) printf '%s' "${text#/thinking }" > "$S/pending-thinking" ;;
      esac
    else
      case "$mode" in
        ok) apply_pending ;;
        popup)
          # The first Enter after a /model line is eaten by the completion
          # popup: the pane changes (so tmux_send_line believes it landed)
          # without the command being submitted. Later Enters submit.
          if [ -f "$S/popup-dismissed" ]; then
            apply_pending
          else
            : > "$S/popup-dismissed"
            printf '\n   [completion popup]\n' >> "$S/pane"
          fi
          ;;
        no-apply)   printf '\n<<submitted>>\n' >> "$S/pane" ;;
        drop-enter) printf '\n' >> "$S/pane" ;;
        drop-text)  : ;;
        reject-thinking)
          # Only Enter changes anything; C-u (composer cleanup) is a no-op.
          if [ "$text" = Enter ]; then
            printf '\n<<submitted>>\n' >> "$S/pane"
            if [ -s "$S/pending-model" ]; then
              cp "$S/pending-model" "$S/current-model"
              rm -f "$S/pending-model"
              if [ -n "${FAKE_TMUX_LEVEL_AFTER_MODEL:-}" ]; then
                printf '%s' "$FAKE_TMUX_LEVEL_AFTER_MODEL" > "$S/current-level"
              fi
            fi
            if [ -s "$S/pending-thinking" ]; then
              lvl=$(cat "$S/pending-thinking")
              rm -f "$S/pending-thinking"
              printf 'Error: Unknown thinking level "%s". Available levels: off, minimal, low, medium, high.\n' "$lvl" >> "$S/pane"
            fi
            rewrite_footer
          fi
          ;;
      esac
    fi
    ;;
  capture-pane)
    cat "$S/pane"
    cat "$S/footer"
    ;;
  *)
    exit 0
    ;;
esac
EOS
  chmod +x "$SB/bin/tmux"
  export PATH="$SB/bin:$PATH"

  : > "$FAKE_TMUX_DIR/sessions"
  : > "$FAKE_TMUX_DIR/pane"
  # Default status bar: the free model whose id extends the shipped fallback id.
  {
    printf '%s\n' '/home/tester/repo (task/demo)'
    printf '%s\n' '0.0%/200k (auto)          (opencode-zen-free) mimo-v2.6-flash-free • xhigh'
  } > "$FAKE_TMUX_DIR/footer"
  export FAKE_TMUX_MODE=ok
  # Pin a fixture config and the timing so no ambient environment leaks into
  # the sandbox. The fallback values under test come from this fixture, never
  # from the shipped root config.json (tests never assert config contents).
  cat > "$SB/fixture-config.json" <<'JSON'
{
  "taskLevels": {
    "default": "standard",
    "fallbackModel": "opencode-go/mimo-v2.6-flash",
    "fallbackThinking": "high",
    "levels": {
      "standard": { "model": "opencode-zen-free/mimo-v2.6-flash-free", "thinking": "high" }
    }
  }
}
JSON
  export SUB_LEVELS_CONFIG="$SB/fixture-config.json"
  unset SUB_FALLBACK_MODEL SUB_FALLBACK_THINKING
  unset FAKE_TMUX_LEVEL_AFTER_MODEL
  export FALLBACK_PROBE_ATTEMPTS=2
  export FALLBACK_PROBE_DELAY=0
}

add_session() { printf '%s\n' "$1" >> "$FAKE_TMUX_DIR/sessions"; }

seed_error() {
  cat >> "$FAKE_TMUX_DIR/pane" <<'ERR'

 hi

 Error: 429: {"type":"FreeUsageLimitError","message":"Rate limit exceeded.
 Please try again later."}
 If this looks like a pi bug, /bug sends a report to the developers.
ERR
}

# The second free-provider failure (observed in production): pi's
# auto-compaction/summarization calls rejected with HTTP 403 FreeTierError,
# which wedges the child exactly like the 429 quota does. The 403 sits on
# its own line; the JSON error type follows on the next.
seed_free_tier_error() {
  cat >> "$FAKE_TMUX_DIR/pane" <<'ERR'

 hi

 Auto-compaction failed: Turn prefix summarization failed: 403:
{"type":"FreeTierError","message":"OpenCode's free tier can only be used from within OpenCode"}
Context overflow recovery failed: Turn prefix summarization failed: 403:
{"type":"FreeTierError","message":"OpenCode's free tier can only be used from within OpenCode"}
ERR
}

count_literal() { grep -c -- ' -l ' "$FAKE_TMUX_DIR/log"; }
count_enter()   { grep -c -- ' Enter$' "$FAKE_TMUX_DIR/log"; }

run_fallback() {
  FB_OUT=$("$FALLBACK" "$@" 2>"$SB/err"); FB_RC=$?
  FB_ERR=$(cat "$SB/err")
}

expect_rc0()        { [ "$FB_RC" -eq 0 ] || fail "expected exit 0, got $FB_RC: out=$FB_OUT err=$FB_ERR"; }
expect_rc_nonzero() { [ "$FB_RC" -ne 0 ] || fail "expected non-zero exit: out=$FB_OUT"; }
expect_out()        { printf '%s' "$FB_OUT" | grep -q -- "$1" || fail "stdout lacks '$1': $FB_OUT"; }
expect_not_out()    { ! printf '%s' "$FB_OUT" | grep -q -- "$1" || fail "stdout must not contain '$1': $FB_OUT"; }
expect_err()        { printf '%s' "$FB_ERR" | grep -q -- "$1" || fail "stderr lacks '$1': $FB_ERR"; }
expect_not_err()    { ! printf '%s' "$FB_ERR" | grep -q -- "$1" || fail "stderr must not contain '$1': $FB_ERR"; }

# ---------------------------------------------------------------------------
# Scenarios — one test per [REQ-n]
# ---------------------------------------------------------------------------

t_req2_env_overrides_win() {
  resolve_fallback resolve_fallback_model \
    SUB_LEVELS_CONFIG="$FB_FIXTURE" SUB_FALLBACK_MODEL=custom/fb
  [ "$RC" -eq 0 ] || fail "exit $RC: $RERR"
  [ "$OUT" = "custom/fb" ] || fail "env model must win, got: $OUT"
  resolve_fallback resolve_fallback_thinking \
    SUB_LEVELS_CONFIG="$FB_FIXTURE" SUB_FALLBACK_THINKING=low
  [ "$RC" -eq 0 ] || fail "exit $RC: $RERR"
  [ "$OUT" = "low" ] || fail "env thinking must win, got: $OUT"
}

t_req3_absent_or_unreadable_degrades_to_none() {
  cat > "$SCRATCH/no-fallback.json" <<'JSON'
{"taskLevels":{"default":"standard","levels":{"standard":{"model":"m","thinking":"high"}}}}
JSON
  resolve_fallback resolve_fallback_model SUB_LEVELS_CONFIG="$SCRATCH/no-fallback.json"
  [ "$RC" -eq 0 ] || fail "absent key must exit 0, got $RC"
  [ -z "$OUT" ] || fail "absent key must resolve to nothing, got: $OUT"
  [ -z "$RERR" ] || fail "absent key must be silent, got: $RERR"
  resolve_fallback resolve_fallback_thinking SUB_LEVELS_CONFIG="$SCRATCH/no-fallback.json"
  [ "$RC" -eq 0 ] || fail "absent thinking must exit 0, got $RC"
  [ -z "$OUT" ] || fail "absent thinking must resolve to nothing, got: $OUT"

  resolve_fallback resolve_fallback_model SUB_LEVELS_CONFIG="$SCRATCH/missing.json"
  [ "$RC" -eq 0 ] || fail "missing config must exit 0, got $RC"
  [ -z "$OUT" ] || fail "missing config must resolve to nothing, got: $OUT"

  printf '{not valid json' > "$SCRATCH/broken.json"
  resolve_fallback resolve_fallback_model SUB_LEVELS_CONFIG="$SCRATCH/broken.json"
  [ "$RC" -eq 0 ] || fail "malformed config must exit 0, got $RC"
  [ -z "$OUT" ] || fail "malformed config must resolve to nothing, got: $OUT"
}

t_req4_free_limit_error_detected() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  (source "$COMMON"; pane_has_free_limit_error "$TASK" 50) \
    || fail "the FreeUsageLimitError signature must be detected"
  : > "$FAKE_TMUX_DIR/pane"
  printf '%s\n' 'everything is fine, no provider errors here' > "$FAKE_TMUX_DIR/pane"
  if (source "$COMMON"; pane_has_free_limit_error "$TASK" 50); then
    fail "a clean pane must not be reported as an error"
  fi
}

t_req5_no_error_is_a_noop() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  printf '%s\n' 'working normally, no provider errors here' > "$FAKE_TMUX_DIR/pane"
  run_fallback "$TASK"
  expect_rc0
  [ "$(count_literal)" -eq 0 ] || fail "no keys may be sent without an error: $(cat "$FAKE_TMUX_DIR/log")"
  [ "$(count_enter)" -eq 0 ] || fail "no Enter may be sent without an error: $(cat "$FAKE_TMUX_DIR/log")"
  expect_out "no model switch performed"
}

t_req6_detected_error_switches_to_fallback() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  run_fallback "$TASK"
  expect_rc0
  grep -q -- '-l /model opencode-go/mimo-v2.6-flash' "$FAKE_TMUX_DIR/log" \
    || fail "the model switch was not sent: $(cat "$FAKE_TMUX_DIR/log")"
  # The footer starts on the free model whose id extends the fallback id:
  # assert the switched id as a delimited token, not a substring.
  grep -qF -- '(opencode-go) mimo-v2.6-flash' "$FAKE_TMUX_DIR/footer" \
    || fail "the fake footer never showed the switched model: $(cat "$FAKE_TMUX_DIR/footer")"
  expect_out "switched"
}

# The model switch clamps the session's level to the new model's range. When
# the clamp already lands on fallbackThinking, nothing may be sent; when it
# does not, /thinking is sent and confirmed against the status bar.
t_req7_thinking_level_in_effect_after_recovery() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  export FAKE_TMUX_LEVEL_AFTER_MODEL=high
  run_fallback "$TASK"
  expect_rc0
  if grep -q -- '-l /thinking' "$FAKE_TMUX_DIR/log"; then
    fail "an already-effective level must not be re-sent: $(cat "$FAKE_TMUX_DIR/log")"
  fi
  grep -qF -- '• high' "$FAKE_TMUX_DIR/footer" \
    || fail "the status bar does not show the configured level: $(cat "$FAKE_TMUX_DIR/footer")"
  expect_out "already high"

  setup
  add_session "$SESS"
  seed_error
  run_fallback "$TASK"
  expect_rc0
  grep -q -- '-l /thinking high' "$FAKE_TMUX_DIR/log" \
    || fail "the thinking level was not sent: $(cat "$FAKE_TMUX_DIR/log")"
  grep -qF -- '• high' "$FAKE_TMUX_DIR/footer" \
    || fail "the status bar does not show the applied level: $(cat "$FAKE_TMUX_DIR/footer")"
  expect_out "thinking level set to high"
}

# Supplementary (no [REQ-n]): a completion popup can swallow the first Enter,
# so tmux_send_line may report a reaction without a submission. The status-bar
# probe plus the Enter nudge must still recover the child.
t_supp_popup_swallowed_enter_is_recovered() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  export FAKE_TMUX_MODE=popup
  run_fallback "$TASK"
  expect_rc0
  grep -Fq -- "-l /model opencode-go/mimo-v2.6-flash" "$FAKE_TMUX_DIR/log" \
    || fail "the model switch was not sent: $(cat "$FAKE_TMUX_DIR/log")"
  grep -qF -- '(opencode-go) mimo-v2.6-flash' "$FAKE_TMUX_DIR/footer" \
    || fail "the completion popup swallowed the switch without a nudge: $(cat "$FAKE_TMUX_DIR/footer")"
  expect_out "switched"
}

t_req8_unconfirmed_switch_fails_loudly() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  export FAKE_TMUX_MODE=no-apply
  run_fallback "$TASK"
  expect_rc_nonzero
  expect_err "ERROR:"
  expect_err "$SESS"
  expect_err "mimo-v2.6-flash"
  expect_not_out "switched"
  grep -q -- ' C-u' "$FAKE_TMUX_DIR/log" \
    || fail "the composer must be cleared when the switch cannot be confirmed"
}

t_req9_error_without_fallback_sends_nothing() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  cat > "$SB/no-fallback.json" <<'JSON'
{"taskLevels":{"default":"standard","levels":{"standard":{"model":"m","thinking":"high"}}}}
JSON
  export SUB_LEVELS_CONFIG="$SB/no-fallback.json"
  run_fallback "$TASK"
  expect_rc_nonzero
  expect_err "ERROR:"
  expect_err "fallbackModel"
  expect_err "no-fallback.json"
  [ "$(count_literal)" -eq 0 ] || fail "no keys may be sent without a fallback: $(cat "$FAKE_TMUX_DIR/log")"
}

t_req10_already_on_fallback_is_a_noop() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  {
    printf '%s\n' '/home/tester/repo (task/demo)'
    printf '%s\n' '0.0%/1.0M (auto)          (opencode-go) mimo-v2.6-flash • high'
  } > "$FAKE_TMUX_DIR/footer"
  run_fallback "$TASK"
  expect_rc0
  [ "$(count_literal)" -eq 0 ] || fail "no keys may be sent when already on fallback: $(cat "$FAKE_TMUX_DIR/log")"
  expect_out "already on fallback"
}

# [REQ-14] regression for the 2026-09-29 live test: the free model id
# (mimo-v2.6-flash-free) *contains* the configured fallback id
# (mimo-v2.6-flash) as a prefix. A fixed-substring guard read the status bar
# as "already on fallback" and the fallback silently no-op'd while the child
# stayed stuck on the limited model. The boundary rule must send the switch.
t_req14_prefix_collision_is_not_already_on() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  # The sandbox footer starts on (opencode-zen-free) mimo-v2.6-flash-free • xhigh.
  grep -qF -- 'mimo-v2.6-flash-free' "$FAKE_TMUX_DIR/footer" \
    || fail "fixture must start on the free model"
  run_fallback "$TASK"
  expect_rc0
  grep -q -- '-l /model opencode-go/mimo-v2.6-flash' "$FAKE_TMUX_DIR/log" \
    || fail "the prefix id was mistaken for the fallback model: $(cat "$FAKE_TMUX_DIR/log")"
  grep -qF -- '(opencode-go) mimo-v2.6-flash' "$FAKE_TMUX_DIR/footer" \
    || fail "the fake footer never showed the switched model: $(cat "$FAKE_TMUX_DIR/footer")"
  expect_out "switched"
  expect_not_out "already on fallback"
}

# [REQ-15] regression for a stale fallbackThinking: the model switch
# succeeds but the TUI rejects /thinking with Error: Unknown thinking level.
# The switch alone must count as the recovery: exit 0, no success claim for
# the level, a config-problem warning, and no Enter-nudge warn loop.
t_req15_rejected_thinking_degrades_to_model_recovery() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_error
  export FAKE_TMUX_MODE=reject-thinking
  export FAKE_TMUX_LEVEL_AFTER_MODEL=high
  # A fallbackThinking the model does not accept (env override stands in for
  # a config.json where fallbackModel changed and the level was not retuned).
  export SUB_FALLBACK_THINKING=max
  run_fallback "$TASK"
  expect_rc0
  grep -q -- '-l /model opencode-go/mimo-v2.6-flash' "$FAKE_TMUX_DIR/log" \
    || fail "the model switch was not sent: $(cat "$FAKE_TMUX_DIR/log")"
  grep -q -- '-l /thinking max' "$FAKE_TMUX_DIR/log" \
    || fail "the configured level was never attempted: $(cat "$FAKE_TMUX_DIR/log")"
  expect_out "switched"
  expect_not_out "thinking level set"
  expect_err "Unknown thinking level"
  expect_err "fallbackThinking"
  expect_not_err "ERROR:"
  # No warn loop: at most the two verified sends (model + thinking) may have
  # pressed Enter; a rejected command must not be nudged again.
  [ "$(count_enter)" -le 2 ] \
    || fail "the rejected /thinking was nudged in a loop: $(cat "$FAKE_TMUX_DIR/log")"
  grep -q -- ' C-u' "$FAKE_TMUX_DIR/log" \
    || fail "the composer must be cleared after the rejection"
  grep -qF -- '(opencode-go) mimo-v2.6-flash • high' "$FAKE_TMUX_DIR/footer" \
    || fail "the child must end on the switched model: $(cat "$FAKE_TMUX_DIR/footer")"
}

# [REQ-17] regression for the production wedge the helper no-opped on:
# pi's compaction calls rejected with HTTP 403 FreeTierError — a pane with
# no FreeUsageLimitError/429 anywhere, so the old detector answered
# "no FreeUsageLimitError in …" and left the child stuck.
t_req17_free_tier_error_detected() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  seed_free_tier_error
  (source "$COMMON"; pane_has_free_limit_error "$TASK" 50) \
    || fail "the 403 FreeTierError compaction failure must be detected"
  # End to end: the helper must switch instead of no-op'ing.
  run_fallback "$TASK"
  expect_rc0
  grep -q -- '-l /model opencode-go/mimo-v2.6-flash' "$FAKE_TMUX_DIR/log" \
    || fail "the FreeTierError failure was not recovered: $(cat "$FAKE_TMUX_DIR/log")"
  grep -qF -- '(opencode-go) mimo-v2.6-flash' "$FAKE_TMUX_DIR/footer" \
    || fail "the fake footer never showed the switched model: $(cat "$FAKE_TMUX_DIR/footer")"
  expect_out "switched"
  # A healthy pane still reports no failure (never speculative).
  setup
  add_session "$SESS"
  printf '%s\n' 'working normally, no provider errors here' > "$FAKE_TMUX_DIR/pane"
  if (source "$COMMON"; pane_has_free_limit_error "$TASK" 50); then
    fail "a clean pane must not be reported as an error"
  fi
}

# [REQ-18] with two detected failure kinds the user-facing messages must
# describe what the helper actually looks for: the no-switch message names
# both signatures (not only FreeUsageLimitError), and the no-fallback
# failure describes the pane as a free-provider failure. A healthy pane
# must still no-op without a single key press.
t_req18_messages_describe_detected_failures() {
  jq_ok || return 0
  setup
  add_session "$SESS"
  printf '%s\n' 'working normally, no provider errors here' > "$FAKE_TMUX_DIR/pane"
  run_fallback "$TASK"
  expect_rc0
  [ "$(count_literal)" -eq 0 ] || fail "no keys may be sent to a healthy pane: $(cat "$FAKE_TMUX_DIR/log")"
  [ "$(count_enter)" -eq 0 ] || fail "no Enter may be sent to a healthy pane: $(cat "$FAKE_TMUX_DIR/log")"
  expect_out "no model switch performed"
  expect_out "FreeUsageLimitError"
  expect_out "FreeTierError"
  expect_not_out "no FreeUsageLimitError in"

  setup
  add_session "$SESS"
  seed_free_tier_error
  cat > "$SB/no-fallback.json" <<'JSON'
{"taskLevels":{"default":"standard","levels":{"standard":{"model":"m","thinking":"high"}}}}
JSON
  export SUB_LEVELS_CONFIG="$SB/no-fallback.json"
  run_fallback "$TASK"
  expect_rc_nonzero
  expect_err "ERROR:"
  expect_err "fallbackModel"
  expect_err "free-provider failure detected"
  [ "$(count_literal)" -eq 0 ] || fail "no keys may be sent without a fallback: $(cat "$FAKE_TMUX_DIR/log")"
}

t_req11_missing_session_dies() {
  setup
  run_fallback "$TASK"
  expect_rc_nonzero
  expect_err "$SESS"
  expect_err "not running"
}

t_req13_shellcheck_and_bash_n_clean() {
  bash -n "$COMMON" || fail "bash -n reported syntax errors in $COMMON"
  bash -n "$FALLBACK" || fail "bash -n reported syntax errors in $FALLBACK"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$COMMON" "$FALLBACK" || fail "shellcheck reported findings"
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

run "[REQ-2]  env overrides win over the config"             t_req2_env_overrides_win
run "[REQ-3]  absent/unreadable config degrades to none"     t_req3_absent_or_unreadable_degrades_to_none
run "[REQ-4]  free-limit error in the pane is detected"      t_req4_free_limit_error_detected
run "[REQ-5]  no error means no switch"                      t_req5_no_error_is_a_noop
run "[REQ-6]  detected error switches to the fallback"       t_req6_detected_error_switches_to_fallback
run "[REQ-7]  thinking is in effect after the recovery"      t_req7_thinking_level_in_effect_after_recovery
run "[supp]   completion popup swallowing Enter is recovered" t_supp_popup_swallowed_enter_is_recovered
run "[REQ-8]  unconfirmed switch fails loudly"               t_req8_unconfirmed_switch_fails_loudly
run "[REQ-9]  error without a fallback sends nothing"        t_req9_error_without_fallback_sends_nothing
run "[REQ-10] already on fallback is a no-op"                t_req10_already_on_fallback_is_a_noop
run "[REQ-14] prefix-colliding id is not 'already on'"       t_req14_prefix_collision_is_not_already_on
run "[REQ-15] rejected thinking degrades to the recovery"    t_req15_rejected_thinking_degrades_to_model_recovery
run "[REQ-17] FreeTierError/403 pane failure is detected"    t_req17_free_tier_error_detected
run "[REQ-18] messages describe both detected failure kinds"  t_req18_messages_describe_detected_failures
run "[REQ-11] missing child session dies"                    t_req11_missing_session_dies
run "[REQ-13] touched scripts shellcheck-clean"              t_req13_shellcheck_and_bash_n_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
