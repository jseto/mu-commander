#!/usr/bin/env bash
# mu-commander dependency installer.
#
# Detects which of the tools README.md documents (Installation -> 2.
# Dependencies) resolve on PATH and installs only the ones that are missing:
#
#   - system tools (bash, git, tmux, jq, gh, coreutils pieces, sed, grep,
#     awk, tar) through the first package manager on PATH: apt-get, dnf,
#     pacman, or Homebrew — prefixed with sudo only when the effective user
#     is not root and sudo is available (never for brew);
#   - treehouse from its official GitHub release (latest tag, sha256-checked
#     against the release's checksums.txt) into ~/.local/bin;
#   - pi through the npm command pi's own README documents;
#   - shellcheck by delegating to scripts/worktree-setup.sh, the single
#     pinned source of truth for that dependency — this script deliberately
#     declares no shellcheck version or checksum of its own;
#   - the repository's own `mu` launcher (README.md, Installation -> 4.
#     Put the `mu` launcher on PATH) as the symlink ~/.local/bin/mu ->
#     the checkout's mu file (main checkout preferred — pooled worktrees
#     are ephemeral) — nothing is downloaded for it.
#
# Besides dependencies, every run also mirrors the required skills
# (required-skills/ -> .agents/skills/ through scripts/sync-skills.sh) and
# activates the repository's versioned git hooks (core.hooksPath ->
# .githooks, set only when unset, never over a foreign value). Both are
# advisory: they report problems as warnings and never change the exit
# status, which stays tied to PATH dependencies only (specs/skills-sync-hook).
#
# Idempotent and non-destructive: an existing tool is never overwritten,
# every skip is a visible per-tool manual hint, the run ends with a summary
# (installed / already present / needs manual action), and the exit status
# is 0 only when every required dependency resolves on PATH at the end.
#
# Usage: ./install.sh [-h|--help]
set -uo pipefail

