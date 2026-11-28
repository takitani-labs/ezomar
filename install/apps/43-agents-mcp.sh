#!/usr/bin/env bash
set -euo pipefail

# chrome-devtools nos outros agentes, além do Claude (que o 42 já cobre).
#
# A regra global de navegador (~/.config/agents/AGENTS.md, ~/.claude/browser-cdp.md)
# manda todo agente usar o Chrome do dia a dia pelo CDP, nunca Playwright. Sem o
# MCP registrado o agente não tem como obedecer: ou para e avisa, ou cai no
# Playwright mesmo. Então o servidor entra em cada CLI que tem MCP, com o mesmo
# comando do 42 (--autoConnect liga no Chrome já aberto e logado).
#
# Cada CLI guarda o registro num lugar e num formato próprios, e todas têm um
# `mcp add` que escreve no lugar certo. Aqui só conferimos antes se já existe,
# para o módulo poder rodar de novo sem duplicar nada. CLI ausente é pulada.
#
# Fora daqui, por falta de comando de MCP: Muse e o Kimi Code CLI.

say() { echo "[ezomar][agents-mcp] $*"; }

NAME=chrome-devtools
SERVER=(npx -y chrome-devtools-mcp@latest --autoConnect)

if ! command -v npx >/dev/null 2>&1; then
  say "npx ausente; o servidor não roda sem ele. Pulando."
  exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }

# Codex: uma vez por conta, cada uma com seu CODEX_HOME.
if have codex; then
  for home in "$HOME"/.codex-profiles/*/; do
    home="${home%/}"
    [ -f "$home/config.toml" ] || continue
    name="$(basename "$home")"
    if grep -q "^\[mcp_servers\.$NAME\]" "$home/config.toml"; then
      say "codex ($name): já registrado."
    else
      CODEX_HOME="$home" codex mcp add "$NAME" -- "${SERVER[@]}" >/dev/null
      say "codex ($name): registrado."
    fi
  done
fi

# Gemini: escopo de usuário; o padrão do `add` é o projeto.
if have gemini; then
  if jq -e --arg n "$NAME" '.mcpServers[$n]' "$HOME/.gemini/settings.json" >/dev/null 2>&1; then
    say "gemini: já registrado."
  else
    gemini mcp add -s user "$NAME" "${SERVER[@]}" >/dev/null
    say "gemini: registrado."
  fi
fi

# Antigravity (agy): grava em ~/.gemini/config/mcp_config.json; -- garante que
# -y e --autoConnect cheguem ao npx em vez de serem lidos como flags do `add`.
if have agy; then
  if jq -e --arg n "$NAME" '.mcpServers[$n]' "$HOME/.gemini/config/mcp_config.json" >/dev/null 2>&1; then
    say "antigravity: já registrado."
  else
    agy mcp add "$NAME" -- "${SERVER[@]}" >/dev/null
    say "antigravity: registrado."
  fi
fi

# Grok: o `add` também atualiza, mas o -- é obrigatório para o -y chegar ao npx.
if have grok; then
  if grok mcp list 2>/dev/null | grep -q "$NAME"; then
    say "grok: já registrado."
  else
    grok mcp add "$NAME" -- "${SERVER[@]}" >/dev/null
    say "grok: registrado."
  fi
fi

if have pi; then
  if jq -e --arg n "$NAME" '.mcpServers[$n]' "$HOME/.pi/agent/mcp.json" >/dev/null 2>&1; then
    say "pi: já registrado."
  else
    pi mcp add "$NAME" -- "${SERVER[@]}" >/dev/null
    say "pi: registrado."
  fi
fi

if have copilot; then
  if jq -e --arg n "$NAME" '.mcpServers[$n]' "$HOME/.copilot/mcp-config.json" >/dev/null 2>&1; then
    say "copilot: já registrado."
  else
    copilot mcp add "$NAME" -- "${SERVER[@]}" >/dev/null
    say "copilot: registrado."
  fi
fi

# opencode: --global, senão grava no projeto do diretório atual.
if have opencode; then
  if grep -qs "\"$NAME\"" "$HOME"/.config/opencode/opencode.json "$HOME"/.config/opencode/opencode.jsonc; then
    say "opencode: já registrado."
  else
    (cd "$HOME" && opencode mcp add --global "$NAME" -- "${SERVER[@]}" >/dev/null)
    say "opencode: registrado."
  fi
fi
