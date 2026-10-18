#!/usr/bin/env bash
# Behavioural tests for the per-child PR action watcher
# (specs/pr-action-watch/pr-action-watch.feature); one test per Scenario,
# labels [REQ-n].
#
# Hermetic: fake `tmux`, `gh`, `treehouse`, and `git` binaries live in a
# scratch dir first on PATH; per-case fixture JSON drives the branch PR read
# and the lease state; bounded watcher ticks and tiny intervals keep the
# suite fast. No real tmux session, worktree pool, GitHub call, or repository
# state is ever touched.
# SC2317: test functions are invoked indirectly via run(); SC2016: fixture
# snippets are deliberately single-quoted.
# shellcheck disable=SC2317,SC2016
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WATCH=${SUB_PR_WATCH_UNDER_TEST:-$ROOT/scripts/sub-pr-watch.sh}
SPAWN=${SUB_SPAWN_UNDER_TEST:-$ROOT/scripts/sub-spawn.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }
jq_ok() { command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not on PATH\n' >&2; return 0; }; }

TASK=demo
SESS=pi-demo
MAIN_SESS=pi-main
BRANCH=task/demo

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
# change, which is what the verified send confirms against); modes:
#   ok                  normal
#   drop-enter          Enter is swallowed (the send can never be confirmed)
#   no-pr-watch-window  only the pr-watch window is refused
#   steer               the main pane is a pi TUI mid-turn: Enter queues the
#                       submitted text as ONE truncated pending `Steering:`
#                       line instead of a transcript entry (the 2026-10-18
#                       duplicate-notice incident)
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S/panes" "$S/sessions" "$S/windows" "$S/pending" "$S/transcript"
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
    n=$(norm "$target")
    [ -e "$p" ] || : > "$p"
    if [ "$literal" = 1 ]; then
      printf '%s' "$text" >> "$p"
    elif [ "$mode" = steer ]; then
      # pi's steering queue while a turn runs: the pending display renders the
      # message as one line truncated to the pane width (TruncatedText(text,
      # 1, 0)), so the notice's tail marker never renders.
      if [ -s "$p" ]; then
        queued=$(cat "$p")
        printf '%s...\n' "${queued:0:24}" >> "$S/pending/$n"
        : > "$p"
      fi
    elif [ "$mode" != drop-enter ]; then
      printf '\n[enter]\n' >> "$p"
    fi ;;
  capture-pane)
    target=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) target=${2:-}; shift 2 ;; *) shift ;; esac
    done
    p=$(pane_of "$target")
    n=$(norm "$target")
    [ -e "$p" ] || exit 1
    if [ "$mode" = steer ]; then
      # A pi TUI mid-turn: transcript, pending ("Steering: <head>…", the
      # dequeue hint), working row, composer, status border, path, stats.
      [ -s "$S/transcript/$n" ] && cat "$S/transcript/$n"
      if [ -s "$S/pending/$n" ]; then
        printf '\n'
        while IFS= read -r q; do printf 'Steering: %s\n' "$q"; done < "$S/pending/$n"
        printf '↳ Alt+Up to edit all queued messages\n'
      fi
      printf '\n── ⠴ Working ────────────────────────────────────────────────────\n'
      if [ -s "$p" ]; then cat "$p"; printf '\n'; else printf '\n'; fi
      printf '%s\n' '────────────────────────────────────────────────────────────────────'
      printf '%s\n' '/test/worktree (task/demo)'
      printf 'stats line\n'
      exit 0
    fi
    cat "$p" ;;
  display-message) printf 'pi\n' ;;
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
    [ "$mode" = no-pr-watch-window ] && [ "$name" = pr-watch ] && exit 1
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
# every read fail, like a missing login or a network error;
# $FAKE_GH_GRAPHQL_FAIL makes only the review-comments query fail.
# $FAKE_GH_GRAPHQL_STATE is a JSON object mapping a review node id to the
# number of top-level comments that review has; an id not listed counts as 1
# (a normal submitted review carries a top-level comment).
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
# leases), `get` hands out $FAKE_WT.
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
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

