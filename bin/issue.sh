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

def personCell: profileUrl as $profile | "@\(.)" | cell(magenta) | linkTo($profile);

def statusLine:
  [stateCell,
   (if $layout == "sidebar" then empty else typeCell end),
   (.author.login // "ghost" | personCell) + (" opened \(.createdAt | ago)" | cell(dim)),
   (if .state == "OPEN" then "updated \(.updatedAt | ago)" else "closed \(.closedAt // .updatedAt | ago)" end
    | cell(dim)),
   (.comments | length | plural("comment") | cell(dim))]
  | joinCells(" · " | cell(dim));

def field($label; $value):
  ($label | 12 - length) as $gap
  | ($label + (" " | times($gap)) | cell(dim)) + $value;

def labelCells:
  (.url | sub("/issues/[0-9]+$"; "/labels/")) as $labelsUrl
  | [.labels[] | .color as $color | "\($labelsUrl)\(.name | @uri)" as $url
     | ("●" | cell($color | hexColor)) + (" \(.name)" | cell("")) | linkTo($url)];

def labelsCell: labelCells | if . == [] then "—" | cell(dim) else joinCells("  " | cell("")) end;

def assigneesCell:
  [.assignees[].login | personCell]
  | if length > 0 then joinCells(" " | cell("")) else "—" | cell(dim) end;

def issueRef: .url as $url | ("#\(.number)" | cell(bold)) + (" \(.title)" | cell("")) | linkTo($url);

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

# The GitHub sidebar: one section per field, a placeholder when it is unset.
def orNone($placeholder): if . == [] then [$placeholder | cell(dim)] else . end;

def sidebarSection($title; $cells): [($title | paint(bold)), ($cells[] | clipCell($terminalWidth) | renderInline)];

def sidebar:
  [sidebarSection("Assignees"; [.assignees[].login | personCell] | orNone("No one assigned")),
   sidebarSection("Labels"; labelCells | orNone("No labels")),
   sidebarSection("Type"; [typeCell] | orNone("No type")),
   sidebarSection("Milestone"; [.milestone // empty | .title | cell("")] | orNone("No milestone")),
   sidebarSection("Parent"; [.parent // empty | issueRef] | orNone("No parent"))]
  | (.[0][]), (.[1:][] | ("─" | times($terminalWidth) | paint(dim)), .[]);

# Markdown without the HTML comments GitHub hides, Windows line ends or surrounding blank lines.
def cleanMarkdown:
  gsub("\r"; "") | gsub("<!--[\\s\\S]*?-->"; "") | gsub("\n{3,}"; "\n\n") | sub("^(\\s*\n)+"; "") | sub("\\s+$"; "");

def textLines($indent): cleanMarkdown | split("\n")[] | $indent + . | sub(" +$"; "");

def hasText: . // "" | test("\\S");

def rule: " " + ("─" | times(if $isTerminal then $terminalWidth - 2 else 100 end) | paint(dim));

def hiddenReason: "(hidden: \(.minimizedReason | ascii_downcase))";

def commentLines:
  " " + ((.author.login // "ghost" | profileUrl as $profile | "@\(.)" | cell(bold) | linkTo($profile))
         + (" · \(.createdAt | ago)" | cell(dim)) | renderInline),
  (if .isMinimized then "    " + (hiddenReason | paint(dim)) else .body | textLines("    ") end),
  "";

def commentMarkdown:
  "**@\(.author.login // "ghost")** · \(.createdAt | ago)\n\n"
  + (if .isMinimized then "_\(hiddenReason)_" else .body | cleanMarkdown end);

def showsComments: $showComments and (.comments | length) > 0;

# The parts are printed one by one so the shell can pass the Markdown ones to glow.
if $part == "header" then
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
  " " + (.url as $url | $url | cell(dim) | linkTo($url) | renderInline),
  ""
end
'

# Puts the sidebar lines (--arg sidebar) beside the main column on stdin, padded to $terminalWidth.
# A main line too wide to share its row keeps it alone. Wide (CJK, emoji) characters count twice.
beside_program='
def wideRanges:
  [[4352,4447],[8986,8987],[9193,9196],[9200,9203],[9725,9726],[9748,9749],[9800,9811],[9855,9855],
   [9875,9875],[9889,9889],[9898,9899],[9917,9918],[9924,9925],[9934,9934],[9940,9940],[9962,9962],
   [9970,9971],[9973,9973],[9978,9978],[9981,9981],[9989,9989],[9994,9995],[10024,10024],[10060,10060],
   [10062,10062],[10067,10069],[10071,10071],[10133,10135],[10160,10160],[10175,10175],[11035,11036],
   [11088,11088],[11093,11093],[11904,12350],[12353,42191],[44032,55203],[63744,64255],[65072,65103],
   [65280,65376],[65504,65510],[127744,128591],[128640,128767],[129280,129535],[129648,129791],
   [131072,262141]];

def charWidth:
  . as $code
  | if $code < 32 or ($code >= 768 and $code <= 879) or ($code >= 8203 and $code <= 8207)
       or ($code >= 65024 and $code <= 65039) then 0
    elif any(wideRanges[]; $code >= .[0] and $code <= .[1]) then 2
    else 1 end;

def visibleWidth:
  gsub("\u001b\\[[0-9;]*m"; "") | gsub("\u001b\\]8;[^\u0007]*\u0007"; "") | explode | map(charWidth) | add // 0;

($sidebar | split("\n")) as $side
| rtrimstr("\n") | split("\n")
| reduce .[] as $line ({lines: [], next: 0};
    if .next >= ($side | length) then .lines += [$line]
    else ($line | visibleWidth) as $used
      | if $used > $terminalWidth then .lines += [$line]
        else .lines += [$line + (" " | times($terminalWidth - $used + 3)) + $side[.next]] | .next += 1 end
    end)
| .lines[], ($side[.next:][] | (" " | times($terminalWidth + 3)) + .)
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
# Like GitHub, the fields move to a sidebar when there is room. Raw Markdown can't be fitted into
# a column, so that needs glow.
layout=stacked
if [[ "$markdown" == true && "$width" -ge 110 ]]; then
  layout=sidebar
fi
sidebar_width=$((width / 4 < 28 ? 28 : width / 4 > 40 ? 40 : width / 4))
main_width=$((width - sidebar_width - 3))

# Usage: print_part part [width]
print_part() {
  render_with "$is_terminal" "${2:-$width}" "$program" --arg part "$1" --arg layout "$layout" \
    --argjson showComments "$show_comments" --argjson markdown "$markdown" <<<"$issue"
}

print_markdown_part() {
  if [[ "$markdown" == true ]]; then
    print_part "$1" "$2" | render_markdown "$2"
  else
    print_part "$1" "$2"
  fi
}

print_main() {
  print_markdown_part body "$1"
  print_part subIssues "$1"
  print_part divider "$1"
  print_markdown_part comments "$1"
}

print_issue() {
  print_part header
  if [[ "$layout" == sidebar ]]; then
    print_main "$main_width" \
      | render_with true "$main_width" "$beside_program" -R -s --arg sidebar "$(print_part sidebar "$sidebar_width")"
  else
    print_main "$width"
  fi
  print_part footer
}

if [[ "$is_terminal" == true ]]; then
  page print_issue
else
  print_issue
fi
