#!/usr/bin/env bash
# Behavioural tests for scripts/sub-report.sh (shared verified send) and the
# fix-send-confirm incident regression through sub-send.sh.
# Labels [REQ-n] trace specs/sub-report-notice/sub-report-notice.feature;
# labels [fix-send-confirm REQ-n] trace specs/fix-send-confirm.
#
# Each test sandboxes a stateful fake tmux binary placed first on PATH — its
# pane/session state lives in a per-test temp dir, driven by FAKE_TMUX_MODE
# (ok | drop-text | drop-enter | redraw). The pane is rendered with pi's
# real TUI structure (transcript / spinner / composer / status border /
# path / stats) so the verified send exercises its evidence path. No real
# tmux session — and specifically the live orchestrator session — is ever
# touched.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPORT="$ROOT/scripts/sub-report.sh"
SEND="$ROOT/scripts/sub-send.sh"
TASK=demo-task
SESS="pi-$TASK"

failures=0

fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

setup() {
  SB=$(mktemp -d)
  trap 'rm -rf "$SB"' EXIT
  export FAKE_TMUX_DIR="$SB/tmux-state"
  mkdir -p "$SB/bin" "$FAKE_TMUX_DIR"

  cat > "$SB/bin/tmux" <<'EOS'
#!/usr/bin/env bash
# Stateful fake tmux: sessions/pane/log live in $FAKE_TMUX_DIR.
# The pane renders pi's TUI structure: transcript ("pane" file), gap+spinner,
# composer, status border, path, stats.
# FAKE_TMUX_MODE controls the behaviour of send-keys:
#   ok         - text lands in the composer; Enter moves it to the transcript
#   drop-text  - text never appears in the pane (send is lost)
#   drop-enter - text appears but Enter is swallowed (pane fully static)
#   redraw     - Enter TICKS the stats line (the pane changes!) while the
#                text stays parked — the 2026-10-02/10-04 incident
#                fingerprint (completion mutation without submission)
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S"
[ -f "$S/sessions" ] || : > "$S/sessions"
[ -f "$S/log" ]      || : > "$S/log"
[ -f "$S/pane" ]     || : > "$S/pane"
[ -f "$S/composer" ] || : > "$S/composer"
[ -f "$S/tick" ]     || : > "$S/tick"
D='────────────────────────────────────────────────────────────────────'

session_exists() {
  local t=${1#=}
  t=${t%:}
  grep -Fxq -- "$t" "$S/sessions"
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
      [ "$mode" = drop-text ] || printf '%s' "$text" >> "$S/composer"
      exit 0
    fi
    case "$mode" in
      ok)
        if [ -s "$S/composer" ]; then
          cat "$S/composer" >> "$S/pane"
          printf '\n' >> "$S/pane"
          : > "$S/composer"
        fi ;;
      drop-enter) : ;;
      redraw)
        n=$(cat "$S/tick")
        printf '#%s' "$(( ${n:-0} + 1 ))" > "$S/tick" ;;
    esac
    exit 0
    ;;
  capture-pane)
    if [ -s "$S/pane" ]; then cat "$S/pane"; fi
    printf '\n%s\n' "$D"          # gap + spinner row
    if [ -s "$S/composer" ]; then cat "$S/composer"; printf '\n'; else printf '\n'; fi
    printf '%s\n' "$D"            # status border
    printf '%s\n' '/test/main (task/main)'
    printf 'stats line %s\n' "$(cat "$S/tick")"
    exit 0
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
  : > "$FAKE_TMUX_DIR/log"
  : > "$FAKE_TMUX_DIR/composer"
  : > "$FAKE_TMUX_DIR/tick"
  export FAKE_TMUX_MODE=ok
  # Pin the target env: the test shell may inherit MAIN_SESSION/MAIN_PANE
  # from a live tmux session, which must not leak into the sandbox.
  export MAIN_SESSION=main-orch
  export MAIN_PANE=
  # Pin the scratch location so the failure hint is deterministic.
  export SCRATCH_DIR=tmp/pi-sub
}

