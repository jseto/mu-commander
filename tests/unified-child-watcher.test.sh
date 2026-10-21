#!/usr/bin/env bash
# Behavioural tests for the unified per-child watcher
# (specs/unified-child-watcher/unified-child-watcher.feature); one test per
# Scenario, labels [REQ-n].
#
# This suite is also the regression seam for specs/orchestrator-stall-recovery
# [REQ-25]: the child stall service stays notify-only with the loose pane
# signature, and none of these scenarios may change while the orchestrator
# watcher gets its own strict detector.
#
# Hermetic: fake `tmux`, `gh`, `treehouse`, `git`, and `lavish-axi` binaries
# live in a scratch dir first on PATH; per-case fixture JSON drives the PR
# read, the lease state, and the Lavish state file; the child pane is a file.
# Bounded watcher ticks and tiny intervals keep the suite fast. No real tmux
# session, worktree pool, GitHub call, or Lavish installation is ever touched.
# SC2317: test functions are invoked indirectly via run(); SC2016: fixture
# snippets are deliberately single-quoted.
# shellcheck disable=SC2317,SC2016
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WATCH=${SUB_WATCH_UNDER_TEST:-$ROOT/scripts/sub-watch.sh}
SPAWN=${SUB_SPAWN_UNDER_TEST:-$ROOT/scripts/sub-spawn.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }
jq_ok() { command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not on PATH\n' >&2; return 0; }; }

TASK=demo
SESS=pi-demo
MAIN_SESS=pi-main
BRANCH=task/demo
FAILURE_TEXT='FreeUsageLimitError: 429: {"type":"FreeUsageLimitError","message":"Rate limit exceeded. Please try again later."}'

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
REAL_GIT=$(command -v git)

# ---------------------------------------------------------------------------
# Fake tools
# ---------------------------------------------------------------------------

setup_fakes() {
  BINDIR="$SCRATCH/bin"
  mkdir -p "$BINDIR"

  cat > "$BINDIR/tmux" <<'EOS'
#!/usr/bin/env bash
# Stateful hermetic fake tmux. Sessions, panes, windows and the call log live
# under $FAKE_TMUX_DIR. Pane content is keyed by the normalized target
# ("=pi-main:" -> panes/pi-main), so a notice aimed at the main session can
# never land in the child's pane. Enter appends a tick line (a visible pane
# change, which is what the verified sends confirm against); modes:
#   ok               normal
#   drop-enter       Enter is swallowed (the send can never be confirmed)
#   pane-bash        display-message reports a non-pi pane
#   no-watch-window  the unified watch window is refused
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S/panes" "$S/sessions" "$S/windows"
[ -f "$S/log" ] || : > "$S/log"
[ -f "$S/mode" ] || printf 'ok\n' > "$S/mode"
mode=$(cat "$S/mode")

norm() { local t=${1#=}; t=${t%:}; printf '%s' "$t"; }
pane_of() { printf '%s/panes/%s' "$S" "$(norm "$1")"; }

printf '%s\n' "$*" >> "$S/log"
cmd=${1:-}; shift || true
case "$cmd" in
  has-session)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=${2:-}; shift 2 ;; *) shift ;; esac
    done
    [ -e "$S/sessions/$(norm "$target")" ] ;;
  new-session)
    name=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -s) name=${2:-}; shift 2 ;;
        -e|-c) shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$name" ] || exit 0
    : > "$S/sessions/$name"
    [ -e "$S/panes/$name" ] || : > "$S/panes/$name" ;;
  kill-session)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=${2:-}; shift 2 ;; *) shift ;; esac
    done
    rm -f "$S/sessions/$(norm "$target")" "$S/panes/$(norm "$target")" ;;
  send-keys)
    target= literal=0 text=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) target=${2:-}; shift 2 ;;
        -l) literal=1; shift ;;
        *) text=$1; shift ;;
      esac
    done
    p=$(pane_of "$target")
    [ -e "$p" ] || : > "$p"
    if [ "$literal" = 1 ]; then
      printf '%s' "$text" >> "$p"
    elif [ "$mode" != drop-enter ]; then
      printf '\n[enter]\n' >> "$p"
    fi ;;
  capture-pane)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=${2:-}; shift 2 ;; *) shift ;; esac
    done
    p=$(pane_of "$target")
    [ -e "$p" ] || exit 1
    cat "$p" ;;
  display-message)
    if [ "$mode" = pane-bash ]; then printf 'bash\n'; else printf 'pi\n'; fi ;;
  list-windows) : ;;
  new-window)
    name=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -t|-c) shift 2 ;;
        *) shift ;;
      esac
    done
    [ "$mode" = no-watch-window ] && [ "$name" = watch ] && exit 1
    [ -n "$name" ] && : > "$S/windows/$name"
    : ;;
  *) : ;;
esac
EOS
  chmod +x "$BINDIR/tmux"

  cat > "$BINDIR/gh" <<'EOS'