# This script's own directory anchors the repository root; pure parameter
# expansion, no external dirname (must work under a restricted PATH).
_INSTALL_DIR=${BASH_SOURCE[0]%/*}
if [ -z "$_INSTALL_DIR" ] || [ "$_INSTALL_DIR" = "${BASH_SOURCE[0]}" ]; then
  _INSTALL_DIR=.
fi
REPO_ROOT=$(cd "$_INSTALL_DIR" 2>/dev/null && pwd) || {
  printf 'ERROR: cannot resolve the repository root\n' >&2
  exit 1
}

# Reuse the shared conventions of the sub-* suite (info/warn/die and the
# need-style `command -v` detection). Detection is collected per tool by
# have() instead of need()'s die-on-first-miss, because the installer's
# contract is "report everything, then summarize".
# shellcheck source=scripts/_sub-common.sh
if [ ! -f "$REPO_ROOT/scripts/_sub-common.sh" ]; then
  printf 'ERROR: missing scripts/_sub-common.sh next to install.sh\n' >&2
  exit 1
fi
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$REPO_ROOT/scripts/_sub-common.sh"

usage() {
  printf '%s\n' \
    "usage: ./install.sh [-h|--help]" \
    "" \
    "Installs the missing mu-commander dependencies (README.md, Installation" \
    "-> 2. Dependencies) and links the mu launcher onto PATH (-> 4). Safe to" \
    "re-run; never overwrites an existing tool; exits 0 only when every" \
    "dependency is present."
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; die "unexpected argument: $1" ;;
esac

# --- dependency inventory ---------------------------------------------------

# System tools, installed via the platform's package manager (order matters:
# this is the summary order too). The four coreutils-set entries and the
# rest map to package names through pkg_for.
SYSTEM_TOOLS="bash git tmux jq gh realpath date readlink sha256sum tar mktemp sed grep awk"
# Tools that are not in distro repos (or are provisioned by the repo):
# dedicated install paths below. `mu` is this repository's own launcher —
# its "install" is the PATH symlink of README.md, Installation -> 4.
CUSTOM_TOOLS="treehouse pi shellcheck mu"
ALL_TOOLS="$SYSTEM_TOOLS $CUSTOM_TOOLS"

# need-style detection, collect-mode: true when the command resolves on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

count_words() { # $1 = space-separated list
  local _ n=0
  for _ in $1; do n=$((n + 1)); done
  printf '%s' "$n"
}

# --- outcome buckets --------------------------------------------------------

PRESENT=""    # space list: already on PATH when the run started
INSTALLED=""  # space list: installed by this run and re-verified on PATH
MANUAL=""     # newline list of ready-to-print "    tool: hint" lines
MANUAL_N=0

state_of() { # $1=tool -> present|installed|manual
  case " $PRESENT "   in *" $1 "*) printf 'present';   return 0 ;; esac
  case " $INSTALLED " in *" $1 "*) printf 'installed'; return 0 ;; esac
  printf 'manual'
}

installed_add() { INSTALLED="${INSTALLED}${INSTALLED:+ }$1"; }

manual_add() { # $1=tool $2=hint
  MANUAL="${MANUAL:+$MANUAL$'\n'}    $1: $2"
  MANUAL_N=$((MANUAL_N + 1))
}

# Temporary directories, removed when the installer exits.
TMP_DIRS=()
register_tmp() { TMP_DIRS+=("$1"); }
# Invoked only through the EXIT trap, which shellcheck cannot follow.
# shellcheck disable=SC2317
cleanup_tmp() {
  local d
  for d in ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}; do
    rm -rf "$d"
  done
}
trap cleanup_tmp EXIT

# --- system packages --------------------------------------------------------

# Supported package managers, first match wins (Linuxbrew loses to a distro
# manager on purpose). Single list: pm_detect and pkg_for stay in sync.
PM_LIST="apt-get dnf pacman brew"

# First supported package manager on PATH.
pm_detect() {
  local pm
  for pm in $PM_LIST; do
    if have "$pm"; then printf '%s' "$pm"; return 0; fi
  done
  return 1
}

# Echo the package name of a tool for a package manager, or fail when this
# platform has no known package for it (the caller then prints a manual
# hint instead of guessing).
pkg_for() { # $1=tool $2=pm
  case " $PM_LIST " in *" $2 "*) : ;; *) return 1 ;; esac
  case "$1" in
    bash|git|tmux|jq) printf '%s' "$1" ;;
    gh) if [ "$2" = pacman ]; then printf 'github-cli'; else printf 'gh'; fi ;;
    awk) printf 'gawk' ;;
    sed|grep|tar)
      # macOS ships its own BSD sed/grep/tar; brew has no unprefixed formula
      # for them, so a missing one is a manual hint, never a wrong install.
      if [ "$2" = brew ]; then return 1; fi
      printf '%s' "$1" ;;
    date|readlink|realpath|sha256sum|mktemp) printf 'coreutils' ;;
    *) return 1 ;;
  esac
}

install_system() {
  local t pm need_root pkg
  local missing=() pkgs=() pkg_tools=()
  for t in $SYSTEM_TOOLS; do
    case " $PRESENT " in *" $t "*) : ;; *) missing+=("$t") ;; esac
  done
  [ "${#missing[@]}" -gt 0 ] || return 0

  pm=$(pm_detect) || pm=""
  if [ -z "$pm" ]; then
    for t in "${missing[@]}"; do
      manual_add "$t" "no supported package manager (apt/dnf/pacman/brew) — install '$t' with your platform's package manager"
    done
    return 0
  fi

  for t in "${missing[@]}"; do
    pkg=$(pkg_for "$t" "$pm") || pkg=""
    if [ -z "$pkg" ]; then
      manual_add "$t" "no known package for '$t' in $pm — install it by hand"
      continue
    fi
    case " ${pkgs[*]-} " in
      *" $pkg "*) : ;;
      *) pkgs+=("$pkg"); pkg_tools+=("$t") ;;
    esac
  done
  [ "${#pkgs[@]}" -gt 0 ] || return 0

  local pm_cmd=()
  case "$pm" in
    apt-get) pm_cmd=(apt-get install -y) ;;
    dnf)     pm_cmd=(dnf install -y) ;;
    pacman)  pm_cmd=(pacman -S --noconfirm --needed) ;;
    brew)    pm_cmd=(brew install) ;;
  esac
  need_root=1
  [ "$pm" = brew ] && need_root=0
  if [ "$need_root" = 1 ] && [ "$EUID" -ne 0 ]; then
    if have sudo; then
      pm_cmd=(sudo "${pm_cmd[@]}")
    else
      for t in "${pkg_tools[@]}"; do
        manual_add "$t" "not root and sudo not found — re-run as root to install '$t' (or install it by hand)"
      done
      return 0
    fi
  fi

  info "running: ${pm_cmd[*]} ${pkgs[*]}"
  if "${pm_cmd[@]}" "${pkgs[@]}"; then
    for t in "${pkg_tools[@]}"; do
      if have "$t"; then
        installed_add "$t"
      elif [ "$pm" = brew ] && [ "$(pkg_for "$t" brew)" = coreutils ]; then
        manual_add "$t" "'$t' still not on PATH after 'brew install coreutils' — Homebrew's GNU tools are g-prefixed (g$t): link g$t into ~/.local/bin or add \"\$(brew --prefix)/coreutils/libexec/gnubin\" to your PATH"
      else
        manual_add "$t" "'$t' still not on PATH after the $pm install — install '$t' by hand"
      fi
    done
  else
    for t in "${pkg_tools[@]}"; do
      manual_add "$t" "$pm install failed — install '$t' by hand (see the package manager output above)"
    done
  fi
  return 0
}

# --- treehouse --------------------------------------------------------------

fetch() { # $1=url $2=dest
  if have curl; then
    curl -fsSL -o "$2" "$1"
  else
    wget -q -O "$2" "$1"
  fi
}

sha256_of() { # $1=file -> hex digest on stdout
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Hint for a treehouse binary that exists at the install path but is not
# reachable — the no-overwrite rule means PATH is the only fix.
treehouse_offpath_hint() { # $1=target
  printf '%s' "$1 exists but treehouse is not on PATH — add ~/.local/bin to your PATH (the existing file is left untouched)"
}

install_treehouse() {
  case " $PRESENT " in *" treehouse "*) return 0 ;; esac
  local target="$HOME/.local/bin/treehouse"
  local releases="https://github.com/kunchenguid/treehouse/releases"
  local dep os arch tag asset expected got tmp

  if [ -e "$target" ]; then
    manual_add "treehouse" "$(treehouse_offpath_hint "$target")"
    return 0
  fi
  if ! have curl && ! have wget; then
    manual_add "treehouse" "no curl or wget to download treehouse — install one and re-run, or install it by hand from $releases into ~/.local/bin"
    return 0
  fi
  for dep in sed grep awk tar mktemp uname; do
    if ! have "$dep"; then
      manual_add "treehouse" "missing '$dep', needed to verify and unpack the treehouse download — install the system tools first, then re-run"
      return 0
    fi
  done
  if ! have sha256sum && ! have shasum; then
    manual_add "treehouse" "sha256sum or shasum is required to verify the treehouse download — install coreutils, then re-run"
    return 0
  fi
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *)
      manual_add "treehouse" "unsupported operating system $(uname -s) — install treehouse by hand from $releases"
      return 0 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)
      manual_add "treehouse" "unsupported architecture $(uname -m) — install treehouse by hand from $releases"
      return 0 ;;
  esac

  tmp=$(mktemp -d) || {
    manual_add "treehouse" "mktemp -d failed — cannot stage the treehouse download"
    return 0
  }
  register_tmp "$tmp"

  if ! fetch "https://api.github.com/repos/kunchenguid/treehouse/releases/latest" "$tmp/latest.json"; then
    manual_add "treehouse" "could not query the latest release (api.github.com) — install it by hand from $releases"
    return 0
  fi
  tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp/latest.json")
  if [ -z "$tag" ]; then
    manual_add "treehouse" "could not resolve the latest treehouse release — install it by hand from $releases"
    return 0
  fi
  asset="treehouse-$tag-$os-$arch.tar.gz"
  if ! fetch "$releases/download/$tag/$asset" "$tmp/$asset" \
     || ! fetch "$releases/download/$tag/checksums.txt" "$tmp/checksums.txt"; then
    manual_add "treehouse" "could not download $asset from the $tag release — install it by hand from $releases"
    return 0
  fi
  expected=$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/checksums.txt")
  if [ -z "$expected" ]; then
    manual_add "treehouse" "the $tag checksums.txt has no entry for $asset — nothing was installed"
    return 0
  fi
  got=$(sha256_of "$tmp/$asset") || {
    manual_add "treehouse" "could not compute the sha256 of $asset — nothing was installed"
    return 0
  }
  if [ "$got" != "$expected" ]; then
    manual_add "treehouse" "checksum mismatch for $asset — the download was not installed"
    return 0
  fi
  if ! tar -xzf "$tmp/$asset" -C "$tmp" || [ ! -x "$tmp/treehouse" ]; then
    manual_add "treehouse" "the $asset release archive did not contain an executable treehouse"
    return 0
  fi
  if [ -e "$target" ]; then
    # Appeared while we were downloading: the no-overwrite rule wins.
    manual_add "treehouse" "$(treehouse_offpath_hint "$target")"
    return 0
  fi
  if ! mkdir -p "$(dirname "$target")" \
     || ! cp "$tmp/treehouse" "$target" \
     || ! chmod +x "$target"; then
    manual_add "treehouse" "could not write $target — install treehouse by hand from $releases"
    return 0
  fi
  if have treehouse; then
    installed_add "treehouse"
  else
    manual_add "treehouse" "installed at $target but it is not on PATH — add ~/.local/bin to your PATH"
  fi
  return 0
}

# --- pi ---------------------------------------------------------------------

install_pi() {
  case " $PRESENT " in *" pi "*) return 0 ;; esac
  local pi_cmd=(npm install -g --ignore-scripts @earendil-works/pi-coding-agent)
  if ! have npm; then
    manual_add "pi" "pi needs Node.js 22.19 or newer with npm — install Node (https://github.com/earendil-works/pi), then run: ${pi_cmd[*]} — or use the official installer: curl -fsSL https://pi.dev/install.sh | sh"
    return 0
  fi
  info "running: ${pi_cmd[*]}"
  if "${pi_cmd[@]}"; then
    if have pi; then
      installed_add "pi"
    else
      manual_add "pi" "npm reported success but pi is not on PATH — check npm's global prefix and re-run"
    fi
  else
    manual_add "pi" "npm install of pi failed — install it by hand: ${pi_cmd[*]}"
  fi
  return 0
}

# --- shellcheck -------------------------------------------------------------

install_shellcheck() {
  case " $PRESENT " in *" shellcheck "*) return 0 ;; esac
  local hook="$REPO_ROOT/scripts/worktree-setup.sh"
  info "provisioning shellcheck via scripts/worktree-setup.sh (the pinned source of truth)"
  # The hook's own [worktree-setup] log passes through; its exit status is
  # advisory here — the command -v re-check below decides the outcome.
  ( cd "$REPO_ROOT" && "$BASH" "$hook" ) || true
  if have shellcheck; then
    installed_add "shellcheck"
  elif [ -e "$HOME/.local/bin/shellcheck" ]; then
    manual_add "shellcheck" "provisioned at ~/.local/bin/shellcheck but it is not on PATH — add ~/.local/bin to your PATH"
  else
    manual_add "shellcheck" "still missing after the shared install — run scripts/worktree-setup.sh or install shellcheck by hand (the pin lives there)"
  fi
  return 0
}

# --- mu launcher ------------------------------------------------------------

# Put the repository's own `mu` launcher on PATH (README.md, Installation ->
# 4): ~/.local/bin/mu -> <checkout>/mu. Nothing is downloaded; the link
# prefers the main checkout (resolved through git's common dir) because
# pooled worktrees are ephemeral — specs/mu-launcher, "PATH installation".
# The no-overwrite rule covers any existing entry (file or symlink, even a
# broken one), and the outcome is re-checked with `command -v` like every
# other tool.
install_mu() {
  case " $PRESENT " in *" mu "*) return 0 ;; esac
  local target="$HOME/.local/bin/mu" launcher="$REPO_ROOT/mu" common main_root
  if have git \
     && common=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null) \
     && [ -n "$common" ] \
     && main_root=$(cd -- "$REPO_ROOT" 2>/dev/null && cd -- "$common" 2>/dev/null && pwd); then
    main_root=${main_root%/*}   # strip the trailing ".git" component
    [ -f "$main_root/mu" ] && launcher="$main_root/mu"
  fi
  if [ ! -f "$launcher" ]; then
    manual_add "mu" "the launcher file $launcher is missing — restore it (git checkout -- mu) and re-run"
    return 0
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    manual_add "mu" "$target exists but mu does not resolve on PATH — add ~/.local/bin to your PATH, or point the entry at $launcher (the existing file is left untouched)"
    return 0
  fi
  if ! mkdir -p "$(dirname "$target")" || ! ln -s "$launcher" "$target"; then
    manual_add "mu" "could not create $target — link it by hand: ln -sf $launcher $target"
    return 0
  fi
  if have mu; then
    installed_add "mu"
  else
    manual_add "mu" "installed at $target but mu is not on PATH — add ~/.local/bin to your PATH"
  fi
  return 0
}

# --- required skills + git hooks (advisory, every run) -----------------------

# Mirror required-skills/ into .agents/skills/ (pi's project skill location).
# MU_SKILLS_SRC / MU_SKILLS_DST relocate the two folders for hermetic tests.
# Failure is a warning only: the exit status stays tied to PATH dependencies.
sync_required_skills() {
  local src=${MU_SKILLS_SRC:-$REPO_ROOT/required-skills}
  local dst=${MU_SKILLS_DST:-$REPO_ROOT/.agents/skills}
  local sync="$REPO_ROOT/scripts/sync-skills.sh"
  if [ ! -f "$sync" ]; then
    warn "missing scripts/sync-skills.sh — required skills were not synced"
    return 0
  fi
  if ! "$BASH" "$sync" "$src" "$dst"; then
    warn "required skills sync failed — $dst may be stale"
  fi
  return 0
}

# Activate this repository's versioned hooks (.githooks/ via the relative
# core.hooksPath, which git resolves against each worktree's top level).
# Idempotent and non-destructive: set only when unset, a foreign value is
# kept and reported — and never activated without a .githooks/ directory.
activate_githooks() {
  [ -d "$REPO_ROOT/.githooks" ] || return 0
  have git || return 0   # git's own dependency report covers its absence
  local current
  current=$(git -C "$REPO_ROOT" config core.hooksPath 2>/dev/null) || current=
  case "$current" in
    .githooks) return 0 ;;
    "")
      if git -C "$REPO_ROOT" config core.hooksPath .githooks 2>/dev/null; then
        info "git hooks: core.hooksPath -> .githooks"
      else
        warn "git hooks: could not set core.hooksPath — run 'git config core.hooksPath .githooks' by hand"
      fi
      ;;
    *)
      warn "git hooks: core.hooksPath is already '$current' — leaving it alone; run 'git config core.hooksPath .githooks' to activate this repo's hooks"
      ;;
  esac
  return 0
}

# --- summary ----------------------------------------------------------------

summarize() {
  local t list n
  info "Summary:"
  list=""; n=0
  for t in $ALL_TOOLS; do
    if [ "$(state_of "$t")" = present ]; then
      list="$list${list:+ }$t"; n=$((n + 1))
    fi
  done
  printf '  already present (%d): %s\n' "$n" "${list:-none}"
  list=""; n=0
  for t in $ALL_TOOLS; do
    if [ "$(state_of "$t")" = installed ]; then
      list="$list${list:+ }$t"; n=$((n + 1))
    fi
  done
  printf '  installed (%d): %s\n' "$n" "${list:-none}"
  printf '  needs manual action (%d):\n' "$MANUAL_N"
  [ "$MANUAL_N" -gt 0 ] && printf '%s\n' "$MANUAL"
  return 0
}

# --- main -------------------------------------------------------------------

main() {
  local t total
  for t in $ALL_TOOLS; do
    if have "$t"; then
      PRESENT="${PRESENT}${PRESENT:+ }$t"
    fi
  done
  total=$(count_words "$ALL_TOOLS")
  info "checking $total required dependencies"

  # Both advisory steps run on every invocation, including the no-op path.
  sync_required_skills

  if [ "${#PRESENT}" -gt 0 ] && [ "$(count_words "$PRESENT")" = "$total" ]; then
    info "all $total dependencies already present — nothing to install"
    activate_githooks
    summarize
    exit 0
  fi

  install_system
  install_treehouse
  install_pi
  install_shellcheck
  install_mu            # repo-owned launcher (README -> 4), not a download
  activate_githooks   # after the installs: git may only have arrived now
  summarize
  if [ "$MANUAL_N" -eq 0 ]; then
    info "all dependencies present"
    exit 0
  fi
  warn "$MANUAL_N dependencies still missing — see 'needs manual action' above"
  exit 1
}

main "$@"
