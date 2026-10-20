#!/usr/bin/env bash
# Prints a repository's settings and changes them; also rules, secrets, variables and labels.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"
SETTINGS_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/settings"

case "${1:-}" in
  rules | labels) exec "$SETTINGS_DIR/$1.sh" "${@:2}" ;;
  secrets) exec "$SETTINGS_DIR/secrets.sh" secret "${@:2}" ;;
  variables) exec "$SETTINGS_DIR/secrets.sh" variable "${@:2}" ;;
esac

usage() {
  cat <<'EOF'
Usage: settings.sh [-R owner/repo] [-i] [--format f] [--refresh] [--offline]
       settings.sh set <setting> <value> [-R owner/repo] [--yes]
       settings.sh rules|secrets|variables|labels [options]

Prints the settings of a GitHub repository: general, features and pull
requests. set changes one; with -i, Enter edits the setting under the cursor
in the preview pane: the left and right arrows pick a value (text settings
take typing), Enter saves it and Esc cancels. The row stays greyed out until
GitHub answers. Changing a setting needs admin access to the repository.

Settings and their values:
  description, homepage     text; "" clears it
  topics                    space-separated, replacing the current topics
  visibility                public, private or internal; asks first, or --yes
  default-branch            an existing branch
  template, forking         on or off; forking is for organisation repositories
  issues, wiki, projects, discussions
                            on or off
  merge-commit, squash-merge, rebase-merge, auto-merge, update-branch,
  delete-branch             on or off
  squash-message            default, pr-title, pr-title-commits or
                            pr-title-description

The other settings have their own commands; see their --help:
  rules                     rulesets and branch protection; turn rulesets on or off
  secrets, variables        Actions secrets and variables; set and delete them
  labels                    labels; create, edit and delete them

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -i, --interactive       Browse the settings in fzf; Enter edits, Enter again saves.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
      --offline           Use the cache only, even past 5 minutes; never
                          contact GitHub.
      --yes               Change the visibility without asking.
  -h, --help              Show this help.
EOF
}

# One entry per setting: what the table shows, and what `set` checks and passes to gh repo edit.
definitions='
def onOff: if . then "on" else "off" end;

def squashMessage:
  if .squashMergeCommitTitle == "COMMIT_OR_PR_TITLE" then "default"
  elif .squashMergeCommitMessage == "COMMIT_MESSAGES" then "pr-title-commits"
  elif .squashMergeCommitMessage == "PR_BODY" then "pr-title-description"
  else "pr-title" end;

def choiceNames:
  {default: "Default message", "pr-title": "Pull request title",
   "pr-title-commits": "Pull request title and commit details",
   "pr-title-description": "Pull request title and description"};

def setting($section; $key; $label; $kind; $flag; $value; $help):
  {$section, $key, $label, $kind, $flag, $value, $help}
  | if $kind == "switch" then .choices = ["on", "off"] else . end;

