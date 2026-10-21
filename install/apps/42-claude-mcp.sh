#!/usr/bin/env bash
set -euo pipefail

# Servidores MCP do Claude Code, em todos os perfis.
#
# chrome-devtools (github.com/ChromeDevTools/chrome-devtools-mcp) deixa o agente
# dirigir o Chrome do dia a dia, já logado em tudo, pelo modo --autoConnect
# (Chrome 144+). Do lado do Chrome é preciso ligar uma vez a depuração remota em
# chrome://inspect/#remote-debugging; isso fica no perfil do Chrome, não aqui.
#
# Diferente do 40-claude-plugins, este entra também nos perfis que falam com
# proxy (kimi, codex, gemini...): o MCP roda local e não depende do modelo.
# O registro mora no .claude.json de cada perfil, que é estado e não vai para o
# chezmoi, então é refeito aqui.

say() { echo "[ezomar][claude-mcp] $*"; }

if ! command -v claude >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
  say "claude ou npx ausente; pulando."
  exit 0
fi

profiles() {
  local d
  [ -d "$HOME/.claude" ] && printf '%s\n' "$HOME/.claude"
  for d in "$HOME"/.claude-profiles/*/; do
    [ -f "${d%/}/settings.json" ] && printf '%s\n' "${d%/}"
  done
}

while read -r profile; do
  name="$(basename "$profile")"
  if CLAUDE_CONFIG_DIR="$profile" claude mcp get chrome-devtools >/dev/null 2>&1; then
    say "$name: chrome-devtools já registrado."
    continue
  fi
  CLAUDE_CONFIG_DIR="$profile" claude mcp add -s user chrome-devtools -- \
    npx -y chrome-devtools-mcp@latest --autoConnect >/dev/null
  say "$name: chrome-devtools registrado."
done < <(profiles)
