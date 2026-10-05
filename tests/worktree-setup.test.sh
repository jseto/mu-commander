#!/usr/bin/env bash
# Behavioural tests for scripts/worktree-setup.sh: shellcheck provisioning
# (one test per Scenario in specs/shellcheck-in-repo/shellcheck-in-repo.feature)
# and the git-hooks activation ([REQ-11]/[REQ-12] in
# specs/skills-sync-hook/skills-sync-hook.feature), plus supplementary checks
# (checksum rejection, PATH note, lint).
#
# Each test sandboxes a fake HOME/XDG_DATA_HOME, a scratch worktree cwd, and
# stub curl/tar/sha256sum/wget/go/git binaries placed first on PATH — no
# network, no real tarballs, no real tmux/treehouse pool; this machine's
# real shellcheck tool is never executed or modified by these stubs.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$ROOT/scripts/worktree-setup.sh"
ORIG_PATH=$PATH
# Resolved before any sandbox PATH rewriting; used by the lint test.
REAL_SHELLCHECK=$(command -v shellcheck || true)
REAL_SHA256SUM=$(command -v sha256sum || printf '/usr/bin/sha256sum')

# Pinned version as declared by the setup script itself (falls back to the
# current default while the pin does not exist yet, i.e. during RED).
PIN=$(awk -F= '/^SHELLCHECK_VERSION=/{print $2}' "$SETUP" 2>/dev/null || true)
PIN=${PIN:-0.10.0}

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

SLOT="$SB/home/.local/bin/shellcheck"
MANAGED="$SB/home/.local/share/mu-commander/shellcheck"

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

write_stubs() {
  cat > "$SB/bin/curl" <<'EOS'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG_DIR/curl.log"
[ "${STUB_CURL_FAIL:-0}" = 1 ] && exit 22
out= prev=
for a in "$@"; do
  [ "$prev" = "-o" ] && out=$a
  prev=$a
done
[ -n "$out" ] || exit 2
printf 'stub shellcheck archive\n' > "$out"
exit 0
EOS

  # wget is only a network guard: it must never actually run in tests.
  cat > "$SB/bin/wget" <<'EOS'
#!/usr/bin/env bash
printf 'wget %s\n' "$*" >> "$STUB_LOG_DIR/wget.log"
exit 4
EOS

  cat > "$SB/bin/tar" <<'STUB'
#!/usr/bin/env bash
# Expected invocation: tar -xJf <archive> -C <dir>
[ "${STUB_TAR_FAIL:-0}" = 1 ] && exit 2
dir= prev=
for a in "$@"; do
  [ "$prev" = "-C" ] && dir=$a
  prev=$a
done
[ -n "$dir" ] || exit 2
target="$dir/shellcheck-v$STUB_PIN/shellcheck"
mkdir -p "$(dirname "$target")"
cat > "$target" <<EOS
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: $STUB_PIN\n'
EOS
chmod +x "$target"
exit 0
STUB

  cat > "$SB/bin/sha256sum" <<EOS
#!/usr/bin/env bash
case " \$* " in
  *" -c "*)
    [ "\${STUB_SHA256_FAIL:-0}" = 1 ] && exit 1
    exit 0
    ;;
esac
exec "$REAL_SHA256SUM" "\$@"
EOS

  cat > "$SB/bin/go" <<'EOS'
#!/usr/bin/env bash
printf 'go %s\n' "$*" >> "$STUB_LOG_DIR/go.log"
exit 0
EOS

  # git: logs every invocation; `git config core.hooksPath` (read) returns
  # STUB_GIT_HOOKSPATH (empty = unset), a write is only logged.
  cat > "$SB/bin/git" <<'EOS'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$STUB_LOG_DIR/git.log"
if [ "${1:-}" = config ] && [ "${2:-}" = core.hooksPath ] && [ -z "${3:-}" ]; then
  printf '%s' "${STUB_GIT_HOOKSPATH:-}"
fi
exit 0
EOS

  chmod +x "$SB/bin/curl" "$SB/bin/wget" "$SB/bin/tar" "$SB/bin/sha256sum" "$SB/bin/go" "$SB/bin/git"
}

