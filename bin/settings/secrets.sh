#!/usr/bin/env bash
# Prints a repository's Actions secrets and variables, and sets or deletes them.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ghs settings secrets [-R owner/repo] [-i] [--format f] [--refresh] [--offline]
       ghs settings secrets set <name> [value]
       ghs settings secrets delete <name> [--yes]
       ghs settings variables set <name> [value]
       ghs settings variables delete <name> [--yes]

Prints the GitHub Actions secrets and variables of a repository: secrets by
name only, since their values can't be read back, and variables with their
values. ghs settings variables prints the same list.

  set       Creates or replaces a secret or variable. Without a value it is
            read from standard input, or asked for (hidden, for a secret).
            Prefer that for secrets: a value typed in the command stays in
            the shell history.
  delete    Deletes one; asks first, unless --yes.

Reading and changing them needs write access to the repository.

Options:
  -R, --repo owner/repo   Repository to read; also accepts a GitHub URL.
                          Defaults to the repository of the current directory.
  -i, --interactive       Browse them in fzf; Enter sets a new value.
      --format format     table (default), json or csv.
      --refresh           Fetch again instead of using the 5-minute cache.
      --offline           Use the cache only, even past 5 minutes; never
                          contact GitHub.
      --yes               Delete without asking.
  -h, --help              Show this help.
EOF
}

# settings.sh passes secret or variable first: what set and delete act on.
type=secret
case "${1:-}" in
  secret | variable) type="$1"; shift ;;
esac
script_args=("$type" "$@")
repo=''
verb=''
name=''
value=''
has_value=false
yes=false
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    -R | --repo) needs_value "$1" $#; repo="$2"; shift 2 ;;
    --yes) yes=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*)
      shared_option "$@"
      [[ "$taken" -gt 0 ]] || { usage >&2; fail "unknown argument: $1"; }
      shift "$taken"
      ;;
    *)
      if [[ -z "$verb" ]]; then verb="$1"
      elif [[ -z "$name" ]]; then name="$1"
      elif [[ "$has_value" == false ]]; then value="$1"; has_value=true
      else usage >&2; fail "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done
case "$verb" in
  '' | new) ;;
  set | delete | change | show) [[ -n "$name" ]] || fail "$verb needs the name of a $type" ;;
  *) usage >&2; fail "unknown command: settings ${type}s $verb" ;;
esac
check_shared_options
repo="$(resolve_repo "$repo")"

program='
. as $all
| ($all | map(select(.type == "secret")) | length) as $secrets
| ($all | map(select(.type == "variable")) | length) as $variables
| {
    title: (("Secrets and variables" | cell(bold)) + ("  " | cell(""))
            + ($repo | cell(cyan) | linkTo("https://github.com/\($repo)/settings/secrets/actions"))),
    subtitle: ("\($secrets | plural("secret")), \($variables | plural("variable")) · \(generatedAt)" | cell(dim)),
    columns: [
      {key: "type", header: "TYPE"},
      {key: "name", header: "NAME", max: 40},
      {key: "value", header: "VALUE", flex: true},
      {key: "updated", header: "UPDATED"}
    ],
    rows: [$all | sort_by(.type, .name)[]
           | {_key: [.type, $repo, .name],
              type: (.type | cell(if . == "secret" then magenta else cyan end)),
              name: (.name | cell(bold)),
              value: (if .type == "secret" then "••••••••" | cell(dim) | decor
                      else .value | gsub("\n"; " ⏎ ") | cell("") end),
              updated: (.updatedAt | ago | cell(dim))}],
    footer: [
      ("the repository’s own; environment and organisation secrets aren’t listed" | cell(dim))
    ],
    empty: "No secrets or variables."
  }
| table
'

secrets_args=(secret list -R "$repo" --json name,updatedAt)
variables_args=(variable list -R "$repo" --json name,value,updatedAt)
fetch_all() {
  local secrets variables
  secrets="$(cached_gh "Loading the secrets of ${repo}…" "${secrets_args[@]}")" \
    || fail "could not read the secrets of $repo"
  variables="$(cached_gh "Loading the variables of ${repo}…" "${variables_args[@]}")" \
    || fail "could not read the variables of $repo"
  all="$(jq -n --argjson secrets "$secrets" --argjson variables "$variables" \
    '($secrets | map(. + {type: "secret"})) + ($variables | map(. + {type: "variable"}))')"
}

