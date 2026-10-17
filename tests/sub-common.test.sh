#!/usr/bin/env bash
# Behavioural tests for scripts/_sub-common.sh — prepare_child_agent_dir
# (specs/child-model-defaults/child-model-defaults.feature) and the region
# parser + verified send of tmux_send_line (specs/fix-send-confirm/
# fix-send-confirm.feature and specs/fix-parked-prompt/fix-parked-prompt.feature,
# labels prefixed [fix-send-confirm] / [fix-parked-prompt]).
#
# The prepare tests source the script under test in a subshell with an
# isolated $HOME (fixture written into $HOME/.pi/agent/settings.json) and
# assert on the produced child settings.json — no real ~/.pi state is ever
# read or touched. SUB_COMMON_UNDER_TEST overrides the script under test so
# the pre-change implementation can be exercised (RED) without modifying the
# tree. The send tests sandbox a stateful fake tmux binary (structured
# pi-TUI pane) placed first on PATH — no real tmux session is ever touched.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON=${SUB_COMMON_UNDER_TEST:-$ROOT/scripts/_sub-common.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# prepare <fixture-fn> [VAR=value ...]
# Runs prepare_child_agent_dir with $HOME redirected to a scratch dir whose
# .pi/agent/settings.json comes from <fixture-fn>; extra VAR=value pairs are
# applied to the child environment (e.g. PATH=… to hide jq).
# Sets: RC (exit status), ERR (stderr), SETTINGS (produced settings.json).
SB=
prepare() {
  local fixture=$1; shift
  SB=$(mktemp -d "$SCRATCH/case.XXXXXX")
  mkdir -p "$SB/home/.pi/agent"
  "$fixture" "$SB/home/.pi/agent"
  RC=0
  OUT=$(env HOME="$SB/home" "$@" bash -c \
    "source '$COMMON'; prepare_child_agent_dir '$SB/agent-dir'" \
    2>"$SB/stderr") || RC=$?
  ERR=$(cat "$SB/stderr")
  SETTINGS=$(cat "$SB/agent-dir/settings.json" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Fixtures: contents of $HOME/.pi/agent/settings.json
# ---------------------------------------------------------------------------

fx_full() {
  cat > "$1/settings.json" <<'JSON'
{"defaultProvider":"anthropic","defaultModel":"claude-sonnet-4-6","enabledModels":["anthropic/claude-sonnet-4-6","openai/gpt-5"],"packages":["evil-ext"],"otherKey":"drop-me"}
JSON
}
fx_nulls() {
  printf '%s\n' '{"defaultProvider":null,"defaultModel":null,"enabledModels":null}' \
    > "$1/settings.json"
}
fx_missing() { :; }
fx_malformed() { printf '{not valid json' > "$1/settings.json"; }
fx_array() { printf '[1,2,3]\n' > "$1/settings.json"; }

# PATH without jq (bash/rm/mkdir/ln are the only externals the function runs).
no_jq_path() {
  local d="$SCRATCH/no-jq-bin" p
  mkdir -p "$d"
  for p in bash rm mkdir ln; do ln -sf "$(command -v "$p")" "$d/$p"; done
  printf '%s' "$d"
}

jq_ok() { command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not on PATH\n' >&2; return 0; }; }

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

t_req1_inherits_model_defaults_from_global_settings() {
  jq_ok || return 0
  prepare fx_full
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  [ "$OUT" = "$SB/agent-dir" ] || fail "expected echoed dest dir, got: $OUT"
  printf '%s' "$SETTINGS" | jq -e '
    .defaultProvider == "anthropic"
    and .defaultModel == "claude-sonnet-4-6"
    and .enabledModels == ["anthropic/claude-sonnet-4-6","openai/gpt-5"]
    and .packages == []
    and (keys | length == 4)' >/dev/null \
    || fail "expected the three inherited model keys + packages, got: $SETTINGS"
}

t_req2_drops_null_valued_model_keys() {
  jq_ok || return 0
  prepare fx_nulls
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "null-valued keys must be dropped, got: $SETTINGS"
}

t_req3_never_inherits_packages_or_unrelated_keys() {
  jq_ok || return 0
  prepare fx_full
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '
    .packages == []
    and (has("otherKey") | not)
    and (keys - ["defaultProvider","defaultModel","enabledModels","packages"] == [])' >/dev/null \
    || fail "global packages/otherKey leaked or model keys missing: $SETTINGS"
}

t_req4_packages_only_when_global_settings_missing() {
  jq_ok || return 0
  prepare fx_missing
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "expected packages-only file, got: $SETTINGS"
}

t_req5_packages_only_when_global_settings_malformed() {
  jq_ok || return 0
  prepare fx_malformed
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "expected packages-only file, got: $SETTINGS"
}

t_req6_packages_only_when_global_settings_wrong_shape() {
  jq_ok || return 0
  prepare fx_array
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "expected packages-only file, got: $SETTINGS"
}

t_req7_packages_only_when_jq_unavailable() {
  prepare fx_full "PATH=$(no_jq_path)"
  [ "$RC" -eq 0 ] || fail "exit=$RC stderr=$ERR"
  [ -z "$ERR" ] || fail "expected silence on stderr, got: $ERR"
  printf '%s' "$SETTINGS" | jq -e '. == {"packages":[]}' >/dev/null \
    || fail "expected packages-only file, got: ${SETTINGS:-<empty>}"
}

t_req8_shellcheck_and_bash_n_clean() {
  bash -n "$COMMON" || fail "bash -n reported syntax errors"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$COMMON" || fail "shellcheck reported findings"
}

# ---------------------------------------------------------------------------
# fix-send-confirm: region parser fixtures + tmux_send_line behaviour
# (specs/fix-send-confirm/fix-send-confirm.feature)
# ---------------------------------------------------------------------------

D68=$(printf '─%.0s' $(seq 1 68))

# parse_fixture <capture-text> — sets PF_LAYOUT / PF_COMP / PF_TRANS / PF_BELOW
# from _pi_parse_regions run against a fixture capture.
parse_fixture() {
  local out
  local -a F
  out=$(bash -c "source '$COMMON'; _pi_parse_regions
    printf '%s\n' \"\$_pi_layout\"
    printf '[%s]\n' \"\$_pi_comp\"
    printf '[%s]\n' \"\$_pi_trans\"
    printf '[%s]\n' \"\$_pi_below\"" <<<"$1")
  mapfile -t F <<<"$out"
  PF_LAYOUT=${F[0]}
  PF_COMP=${F[1]#[}; PF_COMP=${PF_COMP%]}
  PF_TRANS=${F[2]#[}; PF_TRANS=${PF_TRANS%]}
  PF_BELOW=${F[3]#[}; PF_BELOW=${PF_BELOW%]}
}

t_send_req7_regions_split_recognized_layouts() {
  # Observed live pane layouts (idle / parked / working / submitted), plus a
  # shell pane that must stay unrecognized.
  parse_fixture "transcript line
$D68

$D68
/tmp/wt (task/demo)
stats"
  [ "$PF_LAYOUT" = 1 ] || fail "idle pane not recognized (layout=$PF_LAYOUT)"
  [ -z "$PF_COMP" ] || fail "idle composer must be empty, got: $PF_COMP"
  [[ $PF_TRANS == *transcriptline* ]] || fail "idle transcript lost: $PF_TRANS"

  parse_fixture "fold line

$D68
my-parked-prompt-text
$D68
/tmp/wt (task/demo)
stats"
  [ "$PF_LAYOUT" = 1 ] || fail "parked pane not recognized"
  [[ $PF_COMP == *my-parked-prompt-text* ]] || fail "parked text not in composer: $PF_COMP"
  [[ $PF_TRANS != *my-parked-prompt-text* ]] || fail "parked text leaked into transcript: $PF_TRANS"

  parse_fixture "user message landed here

── ⠹ Working ────────

$D68
/tmp/wt (task/demo)
stats"
  [ "$PF_LAYOUT" = 1 ] || fail "working pane not recognized"
  [ -z "$PF_COMP" ] || fail "working composer must be empty, got: $PF_COMP"
  [[ $PF_TRANS == *usermessagelandedhere* ]] || fail "submitted message not in transcript: $PF_TRANS"

  parse_fixture "user@host:~/wt\$ pi -n demo --no-extensions 'go'"
  [ "$PF_LAYOUT" = 0 ] || fail "shell pane must be unrecognized, got layout=$PF_LAYOUT"
}

# [fix-parked-prompt REQ-1] the composer's block survives a blank line above
# the status border (the shape that pushed a parked line into the transcript).
t_send_req1_composer_survives_blank_gap_above_border() {
  parse_fixture "fold line

── ⠴ Working ──────────
my parked instruction

$D68
/tmp/wt (task/demo)
stats"
  [ "$PF_LAYOUT" = 1 ] || fail "gap pane not recognized (layout=$PF_LAYOUT)"
  [[ $PF_COMP == *myparkedinstruct* ]] || fail "parked text lost from the composer: $PF_COMP"
  [[ $PF_TRANS != *myparkedinstruct* ]] || fail "parked text leaked into transcript: $PF_TRANS"
}

# [fix-parked-prompt REQ-4] the composer region is bounded: a transcript that
# runs into the status border without a blank separator is not swallowed.
t_send_req4_composer_region_is_bounded() {
  parse_fixture "oldest line one
older line two
old line three
recent line four
freshest line
$D68
/tmp/wt (task/demo)
stats"
  [ "$PF_LAYOUT" = 1 ] || fail "pane not recognized (layout=$PF_LAYOUT)"
  [[ $PF_COMP == *freshestline* ]] || fail "the line above the border is not the composer: $PF_COMP"
  [[ $PF_TRANS == *oldestlineone* ]] || fail "older history must stay transcript: $PF_TRANS"
  [[ $PF_COMP != *oldestlineone* ]] || fail "the composer swallowed unbounded history: $PF_COMP"
}

# [fix-parked-prompt REQ-4] only pi's own chrome is chrome: a parked line that
# happens to be delimited by box-drawing dashes is still composer content, or
# it would be pushed into the transcript and a parked prompt confirmed as sent.
t_send_req4_dashed_parked_line_stays_in_the_composer() {
  parse_fixture "fold line

── ⠴ Working ──────────
── boxed instruction ──

$D68
/tmp/wt (task/demo)
stats"
  [ "$PF_LAYOUT" = 1 ] || fail "pane not recognized (layout=$PF_LAYOUT)"
  [[ $PF_COMP == *boxedinstruction* ]] || fail "dashed parked line lost from the composer: $PF_COMP"
  [[ $PF_TRANS != *boxedinstruction* ]] || fail "dashed parked line leaked into transcript: $PF_TRANS"
}

# Fake-tmux sandbox: a structured pi-TUI pane (transcript / spinner /
# composer / status border / path / stats) whose behaviour is driven by
# FAKE_TMUX_MODE — see the fake's header for the modes.
setup_send() {
  SB=$(mktemp -d "$SCRATCH/send.XXXXXX")
  export FAKE_TMUX_DIR="$SB/tmux-state"
  mkdir -p "$SB/bin" "$FAKE_TMUX_DIR"
  cat > "$SB/bin/tmux" <<'EOS'
#!/usr/bin/env bash
# Stateful fake tmux with a structured pi-TUI pane (specs/fix-send-confirm).
# FAKE_TMUX_MODE:
#   ok          text lands in the composer; Enter moves it to the transcript
#   drop-text   literal text never lands (send lost before render)
#   drop-enter  text lands; Enter is swallowed (pane fully static)
#   redraw      Enter ticks the stats line — the pane CHANGES — but the text
#               stays parked (the 2026-10-02/10-04 incident fingerprint:
#               completion mutation / redraw without submission)
#   vanish      first Enter wipes the composer with no transcript entry
#               (TUI reset); later Enters submit normally
#   vanish-all  every Enter wipes the composer; nothing ever reaches the
#               transcript
#   already-sent the literal text is rendered into the transcript instead of
#               the composer and Enter is a no-op: the pane state that is
#               indistinguishable from a parked prompt once the region
#               boundaries blur (specs/fix-parked-prompt)
# FAKE_TMUX_LAYOUT selects the pane shape (pi default):
#   shell  an interactive shell pane (no pi layout)
#   live   transcript / blank / "── ⠴ Working ──" / blank / composer / border
#   gap    the same pane in the instant after typing, before pi has drawn the
#          composer's top border: a blank line sits between the composer and
#          the status border (the pi-riak-250-review incident)
#   partial a pi pane caught mid-repaint: chrome and composer, but no
#          resolvable status border (layout unrecognized)
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S"
[ -f "$S/log" ] || : > "$S/log"
[ -f "$S/transcript" ] || : > "$S/transcript"
[ -f "$S/composer" ] || : > "$S/composer"
[ -f "$S/tick" ] || : > "$S/tick"
D='────────────────────────────────────────────────────────────────────'
W='── ⠴ Working ───────────────────────────────────────────────────'
case "${1:-}" in
  send-keys)
    shift
    printf 'send-keys %s\n' "$*" >> "$S/log"
    literal=0 text=
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) text=$1; shift ;; esac
    done
    mode=${FAKE_TMUX_MODE:-ok}
    if [ "$literal" = 1 ]; then
      case "$mode" in
        drop-text) : ;;
        already-sent) printf '%s\n' "$text" >> "$S/transcript" ;;
        *) printf '%s' "$text" >> "$S/composer" ;;
      esac
      exit 0
    fi
    case "$mode" in
      ok)
        if [ -s "$S/composer" ]; then
          cat "$S/composer" >> "$S/transcript"
          printf '\n' >> "$S/transcript"
          : > "$S/composer"
        fi ;;
      drop-text|drop-enter|already-sent) ;;
      redraw)
        n=$(cat "$S/tick")
        printf '#%s' "$(( ${n:-0} + 1 ))" > "$S/tick" ;;
      vanish)
        if [ -f "$S/vanished" ]; then
          cat "$S/composer" >> "$S/transcript"
          printf '\n' >> "$S/transcript"
          : > "$S/composer"
        else
          : > "$S/vanished"
          : > "$S/composer"
        fi ;;
      vanish-all) : > "$S/composer" ;;
    esac
    exit 0 ;;
  capture-pane)
    if [ "${FAKE_TMUX_LAYOUT:-pi}" = shell ]; then
      if [ -s "$S/transcript" ]; then cat "$S/transcript"; fi
      printf 'user@host:~$ %s\n' "$(cat "$S/composer")"
      exit 0
    fi
    if [ -s "$S/transcript" ]; then cat "$S/transcript"; fi
    case "${FAKE_TMUX_LAYOUT:-pi}" in
      live)   # working row, blank, composer — the composer sits directly
              # above the status border
        printf '\n%s\n\n%s\n' "$W" "$(cat "$S/composer")" ;;
      gap)    # …the same pane before pi drew the composer's top border: the
              # blank line between composer and border
        printf '\n%s\n%s\n\n' "$W" "$(cat "$S/composer")" ;;
      partial) # a half-drawn frame: no status border row to anchor the regions
        printf '\n%s\n%s\n' "$W" "$(cat "$S/composer")"
        printf '%s\n' '/test/worktree (task/demo)'
        printf 'stats line %s\n' "$(cat "$S/tick")"
        exit 0 ;;
      *)
        printf '\n%s\n' "$D"          # gap + spinner row
        if [ -s "$S/composer" ]; then cat "$S/composer"; printf '\n'; else printf '\n'; fi ;;
    esac
    printf '%s\n' "$D"            # status border
    printf '%s\n' '/test/worktree (task/demo)'
    printf 'stats line %s\n' "$(cat "$S/tick")"
    exit 0 ;;
  *) exit 0 ;;