review_json() { # $1=login $2=state $3=submittedAt [$4=body] [$5=node id] -> one review object
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

new_watch_case() { # $1=unique case id
  CASE="$SCRATCH/$1"
  rm -rf "$CASE"
  mkdir -p "$CASE"
  REPO="$CASE/repo"
  git init -q "$REPO"
  WT="$CASE/wt"
  mkdir -p "$WT"
  TMUX_DIR="$CASE/tmux"
  mkdir -p "$TMUX_DIR/sessions" "$TMUX_DIR/panes" "$TMUX_DIR/windows"
  mkdir -p "$TMUX_DIR/pending" "$TMUX_DIR/transcript"
  : > "$TMUX_DIR/log"
  printf 'ok\n' > "$TMUX_DIR/mode"
  : > "$TMUX_DIR/sessions/$SESS"
  : > "$TMUX_DIR/sessions/$MAIN_SESS"
  : > "$TMUX_DIR/panes/$SESS"
  : > "$TMUX_DIR/panes/$MAIN_SESS"
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
}

run_watcher() {
  local ticks=${W_TICKS:-2} interval=${W_INTERVAL:-0.2} retry=${W_RETRY:-0}
  RC=0
  OUT=$(env -u MAIN_PANE \
        MAIN_SESSION="$MAIN_SESS" \
        PR_WATCH_INTERVAL="$interval" \
        PR_WATCH_RETRY_SECONDS="$retry" \
        PR_WATCH_TICKS="$ticks" \
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

path_without_gh() {
  local out="" d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$d" = "$BINDIR" ] && continue
    [ -x "$d/gh" ] && continue
    out+="${out:+:}$d"
  done < <(printf '%s\n' "$PATH" | tr ':' '\n')
  printf '%s' "$out"
}

run_watcher_without_gh() {
  local nogh="$CASE/nogh" clean
  mkdir -p "$nogh"
  ln -sf "$BINDIR/tmux" "$nogh/tmux"
  ln -sf "$BINDIR/treehouse" "$nogh/treehouse"
  ln -sf "$BINDIR/git" "$nogh/git"
  clean=$(path_without_gh)
  if env PATH="$nogh:$clean" bash -c 'command -v gh >/dev/null'; then
    fail "gh must be absent from the restricted test PATH"
  fi
  RC=0
  OUT=$(env -u MAIN_PANE \
        MAIN_SESSION="$MAIN_SESS" \
        PR_WATCH_INTERVAL=0.2 \
        PR_WATCH_RETRY_SECONDS=0 \
        PR_WATCH_TICKS=2 \
        FAKE_TMUX_DIR="$TMUX_DIR" \
        FAKE_GH_STATE="$GH_STATE" \
        FAKE_GH_LOG="$GH_LOG" \
        FAKE_TREEHOUSE_STATE="$TH_STATE" \
        FAKE_TREEHOUSE_FAIL="$TH_FAIL" \
        FAKE_WT="$WT" \
        REAL_GIT="$REAL_GIT" \
        PATH="$nogh:$clean" \
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
enter_count() { grep -cE '^send-keys .* Enter$' <<<"$TLOG" || true; }
gh_list_count() { grep -cE '^pr list( |$)' <<<"$GHLOG" || true; }
# Review-comment attribution reads (fix-self-review-loop).
graphql_count() { grep -cE '^api graphql ' <<<"$GHLOG" || true; }
epoch_count() { grep -oE '\[pr-watch [0-9]+\]' <<<"$TLOG" | sort -u | wc -l; }
pane_epoch_count() { grep -oE '\[pr-watch [0-9]+\]' <<<"$MAIN_PANE_TEXT" | sort -u | wc -l; }

# ---------------------------------------------------------------------------
# Scenarios: the watcher
# ---------------------------------------------------------------------------

t_req1_merged_pr_sends_retire_notice() {
  jq_ok || return 0
  new_watch_case req1
  write_pr "$GH_STATE" 11 MERGED "$BRANCH" "$(reviews_json)"
  W_TICKS=5
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "expected one delivered notice: $OUT"
  grep -qF '[demo] PR #11' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must carry the task prefix and PR number: $MAIN_PANE_TEXT"
  grep -qF 'https://github.com/owner/repo/pull/11' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must name the PR URL: $MAIN_PANE_TEXT"
  grep -qF 'was MERGED' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must say the PR was MERGED: $MAIN_PANE_TEXT"
  grep -qF 'retire the child now' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must instruct the orchestrator to retire the child: $MAIN_PANE_TEXT"
  grep -qE '\[pr-watch [0-9]+\]' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must end with the per-attempt marker: $MAIN_PANE_TEXT"
  [ "$(grep -cF 'was MERGED' <<<"$MAIN_PANE_TEXT" || true)" -eq 1 ] \
    || fail "a terminal notice is sent exactly once: $MAIN_PANE_TEXT"
  [ "$(pane_epoch_count)" -eq 1 ] || fail "exactly one attempt marker expected: $MAIN_PANE_TEXT"
}

t_req2_closed_pr_sends_route_notice() {
  jq_ok || return 0
  new_watch_case req2
  write_pr "$GH_STATE" 12 CLOSED "$BRANCH" "$(reviews_json)"
  W_TICKS=5
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "expected one delivered notice: $OUT"
  grep -qF 'PR #12' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must name PR #12: $MAIN_PANE_TEXT"
  grep -qF 'https://github.com/owner/repo/pull/12' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must name the PR URL: $MAIN_PANE_TEXT"
  grep -qF 'was CLOSED without merging' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must say the PR was closed without merging: $MAIN_PANE_TEXT"
  grep -qF 'sub-send.sh demo' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must route it to the child with sub-send.sh: $MAIN_PANE_TEXT"
  grep -qF 'was MERGED' <<<"$MAIN_PANE_TEXT" && fail "a closed PR is not a merge"
  grep -qE '\[pr-watch [0-9]+\]' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must end with the per-attempt marker: $MAIN_PANE_TEXT"
}

t_req3_review_sends_reviewer_and_state() {
  jq_ok || return 0
  local state
  for state in APPROVED CHANGES_REQUESTED COMMENTED; do
    new_watch_case "req3-$state"
    write_pr "$GH_STATE" 13 OPEN "$BRANCH" \
      "$(reviews_json "$(review_json alice "$state" 2026-10-18T10:00:00Z)")"
    W_TICKS=2
    run_watcher
    [ "$RC" -eq 0 ] || fail "$state: watcher exit=$RC stderr=$ERR"
    [ "$(delivered_count)" -eq 1 ] || fail "$state: expected one delivered notice: $OUT"
    grep -qF 'PR #13' <<<"$MAIN_PANE_TEXT" \
      || fail "$state: notice must name PR #13: $MAIN_PANE_TEXT"
    grep -qF 'https://github.com/owner/repo/pull/13' <<<"$MAIN_PANE_TEXT" \
      || fail "$state: notice must name the PR URL: $MAIN_PANE_TEXT"
    grep -qF "got a $state review from alice" <<<"$MAIN_PANE_TEXT" \
      || fail "$state: notice must name the reviewer and the state: $MAIN_PANE_TEXT"
    grep -qF 'sub-send.sh demo' <<<"$MAIN_PANE_TEXT" \
      || fail "$state: notice must route it to the child: $MAIN_PANE_TEXT"
    [ "$(literal_send_count)" -eq 1 ] || fail "$state: one notice expected: $TLOG"
  done
}

t_req4_other_branch_pr_is_never_watched() {
  jq_ok || return 0
  new_watch_case req4
  write_pr "$GH_STATE" 14 OPEN "task/other" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  W_TICKS=3
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 0 ] || fail "no notice expected for another branch: $OUT"
  [ "$(literal_send_count)" -eq 0 ] || fail "no keys expected: $TLOG"
  [ -z "$MAIN_PANE_TEXT" ] || fail "main pane must stay empty: $MAIN_PANE_TEXT"
  [ -z "$CHILD_PANE_TEXT" ] || fail "child pane must stay empty: $CHILD_PANE_TEXT"
}

t_req5_pr_appearing_later_is_picked_up() {
  jq_ok || return 0
  new_watch_case req5
  (
    sleep 0.4
    write_pr "$GH_STATE" 15 OPEN "$BRANCH" \
      "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  ) &
  local mutator=$!
  W_TICKS=8
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "expected the later PR's review to be notified: $OUT"
  grep -qF 'PR #15' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must name PR #15: $MAIN_PANE_TEXT"
  grep -qF 'review from alice' <<<"$MAIN_PANE_TEXT" \
    || fail "notice must name the review: $MAIN_PANE_TEXT"
  [ "$(literal_send_count)" -eq 1 ] || fail "exactly one notice expected: $TLOG"
  [ "$(gh_list_count)" -ge 3 ] || fail "the watcher must keep scanning before the PR appears: $GHLOG"
}

t_req6_unchanged_review_set_is_notified_once() {
  jq_ok || return 0
  new_watch_case req6
  write_pr "$GH_STATE" 16 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  W_TICKS=5
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "unchanged reviews must be notified once: $OUT"
  [ "$(literal_send_count)" -eq 1 ] || fail "one typed notice expected: $TLOG"
  [ "$(gh_list_count)" -ge 3 ] || fail "the watcher must keep scanning: $GHLOG"
  [ "$(grep -cF 'review from alice' <<<"$MAIN_PANE_TEXT" || true)" -eq 1 ] \
    || fail "exactly one alice notice expected: $MAIN_PANE_TEXT"
}

t_req7_new_review_is_notified_again() {
  jq_ok || return 0
  new_watch_case req7
  write_pr "$GH_STATE" 17 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice CHANGES_REQUESTED 2026-10-18T10:00:00Z)")"
  (
    sleep 0.6
    write_pr "$GH_STATE" 17 OPEN "$BRANCH" \
      "$(reviews_json \
          "$(review_json alice CHANGES_REQUESTED 2026-10-18T10:00:00Z)" \
          "$(review_json bob APPROVED 2026-10-18T10:05:00Z)")"
  ) &
  local mutator=$!
  W_TICKS=10
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 2 ] || fail "expected one notice per submitted review: $OUT"
  grep -qF 'review from alice' <<<"$OUT" || fail "alice's review must be notified: $OUT"
  grep -qF 'got a APPROVED review from bob' <<<"$OUT" \
    || fail "the new review must name bob and APPROVED: $OUT"
  [ "$(literal_send_count)" -eq 2 ] || fail "two typed notices expected: $TLOG"
  [ "$(epoch_count)" -eq 2 ] || fail "each notice carries its own attempt marker: $MAIN_PANE_TEXT"
}

t_req8_terminal_state_notifies_once_then_stops() {
  jq_ok || return 0
  new_watch_case req8
  write_pr "$GH_STATE" 18 MERGED "$BRANCH" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  W_TICKS=20
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "exactly one terminal notice expected: $OUT"
  [ "$(literal_send_count)" -eq 1 ] || fail "exactly one typed notice expected: $TLOG"
  grep -qF 'was MERGED' <<<"$MAIN_PANE_TEXT" || fail "terminal notice expected: $MAIN_PANE_TEXT"
  grep -qF 'review from' <<<"$MAIN_PANE_TEXT" && fail "unseen reviews must not be notified for a terminal PR"
  grep -qF 'was CLOSED' <<<"$MAIN_PANE_TEXT" && fail "one terminal notice only"
  # Bounded ticks would allow 20 scans; exiting right after the confirmed
  # delivery means the PR was read exactly once and nothing followed.
  [ "$(gh_list_count)" -eq 1 ] || fail "the watcher must stop after the confirmed terminal notice: $GHLOG"
}

t_req9_unconfirmed_review_notice_is_retried_never_claimed() {
  jq_ok || return 0
  new_watch_case req9
  write_pr "$GH_STATE" 19 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  printf 'drop-enter\n' > "$TMUX_DIR/mode"
  # Flip the pane to a confirmable one once the first attempt has spent its
  # bounded Enter retries (4 pressed), i.e. before the next scan retries.
  (
    for _ in $(seq 1 400); do
      n=$(grep -cE '^send-keys .* Enter$' "$TMUX_DIR/log" 2>/dev/null || true)
      [ "${n:-0}" -ge 4 ] && break
      sleep 0.05
    done
    printf 'ok\n' > "$TMUX_DIR/mode"
  ) &
  local mutator=$!
  W_TICKS=6
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "could not confirm the PR notice for '$TASK'" <<<"$ERR" \
    || fail "an unconfirmed notice must warn: $ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "only the confirmed retry may be claimed delivered: $OUT"
  [ "$(literal_send_count)" -eq 2 ] \
    || fail "expected the failed attempt plus exactly one confirmed retry: $TLOG"
  [ "$(epoch_count)" -ge 2 ] \
    || fail "a retry must carry a fresh [pr-watch <epoch>] marker: $TLOG"
  [ "$(gh_list_count)" -ge 3 ] \
    || fail "the watcher must keep scanning after the confirmed retry: $GHLOG"
  # The review signature was only recorded on the confirmed delivery, so the
  # scans after it must not type the notice again (literal_send_count == 2).
}

t_req10_merged_notice_is_retried_until_confirmed() {
  jq_ok || return 0
  new_watch_case req10
  write_pr "$GH_STATE" 20 MERGED "$BRANCH" "$(reviews_json)"
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
  W_TICKS=40
  W_INTERVAL=0.05
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "could not confirm the PR notice for '$TASK'" <<<"$ERR" \
    || fail "the unconfirmed merged notice must warn: $ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "exactly one confirmed merged notice expected: $OUT"
  [ "$(literal_send_count)" -eq 2 ] \
    || fail "the merged notice must be retried exactly until confirmed: $TLOG"
  [ "$(epoch_count)" -ge 2 ] || fail "the retry must use a fresh marker: $TLOG"
  [ "$(gh_list_count)" -eq 2 ] \
    || fail "the watcher must scan again while unconfirmed and exit after confirmation: $GHLOG"
  grep -qF 'was MERGED' <<<"$MAIN_PANE_TEXT" || fail "merged notice expected: $MAIN_PANE_TEXT"
}

t_req11_unreadable_gh_warns_and_retries() {
  jq_ok || return 0
  # (a) a failing read warns, sends nothing, and a later successful read
  #     notifies the review.
  new_watch_case req11-fail
  write_pr "$GH_STATE" 21 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  : > "$GH_FAIL"
  (
    sleep 0.5
    rm -f "$GH_FAIL"
  ) &
  local mutator=$!
  W_TICKS=10
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "failing read: watcher exit=$RC stderr=$ERR"
  grep -qF 'could not read the PR state' <<<"$ERR" \
    || fail "a failed read must warn: $ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "the later successful read must notify: $OUT"
  grep -qF 'review from alice' <<<"$MAIN_PANE_TEXT" \
    || fail "the successful read's review must be notified: $MAIN_PANE_TEXT"
  [ "$(gh_list_count)" -ge 3 ] || fail "the watcher must keep retrying the read: $GHLOG"

  # (b) gh missing altogether is the same warning path: no notice, no crash.
  new_watch_case req11-missing
  write_pr "$GH_STATE" 22 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  run_watcher_without_gh
  [ "$RC" -eq 0 ] || fail "missing gh: watcher exit=$RC stderr=$ERR"
  grep -qF 'could not read the PR state' <<<"$ERR" \
    || fail "missing gh must warn: $ERR"
  [ "$(delivered_count)" -eq 0 ] || fail "missing gh must send no notice: $OUT"
  [ "$(literal_send_count)" -eq 0 ] || fail "missing gh must send no keys: $TLOG"
  [ ! -s "$GH_LOG" ] || fail "gh must not be invoked when it is missing: $(cat "$GH_LOG")"
}

t_req12_watcher_only_observes_and_only_types_the_notice() {
  jq_ok || return 0
  new_watch_case req12
  write_pr "$GH_STATE" 23 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice CHANGES_REQUESTED 2026-10-18T10:00:00Z)")"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ -n "$GHLOG" ] || fail "expected the watcher to read the PR"
  if grep -Evq '^(pr list( |$)|api graphql( |$))' <<<"$GHLOG"; then
    fail "every gh call must be a read-only query: $GHLOG"
  fi
  grep -qF -- '--head task/demo' <<<"$GHLOG" \
    || fail "the gh read must query the child's branch: $GHLOG"
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
  grep -qF 'PR #23' <<<"$sends" || fail "the keys sent must be the notice: $sends"
  [ -z "$CHILD_PANE_TEXT" ] || fail "the child pane must stay untouched: $CHILD_PANE_TEXT"
}

t_req13_watcher_stops_with_the_child_session() {
  jq_ok || return 0
  new_watch_case req13
  write_pr "$GH_STATE" 24 MERGED "$BRANCH" "$(reviews_json)"
  rm -f "$TMUX_DIR/sessions/$SESS"
  W_TICKS=100
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "child session '$SESS' is not running" <<<"$OUT" \
    || fail "the watcher must report the dead session: $OUT"
  [ "$(delivered_count)" -eq 0 ] || fail "no notice may be sent for a dead child: $OUT"
  [ "$(literal_send_count)" -eq 0 ] || fail "no keys may be sent: $TLOG"
  [ ! -s "$GH_LOG" ] || fail "a dead child must not even read the PR: $(cat "$GH_LOG")"
}

t_req14_watcher_stops_when_the_lease_disappears() {
  jq_ok || return 0
  new_watch_case req14
  write_pr "$GH_STATE" 25 MERGED "$BRANCH" "$(reviews_json)"
  printf '[]\n' > "$TH_STATE"
  W_TICKS=100
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF "no worktree lease for '$TASK'" <<<"$OUT" \
    || fail "the watcher must report the returned lease: $OUT"
  [ "$(delivered_count)" -eq 0 ] || fail "no notice may be sent without a lease: $OUT"
  [ "$(literal_send_count)" -eq 0 ] || fail "no keys may be sent: $TLOG"
  [ ! -s "$GH_LOG" ] || fail "a returned lease must not even read the PR: $(cat "$GH_LOG")"
}

# ---------------------------------------------------------------------------
# Supplementary tests (edge cases the [REQ-n] scenarios do not pin)
# ---------------------------------------------------------------------------

t_supp_unknown_lease_warns_and_still_notifies() {
  jq_ok || return 0
  new_watch_case unknown-lease
  : > "$TH_FAIL"
  (
    sleep 1
    rm -f "$TH_FAIL"
    write_pr "$GH_STATE" 26 OPEN "$BRANCH" \
      "$(reviews_json "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  ) &
  local mutator=$!
  W_TICKS=10; W_INTERVAL=0.2
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'could not read treehouse status' <<<"$ERR" \
    || fail "a failing treehouse status must warn: $ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "the watcher must keep scanning and notify once the lease read recovers: $OUT"
  grep -qF 'alice' <<<"$MAIN_PANE_TEXT" || fail "review notice expected: $MAIN_PANE_TEXT"
}

t_supp_fractional_retry_seconds_is_rejected() {
  jq_ok || return 0
  new_watch_case fractional-retry
  write_pr "$GH_STATE" 27 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json bob COMMENTED 2026-10-18T10:00:00Z)")"
  W_TICKS=2; W_RETRY=0.5
  run_watcher
  [ "$RC" -ne 0 ] || fail "a fractional PR_WATCH_RETRY_SECONDS must be rejected, got exit=0"
  grep -qF 'PR_WATCH_RETRY_SECONDS must be a non-negative integer' <<<"$ERR" \
    || fail "the rejection must name the invalid knob: $ERR"
  [ "$(delivered_count)" -eq 0 ] || fail "no notice may be attempted with an invalid knob: $OUT"
}