#!/usr/bin/env bash
# Fake gh: logs every invocation (so a test can prove only read-only queries
# happened) and serves the fixture PR-list JSON plus the read-only review
# attribution query. $FAKE_GH_FAIL names a marker file whose presence makes
# the read fail, like a missing login or a network error.
set -u
printf '%s\n' "$*" >> "${FAKE_GH_LOG:-/dev/null}"
[ -n "${FAKE_GH_FAIL:-}" ] && [ -e "$FAKE_GH_FAIL" ] && exit 1
case "${1:-}" in
  pr)
    shift
    case "${1:-}" in
      list)
        cat "${FAKE_GH_STATE:?FAKE_GH_STATE not set}"
        exit 0 ;;
    esac ;;
  api)
    shift
    case "${1:-}" in
      graphql)
        shift
        id=
        while [ "$#" -gt 0 ]; do
          case "$1" in id=*) id=${1#id=} ;; esac
          shift
        done
        [ -n "${FAKE_GH_GRAPHQL_FAIL:-}" ] && [ -e "$FAKE_GH_GRAPHQL_FAIL" ] && exit 1
        jq -r --arg id "$id" '.[$id] // 1' "${FAKE_GH_GRAPHQL_STATE:?FAKE_GH_GRAPHQL_STATE not set}"
        exit 0 ;;
    esac ;;
esac
exit 1
EOS
  chmod +x "$BINDIR/gh"

  cat > "$BINDIR/treehouse" <<'EOS'
#!/usr/bin/env bash
# Fake treehouse: `status --json` prints the fixture document (an array of
# leases); a failing read is signalled by $FAKE_TREEHOUSE_FAIL.
set -u
printf '%s\n' "$*" >> "${FAKE_TREEHOUSE_LOG:-/dev/null}"
[ -n "${FAKE_TREEHOUSE_FAIL:-}" ] && [ -e "$FAKE_TREEHOUSE_FAIL" ] && exit 1
case "${1:-}" in
  status)
    if [ -n "${FAKE_TREEHOUSE_STATE:-}" ] && [ -f "$FAKE_TREEHOUSE_STATE" ]; then
      cat "$FAKE_TREEHOUSE_STATE"
    else
      printf '[]\n'
    fi ;;
  get) printf '%s\n' "${FAKE_WT:?FAKE_WT not set}" ;;
  return) : ;;
  *) : ;;
esac
EOS
  chmod +x "$BINDIR/treehouse"

  cat > "$BINDIR/git" <<'EOS'
#!/usr/bin/env bash
# Fake git: logs every invocation (so a test can prove the watcher never
# pushes or merges) and delegates to the real binary.
set -u
printf '%s\n' "$*" >> "${FAKE_GIT_LOG:-/dev/null}"
exec "${REAL_GIT:?REAL_GIT not set}" "$@"
EOS
  chmod +x "$BINDIR/git"

  cat > "$BINDIR/lavish-axi" <<'EOS'
#!/usr/bin/env bash
# Logs every invocation; the watcher must never call this.
printf '%s\n' "$*" >> "${LAVISH_AXI_CALLS:-/dev/null}"
EOS
  chmod +x "$BINDIR/lavish-axi"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

review_json() { # $1=login $2=state $3=submittedAt [$4=body] [$5=node id]
  jq -cn --arg l "$1" --arg s "$2" --arg t "$3" --arg b "${4:-}" \
        --arg i "${5:-PRR_${1}_${3}}" \
    '{id:$i,author:{login:$l},body:$b,state:$s,submittedAt:$t}'
}

reviews_json() { # zero or more review JSON strings -> array
  jq -cn --args '$ARGS.positional | map(fromjson)' "$@"
}

