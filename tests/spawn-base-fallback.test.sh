#!/usr/bin/env bash
# Behavioural tests for the spawn base-branch fallback
# (specs/spawn-base-fallback/spawn-base-fallback.feature); one test per
# Scenario, labels [REQ-n].
#
# Hermetic: fixture git repositories live under a scratch dir and carry their
# origin refs locally (no network); the end-to-end spawn tests sandbox fake
# `treehouse` and `tmux` binaries first on PATH, so no real worktree pool or
# tmux session is ever touched.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON=${SUB_COMMON_UNDER_TEST:-$ROOT/scripts/_sub-common.sh}
SPAWN=${SUB_SPAWN_UNDER_TEST:-$ROOT/scripts/sub-spawn.sh}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# make_base_repo <dir> <branch...> — a repository whose local refs include
# refs/remotes/origin/<branch> for every branch, with origin/HEAD pointing at
# the first. No remote is contacted (refs are written directly).
make_base_repo() {
  local dir=$1; shift
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/master
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  : > "$dir/f"
  git -C "$dir" add f
  git -C "$dir" commit -qm init
  local b
  for b in "$@"; do
    git -C "$dir" update-ref "refs/heads/$b" HEAD
    git -C "$dir" update-ref "refs/remotes/origin/$b" HEAD
  done
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$1"
}

# make_spawn_fixture <dir> [--break-remote] — a repository with a reachable
# origin (master + develop, origin/HEAD -> master) and a detached linked
# worktree for the fake treehouse to hand out. --break-remote removes the
# bare remote after cloning so a later FETCH fails while the remote-tracking
# refs stay put.
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
  git -C "$dir/seed" push -q origin master:develop
  git clone -q "$dir/remote.git" "$dir/repo"
  git -C "$dir/repo" config user.email t@t
  git -C "$dir/repo" config user.name t
  git -C "$dir/repo" fetch -q origin
  git -C "$dir/repo" worktree add -q --detach "$dir/wt"
  if [ "${2:-}" = "--break-remote" ]; then rm -rf "$dir/remote.git"; fi
}

# ---------------------------------------------------------------------------
# Harness: resolve_base_ref (unit)
# ---------------------------------------------------------------------------

RC=0; OUT=; RERR=
resolver() { # <repo-dir> <dev-branch>
  local repo=$1 dev=$2
  RC=0
  OUT=$(env DEV_BRANCH="$dev" bash -c "source '$COMMON'; resolve_base_ref '$repo'" \
    2>"$SCRATCH/resolver-stderr") || RC=$?
  RERR=$(cat "$SCRATCH/resolver-stderr")
}

# ---------------------------------------------------------------------------
# Harness: sub-spawn.sh end to end (fake treehouse + tmux)
# ---------------------------------------------------------------------------

setup_fakes() {
  BINDIR="$SCRATCH/bin"
  mkdir -p "$BINDIR"
  cat > "$BINDIR/tmux" <<'EOS'
#!/usr/bin/env bash
# Minimal fake tmux: no session ever exists; send-keys types into a pane file
# and a bare Enter changes it (the shell-pane path of tmux_send_line).
S=${FAKE_TMUX_DIR:?FAKE_TMUX_DIR not set}
mkdir -p "$S"
[ -f "$S/pane" ] || : > "$S/pane"
cmd=${1:-}; shift || true
case "$cmd" in
  has-session) exit 1 ;;
  new-session) exit 0 ;;
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
    else
      printf '\n[tick]\n' >> "$S/pane"
    fi
    exit 0 ;;
  capture-pane) cat "$S/pane"; exit 0 ;;
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

run_spawn() { # <fixture-dir> <dev-branch>
  local fx=$1 dev=$2
  RC=0
  OUT=$(env -u TMUX -u TMUX_PANE -u MAIN_SESSION \
        PI_BOOT_DELAY=0 SUB_SPAWN_NO_VIEWER=1 \
        FAKE_TMUX_DIR="$fx/tmux" \
        FAKE_WT="$fx/wt" \
        FAKE_TREEHOUSE_LOG="$fx/treehouse.log" \
        DEV_BRANCH="$dev" \
        PATH="$BINDIR:$PATH" \
        bash "$SPAWN" demo "$fx/repo" 2>"$fx/spawn-stderr") || RC=$?
  RERR=$(cat "$fx/spawn-stderr")
}

spawn_kickoff() { tr -d '\\' < "$1/tmux/pane"; }  # unescape printf %q spacing

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

