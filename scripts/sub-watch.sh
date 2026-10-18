#!/usr/bin/env bash
# One watcher per child: runs the Lavish wake-up, the PR action watch, and
# the free-provider stall detector in ONE process and one loop
# (specs/unified-child-watcher/unified-child-watcher.feature).
#
# Armed by sub-spawn.sh in a single `watch` window of the child's tmux
# session, so it dies with the session on retirement. The services keep
# their guarantees: the Lavish wake goes through the verified send and never
# runs `lavish-axi poll`; the PR service only reads GitHub and never types
# into the child's pane; the stall service is notify-only.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_sub-common.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-common.sh"
# shellcheck source=_sub-watch.sh
# shellcheck disable=SC1091  # followed with -x; plain runs must stay clean
source "$SCRIPT_DIR/_sub-watch.sh"

usage() { die "usage: ${0##*/} <task-name> [repo-dir] [branch]"; }

main() {
  if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then usage; fi
  valid_task "$1" || usage
  watch_engine "$1" "${2:-$PWD}" "${3:-}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
