#!/usr/bin/env bash
# Start the orchestrator's main pi session in a tmux session (see AGENTS.md,
# "pi sessions"): create it detached, rooted at the main checkout of this
# repository, launch plain pi, then attach to it. An existing session is
# reported and re-attached, never clobbered; --detach/-d only starts or
# points at it and returns.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
source "$SCRIPT_DIR/_sub-common.sh"

usage() { die "usage: ${0##*/} [--detach|-d]"; }

# Echo the main checkout of the repository this script lives in. The main
# session must be rooted in the main checkout even when the script runs from
# a linked worktree: the repository's shared .git directory lives there.
# Falls back to the script's own repo root when the main checkout cannot be
# determined (e.g. a bare repository).
main_checkout_of() { # $1=dir
  local root common main
  root=$(repo_root "$1")
  if common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
     && main=${common%/.git} \
     && [ "$main" != "$common" ] \
     && [ -d "$common" ] \
     && git -C "$main" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "$main"
  else
    printf '%s\n' "$root"
  fi
}

DETACH=0
for arg in "$@"; do
  case $arg in
    -d|--detach) DETACH=1 ;;
    *) usage ;;
  esac
done

# git resolves the checkout; the pi binary is validated up front so a bad
# invocation fails before any tmux session is touched.
need git tmux "$PI_BIN"

SESS=$MAIN_SESSION   # canonical name is pi-main (see _sub-common.sh)
ROOT=$(main_checkout_of "$SCRIPT_DIR")

# Attach hands the terminal to tmux and returns here once the user detaches;
# --detach callers never reach tmux's terminal handling. TMUX is stripped so
# an invocation from inside another tmux session attaches instead of hitting
# the nested-session refusal (same trick as open_viewer_window).
finish() {
  if [ "$DETACH" = 1 ]; then exit 0; fi
  env -u TMUX tmux attach-session -t "=$SESS"
  exit 0
}

if tmux has-session -t "=$SESS" 2>/dev/null; then
  WHERE=$(tmux display-message -p -t "=$SESS:" '#{pane_current_path}' 2>/dev/null || true)
  if [ "$DETACH" = 1 ]; then
    info "tmux session $SESS already exists (cwd: ${WHERE:-unknown}); leaving it running (--detach)"
  else
    info "tmux session $SESS already exists (cwd: ${WHERE:-unknown}); attaching without restarting it"
  fi
  finish
fi

tmux new-session -d -s "$SESS" -c "$ROOT" \
  || die "could not create tmux session $SESS"
# The whole pattern keys on this exact session name (children address
# notices to it): verify it stuck rather than trusting tmux — a hook or a
# rename must not silently re-target the orchestrator. Window options are
# only ever applied to a session we just created; an existing one is left
# untouched. Both layout calls are best-effort, as in open_viewer_window.
tmux has-session -t "=$SESS" 2>/dev/null \
  || die "tmux session $SESS was not created under its exact name"
tmux set-window-option -t "$SESS:" main-pane-width 50% >/dev/null 2>&1 || true
tmux select-layout -t "$SESS:" main-vertical >/dev/null 2>&1 || true
sleep 0.5
# Plain $PI_BIN, no -n/--no-extensions: the main session is not a child.
# tmux_send_shell_line retries Enter until the launch is confirmed — this pane
# is a shell (no pi TUI yet), and a shell launch line is confirmed by the pane
# changing after the Enter, never by pi transcript evidence it can never
# satisfy. A dropped keystroke still cannot leave the session without pi.
printf -v LAUNCH '%q' "$PI_BIN"
tmux_send_shell_line "$SESS" "$LAUNCH"

if [ "$DETACH" = 1 ]; then
  info "started detached tmux session $SESS (rooted at $ROOT, pi: $PI_BIN); attach with: tmux attach -t $SESS"
else
  info "started tmux session $SESS (rooted at $ROOT, pi: $PI_BIN); attaching (detach with Ctrl-b d)"
fi
finish