esac
EOS
  chmod +x "$SB/bin/tmux"
  export PATH="$SB/bin:$PATH"
  export FAKE_TMUX_MODE=ok
  export FAKE_TMUX_LAYOUT=pi
}

SEND_RC=0; SEND_OUT=; SEND_ERR=
run_send() { # <text> [mode] [layout] [attempts] [settle]
  local text=$1 mode=${2:-ok} layout=${3:-pi} attempts=${4:-3} settle=${5:-0}
  SEND_RC=0
  SEND_OUT=$(env FAKE_TMUX_MODE="$mode" FAKE_TMUX_LAYOUT="$layout" \
    bash -c "source '$COMMON'; tmux_send_line pi-demo $(printf '%q' "$text") $attempts $settle" \
    2>"$SB/err") || SEND_RC=$?
  SEND_ERR=$(cat "$SB/err")
}

sent_literals() { grep -c -- ' -l ' "$FAKE_TMUX_DIR/log"; }
sent_enters()   { grep -c -- ' Enter$' "$FAKE_TMUX_DIR/log"; }

# [fix-parked-prompt REQ-1] the incident: the composer sits one row above the
# border because pi had not drawn the composer's top border yet. Enter must be
# sent and the send confirmed from evidence — the old region model filed the
# line under the transcript and gave up before pressing anything.
t_send_req1_gap_above_border_still_submits() {
  setup_send
  run_send "instruction parked above a blank gap" ok gap 3 0
  [ "$SEND_RC" -eq 0 ] || fail "expected success, got $SEND_RC: $SEND_ERR"
  [ "$(sent_enters)" -ge 1 ] || fail "no Enter was sent: $(cat "$FAKE_TMUX_DIR/log")"
  grep -Fq "instruction parked above a blank gap" "$FAKE_TMUX_DIR/transcript" \
    || fail "transcript never received the line"
  [ ! -s "$FAKE_TMUX_DIR/composer" ] || fail "composer must be empty after submit"
}

