#!/usr/bin/env bash
# Checks the requirements, then links github-scripts and ghs onto the PATH, pointing at this clone.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/lib/install.sh"
source "$LIB_DIR/packages.sh"

usage() {
  cat <<EOF
Usage: install.sh [--prefix DIR] [--yes]

Checks that gh and jq are installed, offers to install the missing ones with
the package manager of this macOS or Linux machine, then links github-scripts
and its short name ghs to cli.sh in this clone. Run it again after moving the
clone.

glow 3 is optional: with it, ghs issues <number> renders the description as
Markdown. It is offered through Homebrew; elsewhere the installer prints where
to get it.

Options:
  --prefix DIR   Directory for the links; it should be on your PATH.
                 Defaults to $DEFAULT_PREFIX.
  -y, --yes      Install missing packages without asking.
  -h, --help     Show this help.
EOF
}

prefix="$DEFAULT_PREFIX"
assume_yes=false
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    --prefix) needs_value "$1" $#; prefix="$2"; shift 2 ;;
    -y | --yes) assume_yes=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

link() {
  local link_path="$prefix/$1"
  if is_own_link "$link_path"; then
    ok "$1 already linked to $CLI_PATH"
    return
  fi
  if [[ -e "$link_path" ]]; then
    missing "$link_path already exists and is not a link to this clone"
    fail "remove $link_path or pass --prefix DIR"
  fi
  ln -sfn "$CLI_PATH" "$link_path"
  ok "$1 linked to $CLI_PATH"
}

check_path() {
  if [[ ":$PATH:" == *":$prefix:"* ]]; then
    ok "$prefix is on your PATH"
    return
  fi
  note "$prefix is not on your PATH; add this line to your shell profile:"
  echo "      export PATH=\"$prefix:\$PATH\""
}

echo "${BOLD}Installing github-scripts${RESET} from $ROOT_DIR"

heading "Platform"
detect_platform

heading "Requirements"
ok "bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]} ($BASH)"
ensure_tool gh "" https://cli.github.com/
ensure_tool jq 1.7 https://jqlang.org/download/
offer_tool glow 3.0 https://github.com/charmbracelet/glow#installation "renders issue Markdown"
check_login

heading "Commands"
chmod +x "$CLI_PATH" "$ROOT_DIR"/bin/*.sh
mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd)"
for name in "${LINK_NAMES[@]}"; do
  link "$name"
done
check_path

heading "Done"
echo "  Run 'ghs --help' to see the commands."
