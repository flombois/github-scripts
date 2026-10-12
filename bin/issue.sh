#!/usr/bin/env bash
# Prints one issue: its details, sub-issues and description; -c adds the comments.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: issue.sh <number> [-c] [-R owner/repo]

Prints one issue of a GitHub repository: its state, type, labels, assignees,
parent and sub-issues, then its description. On a terminal, long output is
paged with less (or $PAGER).

Options:
  -c, --comments          Also print the comments.
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -h, --help              Show this help.
EOF
}

number=''
show_comments=false
repo=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -c | --comments) show_comments=true; shift ;;
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    [0-9]* | '#'[0-9]*)
      [[ -z "$number" ]] || fail "one issue at a time, got #$number and $1"
      [[ "$1" =~ ^#?[1-9][0-9]*$ ]] || fail "not an issue number: $1"
      number="${1#\#}"
      shift
      ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done
if [[ -z "$number" ]]; then
  usage >&2
  fail "an issue number is needed"
fi
repo="$(resolve_repo "$repo")"

fields='number,title,state,stateReason,author,createdAt,updatedAt,closedAt,issueType,labels,assignees,milestone,parent,subIssues,subIssuesSummary,body,url,comments'

program='
def stateCell:
  if .state == "OPEN" then "● Open" | cell(green)
  elif .stateReason == "NOT_PLANNED" then "● Closed as not planned" | cell(gray)
  elif .stateReason == "DUPLICATE" then "● Closed as duplicate" | cell(gray)
  else "● Closed" | cell(magenta) end;

def typeCell:
  if .issueType == null then empty
  else .issueType as $type | $type.name | cell($type.color | namedColor) end;

def statusLine:
  [stateCell,
   typeCell,
   ("@\(.author.login // "ghost")" | cell(magenta)) + (" opened \(.createdAt | ago)" | cell(dim)),
   (if .state == "OPEN" then "updated \(.updatedAt | ago)" else "closed \(.closedAt // .updatedAt | ago)" end
    | cell(dim)),
   (.comments | length | plural("comment") | cell(dim))]
  | joinCells(" · " | cell(dim));

def field($label; $value):
  ($label | 12 - length) as $gap
  | ($label + (" " | times($gap)) | cell(dim)) + $value;

def labelsCell:
  if .labels == [] then "—" | cell(dim)
  else [.labels[] | .color as $color | ("●" | cell($color | hexColor)) + (" \(.name)" | cell(""))]
       | joinCells("  " | cell("")) end;

def assigneesCell:
  [.assignees[].login | "@" + .]
  | if length > 0 then join(" ") | cell(magenta) else "—" | cell(dim) end;

def issueRef: ("#\(.number)" | cell(bold)) + (" \(.title)" | cell(""));

def subIssueLine:
  (if .state == "CLOSED" then "✓ " | cell(green) else "○ " | cell(dim) end) + issueRef;

def fields:
  field("Labels"; labelsCell),
  field("Assignees"; assigneesCell),
  ((.milestone // empty) as $milestone | field("Milestone"; $milestone.title | cell(""))),
  ((.parent // empty) as $parent | field("Parent"; $parent | issueRef)),
  (if .subIssues.totalCount > 0 then
     field("Sub-issues"; progressBar(.subIssuesSummary.completed; .subIssuesSummary.total)),
     (.subIssues.nodes[] | field(""; subIssueLine)),
     ((.subIssues.totalCount - (.subIssues.nodes | length)) as $more
      | select($more > 0) | field(""; "… \($more) more" | cell(dim)))
   else empty end);

# Markdown without the HTML comments GitHub hides, Windows line ends or surrounding blank lines.
def cleanMarkdown:
  gsub("\r"; "") | gsub("<!--[\\s\\S]*?-->"; "") | gsub("\n{3,}"; "\n\n") | sub("^(\\s*\n)+"; "") | sub("\\s+$"; "");

def textLines($indent): cleanMarkdown | split("\n")[] | $indent + . | sub(" +$"; "");

def hasText: . // "" | test("\\S");

def rule: " " + ("─" | times([$terminalWidth - 2, 100] | min) | paint(dim));

def hiddenReason: "(hidden: \(.minimizedReason | ascii_downcase))";

def commentLines:
  " " + (("@\(.author.login // "ghost")" | cell(bold)) + (" · \(.createdAt | ago)" | cell(dim)) | renderInline),
  (if .isMinimized then "    " + (hiddenReason | paint(dim)) else .body | textLines("    ") end),
  "";

def commentMarkdown:
  "**@\(.author.login // "ghost")** · \(.createdAt | ago)\n\n"
  + (if .isMinimized then "_\(hiddenReason)_" else .body | cleanMarkdown end);

def showsComments: $showComments and (.comments | length) > 0;

# The parts are printed one by one so the shell can pass the Markdown ones to glow.
if $part == "header" then
  "",
  " " + (("#\(.number)" | cell(bold)) + ("  " | cell("")) + (.title | cell(bold)) | renderInline),
  " " + (statusLine | renderInline),
  "",
  (fields | " " + renderInline),
  rule
elif $part == "body" then
  if $markdown then
    if .body | hasText then .body | cleanMarkdown else "_No description provided._" end
  elif .body | hasText | not then " " + ("No description provided." | paint(dim))
  else .body | textLines(" ") end
elif $part == "divider" then
  rule,
  (if showsComments then "", " " + ("Comments" | paint(bold)) else empty end)
elif $part == "comments" then
  if showsComments | not then empty
  elif $markdown then [.comments[] | commentMarkdown] | join("\n\n---\n\n")
  else "", (.comments[] | commentLines) end
else
  " " + (.url | paint(dim)),
  ""
end
'

issue="$(gh issue view "$number" -R "$repo" --json "$fields")" \
  || fail "could not read issue #$number of $repo"

is_terminal=false
width=1000
if [[ -t 1 ]]; then
  is_terminal=true
  width="$(terminal_width)"
fi
markdown=false
if [[ "$is_terminal" == true ]] && has_glow; then
  markdown=true
fi

print_part() {
  render_with "$is_terminal" "$width" "$program" --arg part "$1" \
    --argjson showComments "$show_comments" --argjson markdown "$markdown" <<<"$issue"
}

print_markdown_part() {
  if [[ "$markdown" == true ]]; then
    print_part "$1" | render_markdown "$width"
  else
    print_part "$1"
  fi
}

print_issue() {
  print_part header
  print_markdown_part body
  print_part divider
  print_markdown_part comments
  print_part footer
}

if [[ "$is_terminal" == true ]]; then
  page print_issue
else
  print_issue
fi
