#!/usr/bin/env bash
# Shared helpers for the subsession scripts (see AGENTS.md, "pi sessions").
# Source this file; don't execute it.
# shellcheck shell=bash

: "${DEV_BRANCH:=development}"   # base branch for worktrees
# Keep this distinction so callers can fall back to the invoking tmux session
# only when MAIN_SESSION was not explicitly configured.
_SUB_MAIN_SESSION_WAS_SET=${MAIN_SESSION+x}
: "${MAIN_SESSION:=pi-main}"     # orchestrator tmux session
: "${MAIN_PANE:=}"               # stable orchestrator pane ID, when known
: "${PI_BIN:=pi}"                # pi executable
: "${PI_BOOT_DELAY:=3}"          # seconds to wait for the pi TUI to boot
: "${SCRATCH_DIR:=tmp/pi-sub}"      # gitignored scratch dir in the main checkout

# This script's own directory: anchors repo-local defaults (the child
# difficulty levels live in config.json at the repo root, next to this
# scripts/ dir).
# Pure parameter expansion — no external dirname at source time: this file
# must stay sourceable with a restricted PATH (tests/sub-common.test.sh) and
# under set -e.
_SUB_COMMON_DIR=${BASH_SOURCE[0]%/*}
if [ -z "$_SUB_COMMON_DIR" ] || [ "$_SUB_COMMON_DIR" = "${BASH_SOURCE[0]}" ]; then
  _SUB_COMMON_DIR=.
fi

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
  done
}

valid_task() { [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; }

# Echo the git toplevel of a directory (default: cwd), or die.
repo_root() {
  local r="${1:-$PWD}"
  [ -e "$r" ] || die "no such path: $r"
  git -C "$r" rev-parse --show-toplevel 2>/dev/null || die "not a git repository: $r"
}

# tmux session name for a task
session_of() { printf 'pi-%s' "$1"; }

# Echo the tmux session containing the invoking pane, when this script was
# launched from tmux. An empty result means there is no usable invoking pane.
invoking_tmux_session() {
  [ -n "${TMUX:-}" ] || return 0
  if [ -n "${TMUX_PANE:-}" ]; then
    tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true
  else
    tmux display-message -p '#S' 2>/dev/null || true
  fi
}

# Echo the stable pane ID containing the invoking shell, when launched from
# tmux. Pane IDs remain tied to the original pane even if another window is
# selected later (for example, by open_viewer_window).
invoking_tmux_pane() {
  [ -n "${TMUX:-}" ] || return 0
  if [ -n "${TMUX_PANE:-}" ]; then
    tmux display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>/dev/null || true
  else
    tmux display-message -p '#{pane_id}' 2>/dev/null || true
  fi
}

# Echo the leased worktree path for a task (lease holder == task name),
# or print nothing when the task holds no lease.
wt_for_task() { # $1=task $2=repo-root
  ( cd "$2" && treehouse status --json 2>/dev/null \
      | jq -r --arg h "$1" '[.[] | select(.lease_holder == $h) | .path][0] // empty' \
    ) || true
}

branch_exists() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }

# Echo the ref a new task branch is based on for the repo at $1, and die when
# there is none. The configured $DEV_BRANCH wins when it exists: its remote
# ref origin/<dev> first, else the local branch. Only when neither exists does
# this fall back to the repository's default branch as advertised by
# origin/HEAD (e.g. origin/master) and warn about it, so a repository that
# deleted its dev branch keeps spawning. Deliberately no fetch here: callers
# fetch first, and a pre-existing remote ref must keep priority even when that
# fetch failed.
resolve_base_ref() { # $1=repo-root
  local root=$1 default
  if git -C "$root" rev-parse --verify --quiet "origin/$DEV_BRANCH" >/dev/null; then
    printf 'origin/%s' "$DEV_BRANCH"; return 0
  fi
  if branch_exists "$root" "$DEV_BRANCH"; then
    printf '%s' "$DEV_BRANCH"; return 0
  fi
  default=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$default" ] && git -C "$root" rev-parse --verify --quiet "$default" >/dev/null; then
    warn "base branch '$DEV_BRANCH' not found on origin or locally; falling back to the default branch '${default#origin/}'"
    printf '%s' "$default"; return 0
  fi
  die "no base branch: '$DEV_BRANCH' is missing from origin and local refs, and origin/HEAD names no usable default (in $root)"
}

# Echo the number of commits reachable from HEAD but not from base ref $2 in
# the repository $1, or fail (non-zero, echoing nothing) when that range
# cannot be computed. Callers must treat a failure as "unknown", never as
# "0": the unpublished-work guard in sub-retire.sh depends on a broken base
# ref aborting rather than reading as zero, and this holds regardless of the
# caller's shell options — a `git log … | wc -l` pipeline would let wc's exit
# status hide git's failure whenever pipefail is off.
unlanded_count() { # $1=repo-root $2=base-ref
  local out
  if ! out=$(git -C "$1" log --oneline "$2"..HEAD 2>/dev/null); then
    return 1
  fi
  if [ -z "$out" ]; then
    printf '0'
  else
    wc -l <<<"$out"
  fi
}

# Pick an unused local task branch. A linked worktree cannot check out a branch
# already checked out by another worktree, so never assume task/<name> is free.
task_branch() { # $1=repo-root $2=task
  local root=$1 task=$2 candidate suffix=2
  candidate="task/$task"
  while branch_exists "$root" "$candidate"; do
    candidate="task/$task-$suffix"
    suffix=$((suffix + 1))
  done
  printf '%s' "$candidate"
}

# Shared file locations for the brief/report exchange with a child. They live
# in a gitignored scratch dir inside the MAIN checkout (outside any worktree,
# so they survive 'treehouse return --force') and are deleted when the task is
# retired (see sub-retire.sh). The default `tmp/pi-sub/` is covered by the
# global excludes file (~/.config/git/ignore); set SCRATCH_DIR to relocate it,
# but keep it gitignored. Do NOT use `.pi/` — that is pi's own config dir.
scratch_root() { printf '%s/%s' "$1" "$SCRATCH_DIR"; }
task_file()    { printf '%s/%s/tasks/%s.md'    "$1" "$SCRATCH_DIR" "$2"; }
report_file()  { printf '%s/%s/reports/%s.md'  "$1" "$SCRATCH_DIR" "$2"; }
patch_file()   { printf '%s/%s/reports/%s.patch' "$1" "$SCRATCH_DIR" "$2"; }

# The child difficulty-levels config (AGENTS.md, "Child model and thinking
# levels"): config.json at the repository root — a generic root-level file
# whose taskLevels section holds the levels; sibling top-level keys are
# future general settings and must stay invisible to level resolution.
# SUB_LEVELS_CONFIG relocates the file.
levels_config() {
  printf '%s' "${SUB_LEVELS_CONFIG:-$_SUB_COMMON_DIR/../config.json}"
}

# Echo the fallback model configured for a stuck child (AGENTS.md, "Child
# model and thinking levels"): the env override SUB_FALLBACK_MODEL, else
# .taskLevels.fallbackModel in the levels config. Empty when no fallback is
# configured — a missing, unreadable, or malformed config means "no
# fallback", never an error, so no caller breaks on a config problem.
resolve_fallback_model() {
  if [ -n "${SUB_FALLBACK_MODEL:-}" ]; then printf '%s' "$SUB_FALLBACK_MODEL"; return 0; fi
  _fallback_config_value fallbackModel
}

# Echo the thinking level to apply with the fallback model (env override
# SUB_FALLBACK_THINKING, else .taskLevels.fallbackThinking); empty means
# "leave pi's level as-is". Same graceful degradation as resolve_fallback_model.
resolve_fallback_thinking() {
  if [ -n "${SUB_FALLBACK_THINKING:-}" ]; then printf '%s' "$SUB_FALLBACK_THINKING"; return 0; fi
  _fallback_config_value fallbackThinking
}

# Echo one string key from the taskLevels section, or nothing.
_fallback_config_value() { # $1=key
  local cfg
  cfg=$(levels_config)
  [ -f "$cfg" ] || return 0
  jq -r --arg k "$1" '.taskLevels[$k] // empty' "$cfg" 2>/dev/null || true
  return 0
}

# Echo the quoted --model/--thinking option words for a child pi launch
# (possibly empty). Precedence: explicit flag > SUB_MODEL/SUB_THINKING env >
# the selected level's mapping in the config's taskLevels section; the level
# itself is: explicit flag > SUB_LEVEL env > .taskLevels.default. All jq
# queries are rooted at .taskLevels, so unknown sibling top-level keys in
# config.json are ignored by construction. Always exits 0 — a
# missing/malformed config or an unknown level warns on stderr and degrades
# to no flags, so the child inherits defaultThinkingLevel/modelThinkingLevels
# from the global settings instead of spawning ever failing.
resolve_child_launch_flags() { # $1=level $2=model $3=thinking
  local level=${1:-} model=${2:-} thinking=${3:-} cfg out=""
  [ -n "$model" ] || model=${SUB_MODEL:-}
  [ -n "$thinking" ] || thinking=${SUB_THINKING:-}
  [ -n "$level" ] || level=${SUB_LEVEL:-}
  if [ -z "$model" ] || [ -z "$thinking" ]; then
    cfg=$(levels_config)
    if [ ! -f "$cfg" ]; then
      warn "config.json not found: $cfg — child inherits model/thinking from settings"
    elif ! jq -e '(.taskLevels.levels | type) == "object"' "$cfg" >/dev/null 2>&1; then
      warn "config.json invalid: $cfg — child inherits model/thinking from settings"
    else
      [ -n "$level" ] || level=$(jq -r '.taskLevels.default // empty' "$cfg" 2>/dev/null || true)
      if [ -z "$level" ]; then
        warn "config.json has no default level: $cfg — child inherits model/thinking from settings"
      elif jq -e --arg l "$level" '.taskLevels.levels | has($l)' "$cfg" >/dev/null 2>&1; then
        [ -n "$model" ] || model=$(jq -r --arg l "$level" '.taskLevels.levels[$l].model // empty' "$cfg" 2>/dev/null || true)
        [ -n "$thinking" ] || thinking=$(jq -r --arg l "$level" '.taskLevels.levels[$l].thinking // empty' "$cfg" 2>/dev/null || true)
      else
        warn "unknown level '$level' in $cfg — child inherits model/thinking from settings"
      fi
    fi
  fi
  if [ -n "$model" ]; then
    out=$(printf '%q %q' --model "$model")
  fi
  if [ -n "$thinking" ]; then
    out+="${out:+ }$(printf '%q %q' --thinking "$thinking")"
  fi
  printf '%s' "$out"
  return 0
}

# Echo the subagents source children load explicitly on their launch line, or
# an empty string when they must start without it: SUB_CHILD_SUBAGENTS=0 opts
# out, and a missing local install degrades to a plain child instead of failing
# the spawn. The source is the @tintinweb/pi-subagents package's src entry
# (user directive, 2026-10-17: "let children to load @tintinweb/pi-subagents:src
# instead of pi-subagents extension. remember that for the future") — its
# package manifest declares ./src/index.ts, so naming the file directly is the
# same extension pi would pick up, minus a version re-resolve on every spawn.
# `npm:@tintinweb/pi-subagents` is the fallback for an install that ships no
# src tree. NOTE: `npm:@tintinweb/pi-subagents:src` is NOT a valid spec — pi
# strips only the `npm:` prefix and hands the rest to npm install verbatim
# (`npm install @tintinweb/pi-subagents:src` → ENOENT), failing the spawn.
# pi_launch_command is the only consumer; `-e <source>` gives a child the
# extension for one invocation while --no-extensions keeps every other
# discovered, configured, and built-in extension off (docs/packages.md:
# `pi -e npm:<name>` loads a package without adding it to settings, so the
# deliberately empty child settings file stays empty).
child_subagents_source() {
  [ "${SUB_CHILD_SUBAGENTS:-1}" = 0 ] && return 0
  local pkg="$HOME/.pi/agent/npm/node_modules/@tintinweb/pi-subagents"
  if [ -f "$pkg/src/index.ts" ]; then
    printf '%s' "$pkg/src/index.ts"
    return 0
  fi
  [ -d "$pkg" ] || return 0
  printf 'npm:@tintinweb/pi-subagents'
}

# the options — before the kickoff message argument — so pi parses them as
# options, not as part of the prompt.
pi_launch_command() { # $1=pi-bin $2=task $3=option words $4=kickoff
  local subagents_opt="" source
  source=$(child_subagents_source)
  [ -n "$source" ] && subagents_opt=" -e $(printf '%q' "$source")"
  if [ -n "${3:-}" ]; then
    printf '%q -n %q --no-extensions%s %s --approve %q' "$1" "$2" "$subagents_opt" "$3" "$4"
  else
    printf '%q -n %q --no-extensions%s --approve %q' "$1" "$2" "$subagents_opt" "$4"
  fi
}

# Prepare an isolated Pi agent directory for a child. It preserves non-extension
# resources such as settings metadata, custom agent definitions, skills,
# prompts, and themes, but gives the child no extensions or packages at all —
# @tintinweb/pi-subagents, the one extension children load, is passed on the
# launch line instead (pi_launch_command). Linking `agents` exposes the user's
# custom agent types (the nff-* definitions the flow names) to the child;
# project-level .pi/agents definitions keep being discovered from the child's
# worktree, where they override the user-level ones.
# The directory lives in the
# gitignored scratch dir of the main checkout (outside the worktree) and is
# removed on retirement.
prepare_child_agent_dir() { # $1=destination dir; echoes dir
  local agent_dir=$1 source name model_cfg
  rm -rf "$agent_dir"
  mkdir -p "$agent_dir/extensions"
  # An empty package list prevents package-provided extensions from loading.
  # Model defaults (defaultProvider/defaultModel/enabledModels) are inherited
  # from the global settings: without them the child has no configured default
  # and pi falls through to its built-in per-provider fallback map, landing on
  # an arbitrary model (e.g. google/gemini-3.1-pro-preview) whenever the
  # target repo has no project-level .pi/settings.json. defaultThinkingLevel /
  # modelThinkingLevels / defaultProjectTrust (specs/child-task-levels) ride
  # along as the baseline when sub-spawn passes no --model/--thinking flags.
  model_cfg=$(jq -c '{defaultProvider, defaultModel, enabledModels,
    defaultThinkingLevel, modelThinkingLevels, defaultProjectTrust}
    | with_entries(select(.value != null))' "$HOME/.pi/agent/settings.json" 2>/dev/null || printf '{}')
  jq -cn --argjson cfg "$model_cfg" '$cfg + {packages: []}' > "$agent_dir/settings.json" 2>/dev/null \
    || printf '{"packages":[]}\n' > "$agent_dir/settings.json" # jq absent → never leave an empty file

  for name in auth.json keybindings.json models.json models-store.json trust.json AGENTS.md AGENTS.override.md SYSTEM.md APPEND_SYSTEM.md; do
    source="$HOME/.pi/agent/$name"
    if [ -e "$source" ] || [ -L "$source" ]; then
      ln -s "$source" "$agent_dir/$name"
    fi
  done
  for name in agents npm node_modules skills prompts themes; do
    source="$HOME/.pi/agent/$name"
    if [ -e "$source" ] || [ -L "$source" ]; then
      ln -s "$source" "$agent_dir/$name"
    fi
  done

  printf '%s\n' "$agent_dir"
}

# Open a live viewer for a child session. When launched from tmux, prefer a
# pane in the invoking window; otherwise retain the old viewer-window
# fallback, but create it detached so a non-tmux invocation does not change
# the selected window. Best effort — every failure is silent and non-fatal;
# echoes the target session name on success, nothing on skip/failure. Panes
# inherit $TMUX, so the nested attach needs it cleared — and when the child
# session dies, the attach client exits and tmux closes the pane/window.
open_viewer_window() { # $1=task $2=child-session $3=invoking-pane (optional)
  local task=$1 child=$2 invoking_pane=${3:-} anchor target=$MAIN_SESSION wins
  [ "${SUB_SPAWN_NO_VIEWER:-0}" = 1 ] && return 0
  # An explicitly configured MAIN_PANE is the stable viewer anchor. Otherwise,
  # prefer the pane that invoked the spawn, and report that pane's session.
  anchor=${MAIN_PANE:-$invoking_pane}
  if [ -n "$anchor" ] \
     && tmux display-message -p -t "$anchor" '#{pane_id}' >/dev/null 2>&1; then
    target=$(tmux display-message -p -t "$anchor" '#S' 2>/dev/null) || return 0
    tmux split-window -h -t "$anchor" \
      "env -u TMUX tmux attach -t $child" >/dev/null 2>&1 || return 0
    # Keep the cursor focus where it was: the split made the viewer pane
    # active, so hand focus back to the anchor pane before the layout settles.
    tmux select-pane -t "$anchor" >/dev/null 2>&1 || true
    tmux set-window-option -t "$target" main-pane-width 50% >/dev/null 2>&1 || true
    tmux select-layout -t "$target" main-vertical >/dev/null 2>&1 || true
    tmux resize-pane -t "$anchor" -x 50% >/dev/null 2>&1 || true
    printf '%s\n' "$target"
    return 0
  fi
  tmux has-session -t "=$target" 2>/dev/null || return 0
  wins=$(tmux list-windows -t "=$target:" -F '#W' 2>/dev/null) || return 0
  if grep -Fxq -- "$task" <<<"$wins"; then return 0; fi
  tmux new-window -d -t "=$target:" -n "$task" \
    "env -u TMUX tmux attach -t $child" >/dev/null 2>&1 || return 0
  printf '%s\n' "$target"
}

# Flatten a string to its non-whitespace characters. tmux wraps text to the
# pane width, so a verbatim comparison would miss a message that landed.
_flatten() { printf '%s' "$1" | tr -d '[:space:]'; }

# Flattened text currently shown in a pane.
_pane_flattened() { tmux capture-pane -t "$1" -p 2>/dev/null | tr -d '[:space:]' || true; }

# Remove shell-escaping backslashes (`\x` becomes `x`), in pure bash so this
# file stays sourceable with a restricted PATH.
_shell_unescape() { # $1=text
  local s=$1
  local bs=$'\\' out='' c='' i n=${#s}
  for (( i = 0; i < n; i++ )); do
    c=${s:i:1}
    if [ "$c" = "$bs" ] && (( i + 1 < n )); then
      (( i++ ))
      out+=${s:i:1}
    else
      out+=$c
    fi
  done
  printf '%s' "$out"
}

# The probes a typed line is looked for by: the literal text (as sent, so a
# shell-escaped launch line keeps its backslashes) and the same text with the
# shell's escaping backslashes stripped. Both regions are bottom-anchored (the
# composer and the newest transcript line sit at the pane's foot), so the tail
# survives pane wrapping and scrollback even when the head of a long line is
# out of view.
#
# The stripped form exists because the SHELL removes those backslashes before
# pi ever sees the line: pi shows `(or BLOCKED: <reason>)`, never
# `\"DONE: \<one-line\ summary\>\"` (2026-10-18 — the kickoff confirmation
# failed for exactly that reason). Probing one form only ever confirmed a send
# into a pane that echoes the bytes verbatim. Only the backslash escapes are
# resolved — a `printf %q` line carrying control characters (which %q renders
# as `$'…'`) is out of scope: no such launch line exists today, and a probe
# that matched neither form only costs a retype, never a false success.
_PI_PROBE_TAIL=60
_PI_PROBES=()
# Head probe for pi's pending-message display. While a turn is running, pi
# queues a submitted message as a steering message and renders it as ONE line
# truncated to the pane width (`Steering: <message>…`, TruncatedText(text, 1,
# 0)), so the tail probe can never match a queued line. The message's HEAD is
# visible, and _PI_HEAD_PROBE flattened characters of it are enough to tell a
# queued line from unrelated content while staying inside the truncated prefix
# even on a narrow (~40 column) orchestrator pane. A head alone is not an
# identity — two notices on the same PR share it — so the caller also requires
# that the queued copy is new to this send (_pi_pending_head_count).
_PI_HEAD_PROBE=20
_PI_HEAD_PROBES=()

# Set the probe set for a typed line: flattened, tail-clamped, duplicates
# dropped, the literal form first.
_set_probes() { # $1=text
  local form clamped dup='' existing
  _PI_PROBES=()
  for form in "$(_flatten "$1")" "$(_flatten "$(_shell_unescape "$1")")"; do
    [ -n "$form" ] || continue
    clamped=$form
    # Bash's ${var: -n} yields an EMPTY string for strings shorter than n, so
    # clamp to the full text instead of silently probing for "".
    if [ "${#clamped}" -gt "$_PI_PROBE_TAIL" ]; then clamped=${clamped: -$_PI_PROBE_TAIL}; fi
    dup=''
    for existing in ${_PI_PROBES[@]+"${_PI_PROBES[@]}"}; do
      if [ "$existing" = "$clamped" ]; then dup=1; break; fi
    done
    [ -n "$dup" ] || _PI_PROBES+=("$clamped")
  done
  return 0
}

# True when any probe form appears in already-flattened text $1.
_has_probe() { # $1=text
  local p
  for p in ${_PI_PROBES[@]+"${_PI_PROBES[@]}"}; do
    grep -qF -- "$p" <<<"$1" && return 0
  done
  return 1
}

# Set the head-probe set for a typed line: the first _PI_HEAD_PROBE flattened
# characters of each probe form, duplicates dropped, the literal form first.
_set_head_probes() { # $1=text
  local form head dup='' existing
  _PI_HEAD_PROBES=()
  for form in "$(_flatten "$1")" "$(_flatten "$(_shell_unescape "$1")")"; do
    [ -n "$form" ] || continue
    # ${var:0:n} yields the whole string when the form is shorter than n.
    head=${form:0:$_PI_HEAD_PROBE}
    dup=''
    for existing in ${_PI_HEAD_PROBES[@]+"${_PI_HEAD_PROBES[@]}"}; do
      if [ "$existing" = "$head" ]; then dup=1; break; fi
    done
    [ -n "$dup" ] || _PI_HEAD_PROBES+=("$head")
  done
  return 0
}

# True when any head-probe form appears in already-flattened text $1. $1 is
# pi's pending display, one flattened queued message per line; grep matches
# line by line, so a head can never be assembled across two queued messages.
_has_head_probe() { # $1=text
  local p
  for p in ${_PI_HEAD_PROBES[@]+"${_PI_HEAD_PROBES[@]}"}; do
    grep -qF -- "$p" <<<"$1" && return 0
  done
  return 1
}

# Number of lines in pi's already-flattened pending display $1 that match a
# head-probe form — i.e. the queued copies of this message. The caller
# compares it before and after typing: only a copy THIS send added may confirm
# it, so an older queued message whose visible head merely collides with this
# line's head can never pass for the send. The maximum across probe forms is
# deliberate: each form matches whole lines, and two forms of one message are
# the same queued line, not two copies.
_pi_pending_head_count() { # $1=text
  local p c n=0
  for p in ${_PI_HEAD_PROBES[@]+"${_PI_HEAD_PROBES[@]}"}; do
    c=$(grep -cF -- "$p" <<<"$1" 2>/dev/null || true)
    if [ "$c" -gt "$n" ]; then n=$c; fi
  done
  printf '%s' "$n"
}

# True when a probe is visible anywhere in the pane, polling a bounded
# number of times: `send-keys` only hands the bytes to the pane's input queue,
# and a TUI mid-redraw (slow extension init, model switch, compaction) can hold
# them there long after the call returned.
_pi_visible() { # $1=target
  local n
  for (( n = 0; n < _PI_VISIBILITY_TRIES; n++ )); do
    if _has_probe "$(_pane_flattened "$1")"; then return 0; fi
    sleep "$_PI_TYPE_SETTLE"
  done
  return 1
}

# Bounded composer window. pi's composer is a short block (the typed line plus
# at most its wrapped tail) directly above the status border, and the probe
# callers use is the TAIL of the line, so the bottom window is all the
# evidence needs. Bounding it stops a transcript that runs straight into the
# border (no blank separator) from being swallowed as "composer" — the
# unbounded walk-up of the previous implementation reported an idle pane's
# whole scrollback as parked text.
_PI_COMP_MAX_LINES=4
# How many rows above the status border are scanned for the composer's bottom
# edge — i.e. how many blank rows are tolerated there (at most
# _PI_COMP_SCAN_LINES-1 of them): pi leaves one for the empty composer, and
# the composer's own top border is not drawn at all in the instant after
# typing (reproduced on pi-riak-250-review, where the parked line then landed
# in the transcript and the send was abandoned before any Enter).
_PI_COMP_SCAN_LINES=2
# Bounded budget for "did the typed text render at all": `send-keys` hands the
# bytes to the pane's input queue, and a TUI mid-redraw can hold them there for
# a while, so visibility is polled instead of probed once per attempt.
_PI_TYPE_ATTEMPTS=2
_PI_VISIBILITY_TRIES=3
_PI_TYPE_SETTLE=0.4
# One quick re-capture before a vanished line is re-typed: a merely LATE
# transcript render must not lead to a duplicate line.
_PI_VANISH_RECHECK=0.2

# Region globals, so a predicate can never read an unset variable (callers run
# with set -u) before a parse filled them in.
_pi_layout='' _pi_comp='' _pi_trans='' _pi_below='' _pi_all='' _pi_pending=''

# True when a pane line is nothing but box-drawing dashes — pi's status
# border. Byte-exact dash stripping keeps this locale-independent (the system
# awk is mawk, whose multibyte regexes would misfire — hence pure bash + tr).
_pi_dash_row() { # $1=pane line
  local s=${1//[[:space:]]/}
  [ -n "$s" ] && [ -z "${s//─/}" ]
}

# True when a pane line is pi's chrome rather than composer content: the
# status border, or the bordered spinner/status row above the composer
# ("── ⠴ Working ──", pi's Loader frames and its message). Chrome bounds the
# composer block but is never part of it, which keeps an idle or working pane's
# composer region empty. The rule is deliberately narrow — a started-and-ended
# dashed row is not chrome — because classifying a parked line as chrome would
# push it into the transcript and turn a still-parked prompt into a confirmed
# send. A wording change in pi's status row only means chrome is no longer
# recognised, which is harmless: the row then reads as ordinary content and
# never holds the probe.
_pi_chrome_row() { # $1=pane line
  local s=${1//[[:space:]]/}
  if _pi_dash_row "$1"; then return 0; fi
  case $s in
    ─*⠋*|─*⠙*|─*⠹*|─*⠸*|─*⠼*|─*⠴*|─*⠦*|─*⠧*|─*⠇*|─*⠏*) return 0 ;;
  esac
  return 1
}

# True when a pane line is one of pi's pending-message display entries: a
# `Steering: <text>` line (a message queued behind a running turn) or a
# `Follow-up: <text>` line. Such a line has left the composer and is delivery
# of its own kind (_pi_pending_holds), so it is neither transcript content
# (the transcript region must not confirm a queued message's full text or
# stand in for its truncated head) nor composer content.
_pi_pending_row() { # $1=pane line
  local s=${1#"${1%%[![:space:]]*}"}
  case $s in
    'Steering: '*|'Follow-up: '*) return 0 ;;
  esac
  return 1
}

# Split one capture of a pi TUI pane into its regions. Reads the capture on
# stdin and sets globals — the caller needs every region from ONE capture
# (the pane changes between polls, so per-region captures could race):
#
#   _pi_layout  1 when the capture shows pi's TUI: a box-drawing border line
#               (pi's status border) within six lines above the pane's last
#               non-empty line (the stats bar). 0 otherwise — a shell, a
#               mid-boot or foreign TUI: "no submission evidence possible".
#   _pi_comp    flattened composer region: the run of non-blank, non-chrome
#               lines directly above that border, bounded to
#               _PI_COMP_MAX_LINES. Its bottom edge is the lowest non-blank
#               line within _PI_COMP_SCAN_LINES above the border, so a not yet
#               drawn composer top border (a blank line between text and
#               border) no longer collapses the region — which used to push a
#               parked line into the transcript. Empty when the composer is
#               empty (pi draws a blank row there).
#   _pi_trans   flattened transcript region: everything above that block.
#   _pi_below   flattened region below the border (pi's path/stats bar —
#               and, on a pane that merely looks like pi, the shell prompt
#               line where the typed text sits).
#   _pi_all     flattened whole capture.
#
# The regions are what "parked" vs "submitted" means: a prompt that is in
# _pi_comp is unsent; a prompt that left _pi_comp and shows up in _pi_trans
# was received. They are deliberately fuzzy in the safe direction — a line the
# model cannot place must stay *unknown*, never "sent" — and the parser never
# guesses from elapsed time or bare pane activity: an unrecognized layout
# reports _pi_layout=0 with empty regions so callers treat it as "no
# evidence", never as success.
_pi_parse_regions() {
  local -a L=()
  local last=-1 b=-1 top j i n s line
  _pi_layout=0 _pi_comp='' _pi_trans='' _pi_below='' _pi_all='' _pi_pending=''
  mapfile -t L
  _pi_all=$(printf '%s\n' "${L[@]}" | tr -d '[:space:]')
  # pi's pending-message display: one `Steering: <text>` (or `Follow-up: `)
  # line per message queued behind a running turn. A line shown there has
  # left the composer and will be injected as a turn — a delivery region of
  # its own (_pi_pending_holds) — flattened per line, with pi's marker
  # stripped, so a head probe can never match across two queued messages.
  for line in ${L[@]+"${L[@]}"}; do
    if _pi_pending_row "$line"; then
      line=${line#"${line%%[![:space:]]*}"}
      _pi_pending+=$(printf '%s' "${line#*: }" | tr -d '[:space:]')$'\n'
    fi
  done
  for (( i = ${#L[@]} - 1; i >= 0; i-- )); do
    if [[ ${L[i]} == *[![:space:]]* ]]; then last=$i; break; fi
  done
  # Status border: the lowest box-drawing line near the bottom. Byte-exact
  # dash stripping keeps this locale-independent (the system awk is mawk,
  # whose multibyte regexes would misfire — hence pure bash + tr here).
  if (( last > 0 )); then
    for (( i = last - 1; i >= 0 && i >= last - 6; i-- )); do
      if _pi_dash_row "${L[i]}"; then b=$i; break; fi
    done
  fi
  [ "$b" -ge 0 ] || return 0
  _pi_layout=1
  # Composer bottom edge: the lowest non-blank line within _PI_COMP_SCAN_LINES
  # above the border (skipping the blank row pi leaves for an empty composer
  # and, transiently, the missing composer top border). Chrome (the working
  # row) there means the composer is empty.
  top=$b
  j=-1
  for (( i = b - 1; i >= 0 && i > b - 1 - _PI_COMP_SCAN_LINES; i-- )); do
    [ -n "${L[i]//[[:space:]]/}" ] || continue
    j=$i
    break
  done
  if (( j >= 0 )) && ! _pi_chrome_row "${L[j]}"; then
    # Walk up from that edge while the lines are content, bounded: a parked
    # line pushes the spinner row (chrome) up into the block, and a transcript
    # running into the border must not be swallowed whole.
    top=$j
    n=1
    while (( n < _PI_COMP_MAX_LINES )); do
      (( top > 0 )) || break
      s=${L[top-1]//[[:space:]]/}
      [ -n "$s" ] || break
      if _pi_chrome_row "${L[top-1]}"; then break; fi
      top=$((top-1))
      n=$((n+1))
    done
  fi
  for (( i = top; i < b; i++ )); do _pi_comp+=${L[i]}; done
  for (( i = 0; i < top; i++ )); do
    # A pending line is a delivery region of its own: leaving it in the
    # transcript would let the full text of a short queued message satisfy
    # _pi_submission_evidence, and the pending region already answers whether
    # a queued copy belongs to this send.
    _pi_pending_row "${L[i]}" && continue
    _pi_trans+=${L[i]}
  done
  for (( i = b + 1; i < ${#L[@]}; i++ )); do _pi_below+=${L[i]}; done
  _pi_comp=$(printf '%s' "$_pi_comp" | tr -d '[:space:]')
  _pi_trans=$(printf '%s' "$_pi_trans" | tr -d '[:space:]')
  _pi_below=$(printf '%s' "$_pi_below" | tr -d '[:space:]')
  return 0
}

# Fill the _pi_* globals from a live pane capture. Never fails: a failed
# capture clears them (layout 0 = "no evidence"), so a dead target can never
# confirm a send with stale regions.
_pi_regions_of() { # $1=tmux target
  local cap
  if cap=$(tmux capture-pane -t "$1" -p 2>/dev/null); then
    _pi_parse_regions <<<"$cap"
  else
    _pi_layout=0 _pi_comp='' _pi_trans='' _pi_below='' _pi_all='' _pi_pending=''
  fi
  return 0
}

# True when the pane currently holds the line in pi's composer — the prompt
# is parked (unsent). Needs a recognized layout; "no evidence" is false.
_pi_composer_holds() {
  [ "$_pi_layout" = 1 ] && _has_probe "$_pi_comp"
}

# True when the pane shows the line in pi's pending-message display: it left
# the composer, pi accepted it into the steering queue, and it will be
# injected as a turn. That is the delivered-PENDING state of a send — the
# only evidence available while the orchestrator is mid-turn, because pi
# truncates the queued message to one line and the tail probe can never
# match. Confirming it is what keeps an unconfirmed-notice retry from
# appending the same notice to the queue again and again (2026-10-18).
#
# A copy still in the composer blocks the evidence whatever the pending
# display shows: a parked line was never delivered, and an older queued copy
# of the same message must not confirm it. Both probe sets are checked — pi's
# editor scrolls a long typed line, so either its head or its tail is the
# visible part. "Holds" does not by itself mean THIS send queued the line:
# the caller compares _pi_pending_head_count across the send, so a pre-existing
# same-head pending copy cannot confirm it (test [REQ-8]).
_pi_pending_holds() {
  [ "$_pi_layout" = 1 ] || return 1
  [ -n "$_pi_pending" ] || return 1
  _has_probe "$_pi_comp" && return 1
  _has_head_probe "$_pi_comp" && return 1
  _has_head_probe "$_pi_pending"
}

# True when the pane shows submission evidence for the line: it left the
# composer and appears in the transcript region. Pane activity, redraws and
# completion mutations never satisfy this. It is the ONLY success condition
# on a pi pane — an empty Enter against an already-submitted line leaves the
# evidence in place, so the check is safe to evaluate from any capture.
#
# It relies on one property of pi's renderer: the user turn is echoed into the
# transcript verbatim (at least its tail — which is all the probe matches). A
# renderer that folds or truncates the turn would turn a submitted line into
# "vanished" and re-type it.
#
# Any probe form counts as the submitted line (a shell-escaped launch line
# reaches pi unescaped), but a form sitting in the composer blocks the evidence
# whatever else matches: a parked line is never evidence, which is the
# never-strand rule.
_pi_submission_evidence() {
  [ "$_pi_layout" = 1 ] || return 1
  # Any probe form counts as the submitted line — pi never receives the shell's
  # backslashes — but a form sitting in the composer blocks the evidence
  # whatever else matches: a parked line is never evidence, which is the
  # never-strand rule.
  _has_probe "$_pi_comp" && return 1
  _has_probe "$_pi_trans"
}

# True when the capture shows pi's box-drawing chrome but no resolvable status
# border — an incomplete frame of a pi TUI, not a shell. Confirming such a pane
# from "the pane changed" is the 2026-10-02 false success waiting to happen, so
# it is treated as a pi pane (evidence only). The shell-launch panes of
# start-main.sh / sub-spawn.sh are brand-new tmux sessions whose only output is
# the prompt, so this never fires there; where it does misfire the cost is a
# loud failure, never a silent "sent".
_pi_unresolved_pi_pane() { # $1=flattened capture
  [ "$_pi_layout" = 0 ] && grep -q -- '─' <<<"$1"
}

# Type a line into a tmux pane and make sure it actually runs.
#
# A bare `send-keys -l` + `Enter` races the target TUI's startup: pi can be
# mid-redraw (slow extension init, model switch, compaction) when the Enter
# arrives, and the keystroke is dropped, leaving the text parked in the
# composer. Seeing the text — or any pane change — is NOT proof of
# submission (a busy redraw changes the pane too), so this helper confirms
# positively, per pane kind:
#
#   * pi's TUI (status-border layout, see _pi_parse_regions), the `auto`
#     expectation: success needs submission evidence — the line left the
#     composer region and appears in the transcript region. While the line
#     sits in the composer, Enter is retried (bounded by [attempts]) no matter
#     what else the pane does. A line that vanishes from the pane without ever
#     reaching the transcript (TUI reset / compaction wipe) is typed once more;
#     a second vanish or exhausted attempts fails.
#   * any other pane (a shell — the start-main.sh / sub-spawn.sh launch
#     path, where the typed line lives at the prompt, below pi's border):
#     the legacy confirmation — the pane content changed after an Enter.
#
# The [expectation] argument (5th) says which of the two panes the caller is
# typing into:
#
#   auto    (default) decide from the capture, as above: a capture that
#           resolves as pi's TUI escalates to transcript evidence.
#   shell   the caller types a SHELL command into a fresh shell pane (the
#           launch lines of sub-spawn.sh / start-main.sh). The confirmation
#           stays the shell one — the pane changed after the Enter — and never
#           escalates: a launch line is not a composer message and can never
#           appear in pi's transcript, and a fast-booting pi turned the strict
#           rule into a guaranteed failure (2026-10-18: three spawns rolled
#           back, each re-typing the launch command into the running pi). It
#           also never re-types: that retype is only reachable through the
#           strict path. Declaring the pane kind is what keeps the guarantee
#           honest; guessing it from the text would not.
#
# Either way a change is never evidence while the text is shown parked in a pi
# composer, and Enter keeps being retried — the shell expectation strands
# nothing either.
#
# Returns 0 only when confirmed submitted. Returns 1 when it could not be
# confirmed. Callers decide what an unconfirmed send means for them; the sub-*
# scripts treat it as fatal so a stranded line can never be reported as
# delivered.
#
# NEVER STRAND A PROMPT: as long as the text is visible in the pane — or its
# bytes may still be rendering there — the helper presses Enter before it can
# give up. A region boundary is fuzzy (pi redraws between the typing and the
# capture), so visible-but-unplaced text is UNKNOWN, never "sent" — abandoning
# it is what left an instruction parked in pi-riak-250-review's composer on
# 2026-10-17. An Enter against an already-submitted line is harmless; a prompt
# nobody submits is not.
tmux_send_line() { # $1=tmux target $2=text [attempts] [settle seconds] [expectation]
  local target=$1 text=$2 attempts=${3:-4} settle=${4:-1} expect=${5:-auto}
  local before after i strict=0 retyped=0 typed=0 entered=0 pending_before
  # An unknown expectation is a caller bug, and degrading it to 'auto' would
  # reproduce the very failure this argument exists to prevent (2026-10-18):
  # a typo would silently drop the shell confirmation.
  case $expect in
    auto|shell) ;;
    *) die "tmux_send_line: unknown expectation '$expect' for $target (auto|shell)" ;;
  esac
  # Evidence is looked for in both the literal typed text and the form the
  # shell hands to the program: pi never sees the backslashes (see _set_probes).
  _set_probes "$text"
  # The pending display truncates a queued message to one line, so it is
  # matched by the head probes instead (see _set_head_probes).
  _set_head_probes "$text"
  if [ -z "${_PI_PROBES[0]:-}" ]; then
    warn "nothing to send to $target (empty line)"
    return 1
  fi
  if _has_probe "$(_pane_flattened "$target")"; then
    warn "the text was already visible in $target before typing — the confirmation below may be satisfied by that copy rather than by this send"
  fi
  # 1) Type the line until it renders somewhere in the pane.
  for (( i = 0; i < _PI_TYPE_ATTEMPTS; i++ )); do
    tmux send-keys -t "$target" -l "$text"
    typed=$((typed + 1))
    if _pi_visible "$target"; then break; fi
    warn "text not visible in $target yet; retyping"
  done
  if ! _pi_visible "$target"; then
    # The bytes are already in the pane's input queue, so the composer may
    # render this line a frame later: press Enter rather than abandon it. This
    # is the last-resort Enter of the never-strand rule — the helper still
    # fails, because nothing here is evidence that the line was submitted.
    tmux send-keys -t "$target" Enter
    entered=1
    warn "the text never rendered in $target after typing it ${typed} time(s) — Enter sent anyway in case it renders late; check the pane"
    return 1
  fi
  # 2) Decide from where the text landed what may confirm the send. On a pi
  #    pane the line belongs in the composer, so it is parked there; when the
  #    regions cannot place it (composer and transcript indistinguishable after
  #    a redraw) the state is UNKNOWN and handled exactly like parked: Enter,
  #    then evidence. Never a bail-out before the first Enter. Only text BELOW
  #    pi's border is the shell-launch case (a prompt of a pane that merely
  #    looks like pi), which keeps the legacy change check — and a shell
  #    expectation keeps it whatever the pane does afterwards.
  _pi_regions_of "$target"
  if [ "$expect" = auto ]; then
    if [ "$_pi_layout" = 1 ] && ! _has_probe "$_pi_below"; then
      strict=1
    elif _pi_unresolved_pi_pane "$_pi_all"; then
      strict=1
    fi
  fi
  before=$_pi_all   # baseline from the decision capture (same pane, no re-capture)
  # How many queued copies of this line the pending display already held
  # BEFORE this send's Enters: only growth beyond it may confirm the send, so
  # an older message whose head merely collides with this one never passes for
  # it (nothing else about a truncated pending line identifies a send).
  pending_before=$(_pi_pending_head_count "$_pi_pending")
  for (( i = 0; i < attempts; i++ )); do
    tmux send-keys -t "$target" Enter
    entered=$((entered + 1))
    sleep "$settle"
    _pi_regions_of "$target"
    if [ "$expect" = auto ]; then
      # Escalate the moment a capture places the line inside pi's TUI — even a
      # send that started out generic must never be confirmed generically while
      # the line may be parked in a composer (this also recovers a pane whose
      # first capture was an incomplete frame: one later capture that resolves
      # the layout latches strict mode for the rest of the send).
      if [ "$_pi_layout" = 1 ] && ! _has_probe "$_pi_below"; then
        strict=1
      elif _pi_unresolved_pi_pane "$_pi_all"; then
        strict=1
      fi
    fi
    if [ "$strict" = 1 ]; then
      # Layout lost (mid-redraw / dead target): no evidence, retry bounded.
      if [ "$_pi_layout" = 1 ]; then
        # Positive evidence: the line left the composer and reached the transcript.
        if _pi_submission_evidence; then
          return 0
        fi
        # Queued behind a running turn: the line left the composer and pi's
        # pending display shows its head. The message is not lost — pi injects
        # it as a turn — so this is delivery, and confirming it here is what
        # stops a retry from appending the same notice to the queue again.
        # Checked before the vanish path: a queued line IS gone from the pane
        # as far as the tail probe can tell, and must not be re-typed.
        # The head alone is not enough: the queued copy must be one this send
        # added (count above the pre-Enter baseline), or an older same-head
        # message would confirm a line that actually vanished.
        if _pi_pending_holds \
           && [ "$(_pi_pending_head_count "$_pi_pending")" -gt "$pending_before" ]; then
          return 0
        fi
        # Gone from the whole pane without ever reaching the transcript:
        # a TUI reset wiped it — type it once more, then stay strict. One
        # quick re-capture first: a merely LATE transcript render must not
        # lead to a duplicate line. Unreachable for a shell expectation: that
        # one never latches strict mode, so a launch command can never be
        # typed into a pi that has since booted.
        if ! _has_probe "$_pi_all"; then
          sleep "$_PI_VANISH_RECHECK"
          _pi_regions_of "$target"
          if _pi_submission_evidence; then
            return 0 # the transcript render was only slow — submitted
          fi
          if _has_probe "$_pi_all"; then
            continue # the line is back (TUI restored it): parked again
          fi
          if [ "$retyped" -ge 1 ]; then
            warn "the prompt vanished from $target again — not claiming it was sent"
            return 1
          fi
          retyped=1
          warn "the prompt vanished from $target without reaching the transcript; retyping"
          tmux send-keys -t "$target" -l "$text"
          typed=$((typed + 1))
          sleep "$_PI_TYPE_SETTLE"
        fi
      fi
      continue # still parked (or no evidence yet): retry Enter
    fi
    # Shell-like pane: legacy confirmation on the same capture, guarded so a
    # pane that turns out to hold a parked pi composer can never satisfy it —
    # with the shell expectation this is the only way back to a retried Enter,
    # so nothing is ever stranded there either.
    if _pi_composer_holds; then
      before=$_pi_all
      continue
    fi
    if [ -n "$_pi_all" ]; then
      after=$_pi_all
      if [ "$after" != "$before" ]; then return 0; fi
      before=$after
    fi
  done
  warn "could not confirm that $target submitted the line: typed it ${typed} time(s), sent Enter ${entered} time(s) — it may still be parked in $target's composer; check the pane"
  return 1
}

# Type a SHELL COMMAND into a fresh shell pane and confirm it ran — the launch
# path of sub-spawn.sh / start-main.sh. The wrapper owns the knobs such a send
# needs (the bounded Enter retries and the shell expectation), so no caller
# learns them: restating them at every call site is how a launch would quietly
# lose its confirmation.
tmux_send_shell_line() { # $1=tmux target $2=text [attempts] [settle seconds]
  tmux_send_line "$1" "$2" "${3:-4}" "${4:-1}" shell
}

# ---------------------------------------------------------------------------
# Pane probes
#
# Every probe exists twice: `<name>_in <session> …` takes a tmux target — a
# child's `pi-<task>` session, or any other session (the orchestrator watcher
# passes its exact `=<session>:` pane target) — and `<name> <task> …` resolves
# the task's child session through session_of. The wrappers are the whole child
# surface and behave exactly as before the split; a caller that is not
# addressing a child uses the `_in` form instead of inventing a task name.
# ---------------------------------------------------------------------------

# Tail of a session's pane (trailing blank lines dropped), or a note when it
# isn't running.
pane_tail_in() { # $1=session $2=lines
  local sess=$1
  if tmux has-session -t "$sess" 2>/dev/null; then
    tmux capture-pane -t "$sess" -p | awk -v n="$2" '
      { if ($0 ~ /[^[:space:]]/) last=NR; line[NR]=$0 }
      END { start=last-n+1; if (start<1) start=1
            for (i=start; i<=last; i++) print line[i] }'
  else
    info "(tmux session $sess is not running)"
  fi
}

# Tail of the task's tmux pane.
pane_tail() { # $1=task $2=lines
  pane_tail_in "$(session_of "$1")" "$2"
}

# Signature of pi's free-provider failures in a pane: the JSON error type of
# either kind — FreeUsageLimitError (HTTP 429 quota exhaustion, terminal for
# pi) or FreeTierError (HTTP 403 rejecting the free tier, which wedges the
# child by blocking pi's compaction/summarization calls) — or an HTTP 429
# next to rate-limit wording. Deliberately textual (there is no other
# channel into a running TUI), so callers scan a bounded pane window instead
# of the whole scrollback.
_FALLBACK_ERROR_RE='FreeUsageLimitError|FreeTierError|(^|[^0-9])429([^0-9]|$).*([Rr]ate[ -]?limit|[Tt]oo [Mm]any [Rr]equests)'

# True when a session's pane tail shows a free-provider failure.
pane_has_free_limit_error_in() { # $1=session [$2=scan lines]
  local sess=$1 lines=${2:-50}
  pane_tail_in "$sess" "$lines" | grep -qE -- "$_FALLBACK_ERROR_RE"
}

# True when the task's pane tail shows a free-provider failure.
pane_has_free_limit_error() { # $1=task [$2=scan lines]
  pane_has_free_limit_error_in "$(session_of "$1")" "${2:-50}"
}

# True when the task's pane tail shows pi rejecting a thinking level the
# current model does not support (configured fallbackThinking drift).
_FALLBACK_THINKING_ERROR_RE='Error: Unknown thinking level'

# True when a session's pane tail shows that rejection.
pane_thinking_level_rejected_in() { # $1=session [$2=scan lines]
  local sess=$1 lines=${2:-50}
  pane_tail_in "$sess" "$lines" | grep -qF -- "$_FALLBACK_THINKING_ERROR_RE"
}

# Echo the last non-empty line currently shown in a session's pane — pi draws
# its status bar (path, token stats, model • thinking) there. Nothing when the
# session is not running.
pane_last_line_in() { # $1=session
  local sess=$1
  tmux has-session -t "$sess" 2>/dev/null || return 0
  tmux capture-pane -t "$sess" -p 2>/dev/null \
    | awk 'NF { last=$0 } END { if (last != "") print last }'
}

# True when the task's status bar shows the model. pi renders the model id
# (the part after the final "/") there, not the provider-qualified name.
# The id must appear as a delimited token — preceded by start-of-line or a
# character outside the model-id alphabet [A-Za-z0-9._-], and followed by
# end-of-line or a character outside it (in the footer the id sits between
# "(provider) " and " • level"). A fixed substring match would read the free
# variant "mimo-v2.6-flash-free" as "mimo-v2.6-flash" (a strict prefix) and
# wrongly report the child as already on the fallback model.
pane_shows_model_in() { # $1=session $2=model
  local sess=$1 model=$2 last id re
  id=${model##*/}
  [ -n "$id" ] || return 1
  last=$(pane_last_line_in "$sess")
  [ -n "$last" ] || return 1
  # Escape everything outside the id alphabet so the id matches literally.
  re=$(printf '%s' "$id" | sed 's/[^A-Za-z0-9_-]/\\&/g')
  grep -qE "(^|[^A-Za-z0-9._-])${re}([^A-Za-z0-9._-]|$)" <<<"$last"
}