t_supp_missing_headrefname_uses_the_requested_branch() {
  jq_ok || return 0
  new_watch_case no-head-ref
  jq -n --argjson r "$(reviews_json "$(review_json carol CHANGES_REQUESTED 2026-10-18T10:00:00Z)")" '
    [{number: 41, url: "https://github.com/owner/repo/pull/41",
      state: "OPEN", mergedAt: null, reviews: $r}]' > "$GH_STATE"
  W_TICKS=3
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "a gh result without headRefName must fall back to the requested branch: $OUT"
  grep -qF 'carol' <<<"$MAIN_PANE_TEXT" || fail "review notice expected: $MAIN_PANE_TEXT"
}

# [fix-pending-notice REQ-5] the 2026-10-18 flood: the orchestrator is
# mid-turn, so pi queues the review notice as a truncated steering message.
# The queued delivery is confirmed and recorded, so later scans do not retype
# it into the orchestrator's queue again.
t_pending_req5_queued_review_notice_is_delivered_once() {
  jq_ok || return 0
  new_watch_case pending-review
  write_pr "$GH_STATE" 51 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json alice CHANGES_REQUESTED 2026-10-18T10:00:00Z)")"
  printf 'steer\n' > "$TMUX_DIR/mode"
  W_TICKS=5
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "the queued notice must be claimed delivered exactly once: $OUT"
  [ "$(literal_send_count)" -eq 1 ] \
    || fail "the notice must not be retyped after a queued delivery: $TLOG"
  [ "$(gh_list_count)" -ge 3 ] || fail "the watcher must keep scanning after it: $GHLOG"
  [ "$(wc -l < "$TMUX_DIR/pending/$MAIN_SESS")" -eq 1 ] \
    || fail "exactly one queued copy expected: $(cat "$TMUX_DIR/pending/$MAIN_SESS")"
  grep -qF 'PR #51' "$TMUX_DIR/pending/$MAIN_SESS" \
    || fail "the queued head must name the reviewed PR: $(cat "$TMUX_DIR/pending/$MAIN_SESS")"
  if grep -qE 'WARNING|ERROR' <<<"$ERR"; then
    fail "a queued delivery must not warn or fail: $ERR"
  fi
}

