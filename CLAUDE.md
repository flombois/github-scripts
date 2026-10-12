# CLAUDE.md

`ghs` (also `github-scripts`): a Bash + jq CLI of reports on top of the `gh` CLI. `cli.sh` routes
`ghs <command>` to `bin/<command>.sh`; `install.sh` links it onto the `PATH`. `README.md` covers
usage and layout; `--help` on each command lists its options.

## Adding or changing a report

Every script in `bin/` has the same shape; copy an existing one:

1. `usage`, then the option loop (it splits `--opt=value`, checks values with `needs_value`, and ends
   with `repo="$(resolve_repo "$repo")"`).
2. One `gh` call whose JSON is captured into a variable, `|| fail "could not read …"`, so a `gh`
   error stops the script before jq runs.
3. A jq `program` that builds `{title, subtitle, columns, rows, footer, empty}` and ends in `| table`,
   handed to `render_table` with any extra `--arg`s.

A new `bin/<name>.sh` is a `ghs <name>` command with no change to `cli.sh`. Its line-2 comment is
its description in `ghs --help`, so keep it to one line. Short aliases live in `ALIASES` in
`cli.sh`; add the alias to the README command table too.

Table rules, all enforced by `lib/table.jq`:

- A **cell** is an array of **segments** `{text, style}`; build one with `"text" | cell(green)` and
  join cells with `+`. A style is an ANSI SGR code from the named defs (`bold`, `dim`, `red`, …,
  `hexColor` for GitHub label hex, `namedColor` for issue-type enum colours).
- Colour goes through `paint` only, which is a no-op off a terminal, so piped output stays plain.
- One column per table is `flex: true` (it takes the leftover width); cap long columns with `max: N`.
  Clipping is done by the table, so cells carry full text.
- Footer counts use `tally` (drops zeros) and `plural`.

## Gotchas

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

`cli/cli` has enough open PRs, labels and runs to exercise most cells. For states no live repo shows
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