add_session() { printf '%s\n' "$1" >> "$FAKE_TMUX_DIR/sessions"; }

# --- scenario helpers -------------------------------------------------------

count_sent()  { grep -c -- ' -l ' "$FAKE_TMUX_DIR/log"; }   # text (literal) sends
count_enter() { grep -c -- ' Enter$' "$FAKE_TMUX_DIR/log"; } # Enter key sends

run_report() {
  REP_OUT=$("$REPORT" "$@" 2>"$SB/err"); REP_RC=$?
  REP_ERR=$(cat "$SB/err")
}

run_send() {
  REP_OUT=$("$SEND" "$@" 2>"$SB/err"); REP_RC=$?
  REP_ERR=$(cat "$SB/err")
}

run_report_no_tmux() { # restricted PATH: bash + dirname only, no tmux
  REP_OUT=$(PATH="$SB/notmux" "$REPORT" "$@" 2>"$SB/err"); REP_RC=$?
  REP_ERR=$(cat "$SB/err")
}

expect_rc0()        { [ "$REP_RC" -eq 0 ] || fail "expected exit 0, got $REP_RC: out=$REP_OUT err=$REP_ERR"; }
expect_rc_nonzero() { [ "$REP_RC" -ne 0 ] || fail "expected non-zero exit: out=$REP_OUT"; }
expect_out()        { printf '%s' "$REP_OUT" | grep -q -- "$1" || fail "stdout lacks '$1': $REP_OUT"; }
expect_not_out()    { ! printf '%s' "$REP_OUT" | grep -q -- "$1" || fail "stdout must not contain '$1': $REP_OUT"; }
expect_err()        { printf '%s' "$REP_ERR" | grep -q -- "$1" || fail "stderr lacks '$1': $REP_ERR"; }

# ---------------------------------------------------------------------------
# Tests — one per [REQ-n]
# ---------------------------------------------------------------------------

t_req1_happy_path_delivers_verified_notice() {
  setup
  add_session main-orch
  local msg='DONE: "quoted" brackets [x] unicode ✓ -> reports/demo.md'
  run_report "$TASK" "$msg"
  expect_rc0
  grep -Fq -- "[demo-task] $msg" "$FAKE_TMUX_DIR/pane" \
    || fail "pane never received the exact text: $(cat "$FAKE_TMUX_DIR/pane")"
  expect_out "notice"
}

t_req2_missing_session_fails_loudly() {
  setup
  add_session some-other-session   # MAIN_SESSION=main-orch is NOT running
  run_report "$TASK" "DONE: x"
  expect_rc_nonzero
  expect_err "ERROR:"
  expect_err "main-orch"
  expect_err "tmp/pi-sub/reports/$TASK.md"
  expect_not_out "notice"
}

t_req3_no_tmux_fails_loudly() {
  setup
  mkdir -p "$SB/notmux"
  ln -s "$(command -v bash)" "$SB/notmux/bash"
  ln -s "$(command -v dirname)" "$SB/notmux/dirname"
  run_report_no_tmux "$TASK" "DONE: x"
  expect_rc_nonzero
  expect_err "ERROR:"
  expect_err "tmux"
  expect_err "tmp/pi-sub/reports/$TASK.md"
}

t_req4_retypes_when_text_never_appears() {
  setup
  add_session main-orch
  export FAKE_TMUX_MODE=drop-text
  run_report "$TASK" "DONE: x"
  local sent; sent=$(count_sent)
  [ "$sent" -ge 2 ] || fail "text sent $sent time(s); expected a re-type (>= 2): $(cat "$FAKE_TMUX_DIR/log")"
}

t_req5_retries_enter_while_pane_frozen() {
  setup
  add_session main-orch
  export FAKE_TMUX_MODE=drop-enter
  run_report "$TASK" "DONE: x"
  local enters; enters=$(count_enter)
  [ "$enters" -ge 2 ] || fail "Enter sent $enters time(s); expected retries (>= 2): $(cat "$FAKE_TMUX_DIR/log")"
}

