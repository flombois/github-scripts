#!/usr/bin/env bash
# Acts on the item under the cursor in an fzf browse; fzf runs it as browse.sh action kind repo id extra.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/common.sh"

action="$1"
kind="$2"
repo="$3"
id="$4"
extra="${5:-}"
BIN_DIR="$LIB_DIR/../bin"

# Shows the item in the preview pane, which is a pipe: our views are told it is a terminal.
preview() {
  case "$kind" in
    issue) GHS_FORCE_TERMINAL=1 COLUMNS="$FZF_PREVIEW_COLUMNS" "$BIN_DIR/issue.sh" "$id" -R "$repo" ;;
    pr) GHS_FORCE_TERMINAL=1 COLUMNS="$FZF_PREVIEW_COLUMNS" "$BIN_DIR/pull-request.sh" "$id" -R "$repo" ;;
    run) GH_FORCE_TTY="$FZF_PREVIEW_COLUMNS" gh run view "$id" -R "$repo" ;;
    link) printf '%s\n\n%s\n' "Enter or ctrl-o opens it in the browser:" "$id" ;;
  esac
}

view() {
  case "$kind" in
    issue) "$BIN_DIR/issue.sh" "$id" -c -R "$repo" ;;
    pr) "$BIN_DIR/pull-request.sh" "$id" -c -R "$repo" ;;
    run) GH_FORCE_TTY=100% gh run view "$id" --verbose -R "$repo" | less -RF ;;
    link) open_url "$id" ;;
  esac
}

open_in_browser() {
  case "$kind" in
    issue) gh issue view "$id" -R "$repo" --web ;;
    pr) gh pr view "$id" -R "$repo" --web ;;
    run) gh run view "$id" -R "$repo" --web ;;
    link) open_url "$id" ;;
  esac
}

open_url() {
  if command -v open >/dev/null && [[ "$(uname)" == Darwin ]]; then
    open "$1"
  else
    xdg-open "$1" >/dev/null 2>&1
  fi
}

# fzf hands the terminal over without clearing it.
clear_screen() {
  printf '\033[H\033[2J' >/dev/tty
}

# Asks on the terminal, with gum when it is there; fzf owns stdin, so read /dev/tty.
confirm() {
  if command -v gum >/dev/null; then
    gum confirm "$1" </dev/tty >/dev/tty
  else
    local answer
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r answer </dev/tty
    [[ "$answer" == [yY]* ]]
  fi
}

# Leaves the outcome on screen until a key is pressed.
pause() {
  printf '\nPress any key to go back to the list.' >/dev/tty
  read -rsn1 </dev/tty || true
}

# Usage: act description command…
# Runs an action that changes something on GitHub once confirmed, then pauses on its outcome.
act() {
  local description="$1"
  shift
  clear_screen
  confirm "$description?" || return 0
  "$@" || true
  pause
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

# Usage: interactive command…
# Runs a command that asks its own questions (gh's merge prompt, a comment editor), then pauses.
interactive() {
  clear_screen
  "$@" </dev/tty >/dev/tty || true
  pause
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
  *) fail "no $action action for a $kind" ;;
esac
