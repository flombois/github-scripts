#!/usr/bin/env bash
# Prints a repository's open issues as a table, sub-issues nested under their parent.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

# `issues 42` shows issue #42.
if [[ "${1:-}" =~ ^#?[0-9]+$ ]]; then
  exec "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/issue.sh" "$@"
fi

usage() {
  cat <<'EOF'
Usage: issues.sh [-R owner/repo] [-s state] [filters] [-i] [--format f] [--refresh] [--offline]
       issues.sh <number> [-c] [-R owner/repo]

Prints the open issues of a GitHub repository as a table, sub-issues nested
under their parent. With an issue number, shows that issue instead; see
issue.sh --help.

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -s, --state state       open (default), closed or all.
  -l, --label name        Only issues with this label; repeat for several.
  -a, --assignee login    Only issues assigned to this login (@me for you).
  -A, --author login      Only issues opened by this login.
  -t, --type name         Only issues of this type, such as Bug.
  -m, --milestone title   Only issues in this milestone.
  -S, --search text       Only issues matching this text (GitHub search syntax).
  -i, --interactive       Browse the issues in fzf, with a preview pane.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
      --offline           Use the cache only, even past 5 minutes; never
                          contact GitHub.
  -h, --help              Show this help.

Filters go through GitHub search, which returns at most 1000 issues.
EOF
}

script_args=("$@")
repo=''
state=open
labels=()
assignee=''
author=''
type=''
milestone=''
search=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -s | --state) needs_value "$1" $#; state="$2"; shift 2 ;;
    -l | --label) needs_value "$1" $#; labels+=("$2"); shift 2 ;;
    -a | --assignee) needs_value "$1" $#; assignee="$2"; shift 2 ;;
    -A | --author) needs_value "$1" $#; author="$2"; shift 2 ;;
    -t | --type) needs_value "$1" $#; type="$2"; shift 2 ;;
    -m | --milestone) needs_value "$1" $#; milestone="$2"; shift 2 ;;
    -S | --search) needs_value "$1" $#; search="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
  esac
done
[[ "$state" =~ ^(open|closed|all)$ ]] || fail "state must be open, closed or all, got: $state"
check_shared_options
repo="$(resolve_repo "$repo")"

# Search qualifiers for the filters, values quoted; empty when there are none.
qualifiers=()
for label in ${labels[@]+"${labels[@]}"}; do qualifiers+=("label:\"$label\""); done
if [[ -n "$assignee" ]]; then qualifiers+=("assignee:$assignee"); fi
if [[ -n "$author" ]]; then qualifiers+=("author:$author"); fi
if [[ -n "$type" ]]; then qualifiers+=("type:\"$type\""); fi
if [[ -n "$milestone" ]]; then qualifiers+=("milestone:\"$milestone\""); fi
if [[ -n "$search" ]]; then qualifiers+=("$search"); fi
filters="${qualifiers[*]+"${qualifiers[*]}"}"

issue_fields='
        number
        title
        state
        stateReason
        updatedAt
        issueType { name color }
        parent { number state }
        subIssuesSummary { total completed }
        labels(first: 10) { nodes { name color } }
        assignees(first: 5) { nodes { login } }'

if [[ -n "$filters" ]]; then
  search_query="repo:$repo is:issue"
  if [[ "$state" != all ]]; then search_query+=" is:$state"; fi
  search_query+=" $filters"
  query="
query(\$q: String!, \$endCursor: String) {
  search(type: ISSUE, query: \$q, first: 100, after: \$endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on Issue { $issue_fields } }
  }
}"
  variables=(-f q="$search_query")
else
  states='OPEN, CLOSED'
  if [[ "$state" != all ]]; then states="$(echo "$state" | tr '[:lower:]' '[:upper:]')"; fi
  query="
query(\$owner: String!, \$name: String!, \$endCursor: String) {
  repository(owner: \$owner, name: \$name) {
    issues(first: 100, after: \$endCursor, states: [$states]) {
      pageInfo { hasNextPage endCursor }
      nodes { $issue_fields }
    }
  }
}"
  variables=(-F owner="${repo%%/*}" -F name="${repo#*/}")
fi

