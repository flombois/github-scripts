#!/usr/bin/env bash
# Removes the github-scripts and ghs links that install.sh made; leaves this clone and packages alone.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/lib/install.sh"

usage() {
  cat <<EOF
Usage: uninstall.sh [--prefix DIR]

Removes the github-scripts and ghs links to this clone. Files that are not
links to this clone are left in place, and so are gh and jq.

Options:
  --prefix DIR   Directory the links were put in; use the same one as install.sh.
                 Defaults to $DEFAULT_PREFIX.
  -h, --help     Show this help.
EOF
}

prefix="$DEFAULT_PREFIX"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    --prefix) needs_value "$1" $#; prefix="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

unlink_own() {
  local link_path="${prefix%/}/$1"
  if is_own_link "$link_path"; then
    rm "$link_path"
    ok "removed $link_path"
  elif [[ -e "$link_path" || -L "$link_path" ]]; then
    note "left $link_path in place: it is not a link to this clone"
  else
    ok "$link_path is not installed"
  fi
}

echo "${BOLD}Uninstalling github-scripts${RESET} from ${prefix%/}"
for name in "${LINK_NAMES[@]}"; do
  unlink_own "$name"
done