# True when the task's status bar shows the thinking level. pi renders it
# after a bullet ("model • max"); "off" renders as "model • thinking off".
pane_shows_thinking_in() { # $1=session $2=level
  local last
  last=$(pane_last_line_in "$1")
  [ -n "$last" ] || return 1
  if [ "$2" = off ]; then
    grep -qF -- '• thinking off' <<<"$last"
  else
    grep -qF -- "• $2" <<<"$last"
  fi
}

# ---------------------------------------------------------------------------
# Free-provider recovery mechanics
#
# Shared by sub-fallback.sh (recovering a child) and main-watch.sh (recovering
# the orchestrator's own session). The *policy* — which pane text counts as the
# failure, and when an attempt is due — stays with each caller: the child
# re-checks its pane with the loose probe, the orchestrator watcher uses its
# strict `Error: ` banner detector. Only the mechanics below are shared, so a
# change to the switch or its confirmation can never fix one caller and miss
# the other. The timing knobs are the child helper's own
# (FALLBACK_PROBE_ATTEMPTS, FALLBACK_PROBE_DELAY, FALLBACK_SEND_ATTEMPTS); the
# values below apply when a caller does not set them.
# ---------------------------------------------------------------------------

# Discard whatever is left in the composer after a send that could not be
# confirmed, so a parked slash command can never be submitted later by an
# unrelated Enter (pi's editor deleteToLineStart binding is ctrl+u).
clear_composer() { # $1=tmux target
  tmux send-keys -t "$1" C-u 2>/dev/null || true
}

