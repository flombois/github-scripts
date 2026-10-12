# Shared by the detail views (issue.sh, pull-request.sh); source it after common.sh.
# A view sets `program` (starting with $DETAIL_JQ) and `item` (the JSON), defines print_main, then
# calls detail_layout and print_detail.

DETAIL_JQ="$(cat "$LIB_DIR/detail.jq")"$'\n'

# Puts the sidebar lines (--arg sidebar) beside the main column on stdin, padded to $terminalWidth.
# A main line too wide to share its row keeps it alone.
beside_program='
($sidebar | split("\n")) as $side
| rtrimstr("\n") | split("\n")
| reduce .[] as $line ({lines: [], next: 0};
    if .next >= ($side | length) then .lines += [$line]
    else ($line | visibleWidth) as $used
      | if $used > $terminalWidth then .lines += [$line]
        else .lines += [$line + (" " | times($terminalWidth - $used + 3)) + $side[.next]] | .next += 1 end
    end)
| .lines[], ($side[.next:][] | (" " | times($terminalWidth + 3)) + .)
'

# Frames the lines on stdin as a card titled --arg title, dropping blank lines around them.
frame_program='
[rtrimstr("\n") | split("\n")[]] as $lines
| [range(0; $lines | length) | select($lines[.] | visibleWidth > 0)] as $filled
| frameTop($title; ""; $terminalWidth),
  (if $filled == [] then empty else $lines[$filled[0]:$filled[-1] + 1][] end | frameLine($terminalWidth)),
  frameBottom($terminalWidth),
  ""
'

entry_index=0

# Decides colour, width, glow and the layout. Like GitHub, the fields move to a sidebar when there
# is room; raw Markdown can't be fitted into a column, so that needs glow.
detail_layout() {
  is_terminal=false
  width=1000
  if on_terminal; then
    is_terminal=true
    width="$(terminal_width)"
  fi
  markdown=false
  if [[ "$is_terminal" == true ]] && has_glow; then
    markdown=true
  fi
  layout=stacked
  if [[ "$markdown" == true && "$width" -ge 110 ]]; then
    layout=sidebar
  fi
  sidebar_width=$((width / 4 < 28 ? 28 : width / 4 > 40 ? 40 : width / 4))
  main_width=$((width - sidebar_width - 3))
}

# Usage: print_part part [width]
print_part() {
  render_with "$is_terminal" "${2:-$width}" "$program" --arg part "$1" --arg layout "$layout" \
    --argjson showComments "$show_comments" --argjson markdown "$markdown" --argjson index "$entry_index" \
    <<<"$item"
}

print_markdown_part() {
  if [[ "$markdown" == true ]]; then
    print_part "$1" "$2" | render_markdown "$2"
  else
    print_part "$1" "$2"
  fi
}

# Usage: print_card width title_part content_part
print_card() {
  print_markdown_part "$3" "$(($1 - 4))" \
    | render_with true "$1" "$frame_program" -R -s --arg title "$(print_part "$2" "$1")"
}

print_detail_lines() {
  print_part header
  if [[ "$layout" == sidebar ]]; then
    print_main "$main_width" \
      | render_with true "$main_width" "$beside_program" -R -s --arg sidebar "$(print_part sidebar "$sidebar_width")"
  else
    print_main "$width"
  fi
  print_part footer
}

# Prints the header, print_main (beside the sidebar when there is one) and the footer, paged on a terminal.
print_detail() {
  if [[ "$is_terminal" == true ]]; then
    page print_detail_lines
  else
    print_detail_lines
  fi
}