write_pr() { # $1=file $2=number $3=state $4=headRefName $5=reviews array
  local path=$1 number=$2 state=$3 branch=$4 reviews=$5 tmp
  tmp="$path.tmp.$$"
  jq -n --argjson n "$number" --arg s "$state" --arg b "$branch" \
        --argjson r "$reviews" '
    [{ number: $n,
       url: ("https://github.com/owner/repo/pull/\($n)"),
       state: $s,
       mergedAt: (if $s == "MERGED" then "2026-10-18T12:00:00Z" else null end),
       headRefName: $b,
       reviews: $r }]' > "$tmp"
  mv "$tmp" "$path"   # atomic: the watcher may read while a test mutates
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

write_lavish_state() { # $1=status $2=pending $3=updated $4=artifact [prompts]
  local status=$1 pending=$2 updated=$3 artifact=$4
  local prompts=${5:-'[{"uid":"","prompt":"","selector":"","tag":"prompt","text":"do the thing"}]'}
  jq -n --arg f "$artifact" --arg s "$status" --arg u "$updated" \
        --argjson p "$pending" --argjson pr "$prompts" \
        '{sessions:{sess1:{key:"sess1",file:$f,status:$s,pending_prompts:$p,updated_at:$u,prompts:$pr}}}' \
    > "$STATE_DIR/state.json"
}

new_watch_case() { # $1=unique case id
  CASE="$SCRATCH/$1"
  rm -rf "$CASE"
  mkdir -p "$CASE"
  REPO="$CASE/repo"
  git init -q "$REPO"
  WT="$CASE/wt"
  mkdir -p "$WT/.lavish"
  TMUX_DIR="$CASE/tmux"
  mkdir -p "$TMUX_DIR/sessions" "$TMUX_DIR/panes" "$TMUX_DIR/windows"
  : > "$TMUX_DIR/log"
  printf 'ok\n' > "$TMUX_DIR/mode"
  : > "$TMUX_DIR/sessions/$SESS"
  : > "$TMUX_DIR/sessions/$MAIN_SESS"
  : > "$TMUX_DIR/panes/$SESS"
  : > "$TMUX_DIR/panes/$MAIN_SESS"
  STATE_DIR="$CASE/lavish"
  mkdir -p "$STATE_DIR"
  GH_STATE="$CASE/prs.json"
  printf '[]\n' > "$GH_STATE"
  GH_LOG="$CASE/gh.log"
  : > "$GH_LOG"
  GH_FAIL="$CASE/gh-fail"
  GH_GRAPHQL_STATE="$CASE/review-comments.json"
  printf '{}\n' > "$GH_GRAPHQL_STATE"
  GH_GRAPHQL_FAIL="$CASE/gh-graphql-fail"
  TH_STATE="$CASE/leases.json"
  TH_FAIL="$CASE/th-fail"
  printf '[{"path":"%s","lease_holder":"%s"}]\n' "$WT" "$TASK" > "$TH_STATE"
  GIT_LOG="$CASE/git.log"
  : > "$GIT_LOG"
  AXI_CALLS="$CASE/axi-calls"
  unset SERVICES INTERVAL RETRY REWAKE MARGIN L_TICKS P_TICKS S_TICKS SCAN_LINES 2>/dev/null || true
}

run_watcher() {
  RC=0
  OUT=$(env -u MAIN_PANE \
        MAIN_SESSION="$MAIN_SESS" \
        SUB_WATCH_SERVICES="${SERVICES-lavish,pr,stall}" \
        LAVISH_AXI_STATE_DIR="$STATE_DIR" \
        LAVISH_WATCH_INTERVAL="${INTERVAL:-0.2}" \
        LAVISH_WATCH_RETRY_SECONDS="${RETRY:-0}" \
        LAVISH_WATCH_REWAKE_SECONDS="${REWAKE:-9999}" \
        LAVISH_WATCH_TICKS="${L_TICKS:-2}" \
        LAVISH_WATCH_START_MARGIN="${MARGIN:-60}" \
        LAVISH_AXI_CALLS="$AXI_CALLS" \
        PR_WATCH_INTERVAL="${INTERVAL:-0.2}" \
        PR_WATCH_RETRY_SECONDS="${RETRY:-0}" \
        PR_WATCH_TICKS="${P_TICKS:-2}" \
        STALL_WATCH_INTERVAL="${INTERVAL:-0.2}" \
        STALL_WATCH_RETRY_SECONDS="${RETRY:-0}" \
        STALL_WATCH_REWAKE_SECONDS="${REWAKE:-9999}" \
        STALL_WATCH_TICKS="${S_TICKS:-2}" \
        STALL_WATCH_SCAN_LINES="${SCAN_LINES:-50}" \
        FAKE_TMUX_DIR="$TMUX_DIR" \
        FAKE_GH_STATE="$GH_STATE" \
        FAKE_GH_LOG="$GH_LOG" \
        FAKE_GH_FAIL="$GH_FAIL" \
        FAKE_GH_GRAPHQL_STATE="$GH_GRAPHQL_STATE" \
        FAKE_GH_GRAPHQL_FAIL="$GH_GRAPHQL_FAIL" \
        FAKE_TREEHOUSE_STATE="$TH_STATE" \
        FAKE_TREEHOUSE_FAIL="$TH_FAIL" \
        FAKE_WT="$WT" \
        REAL_GIT="$REAL_GIT" \
        PATH="$BINDIR:$PATH" \
        bash "$WATCH" "$TASK" "$REPO" "$BRANCH" 2>"$CASE/stderr") || RC=$?
  ERR=$(cat "$CASE/stderr")
  MAIN_PANE_TEXT=$(cat "$TMUX_DIR/panes/$MAIN_SESS" 2>/dev/null || true)
  CHILD_PANE_TEXT=$(cat "$TMUX_DIR/panes/$SESS" 2>/dev/null || true)
  TLOG=$(cat "$TMUX_DIR/log" 2>/dev/null || true)
  GHLOG=$(cat "$GH_LOG" 2>/dev/null || true)
  GITLOG=$(cat "$GIT_LOG" 2>/dev/null || true)
}

# --- log readers -----------------------------------------------------------

delivered_count() { grep -cF 'notice delivered' <<<"$OUT" || true; }
literal_send_count() { grep -cE '^send-keys .* -l ' <<<"$TLOG" || true; }
gh_list_count() { grep -cE '^pr list( |$)' <<<"$GHLOG" || true; }
stall_epoch_count() { grep -oE '\[stall-watch [0-9]+\]' <<<"$TLOG" | sort -u | wc -l; }
stall_pane_count() { grep -oF 'STUCK:' <<<"$MAIN_PANE_TEXT" | wc -l; }
wake_count() { grep -cF "woke '$TASK' for Lavish feedback" <<<"$OUT" || true; }

# ---------------------------------------------------------------------------
# Scenarios: the watcher
# ---------------------------------------------------------------------------

t_req1_every_spawn_arms_one_watcher_window() {
  jq_ok || return 0
  local fx="$SCRATCH/spawn-default"
  make_spawn_fixture "$fx"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "spawn exit=$RC stderr=$ERR"
  local windows
  windows=$(grep -cE -- '-n watch( |$)' <<<"$TLOG" || true)
  [ "$windows" -eq 1 ] || fail "exactly one watch window expected: $TLOG"
  grep -qF -- "sub-watch.sh $TASK $fx/repo $BRANCH" <<<"$TLOG" \
    || fail "the watch window must run the unified watcher for task/root/branch: $TLOG"
  grep -qF 'SUB_WATCH_SERVICES=lavish' <<<"$TLOG" \
    || fail "the watcher must be armed with the default services: $TLOG"
  grep -qE -- '-n lavish-watch( |$)' <<<"$TLOG" && fail "no per-service lavish window may exist: $TLOG"
  grep -qE -- '-n pr-watch( |$)' <<<"$TLOG" && fail "no per-service pr window may exist: $TLOG"
  grep -qF 'watch:    watch window in pi-demo (services: lavish,pr,stall)' <<<"$OUT" \
    || fail "the handles must report the watch window: $OUT"
}

t_req2_three_services_run_in_one_process() {
  jq_ok || return 0
  new_watch_case all-services
  write_lavish_state open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  write_pr "$GH_STATE" 31 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  printf '%s' "$FAILURE_TEXT" > "$TMUX_DIR/panes/$SESS"
  L_TICKS=2; P_TICKS=2; S_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'plan.html (2 prompts)' <<<"$CHILD_PANE_TEXT" \
    || fail "the Lavish wake must reach the child pane: $CHILD_PANE_TEXT"
  grep -qF '[demo] PR #31' <<<"$MAIN_PANE_TEXT" \
    || fail "the review notice must reach the orchestrator: $MAIN_PANE_TEXT"
  grep -qF '[demo] STUCK:' <<<"$MAIN_PANE_TEXT" \
    || fail "the stall notice must reach the orchestrator: $MAIN_PANE_TEXT"
  [ "$(delivered_count)" -eq 2 ] || fail "two notices expected (review + stall): $OUT"
  [ "$(grep -cF "watching '$TASK' with services" <<<"$OUT")" -eq 1 ] \
    || fail "all services must run in one watcher process: $OUT"
}

t_req3_service_selection_restricts_the_watcher() {
  jq_ok || return 0
  new_watch_case selection-pr
  write_lavish_state open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  write_pr "$GH_STATE" 32 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  printf '%s' "$FAILURE_TEXT" > "$TMUX_DIR/panes/$SESS"
  SERVICES=pr; P_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF '[demo] PR #32' <<<"$MAIN_PANE_TEXT" \
    || fail "the review notice must be sent: $MAIN_PANE_TEXT"
  grep -qF 'STUCK:' <<<"$MAIN_PANE_TEXT" && fail "no stall notice may be sent: $MAIN_PANE_TEXT"
  grep -qF 'Lavish feedback queued' <<<"$CHILD_PANE_TEXT" \
    && fail "the Lavish service must not run: $CHILD_PANE_TEXT"
  [ "$(literal_send_count)" -eq 1 ] \
    || fail "only the one notice may be typed: $TLOG"
}

t_req4_unknown_service_name_warns_and_is_ignored() {
  jq_ok || return 0
  new_watch_case selection-unknown
  write_lavish_state open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  SERVICES=lavish,bogus; L_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "unknown watch service 'bogus'" <<<"$ERR" \
    || fail "the unknown service must warn: $ERR"
  grep -qF 'plan.html (2 prompts)' <<<"$CHILD_PANE_TEXT" \
    || fail "the Lavish service must still run: $CHILD_PANE_TEXT"
}

t_req5_empty_selection_exits_without_watching() {
  jq_ok || return 0
  new_watch_case selection-empty
  write_lavish_state open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  SERVICES=
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'no watch service selected' <<<"$OUT" \
    || fail "the empty selection must be reported: $OUT"
  [ -z "$CHILD_PANE_TEXT" ] || fail "no service may scan: $CHILD_PANE_TEXT"
  [ ! -s "$GH_LOG" ] || fail "no service may read the PR: $(cat "$GH_LOG")"
}

t_req6_a_bounded_service_stops_without_stopping_the_others() {
  jq_ok || return 0
  new_watch_case bounded-service
  write_lavish_state open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  (
    sleep 0.6
    write_pr "$GH_STATE" 33 OPEN "$BRANCH" \
      "$(reviews_json "$(review_json bob APPROVED 2026-10-18T10:00:00Z)")"
  ) &
  local mutator=$!
  L_TICKS=1; P_TICKS=8; S_TICKS=1; INTERVAL=0.2
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(wake_count)" -eq 1 ] || fail "the Lavish service must scan exactly once: $OUT"
  [ "$(gh_list_count)" -ge 2 ] || fail "the PR service must keep scanning: $GHLOG"
  grep -qF '[demo] PR #33' <<<"$MAIN_PANE_TEXT" \
    || fail "the later review must still be notified: $MAIN_PANE_TEXT"
}

t_req7_watcher_stops_when_the_child_session_goes_away() {
  jq_ok || return 0
  new_watch_case session-gone
  write_pr "$GH_STATE" 34 MERGED "$BRANCH" "$(reviews_json)"
  write_lavish_state open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  rm -f "$TMUX_DIR/sessions/$SESS"
  L_TICKS=100; P_TICKS=100; S_TICKS=100
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "child session '$SESS' is not running" <<<"$OUT" \
    || fail "the watcher must report the dead session: $OUT"
  [ ! -s "$GH_LOG" ] || fail "a dead child must not even read the PR: $(cat "$GH_LOG")"
  [ "$(literal_send_count)" -eq 0 ] || fail "no keys may be sent: $TLOG"
}

t_req8_watcher_stops_when_the_lease_disappears() {
  jq_ok || return 0
  new_watch_case lease-gone
  write_pr "$GH_STATE" 35 MERGED "$BRANCH" "$(reviews_json)"
  printf '[]\n' > "$TH_STATE"
  L_TICKS=100; P_TICKS=100; S_TICKS=100
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "no worktree lease for '$TASK'" <<<"$OUT" \
    || fail "the watcher must report the returned lease: $OUT"
  [ ! -s "$GH_LOG" ] || fail "a returned lease must not read the PR: $(cat "$GH_LOG")"
  [ "$(literal_send_count)" -eq 0 ] || fail "no keys may be sent: $TLOG"
}

t_req9_unreadable_lease_warns_and_keeps_watching() {
  jq_ok || return 0
  new_watch_case lease-unknown
  write_pr "$GH_STATE" 36 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  : > "$TH_FAIL"
  (
    sleep 0.5
    rm -f "$TH_FAIL"
  ) &
  local mutator=$!
  SERVICES=pr; P_TICKS=10; INTERVAL=0.2
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'could not read treehouse status' <<<"$ERR" \
    || fail "a failing treehouse status must warn: $ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "the watcher must notify once the read recovers: $OUT"
  grep -qF 'review from alice' <<<"$MAIN_PANE_TEXT" \
    || fail "review notice expected: $MAIN_PANE_TEXT"
}

t_req10_lavish_wake_keeps_its_guarantees() {
  jq_ok || return 0
  new_watch_case lavish-guarantees
  write_lavish_state open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  cp "$STATE_DIR/state.json" "$CASE/state.before"
  SERVICES=lavish; L_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'plan.html (2 prompts)' <<<"$CHILD_PANE_TEXT" \
    || fail "the wake must name the artifact and count: $CHILD_PANE_TEXT"
  grep -qF 'lavish-axi poll' <<<"$CHILD_PANE_TEXT" \
    || fail "the wake must instruct the child to poll: $CHILD_PANE_TEXT"
  [ ! -e "$AXI_CALLS" ] || fail "the watcher ran lavish-axi: $(cat "$AXI_CALLS")"
  cmp -s "$STATE_DIR/state.json" "$CASE/state.before" \
    || fail "the watcher must not touch the Lavish state file"
}

t_req11_pr_service_keeps_its_read_only_guarantee() {
  jq_ok || return 0
  new_watch_case pr-guarantees
  write_pr "$GH_STATE" 37 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice CHANGES_REQUESTED 2026-10-18T10:00:00Z)")"
  SERVICES=pr; P_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ -n "$GHLOG" ] || fail "expected the watcher to read the PR"
  if grep -Evq '^(pr list( |$)|api graphql( |$))' <<<"$GHLOG"; then
    fail "every gh call must be a read-only query: $GHLOG"
  fi
  if grep -Eq '(^| )(merge|close|comment|review|edit|create|push|reopen|ready)( |$)' <<<"$GHLOG"; then
    fail "the watcher must never mutate GitHub: $GHLOG"
  fi
  if grep -Eq '(^| )(push|merge|commit|checkout|reset|clean)( |$)' <<<"$GITLOG"; then
    fail "the watcher must never push or change the repository: $GITLOG"
  fi
  local sends
  sends=$(grep -E '^send-keys ' <<<"$TLOG" || true)
  [ -n "$sends" ] || fail "expected the notice keys to be sent"
  if grep -vqF -- '-t =pi-main:' <<<"$sends"; then
    fail "every send-keys call must target the main session: $sends"
  fi
  grep -qF "$SESS" <<<"$sends" && fail "keys must never target the child's pane: $sends"
  [ -z "$CHILD_PANE_TEXT" ] || fail "the child pane must stay untouched: $CHILD_PANE_TEXT"
}