# [fix-parked-prompt REQ-1] the exact live shape: working row, blank line,
# composer directly above the status border.
t_send_req1_live_shape_submits() {
  setup_send
  run_send "instruction under a working row" ok live 3 0
  [ "$SEND_RC" -eq 0 ] || fail "expected success, got $SEND_RC: $SEND_ERR"
  [ "$(sent_enters)" -ge 1 ] || fail "no Enter was sent: $(cat "$FAKE_TMUX_DIR/log")"
  grep -Fq "instruction under a working row" "$FAKE_TMUX_DIR/transcript" \
    || fail "transcript never received the line"
}

# [fix-parked-prompt REQ-2, REQ-3] visible text that cannot be placed in the
# composer is UNKNOWN, not sent: Enter is still sent, the send is confirmed
# from evidence, and an already-submitted line is not submitted twice.
t_send_req2_unproven_text_is_entered_then_confirmed() {
  setup_send
  run_send "already submitted, unknown placement" already-sent pi 3 0
  [ "$SEND_RC" -eq 0 ] || fail "an unproven placement must not fail the send: $SEND_ERR"
  [ "$(sent_enters)" -ge 1 ] || fail "gave up before pressing Enter: $(cat "$FAKE_TMUX_DIR/log")"
  [ "$(grep -Fc -- 'already submitted, unknown placement' "$FAKE_TMUX_DIR/transcript")" -eq 1 ] \
    || fail "the line must not be submitted twice: $(cat "$FAKE_TMUX_DIR/transcript")"
  [ ! -s "$FAKE_TMUX_DIR/composer" ] || fail "nothing may be left parked"
}

