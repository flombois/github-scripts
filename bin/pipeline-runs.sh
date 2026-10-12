#!/usr/bin/env bash
# Prints a repository's recent GitHub Actions runs as a table.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: pipeline-runs.sh [-R owner/repo] [-b branch] [-w workflow] [-L limit] [-i] [--format f] [--refresh]

Prints the recent GitHub Actions runs of a repository as a table.

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -b, --branch branch     Only runs on this branch.
  -w, --workflow name     Only runs of this workflow (name or file name).
  -L, --limit count       Most recent runs to show (default 20).
  -i, --interactive       Browse the runs in fzf, with a preview pane.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
  -h, --help              Show this help.
EOF
}

script_args=("$@")
repo=''
branch=''
workflow=''
limit=20
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -b | --branch) needs_value "$1" $#; branch="$2"; shift 2 ;;
    -w | --workflow) needs_value "$1" $#; workflow="$2"; shift 2 ;;
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
check_shared_options
repo="$(resolve_repo "$repo")"

program='
def outcome:
  if .status == "completed" then
    {success: ["✓", "success", green], failure: ["✗", "failure", red], timed_out: ["✗", "timed out", red],
     startup_failure: ["✗", "startup failure", red], action_required: ["!", "action required", yellow],
     cancelled: ["⊘", "cancelled", gray], skipped: ["–", "skipped", gray], neutral: ["○", "neutral", gray],
     stale: ["○", "stale", gray]}[.conclusion]
    // ["?", .conclusion, ""]
  else
    {in_progress: ["●", "running", yellow], queued: ["○", "queued", yellow], waiting: ["◷", "waiting", yellow],
     requested: ["○", "requested", yellow], pending: ["○", "pending", yellow]}[.status]
    // ["○", .status, yellow]
  end;

def statusCell: outcome as [$icon, $label, $style] | "\($icon) \($label)" | cell($style);

def titleCell:
  (.displayTitle | cell(""))
  + (if .attempt > 1 then " ↻\(.attempt)" | cell(dim) else [] end);

def durationCell:
  if .status == "completed" then (.updatedAt | fromdateiso8601) - (.startedAt | fromdateiso8601) | duration | cell("")
  elif .status == "in_progress" then now - (.startedAt | fromdateiso8601) | duration | cell(yellow)
  else "—" | cell(dim) | decor end;

def row:
  "https://github.com/\($repo)/actions/runs/\(.databaseId)" as $url
  | {_key: ["run", $repo, .databaseId],
    id: ("\(.databaseId)" | cell(dim) | linkTo($url)),
    status: statusCell,
    workflow: (if .workflowName == "" then .name else .workflowName end | cell(bold)),
    title: (titleCell | linkTo($url)),
    branch: (.headBranch | cell(cyan)),
    event: (.event | cell(dim)),
    duration: durationCell,
    started: (.createdAt | ago | cell(dim))};

. as $runs
| ($runs | map(select(.status == "completed" and .conclusion != "skipped" and .conclusion != "cancelled"))) as $finished
| ([if $branch == "" then empty else "branch \($branch)" end,
    if $workflow == "" then empty else "workflow \($workflow)" end] | join(" · ")) as $filters
| {
    title: (("Pipeline runs" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)"))),
    subtitle: ("last \($runs | length | plural("run"))"
               + (if $filters == "" then "" else " · \($filters)" end)
               + " · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "id", header: "ID", align: "right"},
      {key: "status", header: "STATUS"},
      {key: "workflow", header: "WORKFLOW", max: 28},
      {key: "title", header: "TITLE", flex: true},
      {key: "branch", header: "BRANCH", max: 28},
      {key: "event", header: "EVENT", drop: true},
      {key: "duration", header: "DURATION", align: "right", drop: true},
      {key: "started", header: "STARTED", drop: true}
    ],
    rows: [$runs[] | row],
    footer: [
      ($runs | length | plural("run") | cell("")),
      ($runs | group_by(outcome[1]) | sort_by(-length)[]
       | (.[0] | outcome) as [$icon, $label, $style] | "\($icon) \(length) \($label)" | cell($style)),
      (if $finished == [] then empty
       else "\($finished | map(select(.conclusion == "success")) | length * 100 / ($finished | length) | round)% success rate"
            | cell(bold) end)
    ],
    empty: "No runs found."
  }
| table
'

filters=()
if [[ -n "$branch" ]]; then filters+=(--branch "$branch"); fi
if [[ -n "$workflow" ]]; then filters+=(--workflow "$workflow"); fi

runs="$(cached_gh "Loading the workflow runs of ${repo}…" run list -R "$repo" --limit "$limit" ${filters[@]+"${filters[@]}"} --json \
  databaseId,status,conclusion,name,workflowName,displayTitle,headBranch,event,createdAt,startedAt,updatedAt,attempt)" \
  || fail "could not read the workflow runs of $repo"

show_table run "$program" --arg repo "$repo" --arg branch "$branch" --arg workflow "$workflow" <<<"$runs"
