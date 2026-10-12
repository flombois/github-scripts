#!/usr/bin/env bash
# Prints a repository's labels with their open issues and pull requests, and creates, edits or deletes them.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ghs settings labels [-R owner/repo] [-i] [--format f] [--refresh] [--offline]
       ghs settings labels create <name> [-c color] [-d description]
       ghs settings labels edit <name> [-n new-name] [-c color] [-d description]
       ghs settings labels delete <name> [--yes]

Prints the labels of a GitHub repository, with their colour, description and
how many open issues and pull requests carry them.

  create    Adds a label; without -c, GitHub picks a colour.
  edit      Renames a label or changes its colour or description.
  delete    Deletes a label, taking it off every issue and pull request;
            asks first, unless --yes.

Changing labels needs write access to the repository.

Options:
  -R, --repo owner/repo     Repository to read; also accepts a GitHub URL.
                            Defaults to the repository of the current directory.
  -c, --color hex           Colour as six hex digits, such as d73a4a.
  -d, --description text    Description.
  -n, --name name           New name, with edit.
  -i, --interactive         Browse them in fzf; Enter lists a label's issues.
      --format format       table (default), json or csv.
      --refresh             Fetch again instead of using the 5-minute cache.
      --offline             Use the cache only, even past 5 minutes; never
                            contact GitHub.
      --yes                 Delete without asking.
  -h, --help                Show this help.
EOF
}

script_args=("$@")
repo=''
verb=''
name=''
color=''
description=''
new_name=''
has_color=false
has_description=false
yes=false
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -c | --color) needs_value "$1" $#; color="${2#\#}"; has_color=true; shift 2 ;;
    -d | --description) needs_value "$1" $#; description="$2"; has_description=true; shift 2 ;;
    -n | --name) needs_value "$1" $#; new_name="$2"; shift 2 ;;
    --yes) yes=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
    *)
      if [[ -z "$verb" ]]; then verb="$1"
      elif [[ -z "$name" ]]; then name="$1"
      else usage >&2; fail "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done
case "$verb" in
  '' | new) ;;
  create | edit | delete | change | show) [[ -n "$name" ]] || fail "$verb needs a label name" ;;
  *) usage >&2; fail "unknown command: settings labels $verb" ;;
esac
if [[ "$has_color" == true && ! "$color" =~ ^[0-9a-fA-F]{6}$ ]]; then
  fail "the colour must be six hex digits, such as d73a4a; got: $color"
fi
check_shared_options
repo="$(resolve_repo "$repo")"

query='
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    labels(first: 100, after: $endCursor, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        color
        description
        isDefault
        url
        issues(states: OPEN) { totalCount }
        pullRequests(states: OPEN) { totalCount }
      }
    }
  }
}'

program='
def countCell: (if . == 0 then dim else "" end) as $style | "\(.)" | cell($style);

