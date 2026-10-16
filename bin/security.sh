#!/usr/bin/env bash
# Prints a repository's Dependabot, code scanning and secret scanning alerts, and dismisses or reopens them.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: security.sh [-R owner/repo] [-s state] [-k kind] [--severity level] [-i] [--format f]
                   [--refresh] [--offline]
       security.sh show <kind/number>
       security.sh dismiss <kind/number> [--reason reason]
       security.sh reopen <kind/number>

Prints the security alerts of a GitHub repository as a table, most severe
first: Dependabot, code scanning and secret scanning, with severity, title or
rule, package or file, state and age. A source that is turned off or that you
may not read shows as a note under the table.

  show      Prints one alert, such as dependabot/12, code/3 or secret/1.
  dismiss   Dismisses an open alert (resolves a secret scanning one); asks for
            the reason unless --reason. Reasons:
              dependabot  fix_started, inaccurate, no_bandwidth, not_used,
                          tolerable_risk
              code        "false positive", "won't fix", "used in tests"
              secret      false_positive, wont_fix, revoked, used_in_tests
  reopen    Reopens a dismissed or resolved alert.

Reading alerts needs the features turned on and access to them; dismissing
needs write access (admin for some sources).

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -s, --state state       open (default), closed or all.
  -k, --kind kind         dependabot, code or secret; repeat for several
                          (default all three).
      --severity level    Only alerts at least this severe: critical, high,
                          medium or low. Secret scanning alerts have no
                          severity, so they are left out.
      --reason reason     Why the alert is dismissed, with dismiss.
  -i, --interactive       Browse the alerts in fzf, with a preview pane.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
      --offline           Use the cache only, even past 5 minutes; never
                          contact GitHub.
  -h, --help              Show this help.
EOF
}

script_args=("$@")
repo=''
state=open
kinds=()
severity=''
reason=''
has_reason=false
verb=''
alert_id=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    -s | --state) needs_value "$1" $#; state="$2"; shift 2 ;;
    -k | --kind) needs_value "$1" $#; kinds+=("$2"); shift 2 ;;
    --severity) needs_value "$1" $#; severity="$2"; shift 2 ;;
    --reason) needs_value "$1" $#; reason="$2"; has_reason=true; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
    *)
      if [[ -z "$verb" ]]; then verb="$1"
      elif [[ -z "$alert_id" ]]; then alert_id="$1"
      else usage >&2; fail "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done
case "$verb" in
  '') ;;
  show | dismiss | reopen)
    [[ "$alert_id" =~ ^(dependabot|code|secret)/[1-9][0-9]*$ ]] \
      || fail "$verb needs an alert such as dependabot/12, code/3 or secret/1; got: ${alert_id:-nothing}"
    ;;
  *) usage >&2; fail "unknown command: security $verb" ;;
esac
[[ "$state" =~ ^(open|closed|all)$ ]] || fail "--state must be open, closed or all, got: $state"
[[ -z "$severity" || "$severity" =~ ^(critical|high|medium|low)$ ]] \
  || fail "--severity must be critical, high, medium or low, got: $severity"
for kind in ${kinds[@]+"${kinds[@]}"}; do
  [[ "$kind" =~ ^(dependabot|code|secret)$ ]] || fail "--kind must be dependabot, code or secret, got: $kind"
