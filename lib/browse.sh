#!/usr/bin/env bash
# Acts on the item under the cursor in an fzf browse; fzf runs it as browse.sh action kind repo id extra.
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/common.sh"

action="$1"
kind="$2"
repo="$3"
id="$4"
BIN_DIR="$LIB_DIR/../bin"

# Shows the item in the preview pane, which is a pipe: our views are told it is a terminal.
preview() {
  case "$kind" in
    issue) GHS_FORCE_TERMINAL=1 COLUMNS="$FZF_PREVIEW_COLUMNS" "$BIN_DIR/issue.sh" "$id" -R "$repo" ;;
    pr) GHS_FORCE_TERMINAL=1 COLUMNS="$FZF_PREVIEW_COLUMNS" "$BIN_DIR/pull-request.sh" "$id" -R "$repo" ;;
    run) GH_FORCE_TTY="$FZF_PREVIEW_COLUMNS" gh run view "$id" -R "$repo" ;;
  esac
}

view() {
  case "$kind" in
    issue) "$BIN_DIR/issue.sh" "$id" -c -R "$repo" ;;
    pr) "$BIN_DIR/pull-request.sh" "$id" -c -R "$repo" ;;
    run) GH_FORCE_TTY=100% gh run view "$id" --verbose -R "$repo" | less -RF ;;
  esac
}

open_in_browser() {
  case "$kind" in
    issue) gh issue view "$id" -R "$repo" --web ;;
    pr) gh pr view "$id" -R "$repo" --web ;;
    run) gh run view "$id" -R "$repo" --web ;;
  esac
}

# The header and an empty list have no item.
[[ -n "$kind" ]] || exit 0
case "$action" in
  preview) preview ;;
  view) view ;;
  open) open_in_browser ;;
  *) fail "unknown action: $action" ;;
esac
