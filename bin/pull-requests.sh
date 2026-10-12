#!/usr/bin/env bash
# Prints a repository's pull requests as a table with review and check status.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: pull-requests.sh [-R owner/repo] [-s state] [-L limit]

Prints the pull requests of a GitHub repository as a table.

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -s, --state state       open (default), closed, merged or all.
  -L, --limit count       Most recent pull requests to show (default 30).
  -h, --help              Show this help.
EOF
}

repo=''
state='open'
limit=30
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -s | --state) needs_value "$1" $#; state="$2"; shift 2 ;;
    -L | --limit) needs_value "$1" $#; limit="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done
[[ "$state" =~ ^(open|closed|merged|all)$ ]] || fail "state must be open, closed, merged or all, got: $state"
require_count --limit "$limit"
repo="$(resolve_repo "$repo")"

program='
def stateCell:
  {OPEN: ["open", green], MERGED: ["merged", magenta], CLOSED: ["closed", red]}[.state]
  | . as [$text, $style] | $text | cell($style);

def titleCell:
  if .isDraft then ("draft " | cell(gray)) + (.title | cell(dim)) else .title | cell("") end;

def branchCell:
  (.headRefName | cell(cyan)) + (" → \(.baseRefName)" | cell(dim));

def reviewCell:
  {APPROVED: ["✓ approved", green], CHANGES_REQUESTED: ["✗ changes", red], REVIEW_REQUIRED: ["● required", yellow]}
    [.reviewDecision // ""]
  // ["—", dim]
  | . as [$text, $style] | $text | cell($style);

def checkOutcome:
  if .__typename == "StatusContext" then
    {SUCCESS: "pass", FAILURE: "fail", ERROR: "fail"}[.state] // "pending"
  elif .status != "COMPLETED" then "pending"
  else
    {SUCCESS: "pass", NEUTRAL: "pass", SKIPPED: "pass",
     FAILURE: "fail", TIMED_OUT: "fail", CANCELLED: "fail", ACTION_REQUIRED: "fail", STARTUP_FAILURE: "fail"}
      [.conclusion] // "pending"
  end;

def checks: [(.statusCheckRollup // [])[] | checkOutcome];

def checksCell:
  checks as $outcomes
  | ($outcomes | length) as $total
  | "\($outcomes | map(select(. == "pass")) | length)/\($total)" as $count
  | if $total == 0 then "—" | cell(dim)
    elif any($outcomes[]; . == "fail") then "✗ \($count)" | cell(red)
    elif any($outcomes[]; . == "pending") then "● \($count)" | cell(yellow)
    else "✓ \($count)" | cell(green) end;

def sizeCell: ("+\(.additions)" | cell(green)) + (" -\(.deletions)" | cell(red));

def row:
  "https://github.com/\($repo)/pull/\(.number)" as $url
  | {number: ("#\(.number)" | cell(bold) | linkTo($url)),
    state: stateCell,
    title: (titleCell | linkTo($url)),
    author: (.author.login | profileUrl as $profile | "@\(.)" | cell(magenta) | linkTo($profile)),
    branch: branchCell,
    review: reviewCell,
    checks: checksCell,
    size: sizeCell,
    updated: (.updatedAt | ago | cell(dim))};

. as $pulls
| (if $state == "all" then "" else $state + " " end) as $qualifier
| {
    title: (("Pull requests" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)"))),
    subtitle: ("\($pulls | length) \($qualifier)shown"
               + (if ($pulls | length) == $limit then " (limit reached, raise it with -L)" else "" end)
               + " · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "number", header: "#", align: "right"},
      (if $state == "open" then empty else {key: "state", header: "STATE"} end),
      {key: "title", header: "TITLE", flex: true},
      {key: "author", header: "AUTHOR"},
      {key: "branch", header: "BRANCH", max: 36},
      {key: "review", header: "REVIEW"},
      {key: "checks", header: "CHECKS"},
      {key: "size", header: "SIZE"},
      {key: "updated", header: "UPDATED"}
    ],
    rows: [$pulls | sort_by(-.number)[] | row],
    footer: [
      ($pulls | length | plural("\($qualifier)pull request") | cell("")),
      (if $state == "all" then
         ($pulls | map(select(.state == "OPEN")) | length | tally("open"; green)),
         ($pulls | map(select(.state == "MERGED")) | length | tally("merged"; magenta)),
         ($pulls | map(select(.state == "CLOSED")) | length | tally("closed"; red))
       else empty end),
      ($pulls | map(select(.isDraft)) | length | tally("drafts"; gray)),
      ($pulls | map(select(.reviewDecision == "APPROVED")) | length | tally("approved"; green)),
      ($pulls | map(select(.reviewDecision == "CHANGES_REQUESTED")) | length | tally("changes requested"; red)),
      ($pulls | map(select(any(checks[]; . == "fail"))) | length | tally("failing checks"; red))
    ],
    empty: "No \($qualifier)pull requests."
  }
| table
'

pulls="$(gh pr list -R "$repo" --state "$state" --limit "$limit" --json \
  number,title,state,isDraft,author,headRefName,baseRefName,reviewDecision,statusCheckRollup,additions,deletions,updatedAt)" \
  || fail "could not read the pull requests of $repo"

render_table "$program" --arg repo "$repo" --arg state "$state" --argjson limit "$limit" <<<"$pulls"