done
[[ ${#kinds[@]} -gt 0 ]] || kinds=(dependabot code secret)
check_shared_options
repo="$(resolve_repo "$repo")"

# Turns each source's alerts into {kind, number, state, severity, title, where, created, url}.
normalize='
def severityRank: {critical: 4, high: 3, error: 3, medium: 2, warning: 2, low: 1, note: 1}[. // ""] // 0;

def normalized($kind):
  {kind: $kind, number, state, created: .created_at, url: .html_url}
  + if $kind == "dependabot" then
      {severity: .security_advisory.severity,
       title: .security_advisory.summary,
       where: .dependency.package.name}
    elif $kind == "code" then
      {severity: (.rule.security_severity_level // .rule.severity),
       title: (.rule.description // .rule.name // .rule.id),
       where: (.most_recent_instance.location
               | if .path then "\(.path)\(if .start_line then ":\(.start_line)" else "" end)" else null end)}
    else
      {severity: null,
       title: (.secret_type_display_name // .secret_type),
       where: .first_location_detected.path}
    end;
'

program="$normalize"'
def sourceName: {dependabot: "Dependabot", code: "Code scanning", secret: "Secret scanning"}[.];

def severityCell:
  if . == null then "—" | cell(dim) | decor
  else . as $level
    | {critical: "1;31", high: red, error: red, medium: yellow, warning: yellow, low: gray, note: gray}[$level] as $style
    | $level | cell($style // "")
  end;

def stateCell:
  if . == "open" then "open" | cell(green)
  elif . == "fixed" or . == "resolved" then cell(magenta)
  else cell(dim) end;

def wanted:
  ($minimum | severityRank) as $floor
  | (if $state == "open" then .state == "open" elif $state == "closed" then .state != "open" else true end)
    and ($floor == 0 or (.severity | severityRank) >= $floor);

def row:
  .url as $url
  | {_key: ["alert", $repo, "\(.kind)/\(.number)", .url],
     kind: (.kind | cell(cyan)),
     number: (("#" | cell(dim) | decor) + ("\(.number)" | cell(dim)) | linkTo($url)),
     severity: (.severity | severityCell),
     title: (.title // "" | cell("") | linkTo($url)),
     where: (.where // "" | if . == "" then "—" | cell(dim) | decor else cell("") end),
     state: (.state | stateCell),
     age: (.created | ago | cell(dim))};

. as $sources
| [$sources[] | .kind as $kind | .alerts[] | normalized($kind) | select(wanted)]
  | sort_by([-(.severity | severityRank), -(.created | fromdateiso8601)]) | . as $alerts
| {
    title: (("Security" | cell(bold)) + ("  " | cell("")) + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)/security"))),
    subtitle: ("\($alerts | length | plural("\(if $state == "all" then "" else "\($state) " end)alert")) · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "kind", header: "KIND"},
      {key: "number", header: "#", align: "right", drop: true},
      {key: "severity", header: "SEVERITY"},
      {key: "title", header: "TITLE", flex: true},
      {key: "where", header: "PACKAGE OR FILE", max: 36, drop: true},
      {key: "state", header: "STATE"},
      {key: "age", header: "AGE"}
    ],
    rows: [$alerts[] | row],
    footer: [
      ($alerts | length | plural("alert") | cell("")),
      ($alerts | map(select(.severity == "critical")) | length | tally("critical"; "1;31")),
      ($alerts | map(select(.severity == "high" or .severity == "error")) | length | tally("high"; red)),
      ($sources[] | select(.note) | "\(.kind | sourceName): \(.note)" | cell(yellow))
    ],
    empty: "No \(if $state == "all" then "" else "\($state) " end)alerts."
  }
| table
'

show_program="$normalize"'
def field($label; $value):
  if ($value // "") == "" then empty
  else ($label | textWidth) as $used
    | " " + ($label | paint(dim)) + (" " | times(14 - $used)) + "\($value)"
  end;

def wrapped($width):
  split("\n")[]
  | if . == "" then ""
    else [scan(".{1,\($width)}(?:\\s|$)|\\S{\($width + 1),}") | " " + rtrimstr(" ") | rtrimstr("\r")][] end;

def login: if . == null then null else "@\(.login)" end;

def closedFields:
  field("Dismissed"; if .dismissed_at then "\(.dismissed_at | ago) by \(.dismissed_by | login // "someone")" else null end),
  field("Reason"; .dismissed_reason),
  field("Comment"; .dismissed_comment),
  field("Fixed"; if .fixed_at then .fixed_at | ago else null end),
  field("Resolved"; if .resolved_at then "\(.resolved_at | ago) by \(.resolved_by | login // "someone")" else null end),
  field("Resolution"; .resolution),
  field("Comment"; .resolution_comment);

def kindFields($kind):
  if $kind == "dependabot" then
    field("Package"; "\(.dependency.package.name) (\(.dependency.package.ecosystem))"),
    field("Manifest"; .dependency.manifest_path),
    field("Scope"; [.dependency.scope, .dependency.relationship] | map(select(. != null)) | join(", ")),
    field("Vulnerable"; .security_vulnerability.vulnerable_version_range),
    field("Patched in"; .security_vulnerability.first_patched_version.identifier),
    field("Advisory"; [.security_advisory.ghsa_id, .security_advisory.cve_id] | map(select(. != null)) | join(" · ")),
    field("CVSS"; .security_advisory.cvss.score | if . == null or . == 0 then null else tostring end)
  elif $kind == "code" then
    field("Rule"; .rule.id),
    field("Tool"; [.tool.name, .tool.version] | map(select(. != null)) | join(" ")),
    field("Location"; .most_recent_instance.location
                      | if .path then "\(.path)\(if .start_line then ":\(.start_line)" else "" end)" else null end),
    field("Ref"; .most_recent_instance.ref)
  else
    field("Secret type"; .secret_type),
    field("Location"; .first_location_detected.path),
    field("Validity"; .validity),
    field("Public leak"; if .publicly_leaked then "yes" else null end),
    field("Push bypass"; if .push_protection_bypassed then "yes, by \(.push_protection_bypassed_by | login // "someone")" else null end)
  end;

def details($kind):
  if $kind == "dependabot" then .security_advisory.description
  elif $kind == "code" then .most_recent_instance.message.text
  else null end;

($width - 2) as $room
| . as $alert
| normalized($kind) as $summary
| "",
  " " + ($summary.title // "" | paint(bold)),
  " " + (["\($kind) #\($summary.number)", $summary.severity // empty, $summary.state] | join(" · ") | paint(dim)),
  "",
  ($alert | kindFields($kind)),
  field("Opened"; $summary.created | ago),
  ($alert | closedFields),
  ($alert | details($kind) // "" | if . == "" then empty else "", wrapped($room) end),
  "",
  (" Enter or ctrl-o opens it on github.com; alt-d dismisses, alt-r reopens." | paint(dim))
'

api_path() {
  case "$1" in
    dependabot) echo dependabot ;;
    code) echo code-scanning ;;
    secret) echo secret-scanning ;;
  esac
}

source_name() {
  case "$1" in
    dependabot) echo Dependabot ;;
    code) echo "code scanning" ;;
    secret) echo "secret scanning" ;;
  esac
}

# Usage: set_list_args kind state — sets fetch_args to the gh arguments that list the alerts.
set_list_args() {
  local query="per_page=100"
  if [[ "$2" == open ]]; then query+="&state=open"; fi
  fetch_args=(api --paginate --slurp "repos/${repo}/$(api_path "$1")/alerts?${query}")
}

# Usage: refusal errors-file
# Prints GitHub's reason when it refused the request (403, 404: turned off, no access); fails otherwise.
refusal() {
  local line
  line="$(grep -E '^gh: .*\(HTTP 40[34]\)$' "$1" | head -n 1)" || return 1
  line="${line#gh: }"
  echo "${line% (HTTP *}"
}

# Usage: fetch_source kind
# Prints {kind, alerts, note?}: the alerts, or a note saying why the source can't be read. A refusal
# is cached like an answer, as {refused: reason}, so offline views still show the note.
fetch_source() {
  local kind="$1" output reason status=0 gh_errors
  set_list_args "$kind" "$state"
  gh_errors="$(mktemp)"
  output="$(cached_gh "Loading the $(source_name "$kind") alerts of ${repo}…" "${fetch_args[@]}")" || status=$?
  if [[ "$status" -ne 0 ]] && reason="$(refusal "$gh_errors")"; then
    output="$(jq -n --arg reason "$reason" '{refused: $reason}')"
    store_cached "$(cache_file "${fetch_args[@]}")" "$output"
    status=0
    : >"$gh_errors"
  fi
  if [[ "$status" -eq 0 ]]; then
    cat "$gh_errors" >&2
    rm -f "$gh_errors"
    jq --arg kind "$kind" '
      if type == "object" then {kind: $kind, alerts: [], note: .refused}
      else {kind: $kind, alerts: (add // [])} end' <<<"$output"
  else
    cat "$gh_errors" >&2
    rm -f "$gh_errors"
    fail "could not read the $(source_name "$kind") alerts of $repo"
  fi
}

list_alerts() {
  local sources='' kind
  for kind in "${kinds[@]}"; do
    sources+="$(fetch_source "$kind")" || exit 1
    sources+=$'\n'
  done
  sources="$(jq -s . <<<"$sources")"
  # Every source "Not Found" means GitHub hides the repository itself.
  ! jq -e 'all(.[]; .note == "Not Found")' <<<"$sources" >/dev/null \
    || fail "could not read the security alerts of $repo: not found, or no access"
  printf '%s\n' "$sources" \
    | show_table alert "$program" --arg repo "$repo" --arg state "$state" --arg minimum "$severity"
}

alert_kind="${alert_id%%/*}"
alert_number="${alert_id#*/}"

alert_args() {
  fetch_args=(api "repos/${repo}/$(api_path "$alert_kind")/alerts/${alert_number}")
}

fetch_alert() {
  alert_args
  alert="$(cached_gh "Loading ${alert_id} of ${repo}…" "${fetch_args[@]}")" \
    || fail "could not read the alert $alert_id of $repo"
}

show_alert() {
  local is_terminal=false width=80
  if on_terminal; then
    is_terminal=true
    width="$(terminal_width)"
  fi
  render_with "$is_terminal" "$width" "$show_program" --arg kind "$alert_kind" --argjson width "$width" <<<"$alert"
}

alert_state() {
  jq -r .state <<<"$alert"
}

dismiss_reasons() {
  case "$alert_kind" in
    dependabot) printf '%s\n' fix_started inaccurate no_bandwidth not_used tolerable_risk ;;
    code) printf '%s\n' "false positive" "won't fix" "used in tests" ;;
    secret) printf '%s\n' false_positive wont_fix revoked used_in_tests ;;
  esac
}

is_reason() {
  dismiss_reasons | grep -qxF -- "$1"
}

# Usage: write_alert gh-api-fields…
# Changes the alert, then forgets the cached alert and lists so the next view fetches them again.
write_alert() {
  ! is_offline || fail "offline: nothing can be changed on GitHub; drop --offline"
  gh api -X PATCH "repos/${repo}/$(api_path "$alert_kind")/alerts/${alert_number}" "$@" --silent || return
  alert_args
  forget_cached "${fetch_args[@]}"
  local list_state
  for list_state in open closed; do
    set_list_args "$alert_kind" "$list_state"
    forget_cached "${fetch_args[@]}"
  done
  echo "Done: $alert_id of $repo has changed."
}

dismiss_with() {
  if [[ "$alert_kind" == secret ]]; then
    write_alert -f state=resolved -f resolution="$1"
  else
    write_alert -f state=dismissed -f dismissed_reason="$1"
  fi
}

dismiss_alert() {
  [[ "$(alert_state)" == open ]] || fail "$alert_id of $repo is not open, it is $(alert_state)"
  if [[ "$has_reason" == true ]]; then
    is_reason "$reason" || fail "the reason for a $alert_kind alert must be one of: $(dismiss_reasons | paste -sd, - | sed 's/,/, /g')"
    dismiss_with "$reason"
    return
  fi
  [[ -t 0 ]] || fail "dismissing $alert_id needs --reason"
  ask_dismiss
}

# Asks for the reason on the terminal, then confirms; fzf's alt-d runs it too.
ask_dismiss() {
  source "$LIB_DIR/prompt.sh"
  clear_screen
  refuse_offline && return 0
  local reasons=() line picked
  while IFS= read -r line; do reasons+=("$line"); done < <(dismiss_reasons)
  picked="$(choose "Why dismiss $alert_id?" "" "${reasons[@]}")" || return 0
  [[ -n "$picked" ]] || return 0
  act "Dismiss $alert_id of $repo as $picked" dismiss_with "$picked"
}

reopen_alert() {
  [[ "$(alert_state)" != open ]] || fail "$alert_id of $repo is already open"
  write_alert -f state=open
}

case "$verb" in
  '') list_alerts ;;
  show) fetch_alert; show_alert ;;
  dismiss) fetch_alert; dismiss_alert ;;
  reopen) fetch_alert; reopen_alert ;;
esac
