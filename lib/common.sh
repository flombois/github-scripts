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
  if [[ -t 2 && -z "$list_width" ]] && command -v gum >/dev/null; then
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

# Options every table command shares; shared_option sets them.
interactive=false
refresh=false
format=table
list_width=''

# Usage: shared_option "$@"
# Handles -i, --refresh, --format and the internal --list-width, setting `taken` to the number of
# arguments used, or 0 when $1 is none of them.
shared_option() {
  taken=1
  case "$1" in
    -i | --interactive) interactive=true ;;
    --refresh) refresh=true ;;
    --format) needs_value "$1" $#; format="$2"; taken=2 ;;
    --list-width) needs_value "$1" $#; list_width="$2"; taken=2 ;;
    *) taken=0 ;;
  esac
}

# Fails early on a bad --format or -i, before anything is fetched.
check_shared_options() {
  [[ "$format" =~ ^(table|json|csv)$ ]] || fail "format must be table, json or csv, got: $format"
  if [[ "$interactive" == true && -z "$list_width" ]]; then
    [[ "$format" == table ]] || fail "-i and --format can't be combined"
    command -v fzf >/dev/null || fail "-i needs fzf; install it from https://github.com/junegunn/fzf#installation"
    [[ -t 1 ]] || fail "-i needs a terminal"
  fi
}

# Usage: cached_gh title gh-arguments…
# Runs gh behind the spinner. Its output is kept for GHS_CACHE_TTL seconds (default 300) and reused
# unless --refresh is given; failures are never kept.
cached_gh() {
  local title="$1"
  shift
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/ghs"
  local file
  file="$dir/$(printf '%s\n' "$@" | cksum | tr ' ' '-').json"
  if [[ "$refresh" != true && -f "$file" ]] && [[ "$(file_age "$file")" -lt "${GHS_CACHE_TTL:-300}" ]]; then
    cat "$file"
    return
  fi
  local output
  output="$(with_spinner "$title" gh "$@")" || return
  if mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir"; then
    printf '%s\n' "$output" >"$file.$$" && mv "$file.$$" "$file"
  fi
  printf '%s\n' "$output"
}

# Seconds since the file was modified; stat's flags differ between GNU and BSD.
file_age() {
  local modified
  modified="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1")"
  echo $(($(date +%s) - modified))
}

# Usage: show_table kind program [jq options…] <json
# Prints a table program's output the way the shared options ask: the framed or plain table,
# --format json or csv, the fzf list (--list-width) or the fzf browse (-i). kind is the browse
# kind: issue, pr, run, release, or notification (whose rows each name their own kind).
show_table() {
  local kind="$1" program="$2"
  shift 2
  if [[ "$format" != table ]]; then
    render_with false 1000 "$program" --arg view "$format" "$@"
  elif [[ -n "$list_width" ]]; then
    render_with true "$list_width" "$program" --arg view list "$@"
  elif [[ "$interactive" == true ]]; then
    local width
    width="$(terminal_width)"
    render_with true "$(browse_list_width "$width")" "$program" --arg view list "$@" | browse "$kind" "$width"
  else
    render_table "$program" "$@"
  fi
}

# The list's width in the fzf browse: the preview sits beside it from 160 columns, below it otherwise.
browse_list_width() {
  if [[ "$1" -ge 160 ]]; then echo $(($1 / 2 - 7)); else echo $(($1 - 6)); fi
}

