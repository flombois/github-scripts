# github-scripts

`ghs` — terminal reports for GitHub repositories, built on the `gh` CLI.

```sh
ghs issues                 # open issues, sub-issues nested under their parent
ghs issues 42 -c           # issue #42 with its sub-issues, description and comments
ghs pr -R cli/cli          # pull requests with review, checks and size
ghs actions -b main -w CI  # recent GitHub Actions runs with outcome and duration
ghs info                   # repository overview: stats, activity, CI health, contributors
ghs settings -i            # browse the repository's settings and change them
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
   Homebrew, and elsewhere prints where to get them (most Linux distributions package only glow 2
   so far; nixpkgs has glow 3).
3. **Commands**: links `github-scripts` and its short name `ghs` into `~/.local/bin`, pointing at the
   clone. If that directory is not on your `PATH`, it prints the line to add to your shell profile.

Options:

- `--prefix DIR` puts the links in another directory.
- `--yes` installs missing packages without asking (for scripts and CI).

On Linux, package installs go through `sudo` unless you run as root. Some older releases ship jq
1.6 (Debian 12, Ubuntu 22.04); there, install jq 1.7 from [jqlang.org](https://jqlang.org/download/)
and rerun the installer.

### Nix

The repository is a flake, so on NixOS, nix-darwin or any machine with Nix there is nothing to
install or link: the package wraps `ghs` with `gh`, `jq`, `glow` 3, `gum` and `fzf` on its `PATH`,
and ships the bash completion.

```sh
nix run github:flombois/github-scripts -- issues -R cli/cli   # try it once
nix profile install github:flombois/github-scripts            # keep it
```

To declare it instead, add the flake as an input and the package to your configuration:

```nix
# flake.nix
inputs.github-scripts.url = "github:flombois/github-scripts";

# NixOS: configuration.nix          home-manager: home.nix
environment.systemPackages = [ inputs.github-scripts.packages.${pkgs.system}.default ];
home.packages = [ inputs.github-scripts.packages.${pkgs.system}.default ];
```

`overlays.default` is there too, if you would rather have `pkgs.github-scripts`. Completion is
loaded for you with `programs.bash.completion.enable` (NixOS) or `programs.bash.enableCompletion`
(home-manager); for zsh, add `eval "$(ghs completion zsh)"` as `programs.zsh.initContent`.

Without flakes, or to run the scripts straight from a clone, the packages are
`gh jq glow gum fzf less util-linux`; `install.sh` detects Nix and prints what to declare rather
than installing anything. `nix develop` gives a shell with those plus Python with `pyte`, which
renders fzf's screen when checking the browse.

## Update

```sh
cd github-scripts
git pull
```

The commands are links to the clone, so pulling is enough. If you move the clone, run
`./install.sh` again from its new place. With Nix, update the flake input (or
`nix profile upgrade github-scripts`) instead.

## Uninstall

```sh
cd github-scripts
./uninstall.sh            # add --prefix DIR if you installed with one
```

With Nix, `nix profile remove github-scripts`, or drop the package from your configuration.

This removes the two links and nothing else; delete the clone afterwards if you no longer need it.

## Usage

```sh
ghs <command> [options]
```

`github-scripts` and `ghs` are the same command.

| Command         | Alias   | Shows                                                                   |
|-----------------|---------|-------------------------------------------------------------------------|
| `issues`        | —       | Open issues, sub-issues nested under their parent, with type and labels |
| `issue`         | —       | One issue: state, labels, parent, sub-issues, description and comments  |
| `pull-requests` | `pr`    | Pull requests with review decision, check results and size              |
| `pull-request`  | —       | One pull request: reviewers, merge status, checks, files and comments   |
| `actions`       | `runs`  | Recent GitHub Actions workflow runs with outcome, duration and success rate |
| `notifications` | `inbox` | Your unread notifications across repositories, with type and reason     |
| `releases`      | —       | Releases with latest / pre-release / draft status, assets and downloads |
| `info`          | —       | Overview: stats, recent merges and commits, CI health per workflow, latest release, top contributors |
| `settings`      | —       | Settings, rulesets, secrets and variables, and labels; view and change them |
| `security`      | —       | Dependabot, code scanning and secret scanning alerts; dismiss or reopen them |
| `completion`    | —       | Prints the tab completion script for bash or zsh                        |

Every command reads the repository of the current directory, or the one given with `-R`:

```sh
ghs issues
ghs issues -R owner/repo
ghs pr -R owner/repo -s all -L 50
ghs actions -R owner/repo -b main -w CI -L 10
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

Older answers stay in the cache for when GitHub can't be reached. If there's no network or GitHub
is down, a view you've opened before shows its last answer, with a note on stderr saying how old it
is. `--offline` (or `GHS_OFFLINE=1`) never contacts GitHub, and works out the repository from the
git remote. Actions that change something are refused while offline. `GHS_CACHE_KEEP` sets how long
answers are kept: a number of days (default 30), `forever`, or `never` to turn the fallback off.

```sh
ghs issues --offline
GHS_CACHE_KEEP=forever ghs pr
```

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