# [fix-parked-prompt REQ-5] a line that stays visible but unproven is never
# re-typed; Enter is retried until the bound is exhausted.
t_send_req5_no_retype_on_ambiguous_capture() {
  setup_send
  run_send "never retype an ambiguous line" drop-enter gap 2 0
  [ "$SEND_RC" -ne 0 ] || fail "expected failure when the pane never submits"
  [ "$(sent_literals)" -eq 1 ] || fail "re-typed on an ambiguous capture: $(cat "$FAKE_TMUX_DIR/log")"
  [ "$(sent_enters)" -ge 2 ] || fail "Enter not retried: $(cat "$FAKE_TMUX_DIR/log")"
}

# [fix-parked-prompt REQ-6] the final failure names exactly what was attempted.
t_send_req6_failure_names_what_was_attempted() {
  setup_send
  run_send "instruction that never submits" drop-enter pi 3 0
  [ "$SEND_RC" -ne 0 ] || fail "expected failure for a pane that never submits"
  case $SEND_ERR in
    *"typed it 1 time(s)"*) ;; *) fail "stderr must name the typing count: $SEND_ERR" ;;
  esac
  case $SEND_ERR in
    *"Enter 3 time(s)"*) ;; *) fail "stderr must name the Enter count: $SEND_ERR" ;;
  esac
  case $SEND_ERR in
    *parked*) ;; *) fail "stderr must say the prompt may be parked: $SEND_ERR" ;;
  esac
}

