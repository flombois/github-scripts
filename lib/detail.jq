# Shared by the detail views (issue.sh, pull-request.sh); expects $layout, $markdown and $index too.

def personCell: profileUrl as $profile | "@\(.)" | cell(magenta) | linkTo($profile);

def field($label; $value):
  ($label | 12 - length) as $gap
  | ($label + (" " | times($gap)) | cell(dim)) + $value;

def labelCells:
  (.url | sub("/(issues|pull)/[0-9]+$"; "/labels/")) as $labelsUrl
  | [.labels[] | .color as $color | "\($labelsUrl)\(.name | @uri)" as $url
     | ("●" | cell($color | hexColor)) + (" \(.name)" | cell("")) | linkTo($url)];

def labelsCell: labelCells | if . == [] then "—" | cell(dim) else joinCells("  " | cell("")) end;

def assigneesCell:
  [.assignees[].login | personCell]
  | if length > 0 then joinCells(" " | cell("")) else "—" | cell(dim) end;

def issueRef: .url as $url | ("#\(.number)" | cell(bold)) + (" \(.title)" | cell("")) | linkTo($url);

# The GitHub sidebar: one section per field, a placeholder when it is unset.
def orNone($placeholder): if . == [] then [$placeholder | cell(dim)] else . end;

def sidebarSection($title; $cells): [($title | paint(bold)), ($cells[] | clipCell($terminalWidth) | renderInline)];

# Usage: [sidebarSection(…), …] | sidebarLines
def sidebarLines: (.[0][]), (.[1:][] | ("─" | times($terminalWidth) | paint(dim)), .[]);

# Markdown without the HTML comments GitHub hides, Windows line ends or surrounding blank lines.
def cleanMarkdown:
  gsub("\r"; "") | gsub("<!--[\\s\\S]*?-->"; "") | gsub("\n{3,}"; "\n\n") | sub("^(\\s*\n)+"; "") | sub("\\s+$"; "");

def textLines($indent): cleanMarkdown | split("\n")[] | $indent + . | sub(" +$"; "");

# Word-wraps a raw line to $width, keeping its indent on every piece.
def wrapLine($width):
  capture("^(?<indent> *)(?<text>.*)$") as $parts
  | ($parts.text | split(" ") | map(cell(""))
     | wrapCells($width - ($parts.indent | length); " " | cell(""))) as $pieces
  | if $pieces == [] then "" else $pieces[] | $parts.indent + renderInline end;

def hasText: . // "" | test("\\S");

def rule: " " + ("─" | times(if $isTerminal then $terminalWidth - 2 else 100 end) | paint(dim));

def hiddenReason: "(hidden: \(.minimizedReason | ascii_downcase))";

def inner: $terminalWidth - 4;

# Usage: framedHeader(badge; status cells; field lines), with the item as input.
def framedHeader($badge; $status; $fields):
  .url as $url
  | "",
    frameTop("#\(.number)" | cell(bold) | linkTo($url) | renderInline; $badge | renderInline; $terminalWidth),
    ((.title | split(" ") | map(cell(bold) | linkTo($url)) | wrapCells(inner; " " | cell(""))[] | renderInline),
     ($status | wrapCells(inner; " · " | cell(dim))[]
      | if cellWidth > inner then words | wrapCells(inner; " " | cell(""))[] else . end | renderInline),
     (if $layout == "sidebar" or $fields == [] then empty
      else "", ($fields[] | clipCell(inner) | renderInline) end)
     | frameLine($terminalWidth)),
    frameBottom($terminalWidth),
    "";

# A card drawn in jq, for parts with no Markdown: a title cell and lines of cells.
def framedCard($title; $lines):
  frameTop($title | renderInline; ""; $terminalWidth),
  ($lines[] | clipCell(inner) | renderInline | frameLine($terminalWidth)),
  frameBottom($terminalWidth),
  "";

def cardTitle($verb):
  (.author.login // "ghost" | profileUrl as $profile | "@\(.)" | cell(bold) | linkTo($profile))
  + (" \($verb) \(.createdAt | ago)" | cell(dim))
  | renderInline;

def cardBody:
  if $markdown then
    if .isMinimized then "_\(hiddenReason)_"
    elif .body | hasText then .body | cleanMarkdown
    else "_No description provided._" end
  elif .isMinimized then hiddenReason | paint(dim)
  elif .body | hasText then .body | textLines("") | wrapLine($terminalWidth)
  else "No description provided." | paint(dim) end;

def commentLines:
  " " + ((.author.login // "ghost" | profileUrl as $profile | "@\(.)" | cell(bold) | linkTo($profile))
         + (" · \(.createdAt | ago)" | cell(dim)) | renderInline),
  (if .isMinimized then "    " + (hiddenReason | paint(dim)) else .body | textLines("    ") end),
  "";

def commentMarkdown:
  "**@\(.author.login // "ghost")** · \(.createdAt | ago)\n\n"
  + (if .isMinimized then "_\(hiddenReason)_" else .body | cleanMarkdown end);

def footerLines:
  " " + (.url as $url | $url | cell(dim) | linkTo($url) | renderInline),
  "";
