# Questions asked on the terminal, for the fzf browse actions; source it after common.sh.
# fzf owns stdin and stdout while it runs, so everything goes through /dev/tty.

# fzf hands the terminal over without clearing it.
clear_screen() {
  printf '\033[H\033[2J' >/dev/tty
}

# Asks a yes/no question, with gum when it is there.
confirm() {
  if command -v gum >/dev/null; then
    gum confirm "$1" </dev/tty >/dev/tty
  else
    local answer
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r answer </dev/tty
    [[ "$answer" == [yY]* ]]
  fi
}

# Leaves the outcome on screen until a key is pressed.
pause() {
  printf '\nPress any key to go back to the list.' >/dev/tty
  read -rsn1 </dev/tty || true
}

# Usage: ask question current
# Prints the answer, starting from the current value; fails when cancelled. Without gum, Enter keeps
# the current value and a single - clears it.
ask() {
  if command -v gum >/dev/null; then
    gum input --header "$1" --value "$2" --width 0 </dev/tty 2>/dev/tty
  else
    local answer
    printf '%s\n' "$1" >/dev/tty
    [[ -z "$2" ]] || printf 'Now: %s (Enter keeps it, - clears it)\n' "$2" >/dev/tty
    read -r answer </dev/tty || return
    if [[ -z "$answer" ]]; then echo "$2"; elif [[ "$answer" == - ]]; then echo; else echo "$answer"; fi
  fi
}

# Prints a value typed without echo, such as a secret.
ask_hidden() {
  if command -v gum >/dev/null; then
    gum input --header "$1" --password --width 0 </dev/tty 2>/dev/tty
  else
    local answer
    printf '%s ' "$1" >/dev/tty
    read -rs answer </dev/tty || return
    printf '\n' >/dev/tty
    echo "$answer"
  fi
}

# Usage: choose question current choices…
# Prints the picked choice, with gum or fzf; fails when cancelled.
choose() {
  local question="$1" current="$2"
  shift 2
  if command -v gum >/dev/null; then
    gum choose --header "$question" --selected "$current" "$@" </dev/tty 2>/dev/tty
  else
    printf '%s\n' "$@" | fzf --height 12 --layout reverse --header "$question" \
      --bind "load:pos($(choice_position "$current" "$@"))" 2>/dev/tty
  fi
}

choice_position() {
  local current="$1" position=1 choice
  shift
  for choice in "$@"; do
    [[ "$choice" == "$current" ]] && { echo "$position"; return; }
    position=$((position + 1))
  done
  echo 1
}

# Usage: act description command…
# Runs an action that changes something on GitHub once confirmed, then pauses on its outcome.
act() {
  local description="$1"
  shift
  clear_screen
  confirm "$description?" || return 0
  "$@" || true
  pause
}

# Usage: interactive command…
# Runs a command that asks its own questions (gh's merge prompt, an editor), then pauses.
interactive() {
  clear_screen
  "$@" </dev/tty >/dev/tty || true
  pause
}
