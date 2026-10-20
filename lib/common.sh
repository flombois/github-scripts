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
    repo="$(current_repo)" || fail "no GitHub repository found in $(pwd); pass one with -R owner/repo"
  fi
  repo="${repo#https://github.com/}"
  repo="${repo#ssh://git@github.com/}"
  repo="${repo#*@github.com:}"
  repo="${repo%.git}"
  repo="${repo%/}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "not a repository: $repo (expected owner/repo)"
  echo "$repo"
}

# The current directory's repository: gh asks GitHub, and the git remotes answer when it can't.
current_repo() {
  if ! is_offline && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null; then
    return
  fi
  local_repo
}

# The GitHub URL of the remote gh picked as the default, or of origin.
local_repo() {
  local remote url
  remote="$(git config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null \
    | sed -E -n '1s/^remote\.(.*)\.gh-resolved .*/\1/p')"
  url="$(git remote get-url "${remote:-origin}" 2>/dev/null)" || return
  [[ "$url" =~ github\.com[:/] ]] || return
  echo "$url"
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
# Handles -i, --refresh, --offline, --format and the internal --list-width, setting `taken` to the
# number of arguments used, or 0 when $1 is none of them. --offline is exported, so the fzf previews
# and views it starts stay offline too.
shared_option() {
  taken=1
  case "$1" in
    -i | --interactive) interactive=true ;;
    --refresh) refresh=true ;;
    --offline) export GHS_OFFLINE=1 ;;
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
# unless --refresh is given; failures are never kept. When GitHub can't be reached, or with
# --offline, an older answer is shown instead, up to GHS_CACHE_KEEP old. gh's errors go to stderr,
# or into the file named by gh_errors when it is set, for a caller that reads them.
cached_gh() {
  local title="$1"
  shift
  local file
  file="$(cache_file "$@")"
  if [[ "$refresh" != true && -f "$file" ]] && [[ "$(file_age "$file")" -lt "$(cache_ttl)" ]]; then
    cat "$file"
    return
  fi
  if is_offline; then
    serve_stale "$file" offline || fail "offline, and nothing is cached for this view; open it once online"
    return
  fi
  local errors output status=0
  errors="$(mktemp)"
  output="$(with_spinner "$title" sh -c 'exec gh "$@" 2>"$0"' "$errors" "$@")" || status=$?
  if [[ "$status" -ne 0 ]] && is_unreachable "$errors" && serve_stale "$file" "GitHub is unreachable"; then
    rm -f "$errors"
    return
  fi
  if [[ -n "${gh_errors:-}" ]]; then cat "$errors" >"$gh_errors"; else cat "$errors" >&2; fi
  rm -f "$errors"
  [[ "$status" -eq 0 ]] || return "$status"
  store_cached "$file" "$output"
  printf '%s\n' "$output"
}

# True with --offline or GHS_OFFLINE=1.
is_offline() {
  [[ "${GHS_OFFLINE:-}" == 1 ]]
}

cache_ttl() {
  echo "${GHS_CACHE_TTL:-300}"
}

# True when gh's error output says GitHub could not be reached, rather than refusing the request.
is_unreachable() {
  grep -qiE 'error connecting to|dial tcp|no such host|i/o timeout|connection refused' "$1" \
    || grep -qiE 'network is unreachable|TLS handshake timeout|HTTP 5[0-9][0-9]' "$1"
}

# Usage: serve_stale file reason
# Prints a cached answer no older than GHS_CACHE_KEEP, with a notice on stderr; fails when there is
# none. fzf reloads (--list-width) get no notice, since it would be drawn over the list.
serve_stale() {
  local file="$1" reason="$2" age
  [[ -f "$file" ]] || return 1
  age="$(file_age "$file")"
  [[ "$age" -lt "$(cache_keep_seconds)" ]] || return 1
  if [[ -z "$list_width" ]]; then
    local notice
    notice="$(basename "$0" .sh): $reason; showing what was cached $(describe_age "$age") ago"
    if [[ -t 2 ]]; then printf '\033[2m%s\033[0m\n' "$notice" >&2; else echo "$notice" >&2; fi
  fi
  cat "$file"
}