forget_all() {
  forget_cached "${secrets_args[@]}"
  forget_cached "${variables_args[@]}"
}

# Prints the current value of a variable; empty for a secret or a new name.
current_value() {
  jq -r --arg type "$type" --arg name "$1" 'first(.[] | select(.type == $type and .name == $name) | .value // "") // ""' \
    <<<"$all"
}

exists() {
  jq -e --arg type "$type" --arg name "$1" 'any(.[]; .type == $type and .name == $name)' <<<"$all" >/dev/null
}

# Usage: apply_value name value
# The value goes through stdin, so it never shows in the process list.
apply_value() {
  printf '%s' "$2" | gh "$type" set "$1" -R "$repo" || return
  forget_all
  echo "✓ $type $1 set"
}

set_value() {
  if [[ "$has_value" == false ]]; then
    if [[ ! -t 0 ]]; then
      value="$(cat)"
    elif [[ "$type" == secret ]]; then
      source "$LIB_DIR/prompt.sh"
      value="$(ask_hidden "Value of the secret $name:")"
    else
      source "$LIB_DIR/prompt.sh"
      value="$(ask "Value of the variable $name" "$(current_value "$name")")"
    fi
  fi
  [[ -n "$value" ]] || fail "the value of $name is empty; nothing was set"
  apply_value "$name" "$value"
}

delete_value() {
  exists "$name" || fail "no $type named $name in $repo"
  if [[ "$yes" != true ]]; then
    [[ -t 0 ]] || fail "deleting the $type $name needs --yes"
    source "$LIB_DIR/prompt.sh"
    confirm "Delete the $type $name of $repo?" || exit 0
  fi
  gh "$type" delete "$name" -R "$repo" || return
  forget_all
  echo "✓ $type $name deleted"
}

# fzf's Enter: asks for a new value and confirms.
change_value() {
  source "$LIB_DIR/prompt.sh"
  clear_screen
  local new
  if [[ "$type" == secret ]]; then
    new="$(ask_hidden "New value of the secret $name:")" || return 0
  else
    new="$(ask "Value of the variable $name" "$(current_value "$name")")" || return 0
    [[ "$new" != "$(current_value "$name")" ]] || return 0
  fi
  [[ -n "$new" ]] || return 0
  if confirm "Replace the value of the $type $name in $repo?"; then
    apply_value "$name" "$new" || true
    pause
  fi
}

# fzf's alt-n and alt-v: asks for a name and a value, then confirms.
new_value() {
  source "$LIB_DIR/prompt.sh"
  clear_screen
  local new_name new
  new_name="$(ask "Name of the new $type" "")" || return 0
  [[ -n "$new_name" ]] || return 0
  if exists "$new_name"; then
    echo "$repo already has a $type named $new_name; Enter on it sets a new value." >/dev/tty
    pause
    return
  fi
  if [[ "$type" == secret ]]; then
    new="$(ask_hidden "Value of the secret $new_name:")" || return 0
  else
    new="$(ask "Value of the variable $new_name" "")" || return 0
  fi
  [[ -n "$new" ]] || return 0
  if confirm "Add the $type $new_name to $repo?"; then
    apply_value "$new_name" "$new" || true
    pause
  fi
}

# The fzf preview.
show_value() {
  jq -r --arg type "$type" --arg name "$name" '
    def bold: "\u001b[1m\(.)\u001b[0m";
    def dim: "\u001b[2m\(.)\u001b[0m";
    first(.[] | select(.type == $type and .name == $name))
    | "", " " + (.name | bold), " " + ("\(.type) · updated \(.updatedAt[0:10])" | dim), "",
      if .type == "secret" then " The value of a secret can’t be read back." | dim
      else (.value | split("\n")[] | " " + .) end,
      "", (" Enter sets a new value." | dim)
  ' <<<"$all"
}

fetch_all
case "$verb" in
  set) set_value ;;
  delete) delete_value ;;
  change) change_value ;;
  new) new_value ;;
  show) show_value ;;
  *) show_table secret "$program" --arg repo "$repo" <<<"$all" ;;
esac