t_req12_terminal_notice_stops_only_the_pr_service() {
  jq_ok || return 0
  new_watch_case terminal-only-pr
  write_pr "$GH_STATE" 38 MERGED "$BRANCH" "$(reviews_json)"
  (
    for _ in $(seq 1 400); do
      grep -q 'was MERGED' "$TMUX_DIR/panes/$MAIN_SESS" 2>/dev/null && break
      sleep 0.05
    done
    write_lavish_state open 2 "$(now_utc)" "$WT/.lavish/plan.html"
  ) &
  local mutator=$!
  L_TICKS=8; P_TICKS=8; S_TICKS=8; INTERVAL=0.2
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(gh_list_count)" -eq 1 ] || fail "the PR service must stop after the merged notice: $GHLOG"
  grep -qF 'was MERGED' <<<"$MAIN_PANE_TEXT" || fail "merged notice expected: $MAIN_PANE_TEXT"
  grep -qF 'Lavish feedback queued' <<<"$CHILD_PANE_TEXT" \
    || fail "the Lavish service must keep watching: $CHILD_PANE_TEXT"
}

t_req13_free_provider_failure_sends_a_stuck_notice() {
  jq_ok || return 0
  new_watch_case stall-notice
  printf '%s' "$FAILURE_TEXT" > "$TMUX_DIR/panes/$SESS"
  SERVICES=stall; S_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF '[demo] STUCK:' <<<"$MAIN_PANE_TEXT" \
    || fail "the stall notice must carry the task prefix: $MAIN_PANE_TEXT"
  grep -qF 'sub-fallback.sh demo' <<<"$MAIN_PANE_TEXT" \
    || fail "the notice must name the recovery helper: $MAIN_PANE_TEXT"
  grep -qF 'nudge the child to continue' <<<"$MAIN_PANE_TEXT" \
    || fail "the notice must ask for the continue nudge: $MAIN_PANE_TEXT"
  grep -qE '\[stall-watch [0-9]+\]' <<<"$MAIN_PANE_TEXT" \
    || fail "the notice must end with the per-attempt marker: $MAIN_PANE_TEXT"
}