# How old a cached answer may be and still be shown when GitHub is out of reach.
cache_keep_seconds() {
  case "$(cache_keep)" in
    never) cache_ttl ;;
    forever) echo 9999999999 ;;
    *) echo $(($(cache_keep) * 86400)) ;;
  esac
}

# GHS_CACHE_KEEP: never, forever or a number of days (default 30).
cache_keep() {
  echo "${GHS_CACHE_KEEP:-30}"
}

check_cache_keep() {
  [[ "$(cache_keep)" =~ ^(never|forever|[0-9]+)$ ]] \
    || fail "GHS_CACHE_KEEP must be never, forever or a number of days, got: $(cache_keep)"
}

describe_age() {
  local seconds="$1"
  if [[ "$seconds" -lt 60 ]]; then
    echo "$seconds s"
  elif [[ "$seconds" -lt 3600 ]]; then
    echo "$((seconds / 60)) min"
  elif [[ "$seconds" -lt 172800 ]]; then
    echo "$((seconds / 3600)) h"
  else
    echo "$((seconds / 86400)) days"
  fi
}

# Usage: store_cached file output
# Keeps the answer, then drops the answers older than GHS_CACHE_KEEP.
store_cached() {
  local dir
  dir="$(cache_dir)"
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" || return 0
  printf '%s\n' "$2" >"$1.$$" && mv "$1.$$" "$1"
  prune_cache "$dir"
}

prune_cache() {
  case "$(cache_keep)" in
    forever) ;;
    never) find "$1" -name '*.json' -mmin "+$(($(cache_ttl) / 60))" -delete 2>/dev/null || true ;;
    *) find "$1" -name '*.json' -mtime "+$(cache_keep)" -delete 2>/dev/null || true ;;
  esac
}

cache_dir() {
  echo "${XDG_CACHE_HOME:-$HOME/.cache}/ghs"
}

cache_file() {
  echo "$(cache_dir)/$(printf '%s\n' "$@" | cksum | tr ' ' '-').json"
}