sandbox() {
  rm -rf "${SB:?}"/*
  mkdir -p "$SB/home/.local/bin" "$SB/bin" "$SB/stray" "$SB/wt" "$SB/log"
  write_stubs
  export HOME="$SB/home"
  export XDG_DATA_HOME="$SB/home/.local/share"
  export STUB_LOG_DIR="$SB/log"
  export STUB_PIN="$PIN"
  unset STUB_CURL_FAIL STUB_SHA256_FAIL STUB_TAR_FAIL STUB_GIT_HOOKSPATH 2>/dev/null || true
  # Managed slot dir first, then stubs, then the stray dir, then the real
  # PATH (which may contain this machine's shellcheck - always shadowed).
  export PATH="$SB/home/.local/bin:$SB/bin:$SB/stray:$ORIG_PATH"
}

make_fake_shellcheck() { # <path> <version>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOS
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: $2\n'
EOS
  chmod +x "$1"
}

run_setup() {
  ( cd "$SB/wt" && exec "$SETUP" ) >"$SB/out" 2>"$SB/err"
  status=$?
  cat "$SB/out" "$SB/err" > "$SB/all"
}

curl_calls() {
  if [ -f "$SB/log/curl.log" ]; then
    wc -l < "$SB/log/curl.log" | tr -d ' '
  else
    printf '0'
  fi
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_status() {
  [ "${status:-}" = "$1" ] \
    || fail "expected exit status $1, got '${status:-unset}'; output: $(tr '\n' '|' < "$SB/all")"
}

assert_contains() {
  grep -qF -- "$1" "$SB/all" || fail "output missing '$1'; output: $(tr '\n' '|' < "$SB/all")"
}

assert_slot_version() {
  local got
  [ -e "$SLOT" ] || fail "no shellcheck at $SLOT"
  got=$("$SLOT" --version 2>/dev/null | awk '/^version:/{print $2; exit}')
  [ "$got" = "$1" ] || fail "slot reports version '$got', expected '$1'"
}

assert_unchanged() { # <file> <content>
  local now
  now=$(cat "$1" 2>/dev/null || true)
  [ "$now" = "$2" ] || fail "$1 was modified by setup"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

t_req1_provisions_when_missing() {
  sandbox
  run_setup
  assert_status 0
  [ -x "$SLOT" ] || fail "no executable at $SLOT"
  local resolved
  resolved=$(command -v shellcheck || true)
  [ "$resolved" = "$SLOT" ] || fail "command -v shellcheck -> '$resolved', expected '$SLOT'"
  assert_slot_version "$PIN"
  assert_contains "shellcheck: provisioned $PIN"
}

t_req2_skips_when_pinned_version_present() {
  sandbox
  run_setup                 # first run provisions
  assert_status 0
  local before after
  before=$(curl_calls)
  run_setup                 # second run must not download
  assert_status 0
  after=$(curl_calls)
  [ "$after" = "$before" ] || fail "second run downloaded again ($before -> $after)"
  assert_contains "shellcheck: already installed at"

  # Same behaviour for a foreign shellcheck of the pinned version at the slot.
  rm -f "$SLOT"
  make_fake_shellcheck "$SLOT" "$PIN"
  printf '# foreign marker\n' >> "$SLOT"
  local foreign
  foreign=$(cat "$SLOT")
  : > "$SB/log/curl.log"
  run_setup
  assert_status 0
  [ "$(curl_calls)" = 0 ] || fail "foreign pinned shellcheck was re-downloaded over"
  assert_unchanged "$SLOT" "$foreign"
  assert_contains "shellcheck: already installed at"
}

t_req3_warns_instead_of_overwriting_foreign_version() {
  sandbox
  make_fake_shellcheck "$SLOT" "0.9.0"
  printf '# foreign marker\n' >> "$SLOT"
  local foreign
  foreign=$(cat "$SLOT")
  run_setup
  assert_status 0
  assert_unchanged "$SLOT" "$foreign"
  [ "$(curl_calls)" = 0 ] || fail "download performed over a foreign shellcheck"
  assert_contains "leaving it in place"
}

t_req4_refreshes_managed_install_on_pin_change() {
  sandbox
  make_fake_shellcheck "$MANAGED/v0.9.0/shellcheck" "0.9.0"
  ln -s "$MANAGED/v0.9.0/shellcheck" "$SLOT"
  run_setup
  assert_status 0
  assert_slot_version "$PIN"
  case "$(readlink "$SLOT")" in
    "$MANAGED/v$PIN/shellcheck") : ;;
    *) fail "slot links to $(readlink "$SLOT"), expected managed v$PIN" ;;
  esac
  assert_contains "shellcheck: refreshing managed install"
}

t_req5_failure_reported_without_aborting_setup() {
  sandbox
  touch "$SB/wt/go.mod"     # a later setup step must still run
  export STUB_CURL_FAIL=1
  run_setup
  assert_status 1
  assert_contains "FAILED: shellcheck download"
  [ ! -e "$SLOT" ] || fail "shellcheck installed despite failed download"
  [ -f "$SB/log/go.log" ] || fail "later setup step (go mod download) did not run"
}

t_req6_resolves_repo_provided_shellcheck_on_path() {
  sandbox
  make_fake_shellcheck "$SB/stray/shellcheck" "$PIN"   # stray sits later on PATH
  run_setup
  assert_status 0
  local resolved
  resolved=$(command -v shellcheck || true)
  [ "$resolved" = "$SLOT" ] || fail "command -v shellcheck -> '$resolved', expected '$SLOT'"
  assert_slot_version "$PIN"
}

t_req7_stray_shellcheck_outside_slot_untouched() {
  sandbox
  make_fake_shellcheck "$SB/stray/shellcheck" "0.8.0"
  printf '# stray marker\n' >> "$SB/stray/shellcheck"
  local stray
  stray=$(cat "$SB/stray/shellcheck")
  run_setup
  assert_status 0
  assert_unchanged "$SB/stray/shellcheck" "$stray"
  assert_slot_version "$PIN"       # repo copy provisioned alongside the stray
}

# --- [REQ-11] activate .githooks when core.hooksPath is unset --------------
t_req11_activates_githooks_when_unset() {
  sandbox
  mkdir -p "$SB/wt/.githooks"
  : > "$SB/wt/.githooks/pre-push"
  run_setup
  assert_status 0
  assert_contains "git hooks: core.hooksPath -> .githooks"
  grep -qxF 'git config core.hooksPath .githooks' "$SB/log/git.log" \
    || fail "core.hooksPath was not written: $(tr '\n' '|' < "$SB/log/git.log" 2>/dev/null)"
}

# --- [REQ-12] skip a repository without .githooks --------------------------
t_req12_skips_repository_without_githooks() {
  sandbox                    # scratch worktree carries no .githooks/
  run_setup
  assert_status 0
  [ ! -f "$SB/log/git.log" ] \
    || fail "git was invoked although .githooks is absent: $(tr '\n' '|' < "$SB/log/git.log")"
}

t_sup_checksum_mismatch_rejected() {
  sandbox
  export STUB_SHA256_FAIL=1
  run_setup
  assert_status 1
  assert_contains "FAILED: shellcheck checksum mismatch"
  [ ! -e "$SLOT" ] || fail "shellcheck installed despite checksum failure"
}

t_sup_path_note_when_shadowed() {
  sandbox
  make_fake_shellcheck "$SB/stray/shellcheck" "0.9.0"
  export PATH="$SB/stray:$PATH"     # stray now resolves before the slot
  run_setup
  assert_status 0
  assert_contains "PATH resolves shellcheck"
}

t_sup_foreign_hooks_path_left_alone() {
  sandbox
  mkdir -p "$SB/wt/.githooks"
  : > "$SB/wt/.githooks/pre-push"
  export STUB_GIT_HOOKSPATH=custom-hooks
  run_setup
  assert_status 0
  assert_contains "core.hooksPath is 'custom-hooks' - leaving it alone"
  if grep -qxF 'git config core.hooksPath .githooks' "$SB/log/git.log"; then
    fail "foreign core.hooksPath was overwritten"
  fi
}

t_sup_shellcheck_touched_scripts() {
  if [ -z "$REAL_SHELLCHECK" ]; then
    printf '  SKIP: shellcheck not on PATH\n' >&2
    return 0
  fi
  "$REAL_SHELLCHECK" "$SETUP" "$ROOT/tests/worktree-setup.test.sh" \
    || fail "shellcheck reported findings"
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

run "[REQ-1] provision pinned shellcheck when missing"        t_req1_provisions_when_missing
run "[REQ-2] skip when pinned shellcheck already present"     t_req2_skips_when_pinned_version_present
run "[REQ-3] warn instead of overwriting foreign version"     t_req3_warns_instead_of_overwriting_foreign_version
run "[REQ-4] refresh managed install on pin change"           t_req4_refreshes_managed_install_on_pin_change
run "[REQ-5] failure reported without aborting setup"         t_req5_failure_reported_without_aborting_setup
run "[REQ-6] resolve repo-provided shellcheck on PATH"        t_req6_resolves_repo_provided_shellcheck_on_path
run "[REQ-7] stray shellcheck outside slot untouched"         t_req7_stray_shellcheck_outside_slot_untouched
run "[REQ-11] activate .githooks when hooksPath unset"        t_req11_activates_githooks_when_unset
run "[REQ-12] skip repositories without .githooks"            t_req12_skips_repository_without_githooks
run "[supp] checksum mismatch rejected"                       t_sup_checksum_mismatch_rejected
run "[supp] PATH note when shadowed"                          t_sup_path_note_when_shadowed
run "[supp] foreign core.hooksPath left alone"                t_sup_foreign_hooks_path_left_alone
run "[supp] shellcheck lint of touched scripts"               t_sup_shellcheck_touched_scripts

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