t_req14_stall_service_is_notify_only() {
  jq_ok || return 0
  new_watch_case stall-notify-only
  printf '%s' "$FAILURE_TEXT" > "$TMUX_DIR/panes/$SESS"
  SERVICES=stall; S_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(literal_send_count)" -eq 1 ] || fail "only the notice may be typed: $TLOG"
  local sends
  sends=$(grep -E '^send-keys ' <<<"$TLOG" || true)
  if grep -vqF -- '-t =pi-main:' <<<"$sends"; then
    fail "no keys may go anywhere but the orchestrator: $sends"
  fi
  grep -qF "$SESS" <<<"$sends" && fail "no keys may target the child's pane: $sends"
  grep -qF '/model' <<<"$TLOG" && fail "the watcher must never send a model switch: $TLOG"
  [ ! -s "$GH_LOG" ] || fail "the stall service must not read GitHub: $(cat "$GH_LOG")"
  grep -qF 'STUCK:' <<<"$CHILD_PANE_TEXT" && fail "the notice must not reach the child pane"
  return 0
}

t_req15_confirmed_stall_notice_is_not_repeated() {
  jq_ok || return 0
  new_watch_case stall-dedupe
  printf '%s' "$FAILURE_TEXT" > "$TMUX_DIR/panes/$SESS"
  SERVICES=stall; S_TICKS=4; INTERVAL=0.2; RETRY=0; REWAKE=9999
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "exactly one stall notice expected: $OUT"
  [ "$(stall_pane_count)" -eq 1 ] \
    || fail "the failure staying visible must not re-notify: $MAIN_PANE_TEXT"
  [ "$(literal_send_count)" -eq 1 ] || fail "one typed notice expected: $TLOG"
}

