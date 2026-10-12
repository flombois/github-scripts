#!/usr/bin/env bash
# Prints your unread GitHub notifications as a table, grouped by repository.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: notifications.sh [-R owner/repo] [-a] [-p] [-i] [--format f] [--refresh]

Prints your unread GitHub notifications (the 50 most recent) as a table,
grouped by repository: review requests, mentions, assignments, CI runs...

Options:
  -R, --repo owner/repo   Only notifications from this repository.
                          Defaults to all repositories.
  -a, --all               Include notifications already read.
  -p, --participating     Only threads you take part in or are mentioned in.
  -i, --interactive       Browse them in fzf; alt-d marks one as read.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
  -h, --help              Show this help.
EOF
}

script_args=("$@")
repo=''
include_read=false
participating=false
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -a | --all) include_read=true; shift ;;
    -p | --participating) participating=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
  esac
done
check_shared_options
endpoint=notifications
if [[ -n "$repo" ]]; then
  repo="$(resolve_repo "$repo")"
  endpoint="repos/$repo/notifications"
fi
endpoint+="?per_page=50&all=$include_read&participating=$participating"

program='
def reasonText:
  {review_requested: "review requested", approval_requested: "approval requested", mention: "mentioned",
   team_mention: "team mentioned", assign: "assigned", author: "your thread", comment: "commented",
   state_change: "state changed", ci_activity: "CI activity", subscribed: "watching", manual: "subscribed",
   security_alert: "security alert", invitation: "invited", member_feature_requested: "feature request"}[.]
  // gsub("_"; " ");

def reasonStyle:
  {review_requested: yellow, approval_requested: yellow, mention: cyan, team_mention: cyan, assign: magenta,
   security_alert: red}[.] // dim;

# The number at the end of an API URL, such as .../pulls/42.
def tailNumber: . // "" | capture("/(?<number>[0-9]+)$").number // null;

# Where the thread lives on github.com, and how the fzf browse handles it (issue, pr or link).
def target:
  .repository.html_url as $repo
  | (.subject.url | tailNumber) as $number
  | if .subject.type == "PullRequest" and $number then {kind: "pr", id: $number, url: "\($repo)/pull/\($number)"}
    elif .subject.type == "Issue" and $number then {kind: "issue", id: $number, url: "\($repo)/issues/\($number)"}
    elif .subject.type == "Discussion" and $number then {kind: "link", url: "\($repo)/discussions/\($number)"}
    elif .subject.type == "Release" then {kind: "link", url: "\($repo)/releases"}
    elif .subject.type == "Commit" then {kind: "link", url: "\($repo)/commit/\(.subject.url | split("/") | last)"}
    elif .subject.type | IN("CheckSuite", "WorkflowRun") then {kind: "link", url: "\($repo)/actions"}
    else {kind: "link", url: $repo} end
  | .id //= .url;

def typeCell:
  if .subject.type == "PullRequest" then "⇄ PR" | cell(green)
  elif .subject.type == "Issue" then "◎ issue" | cell(green)
  elif .subject.type == "Release" then "⬢ release" | cell(cyan)
  elif .subject.type == "Discussion" then "◆ discussion" | cell(magenta)
  elif .subject.type | IN("CheckSuite", "WorkflowRun") then
    if .subject.title | test("fail"; "i") then "✗ CI" | cell(red) else "✓ CI" | cell(gray) end
  else "• \(.subject.type | ascii_downcase)" | cell(dim) end;

def row:
  target as $target
  | (if .unread then "" else dim end) as $titleStyle
  | (.reason | reasonStyle) as $reasonStyle
  | ("https://github.com/\(.repository.full_name)") as $repoUrl
  | {_key: [$target.kind, .repository.full_name, $target.id, .id],
     repo: (.repository.full_name | cell(cyan) | linkTo($repoUrl)),
     type: typeCell,
     title: (.subject.title | cell($titleStyle) | linkTo($target.url)),
     reason: (.reason | reasonText | cell($reasonStyle)),
     updated: (.updated_at | ago | cell(dim))};

. as $threads
| ($threads | map(select(.unread)) | length) as $unread
| {
    title: (("Notifications" | cell(bold))
            + (if $repo == "" then [] else ("  " | cell("")) + ($repo | cell(cyan)) end)),
    subtitle: ((if $includeRead then "\($threads | length) notifications, \($unread) unread"
                else "\($unread) unread" end)
               + (if ($threads | length) == 50 then " (the 50 most recent)" else "" end)
               + (if $participating then " · participating" else "" end)
               + " · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "repo", header: "REPOSITORY", max: 30},
      {key: "type", header: "TYPE"},
      {key: "title", header: "TITLE", flex: true},
      {key: "reason", header: "REASON", drop: true},
      {key: "updated", header: "UPDATED", drop: true}
    ],
    rows: [$threads | sort_by(.repository.full_name, (.updated_at | fromdateiso8601 | -.))[] | row],
    footer: [
      ($threads | length | plural("notification") | cell("")),
      ($threads | group_by(.reason) | sort_by(-length)[]
       | (.[0].reason | reasonStyle) as $style | "\(length) \(.[0].reason | reasonText)" | cell($style))
    ],
    empty: (if $includeRead then "No notifications." else "Inbox zero: no unread notifications." end)
  }
| table
'

threads="$(cached_gh "Loading your notifications…" api "$endpoint")" \
  || fail "could not read your notifications"

show_table notification "$program" --arg repo "$repo" --argjson includeRead "$include_read" \
  --argjson participating "$participating" <<<"$threads"