# Usage: browse kind width <list
# Browses the list lines in fzf. Each starts with four tab-separated key fields (kind, repo, id,
# extra) that lib/browse.sh acts on; ctrl-r reloads the list by running this script again.
browse() {
  local kind="$1" width="$2"
  local window="down,60%,border-top"
  if [[ "$width" -ge 160 ]]; then window="right,50%,border-left"; fi
  local action reload argument
  action="$(printf %q "$LIB_DIR/browse.sh")"
  reload="$(printf %q "$(realpath "$0")")"
  for argument in ${script_args[@]+"${script_args[@]}"}; do
    reload+=" $(printf %q "$argument")"
  done
  reload+=" --refresh --list-width $(browse_list_width "$width")"
  local keys='{1} {2} {3} {4}'
  local binds=(--bind "enter:execute:$action view $keys" --bind "ctrl-o:execute-silent:$action open $keys"
    --bind "ctrl-r:reload:$reload")
  # key:action:reload, the last part saying whether the list may have changed.
  local key_actions=() key_action name
  case "$kind" in
    issue) key_actions=(alt-a:assign:1 alt-c:comment:1 alt-x:close:1) ;;
    pr) key_actions=(alt-k:checkout:0 alt-a:approve:1 alt-m:merge:1 alt-c:comment:1) ;;
    run) key_actions=(alt-r:rerun:1 alt-l:logs:0 alt-w:watch:1) ;;
    notification) key_actions=(alt-d:read:1) ;;
  esac
  for key_action in ${key_actions[@]+"${key_actions[@]}"}; do
    name="${key_action#*:}"
    name="${name%:*}"
    if [[ "${key_action##*:}" == 1 ]]; then
      binds+=(--bind "${key_action%%:*}:execute[$action $name $keys]+reload[$reload]")
    else
      binds+=(--bind "${key_action%%:*}:execute[$action $name $keys]")
    fi
  done
  fzf --ansi --header-lines 1 --delimiter '\t' --with-nth 5.. --layout reverse --info inline-right \
    --tiebreak index --border rounded --border-label " $(browse_title "$kind") " \
    --header "$(browse_help "$kind")" \
    --preview "$action preview $keys" --preview-window "$window" "${binds[@]}" \
    || { local status=$?; [[ "$status" -eq 130 ]] || return "$status"; }
}

browse_title() {
  case "$1" in
    issue) echo "Issues · $repo" ;;
    pr) echo "Pull requests · $repo" ;;
    run) echo "Actions · $repo" ;;
    notification) echo "Notifications${repo:+ · $repo}" ;;
    release) echo "Releases · $repo" ;;
  esac
}

browse_help() {
  echo "enter view · ctrl-o browser · ctrl-r reload · esc quit"
  case "$1" in
    issue) echo "alt-a assign me · alt-c comment · alt-x close" ;;
    pr) echo "alt-k check out · alt-a approve · alt-m merge · alt-c comment" ;;
    run) echo "alt-r re-run failed · alt-l failed logs · alt-w watch" ;;
    notification) echo "alt-d mark as read" ;;
  esac
}

# Usage: watch_loop seconds fetch draw active
# Redraws every few seconds: fetch (in this shell, uncached) sets the data, draw prints the screen,
# and the loop stops once active says nothing is left running. ctrl-c stops it too.
watch_loop() {
  local seconds="$1" fetch="$2" draw="$3" active="$4" screen
  [[ -t 1 ]] || fail "--watch needs a terminal"
  refresh=true
  trap 'printf "\033[?25h\n"; exit 130' INT
  printf '\033[?25l'
  while :; do
    "$fetch"
    screen="$(GHS_FORCE_TERMINAL=1 "$draw")"
    printf '\033[H\033[2J%s\n' "$screen"
    if ! "$active"; then
      printf ' \033[32m✓\033[0m Nothing left running, so the watch stopped.\n'
      break
    fi
    printf ' \033[2mwatching every %ss · updated %s · ctrl-c to stop\033[0m\n' "$seconds" "$(date +%H:%M:%S)"
    sleep "$seconds"
  done
  printf '\033[?25h'
}

# Usage: watch_option "$@" — reads --watch [seconds] (default 5) into `watch`, setting `taken`.
watch_option() {
  watch=5
  taken=1
  if [[ "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
    watch="$2"
    taken=2
  fi
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
