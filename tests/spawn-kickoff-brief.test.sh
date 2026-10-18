#!/usr/bin/env bash
# Behavioural tests for the spawn kickoff deferring to the task brief
# (specs/spawn-kickoff-brief/spawn-kickoff-brief.feature); one test per
# Scenario, labels [REQ-n].
#
# Hermetic: the fixture git repository carries its origin refs locally (no
# network), and fake `treehouse` / `tmux` binaries sit first on PATH, so no
# real worktree pool, tmux session or pi is ever touched. The fake pane is a
# fresh shell that RUNS the launch line on Enter and records it, so the test
# sees the kickoff exactly as pi received it — an argument of the launch line.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SPAWN=${SUB_SPAWN_UNDER_TEST:-$ROOT/scripts/sub-spawn.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# make_spawn_fixture <dir> — a repository with a reachable local origin
# (master, origin/HEAD -> master) and a detached linked worktree for the fake
# treehouse to hand out.
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
  git clone -q "$dir/remote.git" "$dir/repo"
  git -C "$dir/repo" config user.email t@t
  git -C "$dir/repo" config user.name t
  git -C "$dir/repo" fetch -q origin
  git -C "$dir/repo" worktree add -q --detach "$dir/wt"
}

setup_fakes() {
  BINDIR="$SCRATCH/bin"
  mkdir -p "$BINDIR"
  cat > "$BINDIR/tmux" <<'EOS'
#!/usr/bin/env bash
# Fake tmux with a fresh shell pane: a literal send lands on the shell command
# line ($S/line); an Enter RUNS it, recording the exact command line in $S/ran
# and clearing the prompt. Every send is logged so a test can count the typed
# launch lines. A shell pane, so the spawn's shell confirmation settles the send.
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S"
[ -f "$S/log" ] || : > "$S/log"
[ -f "$S/line" ] || : > "$S/line"
[ -f "$S/ran" ] || : > "$S/ran"
case "${1:-}" in
  has-session) exit 1 ;;
  new-session|new-window) exit 0 ;;
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
    fi
    exit 0 ;;
  capture-pane)
    printf 'user@host:~$ %s\n' "$(cat "$S/line")"
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

RC=0; OUT=; RERR=
run_spawn() { # <fixture-dir> [brief-file]
  local fx=$1 brief=${2:-} args
  args=(demo "$fx/repo")
  [ -n "$brief" ] && args+=("$brief")
  RC=0
  OUT=$(env -u TMUX -u TMUX_PANE -u MAIN_SESSION \
        PI_BOOT_DELAY=0 SUB_SPAWN_NO_VIEWER=1 SUB_SPAWN_NO_WATCH=1 \
        FAKE_TMUX_DIR="$fx/tmux" \
        FAKE_WT="$fx/wt" \
        FAKE_TREEHOUSE_LOG="$fx/treehouse.log" \
        PATH="$BINDIR:$PATH" \
        bash "$SPAWN" "${args[@]}" 2>"$fx/spawn-stderr") || RC=$?
  RERR=$(cat "$fx/spawn-stderr")
}

# The kickoff as pi received it: the argument of the launch line the shell ran,
# with the shell-escaping backslashes `printf %q` produced stripped.
spawn_kickoff() { local line; line=$(cat "$1/tmux/ran"); printf '%s' "${line//\\/}"; }
launch_lines_typed() { grep -c -- ' -l .*pi -n demo' "$1/tmux/log" || true; }

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

t_req1_kickoff_names_the_brief_as_authority() {
  local fx="$SCRATCH/req1" k
  make_spawn_fixture "$fx"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "expected spawn success, got $RC: $RERR"
  grep -Eq 'session:[[:space:]]+pi-demo' <<<"$OUT" \
    || fail "the spawn must report the session handle, got: $OUT"
  k=$(spawn_kickoff "$fx")
  grep -Fq 'pi-sub/tasks/demo.md' <<<"$k" \
    || fail "the kickoff must name the brief path, got: $k"
  grep -Fq 'source of truth for what this task must deliver' <<<"$k" \
    || fail "the kickoff must name the brief as the deliverable authority, got: $k"
}