# Usage: forget_cached gh-arguments…
# Drops a cached response after a change, so the next view fetches it again.
forget_cached() {
  rm -f "$(cache_file "$@")"
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
# kind: issue, pr, run, release, setting, ruleset, label, alert, or notification and secret (whose rows each
# name their own kind).
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
    [[ "$argument" == --refresh ]] || reload+=" $(printf %q "$argument")"
  done
  reload+=" --list-width $(browse_list_width "$width")"
  # ctrl-r fetches again; the settings reload after a change reads the cache, which the change cleared.
  local cached_reload="$reload"
  reload+=" --refresh"
  local keys='{1} {2} {3} {4}'
  local binds=(--bind "enter:execute:$action view $keys" --bind "ctrl-o:execute-silent:$action open $keys"
    --bind "ctrl-r:reload:$reload")
  # key:action:reload, the last part saying whether the list may have changed. A later binding
  # replaces an earlier one, such as enter.
  local key_actions=() key_action name item_keys
  case "$kind" in
    issue) key_actions=(alt-a:assign:1 alt-c:comment:1 alt-x:close:1) ;;
    pr) key_actions=(alt-k:checkout:0 alt-a:approve:1 alt-m:merge:1 alt-c:comment:1) ;;
    run) key_actions=(alt-r:rerun:1 alt-l:logs:0 alt-w:watch:1) ;;
    notification) key_actions=(alt-d:read:1) ;;
    ruleset) key_actions=(alt-e:active:1 alt-v:evaluate:1 alt-x:disabled:1) ;;
    secret) key_actions=(enter:change:1 alt-n:new-secret:1 alt-v:new-variable:1 alt-x:delete:1) ;;
    label) key_actions=(alt-n:new:1 alt-e:change:1 alt-x:delete:1) ;;
    alert) key_actions=(alt-d:dismiss:1 alt-r:reopen:1) ;;
  esac
  for key_action in ${key_actions[@]+"${key_actions[@]}"}; do
    name="${key_action#*:}"
    name="${name%:*}"
    # Creating needs no item under the cursor, so it works on an empty list too.
    item_keys="$keys"
    if [[ "$name" == new* ]]; then item_keys="$kind $(printf %q "$repo") '' ''"; fi
    if [[ "${key_action##*:}" == 1 ]]; then
      binds+=(--bind "${key_action%%:*}:execute[$action $name $item_keys]+reload[$reload]")
    else
      binds+=(--bind "${key_action%%:*}:execute[$action $name $item_keys]")
    fi
  done
  local extra_options=() state=''
  if [[ "$kind" == setting ]]; then
    # Enter edits the row in the preview pane (see lib/browse.sh); the cursor follows its row through
    # the reloads.
    binds+=(--bind "enter:transform:$action enter $keys" --bind "esc:transform:$action esc $keys"
      --bind "left:transform:$action left $keys" --bind "right:transform:$action right $keys"
      --bind "start:unbind(change)" --bind "change:refresh-preview")
    extra_options=(--track --id-nth 3 --footer ' ')
    state="$(mktemp -d)"
    mkdir "$state/saving"
  fi
  local status=0
  GHS_RELOAD="$cached_reload" GHS_BROWSE_STATE="$state" GHS_PREVIEW_WINDOW="$window" \
    fzf --ansi --header-lines 1 --delimiter '\t' --with-nth 5.. --layout reverse --info inline-right \
    --tiebreak index --border rounded --border-label " $(browse_title "$kind") " \
    --header "$(browse_help "$kind")" \
    --preview "$action preview $keys" --preview-window "$window" "${binds[@]}" ${extra_options[@]+"${extra_options[@]}"} \
    || status=$?
  [[ -z "$state" ]] || rm -rf "$state"
  [[ "$status" -eq 0 || "$status" -eq 130 ]] || return "$status"
}

browse_title() {
  case "$1" in
    issue) echo "Issues · $repo" ;;
    pr) echo "Pull requests · $repo" ;;
    run) echo "Actions · $repo" ;;
    notification) echo "Notifications${repo:+ · $repo}" ;;
    release) echo "Releases · $repo" ;;
    setting) echo "Settings · $repo" ;;
    ruleset) echo "Rules · $repo" ;;
    secret) echo "Secrets and variables · $repo" ;;
    label) echo "Labels · $repo" ;;
    alert) echo "Security · $repo" ;;
  esac
}

browse_help() {
  local enter="enter view"
  case "$1" in
    setting) enter="enter edit" ;;
    secret) enter="enter change" ;;
    alert) enter="enter browser" ;;
    label) enter="enter issues" ;;
  esac
  echo "$enter · ctrl-o browser · ctrl-r reload · esc quit"
  case "$1" in
    issue) echo "alt-a assign me · alt-c comment · alt-x close" ;;
    pr) echo "alt-k check out · alt-a approve · alt-m merge · alt-c comment" ;;
    run) echo "alt-r re-run failed · alt-l failed logs · alt-w watch" ;;
    notification) echo "alt-d mark as read" ;;
    setting) echo "editing: ← → pick a value · enter save · esc cancel" ;;
    ruleset) echo "alt-e enforce · alt-v evaluate only · alt-x disable" ;;
    secret) echo "alt-n new secret · alt-v new variable · alt-x delete" ;;
    label) echo "alt-n new · alt-e edit · alt-x delete" ;;
    alert) echo "alt-d dismiss · alt-r reopen" ;;
  esac
}

# Usage: watch_loop seconds fetch draw active
# Redraws every few seconds: fetch (in this shell, uncached) sets the data, draw prints the screen,
# and the loop stops once active says nothing is left running. ctrl-c stops it too.
watch_loop() {
  local seconds="$1" fetch="$2" draw="$3" active="$4" screen
  [[ -t 1 ]] || fail "--watch needs a terminal"
  is_offline && fail "--watch needs GitHub; drop --offline"
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

check_cache_keep