# Wait for a switch to show up in the status bar, nudging the verified line
# with bare Enters while it has not. tmux_send_line confirms the pane reacted
# to Enter, but pi's argument completion can consume an Enter as "close the
# popup" without submitting the command (observed in a real TUI: the pane
# changes, the line stays in the composer). The status bar is the ground
# truth, so poll it; the nudged line was just verified present, so an extra
# Enter cannot submit anything else.
confirm_model_in() { # $1=tmux target $2=model
  local target=$1 model=$2 attempt i
  local attempts=${FALLBACK_SEND_ATTEMPTS:-4} tries=${FALLBACK_PROBE_ATTEMPTS:-10} delay=${FALLBACK_PROBE_DELAY:-0.5}
  for (( attempt = 0; attempt <= attempts; attempt++ )); do
    if [ "$attempt" -gt 0 ]; then
      tmux send-keys -t "$target" Enter
      sleep "$delay"
    fi
    for (( i = 0; i < tries; i++ )); do
      pane_shows_model_in "$target" "$model" && return 0
      sleep "$delay"
    done
  done
  return 1
}

# Returns 0 once the level shows in the status bar, 2 when pi rejected it
# (Error: Unknown thinking level — a fallbackThinking that does not match the
# model now in effect, i.e. a config.json problem, not a delivery problem:
# stop instead of nudging a command the TUI will never accept), 1 when it
# could not be confirmed at all.
confirm_thinking_in() { # $1=tmux target $2=thinking $3=scan lines
  local target=$1 thinking=$2 lines=${3:-50} attempt i
  local attempts=${FALLBACK_SEND_ATTEMPTS:-4} tries=${FALLBACK_PROBE_ATTEMPTS:-10} delay=${FALLBACK_PROBE_DELAY:-0.5}
  for (( attempt = 0; attempt <= attempts; attempt++ )); do
    if [ "$attempt" -gt 0 ]; then
      tmux send-keys -t "$target" Enter
      sleep "$delay"
    fi
    for (( i = 0; i < tries; i++ )); do
      pane_shows_thinking_in "$target" "$thinking" && return 0
      pane_thinking_level_rejected_in "$target" "$lines" && return 2
      sleep "$delay"
    done
  done
  return 1
}

