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

# Renders the JSON on stdin; $1 is a jq program that ends in `| table` or prints its own lines,
# the rest are extra jq options.
render_table() {
  if [[ -t 1 ]]; then
    render_with true "$(terminal_width)" "$@"
  else
    render_with false 1000 "$@"
  fi
}

# Runs a command and pages its output through less (or $PAGER) when one is available.
# Decide colour and width before calling it: the command's output is a pipe.
page() {
  if [[ -n "${PAGER:-}" ]] || command -v less >/dev/null; then
    "$@" | LESS="${LESS:-FRX}" ${PAGER:-less}
  else
    "$@"
  fi
}

# True when glow 3 or later is installed.
has_glow() {
  [[ "$(glow --version 2>/dev/null)" =~ version\ ([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" -ge 3 ]]
}

# Renders the Markdown on stdin with glow, in colour, to fit the given terminal width.
# TERM=dumb stops glow querying the terminal's colours (the replies would land in less);
# -s still forces colour. glow pads every line and indents by two; both are trimmed.
render_markdown() {
  local text
  text="$(cat)"
  [[ -n "$text" ]] || return 0
  TERM=dumb glow -s "${GLAMOUR_STYLE:-dark}" -w "$(($1 - 1))" - <<<"$text" \
    | LC_ALL=C sed -E -e 's/^ //' -e $'s/(\x1b\\[[0-9;]*m| )+$/\x1b[0m/'
}

# Asks the terminal itself: inside $(…), tput sees a pipe and answers 80.
terminal_width() {
  local size
  if [[ -n "${COLUMNS:-}" ]]; then
    echo "$COLUMNS"
  elif size="$(stty size </dev/tty 2>/dev/null)" && [[ "$size" =~ ^[0-9]+\ ([1-9][0-9]*)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 80
  fi
}

# Usage: render_with is_terminal width program [jq options…]
render_with() {
  local is_terminal="$1"
  local width="$2"
  local program="$3"
  shift 3
  jq -r --argjson isTerminal "$is_terminal" --argjson terminalWidth "$width" "$@" \
    "$(cat "$LIB_DIR/table.jq")"$'\n'"$program"
}
