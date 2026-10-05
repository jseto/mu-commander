#!/usr/bin/env bash
# Behavioural tests for the automatic child wake-up on queued Lavish
# feedback (specs/lavish-wake/lavish-wake.feature); one test per Scenario,
# labels [REQ-n].
#
# Hermetic: fake `treehouse`, `tmux`, and `lavish-axi` binaries plus fixture
# Lavish state files live under a scratch dir; bounded watcher ticks and tiny
# intervals keep the suite fast. No real tmux session, worktree pool, or
# Lavish installation is ever touched.
# SC2317: test functions are invoked indirectly via run(); SC2016: fixture
# snippets are deliberately single-quoted.
# shellcheck disable=SC2317,SC2016
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WATCH=${SUB_LAVISH_WATCH_UNDER_TEST:-$ROOT/scripts/sub-lavish-watch.sh}
SPAWN=${SUB_SPAWN_UNDER_TEST:-$ROOT/scripts/sub-spawn.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }
jq_ok() { command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not on PATH\n' >&2; return 0; }; }

TASK=demo
SESS=pi-demo

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Fake tools
# ---------------------------------------------------------------------------

setup_fakes() {
  BINDIR="$SCRATCH/bin"
  mkdir -p "$BINDIR"

  cat > "$BINDIR/treehouse" <<'EOS'
#!/usr/bin/env bash
# Fake treehouse: reports the lease named by $FAKE_LEASE_HOLDER (when set)
# and hands out $FAKE_WT on `get`.
case "${1:-}" in
  status)
    if [ -n "${FAKE_LEASE_HOLDER:-}" ]; then
      printf '[{"path":"%s","lease_holder":"%s"}]\n' "$FAKE_WT" "$FAKE_LEASE_HOLDER"
    else
      printf '[]\n'
    fi ;;
  get)    printf '%s\n' "$FAKE_WT" ;;
  return) printf '%s\n' "$*" >> "${FAKE_TREEHOUSE_LOG:-/dev/null}" ;;
esac
EOS

  cat > "$BINDIR/tmux" <<'EOS'
#!/usr/bin/env bash
# Stateful fake tmux.
#   $FAKE_TMUX_DIR/session  exists => has-session succeeds (new-session creates it)
#   $FAKE_TMUX_DIR/pane     pane content
#   $FAKE_TMUX_DIR/log      every invocation
#   $FAKE_TMUX_DIR/mode     ok (default) | drop-enter | pane-bash | no-new-window
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S"
[ -f "$S/pane" ] || : > "$S/pane"
[ -f "$S/mode" ] || printf 'ok\n' > "$S/mode"
mode=$(cat "$S/mode")
mkdir -p "$S"
{ printf '%q ' "$@"; printf '\n'; } >> "$S/log"
cmd=${1:-}; shift || true
case "$cmd" in
  has-session)
    [ -e "$S/session" ] && exit 0 || exit 1 ;;
  new-session)
    : > "$S/session"; exit 0 ;;
  kill-session)
    rm -f "$S/session"; exit 0 ;;
  display-message)
    if [ "$mode" = pane-bash ]; then printf 'bash\n'; else printf 'pi\n'; fi
    exit 0 ;;
  send-keys)
    literal=0; text=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *)  text=$1; shift ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "$text" >> "$S/pane"
    elif [ "$mode" != drop-enter ]; then
      printf '\n[tick]\n' >> "$S/pane"
    fi
    exit 0 ;;
  capture-pane) cat "$S/pane"; exit 0 ;;
  new-window)
    [ "$mode" = no-new-window ] && exit 1
    exit 0 ;;
  *) exit 0 ;;
esac
EOS
  chmod +x "$BINDIR/treehouse" "$BINDIR/tmux"

  cat > "$BINDIR/lavish-axi" <<'EOS'
#!/usr/bin/env bash
# Logs every invocation; the watcher must never call this.
printf '%s\n' "$*" >> "${LAVISH_AXI_CALLS:-$PWD/lavish-axi-calls}"
EOS
  chmod +x "$BINDIR/lavish-axi"
}

# ---------------------------------------------------------------------------
# Watcher fixture harness
# ---------------------------------------------------------------------------

