#!/usr/bin/env bash
# Behavioural tests for scripts/main-watch.sh — the orchestrator stall watcher
# (specs/orchestrator-stall-recovery). One test per scenario the watcher owns:
# REQ-3 … REQ-20, REQ-23, REQ-24, REQ-31, REQ-32, REQ-33, REQ-34, REQ-35,
# REQ-36. The
# arming scenarios (REQ-1, REQ-2, REQ-21, REQ-22) and the shellcheck gate
# (REQ-27) live in tests/test-start-main.sh, because they are start-main.sh's
# behaviour.
#
# Hermetic: no real tmux session is ever touched. A stateful fake `tmux` is
# placed first on PATH and keeps every bit of pane/status-bar/session state in
# files under $TMP, so a test asserts the keys that crossed the tmux boundary
# — the only observable behaviour a watcher has. Fallback values come from a
# SUB_LEVELS_CONFIG fixture written by this suite (never the shipped
# config.json), and every id and level here is suite-local
# (fixture-runner/recovery-alpha, level-stub): were the fixture ever not wired
# up, a coincidental match with a real model id could not keep a test green.
#
# The timing knobs are all pinned so the suite runs in seconds:
# MAIN_WATCH_INTERVAL=0, MAIN_WATCH_TICKS=1 (3 where dedupe/rewake needs
# repeated scans), MAIN_WATCH_RETRY_SECONDS=0, MAIN_WATCH_REWAKE_SECONDS=900
# (0 where the rewake must fire), FALLBACK_PROBE_DELAY=0,
# FALLBACK_PROBE_ATTEMPTS=1, FALLBACK_SEND_ATTEMPTS=0.
#
# Usage: bash tests/main-watch.test.sh   (exit 0 = all green)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# SUT override, the idiom the sibling suites use (SUB_COMMON_UNDER_TEST …):
# a mutated copy of the watcher (with its own sibling _sub-common.sh) can be
# checked to make these tests go red, without touching scripts/ here.
SUT=${MAIN_WATCH_UNDER_TEST:-$ROOT/scripts/main-watch.sh}
BASE_PATH=$PATH

SESS=pi-main
CHILD=pi-demo-task
FB_MODEL=fixture-runner/recovery-alpha
FB_FOOTER='(fixture-runner) recovery-alpha'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A `sleep` that caps at 10 ms, used on the watcher's PATH only. The fake tmux
# applies every send synchronously, so the settle delays that exist to let a
# real pi TUI redraw are pure test time; a tiny real sleep still yields. The
# real binary is named by absolute path — a bare `sleep` would re-enter this
# shim from the same PATH and spin forever.
REAL_SLEEP=$(command -v sleep)
mkdir -p "$TMP/fastbin"
cat > "$TMP/fastbin/sleep" <<EOS
#!/usr/bin/env bash
exec "$REAL_SLEEP" 0.01
EOS
chmod +x "$TMP/fastbin/sleep"

