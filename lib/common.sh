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
  if on_terminal; then
    render_with true "$(terminal_width)" "$@"
  else
    render_with false 1000 "$@"
  fi
}

# True on a terminal, or when GHS_FORCE_TERMINAL=1 (fzf previews, whose output is a pipe).
on_terminal() {
  [[ -t 1 || "${GHS_FORCE_TERMINAL:-}" == 1 ]]
}

# Runs a command and pages its output through less (or $PAGER) when one is available.
# Decide colour and width before calling it: the command's output is a pipe.
page() {
  if [[ "${GHS_FORCE_TERMINAL:-}" == 1 ]]; then
    "$@"
  elif [[ -n "${PAGER:-}" ]] || command -v less >/dev/null; then
    "$@" | LESS="${LESS:-FRX}" ${PAGER:-less}
  else
    "$@"
  fi
}

# Usage: with_spinner title command…
# Runs the command behind a gum spinner when stderr is a terminal; its output and status pass through.
with_spinner() {
  local title="$1"
  shift
  if [[ -t 2 ]] && command -v gum >/dev/null; then
    gum spin --spinner dot --title "$title" --show-stdout --show-stderr -- "$@"
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
# -s still forces colour. glow pads every line and indents by two; both are trimmed, so its -w
# (which counts the indent and stays one short) is the width plus 2.
render_markdown() {
  local text
  text="$(cat)"
  [[ -n "$text" ]] || return 0
  TERM=dumb glow -s "${GLAMOUR_STYLE:-dark}" -w "$(($1 + 2))" - <<<"$text" \
    | LC_ALL=C sed -E -e 's/^  //' -e $'s/(\x1b\\[[0-9;]*m| )+$/\x1b[0m/'
}

# Fails early when -i can't work: it needs fzf and a terminal.
check_browse() {
  command -v fzf >/dev/null || fail "-i needs fzf; install it from https://github.com/junegunn/fzf#installation"
  [[ -t 1 ]] || fail "-i needs a terminal"
}

# Usage: browse kind repo title program [jq options…] <json
# Lists the rows of the table program in fzf, with the issue, pull request or run (kind) under the
# cursor in a preview pane. Enter shows it in full, ctrl-o opens it in the browser.
browse() {
  local kind="$1" repo="$2" title="$3" program="$4"
  shift 4
  check_browse
  local width list_width window
  width="$(terminal_width)"
  if [[ "$width" -ge 160 ]]; then
    list_width=$((width / 2 - 7))
    window="right,50%,border-left"
  else
    list_width=$((width - 6))
    window="down,60%,border-top"
  fi
  # fzf runs these with $SHELL; {1} is the first column, such as #42.
  local number='n="$(printf %s {1} | tr -dc 0-9)";'
  local target view preview enter open
  target="\"\$n\" -R $(printf %q "$repo")"
  case "$kind" in
    issue)
      view="$(printf %q "$LIB_DIR/../bin/issue.sh") $target"
      preview="GHS_FORCE_TERMINAL=1 COLUMNS=\"\$FZF_PREVIEW_COLUMNS\" $view"
      enter="$view -c"
      open="gh issue view $target --web" ;;
    pr)
      preview="GH_FORCE_TTY=\"\$FZF_PREVIEW_COLUMNS\" gh pr view $target"
      enter="GH_FORCE_TTY=100% gh pr view $target -c | less -RF"
      open="gh pr view $target --web" ;;
    run)
      preview="GH_FORCE_TTY=\"\$FZF_PREVIEW_COLUMNS\" gh run view $target"
      enter="GH_FORCE_TTY=100% gh run view $target --verbose | less -RF"
      open="gh run view $target --web" ;;
  esac
  render_with true "$list_width" "$program" --arg view list "$@" \
    | fzf --ansi --header-lines 1 --layout reverse --info inline-right --tiebreak index \
        --border rounded --border-label " $title " --header "enter view · ctrl-o browser · esc quit" \
        --preview "$number $preview" --preview-window "$window" \
        --bind "enter:execute:$number $enter" --bind "ctrl-o:execute-silent:$number $open" \
    || { local status=$?; [[ "$status" -eq 130 ]] || return "$status"; }
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