# Recover a pane stuck on a free-provider failure: switch pi to $2 through the
# verified send, confirm the switch in the status bar, then apply $3 — a level
# the new model already landed on is left alone, and a thinking problem never
# turns a recovered session into a failed recovery. Never speculative: the
# caller decides that the failure is visible; only the already-on guard here
# can stop a send.
#
# Outcome codes: 0 switched (thinking set, already in effect, or nothing
# configured), 5 already on the fallback model (nothing sent), 1 model switch
# unconfirmed, 2 switch confirmed but /thinking rejected, 3 no fallback model
# configured (nothing sent), 4 switch confirmed but /thinking unconfirmed. The
# composer is cleared on every unconfirmed or rejected path, so a parked slash
# command can never be submitted by a later, unrelated Enter.
free_provider_recover() { # $1=tmux target $2=model $3=thinking $4=scan lines
  local target=$1 model=$2 thinking=$3 lines=${4:-50} t_rc
  # No configured fallback: nothing is or can be sent.
  [ -n "$model" ] || return 3
  # Re-running after a successful (or externally performed) switch is a no-op.
  if pane_shows_model_in "$target" "$model"; then
    info "$target is already on fallback model $model — no model switch performed"
    return 5
  fi
  if tmux_send_line "$target" "/model $model" && confirm_model_in "$target" "$model"; then
    info "switched $target to fallback model $model"
  else
    clear_composer "$target"
    return 1
  fi
  # Thinking comes after the model switch: pi clamps the session's current
  # level to the new model's range on /model, so if the clamp already lands on
  # the configured level there is nothing to send. Otherwise apply it, still
  # confirming against the status bar. This is a refinement, not the recovery —
  # a level pi rejects is reported as the config problem it is, and any other
  # unconfirmed send surfaces as its own outcome.
  [ -n "$thinking" ] || return 0
  if pane_shows_thinking_in "$target" "$thinking"; then
    info "thinking level already $thinking — nothing to change"
    return 0
  fi
  t_rc=0
  if tmux_send_line "$target" "/thinking $thinking"; then
    confirm_thinking_in "$target" "$thinking" "$lines" || t_rc=$?
  else
    t_rc=1
  fi
  case $t_rc in
    0) info "thinking level set to $thinking" ;;
    2) clear_composer "$target"; return 2 ;;
    *) clear_composer "$target"; return 4 ;;
  esac
  return 0
}

