#!/usr/bin/env bash
# Behavioural tests for install.sh — one assertion block per Gherkin scenario
# in specs/install-script/install-script.feature ([REQ-n] traceable).
#
# Hermetic: install.sh runs under `env -i` with a sandbox-only PATH (no real
# package manager, downloader, npm, or hook can touch the machine), a fake
# HOME, and stub installers (apt-get/dnf/pacman/brew/sudo/curl/wget/npm/
# tar/sha256sum) that log their argv and simulate installation by creating
# the corresponding sandbox commands. "A tool is present" means it resolves
# on the sandbox PATH; "missing" means there is no entry for it.
#
# Usage: bash tests/install.test.sh   (exit 0 = all green)
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL=$ROOT/install.sh
BASH_BIN=$(command -v bash)
REAL_SHA256SUM=$(command -v sha256sum || printf '/usr/bin/sha256sum')
# Resolved before any sandbox PATH rewriting; used by the lint test.
REAL_SHELLCHECK=$(command -v shellcheck || true)

# Pinned shellcheck version as declared by the shared installer (fallback
# while that pin does not exist, i.e. during RED).
PIN=$(awk -F= '/^SHELLCHECK_VERSION=/{print $2}' "$ROOT/scripts/worktree-setup.sh" 2>/dev/null || true)
PIN=${PIN:-0.10.0}

# Fixed payload the curl stub serves for the treehouse release tarball; its
# real sha256 is what the stub writes into checksums.txt.
TH_PAYLOAD='stub treehouse archive payload'
TH_SHA=$(printf '%s' "$TH_PAYLOAD" | "$REAL_SHA256SUM" | awk '{print $1}')

failures=0
fail() { printf '  ASSERT FAILED: %s\n' "$*" >&2; exit 1; }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

mk_marker() { # presence-only executable: behaviour never exercised
  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/$1"
  chmod +x "$SB/bin/$1"
}

write_stubs() {
  # Operational binaries install.sh and the delegated hook really need.
  local c p
  # sha256sum and tar are deliberately NOT symlinked here: their stubs are
  # written below, and a symlink would make `cat >` follow it to the real
  # (read-only) binary.
  for c in bash env dirname basename mkdir rm cp chmod ln mktemp uname cat \
           tr sed grep awk readlink; do
    p=$(command -v "$c") || fail "host is missing $c"
    ln -sf "$p" "$SB/bin/$c"
  done
  # Required tools whose behaviour no test exercises: present as markers.
  for c in git tmux realpath date; do mk_marker "$c"; done

  # sha256sum: plain mode delegates to the real tool (treehouse verification
  # is honestly checked); the hook's `sha256sum -c` mode cannot match its
  # pinned hash against the stub payload, so -c always "passes" — same
  # treatment tests/worktree-setup.test.sh applies.
  cat > "$SB/bin/sha256sum" <<'EOS'
#!/usr/bin/env bash
case " $* " in
  *" -c "*) exit 0 ;;
esac
exec "$STUB_REAL_SHA256SUM" "$@"
EOS

  cat > "$SB/bin/curl" <<'EOS'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG_DIR/curl.log"
[ "${STUB_CURL_FAIL:-0}" = 1 ] && exit 22
out= url= prev=
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out=$a; prev=; continue; fi
  case "$a" in -o) prev=-o ;; *) url=$a ;; esac
done
[ -n "$out" ] || exit 2
case "$url" in
  *kunchenguid/treehouse/releases/latest*)
    printf '{"tag_name": "v9.9.9", "assets": []}\n' > "$out" ;;
  *treehouse*/checksums.txt)
    for a in darwin-amd64 darwin-arm64 linux-amd64 linux-arm64; do
      printf '%s  treehouse-v9.9.9-%s.tar.gz\n' "${STUB_TH_BAD_SHA:-$STUB_TH_SHA}" "$a"
    done > "$out" ;;
  *treehouse-v9.9.9-*.tar.gz)
    printf '%s' "$STUB_TH_PAYLOAD" > "$out" ;;
  *shellcheck-v*.tar.xz)
    printf 'stub shellcheck archive\n' > "$out" ;;
  *) exit 22 ;;
