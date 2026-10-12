#!/usr/bin/env bash
# Prints a repository's rulesets and classic branch protection rules, and turns rulesets on or off.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ghs settings rules [-R owner/repo] [-i] [--format f] [--refresh]
       ghs settings rules show <ruleset>
       ghs settings rules set <ruleset> active|evaluate|disabled

Prints the rulesets that apply to a GitHub repository, its own and those of
its organisation, with what they protect and how they are enforced, then its
classic branch protection rules (shown to admins only). A ruleset is named by
its id or its name.

  show      Prints one ruleset or protection rule in full.
  set       Enforces a ruleset (active), only reports what it would block
            (evaluate) or turns it off (disabled). Needs admin access, and the
            ruleset must belong to the repository.

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -i, --interactive       Browse the rules in fzf; alt keys turn them on or off.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
  -h, --help              Show this help.
EOF
}

script_args=("$@")
repo=''
verb=''
name=''
state=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
    *)
      if [[ -z "$verb" ]]; then verb="$1"
      elif [[ -z "$name" ]]; then name="$1"
      elif [[ -z "$state" ]]; then state="$1"
      else usage >&2; fail "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done
case "$verb" in
  '') ;;
  show) [[ -n "$name" ]] || fail "show needs a ruleset id or name" ;;
  set | change)
    [[ -n "$name" && -n "$state" ]] || fail "$verb needs a ruleset and a state, such as: set 42 disabled"
    [[ "$state" =~ ^(active|evaluate|disabled)$ ]] || fail "state must be active, evaluate or disabled, got: $state"
    ;;
  *) usage >&2; fail "unknown command: settings rules $verb" ;;
esac
check_shared_options
repo="$(resolve_repo "$repo")"

query='
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    viewerPermission
    rulesets(first: 100, includeParents: true) {
      nodes {
        databaseId
        name
        target
        enforcement
        conditions { refName { include exclude } }
        bypassActors { totalCount }
        rules(first: 50) {
          nodes {
            type
            parameters {
              __typename
              ... on PullRequestParameters {
                requiredApprovingReviewCount requireCodeOwnerReview dismissStaleReviewsOnPush
                requiredReviewThreadResolution requireLastPushApproval
              }
              ... on RequiredStatusChecksParameters { strictRequiredStatusChecksPolicy requiredStatusChecks { context } }
              ... on RequiredDeploymentsParameters { requiredDeploymentEnvironments }
              ... on CommitMessagePatternParameters { operator pattern negate name }
              ... on BranchNamePatternParameters { operator pattern negate name }
              ... on TagNamePatternParameters { operator pattern negate name }
              ... on CommitAuthorEmailPatternParameters { operator pattern negate name }
              ... on CommitterEmailPatternParameters { operator pattern negate name }
              ... on WorkflowsParameters { workflows { path } }
              ... on FilePathRestrictionParameters { restrictedFilePaths }
              ... on FileExtensionRestrictionParameters { restrictedFileExtensions }
              ... on MaxFilePathLengthParameters { maxFilePathLength }
              ... on MaxFileSizeParameters { maxFileSize }
              ... on UpdateParameters { updateAllowsFetchAndMerge }
            }
          }
        }
      }
    }
    branchProtectionRules(first: 100) {
      nodes {
        pattern
        requiresApprovingReviews requiredApprovingReviewCount requiresCodeOwnerReviews dismissesStaleReviews
        requiresStatusChecks requiresStrictStatusChecks requiredStatusCheckContexts
        requiresConversationResolution requiresCommitSignatures requiresLinearHistory requiresDeployments
        allowsForcePushes allowsDeletions isAdminEnforced lockBranch restrictsPushes
        matchingRefs { totalCount }
      }
    }
  }
}'

# Rulesets and classic rules in one shape: {kind, id, name, target, enforcement, source, include,
# exclude, bypass, matching, rules: [{short, long, details}]}. GraphQL can't read where an inherited
# ruleset comes from, so the REST list ($sources) tells.
definitions='
def refName($target):
  if . == "~DEFAULT_BRANCH" then "default branch"
  elif . == "~ALL" then "all \({tag: "tags", push: "pushes"}[$target] // "branches")"
  else sub("^refs/(heads|tags)/"; "") end;

