#!/usr/bin/env bash
# Test suite for scripts/start-main.sh — one test per Gherkin scenario in
# specs/start-main-script/start-main-script.feature ([REQ-n] traceable).
#
# Hermetic by construction: everything runs against an isolated tmux server
# (TMUX_TMPDIR sandbox, TMUX/TMUX_PANE/MAIN_SESSION/PI_BIN unset), so the
# suite can never touch a live `pi-main` session, and `PI_BIN` is faked with
# marker shell scripts found first on PATH.
#
# Usage: bash tests/test-start-main.sh   (exit 0 = all green)
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
START_DIR=$(cd "$TESTS_DIR/../scripts" && pwd)
# SUT override (the SUB_COMMON_UNDER_TEST idiom the sibling suites use): a
# mutated copy of the whole scripts/ dir can be checked to make these tests
# go red, without touching scripts/ in this checkout.
START=${START_MAIN_UNDER_TEST:-$START_DIR/start-main.sh}

# The main checkout is the first entry of `git worktree list` — an
# independent source for what "main checkout" means, unlike the
# git-common-dir mapping the script itself uses.
MAIN_WT=$(git -C "$START_DIR" worktree list --porcelain \
  | awk '/^worktree /{sub(/^worktree /,""); print; exit}')

TMP=$(mktemp -d)
TESTBIN="$TMP/bin"
mkdir -p "$TESTBIN" "$TMP/elsewhere"

# Fake pi executables: echo a marker (so tmux_send_line sees the pane change
# on Enter) and linger so the pane child is observable via ps.
cat > "$TESTBIN/fake-pi" <<'EOF'
#!/usr/bin/env bash
echo "fake-pi launched"
sleep 60
EOF
cat > "$TESTBIN/pi" <<'EOF'
#!/usr/bin/env bash
echo "fake default pi launched"
sleep 60
EOF
chmod +x "$TESTBIN/fake-pi" "$TESTBIN/pi"
PATH="$TESTBIN:$PATH"
export PATH