# [fix-pending-notice REQ-6] a terminal notice queued behind a busy
# orchestrator is delivered exactly once, and the watcher exits 0 right after
# the confirmed queued delivery — no second copy on a later scan.
t_pending_req6_queued_merged_notice_is_delivered_once() {
  jq_ok || return 0
  new_watch_case pending-merged
  write_pr "$GH_STATE" 52 MERGED "$BRANCH" "$(reviews_json)"
  printf 'steer\n' > "$TMUX_DIR/mode"
  W_TICKS=20
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "exactly one merged notice expected: $OUT"
  [ "$(literal_send_count)" -eq 1 ] \
    || fail "the merged notice must not be retyped: $TLOG"
  [ "$(gh_list_count)" -eq 1 ] \
    || fail "the watcher must exit after the confirmed queued delivery: $GHLOG"
  [ "$(wc -l < "$TMUX_DIR/pending/$MAIN_SESS")" -eq 1 ] \
    || fail "exactly one queued copy expected: $(cat "$TMUX_DIR/pending/$MAIN_SESS")"
  grep -qF 'PR #52' "$TMUX_DIR/pending/$MAIN_SESS" \
    || fail "the queued head must name the merged PR: $(cat "$TMUX_DIR/pending/$MAIN_SESS")"
}

# ---------------------------------------------------------------------------
# fix-self-review-loop: a child's own review replies
# (specs/fix-self-review-loop/fix-self-review-loop.feature)
# ---------------------------------------------------------------------------