t_req16_unconfirmed_stall_notice_is_retried_never_claimed() {
  jq_ok || return 0
  new_watch_case stall-retry
  printf '%s' "$FAILURE_TEXT" > "$TMUX_DIR/panes/$SESS"
  printf 'drop-enter\n' > "$TMUX_DIR/mode"
  (
    for _ in $(seq 1 400); do
      n=$(grep -cE '^send-keys .* Enter$' "$TMUX_DIR/log" 2>/dev/null || true)
      [ "${n:-0}" -ge 4 ] && break
      sleep 0.05
    done
    printf 'ok\n' > "$TMUX_DIR/mode"
  ) &
  local mutator=$!
  SERVICES=stall; S_TICKS=6; INTERVAL=0.1; RETRY=0
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "could not confirm the stall notice for '$TASK'" <<<"$ERR" \
    || fail "an unconfirmed notice must warn: $ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "only the confirmed retry may be claimed delivered: $OUT"
  [ "$(literal_send_count)" -eq 2 ] \
    || fail "expected the failed attempt plus exactly one confirmed retry: $TLOG"
  [ "$(stall_epoch_count)" -ge 2 ] \
    || fail "a retry must carry a fresh [stall-watch <epoch>] marker: $TLOG"
}

t_req17_cleared_failure_notifies_again() {
  jq_ok || return 0
  new_watch_case stall-cleared
  printf '%s' "$FAILURE_TEXT" > "$TMUX_DIR/panes/$SESS"
  (
    for _ in $(seq 1 400); do
      grep -qF 'STUCK:' "$TMUX_DIR/panes/$MAIN_SESS" 2>/dev/null && break
      sleep 0.05
    done
    printf 'working normally\n' > "$TMUX_DIR/panes/$SESS"
    sleep 1.5
    printf '%s' "$FAILURE_TEXT" > "$TMUX_DIR/panes/$SESS"
  ) &
  local mutator=$!
  SERVICES=stall; S_TICKS=8; INTERVAL=0.2; RETRY=0; REWAKE=9999
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(stall_pane_count)" -eq 2 ] \
    || fail "a cleared failure must let the next one notify again: $MAIN_PANE_TEXT"
  [ "$(stall_epoch_count)" -ge 2 ] || fail "two distinct notices expected: $TLOG"
}

t_req21_reply_only_commented_review_is_never_routed() {
  jq_ok || return 0
  new_watch_case reply-only
  write_pr "$GH_STATE" 41 OPEN "$BRANCH" \
    "$(reviews_json \
        "$(review_json jseto COMMENTED 2026-10-18T16:21:12Z '' PRR_human)" \
        "$(review_json jseto COMMENTED 2026-10-18T18:04:27Z '' PRR_child)")"
  printf '{"PRR_child":0}\n' > "$GH_GRAPHQL_STATE"
  SERVICES=pr; P_TICKS=3
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "only the submitted review may be notified: $OUT"
  grep -qF 'got a COMMENTED review from jseto' <<<"$MAIN_PANE_TEXT" \
    || fail "the submitted review must be notified: $MAIN_PANE_TEXT"
  grep -qF 'is a reply to an existing thread; not notifying' <<<"$OUT" \
    || fail "the reply-only review must be recorded handled: $OUT"
  [ "$(grep -cF 'got a COMMENTED review' <<<"$MAIN_PANE_TEXT")" -eq 1 ] \
    || fail "the reply must never be notified: $MAIN_PANE_TEXT"
}

