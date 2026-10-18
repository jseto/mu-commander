#!/usr/bin/env bash
# Behavioural tests for the launch confirmation of scripts/sub-spawn.sh
# (specs/fix-launch-confirm/fix-launch-confirm.feature); one test per
# Scenario, labels [REQ-n].
#
# Hermetic: the fixture git repository carries its origin refs locally (no
# network), and fake `treehouse` / `tmux` binaries sit first on PATH, so no
# real worktree pool, tmux session or pi is ever touched. The fake pane is a
# shell whose first Enter RUNS the typed line — pi boots and echoes the
# command it received, unescaped — which is the pane shape that failed the
# kickoff confirmation on 2026-10-18.
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
# (master + development, origin/HEAD -> master) and a detached linked worktree
# for the fake treehouse to hand out.
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
}

setup_fakes() {
  BINDIR="$SCRATCH/bin"
  mkdir -p "$BINDIR"
  cat > "$BINDIR/tmux" <<'EOS'
#!/usr/bin/env bash
# Fake tmux with a shell pane that RUNS the launch line on its first Enter:
# the raw command line is recorded in $S/ran (what the shell executed) and pi
# takes the pane over showing the message it received as its initial one — the
# kickoff, never the `pi -n …` command that carried it. Every send is logged so
# a test can count how often the launch line was typed.
set -u
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S"
[ -f "$S/log" ] || : > "$S/log"
[ -f "$S/line" ] || : > "$S/line"
[ -f "$S/ran" ] || : > "$S/ran"
[ -f "$S/transcript" ] || : > "$S/transcript"
D='────────────────────────────────────────────────────────────────────'
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
    # Enter: the shell runs whatever is on its command line, and pi takes over.
    if [ -s "$S/line" ]; then
      cat "$S/line" > "$S/ran"
      printf 'pi received the kickoff as its initial message\n' > "$S/transcript"
      : > "$S/line"
    fi
    exit 0 ;;
  capture-pane)
    if [ -s "$S/transcript" ]; then
      cat "$S/transcript"
      printf '\n%s\n\n\n%s\n' "$D" "$D"
      printf '%s\n' '/fake/worktree (task/demo)'
      printf 'stats\n'
      exit 0
    fi
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
run_spawn() { # <fixture-dir>
  local fx=$1
  RC=0
  OUT=$(env -u TMUX -u TMUX_PANE -u MAIN_SESSION \
        PI_BOOT_DELAY=0 SUB_SPAWN_NO_VIEWER=1 SUB_SPAWN_NO_WATCH=1 \
        FAKE_TMUX_DIR="$fx/tmux" \
        FAKE_WT="$fx/wt" \
        FAKE_TREEHOUSE_LOG="$fx/treehouse.log" \
        PATH="$BINDIR:$PATH" \
        bash "$SPAWN" demo "$fx/repo" 2>"$fx/spawn-stderr") || RC=$?
  RERR=$(cat "$fx/spawn-stderr")
}

launch_lines_typed() { grep -c -- ' -l pi -n demo' "$1/tmux/log"; }

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

# The incident, end to end: pi boots on the first Enter, before the kickoff
# confirmation runs. The spawn must succeed and report the handles.
t_req5_spawn_succeeds_when_pi_boots_before_confirmation() {
  local fx="$SCRATCH/req5"
  make_spawn_fixture "$fx"
  run_spawn "$fx"
  [ "$RC" -eq 0 ] || fail "expected spawn success, got $RC: $RERR"
  grep -Eq 'session:[[:space:]]+pi-demo' <<<"$OUT" \
    || fail "the spawn must report the session handle, got: $OUT"
  grep -Fq 'pi-sub/tasks/demo.md' "$fx/tmux/ran" \
    || fail "the shell must have run the launch line: $(cat "$fx/tmux/ran")"
  grep -Fq 'pi -n demo' "$fx/tmux/ran" \
    || fail "the line the shell ran must be the launch command: $(cat "$fx/tmux/ran")"
  grep -Fq 'pi received the kickoff' "$fx/tmux/transcript" \
    || fail "pi must have taken the pane over"
  [ "$(launch_lines_typed "$fx")" -eq 1 ] \
    || fail "the launch line must be typed once, got $(launch_lines_typed "$fx"): $(cat "$fx/tmux/log")"
  [ ! -s "$fx/tmux/line" ] || fail "nothing may be left on the shell command line"
}

t_req6_shellcheck_and_bash_n_clean() {
  bash -n "$SPAWN" || fail "bash -n reported syntax errors in $SPAWN"
  bash -n "${BASH_SOURCE[0]}" || fail "bash -n reported syntax errors in this file"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$SPAWN" "${BASH_SOURCE[0]}" || fail "shellcheck reported findings"
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

run "[REQ-5] spawn succeeds when pi boots before the confirmation" t_req5_spawn_succeeds_when_pi_boots_before_confirmation
run "[REQ-6] touched scripts shellcheck-clean"                       t_req6_shellcheck_and_bash_n_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'