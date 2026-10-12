# CLAUDE.md

`ghs` (also `github-scripts`): a Bash + jq CLI of reports on top of the `gh` CLI. `cli.sh` routes
`ghs <command>` to `bin/<command>.sh`; `install.sh` links it onto the `PATH`. `README.md` covers
usage and layout; `--help` on each command lists its options.

## Adding or changing a report

Every script in `bin/` has the same shape; copy an existing one:

1. `usage`, then the option loop (it splits `--opt=value`, checks values with `needs_value`, and ends
   with `repo="$(resolve_repo "$repo")"`).
2. One `gh` call, wrapped in `with_spinner "Loading …"` (a gum spinner on a terminal), whose JSON is
   captured into a variable, `|| fail "could not read …"`, so a `gh` error stops the script before jq
   runs.
3. A jq `program` that builds `{title, subtitle, columns, rows, footer, empty}` and ends in `| table`,
   handed to `render_table` with any extra `--arg`s, or to `browse <issue|pr|run>` with `-i` (fzf).

`issue.sh` is the one command without a table: after steps 1–2 its program prints its own lines
in parts (`--arg part …`), so the shell can pass the Markdown to glow 3 (`render_markdown`) and
`page` the whole issue through `less`.

- **Piped:** the parts `header|body|subIssues|divider|comments|footer` are printed as raw text.
- **On a terminal:**
  - `header` and `subIssues` are framed boxes.
  - The description and each comment are cards. `print_card` passes `bodyTitle` + `description`,
    or `commentTitle` + `comment` (with `--argjson index`), through glow at the card's inner width,
    then through `frame_program`.
  - Without glow, the cards hold raw Markdown.
- **Sidebar:** with glow and 110+ columns, `--arg layout sidebar` moves the fields into a
  GitHub-style sidebar. The cards render at the narrower main width, and `beside_program` pads each
  line to it and appends a sidebar line. `backlog.sh 42` (`ghs issues 42`) hands
over to it when the first argument is a number.

A new `bin/<name>.sh` is a `ghs <name>` command with no change to `cli.sh`. Its line-2 comment is
its description in `ghs --help`, so keep it to one line. Short aliases live in `ALIASES` in
`cli.sh`; add the alias to the README command table too.

Table rules, all enforced by `lib/table.jq`:

- A **cell** is an array of **segments** `{text, style}`; build one with `"text" | cell(green)` and
  join cells with `+`. A style is an ANSI SGR code from the named defs (`bold`, `dim`, `red`, …,
  `hexColor` for GitHub label hex, `namedColor` for issue-type enum colours).
- Colour goes through `paint` only, which is a no-op off a terminal, so piped output stays plain.
- `cell | linkTo($url)` makes a segment an OSC 8 hyperlink, emitted by `renderInline` on a terminal
  only. The link lives beside the text, so widths and clipping are unaffected; bind the URL first,
  since `linkTo`'s argument is evaluated against the cell.
- Widths are display widths (`textWidth`, `visibleWidth` past ANSI and OSC 8 codes): CJK and emoji
  count twice. A right border shows any mistake, so measure with these, never `length`.
- One column per table is `flex: true`; on a terminal it stretches to fill the width.
  - `max: N` marks a column that may be clipped: to N when room is short, and down to 12 to give the
    flex column up to 40. A capped column isn't clipped when there is room.
  - `drop: true` columns are left out, last first, while the table is still too wide.
  - Clipping is done by the table, so cells carry full text.
- On a terminal the table is framed (`frameTop`/`frameRow`/`frameLine`/`frameDivider`/`frameBottom`)
  and the footer wraps inside it. `--arg view list` prints only the header and rows, for fzf.
- Footer counts use `tally` (drops zeros) and `plural`.

## Gotchas

- `tput cols` inside `$(…)` answers 80 whatever the terminal, since its stdout is a pipe.
  `terminal_width` asks `stty size </dev/tty` instead. In tests, set the width with `stty cols N`
  inside `script` (or with `COLUMNS`).

- `GHS_FORCE_TERMINAL=1` makes `on_terminal` true and stops `page` paging. fzf previews need it,
  since their stdout is a pipe. Previews of PRs and runs use gh's own `GH_FORCE_TTY` instead.
- In bash 3.2, `"$repo…"` reads the `…` bytes as part of the name; write `"${repo}…"`.
- fzf can't be scripted under `script`. To see its screen, run it in a pty and render the output
  with pyte (a Python VT emulator). To check a preview, run its command by hand with
  `GHS_FORCE_TERMINAL=1 COLUMNS=60`.
- glow writes terminal queries (colours, cursor) to stderr even with `-s`; their replies would land
  in `less`. `render_markdown` runs it with `TERM=dumb`, which stops them and keeps the colours.
- **jq evaluates a function's arguments against the function's input.** In
  `" " | times($width - length)`, `length` measures `" "`. Bind first:
  `($width - length) as $gap | " " | times($gap)`. This caused most bugs so far.
- `repeat` is a jq builtin; the padding helper is named `times` to leave it unshadowed.
- `/bin/bash` on macOS is 3.2: expand a possibly-empty array as `${filters[@]+"${filters[@]}"}`
  under `set -u`, and stay with indexed arrays and plain `[[ ]]` tests.
- Edit jq programs with the Edit tool. jq's `//` operator collides with sed/perl regex delimiters.
- `gh run list` can return an empty `workflowName`; `pipeline-runs.sh` falls back to `name`.
- GitHub truncates some `displayTitle`s itself, so a title ending in `…` is not a clipping bug.
- Org remotes look like `org-12345678@github.com:Owner/repo.git`; `resolve_repo` strips any
  `user@github.com:` prefix.

## Verifying

There is no test suite. After a change, run the touched script both ways:

```sh
bin/pull-requests.sh -R cli/cli -L 10                                   # piped: no colour, no clipping
COLUMNS=110 script -q /dev/null bin/pull-requests.sh -R cli/cli -L 10 \
  | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g'                                # terminal: clipped to 110
```

`cli/cli` has enough open PRs, labels and runs to exercise most cells. For `issue.sh`, cli/cli
#14529 has a parent and sub-issues, #14643 is closed as not planned, and vercel/next.js #100022 has a
type. Under `script`, set `PAGER=cat` and redirect stdin from `/dev/null`. To check the fallback, put a
fake `glow` that prints `glow version 2.1.2` first on the `PATH`. For states no live repo shows
(running, queued, failed runs), render a hand-written fixture through the real program, under bash
since the agent shell is zsh:

```sh
bash -c 'program="$(sed -n "/^program=.\$/,/^.\$/p" bin/pipeline-runs.sh | sed "1d;\$d")"
source lib/common.sh
render_table "$program" --arg repo fixture/runs --arg branch "" --arg workflow "" < runs.json'
```

Also check the error paths still read cleanly: an unknown option, a bad `-R`, and running outside a
git repository.

## Version control

Feature branches are named `flombois/<issue-id>-short-name`; changes land through a pull request.
