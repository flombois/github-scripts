#!/usr/bin/env bash
# Prints a repository's releases as a table with their status, assets and downloads.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: releases.sh [-R owner/repo] [-L limit] [-i] [--format f] [--refresh] [--offline]

Prints the releases of a GitHub repository as a table, newest first: tag,
name, latest / pre-release / draft, author, assets and downloads.

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -L, --limit count       Most recent releases to show (default 20, at most 100).
  -i, --interactive       Browse the releases in fzf, with a preview pane.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
      --offline           Use the cache only, even past 5 minutes; never
                          contact GitHub.
  -h, --help              Show this help.
EOF
}

script_args=("$@")
repo=''
limit=20
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -L | --limit) needs_value "$1" $#; limit="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
  esac
done
require_count --limit "$limit"
[[ "$limit" -le 100 ]] || fail "--limit can be at most 100, got: $limit"
check_shared_options
repo="$(resolve_repo "$repo")"

query='
query($owner: String!, $name: String!, $limit: Int!) {
  repository(owner: $owner, name: $name) {
    releases(first: $limit, orderBy: {field: CREATED_AT, direction: DESC}) {
      totalCount
      nodes {
        tagName
        name
        isDraft
        isPrerelease
        isLatest
        publishedAt
        createdAt
        url
        author { login }
        releaseAssets(first: 50) { totalCount nodes { downloadCount } }
      }
    }
  }
}'

program='
def statusCell:
  if .isDraft then "draft" | cell(gray)
  elif .isLatest then "latest" | cell(green)
  elif .isPrerelease then "pre-release" | cell(yellow)
  else [] end;

def downloads: [.releaseAssets.nodes[].downloadCount] | add // 0;

def row:
  .url as $url
  | {_key: ["release", $repo, .tagName],
     tag: (.tagName | cell(bold) | linkTo($url)),
     name: (if (.name // "") == "" or .name == .tagName then [] else .name | cell("") | linkTo($url) end),
     status: statusCell,
     author: (.author.login // "ghost" | profileUrl as $profile | "@\(.)" | cell(magenta) | linkTo($profile)),
     assets: (.releaseAssets.totalCount | if . == 0 then "—" | cell(dim) | decor else "\(.)" | cell("") end),
     downloads: (downloads | if . == 0 then "—" | cell(dim) | decor else compactNumber | cell("") end),
     published: (.publishedAt // .createdAt | ago | cell(dim))};

.data.repository.releases as $releases
| {
    title: (("Releases" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)"))),
    subtitle: ("\($releases.nodes | length) of \($releases.totalCount) · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "tag", header: "TAG", max: 24},
      {key: "name", header: "NAME", flex: true},
      {key: "status", header: "STATUS"},
      {key: "author", header: "AUTHOR", drop: true},
      {key: "assets", header: "ASSETS", align: "right", drop: true},
      {key: "downloads", header: "DOWNLOADS", align: "right"},
      {key: "published", header: "PUBLISHED"}
    ],
    rows: [$releases.nodes[] | row],
    footer: [
      ($releases.totalCount | plural("release") | cell("")),
      ($releases.nodes | map(select(.isLatest))[0] // empty | "latest \(.tagName)" | cell(green)),
      ($releases.nodes | map(select(.isPrerelease)) | length | tally("pre-releases"; yellow)),
      ($releases.nodes | map(downloads) | add // 0 | select(. > 0)
       | "\(compactNumber) downloads in these \($releases.nodes | length)" | cell(""))
    ],
    empty: "No releases."
  }
| table
'

releases="$(cached_gh "Loading the releases of ${repo}…" api graphql \
  -F owner="${repo%%/*}" -F name="${repo#*/}" -F limit="$limit" -f query="$query")" \
  || fail "could not read the releases of $repo"

show_table release "$program" --arg repo "$repo" <<<"$releases"
