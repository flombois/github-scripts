#!/usr/bin/env bash
# Prints a repository's pull requests as a table with review and check status.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

# `pull-requests 42` shows pull request #42.
if [[ "${1:-}" =~ ^#?[0-9]+$ ]]; then
  exec "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/pull-request.sh" "$@"
fi

usage() {
  cat <<'EOF'
Usage: pull-requests.sh [-R owner/repo] [-s state] [-L limit] [filters] [-i] [--format f] [--refresh]
       pull-requests.sh <number> [-c] [-R owner/repo]

Prints the pull requests of a GitHub repository as a table. With a pull
request number, shows that pull request instead; see pull-request.sh --help.

Options:
  -R, --repo owner/repo     Repository to read; also accepts a GitHub URL.
                            Defaults to the repository of the current directory.
  -s, --state state         open (default), closed, merged or all.
  -L, --limit count         Most recent pull requests to show (default 30).
  -l, --label name          Only pull requests with this label; repeat for several.
  -a, --assignee login      Only pull requests assigned to this login (@me for you).
  -A, --author login        Only pull requests opened by this login.
  -B, --base branch         Only pull requests into this branch.
  -r, --review-requested l  Only pull requests waiting for a review from this login or team.
  -S, --search text         Only pull requests matching this text (GitHub search syntax).
  -i, --interactive         Browse the pull requests in fzf, with a preview pane.
      --format format       table (default), json or csv.
      --refresh             Fetch again instead of using the 5-minute cache.
  -h, --help                Show this help.
EOF
}

script_args=("$@")
repo=''
state='open'
limit=30
labels=()
assignee=''
author=''
base=''
reviewer=''
search=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -s | --state) needs_value "$1" $#; state="$2"; shift 2 ;;
    -L | --limit) needs_value "$1" $#; limit="$2"; shift 2 ;;
    -l | --label) needs_value "$1" $#; labels+=("$2"); shift 2 ;;
    -a | --assignee) needs_value "$1" $#; assignee="$2"; shift 2 ;;
    -A | --author) needs_value "$1" $#; author="$2"; shift 2 ;;
    -B | --base) needs_value "$1" $#; base="$2"; shift 2 ;;
    -r | --review-requested) needs_value "$1" $#; reviewer="$2"; shift 2 ;;
    -S | --search) needs_value "$1" $#; search="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
  esac
done
[[ "$state" =~ ^(open|closed|merged|all)$ ]] || fail "state must be open, closed, merged or all, got: $state"
require_count --limit "$limit"
check_shared_options
repo="$(resolve_repo "$repo")"

# The gh pr list flags for the filters, and how the subtitle names them.
filter_flags=()
shown=()
for label in ${labels[@]+"${labels[@]}"}; do filter_flags+=(--label "$label"); shown+=("label $label"); done
if [[ -n "$assignee" ]]; then filter_flags+=(--assignee "$assignee"); shown+=("assignee $assignee"); fi
if [[ -n "$author" ]]; then filter_flags+=(--author "$author"); shown+=("author $author"); fi
if [[ -n "$base" ]]; then filter_flags+=(--base "$base"); shown+=("base $base"); fi
query="$search"
if [[ -n "$reviewer" ]]; then query="review-requested:$reviewer $query"; shown+=("review requested from $reviewer"); fi
if [[ -n "$search" ]]; then shown+=("\"$search\""); fi
if [[ -n "$query" ]]; then filter_flags+=(--search "$query"); fi
filters=''
for name in ${shown[@]+"${shown[@]}"}; do filters+="${filters:+ · }$name"; done

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

def sizeCell: ("+\(.additions)" | cell(green)) + (" -\(.deletions)" | cell(red));

def row:
  "https://github.com/\($repo)/pull/\(.number)" as $url
  | {_key: ["pr", $repo, .number],
    number: ("#\(.number)" | cell(bold) | linkTo($url)),
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
               + (if $filters == "" then "" else " · \($filters)" end)
               + (if ($pulls | length) == $limit then " (limit reached, raise it with -L)" else "" end)
               + " · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "number", header: "#", align: "right"},
      (if $state == "open" then empty else {key: "state", header: "STATE"} end),
      {key: "title", header: "TITLE", flex: true},
      {key: "author", header: "AUTHOR"},
      {key: "branch", header: "BRANCH", max: 36, drop: true},
      {key: "review", header: "REVIEW"},
      {key: "checks", header: "CHECKS"},
      {key: "size", header: "SIZE", drop: true},
      {key: "updated", header: "UPDATED", drop: true}
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
    empty: (if $filters != "" then "No pull requests match." else "No \($qualifier)pull requests." end)
  }
| table
'

pulls="$(cached_gh "Loading the pull requests of ${repo}…" pr list -R "$repo" --state "$state" --limit "$limit" \
  ${filter_flags[@]+"${filter_flags[@]}"} --json \
  number,title,state,isDraft,author,headRefName,baseRefName,reviewDecision,statusCheckRollup,additions,deletions,updatedAt)" \
  || fail "could not read the pull requests of $repo"

show_table pr "$program" --arg repo "$repo" --arg state "$state" --argjson limit "$limit" --arg filters "$filters" \
  <<<"$pulls"