To browse instead, add `-i` to `issues`, `pr`, `actions`, `notifications`, `releases`, `security` or `settings`
and its subcommands (needs fzf). Type to filter the list; the item under the cursor shows in a
preview pane (beside the list from 160 columns, below it otherwise). Enter opens it in full, ctrl-o
opens it in the browser, ctrl-r reloads the list, Esc quits. Alt keys act on the item, then reload
the list; changes ask for confirmation first:

| Browsing | Keys |
|----------|------|
| issues   | alt-a assign to me · alt-c comment · alt-x close |
| pr       | alt-k check out (in a clone of the repository) · alt-a approve · alt-m merge (gh asks how) · alt-c comment |
| actions  | alt-r re-run failed jobs · alt-l failed logs · alt-w watch |
| notifications | alt-d mark as read (Enter shows a pull request or issue; other threads open in the browser) |
| settings | ← → flip a switch or step through a choice in place; Enter changes a setting (a text one in an edit box: Enter saves, Esc cancels); the subcommands' keys are under [Settings](#settings) |
| security | Enter or ctrl-o opens the alert on GitHub · alt-d dismiss (asks why) · alt-r reopen |

`ghs security` lists the open Dependabot, code scanning and secret scanning alerts, most severe
first (`-s closed` or `all`, `-k dependabot|code|secret`, `--severity high` for high and critical).
A source that is turned off or that you may not read shows as a note under the table.

`ghs notifications` (or `ghs inbox`) reads your notifications from every repository (`-R` for one,
`-a` to include read ones, `-p` for threads you take part in), so it needs no repository.

```sh
ghs issues -i
ghs pr -s all -i
```

To follow CI, `--watch` redraws every 5 seconds (or `--watch 10`) and stops once nothing is queued or
running: `ghs actions --watch` for the runs table, `ghs pr 42 --watch` for a pull request's checks.

For tab completion of commands, options, states, formats, workflow names, branches, repositories and
settings, add this line to `~/.zshrc` (or `bash` to `~/.bashrc`):

```sh
eval "$(ghs completion zsh)"
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

## Settings

`ghs settings` lists a repository's general, feature and pull request settings. Change one with
`set`, or with `-i`: the left and right arrows flip a switch or step to the previous or next choice
right in the list, and Enter asks for a new value (text settings open an edit box holding the current
value). Changes need admin access; in `-i`, the visibility and Enter's switch and choice changes are
confirmed first:

```sh
ghs settings
ghs settings set wiki off
ghs settings set topics "cli bash jq"
ghs settings set squash-message pr-title-description
ghs settings set visibility private --yes     # asks first without --yes
ghs settings -i
```

`ghs settings --help` lists the settings and their values. The rest have their own subcommands, each
with a table, `-i`, `--format` and `--help`:

| Subcommand | Shows | Changes |
|------------|-------|---------|
| `rules` | Rulesets (the repository's and those it inherits) and classic branch protection, with what they protect | `set <ruleset> active\|evaluate\|disabled`; in `-i`, alt-e enforce · alt-v evaluate · alt-x disable |
| `secrets`, `variables` | Actions secrets (names only) and variables (with values) | `set <name> [value]`, `delete <name>`; in `-i`, Enter new value · alt-n new secret · alt-v new variable · alt-x delete |
| `labels` | Labels with colour, description, and their open issues and pull requests | `create`, `edit`, `delete`; in `-i`, alt-n new · alt-e edit · alt-x delete, Enter lists the label's issues |

```sh
ghs settings rules show "Protect main"
ghs settings rules set 4898070 disabled
ghs settings secrets set NPM_TOKEN < token.txt      # or no value: asked for, hidden
ghs settings variables set REGION eu-west-1
ghs settings labels create triage -c fbca04 -d "Needs a first look"
ghs settings labels edit triage -n needs-triage
```

Leave the value out for a secret: it is then read from standard input or a hidden prompt, so it
stays out of your shell history, and ghs hands it to gh through standard input. Deleting a secret,
variable or label asks first, or takes `--yes` in scripts.

Changing settings and rulesets needs admin access; secrets, variables and labels need write access.
Rulesets inherited from an organisation, and classic branch protection (listed to admins only), are
shown but change on github.com. `evaluate` mode is for GitHub Enterprise organisations. Only the
repository's own secrets and variables are listed, not those of its environments or organisation.

## Layout

- `cli.sh` — the `ghs` entry point: routes `ghs <command>` to `bin/<command>.sh`, and holds the aliases
- `install.sh`, `uninstall.sh` — add and remove the `github-scripts` and `ghs` links
- `bin/` — one script per command: options, the `gh` query, and the columns of its table
  (`issue.sh`, `pull-request.sh` and `info.sh` print a detail view instead); `bin/settings/` holds
  the `ghs settings` subcommands
- `lib/common.sh` — option helpers, repository detection, the `jq` call, paging, glow, the gum
  spinner and the fzf browse
- `lib/browse.sh`, `lib/prompt.sh` — the fzf browse's previews and actions, and the questions they ask
- `lib/detail.sh`, `lib/detail.jq` — the layout, cards, sidebar and header box of the detail views
- `lib/install.sh` — link names and output helpers shared by the installer and uninstaller
- `lib/packages.sh` — platform detection, requirement checks and package installs for the installer
- `lib/table.jq` — table rendering and frames shared by every command; a cell is a list of
  `{text, style, link}` segments
- `flake.nix`, `nix/package.nix` — the Nix package, overlay and `nix develop` shell
