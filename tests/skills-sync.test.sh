#!/usr/bin/env bash
# Behavioural tests for the required-skills sync — one assertion block per
# scenario in specs/skills-sync-hook/skills-sync-hook.feature ([REQ-n]
# traceable). REQ-11/REQ-12 (worktree-setup activation) live in
# tests/worktree-setup.test.sh next to the rest of that script's suite.
#
# Hook scenarios ([REQ-1], [REQ-2], [REQ-6]) run REAL git in a sandbox: a
# local bare origin, a work clone seeded with .githooks/ and
# scripts/sync-skills.sh, and a fake HOME holding .agents/skills — no
# network, no touches of this checkout, and global git config is bypassed
# through the fake HOME. Sync scenarios ([REQ-3]..[REQ-5]) invoke
# scripts/sync-skills.sh directly. Installer scenarios ([REQ-7]..[REQ-10])
# run a copy of install.sh inside a sandbox *repository* (real git, so the
# core.hooksPath assertions are observable) with every dependency resolving
# through marker stubs — the run stays on the all-present no-op path, so no
# package manager or downloader can ever execute.
#
# Usage: bash tests/skills-sync.test.sh   (exit 0 = all green)
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASH_BIN=$(command -v bash)
REAL_SHELLCHECK=$(command -v shellcheck || true)
SYNC=$ROOT/scripts/sync-skills.sh

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SB=$(mktemp -d)
# The unwritable-destination tests flip modes; restore before removing.
trap 'chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"' EXIT

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

