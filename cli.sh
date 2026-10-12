#!/usr/bin/env bash
# Routes `github-scripts <command>` (or `ghs <command>`) to the matching report in bin/.
set -euo pipefail
ROOT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$ROOT_DIR/lib/common.sh"

# "alias command" pairs; bash 3.2 has no associative arrays.
ALIASES=("issues backlog" "pr pull-requests" "runs pipeline-runs")

usage() {
  local name
  name="$(basename "$0")"
  echo "Usage: $name <command> [options]"
  echo
  echo "Terminal reports for GitHub repositories, built on the gh CLI."
  echo
  echo "Commands:"
  local script
  for script in "$ROOT_DIR"/bin/*.sh; do
    printf '  %-15s %s\n' "$(basename "$script" .sh)" "$(sed -n '2s/^# //p' "$script")"
  done
  echo
  echo "Aliases:"
  local pair
  for pair in "${ALIASES[@]}"; do
    printf '  %-15s %s\n' "${pair%% *}" "${pair#* }"
  done
  echo
  echo "Run '$name <command> --help' for the options of a command."
}

# Prints the command an alias stands for, or the name unchanged.
resolve_alias() {
  local pair
  for pair in "${ALIASES[@]}"; do
    if [[ "${pair%% *}" == "$1" ]]; then
      echo "${pair#* }"
      return
    fi
  done
  echo "$1"
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi
case "$1" in
  -h | --help) usage; exit 0 ;;
  help)
    if [[ $# -lt 2 ]]; then usage; exit 0; fi
    set -- "$2" --help
    ;;
esac

command="$(resolve_alias "$1")"
script="$ROOT_DIR/bin/$command.sh"
if [[ ! "$command" =~ ^[a-z0-9-]+$ || ! -x "$script" ]]; then
  usage >&2
  fail "unknown command: $1"
fi
shift
exec "$script" "$@"