def ruleNames:
  {CREATION: ["restrict creation", "Restrict creations"],
   UPDATE: ["restrict updates", "Restrict updates"],
   DELETION: ["restrict deletion", "Restrict deletions"],
   NON_FAST_FORWARD: ["no force push", "Block force pushes"],
   REQUIRED_LINEAR_HISTORY: ["linear history", "Require linear history"],
   REQUIRED_SIGNATURES: ["signed commits", "Require signed commits"],
   REQUIRED_DEPLOYMENTS: ["deployments", "Require deployments to succeed"],
   MERGE_QUEUE: ["merge queue", "Require merge queue"],
   PULL_REQUEST: ["pull request", "Require a pull request before merging"],
   REQUIRED_STATUS_CHECKS: ["status checks", "Require status checks to pass"],
   WORKFLOWS: ["workflows", "Require workflows to pass"],
   CODE_SCANNING: ["code scanning", "Require code scanning results"],
   COPILOT_CODE_REVIEW: ["Copilot review", "Request a Copilot code review"],
   COMMIT_MESSAGE_PATTERN: ["commit message pattern", "Commit message pattern"],
   COMMIT_AUTHOR_EMAIL_PATTERN: ["author email pattern", "Commit author email pattern"],
   COMMITTER_EMAIL_PATTERN: ["committer email pattern", "Committer email pattern"],
   BRANCH_NAME_PATTERN: ["branch name pattern", "Branch name pattern"],
   TAG_NAME_PATTERN: ["tag name pattern", "Tag name pattern"],
   FILE_PATH_RESTRICTION: ["restricted paths", "Restrict file paths"],
   FILE_EXTENSION_RESTRICTION: ["restricted extensions", "Restrict file extensions"],
   MAX_FILE_PATH_LENGTH: ["path length", "Restrict file path length"],
   MAX_FILE_SIZE: ["file size", "Restrict file size"]};

