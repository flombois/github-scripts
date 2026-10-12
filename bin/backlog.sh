#!/usr/bin/env bash
# Prints a repository's open issues as a table, sub-issues nested under their parent.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

# `backlog 42` shows issue #42.
if [[ "${1:-}" =~ ^#?[0-9]+$ ]]; then
  exec "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/issue.sh" "$@"
fi

usage() {
  cat <<'EOF'
Usage: backlog.sh [-R owner/repo]
       backlog.sh <number> [-c] [-R owner/repo]

Prints the open issues of a GitHub repository as a table. With an issue
number, shows that issue instead; see issue.sh --help.

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -h, --help              Show this help.
EOF
}

repo=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done
repo="$(resolve_repo "$repo")"

query='
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, after: $endCursor, states: OPEN) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        title
        updatedAt
        issueType { name color }
        parent { number state }
        subIssuesSummary { total completed }
        labels(first: 10) { nodes { name color } }
        assignees(first: 5) { nodes { login } }
      }
    }
  }
}'

program='
def typeCell:
  if .issueType == null then "—" | cell(dim)
  else .issueType as $type | $type.name | cell($type.color | namedColor) end;

def labelUrl: "https://github.com/\($repo)/labels/\(@uri)";

def labelsCell:
  [.labels.nodes[] | .color as $color | (.name | labelUrl) as $url
   | ("●" | cell($color | hexColor)) + (" \(.name)" | cell("")) | linkTo($url)]
  | joinCells("  " | cell(""));

def assigneesCell:
  [.assignees.nodes[].login | profileUrl as $profile | "@\(.)" | cell(magenta) | linkTo($profile)]
  | if length > 0 then joinCells(" " | cell("")) else "—" | cell(dim) end;

def progressCell:
  .subIssuesSummary as $summary
  | if $summary.total == 0 then [] else progressBar($summary.completed; $summary.total) end;

def row($branch):
  "https://github.com/\($repo)/issues/\(.number)" as $url
  | {number: ("#\(.number)" | cell(bold) | linkTo($url)),
    type: typeCell,
    title: (($branch | cell(dim)) + (.title | cell("") | linkTo($url))),
    labels: labelsCell,
    assignees: assigneesCell,
    progress: progressCell,
    updated: (.updatedAt | ago | cell(dim))};

[.[].data.repository.issues.nodes[]] as $issues
| def children($number): $issues | map(select(.parent.number == $number)) | sort_by(.number);
  def subtree($prefix):
    children(.number) as $kids
    | range(0; $kids | length) as $index
    | ($index == ($kids | length) - 1) as $isLast
    | ($kids[$index] | row($prefix + (if $isLast then "└─ " else "├─ " end))),
      ($kids[$index] | subtree($prefix + (if $isLast then "   " else "│  " end)));
  {
    title: (("Backlog" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)"))),
    subtitle: ("\($issues | length) open · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "number", header: "#", align: "right"},
      {key: "type", header: "TYPE"},
      {key: "title", header: "TITLE", flex: true},
      {key: "labels", header: "LABELS", max: 40},
      {key: "assignees", header: "ASSIGNEE"},
      {key: "progress", header: "PROGRESS"},
      {key: "updated", header: "UPDATED"}
    ],
    rows: [$issues | map(select(.parent == null or .parent.state != "OPEN")) | sort_by(-.number)[]
           | row(""), subtree("")],
    footer: [
      ("\($issues | length) open" | cell("")),
      ($issues | map(.issueType | select(. != null)) | group_by(.name)[]
       | .[0].color as $color | "\(.[0].name) \(length)" | cell($color | namedColor)),
      ($issues | map(select(.parent != null)) | length | tally("sub-issues"; "")),
      ($issues | map(select(.assignees.nodes == [])) | length | tally("unassigned"; "")),
      ($issues | map(.labels.nodes[]) | group_by(.name)[]
       | .[0].color as $color | ("●" | cell($color | hexColor)) + (" \(.[0].name) \(length)" | cell("")))
    ],
    empty: "No open issues."
  }
| table
'

issues="$(gh api graphql --paginate --slurp \
  -F owner="${repo%%/*}" -F name="${repo#*/}" -f query="$query")" \
  || fail "could not read the issues of $repo"

render_table "$program" --arg repo "$repo" <<<"$issues"
