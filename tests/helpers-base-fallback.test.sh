#!/usr/bin/env bash
# Behavioural tests for the comparison-helper base fallback
# (specs/helpers-base-fallback/helpers-base-fallback.feature); one test per
# Scenario, labels [REQ-n].
#
# Hermetic: fixture git repositories live under a scratch dir and carry their
# origin refs locally (no network); end-to-end runs sandbox fake
# `treehouse`/`tmux`/`gh` binaries first on PATH, so no real worktree pool,
# tmux session, or GitHub access is touched.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON=${SUB_COMMON_UNDER_TEST:-$ROOT/scripts/_sub-common.sh}
CHANGES=${SUB_CHANGES_UNDER_TEST:-$ROOT/scripts/sub-changes.sh}
LAND=${SUB_LAND_UNDER_TEST:-$ROOT/scripts/sub-land.sh}
RETIRE=${SUB_RETIRE_UNDER_TEST:-$ROOT/scripts/sub-retire.sh}

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

# make_worktree_fixture <dir> [--no-dev] — a repository with a reachable
# origin (master, plus development unless --no-dev), a linked task worktree
# "task/demo" carrying one commit, and that branch pushed to origin. The task
# branch is based on the repository default (master); with --no-dev the
# configured "development" base is missing everywhere.
make_worktree_fixture() {
  local dir=$1 mode=${2:-}
  mkdir -p "$dir"
  git init -q --bare "$dir/remote.git"
  git -C "$dir/remote.git" symbolic-ref HEAD refs/heads/master
  git init -q "$dir/seed"
  git -C "$dir/seed" symbolic-ref HEAD refs/heads/master
  git -C "$dir/seed" config user.email t@t
  git -C "$dir/seed" config user.name t
  echo init > "$dir/seed/f"
  git -C "$dir/seed" add f
  git -C "$dir/seed" commit -qm init
  git -C "$dir/seed" remote add origin "$dir/remote.git"
  git -C "$dir/seed" push -q origin master
  [ "$mode" = "--no-dev" ] || git -C "$dir/seed" push -q origin master:development
  git clone -q "$dir/remote.git" "$dir/repo"
  git -C "$dir/repo" config user.email t@t
  git -C "$dir/repo" config user.name t
  git -C "$dir/repo" fetch -q origin
  [ "$mode" = "--no-dev" ] || git -C "$dir/repo" branch development origin/development
  git -C "$dir/repo" worktree add -q --detach "$dir/wt"
  git -C "$dir/wt" switch -q -c task/demo
  echo work > "$dir/wt/taskfile"
  git -C "$dir/wt" add taskfile
  git -C "$dir/wt" commit -qm "task work"
  git -C "$dir/wt" push -q -u origin task/demo
}

setup_fakes() {
  BINDIR="$SCRATCH/bin"
  mkdir -p "$BINDIR"
  cat > "$BINDIR/treehouse" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  status) printf '[{"path":"%s","lease_holder":"demo"}]\n' "$FAKE_WT" ;;
  return)
    printf '%s\n' "$*" >> "$FAKE_TREEHOUSE_LOG"
    shift
    [ "${1:-}" = "--force" ] && shift
    # The real 'treehouse return --force' cleans, resets and detaches HEAD.
    git -C "$1" checkout --detach -q 2>/dev/null || true ;;
esac
exit 0
EOS
  cat > "$BINDIR/tmux" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = "has-session" ] && exit 1
exit 0
EOS
  cat > "$BINDIR/gh" <<'EOS'
#!/usr/bin/env bash
printf '[]\n'
exit 0
EOS
  chmod +x "$BINDIR/treehouse" "$BINDIR/tmux" "$BINDIR/gh"
}

# run_helper <script> <fixture> <args...>
run_helper() {
  local script=$1 fx=$2; shift 2
  RC=0
  OUT=$(env -u TMUX -u TMUX_PANE -u MAIN_SESSION \
        FAKE_WT="$fx/wt" FAKE_TREEHOUSE_LOG="$fx/treehouse.log" \
        PATH="$BINDIR:$PATH" \
        bash "$script" "$@" 2>"$fx/stderr") || RC=$?
  RERR=$(cat "$fx/stderr")
}

# remove_origin_head <fixture> — break the origin/HEAD fallback too.
remove_origin_head() {
  git -C "$1/repo" symbolic-ref --delete refs/remotes/origin/HEAD
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

t_req1_sub_changes_falls_back() {
  local fx="$SCRATCH/req1"
  make_worktree_fixture "$fx" --no-dev
  run_helper "$CHANGES" "$fx" demo "$fx/repo"
  [ "$RC" -eq 0 ] || fail "expected success, got $RC ($RERR)"
  grep -Fq 'task work' <<<"$OUT"        || fail "commit list missing: $OUT"
  grep -Fq 'commits not on master' <<<"$OUT"    || fail "commits label must name master: $OUT"
  grep -Fq 'diff stat vs master' <<<"$OUT"      || fail "diff-stat label must name master: $OUT"
  grep -Fq 'taskfile' <<<"$OUT"         || fail "diff stat missing: $OUT"
}

t_req2_sub_land_falls_back() {
  local fx="$SCRATCH/req2"
  make_worktree_fixture "$fx" --no-dev
  run_helper "$LAND" "$fx" demo "$fx/repo"
  [ "$RC" -eq 0 ] || fail "expected success, got $RC ($RERR)"
  grep -Fq 'commits not on master: 1' <<<"$OUT" || fail "unlanded count must be 1 on master: $OUT"
  grep -Fq 'gh pr create --base master --head task/demo' <<<"$OUT" \
    || fail "publish instructions must target master: $OUT"
}

t_req3_sub_retire_resolves_base() {
  local fx="$SCRATCH/req3"
  make_worktree_fixture "$fx" --no-dev
  run_helper "$RETIRE" "$fx" demo "$fx/repo"
  [ "$RC" -eq 0 ] || fail "expected successful retirement, got $RC ($RERR)"
  grep -Fq 'returned worktree' <<<"$OUT" || fail "worktree was not returned: $OUT"
  [ -s "$fx/treehouse.log" ] || fail "treehouse return was never called"
}

t_req4_fallback_is_warned() {
  local fx="$SCRATCH/req4"
  make_worktree_fixture "$fx" --no-dev
  run_helper "$CHANGES" "$fx" demo "$fx/repo"
  [ "$RC" -eq 0 ] || fail "expected success, got $RC ($RERR)"
  case "$RERR" in
    *"falling back to the default branch 'master'"*) ;;
    *) fail "expected a fallback warning on stderr: $RERR" ;;
  esac
}

