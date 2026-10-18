#!/usr/bin/env bash
# Development entry point for the PR action service of the per-child watcher
# (specs/pr-action-watch/pr-action-watch.feature). `scripts/sub-watch.sh`
# runs all three watching services in one process; this wrapper keeps the
# historical single-service argv and is the regression seam for the PR
# suite, which exercises the same tick the unified watcher runs.
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
  export SUB_WATCH_SERVICES=pr
  watch_engine "$1" "${2:-$PWD}" "${3:-}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
