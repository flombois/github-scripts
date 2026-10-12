# Shared rendering for the report scripts; expects $isTerminal and $terminalWidth.
# A cell is an array of {text, style} segments, where a style is an ANSI SGR code.

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

def times($count): if $count > 0 then . * $count else "" end;
def paint($style):
  if $isTerminal and $style != "" and . != "" then "\u001b[\($style)m\(.)\u001b[0m" else . end;

def cell($style): [{text: ., style: $style}];
def cellWidth: map(.text | length) | add // 0;
def joinCells($separator): reduce .[] as $cell ([]; if . == [] then $cell else . + $separator + $cell end);
def renderInline: map(.style as $style | .text | paint($style)) | join("");

# Packs cells into as few lines as fit $width, joined by $separator.
def wrapCells($width; $separator):
  reduce .[] as $cell ([];
    if . == [] then [$cell]
    elif (.[-1] + $separator + $cell | cellWidth) <= $width then .[-1] += $separator + $cell
    else . + [$cell] end);

def clipCell($width):
  if cellWidth <= $width then .
  else
    reduce .[] as $segment ({room: ($width - 1), kept: []};
      .room as $room
      | if $room > 0
        then .kept += [$segment | .text |= .[0:$room]] | .room -= ($segment.text | length)
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


def plural($word): if . == 1 then "1 \($word)" else "\(.) \($word)s" end;

# A five-step bar such as "▰▰▰▱▱ 3/5".
def progressBar($completed; $total):
  ($completed * 5 / $total | round) as $filled
  | ("▰" | times($filled) | cell(green))
    + ("▱" | times(5 - $filled) | cell(dim))
    + (" \($completed)/\($total)" | cell(""));

# Renders {title, subtitle, columns: [{key, header, align?, flex?, max?}], rows, footer, empty} as lines.
# On a terminal the single flex column stretches to fill the width. max caps a column only when
# the room is short.
def table:
  . as $table
  | $table.columns as $columns
  | $table.rows as $rows
  | ($columns | length) as $count
  | [$columns[] | .key as $key | [(.header | length), ($rows[] | .[$key] // [] | cellWidth)] | max] as $full
  | [range(0; $count) | [$full[.], ($columns[.].max // infinite)] | min] as $capped
  | [range(0; $count) | select($columns[.].flex)][0] as $flex
  | [range(0; $count) | select(. != $flex)] as $fixed
  | ($terminalWidth - (2 * $count - 1)) as $room
  | ($room - ([$fixed[] | $capped[.]] | add // 0) - $full[$flex]) as $spare
  | (reduce $fixed[] as $index ({widths: $capped, spare: $spare};
       ([$full[$index] - .widths[$index], .spare] | min) as $extra
       | if $extra > 0 then .widths[$index] += $extra | .spare -= $extra else . end)
     | .widths) as $grown
  | ([$full[$flex], 20] | min) as $flexMinimum
  | (reduce ($fixed[] | select($columns[.].max)) as $index
       ({widths: $grown, short: ($flexMinimum - $room + ([$fixed[] | $grown[.]] | add // 0))};
       ([.short, .widths[$index] - 12] | min) as $cut
       | if $cut > 0 then .widths[$index] -= $cut | .short -= $cut else . end)
     | .widths) as $squeezed
  | ($room - ([$fixed[] | $squeezed[.]] | add // 0)) as $flexRoom
  | ($squeezed
     | .[$flex] = ([if $isTerminal then $flexRoom else [$flexRoom, $full[$flex]] | min end, $flexMinimum]
                   | max)) as $widths
  | (($widths | add) + 2 * (($widths | length) - 1)) as $tableWidth
  | def line($cells):
      " " + ([range(0; $columns | length) as $index
              | $cells[$index] | renderCell($widths[$index]; $columns[$index].align // "left")] | join("  "))
      | sub(" +$"; "");
    def rule: " " + ("─" | times($tableWidth) | paint(dim));
    "",
    " " + ($table.title | renderInline),
    " " + ($table.subtitle | renderInline),
    "",
    line([$columns[] | .header | cell(dim)]),
    rule,
    (if $rows == [] then " " + ($table.empty | paint(dim))
     else $rows[] | . as $row | line([$columns[] | $row[.key] // []]) end),
    rule,
    ((if $isTerminal then $terminalWidth - 1 else infinite end) as $footerWidth
     | ($table.footer | wrapCells($footerWidth; "  ·  " | cell(dim)))[] | " " + renderInline),
    "";
