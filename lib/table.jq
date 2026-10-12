# Shared rendering for the report scripts; expects $isTerminal and $terminalWidth.
# A cell is an array of {text, style, link?} segments, where a style is an ANSI SGR code.

def bold: "1";
def dim: "2";
def red: "31";
def green: "32";
def yellow: "33";
def blue: "34";
def magenta: "35";
def cyan: "36";
def gray: "90";
def pink: "95";
def orange: "38;5;208";

def hexColor:
  ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end)
  | "38;2;\(.[0] * 16 + .[1]);\(.[2] * 16 + .[3]);\(.[4] * 16 + .[5])";

def namedColor:
  {RED: red, GREEN: green, YELLOW: yellow, BLUE: blue, PURPLE: magenta, PINK: pink, ORANGE: orange, GRAY: gray}[.]
  // "";

# Display width: wide (CJK, emoji) characters take two columns, combining marks none.
def wideRanges:
  [[4352,4447],[8986,8987],[9193,9196],[9200,9203],[9725,9726],[9748,9749],[9800,9811],[9855,9855],
   [9875,9875],[9889,9889],[9898,9899],[9917,9918],[9924,9925],[9934,9934],[9940,9940],[9962,9962],
   [9970,9971],[9973,9973],[9978,9978],[9981,9981],[9989,9989],[9994,9995],[10024,10024],[10060,10060],
   [10062,10062],[10067,10069],[10071,10071],[10133,10135],[10160,10160],[10175,10175],[11035,11036],
   [11088,11088],[11093,11093],[11904,12350],[12353,42191],[44032,55203],[63744,64255],[65072,65103],
   [65280,65376],[65504,65510],[127744,128591],[128640,128767],[129280,129535],[129648,129791],
   [131072,262141]];

def charWidth:
  . as $code
  | if $code < 32 or ($code >= 768 and $code <= 879) or ($code >= 8203 and $code <= 8207)
       or ($code >= 65024 and $code <= 65039) or ($code >= 127995 and $code <= 127999) then 0
    elif $code < 4352 or ($code >= 9204 and $code < 9725) then 1
    elif any(wideRanges[]; $code >= .[0] and $code <= .[1]) then 2
    else 1 end;

def textWidth: if utf8bytelength == length then length else explode | map(charWidth) | add // 0 end;

# The width of a rendered line, past its colour and link codes.
def visibleWidth: gsub("\u001b\\[[0-9;]*m"; "") | gsub("\u001b\\]8;[^\u0007]*\u0007"; "") | textWidth;

# The longest start of the text that fits $room columns.
def clipText($room):
  reduce explode[] as $code ({codes: [], room: $room};
    if .room < 0 then .
    else ($code | charWidth) as $width
      | if $width <= .room then .codes += [$code] | .room -= $width else .room = -1 end
    end)
  | .codes | implode;

def times($count): if $count > 0 then . * $count else "" end;
def paint($style):
  if $isTerminal and $style != "" and . != "" then "\u001b[\($style)m\(.)\u001b[0m" else . end;

# An OSC 8 hyperlink, which terminals make clickable; a no-op off a terminal, like paint.
def hyperlink($url):
  if $isTerminal and $url != null and . != "" then "\u001b]8;;\($url)\u0007\(.)\u001b]8;;\u0007" else . end;

def cell($style): [{text: ., style: $style}];
def linkTo($url): map(.link = $url);
# Decoration, such as the backlog's tree lines, that --format json and csv leave out.
def decor: map(.decor = true);
def cellText: map(select(.decor | not) | .text) | join("") | sub("^ +"; "") | sub(" +$"; "");
def profileUrl:
  if startswith("app/") then "https://github.com/apps/\(.[4:])"
  elif endswith("[bot]") then "https://github.com/apps/\(rtrimstr("[bot]"))"
  else "https://github.com/\(.)" end;
def cellWidth: map(.text | textWidth) | add // 0;
def joinCells($separator): reduce .[] as $cell ([]; if . == [] then $cell else . + $separator + $cell end);
def renderInline: map(.style as $style | .link as $url | .text | paint($style) | hyperlink($url)) | join("");

# Packs cells into as few lines as fit $width, joined by $separator.
def wrapCells($width; $separator):
  reduce .[] as $cell ([];
    if . == [] then [$cell]
    elif (.[-1] + $separator + $cell | cellWidth) <= $width then .[-1] += $separator + $cell
    else . + [$cell] end);

# Splits a cell into one cell per word, each keeping its style and link, for wrapCells.
def words: [.[] as $segment | $segment.text | split(" ")[] | select(. != "") | [$segment + {text: .}]];

def clipCell($width):
  if cellWidth <= $width then .
  else
    reduce .[] as $segment ({room: ($width - 1), kept: []};
      .room as $room
      | if $room > 0
        then .kept += [$segment | .text |= clipText($room)] | .room -= ($segment.text | textWidth)
        else . end)
    | .kept + ("…" | cell(""))
  end;