# [fix-self-review-loop REQ-1] the PR #263 shape: a human COMMENTED review
# with a top-level inline comment, then the child's reply recorded as a second
# COMMENTED review whose only comment replies to that thread. Only the human
# review may be notified; the reply is recorded handled and never re-read.
t_self_req1_reply_only_review_is_not_notified() {
  jq_ok || return 0
  new_watch_case self-reply
  write_pr "$GH_STATE" 61 OPEN "$BRANCH" \
    "$(reviews_json \
        "$(review_json jseto COMMENTED 2026-10-18T16:21:12Z '' PRR_human)" \
        "$(review_json jseto COMMENTED 2026-10-18T18:04:27Z '' PRR_child)")"
  printf '{"PRR_child":0}\n' > "$GH_GRAPHQL_STATE"
  W_TICKS=4
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "only the submitted review may be notified: $OUT"
  [ "$(literal_send_count)" -eq 1 ] || fail "exactly one notice expected: $TLOG"
  grep -qF 'got a COMMENTED review from jseto' <<<"$MAIN_PANE_TEXT" \
    || fail "the submitted review must be notified: $MAIN_PANE_TEXT"
  grep -qF 'is a reply to an existing thread; not notifying' <<<"$OUT" \
    || fail "the reply review must be reported handled: $OUT"
  grep -qF 'PRR_child' <<<"$OUT" || fail "the skip must name the reply review: $OUT"
  [ "$(graphql_count)" -eq 2 ] \
    || fail "each unseen COMMENTED review is read exactly once: $GHLOG"
  [ "$(grep -cF 'id=PRR_child' <<<"$GHLOG")" -eq 1 ] \
    || fail "the recorded reply must not be re-read on later scans: $GHLOG"
}