esac
exit 0
EOS

  # tar dispatches on the archive name: treehouse releases unpack the
  # 'treehouse' binary at their root (verified against the real tarball);
  # for shellcheck releases the archive unpacks a shellcheck-v<pin>
  # directory like the hook expects.
  cat > "$SB/bin/tar" <<'EOS'
#!/usr/bin/env bash
printf 'tar %s\n' "$*" >> "$STUB_LOG_DIR/tar.log"
[ "${STUB_TAR_FAIL:-0}" = 1 ] && exit 2
dir= prev=
for a in "$@"; do
  if [ "$prev" = "-C" ]; then dir=$a; prev=; continue; fi
  case "$a" in -C) prev=-C ;; esac
done
[ -n "$dir" ] || exit 2
case "$*" in
  *treehouse*)
    printf '#!/usr/bin/env bash\necho treehouse stub\n' > "$dir/treehouse"
    chmod +x "$dir/treehouse" ;;
  *shellcheck*)
    mkdir -p "$dir/shellcheck-v$STUB_PIN"
    printf '#!/usr/bin/env bash\nprintf "ShellCheck - shell script analysis tool\\nversion: %s\\n"\n' "$STUB_PIN" \
      > "$dir/shellcheck-v$STUB_PIN/shellcheck"
    chmod +x "$dir/shellcheck-v$STUB_PIN/shellcheck" ;;
  *) exit 2 ;;
esac
exit 0
EOS

  chmod +x "$SB/bin/sha256sum" "$SB/bin/curl" "$SB/bin/tar"
}

write_pkg_stub() { # $1 = package manager name
  cat > "$SB/bin/$1" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$STUB_LOG_DIR/$1.log"
case " \$* " in
  *" install "*|*" -S "*) : ;;
  *) exit 0 ;;
esac
[ "\${STUB_PM_FAIL:-0}" = 1 ] && exit 10
mk() { printf '#!/usr/bin/env bash\necho %s stub\n' "\$1" > "\$STUB_BIN/\$1"; chmod +x "\$STUB_BIN/\$1"; }
for pkg in "\$@"; do
  case "\$pkg" in
    install|-y|-S|--noconfirm|--needed) ;;
    jq) mk jq ;;
    gh|github-cli) mk gh ;;
    git) mk git ;;
    tmux) mk tmux ;;
    gawk) mk awk ;;
    sed|grep|tar) mk "\$pkg" ;;
    coreutils) for c in realpath date readlink sha256sum mktemp; do mk "\$c"; done ;;
    *) : ;;
  esac
done
exit 0
EOS
  chmod +x "$SB/bin/$1"
}

write_sudo_stub() {
  cat > "$SB/bin/sudo" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG_DIR/sudo.log"
exec "$@"
EOS
  chmod +x "$SB/bin/sudo"
}

write_npm_stub() {
  cat > "$SB/bin/npm" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG_DIR/npm.log"
printf '%s\n' "$*" | grep -qF -- '@earendil-works/pi-coding-agent' || exit 3
printf '#!/usr/bin/env bash\necho pi stub\n' > "$STUB_BIN/pi"
chmod +x "$STUB_BIN/pi"
EOS
  chmod +x "$SB/bin/npm"
}

write_wget_stub() {
  cat > "$SB/bin/wget" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG_DIR/wget.log"
[ "${STUB_WGET_FAIL:-0}" = 1 ] && exit 4
out= url= prev=
for a in "$@"; do
  if [ "$prev" = "-O" ]; then out=$a; prev=; continue; fi
  case "$a" in -O) prev=-O ;; *) url=$a ;; esac