# [REQ-1] success only from positive evidence: line left the composer and
# appears in the transcript.
t_send_req1_confirms_from_transcript_evidence() {
  setup_send
  run_send "please land in the transcript"
  [ "$SEND_RC" -eq 0 ] || fail "expected success, got $SEND_RC: $SEND_ERR"
  [ -z "$SEND_OUT" ] || fail "the helper must be silent on stdout, got: $SEND_OUT"
  grep -Fq "please land in the transcript" "$FAKE_TMUX_DIR/transcript" \
    || fail "transcript never received the line"
  [ ! -s "$FAKE_TMUX_DIR/composer" ] || fail "composer must be empty after submit"
  [ "$(sent_enters)" -ge 1 ] || fail "no Enter was sent"
}

# [REQ-2] the incident: the pane CHANGES on every Enter (stats tick) while
# the line stays parked. Never confirm; retry Enter; fail.
t_send_req2_parked_prompt_with_pane_noise_never_confirmed() {
  setup_send
  run_send "parked while the pane redraws" redraw
  [ "$SEND_RC" -ne 0 ] || fail "false success for a parked prompt (old change-check bug)"
  [ "$(sent_enters)" -ge 2 ] || fail "Enter not retried: $(cat "$FAKE_TMUX_DIR/log")"
  grep -Fq "parked while the pane redraws" "$FAKE_TMUX_DIR/composer" \
    || fail "the parked line must stay in the composer"
  case $SEND_ERR in *WARNING:*) ;; *) fail "no warning on stderr: $SEND_ERR" ;; esac
}