def settings:
  (.owner.__typename == "Organization") as $organization
  | [setting("General"; "description"; "Description"; "text"; "--description"; .description // "";
       "A short description, shown at the top of the repository and in search results."),
     setting("General"; "homepage"; "Website"; "text"; "--homepage"; .homepageUrl // "";
       "A URL shown beside the description."),
     setting("General"; "topics"; "Topics"; "topics"; ""; [.repositoryTopics.nodes[].topic.name] | join(" ");
       "Topics help people find the repository. Separate them with spaces; the new list replaces the old one."),
     (setting("General"; "visibility"; "Visibility"; "choice"; "--visibility"; .visibility | ascii_downcase;
        "Who can see the repository. Making a public repository private loses its stars and watchers.")
      | .choices = (if $organization then ["public", "private", "internal"] else ["public", "private"] end)),
     setting("General"; "default-branch"; "Default branch"; "branch"; "--default-branch"; .defaultBranchRef.name // "";
       "The base branch for pull requests and the branch shown first."),
     setting("General"; "template"; "Template repository"; "switch"; "--template"; .isTemplate | onOff;
       "Lets people generate new repositories with the same files and branches."),
     (if $organization then
        setting("General"; "forking"; "Allow forking"; "switch"; "--allow-forking"; .forkingAllowed | onOff;
          "Lets people fork this organisation repository.")
      else empty end),
     setting("Features"; "issues"; "Issues"; "switch"; "--enable-issues"; .hasIssuesEnabled | onOff;
       "Issues track work, bugs and ideas."),
     setting("Features"; "wiki"; "Wiki"; "switch"; "--enable-wiki"; .hasWikiEnabled | onOff;
       "A wiki for long-form documentation."),
     setting("Features"; "projects"; "Projects"; "switch"; "--enable-projects"; .hasProjectsEnabled | onOff;
       "Project boards and tables linked to the repository."),
     setting("Features"; "discussions"; "Discussions"; "switch"; "--enable-discussions"; .hasDiscussionsEnabled | onOff;
       "A forum for questions and conversations outside issues."),
     setting("Pull requests"; "merge-commit"; "Allow merge commits"; "switch"; "--enable-merge-commit";
       .mergeCommitAllowed | onOff; "Merges a pull request with a merge commit, keeping all its commits."),
     setting("Pull requests"; "squash-merge"; "Allow squash merging"; "switch"; "--enable-squash-merge";
       .squashMergeAllowed | onOff; "Combines the commits of a pull request into one commit."),
     (setting("Pull requests"; "squash-message"; "Squash commit message"; "choice"; "--squash-merge-commit-message";
        squashMessage; "The default title and message of a squash commit.")
      | .choices = (choiceNames | keys_unsorted)),
     setting("Pull requests"; "rebase-merge"; "Allow rebase merging"; "switch"; "--enable-rebase-merge";
       .rebaseMergeAllowed | onOff; "Adds the commits of a pull request to the base branch one by one."),
     setting("Pull requests"; "auto-merge"; "Allow auto-merge"; "switch"; "--enable-auto-merge";
       .autoMergeAllowed | onOff; "Lets a pull request merge by itself once its requirements are met."),
     setting("Pull requests"; "update-branch"; "Always suggest updating branches"; "switch"; "--allow-update-branch";
       .allowUpdateBranch | onOff; "Offers to update a pull request branch that is behind its base."),
     setting("Pull requests"; "delete-branch"; "Delete head branches"; "switch"; "--delete-branch-on-merge";
       .deleteBranchOnMerge | onOff; "Deletes the head branch once its pull request is merged.")];
'

take_positional() {
  if [[ -z "$verb" ]]; then verb="$1"
  elif [[ -z "$key" ]]; then key="$1"
  elif [[ "$has_value" == false ]]; then value="$1"; has_value=true
  else usage >&2; fail "unexpected argument: $1"
  fi
}

script_args=("$@")
repo=''
verb=''
key=''
value=''
has_value=false
yes=false
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    --yes) yes=true; shift ;;
    -h | --help) usage; exit 0 ;;
    # The rest are positional, so a value may start with a dash.
    --) shift; break ;;
    -*)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
    *) take_positional "$1"; shift ;;
  esac
done
for argument in "$@"; do take_positional "$argument"; done
case "$verb" in
  '') ;;
  set) [[ -n "$key" && "$has_value" == true ]] || fail "set needs a setting and a value, such as: set wiki off" ;;
  # The fzf browse: the preview, the editor's checks and choices, and the editor pane with a draft value.
  show | editable) [[ -n "$key" ]] || fail "$verb needs a setting" ;;
  editor) [[ -n "$key" && "$has_value" == true ]] || fail "editor needs a setting and a value" ;;
  # For the shell completion: the setting names, or the values one takes.
  __keys) jq -rn "$definitions"'{owner: {__typename: "Organization"}, repositoryTopics: {nodes: []}, visibility: "PUBLIC"} | settings[].key'; exit 0 ;;
  __values) jq -rn --arg key "$key" "$definitions"'{owner: {__typename: "Organization"}, repositoryTopics: {nodes: []}, visibility: "PUBLIC"}
              | settings[] | select(.key == $key) | .choices // [] | .[]'; exit 0 ;;
  *) usage >&2; fail "unknown command: settings $verb" ;;
