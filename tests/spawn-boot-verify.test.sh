#!/usr/bin/env bash
# Behavioural tests for the spawn's boot verification
# (specs/spawn-boot-verify/spawn-boot-verify.feature); one test per Scenario,
# labels [REQ-n].
#
# Hermetic: the fixture git repository carries its origin refs locally (no
# network), and fake `treehouse` / `tmux` binaries sit first on PATH, so no
# real worktree pool, tmux session or pi is ever touched. The fake pane runs
# the launch line on Enter and then reports whatever pane command the test
# chose — that is exactly how a pi that died during startup looks (the shell
# is back) versus a healthy one (pi keeps the pane).
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SPAWN=${SUB_SPAWN_UNDER_TEST:-$ROOT/scripts/sub-spawn.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# A fixture levels config: the shipped config.json is never the subject under
# test, and this one names no allowed extensions.
LEVELS_FIXTURE="$SCRATCH/levels.json"
cat > "$LEVELS_FIXTURE" <<'JSON'
{ "taskLevels": { "default": "standard",
    "levels": { "standard": { "model": "fixture/model", "thinking": "high" } } } }
JSON

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# make_spawn_fixture <dir> — a repository with a reachable local origin
# (master + development, origin/HEAD -> master) and a detached linked worktree
# for the fake treehouse to hand out. Also prepares the fake pane state: what
# the shell/pi pane shows after the launch line ran ($dir/tmux/pane) and what
# command tmux reports for it (absent = unreadable).
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
}

# A pane that shows a healthy pi after the launch line ran.
healthy_pane() { # <fixture-dir>
  cat > "$1/tmux/pane" <<'EOF'
────────────────────────────────────────────────────────────────────────────
 pi 1.5.0
────────────────────────────────────────────────────────────────────────────
EOF
  printf 'node\n' > "$1/tmux/pane_cmd"
}

# A pane that shows pi's startup failure — what the model-not-found incident
# left behind: the error lines, then the shell prompt is back.
failed_pane() { # <fixture-dir>
  cat > "$1/tmux/pane" <<'EOF'
Warning: No models match pattern "fixture/model"
Error: Model "fixture/model" not found. Use --list-models to see available models.
user@host:~/wt$
EOF
  printf 'bash\n' > "$1/tmux/pane_cmd"
}

setup_fakes() {
  BINDIR="$SCRATCH/bin"
  mkdir -p "$BINDIR"
  cat > "$BINDIR/tmux" <<'EOS'
#!/usr/bin/env bash
# Fake tmux. The pane is a shell that RUNS the launch line on Enter; after
# that it shows $S/pane and reports the command in $S/pane_cmd (absent = the
# pane command cannot be read), optionally switching to $S/pane_cmd_next once
# more than $S/switch_after display-message calls have happened — a slow boot.
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S"
[ -f "$S/log" ] || : > "$S/log"
[ -f "$S/line" ] || : > "$S/line"
[ -f "$S/ran" ] || : > "$S/ran"
case "${1:-}" in
  has-session) [ -f "$S/session" ] ; exit $? ;;
  new-session)  : > "$S/session"; exit 0 ;;
  new-window)   exit 0 ;;
  kill-session)
    printf 'kill-session %s\n' "$*" >> "$S/log"
    rm -f "$S/session"
    exit 0 ;;
  send-keys)
    shift
    printf 'send-keys %s\n' "$*" >> "$S/log"
    literal=0 text=
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) text=$1; shift ;; esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "$text" > "$S/line"
      exit 0
    fi
    if [ -s "$S/line" ]; then
      cat "$S/line" > "$S/ran"
      : > "$S/line"
      : > "$S/booted"
    fi
    exit 0 ;;
  capture-pane)
    if [ -f "$S/booted" ]; then
      cat "$S/pane" 2>/dev/null || : > "$S/pane"
    else
      printf 'user@host:~$ %s\n' "$(cat "$S/line")"
    fi
    exit 0 ;;
  display-message)
    shift
    fmt=${!#}
    case $fmt in
      *pane_current_command*)
        n=0
        [ -f "$S/dm" ] && n=$(cat "$S/dm")
        n=$((n + 1))
        printf '%s' "$n" > "$S/dm"
        switch_after=0
        [ -f "$S/switch_after" ] && switch_after=$(cat "$S/switch_after")
        if [ "$switch_after" -gt 0 ] && [ "$n" -gt "$switch_after" ] && [ -f "$S/pane_cmd_next" ]; then
          cat "$S/pane_cmd_next"
        elif [ -f "$S/pane_cmd" ]; then
          cat "$S/pane_cmd"
        fi
        ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
EOS
  cat > "$BINDIR/treehouse" <<'EOS'
#!/usr/bin/env bash
# Fake treehouse: reports no leases, hands out $FAKE_WT, records returns.
case "${1:-}" in
  status) printf '[]\n' ;;
  get)    printf '%s\n' "$FAKE_WT" ;;
  return) printf '%s\n' "$*" >> "$FAKE_TREEHOUSE_LOG" ;;
esac
EOS
  chmod +x "$BINDIR/tmux" "$BINDIR/treehouse"
}

RC=0; OUT=; RERR=; VERIFY_SECONDS=0

