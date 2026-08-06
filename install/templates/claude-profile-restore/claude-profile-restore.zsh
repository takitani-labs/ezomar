# Devolve ao Claude Code o perfil correto quando o herdr restaura um pane. O
# herdr preserva o sessionId, mas não CLAUDE_CONFIG_DIR; o helper encontra o
# perfil de nascimento da sessão sem deixar a variável vazar para o shell.
claude() {
  local cfg="${CLAUDE_CONFIG_DIR:-}"

  if [[ -z "$cfg" ]]; then
    local uuid="" i
    for (( i = 1; i <= $#; i++ )); do
      case "${@[i]}" in
        --resume)   uuid="${@[i+1]}" ;;
        --resume=*) uuid="${${@[i]}#--resume=}" ;;
      esac
    done
    if [[ -n "$uuid" ]]; then
      local profile
      profile="$(claude-session-profile "$uuid" 2>/dev/null)"
      [[ -n "$profile" && -d "$HOME/.claude-profiles/$profile" ]] \
        && cfg="$HOME/.claude-profiles/$profile"
    fi
  fi

  if [[ -n "$cfg" ]]; then
    CLAUDE_CONFIG_DIR="$cfg" command claude "$@"
  else
    command claude "$@"
  fi
}