esac
check_shared_options
repo="$(resolve_repo "$repo")"

query='
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    nameWithOwner
    url
    viewerPermission
    isArchived
    owner { __typename }
    description
    homepageUrl
    repositoryTopics(first: 20) { nodes { topic { name } } }
    visibility
    defaultBranchRef { name }
    isTemplate
    forkingAllowed
    hasIssuesEnabled
    hasWikiEnabled
    hasProjectsEnabled
    hasDiscussionsEnabled
    mergeCommitAllowed
    squashMergeAllowed
    squashMergeCommitTitle
    squashMergeCommitMessage
    rebaseMergeAllowed
    autoMergeAllowed
    allowUpdateBranch
    deleteBranchOnMerge
    labels { totalCount }
    rulesets(includeParents: true) { totalCount }
  }
}'

program="$definitions"'
def valueCell:
  if .kind == "switch" then
    if .value == "on" then ("● " | cell(green) | decor) + ("on" | cell(green))
    else ("○ " | cell(dim) | decor) + ("off" | cell(dim)) end
  elif .value == "" then "—" | cell(dim) | decor
  elif .kind == "topics" then .value | split(" ") | map(cell(cyan)) | joinCells(" " | cell(""))
  elif .key == "squash-message" then (.value | cell("")) + ("  \(choiceNames[.value])" | cell(dim) | decor)
  elif .key == "visibility" then .value | cell(if . == "public" then "" else yellow end)
  else .value | cell("") end;

# A row the fzf browse is still saving: greyed out, with the value on its way.
def savingCell($new):
  ("⋯ " | cell(dim) | decor) + (if $new == "" then [] else $new | cell(dim) end) + ("  saving…" | cell(dim) | decor);

($ARGS.named.view // "" | IN("json", "csv")) as $exporting
| (.viewerPermission == "ADMIN" and (.isArchived | not)) as $canChange
| settings as $settings
| "\(.url)/settings" as $settingsUrl
| {
    title: (("Settings" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo($settingsUrl))),
    subtitle: ((if .isArchived then "archived, read only"
                elif $canChange then "admin access"
                else "read only: you have \(.viewerPermission // "no" | ascii_downcase) access" end)
               + " · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "section", header: "SECTION"},
      {key: "setting", header: "SETTING"},
      {key: "value", header: "VALUE", flex: true},
      {key: "key", header: "KEY", drop: true}
    ],
    rows: [range(0; $settings | length) as $index
           | $settings[$index]
           | $saving[.key] as $new
           | {_key: ["setting", $repo, .key],
              section: (if $exporting or $index == 0 or $settings[$index - 1].section != .section
                        then .section | cell(bold) else [] end),
              setting: (.label | cell(if $new then dim else "" end)),
              value: (if $new then savingCell($new) else valueCell end),
              key: (.key | cell(dim))}],
    footer: [
      (.rulesets.totalCount | plural("ruleset") | cell("")),
      (.labels.totalCount | plural("label") | cell("")),
      ("more with ghs settings rules, secrets, variables or labels" | cell(dim))
    ],
    empty: "No settings."
  }
| table
'

fetch_args=(api graphql -F owner="${repo%%/*}" -F name="${repo#*/}" -f query="$query")
fetch_settings() {
  item="$(cached_gh "Loading the settings of ${repo}…" "${fetch_args[@]}")" \
    || fail "could not read the settings of $repo"
  item="$(jq '.data.repository' <<<"$item")"
}

# Usage: read_setting key
# Sets kind, flag, label, choices (space-separated) and current from the definitions.
read_setting() {
  local fields
  fields="$(jq -r --arg key "$1" "$definitions"'
    settings[] | select(.key == $key) | [.kind, .flag, .label, (.choices // [] | join(" ")), .value] | join("\u001f")
  ' <<<"$item")"
  [[ -n "$fields" ]] || fail "unknown setting: $1 (settings.sh --help lists them)"
  IFS=$'\x1f' read -r kind flag label choices current <<<"$fields"
}

# Fails unless the viewer may change the settings.
require_admin() {
  local permission
  permission="$(jq -r '.viewerPermission // "no" | ascii_downcase' <<<"$item")"
  [[ "$(jq -r .isArchived <<<"$item")" == false ]] || fail "$repo is archived, so its settings can't change"
  [[ "$permission" == admin ]] || fail "changing the settings of $repo needs admin access; you have $permission access"
}

# Prints the value in the form set takes, or fails when the setting doesn't accept it.
normalize_value() {
  case "$kind" in
    switch)
      case "$(tr '[:upper:]' '[:lower:]' <<<"$1")" in
        on | true | yes | enable | enabled | 1) echo on ;;
        off | false | no | disable | disabled | 0) echo off ;;
        *) fail "$key must be on or off, got: $1" ;;
      esac
      ;;
    choice)
      [[ " $choices " == *" $1 "* ]] || fail "$key must be one of: ${choices// /, }; got: $1"
      echo "$1"
      ;;
    topics) tr ',' ' ' <<<"$1" | xargs ;;
    *) echo "$1" ;;
  esac
}