# [fix-self-review-loop REQ-2] a COMMENTED review that carries a top-level
# inline comment (no replyTo) is a submitted review and is notified.
t_self_req2_top_level_commented_review_is_notified() {
  jq_ok || return 0
  new_watch_case self-top-level
  write_pr "$GH_STATE" 62 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json jseto COMMENTED 2026-10-18T16:21:12Z '' PRR_top)")"
  printf '{"PRR_top":1}\n' > "$GH_GRAPHQL_STATE"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "the top-level COMMENTED review must be notified: $OUT"
  [ "$(literal_send_count)" -eq 1 ] || fail "one notice expected: $TLOG"
  grep -qF 'got a COMMENTED review from jseto' <<<"$MAIN_PANE_TEXT" \
    || fail "notice expected: $MAIN_PANE_TEXT"
  [ "$(graphql_count)" -eq 1 ] || fail "exactly one attribution read expected: $GHLOG"
}

# [fix-self-review-loop REQ-3] a COMMENTED review with a review body is a
# submission: notified without any review-comments read.
t_self_req3_review_body_needs_no_comment_read() {
  jq_ok || return 0
  new_watch_case self-body
  write_pr "$GH_STATE" 63 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json jseto COMMENTED 2026-10-18T16:21:12Z 'Some thoughts on the diff' PRR_body)")"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 1 ] || fail "the body review must be notified: $OUT"
  [ "$(graphql_count)" -eq 0 ] || fail "a review body needs no comments read: $GHLOG"
}

# [fix-self-review-loop REQ-4] APPROVED / CHANGES_REQUESTED can never be a
# reply: notified without any attribution read.
t_self_req4_non_commented_reviews_need_no_comment_read() {
  jq_ok || return 0
  new_watch_case self-states
  write_pr "$GH_STATE" 64 OPEN "$BRANCH" \
    "$(reviews_json \
        "$(review_json alice APPROVED 2026-10-18T10:00:00Z)" \
        "$(review_json bob CHANGES_REQUESTED 2026-10-18T10:05:00Z)")"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  [ "$(delivered_count)" -eq 2 ] || fail "both reviews must be notified: $OUT"
  [ "$(graphql_count)" -eq 0 ] || fail "no attribution read expected: $GHLOG"
}

# [fix-self-review-loop REQ-5] a failed attribution read is never a notice and
# is retried: the review is notified once the read recovers.
t_self_req5_unreadable_read_warns_and_retries() {
  jq_ok || return 0
  new_watch_case self-unreadable
  write_pr "$GH_STATE" 65 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json jseto COMMENTED 2026-10-18T16:21:12Z '' PRR_retry)")"
  printf '{"PRR_retry":1}\n' > "$GH_GRAPHQL_STATE"
  : > "$GH_GRAPHQL_FAIL"
  (
    sleep 0.5
    rm -f "$GH_GRAPHQL_FAIL"
  ) &
  local mutator=$!
  W_TICKS=8
  run_watcher
  wait "$mutator" 2>/dev/null || true
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'could not read the review comments' <<<"$ERR" \
    || fail "a failed attribution read must warn: $ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "the recovered read must notify the review exactly once: $OUT"
  [ "$(graphql_count)" -ge 2 ] || fail "the read must be retried: $GHLOG"
}