# [REQ-3] a line wiped without reaching the transcript is typed once more;
# the re-typed submission confirms normally.
t_send_req3_retypes_when_prompt_vanished() {
  setup_send
  run_send "vanish once then land" vanish
  [ "$SEND_RC" -eq 0 ] || fail "expected success after retype, got $SEND_RC: $SEND_ERR"
  [ "$(sent_literals)" -ge 2 ] || fail "line was not typed a second time"
  grep -Fq "vanish once then land" "$FAKE_TMUX_DIR/transcript" \
    || fail "re-typed line never reached the transcript"
}

# [REQ-5] second vanish stays bounded and loud.
t_send_req5_second_vanish_fails_loudly() {
  setup_send
  run_send "always wiped" vanish-all
  [ "$SEND_RC" -ne 0 ] || fail "expected failure after the second vanish"
  [ "$(sent_literals)" -eq 2 ] || fail "exactly one retype expected, got $(sent_literals)"
  case $SEND_ERR in
    *"vanished"*) ;; *) fail "stderr should name the vanish: $SEND_ERR" ;;
  esac
}

# [REQ-4] text that never appears: retype, then fail before any Enter-based
# success is possible (fix-parked-prompt REQ-9 adds the last-resort Enter).
t_send_req4_text_never_appears_fails_without_enter_success() {
  setup_send
  run_send "text that never lands" drop-text
  [ "$SEND_RC" -ne 0 ] || fail "expected failure for text that never appeared"
  [ "$(sent_literals)" -ge 2 ] || fail "expected a retype (>= 2 sends)"
  case $SEND_ERR in
    *"never rendered"*) ;; *) fail "stderr should say the text never rendered: $SEND_ERR" ;;
  esac
}

# [fix-parked-prompt REQ-9] the bytes are in the pane's input queue even when
# nothing rendered: Enter is sent anyway, and the helper still fails.
t_send_req9_enter_sent_before_giving_up_on_unrendered_text() {
  setup_send
  run_send "text that never lands" drop-text
  [ "$SEND_RC" -ne 0 ] || fail "an unrendered line must never be claimed as sent"
  [ "$(sent_enters)" -ge 1 ] || fail "no last-resort Enter: $(cat "$FAKE_TMUX_DIR/log")"
  case $SEND_ERR in
    *"Enter sent anyway"*) ;; *) fail "stderr should name the last-resort Enter: $SEND_ERR" ;;
  esac
}

# [fix-parked-prompt REQ-7] a half-drawn pi pane (chrome, no resolvable status
# border) must never be confirmed by the legacy "pane changed" check.
t_send_req7_incompletely_drawn_pi_pane_never_confirmed() {
  setup_send
  run_send "pane caught mid-repaint" redraw partial 3 0
  [ "$SEND_RC" -ne 0 ] || fail "an unresolved pi pane was confirmed by a pane change"
  [ "$(sent_enters)" -ge 2 ] || fail "Enter not retried: $(cat "$FAKE_TMUX_DIR/log")"
}

# [REQ-5] frozen pane: bounded Enter retries, then failure.
t_send_req5_frozen_pane_fails_after_bounds() {
  setup_send
  run_send "instruction that never submits" drop-enter pi 3 0
  [ "$SEND_RC" -ne 0 ] || fail "expected failure for a frozen pane"
  [ "$(sent_enters)" -ge 2 ] || fail "Enter not retried: $(cat "$FAKE_TMUX_DIR/log")"
}