new_watch_case() { # $1 = unique case id
  CASE="$SCRATCH/$1"
  mkdir -p "$CASE"
  WT="$CASE/wt"
  mkdir -p "$WT/.lavish"
  TMUX_DIR="$CASE/tmux"
  mkdir -p "$TMUX_DIR"
  : > "$TMUX_DIR/pane"
  : > "$TMUX_DIR/log"
  printf 'ok\n' > "$TMUX_DIR/mode"
  : > "$TMUX_DIR/session"
  STATE_DIR="$CASE/lavish"
  mkdir -p "$STATE_DIR"
  AXI_CALLS="$CASE/axi-calls"
  export AXI_CALLS
  unset W_INTERVAL W_RETRY W_REWAKE W_TICKS W_MARGIN 2>/dev/null || true
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

# write_state <file> <status> <pending> <updated_at> <artifact> [prompts-json]
write_state() {
  local path=$1 status=$2 pending=$3 updated=$4 artifact=$5
  local prompts=${6:-'[{"uid":"","prompt":"","selector":"","tag":"prompt","text":"do the thing"}]'}
  jq -n --arg f "$artifact" --arg s "$status" --arg u "$updated" \
        --argjson p "$pending" --argjson pr "$prompts" \
        '{sessions:{sess1:{key:"sess1",file:$f,status:$s,pending_prompts:$p,updated_at:$u,prompts:$pr}}}' \
    > "$path"
}

run_watcher() {
  RC=0
  OUT=$(env \
        LAVISH_AXI_STATE_DIR="$STATE_DIR" \
        LAVISH_WATCH_INTERVAL="${W_INTERVAL:-0.2}" \
        LAVISH_WATCH_RETRY_SECONDS="${W_RETRY:-0}" \
        LAVISH_WATCH_REWAKE_SECONDS="${W_REWAKE:-60}" \
        LAVISH_WATCH_TICKS="${W_TICKS:-2}" \
        LAVISH_WATCH_START_MARGIN="${W_MARGIN:-60}" \
        LAVISH_AXI_CALLS="$AXI_CALLS" \
        FAKE_TMUX_DIR="$TMUX_DIR" \
        FAKE_TASK="$TASK" \
        FAKE_LEASE_HOLDER="$TASK" \
        FAKE_WT="$WT" \
        PATH="$BINDIR:$PATH" \
        bash "$WATCH" "$TASK" "$ROOT" 2>"$CASE/stderr") || RC=$?
  ERR=$(cat "$CASE/stderr")
  PANE=$(cat "$TMUX_DIR/pane" 2>/dev/null || true)
  TLOG=$(cat "$TMUX_DIR/log" 2>/dev/null || true)
}

send_keys_calls() { grep -c 'send-keys' <<<"$TLOG" || true; }

# ---------------------------------------------------------------------------
# Scenarios: the watcher
# ---------------------------------------------------------------------------

t_req1_queued_feedback_wakes_the_child() {
  jq_ok || return 0
  new_watch_case req1
  write_state "$STATE_DIR/state.json" open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'plan.html (2 prompts)' <<<"$PANE" || fail "wake must name the artifact and count: $PANE"
  grep -qF 'lavish-axi poll' <<<"$PANE" || fail "wake must instruct the child to poll: $PANE"
}

t_req2_watcher_never_polls_or_consumes() {
  jq_ok || return 0
  new_watch_case req2
  write_state "$STATE_DIR/state.json" open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  cp "$STATE_DIR/state.json" "$CASE/state.before"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ ! -e "$AXI_CALLS" ] || fail "watcher ran lavish-axi: $(cat "$AXI_CALLS")"
  cmp -s "$STATE_DIR/state.json" "$CASE/state.before" || fail "watcher must not touch the state file"
}

t_req3_sessions_outside_the_worktree_are_ignored() {
  jq_ok || return 0
  new_watch_case req3
  write_state "$STATE_DIR/state.json" open 2 "$(now_utc)" "$CASE/elsewhere/plan.html"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ -z "$PANE" ] || fail "no wake expected, pane: $PANE"
  [ "$(send_keys_calls)" -eq 0 ] || fail "no keys expected: $TLOG"
}

t_req4_ended_sessions_are_ignored() {
  jq_ok || return 0
  new_watch_case req4
  write_state "$STATE_DIR/state.json" ended 2 "$(now_utc)" "$WT/.lavish/plan.html"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ -z "$PANE" ] || fail "no wake expected, pane: $PANE"
  [ "$(send_keys_calls)" -eq 0 ] || fail "no keys expected: $TLOG"
}

t_req5_stale_sessions_are_ignored() {
  jq_ok || return 0
  new_watch_case req5
  write_state "$STATE_DIR/state.json" open 2 "2020-01-01T00:00:00.000Z" "$WT/.lavish/plan.html"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ -z "$PANE" ] || fail "no wake expected, pane: $PANE"
  [ "$(send_keys_calls)" -eq 0 ] || fail "no keys expected: $TLOG"
}

t_req6_no_queued_feedback_means_no_wake() {
  jq_ok || return 0
  new_watch_case req6
  write_state "$STATE_DIR/state.json" open 0 "$(now_utc)" "$WT/.lavish/plan.html" '[]'
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ -z "$PANE" ] || fail "no wake expected, pane: $PANE"
  [ "$(send_keys_calls)" -eq 0 ] || fail "no keys expected: $TLOG"
}