done
[ -n "$out" ] || exit 2
case "$url" in
  *kunchenguid/treehouse/releases/latest*)
    printf '{"tag_name": "v9.9.9", "assets": []}\n' > "$out" ;;
  *treehouse*/checksums.txt)
    for a in darwin-amd64 darwin-arm64 linux-amd64 linux-arm64; do
      printf '%s  treehouse-v9.9.9-%s.tar.gz\n' "${STUB_TH_BAD_SHA:-$STUB_TH_SHA}" "$a"
    done > "$out" ;;
  *treehouse-v9.9.9-*.tar.gz)
    printf '%s' "$STUB_TH_PAYLOAD" > "$out" ;;
  *) exit 4 ;;
esac
exit 0
EOS
  chmod +x "$SB/bin/wget"
}

sandbox() {
  rm -rf "${SB:?}"/*
  mkdir -p "$SB/bin" "$SB/home/.local/bin" "$SB/log" "$SB/work"
  # Hermetic source for install.sh's advisory skills step (MU_SKILLS_SRC):
  # the real checkout's required-skills/.agents/skills folders are never read
  # or written by this suite.
  mkdir -p "$SB/skills-src/test-skill"
  printf 'name: test-skill\n' > "$SB/skills-src/test-skill/SKILL.md"
  write_stubs
  export STUB_LOG_DIR="$SB/log"
  export STUB_BIN="$SB/bin"
  export STUB_PIN="$PIN"
  export STUB_TH_SHA="$TH_SHA"
  export STUB_TH_PAYLOAD="$TH_PAYLOAD"
  export STUB_REAL_SHA256SUM="$REAL_SHA256SUM"
  unset STUB_CURL_FAIL STUB_PM_FAIL STUB_TH_BAD_SHA STUB_TAR_FAIL \
        STUB_WGET_FAIL 2>/dev/null || true
  RUN_PATH="$SB/bin:$SB/home/.local/bin"
}

# ---------------------------------------------------------------------------
# Runner helpers
# ---------------------------------------------------------------------------

run_installer() {
  ( cd "$SB/work" && env -i \
      PATH="$RUN_PATH" \
      HOME="$SB/home" \
      MU_SKILLS_SRC="$SB/skills-src" \
      MU_SKILLS_DST="$SB/skills-dst" \
      STUB_LOG_DIR="$SB/log" \
      STUB_BIN="$SB/bin" \
      STUB_PIN="$STUB_PIN" \
      STUB_TH_SHA="$STUB_TH_SHA" \
      STUB_TH_PAYLOAD="$STUB_TH_PAYLOAD" \
      STUB_REAL_SHA256SUM="$STUB_REAL_SHA256SUM" \
      STUB_CURL_FAIL="${STUB_CURL_FAIL:-}" \
      STUB_PM_FAIL="${STUB_PM_FAIL:-}" \
      STUB_TH_BAD_SHA="${STUB_TH_BAD_SHA:-}" \
      STUB_TAR_FAIL="${STUB_TAR_FAIL:-}" \
      STUB_WGET_FAIL="${STUB_WGET_FAIL:-}" \
      "$BASH_BIN" "$INSTALL" ) >"$SB/out" 2>"$SB/err"
  status=$?
  cat "$SB/out" "$SB/err" > "$SB/all"
}

assert_status() {
  [ "${status:-}" = "$1" ] \
    || fail "expected exit status $1, got '${status:-unset}'; output: $(tr '\n' '|' < "$SB/all")"
}

assert_contains() {
  grep -qF -- "$1" "$SB/all" || fail "output missing '$1'; output: $(tr '\n' '|' < "$SB/all")"
}

assert_not_contains() {
  if grep -qF -- "$1" "$SB/all"; then
    fail "output must not contain '$1'; output: $(tr '\n' '|' < "$SB/all")"
  fi
}

assert_log_empty() { # $1 = log file name
  [ ! -s "$SB/log/$1" ] || fail "$1 was invoked: $(tr '\n' '|' < "$SB/log/$1")"
}

assert_log_line() { # $1 = log file name, $2 = exact line
  [ -f "$SB/log/$1" ] || fail "no $1 log"
  local n
  n=$(grep -cxF -- "$2" "$SB/log/$1") \
    || fail "$1 missing exact line '$2': $(tr '\n' '|' < "$SB/log/$1")"
  [ "$n" = 1 ] || fail "$1 has '$2' $n times, expected exactly once"
}

# Expected treehouse release asset for this host (same mapping install.sh
# derives from uname).
expected_th_asset() {
  local os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) os=linux ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; *) arch=arm64 ;; esac
  printf 'treehouse-v9.9.9-%s-%s.tar.gz' "$os" "$arch"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# --- [REQ-1] no-op when every dependency is present ------------------------
t_req1_noop_when_all_present() {
  sandbox
  local c
  for c in jq gh treehouse pi shellcheck; do mk_marker "$c"; done
  write_pkg_stub apt-get
  write_npm_stub
  run_installer
  assert_status 0
  assert_contains "already present (17):"
  assert_contains "nothing to install"
  assert_log_empty apt-get.log
  assert_log_empty curl.log
  assert_log_empty npm.log
  assert_not_contains "[worktree-setup]"
}

# --- [REQ-2] one package-manager run, only missing packages ----------------
t_req2_system_install_via_detected_pm() {
  # apt-get (with sudo, as a non-root user)
  sandbox
  write_pkg_stub apt-get
  write_sudo_stub
  local c; for c in treehouse pi shellcheck; do mk_marker "$c"; done
  run_installer
  assert_status 0
  assert_log_line apt-get.log "install -y jq gh"
  assert_log_line sudo.log "apt-get install -y jq gh"
  assert_contains "installed (2): jq gh"

  # dnf: same package names
  sandbox
  write_pkg_stub dnf
  write_sudo_stub
  for c in treehouse pi shellcheck; do mk_marker "$c"; done
  run_installer
  assert_status 0
  assert_log_line dnf.log "install -y jq gh"
  assert_log_line sudo.log "dnf install -y jq gh"
  assert_contains "installed (2): jq gh"

  # pacman: gh is packaged as github-cli, no sudo line naming apt
  sandbox
  write_pkg_stub pacman
  write_sudo_stub
  for c in treehouse pi shellcheck; do mk_marker "$c"; done
  run_installer
  assert_status 0
  assert_log_line pacman.log "-S --noconfirm --needed jq github-cli"
  assert_log_line sudo.log "pacman -S --noconfirm --needed jq github-cli"
  assert_contains "installed (2): jq gh"

  # Homebrew: never sudo, brew's own flags
  sandbox
  write_pkg_stub brew
  write_sudo_stub
  for c in treehouse pi shellcheck; do mk_marker "$c"; done
  run_installer
  assert_status 0
  assert_log_line brew.log "install jq gh"
  [ ! -f "$SB/log/sudo.log" ] || fail "brew install must not be prefixed with sudo"
  assert_contains "installed (2): jq gh"
}

# --- [REQ-3] manual hints without a package manager, keep going ------------
t_req3_manual_hints_without_pm() {
  sandbox
  local c
  for c in treehouse shellcheck; do mk_marker "$c"; done
  write_npm_stub            # pi can still install: proof of continuation
  run_installer
  assert_status 1
  assert_contains "jq: no supported package manager"
  assert_contains "gh: no supported package manager"
  assert_contains "installed (1): pi"
  assert_contains "needs manual action (2):"
}

# --- [REQ-4] treehouse from its GitHub release -----------------------------
t_req4_treehouse_from_github_release() {
  sandbox
  local c
  for c in jq gh pi shellcheck; do mk_marker "$c"; done
  run_installer
  assert_status 0
  assert_contains "installed (1): treehouse"
  grep -qF -- "api.github.com/repos/kunchenguid/treehouse/releases/latest" \
    "$SB/log/curl.log" || fail "latest release was not queried"
  grep -qF -- "$(expected_th_asset)" "$SB/log/curl.log" \
    || fail "platform tarball $(expected_th_asset) was not downloaded"
  grep -qF -- "checksums.txt" "$SB/log/curl.log" \
    || fail "checksums.txt was not downloaded"
  [ -x "$SB/home/.local/bin/treehouse" ] \
    || fail "no executable treehouse installed into fake HOME/.local/bin"
  assert_not_contains "checksum mismatch"
}

# --- [REQ-5] never overwrite an existing tool at its install path ----------
t_req5_never_overwrite_existing() {
  sandbox
  local c
  for c in jq gh pi shellcheck; do mk_marker "$c"; done
  printf '#!/bin/sh\necho existing marker\n' > "$SB/home/.local/bin/treehouse"
  chmod +x "$SB/home/.local/bin/treehouse"
  RUN_PATH="$SB/bin"        # the file exists but is deliberately off PATH
  local before
  before=$(cat "$SB/home/.local/bin/treehouse")
  run_installer
  assert_status 1
  [ "$(cat "$SB/home/.local/bin/treehouse")" = "$before" ] \
    || fail "existing treehouse file was modified"
  assert_log_empty curl.log
  assert_contains "add ~/.local/bin"
  assert_contains "needs manual action (1):"
}

# --- [REQ-6] pi through the verified npm global command --------------------
t_req6_pi_via_npm() {
  sandbox
  local c
  for c in jq gh treehouse shellcheck; do mk_marker "$c"; done
  write_npm_stub
  run_installer
  assert_status 0
  assert_log_line npm.log "install -g --ignore-scripts @earendil-works/pi-coding-agent"
  assert_contains "installed (1): pi"
  [ -x "$SB/bin/pi" ] || fail "npm stub did not produce pi on PATH"
}

# --- [REQ-7] pi instructions when Node/npm is missing ----------------------
t_req7_pi_instructions_without_npm() {
  sandbox
  local c
  for c in jq gh treehouse; do mk_marker "$c"; done
  # The shellcheck tool stays missing: the delegated hook runs afterwards,
  # proving the installer continues with the remaining categories.
  run_installer
  assert_status 1
  assert_contains "Node.js 22.19"
  assert_contains "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
  assert_contains "pi.dev/install.sh"
  grep -qE '^    pi: ' "$SB/all" || fail "pi not reported under needs manual action"
  assert_contains "installed (1): shellcheck"
}

# --- [REQ-8] shellcheck via the shared pinned install ----------------------
t_req8_shellcheck_via_shared_hook() {
  sandbox
  local c
  for c in jq gh treehouse pi; do mk_marker "$c"; done
  run_installer
  assert_status 0
  assert_contains "[worktree-setup]"
  assert_contains "provisioned $PIN"
  assert_contains "installed (1): shellcheck"
  [ -x "$SB/home/.local/bin/shellcheck" ] \
    || fail "the shared hook did not provision shellcheck into the fake HOME"
  # single source of truth: the installer declares no pin of its own
  if grep -q 'SHELLCHECK_VERSION' "$INSTALL"; then
    fail "install.sh declares SHELLCHECK_VERSION — the pin lives in worktree-setup.sh"
  fi
}

# --- [REQ-9] summary + idempotent second run -------------------------------
t_req9_summary_and_idempotent_rerun() {
  sandbox
  write_pkg_stub apt-get
  write_sudo_stub
  local c; for c in treehouse pi shellcheck; do mk_marker "$c"; done
  run_installer
  assert_status 0
  assert_contains "Summary:"
  assert_contains "already present (15):"
  assert_contains "installed (2): jq gh"
  assert_contains "needs manual action (0):"
  run_installer                # second run: everything now resolves
  assert_status 0
  assert_contains "already present (17):"
  assert_contains "nothing to install"
  assert_log_line apt-get.log "install -y jq gh"   # still exactly one call
}

# --- [REQ-10] exit status reflects the final state -------------------------
t_req10_exit_status() {
  sandbox
  local c
  for c in jq gh treehouse pi shellcheck; do mk_marker "$c"; done
  run_installer
  assert_status 0
  sandbox                      # a missing dependency with no installer path
  for c in treehouse pi shellcheck; do mk_marker "$c"; done
  run_installer
  assert_status 1
}

# --- supplementary ----------------------------------------------------------

t_sup_pm_failure_reports_and_continues() {
  sandbox
  write_pkg_stub apt-get
  write_sudo_stub
  write_npm_stub
  local c; for c in treehouse shellcheck; do mk_marker "$c"; done
  export STUB_PM_FAIL=1
  run_installer
  assert_status 1
  assert_contains "jq: "
  assert_contains "gh: "
  assert_contains "install failed"
  assert_contains "installed (1): pi"     # other categories still ran
}

t_sup_treehouse_checksum_mismatch_rejected() {
  sandbox
  local c
  for c in jq gh pi shellcheck; do mk_marker "$c"; done
  STUB_TH_BAD_SHA=$(printf '%064d' 0)
  export STUB_TH_BAD_SHA
  run_installer
  assert_status 1
  assert_contains "checksum mismatch"
  [ ! -e "$SB/home/.local/bin/treehouse" ] \
    || fail "treehouse was installed despite a checksum mismatch"
}

t_sup_treehouse_wget_fallback() {
  sandbox
  local c
  for c in jq gh pi shellcheck; do mk_marker "$c"; done
  rm -f "$SB/bin/curl"
  write_wget_stub
  run_installer
  assert_status 0
  assert_contains "installed (1): treehouse"
  [ -f "$SB/log/wget.log" ] || fail "wget was not used as the downloader"
}

t_sup_no_sudo_hint() {
  if [ "$EUID" -eq 0 ]; then
    printf '  SKIP: running as root, sudo policy is not exercised\n' >&2
    return 0
  fi
  sandbox
  write_pkg_stub apt-get       # no sudo stub on PATH
  run_installer
  assert_status 1
  assert_contains "not root and sudo not found"
  assert_log_empty apt-get.log
}

t_sup_shellcheck_lint() {
  bash -n "$INSTALL" || fail "bash -n reported findings in install.sh"
  bash -n "$0" || fail "bash -n reported findings in this suite"
  if [ -n "$REAL_SHELLCHECK" ]; then
    "$REAL_SHELLCHECK" "$INSTALL" "$0" || fail "shellcheck reported findings"
  else
    printf '  SKIP: shellcheck not on PATH\n' >&2
  fi
}

# ---------------------------------------------------------------------------
# Harness
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

[ -f "$INSTALL" ] || printf 'NOTE: install.sh does not exist yet (RED phase)\n' >&2

run "[REQ-1]  no-op when every dependency is present"        t_req1_noop_when_all_present
run "[REQ-2]  one package-manager run, only missing pkgs"    t_req2_system_install_via_detected_pm
run "[REQ-3]  manual hints without a package manager"        t_req3_manual_hints_without_pm
run "[REQ-4]  treehouse from its GitHub release"             t_req4_treehouse_from_github_release
run "[REQ-5]  never overwrite an existing tool"              t_req5_never_overwrite_existing
run "[REQ-6]  pi through the verified npm command"           t_req6_pi_via_npm
run "[REQ-7]  pi instructions without Node/npm"              t_req7_pi_instructions_without_npm
run "[REQ-8]  shellcheck via the shared pinned install"      t_req8_shellcheck_via_shared_hook
run "[REQ-9]  summary + idempotent second run"               t_req9_summary_and_idempotent_rerun
run "[REQ-10] exit status reflects final state"              t_req10_exit_status
run "[supp]   pm failure reported, other categories run"     t_sup_pm_failure_reports_and_continues
run "[supp]   treehouse checksum mismatch rejected"          t_sup_treehouse_checksum_mismatch_rejected
run "[supp]   wget fallback when curl is absent"             t_sup_treehouse_wget_fallback
run "[supp]   no sudo -> hint, no package-manager run"       t_sup_no_sudo_hint
run "[supp]   shellcheck + bash -n of installer and suite"   t_sup_shellcheck_lint

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'
