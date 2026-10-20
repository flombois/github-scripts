#!/usr/bin/env bash
# Acts on the item under the cursor in an fzf browse; fzf runs it as browse.sh action kind repo id extra.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/common.sh"
source "$LIB_DIR/prompt.sh"

action="$1"
kind="$2"
repo="$3"
id="$4"
extra="${5:-}"
BIN_DIR="$LIB_DIR/../bin"
SETTINGS_DIR="$BIN_DIR/settings"

# Shows the item in the preview pane, which is a pipe: our views are told it is a terminal.
preview() {
  case "$kind" in
    issue) GHS_FORCE_TERMINAL=1 COLUMNS="$FZF_PREVIEW_COLUMNS" "$BIN_DIR/issue.sh" "$id" -R "$repo" ;;
    pr) GHS_FORCE_TERMINAL=1 COLUMNS="$FZF_PREVIEW_COLUMNS" "$BIN_DIR/pull-request.sh" "$id" -R "$repo" ;;
    run) GH_FORCE_TTY="$FZF_PREVIEW_COLUMNS" gh run view "$id" -R "$repo" ;;
    link) printf '%s\n\n%s\n' "Enter or ctrl-o opens it in the browser:" "$id" ;;
    release) GH_FORCE_TTY="$FZF_PREVIEW_COLUMNS" gh release view "$id" -R "$repo" ;;
    setting) COLUMNS="$FZF_PREVIEW_COLUMNS" "$BIN_DIR/settings.sh" show "$id" -R "$repo" ;;
    ruleset | branch-rule) GHS_FORCE_TERMINAL=1 COLUMNS="$FZF_PREVIEW_COLUMNS" "$SETTINGS_DIR/rules.sh" show "$id" -R "$repo" ;;
    secret | variable) "$SETTINGS_DIR/secrets.sh" "$kind" show "$id" -R "$repo" ;;
    label) COLUMNS="$FZF_PREVIEW_COLUMNS" "$SETTINGS_DIR/labels.sh" show "$id" -R "$repo" ;;
    alert) COLUMNS="$FZF_PREVIEW_COLUMNS" GHS_FORCE_TERMINAL=1 "$BIN_DIR/security.sh" show "$id" -R "$repo" ;;
  esac
}

view() {
  case "$kind" in
    issue) "$BIN_DIR/issue.sh" "$id" -c -R "$repo" ;;
    pr) "$BIN_DIR/pull-request.sh" "$id" -c -R "$repo" ;;
    run) GH_FORCE_TTY=100% gh run view "$id" --verbose -R "$repo" | less -RF ;;
    link) open_url "$id" ;;
    release) GH_FORCE_TTY=100% gh release view "$id" -R "$repo" | less -RF ;;
    ruleset | branch-rule) "$SETTINGS_DIR/rules.sh" show "$id" -R "$repo" ;;
    label) "$BIN_DIR/issues.sh" -l "$id" -R "$repo" ;;
    alert) open_url "$extra" ;;
  esac
}

open_in_browser() {
  case "$kind" in
    issue) gh issue view "$id" -R "$repo" --web ;;
    pr) gh pr view "$id" -R "$repo" --web ;;
    run) gh run view "$id" -R "$repo" --web ;;
    release) gh release view "$id" -R "$repo" --web ;;
    link) open_url "$id" ;;
    setting) open_url "https://github.com/$repo/settings" ;;
    ruleset) open_url "https://github.com/$repo/rules/$id" ;;
    branch-rule) open_url "https://github.com/$repo/settings/branches" ;;
    secret) open_url "https://github.com/$repo/settings/secrets/actions" ;;
    variable) open_url "https://github.com/$repo/settings/variables/actions" ;;
    label) open_url "$extra" ;;
    alert) open_url "$extra" ;;
  esac
}

