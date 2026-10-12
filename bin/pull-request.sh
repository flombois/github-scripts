#!/usr/bin/env bash
# Prints one pull request: its status, reviewers, checks, changed files and description; -c adds the comments.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"
source "$LIB_DIR/detail.sh"

usage() {
  cat <<'EOF'
Usage: pull-request.sh <number> [-c] [-R owner/repo] [--watch [s]] [--refresh] [--offline]

Prints one pull request of a GitHub repository: its state, branches,
reviewers, merge status, checks and changed files, then its description.
On a terminal, long output is paged with less (or $PAGER).

Options:
  -c, --comments          Also print the comments and reviews.
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
      --watch [seconds]   Show the checks and redraw them every few seconds
                          (default 5) until none is pending.
      --refresh           Fetch again instead of using the 5-minute cache.
      --offline           Use the cache only, even past 5 minutes; never
                          contact GitHub.
  -h, --help              Show this help.
EOF
}

number=''
show_comments=false
repo=''
watch=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -c | --comments) show_comments=true; shift ;;
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    --refresh) refresh=true; shift ;;
    --offline) export GHS_OFFLINE=1; shift ;;
    --watch) watch_option "$@"; shift "$taken" ;;
    -h | --help) usage; exit 0 ;;
    [0-9]* | '#'[0-9]*)
      [[ -z "$number" ]] || fail "one pull request at a time, got #$number and $1"
      [[ "$1" =~ ^#?[1-9][0-9]*$ ]] || fail "not a pull request number: $1"
      number="${1#\#}"
      shift
      ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done
if [[ -z "$number" ]]; then
  usage >&2
  fail "a pull request number is needed"
fi
repo="$(resolve_repo "$repo")"

fields='number,title,state,isDraft,author,createdAt,updatedAt,mergedAt,mergedBy,closedAt,baseRefName,headRefName'
fields+=',additions,deletions,changedFiles,files,commits,reviewDecision,reviewRequests,latestReviews,reviews'
fields+=',statusCheckRollup,labels,assignees,milestone,closingIssuesReferences,mergeStateStatus,autoMergeRequest'
fields+=',body,url,comments'

program="$DETAIL_JQ"'
def stateCell:
  if .state == "MERGED" then "● Merged" | cell(magenta)
  elif .state == "CLOSED" then "● Closed" | cell(red)
  elif .isDraft then "● Draft" | cell(gray)
  else "● Open" | cell(green) end;

def sizeCells: ("+\(.additions)" | cell(green)) + (" -\(.deletions)" | cell(red));

# "@a wants to merge 3 commits into main from fix", as on GitHub.
def mergeSentence:
  (if .state == "MERGED" then (.mergedBy.login // "ghost" | personCell) + (" merged " | cell(dim))
   else (.author.login // "ghost" | personCell) + (" wants to merge " | cell(dim)) end)
  + (.commits | length | plural("commit") | cell(""))
  + (" into " | cell(dim)) + (.baseRefName | cell(cyan)) + (" from " | cell(dim)) + (.headRefName | cell(cyan));

# On a terminal the state sits on the header frame instead.
def statusCells:
  [(if $isTerminal then empty else stateCell end),
   mergeSentence,
   sizeCells,
   (.changedFiles | plural("file") | cell(dim)),
   (if .state == "MERGED" then "merged \(.mergedAt | ago)"
    elif .state == "CLOSED" then "closed \(.closedAt // .updatedAt | ago)"
    else "updated \(.updatedAt | ago)" end | cell(dim)),
   (.comments | length | plural("comment") | cell(dim))];

def statusLine: statusCells | joinCells(" · " | cell(dim));

def reviewVerb:
  {APPROVED: "approved", CHANGES_REQUESTED: "requested changes", DISMISSED: "reviewed (dismissed)"}[.state]
  // "reviewed";

# Who reviewed (✓ approved, ✗ changes requested, ○ commented) and who is still awaited (●).
def reviewerCells:
  [.latestReviews[] | select(.state != "DISMISSED" and .state != "PENDING")] as $reviews
  | [$reviews[].author.login] as $reviewed
  | [($reviews[]
       | ({APPROVED: ["✓ ", green], CHANGES_REQUESTED: ["✗ ", red]}[.state] // ["○ ", dim]) as [$icon, $style]
       | ($icon | cell($style)) + (.author.login | personCell)),
     (.reviewRequests[]
       | select(.__typename == "Team" or ((.login as $login | $reviewed | index($login)) | not))
       | ("● " | cell(yellow))
         + (if .__typename == "Team" then .name // .slug | cell(magenta) else .login | personCell end))];

def linkedCells:
  (.url | capture("github.com/(?<repo>[^/]+/[^/]+)/").repo) as $here
  | [.closingIssuesReferences[]
     | "\(.repository.owner.login)/\(.repository.name)" as $there
     | .url as $url
     | (if $there == $here then "#\(.number)" else "\($there)#\(.number)" end) | cell(bold) | linkTo($url)];

def mergeCells:
  if .state == "MERGED" then ["✓ Merged" | cell(magenta)]
  elif .state == "CLOSED" then ["Closed without merging" | cell(dim)]
  else
    [(({CLEAN: ["✓ Ready to merge", green], HAS_HOOKS: ["✓ Ready to merge", green],
        UNSTABLE: ["● Ready, some checks not passing", yellow], BLOCKED: ["✗ Blocked", red],
        BEHIND: ["● Behind the base branch", yellow], DIRTY: ["✗ Merge conflicts", red],
        DRAFT: ["● Draft", gray]}[.mergeStateStatus] // ["○ Checking mergeability", dim]) as [$text, $style]
      | $text | cell($style)),
     (if .mergeStateStatus != "BLOCKED" then empty
      elif .reviewDecision == "CHANGES_REQUESTED" then "changes requested" | cell(dim)
      elif .reviewDecision == "REVIEW_REQUIRED" then "review required" | cell(dim)
      elif any(checks[]; . != "pass") then "checks not passing" | cell(dim)
      else empty end),
     (.autoMergeRequest // empty | "Auto-merge on (\(.mergeMethod | ascii_downcase))" | cell(green))]
  end;

def fields:
  ((reviewerCells | select(. != [])) | field("Reviewers"; joinCells("  " | cell("")))),
  field("Assignees"; assigneesCell),
  field("Labels"; labelsCell),
  ((.milestone // empty) as $milestone | field("Milestone"; $milestone.title | cell(""))),
  ((linkedCells | select(. != [])) | field("Linked"; joinCells(" " | cell("")))),
  field("Merge"; mergeCells | joinCells(" · " | cell(dim)));

def sidebar:
  [sidebarSection("Reviewers"; reviewerCells | orNone("No reviews")),
   sidebarSection("Assignees"; [.assignees[].login | personCell] | orNone("No one assigned")),
   sidebarSection("Labels"; labelCells | orNone("No labels")),
   sidebarSection("Milestone"; [.milestone // empty | .title | cell("")] | orNone("No milestone")),
   sidebarSection("Linked issues"; linkedCells | orNone("None")),
   sidebarSection("Merge"; mergeCells)]
  | sidebarLines;

def checkLine:
  checkOutcome as $outcome
  | (if .conclusion == "SKIPPED" or .conclusion == "NEUTRAL" then ["– ", gray]
     else {pass: ["✓ ", green], fail: ["✗ ", red], pending: ["● ", yellow]}[$outcome] end) as [$icon, $style]
  | (.detailsUrl // .targetUrl) as $url
  | ($icon | cell($style)) + (.name // .context | cell("") | linkTo($url))
    + (if .workflowName // "" | length > 0 then "  \(.workflowName)" | cell(dim) else [] end);

def checkLines($limit):
  [(.statusCheckRollup // [])[] | {check: ., order: (if .conclusion == "SKIPPED" or .conclusion == "NEUTRAL" then 3 else {fail: 0, pending: 1, pass: 2}[checkOutcome] end)}]
  | sort_by(.order) | map(.check) as $checks
  | ($checks[0:$limit][] | checkLine),
    (($checks | length) - $limit | select(. > 0) | "… \(.) more" | cell(dim));

def checksTitle: ("Checks  " | cell(bold)) + checksCell;

# A five-cell bar of the added (green) and deleted (red) share of the changes to a file.
def diffBar:
  (.additions + .deletions) as $total
  | if $total == 0 then "▱▱▱▱▱" | cell(dim)
    else (.additions * 5 / $total | round) as $added
      | ("▰" | times($added) | cell(green)) + ("▰" | times(5 - $added) | cell(red)) end;

def fileLines($limit):
  "\(.url)/files" as $url
  | (.files | sort_by(-(.additions + .deletions))) as $files
  | ([$files[0:$limit][] | "+\(.additions) -\(.deletions)" | length] | max // 0) as $sizeWidth
  | ($files[0:$limit][]
     | ("+\(.additions) -\(.deletions)" | length) as $size
     | diffBar + ("  " | cell("")) + ("+\(.additions)" | cell(green)) + (" -\(.deletions)" | cell(red))
       + (" " | times($sizeWidth - $size + 2) | cell("")) + (.path | cell("") | linkTo($url))),
    ((.changedFiles - $limit) | select(. > 0) | "… \(.) more files" | cell(dim));

def filesTitle: ("Files changed  " | cell(bold)) + ("\(.changedFiles)  " | cell("")) + sizeCells;

# Comments and reviews (those with a body or a verdict), oldest first.
def timeline:
  [(.comments[] | {kind: "comment", at: .createdAt, entry: .}),
   (.reviews[] | select(.state != "PENDING")
    | select((.body | hasText) or .state == "APPROVED" or .state == "CHANGES_REQUESTED")
    | {kind: "review", at: .submittedAt, entry: (. + {createdAt: .submittedAt})})]
  | sort_by(.at);

def entryTitle: if .kind == "review" then .entry | cardTitle(reviewVerb) else .entry | cardTitle("commented") end;

def entryBody:
  if .kind == "review" and (.entry.body | hasText | not) then
    if $markdown then "_No comment._" else "No comment." | paint(dim) end
  else .entry | cardBody end;

def entryLines:
  .kind as $kind
  | .entry
  | " " + ((.author.login // "ghost" | profileUrl as $profile | "@\(.)" | cell(bold) | linkTo($profile))
           + (if $kind == "review" then " \(reviewVerb)" | cell(bold) else [] end)
           + (" · \(.createdAt | ago)" | cell(dim)) | renderInline),
    (if .isMinimized then "    " + (hiddenReason | paint(dim))
     elif .body | hasText then .body | textLines("    ")
     else empty end),
    "";

def showsComments: $showComments and (timeline | length) > 0;

def plainSection($title; $lines): "", " " + ($title | renderInline), ($lines[] | "   " + (clipCell($terminalWidth - 4) | renderInline));

# The parts are printed one by one so the shell can pass the Markdown ones to glow. On a terminal the
# description and each timeline entry are cards: the shell frames bodyTitle + description, entryTitle + entry.
if $part == "header" and $isTerminal then
  framedHeader(stateCell; statusCells; [fields])
elif $part == "checks" and $isTerminal then
  if (.statusCheckRollup // []) == [] then empty else framedCard(checksTitle; [checkLines(30)]) end
elif $part == "files" and $isTerminal then
  if .changedFiles == 0 then empty else framedCard(filesTitle; [fileLines(15)]) end
elif $part == "bodyTitle" then
  cardTitle("opened")
elif $part == "description" then
  cardBody
elif $part == "pendingCount" then
  [checks[] | select(. == "pending")] | length
elif $part == "entryCount" then
  timeline | length
elif $part == "entryTitle" then
  timeline[$index] | entryTitle
elif $part == "entry" then
  timeline[$index] | entryBody
elif $part == "header" then
  "",
  " " + (.url as $url | ("#\(.number)" | cell(bold)) + ("  " | cell("")) + (.title | cell(bold)) | linkTo($url)
         | renderInline),
  " " + (statusLine | renderInline),
  "",
  (fields | " " + renderInline),
  rule
elif $part == "sidebar" then
  sidebar
elif $part == "body" then
  if .body | hasText then .body | textLines(" ") else " " + ("No description provided." | paint(dim)) end
elif $part == "checks" then
  if (.statusCheckRollup // []) == [] then empty else plainSection(checksTitle; [checkLines(1000)]) end
elif $part == "files" then
  if .changedFiles == 0 then empty else plainSection(filesTitle; [fileLines(1000)]) end
elif $part == "divider" then
  "",
  rule,
  (if showsComments then "", " " + ("Comments and reviews" | paint(bold)) else empty end)
elif $part == "comments" then
  if showsComments | not then empty else "", (timeline[] | entryLines) end
else
  footerLines
end
'

fetch_pull_request() {
  item="$(cached_gh "Loading pull request #$number of ${repo}…" pr view "$number" -R "$repo" --json "$fields")" \
    || fail "could not read pull request #$number of $repo"
}

# The --watch screen: the header and the checks.
draw_checks() {
  detail_layout
  print_part header
  print_part checks
}

checks_pending() {
  [[ "$(print_part pendingCount)" -gt 0 ]]
}

if [[ -n "$watch" ]]; then
  detail_layout
  watch_loop "$watch" fetch_pull_request draw_checks checks_pending
  exit 0
fi

fetch_pull_request
detail_layout

print_main() {
  if [[ "$is_terminal" == true ]]; then
    print_card "$1" bodyTitle description
    print_part checks "$1"
    print_part files "$1"
    if [[ "$show_comments" == true ]]; then
      local count
      count="$(print_part entryCount "$1")"
      for ((entry_index = 0; entry_index < count; entry_index++)); do
        print_card "$1" entryTitle entry
      done
    fi
  else
    print_part body "$1"
    print_part checks "$1"
    print_part files "$1"
    print_part divider "$1"
    print_part comments "$1"
  fi
}

print_detail