cleanup() {
  env -u TMUX TMUX_TMPDIR="$TMP" tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Hermetic launch environment: the user's login profile prepends the real
# nvm `pi` to PATH (which would shadow the fake and boot a real TUI inside
# the test server), so give panes a scratch HOME with no profile and force
# the server's global PATH to the fake bin. A bootstrap session keeps the
# server alive while that is set (set-environment does not start a server),
# and exit-empty off keeps the server — and its environment — afterwards.
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TMP" tmux new-session -d \
  -s env-bootstrap -c "$TMP" "sleep 60"
mkdir -p "$TMP/home"
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TMP" tmux set-option -s exit-empty off
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TMP" tmux set-environment -g HOME "$TMP/home"
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TMP" tmux set-environment -g PATH "$TESTBIN:$PATH"
env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TMP" tmux kill-session -t "=env-bootstrap" 2>/dev/null || true

# --- harness ----------------------------------------------------------------

PASSES=0; FAILS=0; SKIPS=0; CUR=""
begin() { CUR="$1"; printf '[%s]\n' "$1"; }
ok()   { PASSES=$((PASSES + 1)); printf '  ok   %s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1));  printf '  FAIL %s\n       %s\n' "$CUR" "$*"; }
skip() { SKIPS=$((SKIPS + 1));  printf '  skip %s\n       %s\n' "$CUR" "$*"; }

t_eq()        { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
t_nz_rc()     { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1 — expected non-zero exit, got 0"; fi; }
t_has()       {
  if [ -z "$2" ]; then bad "$1 — empty pattern (nothing to look for)"; return; fi
  if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 — [$2] not found in $3"; fi
}
t_not_in()    { case "$3" in *"$2"*) bad "$1 — [$2] unexpectedly in [$3]" ;; *) ok "$1" ;; esac; }
t_not_matches() { if printf '%s' "$3" | grep -qE -- "$2"; then bad "$1 — [$2] unexpectedly matches [$3]"; else ok "$1"; fi; }

# --- tmux / script access ---------------------------------------------------

tux() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TMP" tmux "$@"; }

OUT="$TMP/out"; ERR="$TMP/err"; RC=0
PI_VAL=""   # supplied as PI_BIN to the script; empty = unset (default pi)
RUN_CWD=""  # invocation directory for run_start; empty = current dir
RUN_ENV=()   # extra NAME=VALUE exports for the next run_start (added only)
TMUX_SHIM=""  # dir holding a `tmux` shim placed first on the next run's PATH
REAL_TMUX=$(command -v tmux)

run_start() { # <script args...>; sets RC, $OUT, $ERR
  (
    if [ -n "$RUN_CWD" ]; then cd "$RUN_CWD" || exit 1; fi
    unset TMUX TMUX_PANE MAIN_PANE MAIN_SESSION
    export TMUX_TMPDIR="$TMP"
    if [ -n "$PI_VAL" ]; then export PI_BIN="$PI_VAL"; else unset PI_BIN; fi
    if [ -n "$TMUX_SHIM" ]; then export PATH="$TMUX_SHIM:$PATH"; fi
    local kv
    for kv in ${RUN_ENV[@]+"${RUN_ENV[@]}"}; do export "${kv?}"; done
    "$START" "$@"
  ) >"$OUT" 2>"$ERR"
  RC=$?
}

has_main()     { tux has-session -t "=pi-main" 2>/dev/null; }
fresh_session() { tux kill-session -t "=pi-main" 2>/dev/null || true; }
# Pane/window lookups need the "=session:" target: a bare "=pi-main" means
# "window named pi-main" for pane targets and silently resolves to nothing.
pane_cwd()     { tux display-message -p -t "=pi-main:" '#{pane_current_path}' 2>/dev/null; }
pane_pid()     { tux display-message -p -t "=pi-main:" '#{pane_pid}' 2>/dev/null; }
pane_width()   { tux show-options -w -v -t "=pi-main:" main-pane-width 2>/dev/null; }
pane_child_args() { ps --ppid "$(pane_pid)" -o args= --no-headers 2>/dev/null | tr '\n' ' '; }
attached_sessions() { tux list-clients -F '#{client_session}' 2>/dev/null || true; }
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

wait_for_child() { # $1 = needle expected among the pane's children
  local i
  for ((i = 0; i < 40; i++)); do
    pane_child_args | grep -qF -- "$1" && return 0
    sleep 0.25
  done
  return 1
}

# --- orchestrator watcher arming (specs/orchestrator-stall-recovery) --------

# Window lookups always address the session's CURRENT window for pane formats
# (`=pi-main:`); the window list itself needs no index assumption, because a
# user's tmux.conf may set base-index.
window_names()  { tux list-windows -t "=pi-main:" -F '#W' 2>/dev/null; }
window_count()  { local n; n=$(window_names | grep -c '' 2>/dev/null || true); printf '%s' "${n:-0}"; }
watch_windows() { local n; n=$(window_names | grep -cx -- watch 2>/dev/null || true); printf '%s' "${n:-0}"; }
watch_start_command() { tux list-panes -t "=pi-main:watch" -F '#{pane_start_command}' 2>/dev/null; }

# A tmux shim that refuses ONLY the watcher window and delegates everything
# else to the real binary, so the session is created normally.
mk_tmux_shim() { # $1 = dir to populate
  mkdir -p "$1"
  cat > "$1/tmux" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" new-window "*"-n watch "*) printf 'shim: refusing to create windows\\n' >&2; exit 1 ;;
esac
exec "$REAL_TMUX" "\$@"
EOF
  chmod +x "$1/tmux"
}

# --- scenarios --------------------------------------------------------------

req_1() {
  begin "[REQ-1] Start a detached session under the exact name pi-main"
  fresh_session
  PI_VAL=""
  run_start --detach
  t_eq "exits 0" 0 "$RC"
  if has_main; then ok "session pi-main exists"; else bad "session pi-main does not exist"; fi
  t_eq "session is named exactly pi-main (no auto-rename)" "pi-main" \
    "$(tux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
}

req_2() {
  begin "[REQ-2] Launch the program named by PI_BIN without child arguments"
  fresh_session
  PI_VAL="$TESTBIN/fake-pi"
  run_start --detach
  t_eq "exits 0" 0 "$RC"
  if wait_for_child "$TESTBIN/fake-pi"
  then ok "pane runs PI_BIN"
  else bad "pane child is not running PI_BIN (args: $(pane_child_args))"
  fi
  local args; args=$(pane_child_args)
  t_not_in "launch carries no --no-extensions" "--no-extensions" "$args"
  t_not_matches "launch carries no child -n flag" '(^|[[:space:]])-n([[:space:]]|$)' "$args"
}

req_3() {
  begin "[REQ-3] Default to plain pi when PI_BIN is unset"
  fresh_session
  PI_VAL=""
  run_start --detach
  t_eq "exits 0" 0 "$RC"
  if wait_for_child "$TESTBIN/pi"
  then ok "pane runs the fake pi from PATH"
  else bad "pane child is not running fake pi from PATH (args: $(pane_child_args))"
  fi
  local args; args=$(pane_child_args)
  t_not_in "default launch carries no --no-extensions" "--no-extensions" "$args"
}

req_4() {
  begin "[REQ-4] Root the session at the main checkout regardless of invocation cwd"
  fresh_session
  PI_VAL=""
  RUN_CWD="$TMP/elsewhere"
  run_start --detach
  RUN_CWD=""
  t_eq "exits 0 (run from unrelated dir)" 0 "$RC"
  t_eq "session cwd = main checkout (unrelated invocation dir)" \
    "$(canon "$MAIN_WT")" "$(canon "$(pane_cwd)")"
  fresh_session
  RUN_CWD="$START_DIR"
  run_start --detach
  RUN_CWD=""
  t_eq "exits 0 (run from script location)" 0 "$RC"
  t_eq "session cwd = main checkout (script location, a linked worktree when tests run from one)" \
    "$(canon "$MAIN_WT")" "$(canon "$(pane_cwd)")"
}

req_5() {
  begin "[REQ-5] Configure the new session's window for the orchestrator layout"
  fresh_session
  PI_VAL=""
  run_start --detach
  t_eq "exits 0" 0 "$RC"
  t_eq "main-pane-width is 50%" "50%" "$(pane_width)"
}

req_6() {
  begin "[REQ-6] Preserve an existing session and report where it is"
  if ! has_main; then
    PI_VAL=""
    run_start --detach
    t_eq "setup: session exists" 0 "$RC"
  fi
  local pid_before cwd_before
  pid_before=$(pane_pid)
  cwd_before=$(pane_cwd)
  t_nz_rc "setup: session cwd is known" "${#cwd_before}"
  # A marker only a *clobbering* implementation would overwrite.
  tux set-window-option -t "=pi-main:" main-pane-width 70% 2>/dev/null
  PI_VAL=""
  run_start --detach
  t_eq "exits 0" 0 "$RC"
  t_eq "pane process not restarted" "$pid_before" "$(pane_pid)"
  t_eq "window options untouched" "70%" "$(pane_width)"
  t_has "reports that the session already exists" "already exists" "$OUT"
  t_has "reports the session name" "pi-main" "$OUT"
  t_has "reports where it is (cwd)" "$cwd_before" "$OUT"
}

req_7() {
  begin "[REQ-7] Attach to the session by default"
  if ! command -v script >/dev/null 2>&1; then
    skip "script(1) not available — cannot drive the attach pty"
    return 0
  fi
  if ! has_main; then
    PI_VAL=""
    run_start --detach
    t_eq "setup: session started" 0 "$RC"
  fi
  if [ -n "$(attached_sessions)" ]
  then bad "setup: no client expected before the run"
  else ok "setup: no client attached before the run"
  fi

  env -u TMUX -u TMUX_PANE -u MAIN_SESSION -u PI_BIN \
    TERM=xterm-256color TMUX_TMPDIR="$TMP" \
    script -qec "$START" /dev/null >/dev/null 2>"$TMP/attach.err" &
  local spid=$! attached="" i arc=""
  for ((i = 0; i < 60; i++)); do
    if attached_sessions | grep -Fxq -- "pi-main"; then attached=1; break; fi
    kill -0 "$spid" 2>/dev/null || break
    sleep 0.25
  done
  t_eq "client attached without flags" "1" "${attached:-}"
  # Detach by session: `detach-client -a` acts on the *current* session,
  # which a detached test process does not have (and `#{client_id}` is not a
  # format in tmux 3.6), while -s targets every client of our session.
  tux detach-client -s "=pi-main" >/dev/null 2>&1 || true
  for ((i = 0; i < 40; i++)); do
    if ! kill -0 "$spid" 2>/dev/null; then wait "$spid"; arc=$?; break; fi
    sleep 0.25
  done
  if [ -z "$arc" ]; then
    kill "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    bad "script did not exit after the client detached"
  else
    t_eq "script exits 0 after the client detaches" 0 "$arc"
  fi
}

req_8() {
  begin "[REQ-8] Return without attaching when -d or --detach is given"
  if ! has_main; then
    PI_VAL=""
    run_start --detach
    t_eq "setup: session started" 0 "$RC"
  fi
  PI_VAL=""
  run_start --detach
  t_eq "long flag exits 0" 0 "$RC"
  t_eq "long flag attaches no client" "" "$(attached_sessions)"
  t_has "long flag message mentions detach" "detach" "$OUT"
  PI_VAL=""
  run_start -d
  t_eq "short flag exits 0" 0 "$RC"
  t_eq "short flag attaches no client" "" "$(attached_sessions)"
  fresh_session
  PI_VAL=""
  run_start -d
  t_eq "fresh start with -d exits 0" 0 "$RC"
  t_eq "fresh start with -d attaches no client" "" "$(attached_sessions)"
  if has_main
  then ok "fresh start with -d created the session"
  else bad "fresh start with -d did not create the session"
  fi
}

req_9() {
  begin "[REQ-9] Reject invalid invocation without side effects"
  fresh_session
  PI_VAL=""
  run_start --bogus
  t_nz_rc "unknown option fails" "$RC"
  t_has "ERROR: usage on stderr" "ERROR:" "$ERR"
  if has_main; then bad "unknown option created no session"; else ok "unknown option created no session"; fi
  PI_VAL="$TMP/missing-pi-binary"
  run_start --detach
  t_nz_rc "unusable PI_BIN fails" "$RC"
  t_has "ERROR on stderr" "ERROR:" "$ERR"
  if has_main; then bad "unusable PI_BIN created no session"; else ok "unusable PI_BIN created no session"; fi
  PI_VAL=""
}

# --- orchestrator watcher arming (specs/orchestrator-stall-recovery) --------

orch_req_1() {
  begin "[REQ-1] Starting a new main session arms one orchestrator watcher window"
  fresh_session
  PI_VAL="$TESTBIN/fake-pi"
  run_start --detach
  t_eq "exits 0" 0 "$RC"
  t_eq "exactly one extra window (the pi window plus the watcher)" 2 "$(window_count)"
  t_eq "exactly one window is named watch" 1 "$(watch_windows)"
  # -d keeps the pi window current: it stays window 0 for the layout and for
  # every `=pi-main:` pane lookup, and it still runs the launched pi.
  t_eq "the pi window is still the current one" 1 \
    "$(tux display-message -p -t "=pi-main:" '#{window_active}' 2>/dev/null)"
  if wait_for_child "$TESTBIN/fake-pi"
  then ok "the first window still runs the launched pi"
  else bad "the first window no longer runs the launched pi (args: $(pane_child_args))"
  fi
  printf '%s' "$(watch_start_command)" > "$TMP/watch-start.txt"
  t_has "the watch window runs the orchestrator watcher" "main-watch.sh" "$TMP/watch-start.txt"
  t_has "the watcher was armed for the watched session" "main-watch.sh pi-main" "$TMP/watch-start.txt"
  t_has "the output reports the watcher state" \
    "watcher: watch window in pi-main (orchestrator stall recovery)" "$OUT"
}

orch_req_2() {
  begin "[REQ-2] An existing main session gains no watcher and is not restarted"
  fresh_session
  # A session that predates this feature: no watcher window.
  tux new-session -d -s pi-main -c "$TMP" "sleep 60"
  if has_main; then ok "setup: an unwatched session exists"; else bad "setup: could not create the session"; fi
  local pid_before wins_before cwd_before
  pid_before=$(pane_pid)
  wins_before=$(window_names)
  cwd_before=$(pane_cwd)
  t_eq "setup: one window only" 1 "$(window_count)"
  PI_VAL="$TESTBIN/fake-pi"
  run_start --detach
  t_eq "exits 0" 0 "$RC"
  t_eq "the window list is unchanged" "$wins_before" "$(window_names)"
  t_eq "no watcher window is added" 0 "$(watch_windows)"
  t_eq "the pane process was not restarted" "$pid_before" "$(pane_pid)"
  t_has "reports the session name" "pi-main" "$OUT"
  t_has "reports its working directory" "$cwd_before" "$OUT"
}

orch_req_21() {
  begin "[REQ-21] Disarming the watcher leaves start-main succeeding"
  fresh_session
  PI_VAL="$TESTBIN/fake-pi"
  RUN_ENV=(START_MAIN_NO_WATCH=1)
  run_start --detach
  RUN_ENV=()
  t_eq "exits 0" 0 "$RC"
  if wait_for_child "$TESTBIN/fake-pi"
  then ok "the session runs pi"
  else bad "the session does not run pi (args: $(pane_child_args))"
  fi
  t_eq "the session gains no watch window" 0 "$(watch_windows)"
  t_eq "only the pi window exists" 1 "$(window_count)"
  t_has "the output reports the watcher disabled" \
    "watcher: disabled (START_MAIN_NO_WATCH=1)" "$OUT"
}

orch_req_22() {
  begin "[REQ-22] A watcher window that cannot be armed does not fail start-main"
  fresh_session
  mk_tmux_shim "$TMP/tmux-shim"
  PI_VAL="$TESTBIN/fake-pi"
  TMUX_SHIM="$TMP/tmux-shim"
  run_start --detach
  TMUX_SHIM=""
  t_eq "exits 0 despite the refused window" 0 "$RC"
  if wait_for_child "$TESTBIN/fake-pi"
  then ok "the session runs pi"
  else bad "the session does not run pi (args: $(pane_child_args))"
  fi
  t_eq "no watch window was created" 0 "$(watch_windows)"
  t_has "warns that the watcher could not be armed" "could not arm the orchestrator watcher" "$ERR"
  t_has "names what is missing" "only automatic stall watching is missing" "$ERR"
  t_has "the output reports the watcher unavailable" "watcher: unavailable" "$OUT"
}

# --- run --------------------------------------------------------------------

main() {
  printf '== start-main.sh suite (isolated tmux socket: %s)\n' "$TMP"
  printf '   main checkout under test: %s\n\n' "$MAIN_WT"
  req_1
  req_2
  req_3
  req_4
  req_5
  req_6
  req_7
  req_8
  req_9
  orch_req_1
  orch_req_2
  orch_req_21
  orch_req_22

  begin "[REQ-27] Touched scripts stay shellcheck-clean"
  # orchestrator-stall-recovery [REQ-27] names the watcher, start-main.sh and
  # the two scripts whose seams the feature changed, so this gate covers them.
  local -a touched=("$START" "$START_DIR/main-watch.sh" "$START_DIR/_sub-common.sh" \
                    "$START_DIR/sub-fallback.sh" "$TESTS_DIR/test-start-main.sh")
  if bash -n "${touched[@]}"
  then ok "start-main.sh, main-watch.sh, _sub-common.sh, sub-fallback.sh and the test suite pass bash -n"
  else bad "bash -n reported syntax errors"
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -P SCRIPTDIR "${touched[@]}"
    then ok "start-main.sh, main-watch.sh, _sub-common.sh, sub-fallback.sh and the test suite are shellcheck-clean"
    else bad "shellcheck reported issues"
    fi
  else
    skip "shellcheck not available"
  fi

  printf '\n== results: %d passed, %d failed, %d skipped\n' "$PASSES" "$FAILS" "$SKIPS"
  [ "$FAILS" -eq 0 ]
}

main "$@"