. as $labels
| {
    title: (("Labels" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)/labels"))),
    subtitle: ("\($labels | length | plural("label")) · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "label", header: "LABEL", max: 32},
      {key: "description", header: "DESCRIPTION", flex: true},
      {key: "color", header: "COLOR", drop: true},
      {key: "issues", header: "ISSUES", align: "right"},
      {key: "prs", header: "PRS", align: "right"}
    ],
    rows: [$labels[]
           | .url as $url
           | .color as $color
           | {_key: ["label", $repo, .name, .url],
              label: (("● " | cell($color | hexColor) | decor) + (.name | cell("")) | linkTo($url)),
              description: (.description // "" | if . == "" then "—" | cell(dim) | decor else cell("") end),
              color: ("#\($color)" | cell(dim)),
              issues: (.issues.totalCount | countCell),
              prs: (.pullRequests.totalCount | countCell)}],
    footer: [
      ($labels | length | plural("label") | cell("")),
      ($labels | map(select(.issues.totalCount + .pullRequests.totalCount == 0)) | length
       | tally("on nothing open"; dim)),
      ($labels | map(select(.isDefault)) | length | tally("GitHub defaults"; dim))
    ],
    empty: "No labels."
  }
| table
'

fetch_args=(api graphql --paginate --slurp -F owner="${repo%%/*}" -F name="${repo#*/}" -f query="$query")
fetch_labels() {
  labels="$(cached_gh "Loading the labels of ${repo}…" "${fetch_args[@]}")" || fail "could not read the labels of $repo"
  labels="$(jq '[.[].data.repository.labels.nodes[]]' <<<"$labels")"
}

# Usage: label_field name field
label_field() {
  jq -r --arg name "$1" --arg field "$2" 'first(.[] | select(.name == $name) | .[$field] // "") // ""' <<<"$labels"
}

exists() {
  jq -e --arg name "$1" 'any(.[]; .name == $name)' <<<"$labels" >/dev/null
}

# Usage: run_label command…
# Runs a gh label command, then forgets the cached labels.
run_label() {
  gh label "$@" -R "$repo" || return
  forget_cached "${fetch_args[@]}"
}

create_label() {
  ! exists "$name" || fail "$repo already has a label named $name"
  local args=()
  if [[ "$has_color" == true ]]; then args+=(--color "$color"); fi
  if [[ "$has_description" == true ]]; then args+=(--description "$description"); fi
  run_label create "$name" ${args[@]+"${args[@]}"}
}

edit_label() {
  exists "$name" || fail "no label named $name in $repo"
  local args=()
  if [[ -n "$new_name" ]]; then args+=(--name "$new_name"); fi
  if [[ "$has_color" == true ]]; then args+=(--color "$color"); fi
  if [[ "$has_description" == true ]]; then args+=(--description "$description"); fi
  [[ ${#args[@]} -gt 0 ]] || fail "edit needs -n, -c or -d"
  run_label edit "$name" "${args[@]}"
}

delete_label() {
  exists "$name" || fail "no label named $name in $repo"
  if [[ "$yes" != true ]]; then
    [[ -t 0 ]] || fail "deleting the label $name needs --yes"
    source "$LIB_DIR/prompt.sh"
    confirm "Delete the label $name from $repo and everything it is on?" || exit 0
  fi
  run_label delete "$name" --yes
}

# Usage: ask_label name color description
# Asks for the three fields, starting from the given ones; sets new_name, color and description.
ask_label() {
  new_name="$(ask "Name" "$1")" || return
  [[ -n "$new_name" ]] || return
  while true; do
    color="$(ask "Colour, six hex digits (empty lets GitHub pick)" "$2")" || return
    color="${color#\#}"
    [[ -z "$color" || "$color" =~ ^[0-9a-fA-F]{6}$ ]] && break
    echo "Not a colour: $color" >/dev/tty
  done
  description="$(ask "Description" "$3")" || return
}

# fzf's alt-n.
new_label() {
  source "$LIB_DIR/prompt.sh"
  clear_screen
  ask_label "" "" "" || return 0
  if exists "$new_name"; then
    echo "$repo already has a label named $new_name." >/dev/tty
    pause
    return
  fi
  local args=()
  if [[ -n "$color" ]]; then args+=(--color "$color"); fi
  if [[ -n "$description" ]]; then args+=(--description "$description"); fi
  if confirm "Add the label $new_name to $repo?"; then
    run_label create "$new_name" ${args[@]+"${args[@]}"} || true
    pause
  fi
}

# fzf's alt-e.
change_label() {
  source "$LIB_DIR/prompt.sh"
  clear_screen
  local old_color old_description args=()
  old_color="$(label_field "$name" color)"
  old_description="$(label_field "$name" description)"
  ask_label "$name" "$old_color" "$old_description" || return 0
  if [[ "$new_name" != "$name" ]]; then args+=(--name "$new_name"); fi
  if [[ -n "$color" && "$color" != "$old_color" ]]; then args+=(--color "$color"); fi
  if [[ "$description" != "$old_description" ]]; then args+=(--description "$description"); fi
  [[ ${#args[@]} -gt 0 ]] || return 0
  if confirm "Save the changes to the label $name?"; then
    run_label edit "$name" "${args[@]}" || true
    pause
  fi
}

# The fzf preview.
show_label() {
  jq -r --arg name "$name" --argjson width "${COLUMNS:-60}" '
    def bold: "\u001b[1m\(.)\u001b[0m";
    def dim: "\u001b[2m\(.)\u001b[0m";
    def count($word): if . == 1 then "1 \($word)" else "\(.) \($word)s" end;
    first(.[] | select(.name == $name))
    | (.color | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end)
       | "\u001b[38;2;\(.[0] * 16 + .[1]);\(.[2] * 16 + .[3]);\(.[4] * 16 + .[5])m●\u001b[0m") as $swatch
    | "", " \($swatch) " + (.name | bold),
      " " + ("#\(.color)" + (if .isDefault then " · a GitHub default" else "" end) | dim), "",
      (.description // "" | if . == "" then " No description." | dim
       else [scan(".{1,\($width - 2)}(?:\\s|$)") | " " + rtrimstr(" ")][] end),
      "",
      " " + (.issues.totalCount | count("open issue")) + " · " + (.pullRequests.totalCount | count("open pull request")),
      "", (" Enter lists its open issues; ctrl-o opens it on github.com." | dim)
  ' <<<"$labels"
}

fetch_labels
case "$verb" in
  show) show_label ;;
  create) create_label ;;
  edit) edit_label ;;
  delete) delete_label ;;
  new) new_label ;;
  change) change_label ;;
  *) show_table label "$program" --arg repo "$repo" <<<"$labels" ;;
esac
