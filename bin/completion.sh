#!/usr/bin/env bash
# Prints the shell completion script for bash or zsh; load it with eval "$(ghs completion zsh)".
set -euo pipefail
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: completion.sh bash|zsh

Prints the tab completion script for ghs and github-scripts: commands,
aliases, each command's options, and values for -s, --format, -w (workflow
names), -b/-B (branches) and -R (the GitHub remotes of the current clone).

Load it from your shell profile:
  bash  (~/.bashrc)   eval "$(ghs completion bash)"
  zsh   (~/.zshrc)    eval "$(ghs completion zsh)"
EOF
}

[[ $# -eq 1 ]] || { usage >&2; fail "a shell is needed: bash or zsh"; }
case "$1" in
  -h | --help) usage; exit 0 ;;
  bash) ;;
  # zsh runs the bash completion through bashcompinit; compinit must have run first.
  zsh) echo 'autoload -U +X compinit && { (( ${+_comps} )) || compinit; }; autoload -U +X bashcompinit && bashcompinit' ;;
  *) usage >&2; fail "unknown shell: $1 (expected bash or zsh)" ;;
esac

cat <<'EOF'
_ghs() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}" ghs="${COMP_WORDS[0]}"
  local IFS=$'\n'
  COMPREPLY=()
  if [[ "$COMP_CWORD" -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$("$ghs" __commands)" -- "$cur"))
    return
  fi
  # ghs settings [set <setting> <value> | rules | secrets | variables | labels] [verb]
  local sub=""
  if [[ "${COMP_WORDS[1]}" == settings && "$cur" != -* ]]; then
    if [[ "$COMP_CWORD" -ge 3 ]]; then sub="${COMP_WORDS[2]}"; fi
    case "$COMP_CWORD:$sub" in
      2:) COMPREPLY=($(compgen -W $'set\nrules\nsecrets\nvariables\nlabels' -- "$cur")); return ;;
      3:set) COMPREPLY=($(compgen -W "$("$ghs" settings __keys)" -- "$cur")); return ;;
      4:set) COMPREPLY=($(compgen -W "$("$ghs" settings __values "${COMP_WORDS[3]}")" -- "$cur")); return ;;
      3:rules) COMPREPLY=($(compgen -W $'show\nset' -- "$cur")); return ;;
      3:secrets | 3:variables) COMPREPLY=($(compgen -W $'set\ndelete' -- "$cur")); return ;;
      3:labels) COMPREPLY=($(compgen -W $'create\nedit\ndelete' -- "$cur")); return ;;
      5:rules) COMPREPLY=($(compgen -W $'active\nevaluate\ndisabled' -- "$cur")); return ;;
    esac
  fi
  case "$prev" in
    -s | --state) COMPREPLY=($(compgen -W $'open\nclosed\nmerged\nall' -- "$cur")) ;;
    --format) COMPREPLY=($(compgen -W $'table\njson\ncsv' -- "$cur")) ;;
    -w | --workflow) COMPREPLY=($(compgen -W "$(gh workflow list --json name --jq '.[].name' 2>/dev/null)" -- "$cur")) ;;
    -b | --branch | -B | --base)
      COMPREPLY=($(compgen -W "$(git for-each-ref --format='%(refname:lstrip=2)' refs/heads refs/remotes 2>/dev/null \
        | sed 's#^[^/]*/##' | sort -u)" -- "$cur")) ;;
    -R | --repo)
      COMPREPLY=($(compgen -W "$(git remote -v 2>/dev/null \
        | sed -nE 's#.*github\.com[:/]([^/ ]+/[^/ ]+)( .*)?$#\1#p' | sed 's#\.git$##' | sort -u)" -- "$cur")) ;;
    *)
      if [[ "$cur" == -* ]]; then
        if [[ "${COMP_WORDS[1]}" == settings && "$COMP_CWORD" -ge 3 ]]; then sub="${COMP_WORDS[2]}"; fi
        COMPREPLY=($(compgen -W "$("$ghs" __options "${COMP_WORDS[1]}" "$sub")" -- "$cur"))
      fi
      ;;
  esac
}
complete -F _ghs ghs github-scripts
EOF