# [REQ-6] shell panes (start-main / sub-spawn launch) keep the legacy
# change-based confirmation.
t_send_req6_shell_pane_keeps_change_check() {
  setup_send
  run_send "pi -n demo --no-extensions 'go'" ok shell
  [ "$SEND_RC" -eq 0 ] || fail "shell launch not confirmed: $SEND_ERR"
  [ "$(sent_enters)" -ge 1 ] || fail "No Enter was sent"
  grep -Fq "pi -n demo" "$FAKE_TMUX_DIR/transcript" \
    || fail "shell pane never executed the line"
}

# [REQ-10] the touched helper and this suite stay shellcheck/bash -n clean.
t_send_req10_shellcheck_clean() {
  bash -n "$COMMON" || fail "bash -n reported syntax errors"
  bash -n "${BASH_SOURCE[0]}" || fail "bash -n reported syntax errors in this file"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$COMMON" "${BASH_SOURCE[0]}" || fail "shellcheck reported findings"
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

run "[REQ-1] inherit model defaults from the global settings"   t_req1_inherits_model_defaults_from_global_settings
run "[REQ-2] drop null-valued model keys"                       t_req2_drops_null_valued_model_keys
run "[REQ-3] never inherit packages or unrelated keys"          t_req3_never_inherits_packages_or_unrelated_keys
run "[REQ-4] packages-only file when settings missing"          t_req4_packages_only_when_global_settings_missing
run "[REQ-5] packages-only file when settings malformed"        t_req5_packages_only_when_global_settings_malformed
run "[REQ-6] packages-only file when settings wrong-shaped"     t_req6_packages_only_when_global_settings_wrong_shape
run "[REQ-7] packages-only file when jq unavailable"            t_req7_packages_only_when_jq_unavailable
run "[REQ-8] shellcheck and bash -n clean"                      t_req8_shellcheck_and_bash_n_clean

run "[fix-send-confirm REQ-7] region parser splits recognized layouts" t_send_req7_regions_split_recognized_layouts
run "[fix-send-confirm REQ-1] confirm from transcript evidence"        t_send_req1_confirms_from_transcript_evidence
run "[fix-send-confirm REQ-2] parked prompt + pane noise never confirmed" t_send_req2_parked_prompt_with_pane_noise_never_confirmed
run "[fix-send-confirm REQ-3] retype a vanished prompt"                t_send_req3_retypes_when_prompt_vanished
run "[fix-send-confirm REQ-5] second vanish fails loudly"              t_send_req5_second_vanish_fails_loudly
run "[fix-send-confirm REQ-4] never-appearing text fails w/o Enter"    t_send_req4_text_never_appears_fails_without_enter_success
run "[fix-parked-prompt REQ-9] last-resort Enter before giving up"     t_send_req9_enter_sent_before_giving_up_on_unrendered_text
run "[fix-parked-prompt REQ-7] half-drawn pi pane never confirmed"     t_send_req7_incompletely_drawn_pi_pane_never_confirmed
run "[fix-send-confirm REQ-5] frozen pane fails after bounds"          t_send_req5_frozen_pane_fails_after_bounds
run "[fix-send-confirm REQ-6 / fix-parked-prompt REQ-7] shell pane keeps the change check" t_send_req6_shell_pane_keeps_change_check
run "[fix-parked-prompt REQ-1] composer survives a blank gap above the border" t_send_req1_composer_survives_blank_gap_above_border
run "[fix-parked-prompt REQ-4] composer region is bounded"                t_send_req4_composer_region_is_bounded
run "[fix-parked-prompt REQ-4] dashed parked line stays in the composer"   t_send_req4_dashed_parked_line_stays_in_the_composer
run "[fix-parked-prompt REQ-1] gap above the border still submits"         t_send_req1_gap_above_border_still_submits
run "[fix-parked-prompt REQ-1] live shape submits"                         t_send_req1_live_shape_submits
run "[fix-parked-prompt REQ-2/3] unproven text is entered, then confirmed"  t_send_req2_unproven_text_is_entered_then_confirmed
run "[fix-parked-prompt REQ-5] no retype on an ambiguous capture"          t_send_req5_no_retype_on_ambiguous_capture
run "[fix-parked-prompt REQ-6] failure names what was attempted"           t_send_req6_failure_names_what_was_attempted
run "[fix-send-confirm REQ-10 / fix-parked-prompt REQ-8] shellcheck-clean"  t_send_req10_shellcheck_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