# The one place the failure sentences live, so every caller's operator message
# cannot drift: $1 is a free_provider_recover outcome code, $2 the tmux target,
# $3 the fallback model, $4 the noun for the recovered session (default
# `child`), and $5 the thinking level the attempt applied — only the two
# thinking sentences name it, and an absent or empty level keeps the neutral
# wording. The level is an argument, not state: a caller formats a sentence
# from what it passed to the recovery, never from whatever ran last. Callers
# decide whether the sentence is a warning or a hard error.
free_provider_failure_message() { # $1=code $2=target $3=model [$4=role] [$5=thinking]
  local code=$1 target=$2 model=$3 role=${4:-child} level=${5:-the configured level}
  case $code in
    2) printf "%s rejected thinking level '%s' (pi: %s) — fallbackThinking in %s does not match fallbackModel %s; the model switch alone recovered the %s" \
         "$target" "$level" "$_FALLBACK_THINKING_ERROR_RE" "$(levels_config)" "$model" "$role" ;;
    4) printf 'could not confirm /thinking %s in %s — check the pane' \
         "$level" "$target" ;;
    3) printf 'free-provider failure detected in %s, but no fallbackModel is configured in %s — no model switch performed' \
         "$target" "$(levels_config)" ;;
    *) printf 'sent /model %s to %s, but its status bar still does not show it — check the pane' \
         "$model" "$target" ;;
  esac
}