# Resolver fixture for the whole suite: the fallback pair the watcher must
# apply, with neutral stub ids that name no shipped model or level.
LEVELS_CONFIG="$TMP/levels.json"
cat > "$LEVELS_CONFIG" <<'JSON'
{
  "taskLevels": {
    "default": "standard",
    "fallbackModel": "fixture-runner/recovery-alpha",
    "fallbackThinking": "level-stub",
    "levels": {
      "standard": { "model": "fixture-other/baseline-model", "thinking": "level-other" }
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

passes=0 failures=0

# Test-body assertion: abort this test only (each test runs in a subshell).
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

run() { # <test name> <test function>
  local name=$1 fn=$2 out t0 t1 ms
  t0=$(date +%s%N)
  if out=$( "$fn" 2>&1 ); then
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    passes=$((passes + 1))
    printf 'ok     %6d ms  %s\n' "$ms" "$name"
  else
    failures=$((failures + 1))
    printf 'NOT OK %s\n%s\n' "$name" "$out"
  fi
}

# ---------------------------------------------------------------------------
# Fake-tmux sandbox
# ---------------------------------------------------------------------------

setup() {
  SB=$(mktemp -d "$TMP/t.XXXXXX")
  export FAKE_TMUX_DIR="$SB/state"
  mkdir -p "$SB/bin" "$FAKE_TMUX_DIR/mode"
  local S=$FAKE_TMUX_DIR

  cat > "$SB/bin/tmux" <<'EOS'
#!/usr/bin/env bash
# Stateful fake tmux for the orchestrator-watcher tests. Everything lives in
# files under $FAKE_TMUX_DIR; no server is ever contacted.
#   $S/sessions   live session names, one per line
#   $S/pane       the watched pane's transcript
#   $S/footer     the status bar, appended after the transcript on capture
#   $S/model      model id in effect        $S/level  thinking level in effect
#   $S/pending-*  a typed but not yet submitted /model or /thinking argument
#   $S/composer   the last literal line typed (cleared by C-u)
#   $S/log        every send-keys invocation (its arguments)
#   $S/calls      the subcommand of every invocation
#   $S/targets    the raw -t target of every resolve (what was addressed)
#   $S/windows    "<index> <name>" per window of the session
#   $S/selected   the session's current (selected) window index
#   $S/cmd        the pi window's #{pane_current_command} (default pi)
#   $S/pane-watch the watch window's own pane, never pi's transcript
#   $S/relapse-ttl  captures of a cleaned pane before the failure returns
#   $S/mode/<name>  drop-enter | no-apply | reject-thinking | pane-bash |
#                   relapse | swap-incident
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S/mode"
mode() { [ -f "$S/mode/$1" ]; }
# "=pi-main:" / "=pi-main:1" / "=pi-main" / "pi-main" -> "pi-main"
norm() { local t=${1#=}; printf '%s' "${t%%:*}"; }

# The session's selected window index, as tmux would report it.
sel_index() { local i; i=$(cat "$S/selected" 2>/dev/null || true); printf '%s' "${i:-1}"; }
win_exists() { awk -v i="$1" '$1 == i { found = 1 } END { exit !found }' "$S/windows"; }
win_name() { awk -v i="$1" '$1 == i { print $2; exit }' "$S/windows"; }
# The pi window's command: node/bun-exec'd pi reports `node`, a launcher
# symlink reports `pi`; the shell mode reports a shell.
pane_cmd() {
  if [ -f "$S/cmd" ]; then cat "$S/cmd"
  elif mode pane-bash; then printf 'bash'
  else printf 'pi'; fi
}
win_cmd() { # $1 = window index
  [ -n "$(win_name "$1")" ] || return 0
  if [ "$(win_name "$1")" = pi ]; then pane_cmd
  else printf 'bash'; fi
}
# Resolve a -t target the way tmux does: a missing index — including 0 on a
# base-index-1 server — resolves to the session's SELECTED window, which is
# exactly why an unverified index is never a usable pin. The raw target is
# recorded so a test can assert what the watcher addressed.
resolve() {
  local t=${1#=} idx=''
  printf '%s\n' "${1:-}" >> "$S/targets"
  case $t in *:*) idx=${t#*:} ;; esac
  if [ -n "$idx" ] && win_exists "$idx"; then printf '%s' "$idx"
  else sel_index; fi
}

printf '%s\n' "${1:-}" >> "$S/calls"

# Rebuild the status bar from the state files, the way pi renders it.
rewrite_footer() {
  local model level id provider
  model=$(cat "$S/model" 2>/dev/null || true)
  [ -n "$model" ] || return 0
  id=${model##*/}
  provider=${model%%/*}
  level=$(cat "$S/level" 2>/dev/null || true)
  {
    printf '%s\n' '/fixture/repo (task/demo)'
    printf '0.0%%/1.0M (auto)          (%s) %s • %s\n' "$provider" "$id" "$level"
  } > "$S/footer"
}

# Submit whatever the composer holds: pi applies the pending /model (clamping
# the level when asked), then the pending /thinking (or answers it with its
# validation error in reject-thinking mode).
apply_enter() {
  local lvl
  printf '\n<<submitted>>\n' >> "$S/pane"
  if [ -s "$S/pending-model" ]; then
    cp "$S/pending-model" "$S/model"
    rm -f "$S/pending-model"
    if [ -f "$S/level-after-model" ]; then cp "$S/level-after-model" "$S/level"; fi
  fi
  if [ -s "$S/pending-thinking" ]; then
    lvl=$(cat "$S/pending-thinking")
    rm -f "$S/pending-thinking"
    if mode reject-thinking; then
      printf 'Error: Unknown thinking level "%s". Available levels: off, minimal, low.\n' \
        "$lvl" >> "$S/pane"
    else
      printf '%s' "$lvl" > "$S/level"
    fi
  fi
  rewrite_footer
  # mode relapse: the wake submission is the recovery the orchestrator acted
  # on — the failure clears (a clean pane), then a later incident appears.
  if mode relapse && [ ! -f "$S/relapse-done" ] && grep -qF -- '[main-watch ' "$S/composer"; then
    : > "$S/relapse-done"
    cp "$S/pane-clean" "$S/pane"
    printf '%s' 'fixture-other/baseline-model' > "$S/model"
    printf '%s' 'level-stub' > "$S/level"
    rewrite_footer
    printf '2' > "$S/relapse-ttl"
  fi
  # mode swap-incident: the visible pane becomes a DIFFERENT incident after the
  # first recovery, with NO clean scan in between (the old banner scrolled out
  # of the visible window while another error render took its place) and the
  # session back on the baseline model. Nothing observed the pane error-free,
  # so the watcher still believes it is on the earlier incident.
  if mode swap-incident && [ ! -f "$S/swap-done" ] && grep -qF -- '[main-watch ' "$S/composer"; then
    : > "$S/swap-done"
    cp "$S/pane-swap" "$S/pane"
    printf '%s' 'fixture-other/baseline-model' > "$S/model"
    printf '%s' 'level-stub' > "$S/level"
    rewrite_footer
  fi
  : > "$S/composer"
}

capture_pane() {
  local n
  if [ -f "$S/relapse-ttl" ]; then
    n=$(cat "$S/relapse-ttl")
    if [ "$n" -eq 0 ]; then
      # The clean pane was observed; the next capture shows a new incident.
      rm -f "$S/relapse-ttl"
      cat "$S/pane-relapse" >> "$S/pane"
      printf '%s' 'fixture-other/baseline-model' > "$S/model"
      printf '%s' 'level-stub' > "$S/level"
      rewrite_footer
    else
      printf '%s' "$((n - 1))" > "$S/relapse-ttl"
    fi
  fi
  cat "$S/pane"
  cat "$S/footer"
}

send_keys() {
  local literal=0 text='' target='' idx
  shift   # drop the subcommand
  printf 'send-keys %s\n' "$*" >> "$S/log"
  while [ $# -gt 0 ]; do
    case $1 in
      -t) target=${2:-}; shift 2 ;;
      -l) literal=1; shift ;;
      *) text=$1; shift ;;
    esac
  done
  idx=$(resolve "$target")
  # A send into the watch window's own pane is recorded but changes nothing in
  # pi's pane: a watcher addressing the wrong window can never be confirmed.
  if [ "$(win_name "$idx")" = watch ]; then return 0; fi
  if [ "$literal" = 1 ]; then
    printf '%s' "$text" >> "$S/pane"
    printf '%s' "$text" > "$S/composer"
    case $text in
      '/model '*)    printf '%s' "${text#/model }"    > "$S/pending-model" ;;
      '/thinking '*) printf '%s' "${text#/thinking }" > "$S/pending-thinking" ;;
    esac
    return 0
  fi
  case $text in
    C-u)
      # pi's deleteToLineStart: the parked line is discarded, nothing submitted.
      rm -f "$S/pending-model" "$S/pending-thinking"
      : > "$S/composer"
      ;;
    Enter)
      if mode drop-enter; then return 0; fi
      if mode no-apply; then
        printf '\n<<submitted>>\n' >> "$S/pane"
        rm -f "$S/pending-model" "$S/pending-thinking"
        : > "$S/composer"
        return 0
      fi
      apply_enter
      ;;
  esac
}

case "${1:-}" in
  has-session)
    shift
    target=
    while [ $# -gt 0 ]; do
      case $1 in
        -t) target=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    grep -Fxq -- "$(norm "$target")" "$S/sessions"
    ;;
  display-message)
    # Formats the watcher asks for: the pinned pane's command (the pi-like
    # probe) and a window's own index (the pin's verification).
    target='' fmt=''
    while [ $# -gt 0 ]; do
      case $1 in
        -t) target=${2:-}; shift 2 ;;
        -p) shift ;;
        *) fmt=$1; shift ;;
      esac
    done
    case $fmt in
      *pane_current_command*) win_cmd "$(resolve "$target")" ;;
      *window_index*) resolve "$target" ;;
      *) : ;;
    esac
    ;;
  list-windows)
    # The watcher resolves the pi window by this list: this session's windows
    # are 1-based (this host's base-index 1), so window 0 does not exist.
    while [ $# -gt 0 ]; do
      case $1 in
        -t|-F) shift 2 ;;
        *) shift ;;
      esac
    done
    while read -r idx _; do
      [ -n "$idx" ] || continue
      printf '%s %s\n' "$idx" "$(win_cmd "$idx")"
    done < "$S/windows"
    ;;
  capture-pane)
    target=''
    while [ $# -gt 0 ]; do
      case $1 in
        -t) target=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$(win_name "$(resolve "$target")")" = watch ]; then
      cat "$S/pane-watch"
    else
      capture_pane
    fi
    ;;
  send-keys) send_keys "$@" ;;
  *) : ;;   # new-window / show-options: the watcher never needs them
esac
EOS
  chmod +x "$SB/bin/tmux"
  PATH="$SB/bin:$BASE_PATH"
  WATCH_PATH="$SB/bin:$TMP/fastbin:$BASE_PATH"
  export PATH

  : > "$S/sessions" "$S/pane" "$S/log" "$S/calls" "$S/targets" "$S/composer"
  printf '%s\n' '1 pi' > "$S/windows"
  printf '%s' '1' > "$S/selected"
  printf '%s\n' ' watching pi-main for free-provider stalls' > "$S/pane-watch"
  rm -f "$S/cmd"
  printf '%s' 'fixture-other/baseline-model' > "$S/model"
  printf '%s' 'level-stub' > "$S/level"
  footer_set fixture-other baseline-model level-stub

  # Pin the knobs and the fixture config so no ambient environment leaks in.
  export MAIN_WATCH_INTERVAL=0
  export MAIN_WATCH_TICKS=1
  export MAIN_WATCH_RETRY_SECONDS=0
  export MAIN_WATCH_REWAKE_SECONDS=900
  export MAIN_WATCH_SCAN_LINES=50
  export FALLBACK_PROBE_DELAY=0
  export FALLBACK_PROBE_ATTEMPTS=1
  export FALLBACK_SEND_ATTEMPTS=0
  export SUB_LEVELS_CONFIG="$LEVELS_CONFIG"
  unset SUB_FALLBACK_MODEL SUB_FALLBACK_THINKING START_MAIN_NO_WATCH
  unset MAIN_SESSION MAIN_PANE TMUX TMUX_PANE
  WATCH_OUT='' WATCH_ERR='' WATCH_RC=0
}

SB=''
add_session() { printf '%s\n' "$1" >> "$FAKE_TMUX_DIR/sessions"; }
del_session() { grep -Fxv -- "$1" "$FAKE_TMUX_DIR/sessions" > "$FAKE_TMUX_DIR/sessions.tmp" || true
  mv "$FAKE_TMUX_DIR/sessions.tmp" "$FAKE_TMUX_DIR/sessions"; }

# The status bar the fake renders: "(<provider>) <id> • <level>". The state
# files move with it, so a later rewrite stays consistent.
footer_set() { # $1=provider $2=id $3=level
  local S=$FAKE_TMUX_DIR
  printf '%s/%s' "$1" "$2" > "$S/model"
  printf '%s' "$3" > "$S/level"
  {
    printf '%s\n' '/fixture/repo (task/demo)'
    printf '0.0%%/1.0M (auto)          (%s) %s • %s\n' "$1" "$2" "$3"
  } > "$S/footer"
}

# --- pane fixtures ---------------------------------------------------------

# pi's own usage-limit render: the banner line carries the JSON error type.
seed_usage_limit_render() {
  cat >> "$FAKE_TMUX_DIR/pane" <<'ERR'

 hi

 Error: 429: {"type":"FreeUsageLimitError","message":"Rate limit exceeded.
 Please try again later."}
 If this looks like a pi bug, /bug sends a report to the developers.
ERR
}

# pi's own free-tier render (the 403 that wedges compaction just as hard).
seed_free_tier_render() {
  cat >> "$FAKE_TMUX_DIR/pane" <<'ERR'

 hi

 Error: Turn prefix summarization failed: 403: {"type":"FreeTierError","message":"the free tier rejects this request"}
 Context overflow recovery failed.
ERR
}

# The same render wrapped: the banner carries no signature, its continuation
# line does.
seed_wrapped_render() {
  cat >> "$FAKE_TMUX_DIR/pane" <<'ERR'

 hi

 Error: 429
 {"type":"FreeUsageLimitError","message":"Rate limit exceeded."}
ERR
}

# The signature quoted in analysis prose and in tool output — never a banner.
seed_prose_mention() {
  cat >> "$FAKE_TMUX_DIR/pane" <<'PROSE'

 Assistant: the child's log shows FreeUsageLimitError from the provider.
 tool result: {"type":"FreeTierError","message":"the free tier rejects this"}
 The quoted 429 rate limit wording is an excerpt from that log, not a render.

 Error: the launch check failed, no provider was involved
 nothing to see here

 normal transcript output continues.
PROSE
}

# A child's delivered STUCK notice, shaped exactly as sub-report.sh prefixes it.
seed_stuck_notice() {
  cat >> "$FAKE_TMUX_DIR/pane" <<'STUCK'

 [demo-task] STUCK: free-provider failure in the child pane
 (FreeUsageLimitError) - run sub-fallback.sh demo-task to recover it
STUCK
}

seed_transcript() {
  printf '%s\n' \
    ' User: refactor the pane parser' \
    ' Assistant: reading the files now.' \
    ' tool: 24 lines read, no provider errors' > "$FAKE_TMUX_DIR/pane"
}

# [REQ-19] the pane content after the orchestrator acted on the wake, and the
# later incident that follows it.
seed_relapse() {
  : > "$FAKE_TMUX_DIR/mode/relapse"
  printf '%s\n' \
    ' Assistant: resumed and finished the interrupted turn.' > "$FAKE_TMUX_DIR/pane-clean"
  cat > "$FAKE_TMUX_DIR/pane-relapse" <<'ERR'

 User: continue please

 Error: 429: {"type":"FreeUsageLimitError","message":"Rate limit exceeded."}
ERR
}

# [REQ-35] the pane after the first recovery, showing a DIFFERENT incident and
# a session back on the baseline model, with no clean pane in between.
seed_swap_incident() {
  : > "$FAKE_TMUX_DIR/mode/swap-incident"
  cat > "$FAKE_TMUX_DIR/pane-swap" <<'ERR'

 Assistant: continuing.

 Error: Turn prefix summarization failed: 403: {"type":"FreeTierError","message":"the free tier rejects this request"}
 Context overflow recovery failed.
ERR
}

# --- assertions ------------------------------------------------------------

RUN_TIMEOUT=()
command -v timeout >/dev/null 2>&1 && RUN_TIMEOUT=(timeout 20)

run_watch() { # watches $SESS; sets WATCH_RC/OUT/ERR
  # Every run is bounded: a watcher that never honours its scan bound (or
  # loops) must fail a test, not hang the suite. A normal run is well under 2s.
  WATCH_RC=0
  WATCH_OUT=$( PATH=$WATCH_PATH ${RUN_TIMEOUT[@]+"${RUN_TIMEOUT[@]}"} "$SUT" "$SESS" 2>"$SB/err" ) || WATCH_RC=$?
  WATCH_ERR=$(cat "$SB/err")
}

run_watch_in() { # $1=window argument (the index start-main.sh passes)
  WATCH_RC=0
  WATCH_OUT=$( PATH=$WATCH_PATH ${RUN_TIMEOUT[@]+"${RUN_TIMEOUT[@]}"} "$SUT" "$SESS" "$1" 2>"$SB/err" ) || WATCH_RC=$?
  WATCH_ERR=$(cat "$SB/err")
}

expect_rc0() {
  [ "$WATCH_RC" -eq 124 ] && fail "the watcher was still running when the bound expired: out=$WATCH_OUT err=$WATCH_ERR"
  [ "$WATCH_RC" -eq 0 ] || fail "expected exit 0, got $WATCH_RC: out=$WATCH_OUT err=$WATCH_ERR"
}

count_sent() { local n; n=$(grep -cF -- "$1" "$FAKE_TMUX_DIR/log" || true); printf '%s' "${n:-0}"; }
sends_total() { local n; n=$(grep -c '' "$FAKE_TMUX_DIR/log" || true); printf '%s' "${n:-0}"; }
count_calls() { local n; n=$(grep -cFx -- "$1" "$FAKE_TMUX_DIR/calls" || true); printf '%s' "${n:-0}"; }
wakes() { count_sent '-l Resume the interrupted turn'; }
model_sends() { count_sent '-l /model '; }
thinking_sends() { count_sent '-l /thinking '; }

assert_eq() { [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"; }
assert_min() { [ "$3" -ge "$2" ] || fail "$1: expected at least [$2], got [$3]"; }
assert_sent() { grep -qF -- "$1" "$FAKE_TMUX_DIR/log" \
  || fail "the watcher never sent '$1': $(cat "$FAKE_TMUX_DIR/log")"; }
assert_not_sent() { ! grep -qF -- "$1" "$FAKE_TMUX_DIR/log" \
  || fail "the watcher must not send '$1': $(cat "$FAKE_TMUX_DIR/log")"; }
assert_out() { printf '%s' "$WATCH_OUT" | grep -qF -- "$1" || fail "stdout lacks '$1': $WATCH_OUT"; }
assert_not_out() { ! printf '%s' "$WATCH_OUT" | grep -qF -- "$1" || fail "stdout must not contain '$1': $WATCH_OUT"; }
assert_err() { printf '%s' "$WATCH_ERR" | grep -qF -- "$1" || fail "stderr lacks '$1': $WATCH_ERR"; }
assert_err_count() { # <needle> <count>
  local n; n=$(printf '%s' "$WATCH_ERR" | grep -cF -- "$1" || true)
  assert_eq "stderr occurrences of '$1'" "$2" "${n:-0}"
}
assert_footer() { grep -qF -- "$1" "$FAKE_TMUX_DIR/footer" \
  || fail "the status bar does not show '$1': $(cat "$FAKE_TMUX_DIR/footer")"; }
# Every -t target the watcher addressed: a pin is proven by what it looked at,
# not only by what it managed to send.
assert_addressed() { grep -qxF -- "$1" "$FAKE_TMUX_DIR/targets" \
  || fail "the watcher never addressed '$1': $(sort -u "$FAKE_TMUX_DIR/targets")"; }
assert_not_addressed() { ! grep -qxF -- "$1" "$FAKE_TMUX_DIR/targets" \
  || fail "the watcher must not address '$1': $(sort -u "$FAKE_TMUX_DIR/targets")"; }

# ---------------------------------------------------------------------------
# Scenarios — one test per scenario the watcher owns
# ---------------------------------------------------------------------------

# [REQ-3] A free-provider failure rendered by pi in the main pane is detected
t_req3_rendered_failure_is_detected() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  run_watch
  expect_rc0
  # Detection's observable proof: the recovery started instead of idling.
  assert_sent "/model $FB_MODEL"
  assert_out 'switched'

  setup
  add_session "$SESS"
  seed_transcript
  run_watch
  expect_rc0
  assert_eq "a clean pane is not detected" 0 "$(sends_total)"
}

# [REQ-4] A signature quoted in prose or tool output is not a failure
t_req4_prose_mention_is_not_a_failure() {
  setup
  add_session "$SESS"
  seed_prose_mention
  export MAIN_WATCH_TICKS=2
  run_watch
  expect_rc0
  assert_eq "no keys may be sent" 0 "$(sends_total)"
  assert_min "the bounded scans ran" 2 "$(count_calls capture-pane)"
}

# [REQ-5] A child STUCK notice quoting the signature is not a failure
t_req5_child_stuck_notice_is_not_a_failure() {
  setup
  add_session "$SESS"
  add_session "$CHILD"
  seed_stuck_notice
  export MAIN_WATCH_TICKS=2
  run_watch
  expect_rc0
  assert_eq "the watcher must not act on its own notification traffic" 0 "$(sends_total)"
}

# [REQ-6] Both free-provider failure kinds are detected
t_req6_both_failure_kinds_are_detected() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  run_watch
  expect_rc0
  assert_sent "/model $FB_MODEL"

  setup
  add_session "$SESS"
  seed_free_tier_render
  run_watch
  expect_rc0
  assert_sent "/model $FB_MODEL"
}

# [REQ-7] An error render wrapped over several pane lines is detected
t_req7_wrapped_render_is_detected() {
  setup
  add_session "$SESS"
  seed_wrapped_render
  run_watch
  expect_rc0
  assert_sent "/model $FB_MODEL"
}

# [REQ-8] A detected failure switches the orchestrator to the configured fallback
t_req8_switches_to_the_configured_fallback() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  run_watch
  expect_rc0
  assert_eq "exactly one /model" 1 "$(model_sends)"
  assert_sent "-l /model $FB_MODEL"
  assert_sent ' Enter'
  # The switch is only ever claimed once the status bar shows the id.
  assert_footer "$FB_FOOTER"
  assert_out "switched =$SESS:1 to fallback model $FB_MODEL"
}

# [REQ-9] A pane without a pi error render sees no keys
t_req9_clean_pane_sees_no_keys() {
  setup
  add_session "$SESS"
  seed_transcript
  export MAIN_WATCH_TICKS=2
  run_watch
  expect_rc0
  assert_eq "no keys to any session" 0 "$(sends_total)"
  assert_eq "no /model anywhere" 0 "$(model_sends)"
  assert_eq "no /thinking anywhere" 0 "$(thinking_sends)"
}

# [REQ-10] A main pane that is not running pi is never typed into
t_req10_shell_pane_is_never_typed_into() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  : > "$FAKE_TMUX_DIR/mode/pane-bash"
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_eq "no keys to a shell pane" 0 "$(sends_total)"
  assert_err 'is not running pi'
  # It kept watching: every bounded scan still happened, once per incident.
  assert_min "scans ran" 3 "$(count_calls capture-pane)"
  assert_err_count 'is not running pi' 1
  # No pi-like window exists, so the pin is the FIRST LISTED index (1 here) —
  # never a literal 0, which this base-index-1 session does not have.
  assert_addressed "=$SESS:1"
  assert_not_addressed "=$SESS:0"
}

# [REQ-36] A pi-like pane command is not literally `pi` on every install (a
# node/bun-exec'd pi reports `node`): the oracle is a deny-list of shells, so
# such a pane is still detected and recovered. The deny-list's other side — a
# shell is never typed into — is [REQ-10].
t_req36_pi_like_pane_command_is_recovered() {
  # The window argument start-main.sh resolves before arming: the pin is used
  # as given and verified.
  setup
  add_session "$SESS"
  seed_usage_limit_render
  printf '%s' node > "$FAKE_TMUX_DIR/cmd"
  run_watch_in 1
  expect_rc0
  assert_sent "/model $FB_MODEL"
  assert_out "switched =$SESS:1 to fallback model $FB_MODEL"
  assert_addressed "=$SESS:1"

  # No window argument: the resolver picks the same window from the list.
  setup
  add_session "$SESS"
  seed_usage_limit_render
  printf '%s' node > "$FAKE_TMUX_DIR/cmd"
  run_watch
  expect_rc0
  assert_sent "/model $FB_MODEL"
  assert_addressed "=$SESS:1"
}

# [REQ-33] The operator selecting another window (here the watch window itself)
# must not blind the watcher: the pin is the pi window, so the incident is
# still detected and recovered there.
t_req33_selected_other_window_does_not_blind_the_watcher() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  printf '%s\n' '2 watch' >> "$FAKE_TMUX_DIR/windows"
  printf '%s' '2' > "$FAKE_TMUX_DIR/selected"
  run_watch
  expect_rc0
  assert_sent "/model $FB_MODEL"
  assert_out "switched =$SESS:1 to fallback model $FB_MODEL"
  # It never read or typed into the selected watch window, and never fell back
  # to the selection-following session target.
  assert_addressed "=$SESS:1"
  assert_not_addressed "=$SESS:"
  assert_not_addressed "=$SESS:2"
}

# [REQ-34] A `=SESS:0` index this base-index-1 session does not have resolves,
# in tmux, to the SELECTED window — here the watch window. It never becomes the
# pin, so the shell window is neither read as pi nor typed into, and the real
# pi window is recovered instead.
t_req34_unverified_index_is_never_the_pin() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  printf '%s\n' '2 watch' >> "$FAKE_TMUX_DIR/windows"
  printf '%s' '2' > "$FAKE_TMUX_DIR/selected"
  # start-main could not resolve an index (empty): the watcher resolves it.
  run_watch
  expect_rc0
  assert_not_addressed "=$SESS:0"
  assert_sent "/model $FB_MODEL"

  # The argument exists but does not verify: the verification probe asks tmux
  # for index 0 and is told 1, so the argument is dropped and the resolver runs
  # instead of trusting the number it was handed.
  setup
  add_session "$SESS"
  seed_usage_limit_render
  printf '%s\n' '2 watch' >> "$FAKE_TMUX_DIR/windows"
  printf '%s' '2' > "$FAKE_TMUX_DIR/selected"
  run_watch_in 0
  expect_rc0
  assert_not_sent "=$SESS:0"
  assert_sent "/model $FB_MODEL"
  assert_out "switched =$SESS:1 to fallback model $FB_MODEL"
}

# [REQ-11] An orchestrator already on the fallback model is not switched
t_req11_already_on_fallback_is_not_switched() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  footer_set fixture-runner recovery-alpha level-stub
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_eq "no /model on any scan" 0 "$(model_sends)"
  assert_out 'no model switch performed'
  # Later scans of the same visible failure switch nothing either.
  assert_min "scans ran" 3 "$(count_calls capture-pane)"
  assert_eq "no /thinking either" 0 "$(thinking_sends)"
}

# [REQ-12] A status-bar id that extends the fallback id is not "already on"
t_req12_extending_status_bar_id_is_not_already_on() {
  # An id that extends the fallback id as a prefix+suffix (the free twin) …
  setup
  add_session "$SESS"
  seed_usage_limit_render
  footer_set fixture-other recovery-alpha-free level-other
  run_watch
  expect_rc0
  assert_sent "-l /model $FB_MODEL"
  assert_footer "$FB_FOOTER"

  # … and one that only prepends to it: neither counts as already-on.
  setup
  add_session "$SESS"
  seed_usage_limit_render
  footer_set fixture-other xrecovery-alpha level-other
  run_watch
  expect_rc0
  assert_sent "-l /model $FB_MODEL"
  assert_footer "$FB_FOOTER"
}

# [REQ-13] The configured fallback thinking level is applied
t_req13_configured_thinking_level_is_applied() {
  # The switch left the session on another level: /thinking follows and is
  # confirmed in the status bar.
  setup
  add_session "$SESS"
  seed_usage_limit_render
  printf '%s' level-other > "$FAKE_TMUX_DIR/level-after-model"
  run_watch
  expect_rc0
  assert_sent '-l /thinking level-stub'
  assert_footer '• level-stub'
  assert_out 'thinking level set to level-stub'

  # The status bar already shows the level after the switch: nothing is sent.
  setup
  add_session "$SESS"
  seed_usage_limit_render
  run_watch
  expect_rc0
  assert_eq "an already-effective level is never re-sent" 0 "$(thinking_sends)"
  assert_footer '• level-stub'
  assert_out 'thinking level already level-stub'
}

# [REQ-14] A fallback thinking level the model rejects degrades to a warning
t_req14_rejected_thinking_degrades_to_a_warning() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  : > "$FAKE_TMUX_DIR/mode/reject-thinking"
  printf '%s' level-other > "$FAKE_TMUX_DIR/level-after-model"
  run_watch
  expect_rc0
  # The model switch alone recovered the session.
  assert_sent "-l /model $FB_MODEL"
  assert_out "switched =$SESS:1 to fallback model $FB_MODEL"
  assert_footer "$FB_FOOTER"
  # The level is never claimed, the drift is named as the config problem it is.
  assert_not_out 'thinking level set'
  assert_err 'Unknown thinking level'
  assert_err 'fallbackThinking'
  assert_err 'does not match fallbackModel'
  # It stops at the rejection: one attempt, composer cleared, no nudge loop.
  assert_eq "the rejected level is attempted once" 1 "$(thinking_sends)"
  assert_sent ' C-u'
  assert_eq "no Enter nudge loop" 3 "$(count_sent ' Enter')"
}

# [REQ-15] One switch per incident while the same failure stays visible
t_req15_one_switch_per_incident() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_eq "exactly one /model" 1 "$(model_sends)"
  assert_eq "no /thinking" 0 "$(thinking_sends)"
  assert_eq "exactly one wake before the rewake interval" 1 "$(wakes)"
}

# [REQ-16] An unconfirmed switch is retried and never claimed
t_req16_unconfirmed_switch_is_retried_never_claimed() {
  local first_cu second_model
  setup
  add_session "$SESS"
  seed_usage_limit_render
  : > "$FAKE_TMUX_DIR/mode/no-apply"
  export MAIN_WATCH_TICKS=2
  run_watch
  expect_rc0
  assert_eq "the switch is retried on the later scan" 2 "$(model_sends)"
  # The composer is cleared before the retry, so nothing parked is submitted.
  first_cu=$(grep -nF -- ' C-u' "$FAKE_TMUX_DIR/log" | head -n1 | cut -d: -f1)
  second_model=$(grep -nF -- '-l /model ' "$FAKE_TMUX_DIR/log" | sed -n '2p' | cut -d: -f1)
  [ -n "$first_cu" ] || fail "the composer was never cleared: $(cat "$FAKE_TMUX_DIR/log")"
  [ -n "$second_model" ] || fail "the switch was never retried: $(cat "$FAKE_TMUX_DIR/log")"
  [ "$first_cu" -lt "$second_model" ] \
    || fail "the composer must be cleared before the retry: $(cat "$FAKE_TMUX_DIR/log")"
  assert_not_out 'switched'
  assert_err 'still does not show it'
  assert_eq "an unconfirmed switch produces no wake" 0 "$(wakes)"
}

# [REQ-17] A confirmed switch wakes the idle orchestrator exactly once
t_req17_confirmed_switch_wakes_exactly_once() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_eq "exactly one wake line" 1 "$(wakes)"
  assert_sent '-l Resume the interrupted turn'
  # Nothing else follows the wake: model line, its Enter, the wake, its Enter.
  assert_eq "no keys after the wake" 4 "$(sends_total)"
  assert_eq "the last key is the wake's Enter" 'send-keys -t =pi-main:1 Enter' \
    "$(tail -n1 "$FAKE_TMUX_DIR/log")"

  setup
  add_session "$SESS"
  seed_usage_limit_render
  : > "$FAKE_TMUX_DIR/mode/no-apply"
  run_watch
  expect_rc0
  assert_eq "no wake when the switch was not confirmed" 0 "$(wakes)"
}

# [REQ-18] The watcher only ever types into the main session
t_req18_only_types_into_the_main_session() {
  local line
  setup
  add_session "$SESS"
  add_session "$CHILD"
  seed_usage_limit_render
  run_watch
  expect_rc0
  assert_sent "-l /model $FB_MODEL"
  while IFS= read -r line; do
    case $line in
      *"=$SESS:"*) : ;;
      *) fail "a key went outside $SESS: $line" ;;
    esac
  done < "$FAKE_TMUX_DIR/log"
  # Never a child pane, never a report to itself (a notice arrives as "[task] ").
  assert_not_sent "$CHILD"
  assert_not_sent '-l ['
  assert_eq "the switch reached exactly one session" 4 "$(sends_total)"
}

# [REQ-19] A cleared failure lets a later failure be recovered again
t_req19_cleared_failure_allows_a_later_recovery() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  seed_relapse
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_eq "the later incident is switched again" 2 "$(model_sends)"
  assert_eq "and woken again" 2 "$(wakes)"
  assert_footer "$FB_FOOTER"
}

# [REQ-35] A different incident that replaces the recovered one in the visible
# pane — with no clean scan in between and the session back on the baseline
# model — is recovered again, never merely woken: a stale "switched" from the
# earlier incident must not turn the new one into a wake-only.
t_req35_a_different_incident_is_recovered_again() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  seed_swap_incident
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_eq "the new incident is switched too" 2 "$(model_sends)"
  assert_eq "and woken" 2 "$(wakes)"
  assert_footer "$FB_FOOTER"
  # The second switch really followed the second incident, so the pane never
  # stayed on the model the new failure arrived with.
  assert_eq "the pane ends on the fallback model" "$FB_MODEL" "$(cat "$FAKE_TMUX_DIR/model")"
}

# [REQ-20] Config problems warn, send nothing, and keep watching
t_req20_config_problems_warn_and_keep_watching() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  export SUB_LEVELS_CONFIG="$SB/missing-levels.json"
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_err 'missing-levels.json'
  assert_err 'no fallbackModel is configured'
  assert_eq "nothing is sent" 0 "$(sends_total)"
  assert_eq "it keeps watching, warning once" 1 "$(grep -cF -- 'no fallbackModel is configured' "$SB/err" || true)"
  assert_min "scans ran" 3 "$(count_calls capture-pane)"

  setup
  add_session "$SESS"
  seed_usage_limit_render
  printf '{not valid json' > "$SB/broken-levels.json"
  export SUB_LEVELS_CONFIG="$SB/broken-levels.json"
  run_watch
  expect_rc0
  assert_err 'broken-levels.json'
  assert_eq "nothing is sent for a malformed config" 0 "$(sends_total)"

  setup
  add_session "$SESS"
  seed_usage_limit_render
  printf '%s' '{"taskLevels":{"default":"standard"}}' > "$SB/no-fallback.json"
  export SUB_LEVELS_CONFIG="$SB/no-fallback.json"
  run_watch
  expect_rc0
  assert_err 'no fallbackModel is configured'
  assert_eq "nothing is sent without a fallbackModel" 0 "$(sends_total)"
}

# [REQ-23] The watcher stops when the main session goes away
t_req23_stops_when_the_session_goes_away() {
  local before i rc=0
  setup
  add_session "$SESS"
  seed_transcript
  export MAIN_WATCH_TICKS=0
  PATH=$WATCH_PATH "$SUT" "$SESS" > "$SB/out" 2>"$SB/err" &
  local pid=$!
  for ((i = 0; i < 200; i++)); do
    [ "$(count_calls capture-pane)" -ge 1 ] && break
    sleep 0.05
  done
  del_session "$SESS"
  for ((i = 0; i < 200; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the watcher did not stop with its session"
  fi
  wait "$pid" || rc=$?
  assert_eq "the watcher exits 0" 0 "$rc"
  grep -qF -- "watched session '$SESS' is not running" "$SB/out" \
    || fail "the watcher did not report the session is gone: $(cat "$SB/out")"
  # No scan after the session disappeared.
  before=$(count_calls capture-pane)
  sleep 0.2
  assert_eq "no scan after the session went away" "$before" "$(count_calls capture-pane)"
  assert_eq "no keys were ever sent" 0 "$(sends_total)"
}

# [REQ-24] A test scan bound stops the watcher after that many scans
t_req24_scan_bound_stops_the_watcher() {
  local i
  setup
  add_session "$SESS"
  seed_transcript
  run_watch
  expect_rc0
  assert_eq "MAIN_WATCH_TICKS=1 performs exactly one scan" 1 "$(count_calls capture-pane)"

  # MAIN_WATCH_TICKS=0 is unbounded: it keeps scanning until it is stopped.
  setup
  add_session "$SESS"
  seed_transcript
  export MAIN_WATCH_TICKS=0
  PATH=$WATCH_PATH "$SUT" "$SESS" > "$SB/out" 2>"$SB/err" &
  local pid=$!
  for ((i = 0; i < 200; i++)); do
    [ "$(count_calls capture-pane)" -ge 3 ] && break
    sleep 0.05
  done
  kill -0 "$pid" 2>/dev/null \
    || fail "MAIN_WATCH_TICKS=0 exited on its own: $(cat "$SB/out") $(cat "$SB/err")"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(count_calls capture-pane)" -ge 3 ] || fail "the unbounded watcher stopped scanning"
}

# [REQ-31] A visible failure while already on the fallback still gets a wake
t_req31_already_on_fallback_still_gets_a_wake() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  footer_set fixture-runner recovery-alpha level-stub
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_eq "no /model" 0 "$(model_sends)"
  assert_eq "no /thinking" 0 "$(thinking_sends)"
  assert_eq "exactly one wake line" 1 "$(wakes)"
  assert_sent '-l Resume the interrupted turn'
  assert_not_out 'to fallback model'
}

# [REQ-32] An unchanged failure is woken again after the rewake interval
t_req32_unchanged_failure_is_rewoken() {
  # Before the rewake interval: no further wake for the same failure.
  setup
  add_session "$SESS"
  seed_usage_limit_render
  export MAIN_WATCH_TICKS=3
  run_watch
  expect_rc0
  assert_eq "one wake before the interval" 1 "$(wakes)"
  assert_eq "one /model" 1 "$(model_sends)"

  # Once it has elapsed: one further wake per due scan, never a second /model.
  setup
  add_session "$SESS"
  seed_usage_limit_render
  export MAIN_WATCH_TICKS=3
  export MAIN_WATCH_REWAKE_SECONDS=0
  run_watch
  expect_rc0
  assert_eq "one wake per due scan" 3 "$(wakes)"
  assert_eq "never a second /model for the same incident" 1 "$(model_sends)"
  assert_eq "never a second /thinking" 0 "$(thinking_sends)"
}

# ---------------------------------------------------------------------------
# Supplementary tests (no REQ token): edge cases and error paths
# ---------------------------------------------------------------------------

# A pi banner that is not a free-provider failure — pi's own thinking-level
# rejection — must never start a recovery.
t_supp_thinking_rejection_banner_is_not_an_incident() {
  setup
  add_session "$SESS"
  printf '%s\n' \
    ' Error: Unknown thinking level "level-stub". Available levels: off, minimal.' \
    ' normal transcript output continues.' > "$FAKE_TMUX_DIR/pane"
  export MAIN_WATCH_TICKS=2
  run_watch
  expect_rc0
  assert_eq "no keys for a non-provider banner" 0 "$(sends_total)"
}

# An Enter that never reaches pi leaves the switch unconfirmed: the composer is
# cleared, no wake is typed and no switch is ever claimed.
t_supp_unreachable_enter_never_claims_a_switch() {
  setup
  add_session "$SESS"
  seed_usage_limit_render
  : > "$FAKE_TMUX_DIR/mode/drop-enter"
  run_watch
  expect_rc0
  assert_sent "-l /model $FB_MODEL"
  assert_sent ' C-u'
  assert_not_out 'switched'
  assert_err 'could not confirm'
  assert_eq "no wake without a confirmed switch" 0 "$(wakes)"
}

# The knob family and the command line are validated up front: a typo dies
# naming its knob instead of spinning, and a fractional interval is accepted.
t_supp_knob_validation() {
  setup
  add_session "$SESS"
  seed_transcript
  MAIN_WATCH_TICKS=abc run_watch
  [ "$WATCH_RC" -ne 0 ] || fail "a non-numeric MAIN_WATCH_TICKS must fail"
  assert_err 'MAIN_WATCH_TICKS'

  setup
  add_session "$SESS"
  seed_transcript
  MAIN_WATCH_INTERVAL=0.25 run_watch
  expect_rc0

  # The command line is refused, never guessed at: a malformed window index
  # (the second positional, supplied by start-main) and a third argument both
  # fail on the usage line.
  setup
  add_session "$SESS"
  seed_transcript
  WATCH_RC=0
  WATCH_OUT=$( PATH=$WATCH_PATH "$SUT" "$SESS" extra 2>"$SB/err" ) || WATCH_RC=$?
  WATCH_ERR=$(cat "$SB/err")
  [ "$WATCH_RC" -ne 0 ] || fail "a non-numeric window argument must fail the watcher"
  assert_err 'usage:'

  setup
  add_session "$SESS"
  seed_transcript
  WATCH_RC=0
  WATCH_OUT=$( PATH=$WATCH_PATH "$SUT" "$SESS" 1 extra 2>"$SB/err" ) || WATCH_RC=$?
  WATCH_ERR=$(cat "$SB/err")
  [ "$WATCH_RC" -ne 0 ] || fail "a third argument must fail the watcher"
  assert_err 'usage:'
}

# The third entry of the shared signature — HTTP 429 next to rate-limit
# wording — is detected on a banner of its own, like the JSON error types.
t_supp_429_rate_limit_wording_is_detected() {
  setup
  add_session "$SESS"
  printf '%s\n' \
    ' Error: 429 rate limit exceeded, please try again later.' \
    ' normal transcript output continues.' > "$FAKE_TMUX_DIR/pane"
  run_watch
  expect_rc0
  assert_sent "-l /model $FB_MODEL"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

bash -n "$SUT" || fail "bash -n reported syntax errors in $SUT"

run "[REQ-3] A free-provider failure rendered by pi in the main pane is detected" t_req3_rendered_failure_is_detected
run "[REQ-4] A signature quoted in prose or tool output is not a failure" t_req4_prose_mention_is_not_a_failure
run "[REQ-5] A child STUCK notice quoting the signature is not a failure" t_req5_child_stuck_notice_is_not_a_failure
run "[REQ-6] Both free-provider failure kinds are detected" t_req6_both_failure_kinds_are_detected
run "[REQ-7] An error render wrapped over several pane lines is detected" t_req7_wrapped_render_is_detected
run "[REQ-8] A detected failure switches the orchestrator to the configured fallback" t_req8_switches_to_the_configured_fallback
run "[REQ-9] A pane without a pi error render sees no keys" t_req9_clean_pane_sees_no_keys
run "[REQ-10] A main pane that is not running pi is never typed into" t_req10_shell_pane_is_never_typed_into
run "[REQ-36] A pi-like pane command that is not literally pi is recovered" t_req36_pi_like_pane_command_is_recovered
run "[REQ-33] Selecting another window does not blind the watcher" t_req33_selected_other_window_does_not_blind_the_watcher
run "[REQ-34] An index that does not verify is never the pin" t_req34_unverified_index_is_never_the_pin
run "[REQ-11] An orchestrator already on the fallback model is not switched" t_req11_already_on_fallback_is_not_switched
run "[REQ-12] A status-bar id that extends the fallback id is not \"already on\"" t_req12_extending_status_bar_id_is_not_already_on
run "[REQ-13] The configured fallback thinking level is applied" t_req13_configured_thinking_level_is_applied
run "[REQ-14] A fallback thinking level the model rejects degrades to a warning" t_req14_rejected_thinking_degrades_to_a_warning
run "[REQ-15] One switch per incident while the same failure stays visible" t_req15_one_switch_per_incident
run "[REQ-16] An unconfirmed switch is retried and never claimed" t_req16_unconfirmed_switch_is_retried_never_claimed
run "[REQ-17] A confirmed switch wakes the idle orchestrator exactly once" t_req17_confirmed_switch_wakes_exactly_once
run "[REQ-18] The watcher only ever types into the main session" t_req18_only_types_into_the_main_session
run "[REQ-19] A cleared failure lets a later failure be recovered again" t_req19_cleared_failure_allows_a_later_recovery
run "[REQ-35] A different incident replacing a recovered one is recovered again" t_req35_a_different_incident_is_recovered_again
run "[REQ-20] Config problems warn, send nothing, and keep watching" t_req20_config_problems_warn_and_keep_watching
run "[REQ-23] The watcher stops when the main session goes away" t_req23_stops_when_the_session_goes_away
run "[REQ-24] A test scan bound stops the watcher after that many scans" t_req24_scan_bound_stops_the_watcher
run "[REQ-31] A visible failure while already on the fallback still gets a wake" t_req31_already_on_fallback_still_gets_a_wake
run "[REQ-32] An unchanged failure is woken again after the rewake interval" t_req32_unchanged_failure_is_rewoken
run "[supp]  a thinking-level rejection banner is not an incident" t_supp_thinking_rejection_banner_is_not_an_incident
run "[supp]  an Enter that never lands never claims a switch" t_supp_unreachable_enter_never_claims_a_switch
run "[supp]  the 429 rate-limit wording is detected on its own" t_supp_429_rate_limit_wording_is_detected
run "[supp]  the MAIN_WATCH_* knobs and the command line are validated" t_supp_knob_validation

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed (%d)\n' "$passes"
