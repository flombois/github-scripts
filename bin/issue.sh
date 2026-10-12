#!/usr/bin/env bash
# Prints one issue: its details, sub-issues and description; -c adds the comments.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"
source "$LIB_DIR/detail.sh"

usage() {
  cat <<'EOF'
Usage: issue.sh <number> [-c] [-R owner/repo] [--refresh]

Prints one issue of a GitHub repository: its state, type, labels, assignees,
parent and sub-issues, then its description. On a terminal, long output is
paged with less (or $PAGER).

Options:
  -c, --comments          Also print the comments.
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
      --refresh           Fetch again instead of using the 5-minute cache.
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
    --refresh) refresh=true; shift ;;
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

program="$DETAIL_JQ"'
def stateCell:
  if .state == "OPEN" then "● Open" | cell(green)
  elif .stateReason == "NOT_PLANNED" then "● Closed as not planned" | cell(gray)
  elif .stateReason == "DUPLICATE" then "● Closed as duplicate" | cell(gray)
  else "● Closed" | cell(magenta) end;

def typeCell:
  if .issueType == null then empty
  else .issueType as $type | $type.name | cell($type.color | namedColor) end;

# On a terminal the state sits on the header frame instead.
def statusCells:
  [(if $isTerminal then empty else stateCell end),
   (if $layout == "sidebar" then empty else typeCell end),
   (.author.login // "ghost" | personCell) + (" opened \(.createdAt | ago)" | cell(dim)),
   (if .state == "OPEN" then "updated \(.updatedAt | ago)" else "closed \(.closedAt // .updatedAt | ago)" end
    | cell(dim)),
   (.comments | length | plural("comment") | cell(dim))];

def statusLine: statusCells | joinCells(" · " | cell(dim));

def subIssueLine:
  (if .state == "CLOSED" then "✓ " | cell(green) else "○ " | cell(dim) end) + issueRef;

def fields:
  field("Labels"; labelsCell),
  field("Assignees"; assigneesCell),
  ((.milestone // empty) as $milestone | field("Milestone"; $milestone.title | cell(""))),
  ((.parent // empty) as $parent | field("Parent"; $parent | issueRef));

def subIssueLines:
  if .subIssues.totalCount == 0 then empty
  else
    (if $markdown then empty else "" end),
    " " + (("Sub-issues  " | cell(bold)) + progressBar(.subIssuesSummary.completed; .subIssuesSummary.total)
           | renderInline),
    (.subIssues.nodes[] | "   " + (subIssueLine | clipCell($terminalWidth - 4) | renderInline)),
    ((.subIssues.totalCount - (.subIssues.nodes | length)) as $more
     | select($more > 0) | "   " + ("… \($more) more" | paint(dim)))
  end;

def sidebar:
  [sidebarSection("Assignees"; [.assignees[].login | personCell] | orNone("No one assigned")),
   sidebarSection("Labels"; labelCells | orNone("No labels")),
   sidebarSection("Type"; [typeCell] | orNone("No type")),
   sidebarSection("Milestone"; [.milestone // empty | .title | cell("")] | orNone("No milestone")),
   sidebarSection("Parent"; [.parent // empty | issueRef] | orNone("No parent"))]
  | sidebarLines;

def showsComments: $showComments and (.comments | length) > 0;

def framedSubIssues:
  if .subIssues.totalCount == 0 then empty
  else
    framedCard(("Sub-issues  " | cell(bold)) + progressBar(.subIssuesSummary.completed; .subIssuesSummary.total);
               [(.subIssues.nodes[] | subIssueLine),
                ((.subIssues.totalCount - (.subIssues.nodes | length)) as $more
                 | select($more > 0) | "… \($more) more" | cell(dim))])
  end;

# The parts are printed one by one so the shell can pass the Markdown ones to glow. On a terminal,
# the description and each comment are cards: the shell frames bodyTitle + body, commentTitle + comment.
if $part == "header" and $isTerminal then
  framedHeader(stateCell; statusCells; [fields])
elif $part == "subIssues" and $isTerminal then
  framedSubIssues
elif $part == "bodyTitle" then
  cardTitle("opened")
elif $part == "commentTitle" then
  .comments[$index] | cardTitle("commented")
elif $part == "description" then
  cardBody
elif $part == "comment" then
  .comments[$index] | cardBody
elif $part == "header" then
  "",
  " " + (.url as $url | ("#\(.number)" | cell(bold)) + ("  " | cell("")) + (.title | cell(bold)) | linkTo($url)
         | renderInline),
  " " + (statusLine | renderInline),
  "",
  (if $layout == "sidebar" then empty else fields | " " + renderInline end),
  rule
elif $part == "sidebar" then
  sidebar
elif $part == "body" then
  if $markdown then
    if .body | hasText then .body | cleanMarkdown else "_No description provided._" end
  elif .body | hasText | not then " " + ("No description provided." | paint(dim))
  else .body | textLines(" ") end
elif $part == "subIssues" then
  subIssueLines
elif $part == "divider" then
  rule,
  (if showsComments then "", " " + ("Comments" | paint(bold)) else empty end)
elif $part == "comments" then
  if showsComments | not then empty
  elif $markdown then [.comments[] | commentMarkdown] | join("\n\n---\n\n")
  else "", (.comments[] | commentLines) end
else
  footerLines
end
'

item="$(cached_gh "Loading issue #$number of ${repo}…" issue view "$number" -R "$repo" --json "$fields")" \
  || fail "could not read issue #$number of $repo"

detail_layout
comment_count="$(jq '.comments | length' <<<"$item")"

print_main() {
  if [[ "$is_terminal" == true ]]; then
    print_card "$1" bodyTitle description
    print_part subIssues "$1"
    if [[ "$show_comments" == true ]]; then
      for ((entry_index = 0; entry_index < comment_count; entry_index++)); do
        print_card "$1" commentTitle comment
      done
    fi
  else
    print_markdown_part body "$1"
    print_part subIssues "$1"
    print_part divider "$1"
    print_markdown_part comments "$1"
  fi
}

print_detail