t_req2_change_brief_is_told_to_commit_push_and_pr() {
  local fx="$SCRATCH/req2" k
  make_spawn_fixture "$fx"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "expected spawn success, got $RC: $RERR"
  k=$(spawn_kickoff "$fx")
  grep -Fq 'commit your work on the current branch (task/demo)' <<<"$k" \
    || fail "the kickoff must tell a change child to commit, got: $k"
  grep -Fq 'push your branch to origin' <<<"$k" \
    || fail "the kickoff must tell a change child to push, got: $k"
  grep -Fq 'open a pull request against master using gh pr create' <<<"$k" \
    || fail "the kickoff must tell a change child to open a PR against the resolved base, got: $k"
}

t_req3_read_only_brief_is_not_contradicted() {
  local fx="$SCRATCH/req3" k
  make_spawn_fixture "$fx"
  printf 'Read-only: change nothing, push nothing, open no PR.\n' > "$fx/brief.md"
  run_spawn "$fx" "$fx/brief.md"
  [ "$RC" -eq 0 ] || fail "expected spawn success, got $RC: $RERR"
  k=$(spawn_kickoff "$fx")
  grep -Fq 'pi-sub/tasks/demo.md' <<<"$k" \
    || fail "the kickoff must name the read-only brief path, got: $k"
  grep -Fq 'If the brief is read-only' <<<"$k" \
    || fail "the kickoff must recognise a read-only brief, got: $k"
  grep -Fq 'change nothing, push nothing, and open no PR' <<<"$k" \
    || fail "the kickoff must state the read-only deliverable, got: $k"
  if grep -Fq 'PR link' <<<"$k"; then
    fail "the report clause must not demand a PR link of every child, got: $k"
  fi
  if grep -Fq '(PR #...)' <<<"$k"; then
    fail "the DONE notice must not demand a PR number of every child, got: $k"
  fi
}

t_req4_process_comes_from_agents_md_not_the_kickoff() {
  local fx="$SCRATCH/req4" k
  make_spawn_fixture "$fx"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "expected spawn success, got $RC: $RERR"
  k=$(spawn_kickoff "$fx")
  grep -Fq "this repository's AGENTS.md" <<<"$k" \
    || fail "the kickoff must point at the repository's AGENTS.md, got: $k"
  for step in 'atomic specs' 'implementation' 'code audit'; do
    if grep -Fq "$step" <<<"$k"; then
      fail "the kickoff must not enumerate the flow step '$step', got: $k"
    fi
  done
}

t_req5_kickoff_is_pi_initial_message_argument() {
  local fx="$SCRATCH/req5" k
  make_spawn_fixture "$fx"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "expected spawn success, got $RC: $RERR"
  [ -s "$fx/tmux/ran" ] || fail "the shell must have run the launch command"
  k=$(spawn_kickoff "$fx")
  grep -Fq 'pi -n demo' <<<"$k" \
    || fail "the shell must have run the pi launch command, got: $k"
  grep -Fq 'Read the task brief at' <<<"$k" \
    || fail "the kickoff must ride on the launch line as pi's initial message, got: $k"
  [ "$(launch_lines_typed "$fx")" -eq 1 ] \
    || fail "the launch line must be typed exactly once, got $(launch_lines_typed "$fx"): $(cat "$fx/tmux/log")"
  [ ! -s "$fx/tmux/line" ] || fail "nothing may be left parked on the shell command line"
}

t_req6_touched_scripts_shellcheck_and_bash_n_clean() {
  bash -n "$SPAWN" || fail "bash -n reported syntax errors in $SPAWN"
  bash -n "${BASH_SOURCE[0]}" || fail "bash -n reported syntax errors in this file"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck -S warning "$SPAWN" "${BASH_SOURCE[0]}" || fail "shellcheck reported findings"
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

run "[REQ-1] kickoff names the brief as the deliverable authority" t_req1_kickoff_names_the_brief_as_authority
run "[REQ-2] change brief told to commit, push and open a PR"     t_req2_change_brief_is_told_to_commit_push_and_pr
run "[REQ-3] read-only brief is never contradicted"               t_req3_read_only_brief_is_not_contradicted
run "[REQ-4] process comes from AGENTS.md, not the kickoff"       t_req4_process_comes_from_agents_md_not_the_kickoff
run "[REQ-5] kickoff is pi's initial message argument"            t_req5_kickoff_is_pi_initial_message_argument
run "[REQ-6] touched scripts shellcheck- and bash -n-clean"       t_req6_touched_scripts_shellcheck_and_bash_n_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
