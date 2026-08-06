# Perfis de conta do Codex CLI. O chezmoi instala este snippet; o módulo 64
# prepara os diretórios e symlinks que ele consome.
_codex_profile() {
  local profile="$1"
  shift
  local profile_dir="$HOME/.codex-profiles/$profile"
  local shared="$HOME/.codex-profiles/shared"

  if [[ ! -d "$profile_dir" ]]; then
    echo "Codex profile '$profile' não encontrado em $profile_dir" >&2
    echo "Existentes: ${$(ls -1 "$HOME/.codex-profiles" 2>/dev/null | grep -v '^shared$' | tr '\n' ' ')}" >&2
    return 1
  fi

  local item
  for item in config.toml hooks.json plugins memories; do
    [[ -e "$profile_dir/$item" || ! -e "$shared/$item" ]] || ln -s "$shared/$item" "$profile_dir/$item"
  done

  echo "🔹 Codex profile: $profile"
  CODEX_HOME="$profile_dir" codex "$@"
}

alias cdxe='_codex_profile exato'
alias cdxp='_codex_profile personal'