sandbox() {
  chmod -R u+w "$SB" 2>/dev/null || true
  rm -rf "${SB:?}"/*
  mkdir -p "$SB/bin" "$SB/log" "$SB/home/.agents/skills"
  export STUB_LOG_DIR="$SB/log"
  unset STUB_GIT_HOOKSPATH 2>/dev/null || true
}

mk_skill() { # <skills-dir> <name> [content]
  mkdir -p "$1/$2"
  printf '%s\n' "${3:-$2}" > "$1/$2/SKILL.md"
}

# git against the hook sandbox's repository, with the fake HOME so hook
# runs (which read $HOME/.agents/skills) and git config stay sandboxed.
g() { HOME="$SB/home" git -C "$SB/repo" "$@"; }

# Bare origin + work repository carrying the versioned machinery, core.hooksPath
# already activated, and a fake HOME with one skill.
hook_sandbox() {
  sandbox
  mk_skill "$SB/home/.agents/skills" alpha alpha-v1
  mkdir -p "$SB/repo/scripts"
  cp -a "$ROOT/.githooks" "$SB/repo/.githooks"
  cp "$SYNC" "$SB/repo/scripts/sync-skills.sh"
  printf 'required-skills/\n' > "$SB/repo/.gitignore"
  g init -q -b main
  g config user.email test@example.com
  g config user.name test
  g config core.hooksPath .githooks
  printf 'base\n' > "$SB/repo/base.txt"
  g add -A
  g commit -qm init
  HOME="$SB/home" git init -q --bare "$SB/origin.git"
  g remote add origin "$SB/origin.git"
}

# Two branches ready to merge (feature in, main moved on in parallel).
seed_merge() {
  g checkout -qb feature
  printf 'feat\n' > "$SB/repo/feat.txt"
  g add feat.txt
  g commit -qm feature
  g checkout -q main
  printf 'main2\n' > "$SB/repo/base2.txt"
  g add base2.txt
  g commit -qm main-advance
}

# install.sh copied into a sandbox repository with all machinery present;
# marker stubs make every dependency resolve (git is NOT shadowed: the
# activation must really read/write this sandbox repo's config).
install_sandbox() {
  sandbox
  mkdir -p "$SB/repo/scripts" "$SB/repo/.githooks"
  cp "$ROOT/install.sh" "$SB/repo/install.sh"
  cp "$ROOT/scripts/_sub-common.sh" "$ROOT/scripts/sync-skills.sh" \
     "$SB/repo/scripts/"
  cp "$ROOT/.githooks/pre-push" "$ROOT/.githooks/post-merge" "$SB/repo/.githooks/"
  git init -q "$SB/repo"
  mk_skill "$SB/req-skills" alpha install-v1
  local c
  for c in bash tmux jq gh realpath date readlink sha256sum tar mktemp \
           sed grep awk treehouse pi shellcheck; do
    printf '#!/bin/sh\nexit 0\n' > "$SB/bin/$c"
    chmod +x "$SB/bin/$c"
  done
}

run_installer() {
  ( cd "$SB/repo" && env \
      PATH="$SB/bin:$PATH" \
      HOME="$SB/home" \
      MU_SKILLS_SRC="$SB/req-skills" \
      MU_SKILLS_DST="$SB/agents-skills" \
      "$BASH_BIN" "$SB/repo/install.sh" ) >"$SB/out" 2>"$SB/err"
  status=$?
  cat "$SB/out" "$SB/err" > "$SB/all"
}

assert_contains() {
  grep -qF -- "$1" "$SB/all" || fail "output missing '$1'; output: $(tr '\n' '|' < "$SB/all")"
}

assert_not_contains() {
  if grep -qF -- "$1" "$SB/all"; then
    fail "output must not contain '$1'; output: $(tr '\n' '|' < "$SB/all")"
  fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# --- [REQ-1] a push mirrors ~/.agents/skills into required-skills ---------
t_req1_push_mirrors_home_skills() {
  hook_sandbox
  mk_skill "$SB/home/.agents/skills" beta beta-v1
  if ! g push -q origin main 2>"$SB/err"; then
    fail "push failed: $(tr '\n' '|' < "$SB/err")"
  fi
  grep -qF alpha-v1 "$SB/repo/required-skills/alpha/SKILL.md" \
    || fail "required-skills/alpha not synced by the push"
  grep -qF beta-v1 "$SB/repo/required-skills/beta/SKILL.md" \
    || fail "required-skills/beta not synced by the push"
}

# --- [REQ-2] a merge mirrors ~/.agents/skills into required-skills --------
t_req2_merge_mirrors_home_skills() {
  hook_sandbox
  seed_merge
  mkdir -p "$SB/repo/required-skills/alpha"
  printf 'stale-content\n' > "$SB/repo/required-skills/alpha/SKILL.md"
  if ! g merge --no-ff feature -m merge 2>"$SB/err"; then
    fail "merge failed: $(tr '\n' '|' < "$SB/err")"
  fi
  grep -qF alpha-v1 "$SB/repo/required-skills/alpha/SKILL.md" \
    || fail "post-merge did not refresh the stale required-skills copy"
}

# --- [REQ-3] sync replaces a stale destination skill -----------------------
t_req3_sync_replaces_stale_skill() {
  sandbox
  mk_skill "$SB/src" alpha current-content
  mkdir -p "$SB/dst/alpha"
  printf 'outdated-content\n' > "$SB/dst/alpha/SKILL.md"
  printf 'gone-in-source\n' > "$SB/dst/alpha/OLD.md"
  if ! bash "$SYNC" "$SB/src" "$SB/dst" 2>"$SB/err"; then
    fail "sync exited non-zero: $(tr '\n' '|' < "$SB/err")"
  fi
  grep -qF current-content "$SB/dst/alpha/SKILL.md" \
    || fail "stale SKILL.md survived the sync"
  [ ! -e "$SB/dst/alpha/OLD.md" ] \
    || fail "file the source dropped survived inside the skill"
}

# --- [REQ-4] sync removes destination skills the source no longer has ------
t_req4_sync_prunes_destination_only_skill() {
  sandbox
  mk_skill "$SB/src" alpha alpha-content
  mk_skill "$SB/dst" alpha alpha-stale
  mk_skill "$SB/dst" extra extra-content
  if ! bash "$SYNC" "$SB/src" "$SB/dst" 2>"$SB/err"; then
    fail "sync exited non-zero: $(tr '\n' '|' < "$SB/err")"
  fi
  grep -qF alpha-content "$SB/dst/alpha/SKILL.md" || fail "alpha not synced"
  [ ! -e "$SB/dst/extra" ] || fail "destination-only skill 'extra' not pruned"
}

# --- [REQ-5] missing/empty source leaves the destination unchanged ---------
t_req5_empty_source_preserves_destination() {
  sandbox
  mk_skill "$SB/dst" alpha keep-me
  mkdir -p "$SB/empty"
  if ! bash "$SYNC" "$SB/empty" "$SB/dst" 2>"$SB/err"; then
    fail "empty source must exit 0"
  fi
  grep -qF 'no skills in' "$SB/err" || fail "empty source must warn"
  grep -qF keep-me "$SB/dst/alpha/SKILL.md" || fail "destination was modified"
}

# --- [REQ-6] a failing sync never blocks push or merge ---------------------
t_req6_failing_sync_never_blocks_git() {
  # push
  hook_sandbox
  mkdir -p "$SB/repo/required-skills"
  chmod 555 "$SB/repo/required-skills"
  if ! g push -q origin main 2>"$SB/err"; then
    fail "push was blocked by a failing sync"
  fi
  grep -qF 'skills-sync: failed' "$SB/err" \
    || fail "sync failure not reported: $(tr '\n' '|' < "$SB/err")"
  [ -n "$(HOME="$SB/home" git --git-dir="$SB/origin.git" rev-parse --verify main 2>/dev/null)" ] \
    || fail "push did not reach the origin"
  chmod -R u+w "$SB/repo/required-skills"

  # merge
  hook_sandbox
  seed_merge
  mkdir -p "$SB/repo/required-skills"
  chmod 555 "$SB/repo/required-skills"
  if ! g merge --no-ff feature -m merge 2>"$SB/err"; then
    fail "merge was blocked by a failing sync"
  fi
  grep -qF 'skills-sync: failed' "$SB/err" \
    || fail "sync failure not reported: $(tr '\n' '|' < "$SB/err")"
  chmod -R u+w "$SB/repo/required-skills"
}

# --- [REQ-7] installer copies required-skills on every run -----------------
t_req7_installer_copies_required_skills() {
  install_sandbox
  run_installer
  [ "$status" -eq 0 ] || fail "installer exited $status: $(tr '\n' '|' < "$SB/all")"
  assert_contains "skills-sync: 1 skill(s) synced"
  grep -qF install-v1 "$SB/agents-skills/alpha/SKILL.md" \
    || fail ".agents/skills was not populated from required-skills"
}

# --- [REQ-8] skills failure warns, exit status unchanged -------------------
t_req8_skills_failure_warns_without_changing_status() {
  install_sandbox
  printf 'not a directory\n' > "$SB/agents-skills"   # mkdir -p must fail
  run_installer
  [ "$status" -eq 0 ] \
    || fail "exit status must stay 0 (dependencies present), got $status"
  assert_contains "required skills sync failed"
}

# --- [REQ-9] installer activates core.hooksPath when unset -----------------
t_req9_installer_activates_hooks_path() {
  install_sandbox
  run_installer
  [ "$status" -eq 0 ] || fail "installer exited $status"
  [ "$(git -C "$SB/repo" config core.hooksPath)" = .githooks ] \
    || fail "core.hooksPath was not set to .githooks"
  assert_contains "git hooks: core.hooksPath -> .githooks"
  # idempotent second run: no activation report, value untouched
  run_installer
  assert_not_contains "core.hooksPath -> .githooks"
  [ "$(git -C "$SB/repo" config core.hooksPath)" = .githooks ] \
    || fail "second run changed core.hooksPath"
}

# --- [REQ-10] foreign core.hooksPath never overwritten by the installer ----
t_req10_installer_preserves_foreign_hooks_path() {
  install_sandbox
  git -C "$SB/repo" config core.hooksPath custom-hooks
  run_installer
  [ "$status" -eq 0 ] || fail "installer exited $status"
  [ "$(git -C "$SB/repo" config core.hooksPath)" = custom-hooks ] \
    || fail "foreign core.hooksPath was overwritten"
  assert_contains "core.hooksPath is already 'custom-hooks'"
  assert_contains "git config core.hooksPath .githooks"
}

# --- supplementary ---------------------------------------------------------

t_sup_missing_source_path_is_noop() {
  sandbox
  mk_skill "$SB/dst" alpha keep-me
  if ! bash "$SYNC" "$SB/does-not-exist" "$SB/dst" 2>"$SB/err"; then
    fail "missing source must exit 0"
  fi
  grep -qF 'no skills in' "$SB/err" || fail "missing source must warn"
  grep -qF keep-me "$SB/dst/alpha/SKILL.md" || fail "destination was modified"
}

t_sup_activation_failure_warns_without_failing() {
  install_sandbox
  chmod -R a-w "$SB/repo/.git"          # git config cannot write its config
  run_installer
  [ "$status" -eq 0 ] \
    || fail "exit status must stay 0, got $status"
  assert_contains "could not set core.hooksPath"
  chmod -R u+w "$SB/repo/.git"
}

t_sup_usage_without_arguments() {
  sandbox
  bash "$SYNC" >"$SB/out" 2>"$SB/err"
  st=$?
  [ "$st" -eq 2 ] || fail "usage errors must exit 2, got $st"
  grep -qF 'usage: scripts/sync-skills.sh' "$SB/err" || fail "no usage message"
}

t_sup_shellcheck_touched_scripts() {
  bash -n "$SYNC" || fail "bash -n reported findings in sync-skills.sh"
  bash -n "$ROOT/.githooks/pre-push" || fail "bash -n reported findings in pre-push"
  bash -n "$ROOT/.githooks/post-merge" || fail "bash -n reported findings in post-merge"
  bash -n "$0" || fail "bash -n reported findings in this suite"
  if [ -n "$REAL_SHELLCHECK" ]; then
    "$REAL_SHELLCHECK" "$SYNC" "$ROOT/.githooks/pre-push" \
      "$ROOT/.githooks/post-merge" "$ROOT/install.sh" \
      "$ROOT/scripts/worktree-setup.sh" "$ROOT/tests/install.test.sh" \
      "$ROOT/tests/worktree-setup.test.sh" "$0" \
      || fail "shellcheck reported findings"
  else
    printf '  SKIP: shellcheck not on PATH\n' >&2
  fi
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

run "[REQ-1]  push mirrors ~/.agents/skills"            t_req1_push_mirrors_home_skills
run "[REQ-2]  merge mirrors ~/.agents/skills"           t_req2_merge_mirrors_home_skills
run "[REQ-3]  sync replaces a stale skill"              t_req3_sync_replaces_stale_skill
run "[REQ-4]  sync prunes destination-only skills"      t_req4_sync_prunes_destination_only_skill
run "[REQ-5]  empty source preserves destination"       t_req5_empty_source_preserves_destination
run "[REQ-6]  failing sync never blocks push/merge"     t_req6_failing_sync_never_blocks_git
run "[REQ-7]  installer copies required-skills"         t_req7_installer_copies_required_skills
run "[REQ-8]  skills failure warns, status unchanged"   t_req8_skills_failure_warns_without_changing_status
run "[REQ-9]  installer activates core.hooksPath"       t_req9_installer_activates_hooks_path
run "[REQ-10] foreign core.hooksPath preserved"         t_req10_installer_preserves_foreign_hooks_path
run "[supp]   missing source path is a no-op"           t_sup_missing_source_path_is_noop
run "[supp]   activation failure warns, status 0"       t_sup_activation_failure_warns_without_failing
run "[supp]   usage without arguments"                  t_sup_usage_without_arguments
run "[supp]   shellcheck + bash -n of touched scripts"  t_sup_shellcheck_touched_scripts

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