open_url() {
  if command -v open >/dev/null && [[ "$(uname)" == Darwin ]]; then
    open "$1"
  else
    xdg-open "$1" >/dev/null 2>&1
  fi
}

checkout() {
  clear_screen
  local here
  here="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  if [[ "$here" != "$repo" ]]; then
    echo "Can't check out #$id here: $(pwd) is not a clone of $repo." >/dev/tty
  else
    gh pr checkout "$id" -R "$repo" || true
  fi
  pause
}

# Settings edit in the preview pane. Enter, Esc and the arrows run as fzf transforms, which print the
# actions to take. Enter opens the editor; there the arrows pick a value (text settings take typing in
# the search line), Enter saves it in the background and Esc cancels. GHS_BROWSE_STATE holds the
# open editor (edit, choices, draft, confirm) and the values being saved (saving/<key>), whose rows
# the list greys out and locks until GitHub answers.
STATE_DIR="${GHS_BROWSE_STATE:-}"
LIST_KEYS='up,down,ctrl-j,ctrl-k,ctrl-n,ctrl-p,page-up,page-down,tab,btab,ctrl-r,ctrl-o,left-click,double-click,scroll-up,scroll-down'

setting_enter() {
  if is_editing; then
    save_draft
  else
    open_editor
  fi
}

is_editing() {
  [[ -f "$STATE_DIR/edit" ]]
}

open_editor() {
  if is_offline; then
    footer "Offline: nothing can be changed on GitHub."
  elif [[ -f "$STATE_DIR/saving/$id" ]]; then
    footer "Still saving: wait for GitHub to answer."
  else
    local errors fields
    errors="$(mktemp)"
    if fields="$("$BIN_DIR/settings.sh" editable "$id" -R "$repo" </dev/null 2>"$errors")"; then
      start_editing "$fields"
    else
      footer "$(tail -n 1 "$errors" | sed 's/^settings: //')"
    fi
    rm -f "$errors"
  fi
}

# Usage: start_editing fields — the output of settings.sh editable.
start_editing() {
  local kind label current
  IFS=$'\x1f' read -r kind label current <<<"${1%%$'\n'*}"
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$kind" "$label" "$current" "${FZF_QUERY:-}" >"$STATE_DIR/edit"
  local actions
  actions="unbind($LIST_KEYS)+disable-search+$(fzf_action change-preview "$(self) edit-preview {1} {2} {3} {4}")"
  actions+="+$(fzf_action change-preview-window "$(focused_window)")"
  actions+="+$(fzf_action change-preview-label " $(printf '\033[1;36m')Editing · $label$(printf '\033[0m') ")"
  if is_text "$kind"; then
    # The pane follows the typing, from the current value on.
    actions+="+rebind(change)+$(fzf_action change-query "$current")+$(fzf_action change-prompt "$label › ")"
    actions+="+$(fzf_action change-footer "enter save · esc cancel")"
  else
    tail -n +2 <<<"$1" >"$STATE_DIR/choices"
    printf '%s' "$current" >"$STATE_DIR/draft"
    actions+="+hide-input+$(fzf_action change-footer "← → pick · enter save · esc cancel")"
  fi
  echo "$actions"
}

# Text settings are typed in the search line; the others pick from their values.
is_text() {
  [[ "$1" == text || "$1" == topics ]]
}

# The preview window with a bold border, to show the editor has the focus.
focused_window() {
  echo "${GHS_PREVIEW_WINDOW%,border-*},border-bold"
}