def renderCell($width; $align):
  clipCell($width) as $cell
  | (" " | times($width - ($cell | cellWidth))) as $padding
  | if $align == "right" then $padding + ($cell | renderInline) else ($cell | renderInline) + $padding end;

def ago:
  (now - fromdateiso8601) as $seconds
  | if $seconds < 60 then "just now"
    elif $seconds < 3600 then "\($seconds / 60 | floor)m ago"
    elif $seconds < 86400 then "\($seconds / 3600 | floor)h ago"
    elif $seconds < 86400 * 30 then "\($seconds / 86400 | floor)d ago"
    else "\($seconds / 86400 / 30 | floor)mo ago" end;

def duration:
  floor as $seconds
  | if $seconds < 60 then "\($seconds)s"
    elif $seconds < 3600 then "\($seconds / 60 | floor)m \($seconds % 60)s"
    else "\($seconds / 3600 | floor)h \($seconds % 3600 / 60 | floor)m" end;

def generatedAt: now | strflocaltime("%Y-%m-%d %H:%M");

# A footer entry such as "3 drafts", left out when the count is zero.
def tally($label; $style): if . > 0 then "\(.) \($label)" | cell($style) else empty end;


# 12345 as 12.3k, 5600000 as 5.6M; below 10000 as is.
def compactNumber:
  if . >= 1000000 then "\(. / 100000 | floor / 10)M"
  elif . >= 10000 then "\(. / 100 | floor / 10)k"
  else "\(.)" end;

def plural($word): if . == 1 then "1 \($word)" else "\(.) \($word)s" end;

# A pull request check as pass, fail or pending; checks gives them all for a PR.
def checkOutcome:
  if .__typename == "StatusContext" then
    {SUCCESS: "pass", FAILURE: "fail", ERROR: "fail"}[.state] // "pending"
  elif .status != "COMPLETED" then "pending"
  else
    {SUCCESS: "pass", NEUTRAL: "pass", SKIPPED: "pass",
     FAILURE: "fail", TIMED_OUT: "fail", CANCELLED: "fail", ACTION_REQUIRED: "fail", STARTUP_FAILURE: "fail"}
      [.conclusion] // "pending"
  end;

