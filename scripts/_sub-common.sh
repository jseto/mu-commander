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

# Echo the pi command line that boots a child session. The resolved
# model/thinking option words ($3, from resolve_child_launch_flags) sit among
# the options — before the kickoff message argument — so pi parses them as
# options, not as part of the prompt.
pi_launch_command() { # $1=pi-bin $2=task $3=option words $4=kickoff
  if [ -n "${3:-}" ]; then
    printf '%q -n %q --no-extensions %s --approve %q' "$1" "$2" "$3" "$4"
  else
    printf '%q -n %q --no-extensions --approve %q' "$1" "$2" "$4"
  fi
}

# Prepare an isolated Pi agent directory for a child. It preserves non-extension
# resources such as settings metadata, skills, prompts, and themes, but gives
# the child no extensions or packages at all. The directory lives in the
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
  for name in npm node_modules skills prompts themes; do
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

# Split one capture of a pi TUI pane into its regions. Reads the capture on
# stdin and sets globals — the caller needs every region from ONE capture
# (the pane changes between polls, so per-region captures could race):
#
#   _pi_layout  1 when the capture shows pi's TUI: a box-drawing border line
#               (pi's status border) within six lines above the pane's last
#               non-empty line (the stats bar). 0 otherwise — a shell, a
#               mid-boot or foreign TUI: "no submission evidence possible".
#   _pi_comp    flattened composer region: the contiguous non-blank block
#               directly above that border. Empty when the composer is (pi
#               draws a blank line there); a parked line pushes the spinner
#               row up into the block.
#   _pi_trans   flattened transcript region: everything above that block.
#   _pi_below   flattened region below the border (pi's path/stats bar —
#               and, on a pane that merely looks like pi, the shell prompt
#               line where the typed text sits).
#   _pi_all     flattened whole capture.
#
# The regions are what "parked" vs "submitted" means: a prompt that is in
# _pi_comp is unsent; a prompt that left _pi_comp and shows up in _pi_trans
# was received. The parser never guesses from elapsed time or bare pane
# activity — an unrecognized layout reports _pi_layout=0 with empty regions
# so callers treat it as "no evidence", never as success.
_pi_parse_regions() {
  local -a L=()
  local last=-1 b=-1 top i s
  _pi_layout=0 _pi_comp='' _pi_trans='' _pi_below='' _pi_all=''
  mapfile -t L
  _pi_all=$(printf '%s\n' "${L[@]}" | tr -d '[:space:]')
  for (( i = ${#L[@]} - 1; i >= 0; i-- )); do
    if [[ ${L[i]} == *[![:space:]]* ]]; then last=$i; break; fi
  done
  # Status border: the lowest box-drawing line near the bottom. Byte-exact
  # dash stripping keeps this locale-independent (the system awk is mawk,
  # whose multibyte regexes would misfire — hence pure bash + tr here).
  if (( last > 0 )); then
    for (( i = last - 1; i >= 0 && i >= last - 6; i-- )); do
      s=${L[i]//[[:space:]]/}
      [ -n "$s" ] || continue
      if [ -z "${s//─/}" ]; then b=$i; break; fi
    done
  fi
  [ "$b" -ge 0 ] || return 0
  _pi_layout=1
  top=$b
  for (( i = b - 1; i >= 0; i-- )); do
    [[ ${L[i]} == *[![:space:]]* ]] || break
    top=$i
  done
  for (( i = top; i < b; i++ )); do _pi_comp+=${L[i]}; done
  for (( i = 0; i < top; i++ )); do _pi_trans+=${L[i]}; done
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
    _pi_layout=0 _pi_comp='' _pi_trans='' _pi_below='' _pi_all=''
  fi
  return 0
}

# True when the pane currently holds the line in pi's composer — the prompt
# is parked (unsent). Needs a recognized layout; "no evidence" is false.
_pi_composer_holds() { # $1=probe
  [ "$_pi_layout" = 1 ] && grep -qF -- "$1" <<<"$_pi_comp"
}

# True when the pane shows submission evidence for the line: it left the
# composer and appears in the transcript region. Pane activity, redraws and
# completion mutations never satisfy this.
_pi_submission_evidence() { # $1=probe
  [ "$_pi_layout" = 1 ] \
    && grep -qF -- "$1" <<<"$_pi_trans" \
    && ! grep -qF -- "$1" <<<"$_pi_comp"
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
#   * pi's TUI (status-border layout, see _pi_parse_regions): success needs
#     submission evidence — the line left the composer region and appears in
#     the transcript region. While the line sits in the composer, Enter is
#     retried (bounded by [attempts]) no matter what else the pane does. A
#     line that vanishes from the pane without ever reaching the transcript
#     (TUI reset / compaction wipe) is typed once more; a second vanish or
#     exhausted attempts fails.
#   * any other pane (a shell — the start-main.sh / sub-spawn.sh launch
#     path, where the typed line lives at the prompt, below pi's border):
#     the legacy confirmation — the pane content changed after an Enter.
#
# Returns 0 only when confirmed submitted. Returns 1 when it could not be
# confirmed: the text never appeared after re-typing, the line stayed parked
# through every Enter retry, the prompt vanished twice, or send-keys itself
# failed (target gone). Callers decide what an unconfirmed send means for
# them; the sub-* scripts treat it as fatal so a stranded line can never be
# reported as delivered.
tmux_send_line() { # $1=tmux target $2=text [attempts] [settle seconds]
  local target=$1 text=$2 attempts=${3:-4} settle=${4:-1}
  local probe before after i strict=0 retyped=0
  probe=$(_flatten "$text")
  # Both regions are bottom-anchored (the composer and the newest transcript
  # line sit at the pane's foot), so the tail survives pane wrapping and
  # scrollback even when the head of a long line is out of view. Bash's
  # ${var: -60} yields an EMPTY string for strings shorter than 60, so clamp
  # to the full text instead of silently probing for "".
  if [ ${#probe} -gt 60 ]; then probe=${probe: -60}; fi
  if [ -z "$probe" ]; then
    warn "nothing to send to $target (empty line)"
    return 1
  fi
  # 1) Type the line until it is visible somewhere in the pane.
  for (( i = 0; i < 2; i++ )); do
    tmux send-keys -t "$target" -l "$text"
    sleep 0.4
    if _pane_flattened "$target" | grep -qF -- "$probe"; then break; fi
    warn "text not visible in $target yet; retyping"
  done
  if ! _pane_flattened "$target" | grep -qF -- "$probe"; then
    warn "the text never appeared in $target — not claiming it was sent"
    return 1
  fi
  # 2) Decide from where the text landed what may confirm the send. On a pi
  #    pane the typed line belongs in the composer; a copy seen anywhere else
  #    predates this send (or is a coincidence), so there is nothing to
  #    confirm. Below the border, or on a pane without the layout, is the
  #    shell-launch case: legacy change check.
  _pi_regions_of "$target"
  if [ "$_pi_layout" = 1 ]; then
    if _pi_composer_holds "$probe"; then
      strict=1
    elif grep -qF -- "$probe" <<<"$_pi_trans"; then
      warn "the visible copy of the text in $target is in the transcript, not the composer — not claiming this send"
      return 1
    elif ! grep -qF -- "$probe" <<<"$_pi_below"; then
      warn "the text never reached $target's composer — not claiming it was sent"
      return 1
    fi
  fi
  before=$_pi_all   # baseline from the decision capture (same pane, no re-capture)
  for (( i = 0; i < attempts; i++ )); do
    tmux send-keys -t "$target" Enter
    sleep "$settle"
    _pi_regions_of "$target"
    # Escalate the moment the line is seen inside a pi composer — even a send
    # that started out generic must never be confirmed while parked.
    if _pi_composer_holds "$probe"; then
      strict=1
    fi
    if [ "$strict" = 1 ]; then
      # Layout lost (mid-redraw / dead target): no evidence, retry bounded.
      if [ "$_pi_layout" = 1 ]; then
        # Positive evidence: the line left the composer and reached the transcript.
        if _pi_submission_evidence "$probe"; then
          return 0
        fi
        # Gone from the whole pane without ever reaching the transcript:
        # a TUI reset wiped it — type it once more, then stay strict. One
        # quick re-capture first: a merely LATE transcript render must not
        # lead to a duplicate line.
        if ! grep -qF -- "$probe" <<<"$_pi_all"; then
          sleep 0.2
          _pi_regions_of "$target"
          if _pi_submission_evidence "$probe"; then
            return 0 # the transcript render was only slow — submitted
          fi
          if grep -qF -- "$probe" <<<"$_pi_all"; then
            continue # the line is back (TUI restored it): parked again
          fi
          if [ "$retyped" -ge 1 ]; then
            warn "the prompt vanished from $target again — not claiming it was sent"
            return 1
          fi
          retyped=1
          warn "the prompt vanished from $target without reaching the transcript; retyping"
          tmux send-keys -t "$target" -l "$text"
          sleep 0.4
        fi
      fi
      continue # still parked (or no evidence yet): retry Enter
    fi
    # Shell-like pane: legacy confirmation on the same capture, guarded so a
    # pane that turns out to hold a parked pi composer can never satisfy it.
    if [ -n "$_pi_all" ]; then
      after=$_pi_all
      if [ "$after" != "$before" ]; then return 0; fi
      before=$after
    fi
  done
  warn "could not confirm that $target submitted the line; check the pane"
  return 1
}

# Tail of the task's tmux pane (trailing blank lines dropped), or a note
# when it isn't running.
pane_tail() { # $1=task $2=lines
  local sess
  sess=$(session_of "$1")
  if tmux has-session -t "$sess" 2>/dev/null; then
    tmux capture-pane -t "$sess" -p | awk -v n="$2" '
      { if ($0 ~ /[^[:space:]]/) last=NR; line[NR]=$0 }
      END { start=last-n+1; if (start<1) start=1
            for (i=start; i<=last; i++) print line[i] }'
  else
    info "(tmux session $sess is not running)"
  fi
}

# Signature of pi's free-provider failures in a pane: the JSON error type of
# either kind — FreeUsageLimitError (HTTP 429 quota exhaustion, terminal for
# pi) or FreeTierError (HTTP 403 rejecting the free tier, which wedges the
# child by blocking pi's compaction/summarization calls) — or an HTTP 429
# next to rate-limit wording. Deliberately textual (there is no other
# channel into a running TUI), so callers scan a bounded pane window instead
# of the whole scrollback.
_FALLBACK_ERROR_RE='FreeUsageLimitError|FreeTierError|(^|[^0-9])429([^0-9]|$).*([Rr]ate[ -]?limit|[Tt]oo [Mm]any [Rr]equests)'

# Echo the last non-empty line currently shown in the task's pane — pi draws
# its status bar (path, token stats, model • thinking) there. Nothing when
# the session is not running.
pane_last_line() { # $1=task
  local sess
  sess=$(session_of "$1")
  tmux has-session -t "$sess" 2>/dev/null || return 0
  tmux capture-pane -t "$sess" -p 2>/dev/null \
    | awk 'NF { last=$0 } END { if (last != "") print last }'
}

# True when the task's pane tail shows a free-provider failure.
pane_has_free_limit_error() { # $1=task [$2=scan lines]
  local task=$1 lines=${2:-50}
  pane_tail "$task" "$lines" | grep -qE -- "$_FALLBACK_ERROR_RE"
}

# True when the task's pane tail shows pi rejecting a thinking level the
# current model does not support (configured fallbackThinking drift).
_FALLBACK_THINKING_ERROR_RE='Error: Unknown thinking level'

pane_thinking_level_rejected() { # $1=task [$2=scan lines]
  local task=$1 lines=${2:-50}
  pane_tail "$task" "$lines" | grep -qF -- "$_FALLBACK_THINKING_ERROR_RE"
}

# True when the task's status bar shows the model. pi renders the model id
# (the part after the final "/") there, not the provider-qualified name.
# The id must appear as a delimited token — preceded by start-of-line or a
# character outside the model-id alphabet [A-Za-z0-9._-], and followed by
# end-of-line or a character outside it (in the footer the id sits between
# "(provider) " and " • level"). A fixed substring match would read the free
# variant "mimo-v2.6-flash-free" as "mimo-v2.6-flash" (a strict prefix) and
# wrongly report the child as already on the fallback model.
pane_shows_model() { # $1=task $2=model
  local task=$1 model=$2 last id re
  id=${model##*/}
  [ -n "$id" ] || return 1
  last=$(pane_last_line "$task")
  [ -n "$last" ] || return 1
  # Escape everything outside the id alphabet so the id matches literally.
  re=$(printf '%s' "$id" | sed 's/[^A-Za-z0-9_-]/\\&/g')
  grep -qE "(^|[^A-Za-z0-9._-])${re}([^A-Za-z0-9._-]|$)" <<<"$last"
}

# True when the task's status bar shows the thinking level. pi renders it
# after a bullet ("model • max"); "off" renders as "model • thinking off".
pane_shows_thinking() { # $1=task $2=level
  local last
  last=$(pane_last_line "$1")
  [ -n "$last" ] || return 1
  if [ "$2" = off ]; then
    grep -qF -- '• thinking off' <<<"$last"
  else
    grep -qF -- "• $2" <<<"$last"
  fi
}
