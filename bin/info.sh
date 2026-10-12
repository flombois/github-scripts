#!/usr/bin/env bash
# Prints an overview of a repository: stats, recent merges and commits, CI health, latest release, contributors.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"
source "$LIB_DIR/detail.sh"

usage() {
  cat <<'EOF'
Usage: info.sh [-R owner/repo] [--refresh]

Prints an overview of a GitHub repository: its description and stats, recent
merged pull requests and commits, the success rate of each workflow over the
last 100 runs, the latest release and the top contributors.

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
      --refresh           Fetch again instead of using the 5-minute cache.
  -h, --help              Show this help.
EOF
}

repo=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    --refresh) refresh=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done
repo="$(resolve_repo "$repo")"

query='
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    nameWithOwner
    description
    url
    homepageUrl
    stargazerCount
    forkCount
    isPrivate
    isArchived
    isFork
    pushedAt
    primaryLanguage { name }
    licenseInfo { spdxId }
    repositoryTopics(first: 8) { nodes { topic { name } } }
    openIssues: issues(states: OPEN) { totalCount }
    openPullRequests: pullRequests(states: OPEN) { totalCount }
    releases { totalCount }
    latestRelease { tagName name publishedAt url }
    merged: pullRequests(states: MERGED, first: 8, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { number title mergedAt url author { login } }
    }
    defaultBranchRef {
      name
      target {
        ... on Commit {
          history(first: 8) { nodes { messageHeadline committedDate url author { name user { login } } } }
        }
      }
    }
  }
}'

program="$DETAIL_JQ"'
def stat($value; $label): ($value | compactNumber | cell(bold)) + (" \($label)" | cell(dim));

def badge:
  if .isArchived then "Archived" | cell(yellow)
  elif .isPrivate then "Private" | cell(magenta)
  else "Public" | cell(dim) end;