# Usage: apply_setting new-value
# Changes the setting read by read_setting with gh repo edit, then forgets the cached settings.
apply_setting() {
  local new="$1" args=() topic
  case "$kind" in
    switch) args=("$flag=$([[ "$new" == on ]] && echo true || echo false)") ;;
    topics)
      for topic in $new; do [[ " $current " == *" $topic "* ]] || args+=(--add-topic "$topic"); done
      for topic in $current; do [[ " $new " == *" $topic "* ]] || args+=(--remove-topic "$topic"); done
      ;;
    *) args=("$flag" "$new") ;;
  esac
  if [[ "$key" == visibility ]]; then args+=(--accept-visibility-change-consequences); fi
  gh repo edit "$repo" "${args[@]}" || return
  forget_cached "${fetch_args[@]}"
  echo "✓ $label: ${current:-(none)} → ${new:-(none)}"
}

set_setting() {
  read_setting "$key"
  require_admin
  local new
  new="$(normalize_value "$value")"
  change_to "$new"
}

# Usage: change_to new-value
# Applies the value unless it is the current one; the visibility asks first, unless --yes.
change_to() {
  local new="$1"
  if [[ "$new" == "$current" ]]; then
    echo "$label is already ${new:-empty}."
    return
  fi
  if [[ "$key" == visibility && "$yes" != true ]]; then
    [[ -t 0 ]] || fail "changing the visibility needs --yes"
    source "$LIB_DIR/prompt.sh"
    confirm "Make $repo $new? $(visibility_warning "$new")" || exit 0
  fi
  apply_setting "$new"
}

visibility_warning() {
  if [[ "$current" == public ]]; then echo "It will lose its stars and watchers."; fi
}

# Fails unless the viewer may change the setting; prints its kind, label and value, then the values it
# takes, one per line. The fzf browse calls it before opening the editor.
print_editable() {
  read_setting "$key"
  require_admin
  printf '%s\x1f%s\x1f%s\n' "$kind" "$label" "$current"
  setting_options
}

# The values a switch, choice or branch setting takes, one per line.
setting_options() {
  case "$kind" in
    switch | choice) tr ' ' '\n' <<<"$choices" ;;
    branch) list_branches ;;
  esac
}

list_branches() {
  cached_gh "Loading the branches of ${repo}…" api "repos/$repo/branches?per_page=100" --paginate --jq '.[].name' \
    || fail "could not read the branches of $repo"
}

editor_program="$definitions"'
# The text in pieces of at most $room columns.
def pieces($room):
  . as $text
  | if $text == "" then empty
    else ($text | clipText($room) | if . == "" then $text[0:1] else . end) as $head
      | $head, ($text[($head | length):] | pieces($room)) end;

def caret: " " | paint("7");