t_req7_unchanged_batch_is_woken_once() {
  jq_ok || return 0
  new_watch_case req7
  write_state "$STATE_DIR/state.json" open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  cp "$STATE_DIR/state.json" "$CASE/state.good"
  (
    sleep 1.5
    printf '{ not json' > "$STATE_DIR/state.json"
    sleep 0.5
    cp "$CASE/state.good" "$STATE_DIR/state.json"
  ) &
  local mutator=$!
  W_TICKS=6; W_REWAKE=9999
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  local count
  count=$(grep -cF "woke '$TASK' for" <<<"$OUT" || true)
  [ "$count" -eq 1 ] || fail "expected exactly one wake, got $count: $OUT"
  grep -qF 'cannot read Lavish state' <<<"$ERR" \
    || fail "expected a read-failure warning: $ERR"
}

t_req8_additional_feedback_wakes_again() {
  jq_ok || return 0
  new_watch_case req8
  write_state "$STATE_DIR/state.json" open 1 "$(now_utc)" "$WT/.lavish/plan.html"
  (
    sleep 1.8
    write_state "$STATE_DIR/state.json" open 2 "$(now_utc)" "$WT/.lavish/plan.html" \
      '[{"uid":"","prompt":"","selector":"","tag":"prompt","text":"first"},{"uid":"","prompt":"","selector":"","tag":"prompt","text":"second"}]'
  ) &
  local mutator=$!
  W_TICKS=8; W_INTERVAL=0.3; W_REWAKE=9999
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  local count
  count=$(grep -cF "woke '$TASK' for" <<<"$OUT" || true)
  [ "$count" -ge 2 ] || fail "expected a second wake, got $count: $OUT"
  grep -qF 'plan.html (2 prompts)' <<<"$PANE" || fail "second wake must show the updated count: $PANE"
}

t_req9_pane_not_running_pi_is_never_woken() {
  jq_ok || return 0
  new_watch_case req9
  printf 'pane-bash\n' > "$TMUX_DIR/mode"
  write_state "$STATE_DIR/state.json" open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ -z "$PANE" ] || fail "no keys may be typed into a non-pi pane: $PANE"
  [ "$(send_keys_calls)" -eq 0 ] || fail "no keys expected: $TLOG"
  grep -qF 'is not running pi' <<<"$ERR" || fail "must report the non-pi pane: $ERR"
}

t_req10_unconfirmed_wake_is_retried_never_claimed() {
  jq_ok || return 0
  new_watch_case req10
  printf 'drop-enter\n' > "$TMUX_DIR/mode"
  write_state "$STATE_DIR/state.json" open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  W_TICKS=2; W_RETRY=0; W_INTERVAL=0.1
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'could not confirm the Lavish wake' <<<"$ERR" \
    || fail "must report the unconfirmed wake: $ERR"
  grep -qF "woke '$TASK' for" <<<"$OUT" && fail "an unconfirmed wake must not be claimed delivered"
  local count
  count=$(grep -oF 'Lavish feedback queued' <<<"$PANE" | wc -l)
  [ "$count" -ge 2 ] || fail "expected a retried wake, got $count typed copies: $PANE"
  return 0
}

t_req11_watcher_stops_with_the_child_session() {
  jq_ok || return 0
  new_watch_case req11
  rm -f "$TMUX_DIR/session"
  write_state "$STATE_DIR/state.json" open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  W_TICKS=100
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "child session '$SESS' is not running" <<<"$OUT" \
    || fail "watcher must report the dead session: $OUT"
  [ "$(send_keys_calls)" -eq 0 ] || fail "no keys expected: $TLOG"
}

# ---------------------------------------------------------------------------
# Scenarios: the spawn wiring (real sub-spawn.sh, fake treehouse/tmux)
# ---------------------------------------------------------------------------

make_spawn_fixture() {
  local dir=$1
  mkdir -p "$dir"
  git init -q --bare "$dir/remote.git"
  git -C "$dir/remote.git" symbolic-ref HEAD refs/heads/master
  git init -q "$dir/seed"
  git -C "$dir/seed" symbolic-ref HEAD refs/heads/master
  git -C "$dir/seed" config user.email t@t
  git -C "$dir/seed" config user.name t
  : > "$dir/seed/f"
  git -C "$dir/seed" add f
  git -C "$dir/seed" commit -qm init
  git -C "$dir/seed" remote add origin "$dir/remote.git"
  git -C "$dir/seed" push -q origin master
  git -C "$dir/seed" push -q origin master:development
  git clone -q "$dir/remote.git" "$dir/repo"
  git -C "$dir/repo" config user.email t@t
  git -C "$dir/repo" config user.name t
  git -C "$dir/repo" fetch -q origin
  git -C "$dir/repo" worktree add -q --detach "$dir/wt"
  mkdir -p "$dir/tmux"
  : > "$dir/tmux/pane"
  : > "$dir/tmux/log"
  printf 'ok\n' > "$dir/tmux/mode"
}

