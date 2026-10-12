# github-scripts

`ghs` — terminal reports for GitHub repositories, built on the `gh` CLI.

```sh
ghs issues                 # open issues, sub-issues nested under their parent
ghs issues 42 -c           # issue #42 with its sub-issues, description and comments
ghs pr -R cli/cli          # pull requests with review, checks and size
ghs runs -b main -w CI     # recent GitHub Actions runs with outcome and duration
```

## Requirements

- [`gh`](https://cli.github.com/), logged in (`gh auth login`)
- [`jq`](https://jqlang.org/) 1.7 or later
- bash 3.2 or later
- optional: [`glow`](https://github.com/charmbracelet/glow) 3 or later, to render issue descriptions and
  comments as Markdown
- optional: [`gum`](https://github.com/charmbracelet/gum), for a spinner while `gh` loads
- optional: [`fzf`](https://github.com/junegunn/fzf) 0.42 or later, to browse with `-i`

## Install

```sh
git clone https://github.com/flombois/github-scripts.git
cd github-scripts
./install.sh
```

The installer works on macOS and Linux and reports each step:

1. **Platform**: the OS and its package manager (Homebrew on macOS; apt, dnf, yum, pacman, zypper,
   apk or Homebrew on Linux).
2. **Requirements**: checks `gh` and `jq` (1.7 or later). For each missing or outdated one it shows
   the install command and asks before running it. It also offers `gh auth login` if you are not
   logged in. glow, gum and fzf are optional: the installer offers them through
   Homebrew, and elsewhere prints where to get them (Linux distributions package only glow 2 so far).
3. **Commands**: links `github-scripts` and its short name `ghs` into `~/.local/bin`, pointing at the
   clone. If that directory is not on your `PATH`, it prints the line to add to your shell profile.

Options:

- `--prefix DIR` puts the links in another directory.
- `--yes` installs missing packages without asking (for scripts and CI).

On Linux, package installs go through `sudo` unless you run as root. Some older releases ship jq
1.6 (Debian 12, Ubuntu 22.04); there, install jq 1.7 from [jqlang.org](https://jqlang.org/download/)
and rerun the installer.

## Update

```sh
cd github-scripts
git pull
```

The commands are links to the clone, so pulling is enough. If you move the clone, run
`./install.sh` again from its new place.

## Uninstall

```sh
cd github-scripts
./uninstall.sh            # add --prefix DIR if you installed with one
```

This removes the two links and nothing else; delete the clone afterwards if you no longer need it.

## Usage

```sh
ghs <command> [options]
```

`github-scripts` and `ghs` are the same command.

| Command         | Alias    | Shows                                                                   |
|-----------------|----------|-------------------------------------------------------------------------|
| `backlog`       | `issues` | Open issues, sub-issues nested under their parent, with type and labels |
| `issue`         | —        | One issue: state, labels, parent, sub-issues, description and comments  |
| `pull-requests` | `pr`     | Pull requests with review decision, check results and size              |
| `pull-request`  | —        | One pull request: reviewers, merge status, checks, files and comments   |
| `pipeline-runs` | `runs`   | Recent GitHub Actions runs with outcome, duration and success rate      |
| `inbox`         | `notifications` | Your unread notifications across repositories, with type and reason |

Every command reads the repository of the current directory, or the one given with `-R`:

```sh
ghs issues
ghs issues -R owner/repo
ghs pr -R owner/repo -s all -L 50
ghs runs -R owner/repo -b main -w CI -L 10
```

`-R` also accepts a GitHub URL or an SSH remote.

`issues` and `pr` take filters: `-l` label (repeat for several), `-a` assignee and `-A` author
(`@me` works), `-S` search text in GitHub search syntax, plus `-t` type and `-m` milestone for
issues, and `-B` base branch and `-r` review requested for pull requests. `issues -s closed|all`
includes closed issues.

```sh
ghs issues -l bug -a @me
ghs issues -t Bug -S "merge conflict"
ghs pr -r @me
```

Every table command takes `--format json` or `--format csv` to export the rows' text (pretty-printed
JSON, or CSV with a header row). Responses are cached for 5 minutes in `~/.cache/ghs`
(`GHS_CACHE_TTL` sets the seconds), so reopening a view is quick; `--refresh` fetches again.

To read one issue, put its number after `issues` (or `issue`), and likewise for a pull request
after `pr`. `-c` adds the comments (and, for a pull request, the reviews):

```sh
ghs issues 42
ghs issues 42 -c -R owner/repo
ghs pr 1234 -c
```

A pull request shows who wants to merge what into which branch, then its reviewers (✓ approved,
✗ changes requested, ● awaited), merge status, checks (failures first) and the files with the most
changes.

Long issues open in `less` (or `$PAGER`); short ones print directly. With glow installed, the
description and comments are rendered as Markdown (set `GLAMOUR_STYLE=light` on a light terminal), and
on a terminal 110 columns or wider the assignees, labels, type, milestone and parent move to a sidebar
on the right, as on GitHub. Piped output keeps the raw Markdown.

To browse instead, add `-i` to `issues`, `pr` or `runs` (needs fzf). Type to filter the list; the
issue, pull request or run under the cursor shows in a preview pane (beside the list from 160
columns, below it otherwise). Enter opens it in full, ctrl-o opens it in the browser, ctrl-r reloads
the list, Esc quits. Alt keys act on the item, then reload the list; changes ask for confirmation
first:

| Browsing | Keys |
|----------|------|
| issues   | alt-a assign to me · alt-c comment · alt-x close |
| pr       | alt-k check out (in a clone of the repository) · alt-a approve · alt-m merge (gh asks how) · alt-c comment |
| runs     | alt-r re-run failed jobs · alt-l failed logs · alt-w watch |
| inbox    | alt-d mark as read (Enter shows a pull request or issue; other threads open in the browser) |

`ghs inbox` reads your notifications from every repository (`-R` for one, `-a` to include read
ones, `-p` for threads you take part in), so it needs no repository.

```sh
ghs issues -i
ghs pr -s all -i
```

- `ghs --help` lists the commands.
- `ghs <command> --help` (or `ghs help <command>`) lists the options of a command.

On a terminal, tables and issues are drawn in rounded frames, and each issue's description and
comments are cards, as on GitHub. Every view fills the terminal width: the title column of a table
stretches, and narrow terminals clip the longest columns first, then leave out the least useful
ones (override the width with `COLUMNS=120`). Issue and PR numbers,
titles, runs, people, labels and the repository are clickable links in terminals that support them
(iTerm2, kitty, WezTerm, GNOME Terminal, Windows Terminal…). Piped output has no colours, links,
frames, spinner or clipping.

## Layout

- `cli.sh` — the `ghs` entry point: routes `ghs <command>` to `bin/<command>.sh`, and holds the aliases
- `install.sh`, `uninstall.sh` — add and remove the `github-scripts` and `ghs` links
- `bin/` — one script per command: options, the `gh` query, and the columns of its table (`issue.sh`
  prints one issue instead of a table)
- `lib/common.sh` — option helpers, repository detection, the `jq` call, paging, glow, the gum
  spinner and the fzf browse
- `lib/install.sh` — link names and output helpers shared by the installer and uninstaller
- `lib/packages.sh` — platform detection, requirement checks and package installs for the installer
- `lib/table.jq` — table rendering and frames shared by every command; a cell is a list of
  `{text, style, link}` segments
