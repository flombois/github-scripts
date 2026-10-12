# Shared by install.sh and uninstall.sh; source it, don't run it.

source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/common.sh"

LINK_NAMES=(github-scripts ghs)
DEFAULT_PREFIX="${XDG_BIN_HOME:-$HOME/.local/bin}"
ROOT_DIR="$(dirname "$LIB_DIR")"
CLI_PATH="$ROOT_DIR/cli.sh"

BOLD=''
GREEN=''
RED=''
YELLOW=''
RESET=''
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  YELLOW=$'\033[33m'
  RESET=$'\033[0m'
fi

heading() {
  echo
  echo "${BOLD}$1${RESET}"
}

ok() {
  echo "  ${GREEN}✓${RESET} $1"
}

missing() {
  echo "  ${RED}✗${RESET} $1"
}

note() {
  echo "  ${YELLOW}!${RESET} $1"
}

# True when $1 is a symlink to this clone's cli.sh.
is_own_link() {
  [[ -L "$1" && "$(realpath "$1" 2>/dev/null)" == "$CLI_PATH" ]]
}