run_spawn() { # <fixture-dir>
  local fx=$1
  RC=0
  OUT=$(env -u TMUX -u TMUX_PANE -u MAIN_SESSION -u MAIN_PANE \
        -u SUB_CHILD_ALLOWED_EXTENSIONS -u SUB_LEVEL -u SUB_MODEL -u SUB_THINKING \
        PI_BOOT_DELAY=0 PI_BOOT_VERIFY_SECONDS="$VERIFY_SECONDS" \
        SUB_LEVELS_CONFIG="$LEVELS_FIXTURE" \
        SUB_SPAWN_NO_VIEWER=1 SUB_SPAWN_NO_WATCH=1 \
        FAKE_TMUX_DIR="$fx/tmux" \
        FAKE_WT="$fx/wt" \
        FAKE_TREEHOUSE_LOG="$fx/treehouse.log" \
        PATH="$BINDIR:$PATH" \
        bash "$SPAWN" demo "$fx/repo" 2>"$fx/spawn-stderr") || RC=$?
  RERR=$(cat "$fx/spawn-stderr")
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

# [REQ-43] pi exiting during startup must fail the spawn and release everything.
t_req43_exited_child_fails_the_spawn() {
  local fx="$SCRATCH/req43"
  make_spawn_fixture "$fx"
  failed_pane "$fx"
  VERIFY_SECONDS=0
  run_spawn "$fx"
  [ "$RC" -ne 0 ] || fail "a child whose pi exited must fail the spawn, got RC=0: $OUT"
  grep -Fq 'pi is not running in pi-demo' <<<"$RERR" \
    || fail "the failure must name the dead child, got: $RERR"
  if grep -Fq 'task:' <<<"$OUT"; then
    fail "a failed spawn must print no handles, got: $OUT"
  fi
  grep -Eq '^return --force ' "$fx/treehouse.log" \
    || fail "the leased worktree must be returned, got: $(cat "$fx/treehouse.log" 2>/dev/null)"
  grep -Fq 'kill-session' "$fx/tmux/log" \
    || fail "the tmux session must be removed, got: $(cat "$fx/tmux/log")"
}

# [REQ-44] a child that keeps pi reports the handles as before.
t_req44_running_child_is_reported() {
  local fx="$SCRATCH/req44"
  make_spawn_fixture "$fx"
  healthy_pane "$fx"
  VERIFY_SECONDS=0
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "a running child must succeed, got $RC: $RERR"
  grep -Eq 'task:[[:space:]]+demo' <<<"$OUT" || fail "the task handle must be printed, got: $OUT"
  grep -Eq 'session:[[:space:]]+pi-demo' <<<"$OUT" || fail "the session handle must be printed, got: $OUT"
}

# [REQ-45] a slow boot inside the verification window still succeeds.
t_req45_slow_boot_still_succeeds() {
  local fx="$SCRATCH/req45"
  make_spawn_fixture "$fx"
  healthy_pane "$fx"
  printf '1\n' > "$fx/tmux/switch_after"   # first check sees the shell
  printf 'bash\n' > "$fx/tmux/pane_cmd"    # ... then pi owns the pane
  printf 'node\n' > "$fx/tmux/pane_cmd_next"
  VERIFY_SECONDS=5
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "a slow boot inside the window must succeed, got $RC: $RERR"
  grep -Eq 'task:[[:space:]]+demo' <<<"$OUT" || fail "the task handle must be printed, got: $OUT"
  [ "$(cat "$fx/tmux/dm")" -gt 1 ] || fail "the verifier must have polled more than once"
}

# [REQ-46] an unreadable pane command never fails a healthy spawn.
t_req46_unreadable_pane_does_not_fail() {
  local fx="$SCRATCH/req46"
  make_spawn_fixture "$fx"
  healthy_pane "$fx"
  rm -f "$fx/tmux/pane_cmd"     # tmux cannot report the command
  VERIFY_SECONDS=0
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "an unreadable pane must not fail the spawn, got $RC: $RERR"
  grep -Eq 'task:[[:space:]]+demo' <<<"$OUT" || fail "the handles must be printed, got: $OUT"
  grep -Fq 'assuming pi booted' <<<"$RERR" \
    || fail "the degraded probe must say so, got: $RERR"
}

# [REQ-47] the failure output carries the pane's own reason.
t_req47_failure_shows_why_pi_exited() {
  local fx="$SCRATCH/req47"
  make_spawn_fixture "$fx"
  failed_pane "$fx"
  VERIFY_SECONDS=0
  run_spawn "$fx"
  [ "$RC" -ne 0 ] || fail "expected the spawn to fail, got RC=0: $OUT"
  grep -Fq 'Error: Model "fixture/model" not found' <<<"$RERR" \
    || fail "the failure output must include the pane's error line, got: $RERR"
}

# [REQ-49] bash -n and shellcheck on every shell file this change touches.
t_req49_shellcheck_and_bash_n_clean() {
  local f
  for f in "$ROOT/scripts/_sub-common.sh" "$SPAWN" "${BASH_SOURCE[0]}"; do
    bash -n "$f" || fail "bash -n reported syntax errors in $f"
  done
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$ROOT/scripts/_sub-common.sh" "$SPAWN" "${BASH_SOURCE[0]}" \
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

setup_fakes

run "[REQ-43] a child that exited during startup fails the spawn" t_req43_exited_child_fails_the_spawn
run "[REQ-44] a running child is reported normally"              t_req44_running_child_is_reported
run "[REQ-45] a slow boot inside the window still succeeds"      t_req45_slow_boot_still_succeeds
run "[REQ-46] an unreadable pane does not fail a healthy spawn"  t_req46_unreadable_pane_does_not_fail
run "[REQ-47] the failure shows why pi exited"                   t_req47_failure_shows_why_pi_exited
run "[REQ-49] touched scripts shellcheck-clean"                  t_req49_shellcheck_and_bash_n_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