t_req22_unreadable_review_defers_only_itself() {
  jq_ok || return 0
  new_watch_case unreadable-review
  write_pr "$GH_STATE" 42 OPEN "$BRANCH" \
    "$(reviews_json \
        "$(review_json carol COMMENTED 2026-10-18T10:00:00Z '' PRR_unreadable)" \
        "$(review_json bob APPROVED 2026-10-18T10:05:00Z)")"
  : > "$GH_GRAPHQL_FAIL"
  (
    sleep 0.5
    rm -f "$GH_GRAPHQL_FAIL"
    printf '{"PRR_unreadable":1}\n' > "$GH_GRAPHQL_STATE"
  ) &
  local mutator=$!
  SERVICES=pr; P_TICKS=8; INTERVAL=0.2; RETRY=0
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'could not read the review comments' <<<"$ERR" \
    || fail "an unreadable attribution must warn: $ERR"
  [ "$(delivered_count)" -eq 2 ] \
    || fail "the later review and the recovered one must both be notified: $OUT"
  grep -qF 'got a APPROVED review from bob' <<<"$MAIN_PANE_TEXT" \
    || fail "the later review must not be starved: $MAIN_PANE_TEXT"
  grep -qF 'got a COMMENTED review from carol' <<<"$MAIN_PANE_TEXT" \
    || fail "the unreadable review must be notified once its read recovers: $MAIN_PANE_TEXT"
}

# ---------------------------------------------------------------------------
# Supplementary tests (edges the [REQ-n] scenarios do not pin)
# ---------------------------------------------------------------------------

t_supp_stall_scan_window_knob_is_honoured() {
  jq_ok || return 0
  local i
  new_watch_case stall-scan-window-small
  {
    printf '%s\n' "$FAILURE_TEXT"
    for (( i = 1; i <= 20; i++ )); do printf 'filler line %s\n' "$i"; done
  } > "$TMUX_DIR/panes/$SESS"
  SERVICES=stall; S_TICKS=1; SCAN_LINES=5
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'STUCK:' <<<"$MAIN_PANE_TEXT" \
    && fail "the failure sits outside the 5-line window: $MAIN_PANE_TEXT"

  new_watch_case stall-scan-window-default
  {
    printf '%s\n' "$FAILURE_TEXT"
    for (( i = 1; i <= 20; i++ )); do printf 'filler line %s\n' "$i"; done
  } > "$TMUX_DIR/panes/$SESS"
  SERVICES=stall; S_TICKS=1; SCAN_LINES=50
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'STUCK:' <<<"$MAIN_PANE_TEXT" \
    || fail "the default window must find the failure: $MAIN_PANE_TEXT"
  return 0
}

t_supp_lease_returned_mid_run_stops_the_watcher() {
  jq_ok || return 0
  new_watch_case lease-vanished
  (
    sleep 0.4
    printf '[]\n' > "$TH_STATE"
  ) &
  local mutator=$!
  SERVICES=pr; P_TICKS=10; INTERVAL=0.2
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "no worktree lease for '$TASK'" <<<"$OUT" \
    || fail "the vanished lease must stop the watcher: $OUT"
  [ "$(gh_list_count)" -ge 1 ] || fail "the watcher must have scanned at least once: $GHLOG"
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
  mkdir -p "$dir/tmux/sessions" "$dir/tmux/panes" "$dir/tmux/windows"
  : > "$dir/tmux/log"
  printf 'ok\n' > "$dir/tmux/mode"
}

run_spawn() { # $1=fixture-dir [$2=no-pr-watch|no-watch]
  local fx=$1 mode=${2:-}
  local envs=(env -u TMUX -u TMUX_PANE -u MAIN_SESSION -u MAIN_PANE
    PI_BOOT_DELAY=0
    SUB_SPAWN_NO_VIEWER=1
    REAL_GIT="$REAL_GIT"
    FAKE_TMUX_DIR="$fx/tmux"
    FAKE_WT="$fx/wt"
    DEV_BRANCH=development
    PATH="$BINDIR:$PATH")
  case $mode in
    no-pr-watch) envs+=(SUB_SPAWN_NO_PR_WATCH=1) ;;
    no-watch)    envs+=(SUB_SPAWN_NO_WATCH=1) ;;
    no-services) envs+=(SUB_SPAWN_NO_PR_WATCH=1 SUB_WATCH_SERVICES=pr) ;;
  esac
  RC=0
  OUT=$("${envs[@]}" bash "$SPAWN" "$TASK" "$fx/repo" 2>"$fx/spawn-stderr") || RC=$?
  ERR=$(cat "$fx/spawn-stderr")
  TLOG=$(cat "$fx/tmux/log" 2>/dev/null || true)
}

t_req18_spawn_knobs_disable_the_watcher_or_the_pr_service() {
  jq_ok || return 0
  local fx="$SCRATCH/spawn-no-pr"
  make_spawn_fixture "$fx"
  run_spawn "$fx" no-pr-watch
  [ "$RC" -eq 0 ] || fail "no-pr-watch spawn exit=$RC stderr=$ERR"
  grep -qE -- '-n watch( |$)' <<<"$TLOG" \
    || fail "SUB_SPAWN_NO_PR_WATCH=1 must keep the unified watcher: $TLOG"
  grep -qF 'SUB_WATCH_SERVICES=lavish\,stall' <<<"$TLOG" \
    || fail "SUB_SPAWN_NO_PR_WATCH=1 must arm the watcher without the PR service: $TLOG"
  grep -qF 'watch:    watch window in pi-demo (services: lavish,stall)' <<<"$OUT" \
    || fail "the handles must report the reduced service set: $OUT"

  local fx2="$SCRATCH/spawn-no-watch"
  make_spawn_fixture "$fx2"
  run_spawn "$fx2" no-watch
  [ "$RC" -eq 0 ] || fail "no-watch spawn exit=$RC stderr=$ERR"
  grep -qE -- '-n watch( |$)' <<<"$TLOG" && fail "SUB_SPAWN_NO_WATCH=1 must skip the watcher"
  grep -qF 'watch:    disabled (SUB_SPAWN_NO_WATCH=1)' <<<"$OUT" \
    || fail "the handles must report the watcher opt-out: $OUT"
}

