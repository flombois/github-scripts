# Requirement checks and package installs for install.sh; source it after lib/install.sh.
# Reads $assume_yes (true answers every question with yes).

package_manager=''

# Prints the platform and sets package_manager; fails on platforms other than macOS and Linux.
detect_platform() {
  case "$(uname -s)" in
    Darwin) detect_macos ;;
    Linux) detect_linux ;;
    *) fail "unsupported platform: $(uname -s); only macOS and Linux are supported" ;;
  esac
}

detect_macos() {
  ok "macOS $(sw_vers -productVersion) ($(uname -m))"
  if command -v brew >/dev/null; then
    package_manager=brew
    ok "package manager: Homebrew ($(command -v brew))"
  else
    note "Homebrew not found; missing packages can't be installed for you (see https://brew.sh)"
  fi
}

detect_linux() {
  local name="Linux"
  if [[ -r /etc/os-release ]]; then
    name="$(. /etc/os-release && echo "${PRETTY_NAME:-Linux}")"
  fi
  ok "$name ($(uname -m))"
  local candidate
  for candidate in apt-get dnf yum pacman zypper apk brew; do
    if command -v "$candidate" >/dev/null; then
      package_manager="${candidate%-get}"
      ok "package manager: $package_manager ($(command -v "$candidate"))"
      return
    fi
  done
  note "no supported package manager found; missing packages can't be installed for you"
}

# Checks that $1 is installed and at least version $2 (empty for any); offers to install it.
# $3 is where to get it by hand.
ensure_tool() {
  local tool="$1"
  local minimum="$2"
  local url="$3"
  local version
  version="$(tool_version "$tool")"
  if is_recent_enough "$version" "$minimum"; then
    ok "$tool $version ($(command -v "$tool"))"
    return
  fi
  if [[ -z "$version" ]]; then
    missing "$tool is not installed"
  else
    missing "$tool $version is installed, but $minimum or later is needed"
  fi
  install_tool "$tool" "$url"
  version="$(tool_version "$tool")"
  is_recent_enough "$version" "$minimum" \
    || fail "$tool ${version:-is still missing}${version:+ is still older than $minimum}; install it from $url"
  ok "$tool $version ($(command -v "$tool"))"
}

# Like ensure_tool for a tool ghs works without: never fails, and offers the install only
# through Homebrew, the one package manager with a recent enough glow. $4 says what it is for.
offer_tool() {
  local tool="$1"
  local minimum="$2"
  local url="$3"
  local purpose="$4"
  local version
  version="$(tool_version "$tool")"
  if is_recent_enough "$version" "$minimum"; then
    ok "$tool $version ($(command -v "$tool")), $purpose"
    return
  fi
  if [[ -z "$version" ]]; then
    note "$tool is not installed (optional, $purpose)"
  else
    note "$tool $version is installed, but $minimum or later is needed (optional, $purpose)"
  fi
  if [[ "$package_manager" != brew ]]; then
    echo "    Install $tool $minimum or later from $url"
    return
  fi
  local command
  command="$(install_command "$tool")"
  if ! confirm "    Install it with '$command'?"; then
    echo "    Skipped; install it later from $url"
    return
  fi
  echo "    Running: $command"
  if eval "$command" && hash -r && is_recent_enough "$(tool_version "$tool")" "$minimum"; then
    ok "$tool $(tool_version "$tool") ($(command -v "$tool"))"
  else
    note "could not install $tool $minimum or later; install it from $url"
  fi
}

# Prints the version of $1, like 1.7.1, or nothing when it is not installed.
tool_version() {
  command -v "$1" >/dev/null || return 0
  if [[ "$("$1" --version 2>/dev/null | head -n 1)" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

# True when version $1 is set and is at least major.minor $2 (empty for any).
is_recent_enough() {
  local version="$1"
  local minimum="$2"
  [[ -n "$version" ]] || return 1
  [[ -n "$minimum" ]] || return 0
  local major="${version%%.*}"
  local minor="${version#*.}"
  minor="${minor%%.*}"
  local minimum_major="${minimum%%.*}"
  local minimum_minor="${minimum#*.}"
  [[ "$major" -gt "$minimum_major" || ( "$major" -eq "$minimum_major" && "$minor" -ge "$minimum_minor" ) ]]
}

install_tool() {
  local tool="$1"
  local url="$2"
  local command
  command="$(install_command "$tool")" || fail "$tool is required; install it from $url"
  if ! confirm "    Install it with '$command'?"; then
    fail "$tool is required; run '$command' yourself, or rerun with --yes"
  fi
  echo "    Running: $command"
  eval "$command" || fail "could not install $tool with '$command'; install it from $url"
  hash -r
}

# Prints the shell command that installs or upgrades $1; fails without a package manager.
install_command() {
  local package
  package="$(package_name "$1")"
  local sudo='sudo '
  if [[ "$(id -u)" -eq 0 ]]; then sudo=''; fi
  case "$package_manager" in
    brew)
      if brew list --versions "$package" >/dev/null 2>&1; then
        echo "brew upgrade $package"
      else
        echo "brew install $package"
      fi
      ;;
    apt) echo "${sudo}apt-get update && ${sudo}apt-get install -y $package" ;;
    dnf | yum | zypper) echo "${sudo}$package_manager install -y $package" ;;
    pacman) echo "${sudo}pacman -S --noconfirm $package" ;;
    apk) echo "${sudo}apk add --upgrade $package" ;;
    *) return 1 ;;
  esac
}

# Prints the package that provides tool $1 for the detected package manager.
package_name() {
  case "$1:$package_manager" in
    gh:pacman | gh:apk) echo github-cli ;;
    *) echo "$1" ;;
  esac
}

# Asks a yes/no question on the terminal; no terminal counts as no.
confirm() {
  if [[ "$assume_yes" == true ]]; then
    return 0
  fi
  local answer=''
  { printf '%s [y/N] ' "$1" >/dev/tty && read -r answer </dev/tty; } 2>/dev/null || return 1
  [[ "$answer" == [Yy]* ]]
}

# Reports the gh login and offers to log in.
check_login() {
  local status
  if status="$(gh auth status 2>&1)"; then
    if [[ "$status" =~ account\ ([A-Za-z0-9-]+) ]]; then
      ok "gh is logged in as ${BASH_REMATCH[1]}"
    else
      ok "gh is logged in"
    fi
    return
  fi
  missing "gh is not logged in"
  if confirm "    Log in now with 'gh auth login'?" && gh auth login; then
    ok "gh is logged in"
  else
    note "run 'gh auth login' before using ghs"
  fi
}