program='
def stateCell:
  if .state == "OPEN" then "open" | cell(green)
  elif .stateReason == "NOT_PLANNED" then "not planned" | cell(gray)
  else "closed" | cell(magenta) end;

def typeCell:
  if .issueType == null then "—" | cell(dim) | decor
  else .issueType as $type | $type.name | cell($type.color | namedColor) end;

def labelUrl: "https://github.com/\($repo)/labels/\(@uri)";

def labelsCell:
  [.labels.nodes[] | .color as $color | (.name | labelUrl) as $url
   | ("● " | cell($color | hexColor) | decor) + (.name | cell("")) | linkTo($url)]
  | joinCells("  " | cell(""));

def assigneesCell:
  [.assignees.nodes[].login | profileUrl as $profile | "@\(.)" | cell(magenta) | linkTo($profile)]
  | if length > 0 then joinCells(" " | cell("")) else "—" | cell(dim) | decor end;

def progressCell:
  .subIssuesSummary as $summary
  | if $summary.total == 0 then [] else progressBar($summary.completed; $summary.total) end;

def row($branch):
  "https://github.com/\($repo)/issues/\(.number)" as $url
  | {_key: ["issue", $repo, .number],
    number: ("#\(.number)" | cell(bold) | linkTo($url)),
    state: stateCell,
    type: typeCell,
    title: (($branch | cell(dim) | decor) + (.title | cell("") | linkTo($url))),
    labels: labelsCell,
    assignees: assigneesCell,
    progress: progressCell,
    updated: (.updatedAt | ago | cell(dim))};

[.[].data | (.repository.issues // .search) | .nodes[]] as $issues
| ([$issues[] | {key: "\(.number)", value: true}] | from_entries) as $listed
| (if $state == "all" then "" else "\($state) " end) as $qualifier
| (if $state == "open" then "open" else "\($qualifier)issues" end) as $counted
| def children($number): $issues | map(select(.parent.number == $number)) | sort_by(.number);
  def subtree($prefix):
    children(.number) as $kids
    | range(0; $kids | length) as $index
    | ($index == ($kids | length) - 1) as $isLast
    | ($kids[$index] | row($prefix + (if $isLast then "└─ " else "├─ " end))),
      ($kids[$index] | subtree($prefix + (if $isLast then "   " else "│  " end)));
  {
    title: (("Issues" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)"))),
    subtitle: ("\($issues | length) \($counted)"
               + (if $filters == "" then "" else " · \($filters)" end)
               + " · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "number", header: "#", align: "right"},
      (if $state == "open" then empty else {key: "state", header: "STATE"} end),
      {key: "type", header: "TYPE"},
      {key: "title", header: "TITLE", flex: true},
      {key: "labels", header: "LABELS", max: 40},
      {key: "assignees", header: "ASSIGNEE"},
      {key: "progress", header: "PROGRESS", drop: true},
      {key: "updated", header: "UPDATED", drop: true}
    ],
    rows: [$issues | map(select(.parent == null or ($listed["\(.parent.number)"] | not))) | sort_by(-.number)[]
           | row(""), subtree("")],
    footer: [
      ("\($issues | length) \($counted)" | cell("")),
      (if $state == "all" then $issues | map(select(.state == "CLOSED")) | length | tally("closed"; magenta)
       else empty end),
      ($issues | map(.issueType | select(. != null)) | group_by(.name)[]
       | .[0].color as $color | "\(.[0].name) \(length)" | cell($color | namedColor)),
      ($issues | map(select(.parent != null)) | length | tally("sub-issues"; "")),
      ($issues | map(select(.assignees.nodes == [])) | length | tally("unassigned"; "")),
      ($issues | map(.labels.nodes[]) | group_by(.name)[]
       | .[0].color as $color | ("●" | cell($color | hexColor)) + (" \(.[0].name) \(length)" | cell("")))
    ],
    empty: (if $filters != "" then "No issues match." else "No \($qualifier)issues." end)
  }
| table
'

issues="$(cached_gh "Loading the issues of ${repo}…" api graphql --paginate --slurp \
  ${variables[@]+"${variables[@]}"} -f query="$query")" \
  || fail "could not read the issues of $repo"

show_table issue "$program" --arg repo "$repo" --arg state "$state" --arg filters "$filters" <<<"$issues"