def patternText:
  (if .negate then "must not " else "must " end)
  + ({starts_with: "start with", ends_with: "end with", contains: "contain", regex: "match"}[.operator] // .operator)
  + " " + .pattern;

def approvals: if . == 1 then "1 approval" else "\(.) approvals" end;

def ruleDetails:
  .parameters as $parameters
  | if $parameters == null then []
    elif .type == "PULL_REQUEST" then
      [($parameters.requiredApprovingReviewCount | approvals),
       (if $parameters.requireCodeOwnerReview then "code owner review" else empty end),
       (if $parameters.dismissStaleReviewsOnPush then "new pushes dismiss approvals" else empty end),
       (if $parameters.requireLastPushApproval then "someone else approves the last push" else empty end),
       (if $parameters.requiredReviewThreadResolution then "conversations resolved" else empty end)]
    elif .type == "REQUIRED_STATUS_CHECKS" then
      [$parameters.requiredStatusChecks[].context]
      + (if $parameters.strictRequiredStatusChecksPolicy then ["branch up to date with its base"] else [] end)
    elif $parameters | has("pattern") then [($parameters.name // "" | select(. != "")), ($parameters | patternText)]
    elif .type == "REQUIRED_DEPLOYMENTS" then $parameters.requiredDeploymentEnvironments
    elif .type == "WORKFLOWS" then [$parameters.workflows[].path]
    elif .type == "FILE_PATH_RESTRICTION" then $parameters.restrictedFilePaths
    elif .type == "FILE_EXTENSION_RESTRICTION" then $parameters.restrictedFileExtensions
    elif .type == "MAX_FILE_SIZE" then ["up to \($parameters.maxFileSize) MB"]
    elif .type == "MAX_FILE_PATH_LENGTH" then ["up to \($parameters.maxFilePathLength) characters"]
    elif .type == "UPDATE" and $parameters.updateAllowsFetchAndMerge then ["fetch and merge still allowed"]
    else [] end;

def rule:
  (ruleNames[.type] // [.type | ascii_downcase | gsub("_"; " ")] * 2) as [$short, $long]
  | ruleDetails as $details
  | {short: (if .type == "PULL_REQUEST" and .parameters.requiredApprovingReviewCount > 0 then "\($short) (\($details[0]))"
             elif .type == "REQUIRED_STATUS_CHECKS" then "\($short) (\(.parameters.requiredStatusChecks | length))"
             else $short end),
     long: $long, details: $details};

def rulesetEntry($sources; $repo):
  ($sources[.databaseId | tostring] // {}) as $source
  | (.target | ascii_downcase) as $target
  | {kind: "ruleset", id: (.databaseId | tostring), name, target: $target,
     enforcement: (.enforcement | ascii_downcase),
     source: {type: ($source.source_type // "Repository" | ascii_downcase), name: ($source.source // $repo)},
     include: [.conditions.refName.include // [] | .[] | refName($target)],
     exclude: [.conditions.refName.exclude // [] | .[] | refName($target)],
     bypass: .bypassActors.totalCount, matching: null,
     rules: [.rules.nodes[] | rule]};

def classicRule($short; $long; $details): {short: $short, long: $long, details: $details};

def branchRuleEntry($repo):
  {kind: "branch-rule", id: .pattern, name: .pattern, target: "branch", enforcement: "active",
   source: {type: "classic", name: $repo}, include: [.pattern], exclude: [], bypass: null,
   matching: .matchingRefs.totalCount,
   rules: [
     (if .requiresApprovingReviews then
        (.requiredApprovingReviewCount | approvals) as $approvals
        | classicRule("pull request (\($approvals))"; "Require a pull request before merging";
            [$approvals, (if .requiresCodeOwnerReviews then "code owner review" else empty end),
             (if .dismissesStaleReviews then "new pushes dismiss approvals" else empty end)])
      else empty end),
     (if .requiresStatusChecks then
        classicRule("status checks (\(.requiredStatusCheckContexts | length))"; "Require status checks to pass";
          .requiredStatusCheckContexts + (if .requiresStrictStatusChecks then ["branch up to date with its base"] else [] end))
      else empty end),
     (if .requiresConversationResolution then classicRule("conversations resolved"; "Require conversation resolution"; []) else empty end),
     (if .requiresCommitSignatures then classicRule("signed commits"; "Require signed commits"; []) else empty end),
     (if .requiresLinearHistory then classicRule("linear history"; "Require linear history"; []) else empty end),
     (if .requiresDeployments then classicRule("deployments"; "Require deployments to succeed"; []) else empty end),
     (if .lockBranch then classicRule("locked"; "Lock branch"; []) else empty end),
     (if .restrictsPushes then classicRule("restrict pushes"; "Restrict who can push"; []) else empty end),
     (if .allowsForcePushes then empty else classicRule("no force push"; "Block force pushes"; []) end),
     (if .allowsDeletions then empty else classicRule("restrict deletion"; "Restrict deletions"; []) end),
     (if .isAdminEnforced then classicRule("admins included"; "Apply the rules to admins too"; []) else empty end)]};

def entries($sources; $repo):
  [.branchProtectionRules.nodes[] | branchRuleEntry($repo)] as $classic
  | [.rulesets.nodes[] | rulesetEntry($sources; $repo)]
  | map(select(.source.type == "repository")) + map(select(.source.type != "repository")) + $classic;

def entryUrl($repo):
  if .kind == "ruleset" then "https://github.com/\($repo)/rules/\(.id)"
  else "https://github.com/\($repo)/settings/branches" end;

def sourceText:
  if .source.type == "classic" then "classic protection"
  elif .source.type == "repository" then "this repository"
  else "\(.source.type) \(.source.name)" end;
'

program="$definitions"'
def statusCell:
  if .enforcement == "active" then ("● " | cell(green) | decor) + ("active" | cell(green))
  elif .enforcement == "evaluate" then ("◐ " | cell(yellow) | decor) + ("evaluate" | cell(yellow))
  else ("○ " | cell(dim) | decor) + ("disabled" | cell(dim)) end;

def appliesText: (.include | join(", ")) + (if .exclude == [] then "" else " except \(.exclude | join(", "))" end);

entries($sources; $repo) as $entries
| ($entries | map(select(.kind == "ruleset"))) as $rulesets
| ($entries | map(select(.kind == "branch-rule"))) as $classic
| .viewerPermission as $permission
| {
    title: (("Rules" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)/rules"))),
    subtitle: ("\($rulesets | length | plural("ruleset"))"
               + (if $classic == [] then "" else ", \($classic | length | plural("classic rule"))" end)
               + " · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "name", header: "NAME", max: 36},
      {key: "target", header: "TARGET"},
      {key: "applies", header: "APPLIES TO", max: 28},
      {key: "rules", header: "RULES", flex: true},
      {key: "status", header: "STATUS"},
      {key: "source", header: "SOURCE", drop: true},
      {key: "bypass", header: "BYPASS", align: "right", drop: true}
    ],
    rows: [$entries[]
           | entryUrl($repo) as $url
           | {_key: [.kind, $repo, .id, .name],
              name: (.name | cell("") | linkTo($url)),
              target: (.target | cell(dim)),
              applies: (if .include == [] then "—" | cell(dim) | decor else appliesText | cell("") end),
              rules: ([.rules[].short] | join(", ") | cell("")),
              status: statusCell,
              source: (sourceText | cell(dim)),
              bypass: (if .bypass == null then "—" | cell(dim) | decor else "\(.bypass)" | cell("") end)}],
    footer: [
      ($rulesets | map(select(.enforcement == "active")) | length | tally("active"; green)),
      ($rulesets | map(select(.enforcement == "evaluate")) | length | tally("evaluating"; yellow)),
      ($rulesets | map(select(.enforcement == "disabled")) | length | tally("disabled"; dim)),
      ($rulesets | map(select(.source.type != "repository")) | length | tally("inherited"; "")),
      (if $permission == "ADMIN" then empty else "classic rules show to admins only" | cell(dim) end)
    ],
    empty: "No rulesets or branch protection rules."
  }
| table
'

# Prints one entry in full: framed on a terminal, plain when piped.
show_program="$definitions"'
# A line is {indent, lead, text}: the lead (such as a field label) stays put, the text wraps under itself.
def line($indent; $lead; $text): {indent: $indent, lead: $lead, text: $text};
def field($label; $value): line(0; "\($label)" + (" " | times(12 - ($label | length))) | cell(dim); $value | cell(""));

def statusCell:
  if .enforcement == "active" then "● active" | cell(green)
  elif .enforcement == "evaluate" then "◐ evaluate" | cell(yellow)
  else "○ disabled" | cell(dim) end;

def lines:
  [line(0; []; "\(.target) \(if .kind == "ruleset" then "ruleset" else "protection rule" end) · \(sourceText)"
                + (if .kind == "ruleset" then " · id \(.id)" else "" end) | cell(dim)),
   line(0; []; []),
   field("Applies to"; .include | if . == [] then "set by other conditions" else join(", ") end),
   (if .exclude == [] then empty else field("Excluding"; .exclude | join(", ")) end),
   (if .matching == null then empty else field("Matches"; if .matching == 1 then "1 branch" else "\(.matching) branches" end) end),
   (if .bypass == null then empty else field("Bypass"; if .bypass == 0 then "nobody" else .bypass | plural("actor") end) end),
   line(0; []; []),
   line(0; []; "Rules" | cell(bold)),
   (if .rules == [] then line(0; []; "none" | cell(dim)) else empty end),
   (.rules[] | line(0; "✓ " | cell(green); .long | cell("")), (.details[] | line(2; []; cell(dim))))];

def wrapped($width):
  .indent as $indent
  | (" " | times($indent) | cell("")) as $margin
  | ($margin + .lead) as $start
  | ($start | cellWidth) as $used
  | if .text == [] then $start
    else [(.text | words | wrapCells($width - $used; " " | cell("")))[]] as $pieces
      | ($start + $pieces[0]), ($pieces[1:][] | ((" " | times($used)) | cell("")) + .)
    end;

(if $isTerminal then $terminalWidth - 4 else 100 end) as $width
| entryUrl($repo) as $url
| (.name | cell(bold) | linkTo($url)) as $title
| if $isTerminal then
    "",
    frameTop($title | renderInline; statusCell | renderInline; $terminalWidth),
    (lines[] | wrapped($width) | clipCell($width) | renderInline | frameLine($terminalWidth)),
    frameBottom($terminalWidth),
    ""
  else
    "",
    " " + ($title | renderInline) + "  " + (statusCell | renderInline),
    (lines[] | wrapped($width) | " " + renderInline | sub(" +$"; "")),
    ""
  end
'

query_args=(api graphql -F owner="${repo%%/*}" -F name="${repo#*/}" -f query="$query")
sources_args=(api "repos/$repo/rulesets?per_page=100&includes_parents=true")
fetch_rules() {
  item="$(cached_gh "Loading the rules of ${repo}…" "${query_args[@]}")" || fail "could not read the rules of $repo"
  item="$(jq '.data.repository' <<<"$item")"
  sources="$(cached_gh "Loading the ruleset sources of ${repo}…" "${sources_args[@]}")" \
    || fail "could not read the rulesets of $repo"
  sources="$(jq 'map({key: (.id | tostring), value: {source_type, source}}) | from_entries' <<<"$sources")"
}

# Usage: find_entry id-or-name
# Prints the entry as JSON, or fails when there is none.
find_entry() {
  local entry
  entry="$(jq -c --arg name "$1" --arg repo "$repo" --argjson sources "$sources" "$(cat "$LIB_DIR/table.jq")
$definitions"'
    first(entries($sources; $repo)[] | select(.id == $name or .name == $name)) // empty
  ' --argjson isTerminal false --argjson terminalWidth 100 <<<"$item")"
  [[ -n "$entry" ]] || fail "no ruleset or protection rule named $1 in $repo"
  echo "$entry"
}

show_entry() {
  local entry
  entry="$(find_entry "$name")"
  if on_terminal; then
    page render_table "$show_program" --arg repo "$repo" <<<"$entry"
  else
    render_table "$show_program" --arg repo "$repo" <<<"$entry"
  fi
}

# Prints why the entry can't be changed here, or nothing.
change_refusal() {
  jq -r --arg repo "$repo" --arg permission "$(jq -r '.viewerPermission // "none"' <<<"$item")" '
    if .kind != "ruleset" then "classic branch protection rules change on github.com"
    elif .source.type != "repository" then "\(.name) belongs to the \(.source.type) \(.source.name); change it there"
    elif $permission != "ADMIN" then "changing the rules of \($repo) needs admin access; you have \($permission | ascii_downcase) access"
    else empty end
  ' <<<"$1"
}

# Usage: set_enforcement entry
set_enforcement() {
  local entry="$1" id title current refusal
  refusal="$(change_refusal "$entry")"
  [[ -z "$refusal" ]] || fail "$refusal"
  id="$(jq -r .id <<<"$entry")"
  title="$(jq -r .name <<<"$entry")"
  current="$(jq -r .enforcement <<<"$entry")"
  if [[ "$current" == "$state" ]]; then
    echo "$title is already $state."
    return
  fi
  gh api -X PUT "repos/$repo/rulesets/$id" -f enforcement="$state" --silent || return
  forget_cached "${query_args[@]}"
  forget_cached "${sources_args[@]}"
  echo "✓ $title: $current → $state"
}

# The fzf alt keys: explains a refusal, or confirms first.
change_enforcement() {
  source "$LIB_DIR/prompt.sh"
  clear_screen
  local entry refusal question
  entry="$(find_entry "$name")"
  refusal="$(change_refusal "$entry")"
  if [[ -n "$refusal" ]]; then
    echo "Can't change it: $refusal." >/dev/tty
    pause
    return
  fi
  case "$state" in
    active) question="Enforce the ruleset \"$(jq -r .name <<<"$entry")\"?" ;;
    evaluate) question="Only evaluate the ruleset \"$(jq -r .name <<<"$entry")\", without blocking anything?" ;;
    disabled) question="Disable the ruleset \"$(jq -r .name <<<"$entry")\"?" ;;
  esac
  [[ "$(jq -r .enforcement <<<"$entry")" != "$state" ]] || return 0
  if confirm "$question"; then
    set_enforcement "$entry" || true
    pause
  fi
}

fetch_rules
case "$verb" in
  show) show_entry ;;
  set)
    entry="$(find_entry "$name")"
    set_enforcement "$entry"
    ;;
  change) change_enforcement ;;
  *) show_table ruleset "$program" --arg repo "$repo" --argjson sources "$sources" <<<"$item" ;;
esac