run_spawn() { # <fixture-dir> [no-watch]
  local fx=$1 no_watch=${2:-}
  local envs=(env -u TMUX -u TMUX_PANE -u MAIN_SESSION
    PI_BOOT_DELAY=0 SUB_SPAWN_NO_VIEWER=1
    FAKE_TMUX_DIR="$fx/tmux"
    FAKE_WT="$fx/wt"
    DEV_BRANCH=development
    PATH="$BINDIR:$PATH")
  if [ "$no_watch" = no-watch ]; then envs+=(SUB_SPAWN_NO_WATCH=1); fi
  RC=0
  OUT=$("${envs[@]}" bash "$SPAWN" "$TASK" "$fx/repo" 2>"$fx/spawn-stderr") || RC=$?
  ERR=$(cat "$fx/spawn-stderr")
}

t_req12_every_spawn_arms_the_child_watcher() {
  jq_ok || return 0
  local fx="$SCRATCH/spawn-watch"
  make_spawn_fixture "$fx"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "spawn exit=$RC stderr=$ERR"
  grep -q 'new-window' "$fx/tmux/log" || fail "no watcher window created: $(cat "$fx/tmux/log")"
  grep -q 'lavish-watch' "$fx/tmux/log" || fail "watcher window not named: $(cat "$fx/tmux/log")"
  grep -qF 'sub-lavish-watch.sh' "$fx/tmux/log" || fail "watcher script not launched: $(cat "$fx/tmux/log")"
  grep -qF 'watch:    lavish-watch window' <<<"$OUT" || fail "handles must report the watcher: $OUT"

  local fx2="$SCRATCH/spawn-nowatch"
  make_spawn_fixture "$fx2"
  run_spawn "$fx2" no-watch
  [ "$RC" -eq 0 ] || fail "spawn exit=$RC stderr=$ERR"
  grep -q 'new-window' "$fx2/tmux/log" && fail "SUB_SPAWN_NO_WATCH=1 must skip the watcher"
  grep -qF 'watch:    disabled' <<<"$OUT" || fail "opt-out must be reported: $OUT"
  return 0
}

t_req13_watcher_failure_does_not_fail_the_spawn() {
  jq_ok || return 0
  local fx="$SCRATCH/spawn-watcher-fail"
  make_spawn_fixture "$fx"
  printf 'no-new-window\n' > "$fx/tmux/mode"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "spawn must succeed without the watcher, got exit=$RC stderr=$ERR"
  grep -qF 'could not create the lavish-watch window' <<<"$ERR" \
    || fail "must warn about the missing watcher: $ERR"
  grep -qF 'watch:    unavailable' <<<"$OUT" || fail "handles must show the watcher unavailable: $OUT"
}

t_req14_touched_scripts_shellcheck_clean() {
  bash -n "$WATCH" || fail "bash -n reported syntax errors in $WATCH"
  bash -n "$SPAWN" || fail "bash -n reported syntax errors in $SPAWN"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$WATCH" "$SPAWN" || fail "shellcheck reported findings"
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

setup_fakes

run "[REQ-1] queued feedback wakes the child"                        t_req1_queued_feedback_wakes_the_child
run "[REQ-2] watcher never polls or consumes feedback"               t_req2_watcher_never_polls_or_consumes
run "[REQ-3] sessions outside the worktree are ignored"              t_req3_sessions_outside_the_worktree_are_ignored
run "[REQ-4] ended sessions are ignored"                             t_req4_ended_sessions_are_ignored
run "[REQ-5] stale sessions are ignored"                             t_req5_stale_sessions_are_ignored
run "[REQ-6] no queued feedback means no wake"                       t_req6_no_queued_feedback_means_no_wake
run "[REQ-7] unchanged batch is woken once"                          t_req7_unchanged_batch_is_woken_once
run "[REQ-8] additional feedback wakes again"                        t_req8_additional_feedback_wakes_again
run "[REQ-9] pane not running pi is never woken"                     t_req9_pane_not_running_pi_is_never_woken
run "[REQ-10] unconfirmed wake retried, never claimed"               t_req10_unconfirmed_wake_is_retried_never_claimed
run "[REQ-11] watcher stops with the child session"                  t_req11_watcher_stops_with_the_child_session
run "[REQ-12] every spawn arms the child watcher"                    t_req12_every_spawn_arms_the_child_watcher
run "[REQ-13] watcher failure does not fail the spawn"               t_req13_watcher_failure_does_not_fail_the_spawn
run "[REQ-14] touched scripts shellcheck-clean"                      t_req14_touched_scripts_shellcheck_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