t_req19_unstartable_watch_window_does_not_fail_spawn() {
  jq_ok || return 0
  local fx="$SCRATCH/spawn-watch-fail"
  make_spawn_fixture "$fx"
  printf 'no-watch-window\n' > "$fx/tmux/mode"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "spawn must succeed without the watch window, got exit=$RC stderr=$ERR"
  grep -qF 'could not create the watch window' <<<"$ERR" \
    || fail "the spawn must warn about the missing watch window: $ERR"
  grep -qF 'watch:    unavailable' <<<"$OUT" \
    || fail "the handles must show the watch window unavailable: $OUT"
  grep -qF 'session:  pi-demo' <<<"$OUT" \
    || fail "the spawn must still report the child: $OUT"
}

t_req20_touched_scripts_shellcheck_clean() {
  local f
  for f in "$ROOT/scripts/sub-watch.sh" "$ROOT/scripts/_sub-watch.sh" \
           "$ROOT/scripts/sub-lavish-watch.sh" "$ROOT/scripts/sub-pr-watch.sh" \
           "$ROOT/scripts/sub-spawn.sh"; do
    bash -n "$f" || fail "bash -n reported syntax errors in $f"
  done
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$ROOT/scripts/sub-watch.sh" "$ROOT/scripts/_sub-watch.sh" \
    "$ROOT/scripts/sub-lavish-watch.sh" "$ROOT/scripts/sub-pr-watch.sh" \
    "$ROOT/scripts/sub-spawn.sh" || fail "shellcheck reported findings"
}

t_supp_no_services_selection_arms_no_window() {
  jq_ok || return 0
  local fx="$SCRATCH/spawn-no-services"
  make_spawn_fixture "$fx"
  run_spawn "$fx" no-services
  [ "$RC" -eq 0 ] || fail "spawn exit=$RC stderr=$ERR"
  grep -qE -- '-n watch( |$)' <<<"$TLOG" \
    && fail "no window may be created with no service selected: $TLOG"
  grep -qF 'watch:    disabled (no service selected)' <<<"$OUT" \
    || fail "the handles must report the empty selection: $OUT"
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

run "[REQ-1] every spawn arms one watcher window"                     t_req1_every_spawn_arms_one_watcher_window
run "[REQ-2] three services run in one watcher process"              t_req2_three_services_run_in_one_process
run "[REQ-3] service selection restricts the watcher"                t_req3_service_selection_restricts_the_watcher
run "[REQ-4] unknown service name warns and is ignored"              t_req4_unknown_service_name_warns_and_is_ignored
run "[REQ-5] empty selection exits without watching"                 t_req5_empty_selection_exits_without_watching
run "[REQ-6] a bounded service stops without stopping the others"    t_req6_a_bounded_service_stops_without_stopping_the_others
run "[REQ-7] watcher stops when the child session goes away"         t_req7_watcher_stops_when_the_child_session_goes_away
run "[REQ-8] watcher stops when the lease disappears"                t_req8_watcher_stops_when_the_lease_disappears
run "[REQ-9] unreadable lease warns and keeps watching"              t_req9_unreadable_lease_warns_and_keeps_watching
run "[REQ-10] Lavish wake keeps its guarantees"                      t_req10_lavish_wake_keeps_its_guarantees
run "[REQ-11] PR service keeps its read-only guarantee"              t_req11_pr_service_keeps_its_read_only_guarantee
run "[REQ-12] terminal notice stops only the PR service"             t_req12_terminal_notice_stops_only_the_pr_service
run "[REQ-13] free-provider failure sends a STUCK notice"            t_req13_free_provider_failure_sends_a_stuck_notice
run "[REQ-14] stall service is notify-only"                          t_req14_stall_service_is_notify_only
run "[REQ-15] confirmed stall notice is not repeated"                t_req15_confirmed_stall_notice_is_not_repeated
run "[REQ-16] unconfirmed stall notice retried, never claimed"       t_req16_unconfirmed_stall_notice_is_retried_never_claimed
run "[REQ-17] cleared failure notifies again"                        t_req17_cleared_failure_notifies_again
run "[REQ-18] spawn knobs disable the watcher or the PR service"     t_req18_spawn_knobs_disable_the_watcher_or_the_pr_service
run "[REQ-19] unstartable watch window does not fail spawn"          t_req19_unstartable_watch_window_does_not_fail_spawn
run "[REQ-20] touched scripts shellcheck-clean"                      t_req20_touched_scripts_shellcheck_clean
run "[REQ-21] reply-only COMMENTED review is never routed"          t_req21_reply_only_commented_review_is_never_routed
run "[REQ-22] unreadable review defers only itself"                 t_req22_unreadable_review_defers_only_itself
run "supplementary: stall scan window knob is honoured"             t_supp_stall_scan_window_knob_is_honoured
run "supplementary: lease returned mid-run stops the watcher"       t_supp_lease_returned_mid_run_stops_the_watcher
run "supplementary: no service selected arms no window"             t_supp_no_services_selection_arms_no_window

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
