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
   logged in. glow is optional: the installer offers it through
   Homebrew, and elsewhere prints where to get it (Linux distributions package only glow 2 so far).
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
| `pipeline-runs` | `runs`   | Recent GitHub Actions runs with outcome, duration and success rate      |

Every command reads the repository of the current directory, or the one given with `-R`:

```sh
ghs issues
ghs issues -R owner/repo
ghs pr -R owner/repo -s all -L 50
ghs runs -R owner/repo -b main -w CI -L 10
```

`-R` also accepts a GitHub URL or an SSH remote.

To read one issue, put its number after `issues` (or `issue`). `-c` adds the comments:

```sh
ghs issues 42
ghs issues 42 -c -R owner/repo
```

Long issues open in `less` (or `$PAGER`); short ones print directly. With glow installed, the
description and comments are rendered as Markdown (set `GLAMOUR_STYLE=light` on a light terminal), and
on a terminal 110 columns or wider the assignees, labels, type, milestone and parent move to a sidebar
on the right, as on GitHub. Piped output keeps the raw Markdown.

- `ghs --help` lists the commands.
- `ghs <command> --help` (or `ghs help <command>`) lists the options of a command.

Every view fills the terminal width: the title column of a table stretches, and narrow terminals
clip the longest columns first (override the width with `COLUMNS=120`). Piped output has no colours
and no clipping.

## Layout

- `cli.sh` — the `ghs` entry point: routes `ghs <command>` to `bin/<command>.sh`, and holds the aliases
- `install.sh`, `uninstall.sh` — add and remove the `github-scripts` and `ghs` links
- `bin/` — one script per command: options, the `gh` query, and the columns of its table (`issue.sh`
  prints one issue instead of a table)
- `lib/common.sh` — option helpers, repository detection, the `jq` call, paging and glow
- `lib/install.sh` — link names and output helpers shared by the installer and uninstaller
- `lib/packages.sh` — platform detection, requirement checks and package installs for the installer
- `lib/table.jq` — table rendering shared by every command; a cell is a list of `{text, style}` segments