t_req5_existing_dev_branch_unchanged() {
  local fx="$SCRATCH/req5"
  make_worktree_fixture "$fx"
  run_helper "$CHANGES" "$fx" demo "$fx/repo"
  [ "$RC" -eq 0 ] || fail "sub-changes failed: $RERR"
  grep -Fq 'commits not on development' <<<"$OUT" || fail "sub-changes label must name development: $OUT"
  run_helper "$LAND" "$fx" demo "$fx/repo"
  [ "$RC" -eq 0 ] || fail "sub-land failed: $RERR"
  grep -Fq 'commits not on development: 1' <<<"$OUT" || fail "sub-land count must be development-based: $OUT"
  grep -Fq 'gh pr create --base development --head task/demo' <<<"$OUT" \
    || fail "sub-land PR base must be development: $OUT"
  case "$RERR" in
    *"falling back"*) fail "must not warn when development exists: $RERR" ;;
  esac
  run_helper "$RETIRE" "$fx" demo "$fx/repo"
  [ "$RC" -eq 0 ] || fail "sub-retire failed: $RERR"
  case "$RERR" in
    *"falling back"*) fail "must not warn when development exists: $RERR" ;;
  esac
}

t_req6_unlanded_count_never_reads_broken_base_as_zero() {
  local repo="$SCRATCH/req6"
  make_base_repo "$repo" master
  # Deliberately no pipefail (bash -c starts without it): a `git log | wc -l`
  # implementation would report 0 here and exit successfully.
  RC=0
  OUT=$(env DEV_BRANCH=development bash -c \
        "source '$COMMON'; unlanded_count '$repo' no-such-base" 2>"$SCRATCH/req6-err") || RC=$?
  [ "$RC" -eq 1 ] || fail "expected the count to fail with 1, got $RC (out='$OUT')"
  [ -z "$OUT" ] || fail "expected no count, got '$OUT'"

  # End to end: a base that cannot be resolved aborts sub-retire before any
  # worktree is returned, even though the guard counts nothing.
  local fx="$SCRATCH/req6b"
  make_worktree_fixture "$fx" --no-dev
  remove_origin_head "$fx"
  run_helper "$RETIRE" "$fx" demo "$fx/repo"
  [ "$RC" -ne 0 ] || fail "expected refusal with a broken base, got success: $OUT"
  [ ! -s "$fx/treehouse.log" ] || fail "worktree was returned despite a broken base: $(cat "$fx/treehouse.log")"
}

t_req7_cleanup_uses_resolved_base() {
  local fx="$SCRATCH/req7"
  make_worktree_fixture "$fx" --no-dev
  run_helper "$RETIRE" "$fx" demo "$fx/repo"
  [ "$RC" -eq 0 ] || fail "expected successful retirement, got $RC ($RERR)"
  case "$RERR" in
    *"not merged into master"*) ;;
    *) fail "branch cleanup must name the resolved base master: $RERR" ;;
  esac
}

t_req8_shellcheck_and_bash_n_clean() {
  local f
  for f in "$COMMON" "$CHANGES" "$LAND" "$RETIRE"; do
    bash -n "$f" || fail "bash -n reported syntax errors in $f"
  done
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  shellcheck "$COMMON" "$CHANGES" "$LAND" "$RETIRE" || fail "shellcheck reported findings"
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

run "[REQ-1] sub-changes falls back to the origin/HEAD default"    t_req1_sub_changes_falls_back
run "[REQ-2] sub-land falls back to the origin/HEAD default"       t_req2_sub_land_falls_back
run "[REQ-3] sub-retire resolves the base instead of dying"        t_req3_sub_retire_resolves_base
run "[REQ-4] the fallback is reported as a warning"                t_req4_fallback_is_warned
run "[REQ-5] an existing DEV_BRANCH keeps the helpers unchanged"   t_req5_existing_dev_branch_unchanged
run "[REQ-6] the refusal never reads a broken base as zero"        t_req6_unlanded_count_never_reads_broken_base_as_zero
run "[REQ-7] cleanup compares against the resolved base"           t_req7_cleanup_uses_resolved_base
run "[REQ-8] touched scripts shellcheck-clean"                     t_req8_shellcheck_and_bash_n_clean

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
