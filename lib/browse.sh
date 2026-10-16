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

# Run by fzf's transform on the left and right arrows: steps the setting in place, then prints the
# fzf actions that reload the list and say what happened. The visibility asks first, full screen.
step_setting() {
  if is_offline; then
    echo "change-footer:Offline: nothing can be changed on GitHub."
  elif [[ "$id" == visibility ]]; then
    printf 'execute[%q confirm-%s %s %q %q]+reload[%s]\n' "$0" "$action" "$kind" "$repo" "$id" "$GHS_RELOAD"
  else
    local outcome status=0
    outcome="$("$BIN_DIR/settings.sh" step "$id" "$action" -R "$repo" </dev/null 2>&1)" || status=$?
    outcome="$(tail -n 1 <<<"$outcome" | tr -d '~')"
    # The footer changes first: fzf drops actions queued behind a tracked reload.
    if [[ "$status" -eq 0 ]]; then
      printf 'change-footer~%s~+reload[%s]\n' "$outcome" "$GHS_RELOAD"
    else
      printf 'change-footer:%s\n' "${outcome#settings: }"
    fi
  fi
}

# The header and an empty list have no item.
[[ -n "$kind" ]] || exit 0
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
  setting:change) "$BIN_DIR/settings.sh" change "$id" -R "$repo" ;;
  setting:previous | setting:next) step_setting ;;
  setting:confirm-previous | setting:confirm-next)
    clear_screen
    refuse_offline && exit 0
    "$BIN_DIR/settings.sh" step "$id" "${action#confirm-}" -R "$repo" </dev/tty >/dev/tty || true
    pause
    ;;
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
  *)
    clear_screen
    echo "There is no $action action for this $kind." >/dev/tty
    pause
    ;;
esac