t_req1_missing_dev_branch_falls_back_to_default() {
  local repo="$SCRATCH/req1"
  make_base_repo "$repo" master
  resolver "$repo" development
  [ "$RC" -eq 0 ] || fail "expected success, got $RC ($RERR)"
  [ "$OUT" = "origin/master" ] || fail "expected origin/master, got: $OUT"
}

t_req2_existing_origin_dev_branch_keeps_priority() {
  local repo="$SCRATCH/req2"
  make_base_repo "$repo" master develop
  resolver "$repo" develop
  [ "$RC" -eq 0 ] || fail "expected success, got $RC ($RERR)"
  [ "$OUT" = "origin/develop" ] || fail "expected origin/develop, got: $OUT"
}

t_req3_existing_local_only_dev_branch_keeps_priority() {
  local repo="$SCRATCH/req3"
  make_base_repo "$repo" master
  git -C "$repo" update-ref refs/heads/develop HEAD
  resolver "$repo" develop
  [ "$RC" -eq 0 ] || fail "expected success, got $RC ($RERR)"
  [ "$OUT" = "develop" ] || fail "expected local develop, got: $OUT"
}

t_req4_no_usable_base_fails_loudly() {
  local repo="$SCRATCH/req4"
  make_base_repo "$repo" master
  git -C "$repo" symbolic-ref --delete refs/remotes/origin/HEAD
  resolver "$repo" development
  [ "$RC" -ne 0 ] || fail "expected non-zero for a missing base"
  case $RERR in
    *"no base branch"*development*) ;;
    *) fail "error must name the missing base branch: $RERR" ;;
  esac
}

t_req5_spawn_reports_and_warns_about_the_chosen_base() {
  local fx="$SCRATCH/req5"
  make_spawn_fixture "$fx"
  run_spawn "$fx" development
  [ "$RC" -eq 0 ] || fail "expected synchronous spawn success, got $RC ($RERR)"
  grep -Eq 'base:[[:space:]]+origin/master' <<<"$OUT" \
    || fail "handles must report the chosen base, got: $OUT"
  case $RERR in
    *"falling back to the default branch 'master'"*) ;;
    *) fail "expected a fallback warning on stderr, got: $RERR" ;;
  esac
}

t_req6_child_pr_targets_the_chosen_base() {
  local fx="$SCRATCH/req6"
  make_spawn_fixture "$fx"
  run_spawn "$fx" development
  [ "$RC" -eq 0 ] || fail "expected spawn success, got $RC ($RERR)"
  spawn_kickoff "$fx" | grep -Fq 'a pull request against master' \
    || fail "kickoff must target the resolved base, got: $(spawn_kickoff "$fx")"
}

t_req7_fetch_failure_never_triggers_fallback() {
  local fx="$SCRATCH/req7"
  make_spawn_fixture "$fx" --break-remote
  run_spawn "$fx" develop
  [ "$RC" -eq 0 ] || fail "expected spawn success, got $RC ($RERR)"
  grep -Eq 'base:[[:space:]]+origin/develop' <<<"$OUT" \
    || fail "an existing remote ref must win despite the failed fetch, got: $OUT"
  case $RERR in
    *"falling back"*) fail "a fetch failure must not trigger the fallback: $RERR" ;;
  esac
}

t_req8_shellcheck_and_bash_n_clean() {
  bash -n "$COMMON" || fail "bash -n reported syntax errors in $COMMON"
  bash -n "$SPAWN"  || fail "bash -n reported syntax errors in $SPAWN"
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$COMMON" "$SPAWN" || fail "shellcheck reported findings"
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

run "[REQ-1] missing DEV_BRANCH falls back to origin/HEAD default" t_req1_missing_dev_branch_falls_back_to_default
run "[REQ-2] existing origin DEV_BRANCH keeps priority"           t_req2_existing_origin_dev_branch_keeps_priority
run "[REQ-3] existing local-only DEV_BRANCH keeps priority"       t_req3_existing_local_only_dev_branch_keeps_priority
run "[REQ-4] no usable base branch fails loudly"                   t_req4_no_usable_base_fails_loudly
run "[REQ-5] spawn reports and warns about the chosen base"       t_req5_spawn_reports_and_warns_about_the_chosen_base
run "[REQ-6] child PR targets the chosen base"                     t_req6_child_pr_targets_the_chosen_base
run "[REQ-7] fetch failure never triggers the fallback"            t_req7_fetch_failure_never_triggers_fallback
run "[REQ-8] touched scripts shellcheck-clean"                     t_req8_shellcheck_and_bash_n_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