def statCells:
  [stat(.stargazerCount; "stars"), stat(.forkCount; "forks"),
   stat(.openIssues.totalCount; "open issues"), stat(.openPullRequests.totalCount; "open pull requests"),
   (.primaryLanguage.name // empty | cell(cyan)),
   (.licenseInfo.spdxId // empty | select(. != "NOASSERTION") | cell("")),
   ("pushed \(.pushedAt | ago)" | cell(dim))];

def topicCells: [.repositoryTopics.nodes[].topic.name | "#\(.)" | cell(cyan)];

def mergedLines:
  [.merged.nodes | sort_by(.mergedAt) | reverse[]
   | .url as $url
   | ("#\(.number) " | cell(bold) | linkTo($url)) + (.title | cell("") | linkTo($url))
     + ("  @\(.author.login // "ghost") · \(.mergedAt | ago)" | cell(dim))];

def commitLines:
  [.defaultBranchRef.target.history.nodes[]
   | .url as $url
   | (.messageHeadline | cell("") | linkTo($url))
     + ("  \((.author.user.login | select(. != null) | "@" + .) // .author.name) · \(.committedDate | ago)"
        | cell(dim))];

# Success rate per workflow over its finished runs, busiest first.
def ciLines:
  [$runs[] | select(.status == "completed" and (.conclusion | IN("success", "failure", "timed_out", "startup_failure")))
   | {workflow: (if .workflowName == "" then .name else .workflowName end), passed: (.conclusion == "success")}]
  | group_by(.workflow) | sort_by(-length)[0:8]
  | (map(.[0].workflow | length) | max // 0) as $nameWidth
  | map((map(select(.passed)) | length) as $passed
        | length as $total
        | ($passed * 100 / $total | round) as $percent
        | ($percent / 10 | round) as $filled
        | ($nameWidth - (.[0].workflow | length)) as $gap
        | (.[0].workflow + (" " | times($gap)) | cell(""))
          + ("  " | cell(""))
          + ("▰" | times($filled) | cell(if $percent >= 90 then green elif $percent >= 70 then yellow else red end))
          + ("▱" | times(10 - $filled) | cell(dim))
          + (" \($percent)%" | cell(bold)) + (" of \($total)" | cell(dim)));

def releaseLines:
  if .latestRelease == null then ["No releases" | cell(dim)]
  else .latestRelease as $release
    | [($release.tagName | cell(bold) | linkTo($release.url))
       + (if ($release.name // "") != "" and $release.name != $release.tagName then "  \($release.name)" | cell("") else [] end),
       ("published \($release.publishedAt | ago) · \(.releases.totalCount | plural("release")) in all" | cell(dim))]
  end;

def contributorLines:
  ($contributors | map(.contributions) | max // 1) as $most
  | ($contributors | map(.login | length) | max // 0) as $loginWidth
  | [$contributors[]
     | (.contributions * 10 / $most | round) as $filled
     | (.login | profileUrl) as $profile
     | ($loginWidth - (.login | length) + 2) as $gap
     | ("@\(.login)" | cell(magenta) | linkTo($profile))
       + (" " | times($gap) | cell(""))
       + ("▰" | times($filled) | cell(green)) + ("▱" | times(10 - $filled) | cell(dim))
       + (" \(.contributions | compactNumber) commits" | cell(dim))];

def cards($names):
  {merged: ["Recently merged", mergedLines], commits: ["Recent commits on \(.defaultBranchRef.name // "?")", commitLines],
   ci: ["CI health, last 100 runs", ciLines], release: ["Latest release", releaseLines],
   contributors: ["Top contributors", contributorLines]} as $all
  | $names[] as $name
  | $all[$name] as [$title, $lines]
  | if $lines == [] then empty
    elif $isTerminal then framedCard($title | cell(bold); $lines)
    else "", " " + ($title | paint(bold)), ($lines[] | "   " + renderInline) end;

if $part == "header" and $isTerminal then
  (.url as $url
   | "",
     frameTop(.nameWithOwner | cell(bold) | linkTo($url) | renderInline; badge | renderInline; $terminalWidth),
     (((.description // "No description." | split(" ") | map(cell("")) | wrapCells(inner; " " | cell(""))[]),
       (statCells | wrapCells(inner; " · " | cell(dim))[]),
       (topicCells | select(. != []) | wrapCells(inner; " " | cell(""))[])
       | renderInline | frameLine($terminalWidth))),
     frameBottom($terminalWidth),
     "")
elif $part == "header" then
  "",
  " " + (.nameWithOwner | cell(bold) | renderInline) + "  " + (badge | renderInline),
  " " + (.description // "No description."),
  " " + (statCells | joinCells(" · " | cell(dim)) | renderInline),
  (topicCells | select(. != []) | " " + (joinCells(" " | cell("")) | renderInline))
elif $part == "left" then
  cards(["merged", "commits"])
elif $part == "right" then
  cards(["ci", "release", "contributors"])
else
  footerLines
end
'

overview="$(cached_gh "Loading ${repo}…" api graphql -F owner="${repo%%/*}" -F name="${repo#*/}" -f query="$query")" \
  || fail "could not read $repo"
runs="$(cached_gh "Loading the workflow runs of ${repo}…" run list -R "$repo" -L 100 \
  --json workflowName,name,status,conclusion)" || fail "could not read the workflow runs of $repo"
contributors="$(cached_gh "Loading the contributors of ${repo}…" api "repos/$repo/contributors?per_page=6")" \
  || fail "could not read the contributors of $repo"
item="$(jq '.data.repository' <<<"$overview")"
show_comments=false

detail_layout
# Two columns of cards when there is room, glow or not.
columns=$([[ "$is_terminal" == true && "$width" -ge 120 ]] && echo 2 || echo 1)
left_width=$(((width - 3) / 2))
right_width=$((width - 3 - left_width))

# Usage: print_overview_part part [width]
print_overview_part() {
  render_with "$is_terminal" "${2:-$width}" "$program" --arg part "$1" --arg layout "$layout" \
    --argjson showComments false --argjson markdown false --argjson index 0 \
    --argjson runs "$runs" --argjson contributors "$contributors" <<<"$item"
}

print_overview() {
  print_overview_part header
  if [[ "$columns" == 2 ]]; then
    print_overview_part left "$left_width" \
      | render_with true "$left_width" "$beside_program" -R -s --arg sidebar "$(print_overview_part right "$right_width")"
  else
    print_overview_part left
    print_overview_part right
  fi
  print_overview_part footer
}

if [[ "$is_terminal" == true ]]; then
  page print_overview
else
  print_overview
fi
