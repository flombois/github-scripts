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
Usage: settings.sh [-R owner/repo] [-i] [--format f] [--refresh]
       settings.sh set <setting> <value> [-R owner/repo] [--yes]
       settings.sh rules|secrets|variables|labels [options]

Prints the settings of a GitHub repository: general, features and pull
requests. set changes one; with -i, Enter changes the one under the cursor.
Changing a setting needs admin access to the repository.

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
  -i, --interactive       Browse the settings in fzf; Enter changes one.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
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
    -*)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
    *)
      if [[ -z "$verb" ]]; then verb="$1"
      elif [[ -z "$key" ]]; then key="$1"
      elif [[ "$has_value" == false ]]; then value="$1"; has_value=true
      else usage >&2; fail "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done
case "$verb" in
  '') ;;
  set) [[ -n "$key" && "$has_value" == true ]] || fail "set needs a setting and a value, such as: set wiki off" ;;
  change | show) [[ -n "$key" ]] || fail "$verb needs a setting" ;;
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
           | {_key: ["setting", $repo, .key],
              section: (if $exporting or $index == 0 or $settings[$index - 1].section != .section
                        then .section | cell(bold) else [] end),
              setting: (.label | cell("")),
              value: valueCell,
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

# Asks for a new value on the terminal (fzf's Enter), then confirms and applies it.
change_setting() {
  source "$LIB_DIR/prompt.sh"
  clear_screen
  read_setting "$key"
  ( require_admin ) || { pause; return; }
  local new question
  case "$kind" in
    switch)
      new="$([[ "$current" == on ]] && echo off || echo on)"
      question="Turn $label $new for $repo?"
      ;;
    choice)
      # shellcheck disable=SC2086
      new="$(choose "$label" "$current" $choices)" || return 0
      question="Set $label to $new for $repo?"
      if [[ "$key" == visibility ]]; then question="Make $repo $new? $(visibility_warning "$new")"; fi
      ;;
    branch)
      local branches
      branches="$(gh api "repos/$repo/branches?per_page=100" --paginate --jq '.[].name')" || { pause; return; }
      # shellcheck disable=SC2086
      new="$(IFS=$'\n'; choose "$label" "$current" $branches)" || return 0
      question="Make $new the default branch of $repo?"
      ;;
    *)
      new="$(ask "$label" "$current")" || return 0
      new="$(normalize_value "$new")"
      question="Set $label to \"$new\" for $repo?"
      if [[ -z "$new" ]]; then question="Clear the $label of $repo?"; fi
      ;;
  esac
  [[ "$new" != "$current" ]] || return 0
  if confirm "$question"; then
    apply_setting "$new" || true
    pause
  fi
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
      (" Enter changes it. From a script:" | dim),
      .value as $value
      | (" ghs settings set \(.key) \(.choices // [] | map(select(. != $value)) | .[0] // "value") -R \($repo)" | dim)
  ' <<<"$item"
}

fetch_settings
case "$verb" in
  set) set_setting ;;
  change) change_setting ;;
  show) show_setting ;;
  *) show_table setting "$program" --arg repo "$repo" <<<"$item" ;;
esac