settings[] | select(.key == $key)
| ($terminalWidth - 2) as $width
| ($options | split("\n") | map(select(. != ""))) as $values
| (.kind | IN("switch", "choice", "branch")) as $picking
| .value as $current
| def option:
    (if . == $draft then ("› ● " | paint(cyan)) + (. | paint(bold)) else ("  ○ " | paint(dim)) + . end)
    + (if $key == "squash-message" then "  " + (choiceNames[.] // "" | paint(dim)) else "" end)
    + (if . == $current then "  now" | paint(dim) else "" end);
  def options:
    ($values | index($draft) // 0) as $at
    | ([0, $at - 4] | max) as $from
    | ($from + 9) as $to
    | (if $from > 0 then "   ⋮" | paint(dim) else empty end),
      ($values[$from:$to][] | " " + option),
      (if $to < ($values | length) then "   ⋮" | paint(dim) else empty end);
  def field:
    ([$draft | pieces($width - 5)] | if . == [] then [""] else . end) as $lines
    | (frameTop(""; ""; $width),
       ($lines | to_entries[] | .value + (if .key == ($lines | length) - 1 then caret else "" end) | frameLine($width)),
       frameBottom($width))
    | " " + .;
  "",
  " " + (.label | paint(bold)) + (if $draft == $current then "" else "  " + ("● changed" | paint(yellow)) end),
  "",
  (if $picking then options else field end),
  (if $picking or $draft == $current then empty
   else " Now: " + (if $current == "" then "(none)" else $current end) | paint(dim) end),
  (if $key == "visibility" and $draft != $current and $current == "public"
   then " Making it \($draft) loses its stars and watchers." | paint(yellow) else empty end),
  "",
  (.help | [scan(".{1,\($width)}(?:\\s|$)") | " " + rtrimstr(" ")][]),
  "",
  (if $picking then " ← → pick · enter save · esc cancel" else " enter save · esc cancel · empty clears it" end | paint(dim))
'

# The fzf browse's editor pane: the setting with its draft value, and the values it takes.
show_editor() {
  read_setting "$key"
  local options
  options="$(setting_options)"
  render_with true "${COLUMNS:-60}" "$editor_program" --arg key "$key" --arg draft "$value" --arg options "$options" \
    <<<"$item"
}

# The values being saved from the fzf browse, as {key: value}; the list greys their rows out.
saving_values() {
  local file arguments=()
  for file in "${GHS_BROWSE_STATE:-/nonexistent}"/saving/*; do
    [[ -f "$file" ]] && arguments+=(--rawfile "$(basename "$file")" "$file")
  done
  jq -n '$ARGS.named' ${arguments[@]+"${arguments[@]}"}
}

# The fzf preview: the setting, its value, what it does and how to change it from a script.
show_setting() {
  jq -r --arg key "$key" --arg repo "$repo" --argjson width "${COLUMNS:-60}" "$definitions"'
    def bold: "\u001b[1m\(.)\u001b[0m";
    def dim: "\u001b[2m\(.)\u001b[0m";
    settings[] | select(.key == $key)
    | "",
      " " + (.label | bold),
      " " + (if .value == "" then "(none)" | dim else .value end)
        + (if .key == "squash-message" then "  " + (choiceNames[.value] | dim) else "" end),
      "",
      (.help | [scan(".{1,\($width - 2)}(?:\\s|$)") | " " + rtrimstr(" ")][]),
      "",
      (if .choices then " Values: " + (.choices | join(", ")) else empty end),
      (" Enter edits it. From a script:" | dim),
      .value as $value
      | (" ghs settings set \(.key) \(.choices // [] | map(select(. != $value)) | .[0] // "value") -R \($repo)" | dim)
  ' <<<"$item"
}

fetch_settings
case "$verb" in
  set) set_setting ;;
  show) show_setting ;;
  editable) print_editable ;;
  editor) show_editor ;;
  *) show_table setting "$program" --arg repo "$repo" --argjson saving "$(saving_values)" <<<"$item" ;;
esac