def checks: [(.statusCheckRollup // [])[] | checkOutcome];

def checksCell:
  checks as $outcomes
  | ($outcomes | length) as $total
  | "\($outcomes | map(select(. == "pass")) | length)/\($total)" as $count
  | if $total == 0 then "—" | cell(dim) | decor
    elif any($outcomes[]; . == "fail") then "✗ \($count)" | cell(red)
    elif any($outcomes[]; . == "pending") then "● \($count)" | cell(yellow)
    else "✓ \($count)" | cell(green) end;

# A five-step bar such as "▰▰▰▱▱ 3/5".
def progressBar($completed; $total):
  ($completed * 5 / $total | round) as $filled
  | ("▰" | times($filled) | cell(green) | decor)
    + ("▱" | times(5 - $filled) | cell(dim) | decor)
    + (" \($completed)/\($total)" | cell(""));

# Rounded frames for the terminal, $width columns wide; the labels and lines are rendered strings.
# The right label is left out when both don't fit.
def frameTop($left; $right; $width):
  def padded: if . == "" then "" else " \(.) " end;
  ($left | padded) as $leftLabel
  | ($width - 4 - ($leftLabel | visibleWidth)) as $room
  | ($right | padded | if visibleWidth < $room then . else "" end) as $rightLabel
  | ($room - ($rightLabel | visibleWidth)) as $fill
  | ("╭─" | paint(dim)) + $leftLabel + ("─" | times($fill) | paint(dim)) + $rightLabel + ("─╮" | paint(dim));

# A line too wide for the frame goes without its right border. frameRow takes the line's width.
def frameRow($used; $width):
  ($width - 4 - $used) as $gap
  | ("│ " | paint(dim)) + .
    + (if $gap < 0 then "" else (" " | times($gap)) + (" │" | paint(dim)) end);

def frameLine($width): frameRow(visibleWidth; $width);

def frameDivider($width): "├" + ("─" | times($width - 2)) + "┤" | paint(dim);
def frameBottom($width): "╰" + ("─" | times($width - 2)) + "╯" | paint(dim);

# Column widths in $width columns: the flex column takes what the others leave, max columns grow to
# their full width when there is room, and shrink (down to 12) to give the flex column up to 40.
def columnWidths($rows; $width):
  . as $columns
  | length as $count
  | [$columns[] | .key as $key | [(.header | textWidth), ($rows[] | .[$key] // [] | cellWidth)] | max] as $full
  | [range(0; $count) | [$full[.], ($columns[.].max // infinite)] | min] as $capped
  | [range(0; $count) | select($columns[.].flex)][0] as $flex
  | [range(0; $count) | select(. != $flex)] as $fixed
  | ($width - (2 * $count - 1)) as $room
  | ($room - ([$fixed[] | $capped[.]] | add // 0) - $full[$flex]) as $spare
  | (reduce $fixed[] as $index ({widths: $capped, spare: $spare};
       ([$full[$index] - .widths[$index], .spare] | min) as $extra
       | if $extra > 0 then .widths[$index] += $extra | .spare -= $extra else . end)
     | .widths) as $grown
  | ([$full[$flex], 20] | min) as $flexMinimum
  | ([$full[$flex], 40] | min) as $flexTarget
  | (reduce ($fixed[] | select($columns[.].max)) as $index
       ({widths: $grown, short: ($flexTarget - $room + ([$fixed[] | $grown[.]] | add // 0))};
       ([.short, .widths[$index] - 12] | min) as $cut
       | if $cut > 0 then .widths[$index] -= $cut | .short -= $cut else . end)
     | .widths) as $squeezed
  | ($room - ([$fixed[] | $squeezed[.]] | add // 0)) as $flexRoom
  | $squeezed
  | .[$flex] = ([if $isTerminal then $flexRoom else [$flexRoom, $full[$flex]] | min end, $flexMinimum] | max);

def tableWidth: add + 2 * (length - 1);

# Leaves out the drop columns, last first, while the table is wider than $width.
def fitColumns($rows; $width):
  columnWidths($rows; $width) as $widths
  | [range(0; length) as $index | select(.[$index].drop) | $index] as $droppable
  | if $isTerminal and ($widths | tableWidth) > $width - 1 and $droppable != []
    then del(.[$droppable[-1]]) | fitColumns($rows; $width)
    else {columns: ., widths: $widths} end;

# The fzf list's four tab-separated key fields (kind, repo, id, extra), then the line.
def keyed($key): ([($key // [])[], "", "", "", ""][0:4] | map(tostring) | join("\t")) + "\t" + .;

def exportRows: . as $table | $table.rows[] | . as $row | [$table.columns[] | {key: .key, value: ($row[.key] // [] | cellText)}];

# Renders {title, subtitle, columns: [{key, header, align?, flex?, max?, drop?}], rows, footer, empty}
# as lines: framed on a terminal, plain when piped, and only the header and rows with --arg view list
# (fzf). A narrow terminal leaves out the drop columns. Rows may carry _key for the list.
# --arg view json or csv exports the rows' text instead.
def table:
  ($ARGS.named.view // "") as $view
  | if $view == "json" then [exportRows | from_entries]
    elif $view == "csv" then ([.columns[].header] | @csv), (exportRows | map(.value) | @csv)
    else
      . as $table
      | ($isTerminal and $view != "list") as $framed
      | (if $framed then $terminalWidth - 3 else $terminalWidth end) as $width
      | $table.rows as $rows
      | ($table.columns | fitColumns($rows; $width)) as {columns: $columns, widths: $widths}
      | ($widths | tableWidth) as $tableWidth
      | (if $framed or $view == "list" then "" else " " end) as $indent
      | def line($cells):
          $indent + ([range(0; $columns | length) as $index
                  | $cells[$index] | renderCell($widths[$index]; $columns[$index].align // "left")] | join("  "))
          | if $framed then . else sub(" +$"; "") end;
        def rule: $indent + ("─" | times($tableWidth) | paint(dim));
        def header: line([$columns[] | .header | cell(dim)]);
        def body:
          if $rows == [] then $indent + ($table.empty | paint(dim))
          else $rows[] | . as $row | line([$columns[] | $row[.key] // []]) end;
        def footer($footerWidth): ($table.footer | wrapCells($footerWidth; "  ·  " | cell(dim)))[] | $indent + renderInline;
        if $view == "list" then
          (header | keyed(null)),
          (if $rows == [] then body | keyed(null)
           else $rows[] | . as $row | line([$columns[] | $row[.key] // []]) | keyed($row._key) end)
        elif $framed then
          "",
          frameTop($table.title | renderInline; $table.subtitle | renderInline; $terminalWidth),
          ((header, rule, if $rows == [] then empty else body end) | frameRow($tableWidth; $terminalWidth)),
          (if $rows == [] then body | frameLine($terminalWidth) else empty end),
          frameDivider($terminalWidth),
          (footer($terminalWidth - 4) | frameLine($terminalWidth)),
          frameBottom($terminalWidth),
          ""
        else
          "",
          " " + ($table.title | renderInline),
          " " + ($table.subtitle | renderInline),
          "",
          header,
          rule,
          body,
          rule,
          footer(infinite),
          ""
        end
    end;