# Saves a changed draft: the row greys out at once, and the request runs in the background.
save_draft() {
  local kind label current query draft
  IFS=$'\x1f' read -r kind label current query <"$STATE_DIR/edit"
  draft="$(draft_value "$kind")"
  if [[ "$draft" == "$current" ]]; then
    echo "$(stop_editing "$query")+change-footer( )"
  elif [[ "$id" == visibility && "$(cat "$STATE_DIR/confirm" 2>/dev/null)" != "$draft" ]]; then
    printf '%s' "$draft" >"$STATE_DIR/confirm"
    footer "Enter again to make $repo $draft."
  else
    printf '%s' "$draft" >"$STATE_DIR/saving/$id"
    # The footer and the save come first: fzf drops actions queued behind a tracked reload.
    printf '%s+%s+%s+%s\n' "$(stop_editing "$query")" "$(fzf_action change-footer "Saving ${label}…")" \
      "$(fzf_action bg-transform "$(self) save {1} {2} {3} {4}")" "$(fzf_action reload "$GHS_RELOAD")"
  fi
}

# Usage: draft_value kind
draft_value() {
  if is_text "$1"; then
    printf '%s' "${FZF_QUERY:-}"
  else
    cat "$STATE_DIR/draft"
  fi
}

# Usage: stop_editing query — prints the actions that give the list back, with its earlier search.
stop_editing() {
  rm -f "$STATE_DIR/edit" "$STATE_DIR/choices" "$STATE_DIR/draft" "$STATE_DIR/confirm"
  printf '%s' "rebind($LIST_KEYS)+unbind(change)+enable-search+show-input+change-prompt(> )" \
    "+$(fzf_action change-query "$1")+beginning-of-line+end-of-line" \
    "+$(fzf_action change-preview "$(self) preview {1} {2} {3} {4}")" \
    "+$(fzf_action change-preview-window "$GHS_PREVIEW_WINDOW")+change-preview-label( )"
}

setting_esc() {
  if is_editing; then
    local query
    query="$(cut -d $'\x1f' -f 4 "$STATE_DIR/edit")"
    echo "$(stop_editing "$query")+change-footer( )"
  else
    echo abort
  fi
}

# Usage: setting_arrow left|right — picks the previous or next value in the editor; elsewhere the
# arrows move along the search line.
setting_arrow() {
  local kind
  if is_editing && kind="$(cut -d $'\x1f' -f 1 "$STATE_DIR/edit")" && ! is_text "$kind"; then
    step_draft "$1" "$kind"
  elif [[ "$1" == left ]]; then
    echo backward-char
  else
    echo forward-char
  fi
}

# Usage: step_draft left|right kind — a switch flips, the other values step without wrapping.
step_draft() {
  jq -Rrn --arg draft "$(cat "$STATE_DIR/draft")" --arg direction "$1" --arg kind "$2" '
    [inputs] as $values
    | ($values | index($draft) // 0) as $at
    | if $kind == "switch" then $values[1 - $at]
      else (if $direction == "right" then $at + 1 else $at - 1 end) as $to
        | $values[[0, ([$to, ($values | length) - 1] | min)] | max] end
  ' <"$STATE_DIR/choices" | tr -d '\n' >"$STATE_DIR/draft.next"
  mv "$STATE_DIR/draft.next" "$STATE_DIR/draft"
  rm -f "$STATE_DIR/confirm"
  echo refresh-preview
}

edit_preview() {
  local kind
  kind="$(cut -d $'\x1f' -f 1 "$STATE_DIR/edit" 2>/dev/null)" || return 0
  COLUMNS="$FZF_PREVIEW_COLUMNS" "$BIN_DIR/settings.sh" editor -R "$repo" -- "$id" "$(draft_value "$kind")"
}

# Run by bg-transform: sends the value, unlocks the row and reloads the list with the outcome.
save_setting() {
  local marker="$STATE_DIR/saving/$id" outcome status=0
  outcome="$("$BIN_DIR/settings.sh" set --yes -R "$repo" -- "$id" "$(cat "$marker")" </dev/null 2>&1)" || status=$?
  rm -f "$marker"
  outcome="$(tail -n 1 <<<"$outcome")"
  if [[ "$status" -ne 0 ]]; then outcome="✗ ${outcome#settings: }"; fi
  echo "$(fzf_action change-footer "$outcome")+$(fzf_action reload "$GHS_RELOAD")"
}

footer() {
  fzf_action change-footer "$1"
  echo
}

# Usage: fzf_action name argument — the action with its argument between delimiters it doesn't hold.
fzf_action() {
  local pair
  for pair in '()' '[]' '{}' '<>' '~~' '!!' '@@' '##' '%%' '^^' '&&' '**' ';;' '//' '||' '::'; do
    if [[ "$2" != *"${pair:1:1}"* ]]; then
      printf '%s%s%s%s' "$1" "${pair:0:1}" "$2" "${pair:1:1}"
      return
    fi
  done
}

self() {
  printf %q "$0"
}

# The header and an empty list have no item; Esc still quits and the arrows move along the search line.
if [[ -z "$kind" ]]; then
  case "$action" in
    esc) echo abort ;;
    left) echo backward-char ;;
    right) echo forward-char ;;
  esac
  exit 0
