# Shared helpers for the report scripts; source it, don't run it.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "$(basename "$0" .sh): $1" >&2
  exit 1
}

# Usage: needs_value "$1" $#
needs_value() {
  [[ "$2" -ge 2 ]] || fail "$1 needs a value"
}

require_count() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || fail "$1 must be a positive number, got: $2"
}

# Prints owner/repo from a name or GitHub URL, or from the current directory when empty.
resolve_repo() {
  local repo="$1"
  if [[ -z "$repo" ]]; then
    repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
      || fail "no GitHub repository found in $(pwd); pass one with -R owner/repo"
  fi
  repo="${repo#https://github.com/}"
  repo="${repo#*@github.com:}"
  repo="${repo%.git}"
  repo="${repo%/}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "not a repository: $repo (expected owner/repo)"
  echo "$repo"
}

# Renders the JSON on stdin; $1 is a jq program that ends in `| table`, the rest are extra jq options.
render_table() {
  local program="$1"
  shift
  local is_terminal=false
  local width=1000
  if [[ -t 1 ]]; then
    is_terminal=true
    width="${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}"
  fi
  jq -r --argjson isTerminal "$is_terminal" --argjson terminalWidth "$width" "$@" \
    "$(cat "$LIB_DIR/table.jq")"$'\n'"$program"
}