t_req6_unconfirmed_delivery_fails_loudly() {
  setup
  add_session main-orch
  export FAKE_TMUX_MODE=drop-enter
  run_report "$TASK" "DONE: x"
  expect_rc_nonzero
  expect_err "ERROR:"
  expect_err "not delivered"
  expect_err "tmp/pi-sub/reports/$TASK.md"
  expect_not_out "notice"
}

t_req7_sub_send_still_delivers() {
  setup
  add_session "$SESS"
  run_send "$TASK" "please continue with the follow-up"
  expect_rc0
  grep -Fq -- "please continue with the follow-up" "$FAKE_TMUX_DIR/pane" \
    || fail "pane never received the instruction: $(cat "$FAKE_TMUX_DIR/pane")"
  expect_out "instruction sent to $SESS"
}

t_req9_shellcheck_touched_scripts() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$ROOT/scripts/sub-report.sh" "$ROOT/scripts/_sub-common.sh" \
    "$ROOT/scripts/sub-send.sh" "$ROOT/scripts/sub-spawn.sh" \
    || fail "shellcheck reported findings"
}

t_supp_sub_send_unconfirmed_is_loud() {
  setup
  add_session "$SESS"
  export FAKE_TMUX_MODE=drop-enter
  run_send "$TASK" "instruction that never lands"
  expect_rc_nonzero
  expect_not_out "instruction sent"
}

# ---------------------------------------------------------------------------
# fix-send-confirm: the field-incident regression, end to end through the
# script callers (specs/fix-send-confirm/fix-send-confirm.feature)
# ---------------------------------------------------------------------------

# [fix-send-confirm REQ-2/REQ-5] the 2026-10-02/10-04 incident: the pane
# changes on every Enter (completion mutation / redraw) while the prompt
# stays parked in the composer. sub-send must NOT print "instruction sent";
# it must retry Enter and fail loudly.
t_send_req2_incident_never_reported_as_sent() {
  setup
  add_session "$SESS"
  export FAKE_TMUX_MODE=redraw
  run_send "$TASK" "long instruction that stays parked with a ghost suffix"
  expect_rc_nonzero
  expect_err "ERROR:"
  expect_not_out "instruction sent"
  local enters; enters=$(count_enter)
  [ "$enters" -ge 2 ] || fail "Enter not retried ($enters sends): $(cat "$FAKE_TMUX_DIR/log")"
  grep -Fq -- "long instruction that stays parked" "$FAKE_TMUX_DIR/composer" \
    || fail "the parked instruction must still be in the composer"
}

# [fix-send-confirm REQ-8] the success path keeps its exact wording: callers
# parse it.
t_send_req8_success_wording_unchanged() {
  setup
  add_session "$SESS"
  run_send "$TASK" "a follow-up that lands"
  expect_rc0
  expect_out "instruction sent to $SESS"
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

run "[REQ-1] deliver verified notice to a live main session"   t_req1_happy_path_delivers_verified_notice
run "[REQ-2] missing main session fails loudly"               t_req2_missing_session_fails_loudly
run "[REQ-3] no tmux fails loudly with report hint"           t_req3_no_tmux_fails_loudly
run "[REQ-4] re-type when the text never appears"             t_req4_retypes_when_text_never_appears
run "[REQ-5] retry Enter while the pane is frozen"            t_req5_retries_enter_while_pane_frozen
run "[REQ-6] unconfirmed delivery fails loudly"               t_req6_unconfirmed_delivery_fails_loudly
run "[REQ-7] sub-send keeps delivering via shared helper"     t_req7_sub_send_still_delivers
run "[REQ-9] shellcheck touched scripts"                      t_req9_shellcheck_touched_scripts
run "[supp] sub-send unconfirmed instruction fails loudly"    t_supp_sub_send_unconfirmed_is_loud
run "[fix-send-confirm REQ-2/REQ-5] parked incident never reported" t_send_req2_incident_never_reported_as_sent
run "[fix-send-confirm REQ-8] success wording unchanged"       t_send_req8_success_wording_unchanged

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