fi
case "$kind:$action" in
  *:preview) preview ;;
  *:view) view ;;
  *:open) open_in_browser ;;
  issue:assign) act "Assign issue #$id of $repo to you" gh issue edit "$id" -R "$repo" --add-assignee @me ;;
  issue:comment) interactive gh issue comment "$id" -R "$repo" ;;
  issue:close) act "Close issue #$id of $repo" gh issue close "$id" -R "$repo" ;;
  pr:checkout) checkout ;;
  pr:approve) act "Approve pull request #$id of $repo" gh pr review "$id" -R "$repo" --approve ;;
  pr:merge) interactive gh pr merge "$id" -R "$repo" ;;
  pr:comment) interactive gh pr comment "$id" -R "$repo" ;;
  run:rerun) act "Re-run the failed jobs of run $id" gh run rerun "$id" -R "$repo" --failed ;;
  run:logs) gh run view "$id" -R "$repo" --log-failed | less -RF ;;
  run:watch) interactive gh run watch "$id" -R "$repo" ;;
  *:read) gh api -X PATCH "notifications/threads/$extra" --silent ;;
  setting:enter) setting_enter ;;
  setting:esc) setting_esc ;;
  setting:left | setting:right) setting_arrow "$action" ;;
  setting:edit-preview) edit_preview ;;
  setting:save) save_setting ;;
  ruleset:active | ruleset:evaluate | ruleset:disabled) "$SETTINGS_DIR/rules.sh" change "$id" "$action" -R "$repo" ;;
  branch-rule:active | branch-rule:evaluate | branch-rule:disabled)
    clear_screen
    echo "Classic branch protection rules change on github.com: ctrl-o opens the page." >/dev/tty
    pause
    ;;
  secret:new-secret) "$SETTINGS_DIR/secrets.sh" secret new -R "$repo" ;;
  secret:new-variable) "$SETTINGS_DIR/secrets.sh" variable new -R "$repo" ;;
  secret:change | variable:change) "$SETTINGS_DIR/secrets.sh" "$kind" change "$id" -R "$repo" ;;
  secret:delete | variable:delete)
    act "Delete the $kind $id of $repo" "$SETTINGS_DIR/secrets.sh" "$kind" delete "$id" -R "$repo" --yes ;;
  label:new) "$SETTINGS_DIR/labels.sh" new -R "$repo" ;;
  label:change) "$SETTINGS_DIR/labels.sh" change "$id" -R "$repo" ;;
  label:delete) act "Delete the label \"$id\" from $repo and its issues" "$SETTINGS_DIR/labels.sh" delete "$id" -R "$repo" --yes ;;
  alert:dismiss) clear_screen; "$BIN_DIR/security.sh" dismiss "$id" -R "$repo" || pause ;;
  alert:reopen) act "Reopen $id of $repo" "$BIN_DIR/security.sh" reopen "$id" -R "$repo" ;;
  *)
    clear_screen
    echo "There is no $action action for this $kind." >/dev/tty
    pause
    ;;
esac