# [fix-self-review-loop REQ-6] the attribution read is read-only and only the
# notice keys ever go to the orchestrator.
t_self_req6_attribution_read_only_reads() {
  jq_ok || return 0
  new_watch_case self-readonly
  write_pr "$GH_STATE" 66 OPEN "$BRANCH" \
    "$(reviews_json "$(review_json jseto COMMENTED 2026-10-18T16:21:12Z '' PRR_ro)")"
  printf '{"PRR_ro":0}\n' > "$GH_GRAPHQL_STATE"
  W_TICKS=2
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'id=PRR_ro' <<<"$GHLOG" || fail "expected the attribution read: $GHLOG"
  if grep -Evq '^(pr list( |$)|api graphql( |$))' <<<"$GHLOG"; then
    fail "every gh call must be read-only: $GHLOG"
  fi
  if grep -Eq '(^| )(merge|close|comment|review|edit|create|push|reopen|ready)( |$)' <<<"$GHLOG"; then
    fail "the watcher must never mutate GitHub: $GHLOG"
  fi
  [ "$(literal_send_count)" -eq 0 ] || fail "a reply-only review sends nothing: $TLOG"
  [ -z "$CHILD_PANE_TEXT" ] || fail "the child pane must stay untouched: $CHILD_PANE_TEXT"
}

# [fix-self-review-loop REQ-8] a poisoned attribution read never starves the
# rest of the scan: a later review that needs no attribution read is still
# notified while the unreadable one waits out its retry delay.
t_self_req8_unreadable_review_does_not_starve_other_reviews() {
  jq_ok || return 0
  new_watch_case self-starvation
  write_pr "$GH_STATE" 67 OPEN "$BRANCH" \
    "$(reviews_json \
        "$(review_json jseto COMMENTED 2026-10-18T16:21:12Z '' PRR_bad)" \
        "$(review_json alice APPROVED 2026-10-18T10:00:00Z)")"
  printf '{"PRR_bad":1}\n' > "$GH_GRAPHQL_STATE"
  : > "$GH_GRAPHQL_FAIL"
  W_TICKS=4
  run_watcher
  [ "$RC" -eq 0 ] || fail "watcher exit=$RC stderr=$ERR"
  grep -qF 'could not read the review comments' <<<"$ERR" \
    || fail "the unreadable review must warn: $ERR"
  [ "$(delivered_count)" -eq 1 ] \
    || fail "the later actionable review must still be notified: $OUT"
  grep -qF 'got a APPROVED review from alice' <<<"$MAIN_PANE_TEXT" \
    || fail "the APPROVED notice is the one expected: $MAIN_PANE_TEXT"
  grep -qF 'COMMENTED review from jseto' <<<"$MAIN_PANE_TEXT" \
    && fail "the unreadable review must never be notified: $MAIN_PANE_TEXT"
  [ "$(graphql_count)" -ge 2 ] || fail "the unreadable review must be retried: $GHLOG"
}

# [fix-self-review-loop REQ-7] the touched watcher and this suite stay clean.
t_self_req7_shellcheck_clean() {
  bash -n "$WATCH" || fail "bash -n reported syntax errors in $WATCH"
  bash -n "${BASH_SOURCE[0]}" || fail "bash -n reported syntax errors in this suite"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$WATCH" "${BASH_SOURCE[0]}" || fail "shellcheck reported findings"
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
  esac
  RC=0
  OUT=$("${envs[@]}" bash "$SPAWN" "$TASK" "$fx/repo" 2>"$fx/spawn-stderr") || RC=$?
  ERR=$(cat "$fx/spawn-stderr")
  TLOG=$(cat "$fx/tmux/log" 2>/dev/null || true)
}

t_req15_every_spawn_arms_the_pr_watch_window() {
  jq_ok || return 0
  local fx="$SCRATCH/spawn-default"
  make_spawn_fixture "$fx"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "spawn exit=$RC stderr=$ERR"
  grep -qE -- '-n pr-watch( |$)' <<<"$TLOG" || fail "no pr-watch window created: $TLOG"
  grep -qF -- "sub-pr-watch.sh $TASK $fx/repo $BRANCH" <<<"$TLOG" \
    || fail "the pr-watch window must run the watcher for task/root/branch: $TLOG"
  grep -qF 'pr-watch: pr-watch window in pi-demo' <<<"$OUT" \
    || fail "the handles must report the pr-watch window: $OUT"

  local fx2="$SCRATCH/spawn-no-pr-watch"
  make_spawn_fixture "$fx2"
  run_spawn "$fx2" no-pr-watch
  [ "$RC" -eq 0 ] || fail "no-pr-watch spawn exit=$RC stderr=$ERR"
  grep -qE -- '-n pr-watch( |$)' <<<"$TLOG" && fail "SUB_SPAWN_NO_PR_WATCH=1 must skip the pr-watch window"
  grep -qE -- '-n lavish-watch( |$)' <<<"$TLOG" \
    || fail "SUB_SPAWN_NO_PR_WATCH=1 must keep the lavish-watch window: $TLOG"
  grep -qF 'pr-watch: disabled (SUB_SPAWN_NO_PR_WATCH=1)' <<<"$OUT" \
    || fail "the handles must report the pr-watch opt-out: $OUT"
  grep -qF 'watch:    lavish-watch window in pi-demo' <<<"$OUT" \
    || fail "the handles must keep reporting the lavish watcher: $OUT"

  local fx3="$SCRATCH/spawn-no-watch"
  make_spawn_fixture "$fx3"
  run_spawn "$fx3" no-watch
  [ "$RC" -eq 0 ] || fail "no-watch spawn exit=$RC stderr=$ERR"
  grep -qE -- '-n pr-watch( |$)' <<<"$TLOG" && fail "SUB_SPAWN_NO_WATCH=1 must skip the pr-watch window"
  grep -qE -- '-n lavish-watch( |$)' <<<"$TLOG" && fail "SUB_SPAWN_NO_WATCH=1 must skip the lavish-watch window"
  grep -qF 'pr-watch: disabled (SUB_SPAWN_NO_WATCH=1)' <<<"$OUT" \
    || fail "the handles must report the pr-watch opt-out: $OUT"
  grep -qF 'watch:    disabled (SUB_SPAWN_NO_WATCH=1)' <<<"$OUT" \
    || fail "the handles must report the lavish opt-out: $OUT"
}

