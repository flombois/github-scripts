#!/usr/bin/env bash
# Routes `github-scripts <command>` (or `ghs <command>`) to the matching report in bin/.
set -euo pipefail
ROOT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$ROOT_DIR/lib/common.sh"

# "alias command" pairs; bash 3.2 has no associative arrays.
ALIASES=("pr pull-requests" "runs actions" "inbox notifications")

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
# For the shell completion (bin/completion.sh): the commands and aliases, and a command's options
# as its --help lists them.
list_commands() {
  local script pair
  for script in "$ROOT_DIR"/bin/*.sh; do basename "$script" .sh; done
  for pair in "${ALIASES[@]}"; do echo "${pair%% *}"; done
}

# Usage: list_options command [subcommand]
list_options() {
  local script
  script="$ROOT_DIR/bin/$(resolve_alias "$1").sh"
  if [[ -n "${2:-}" && -x "$ROOT_DIR/bin/$1/$2.sh" ]]; then script="$ROOT_DIR/bin/$1/$2.sh"; fi
  if [[ "$1 ${2:-}" == "settings variables" ]]; then script="$ROOT_DIR/bin/settings/secrets.sh"; fi
  [[ -x "$script" ]] || return 0
  "$script" --help 2>/dev/null | grep -oE -- '(^|[ ,])--?[a-zA-Z][a-zA-Z-]*' | tr -d ' ,' | sort -u
}

case "$1" in
  -h | --help) usage; exit 0 ;;
  help)
    if [[ $# -lt 2 ]]; then usage; exit 0; fi
    set -- "$2" --help
    ;;
  __commands) list_commands; exit 0 ;;
  __options) list_options "${2:-}" "${3:-}"; exit 0 ;;
esac

command="$(resolve_alias "$1")"
script="$ROOT_DIR/bin/$command.sh"
if [[ ! "$command" =~ ^[a-z0-9-]+$ || ! -x "$script" ]]; then
  usage >&2
  fail "unknown command: $1"
fi
shift
exec "$script" "$@"