t_req16_unstartable_pr_watch_window_does_not_fail_spawn() {
  jq_ok || return 0
  local fx="$SCRATCH/spawn-pr-watch-fail"
  make_spawn_fixture "$fx"
  printf 'no-pr-watch-window\n' > "$fx/tmux/mode"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "spawn must succeed without the pr-watch window, got exit=$RC stderr=$ERR"
  grep -qF 'could not create the pr-watch window' <<<"$ERR" \
    || fail "the spawn must warn about the missing pr-watch window: $ERR"
  grep -qF 'pr-watch: unavailable' <<<"$OUT" \
    || fail "the handles must show the pr-watch window unavailable: $OUT"
  grep -qF 'session:  pi-demo' <<<"$OUT" \
    || fail "the spawn must still report the child: $OUT"
  grep -qE -- '-n lavish-watch( |$)' <<<"$TLOG" \
    || fail "only the pr-watch window may fail: $TLOG"
}

t_req17_touched_scripts_shellcheck_clean() {
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

run "[REQ-1] merged PR sends the retire notice"                        t_req1_merged_pr_sends_retire_notice
run "[REQ-2] closed PR sends the route-back notice"                    t_req2_closed_pr_sends_route_notice
run "[REQ-3] review notice names reviewer and state"                   t_req3_review_sends_reviewer_and_state
run "[REQ-4] PR for another branch is never watched"                   t_req4_other_branch_pr_is_never_watched
run "[REQ-5] PR appearing later is picked up"                          t_req5_pr_appearing_later_is_picked_up
run "[REQ-6] unchanged review set is notified once"                    t_req6_unchanged_review_set_is_notified_once
run "[REQ-7] new review is notified again"                             t_req7_new_review_is_notified_again
run "[REQ-8] terminal state notifies once then stops"                  t_req8_terminal_state_notifies_once_then_stops
run "[REQ-9] unconfirmed review notice retried, never claimed"         t_req9_unconfirmed_review_notice_is_retried_never_claimed
run "[REQ-10] merged notice retried until confirmed"                   t_req10_merged_notice_is_retried_until_confirmed
run "[REQ-11] unreadable gh warns and retries"                         t_req11_unreadable_gh_warns_and_retries
run "[REQ-12] watcher only observes and only types the notice"         t_req12_watcher_only_observes_and_only_types_the_notice
run "[REQ-13] watcher stops with the child session"                    t_req13_watcher_stops_with_the_child_session
run "[REQ-14] watcher stops when the lease disappears"                 t_req14_watcher_stops_when_the_lease_disappears
run "supplementary: unknown lease warns and still notifies"           t_supp_unknown_lease_warns_and_still_notifies
run "supplementary: fractional retry knob is rejected"                t_supp_fractional_retry_seconds_is_rejected
run "supplementary: missing headRefName falls back to the branch"     t_supp_missing_headrefname_uses_the_requested_branch
run "[fix-pending-notice REQ-5] queued review notice delivered once"  t_pending_req5_queued_review_notice_is_delivered_once
run "[fix-pending-notice REQ-6] queued merged notice delivered once then stops" t_pending_req6_queued_merged_notice_is_delivered_once
run "[fix-self-review-loop REQ-1] reply-only review is not notified"     t_self_req1_reply_only_review_is_not_notified
run "[fix-self-review-loop REQ-2] top-level COMMENTED review notified"  t_self_req2_top_level_commented_review_is_notified
run "[fix-self-review-loop REQ-3] review body needs no comment read"    t_self_req3_review_body_needs_no_comment_read
run "[fix-self-review-loop REQ-4] APPROVED/CHANGES_REQUESTED unprobed"  t_self_req4_non_commented_reviews_need_no_comment_read
run "[fix-self-review-loop REQ-5] unreadable read warns and retries"    t_self_req5_unreadable_read_warns_and_retries
run "[fix-self-review-loop REQ-6] attribution read is read-only"        t_self_req6_attribution_read_only_reads
run "[fix-self-review-loop REQ-7] touched watcher shellcheck-clean"     t_self_req7_shellcheck_clean
run "[fix-self-review-loop REQ-8] unreadable review does not starve others" t_self_req8_unreadable_review_does_not_starve_other_reviews
run "[REQ-15] every spawn arms the pr-watch window"                    t_req15_every_spawn_arms_the_pr_watch_window
run "[REQ-16] unstartable pr-watch window does not fail spawn"         t_req16_unstartable_pr_watch_window_does_not_fail_spawn
run "[REQ-17] touched scripts shellcheck-clean"                        t_req17_touched_scripts_shellcheck_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
