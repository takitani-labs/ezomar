#!/usr/bin/env bash
set -euo pipefail

# Instala o que o ~/.config/mise/config.toml declara.
#
# O arquivo vem do chezmoi (módulo 30) e lista dez ferramentas: opencode, bun,
# node, uv, go, dotnet, gh, claude, codex e o grok via npm. O que faltava era
# alguém rodar `mise install` depois que ele chega, então numa máquina limpa
# nenhuma delas aparecia e só se descobria quando o comando não existia.
#
# Este módulo vem DEPOIS do 58 de propósito: o mise e o npm declaram codex e
# grok os dois, e quem ganha é quem estiver primeiro no PATH. Deixar o mise por
# último faz o shim dele valer, que é o que a máquina de origem usava.

command -v mise >/dev/null 2>&1 || {
  echo "[ezomar][mise] mise não encontrado. O Omarchy costuma trazer; instale antes." >&2
  exit 1
}

CONFIG="$HOME/.config/mise/config.toml"
if [ ! -f "$CONFIG" ]; then
  echo "[ezomar][mise] Sem $CONFIG: o chezmoi (módulo 30) ainda não entregou os dotfiles."
  echo "[ezomar][mise] Rode este módulo de novo depois do chezmoi:"
  echo "[ezomar][mise]   bash install/apps/59-mise-tools.sh"
  exit 0
fi

DECLARED="$(grep -cE '^\s*"?[a-z@:./-]+"?\s*=' "$CONFIG" | head -1 || echo 0)"
echo "[ezomar][mise] $CONFIG declara $DECLARED ferramenta(s). Instalando o que faltar..."

# --yes porque um install limpo precisa aceitar cada backend novo, e travar
# esperando confirmação no meio do dia do format não ajuda ninguém.
mise install --yes

echo "[ezomar][mise] Instalado. O que responde agora:"
for bin in opencode codex grok bun node uv go gh; do
  path="$(command -v "$bin" 2>/dev/null || true)"
  printf '[ezomar][mise]   %-9s %s\n' "$bin" "${path:-AUSENTE}"
done

# O kimi não é gerenciado pelo mise nem por npm: é um binário próprio em
# ~/.kimi-code/bin que se atualiza sozinho por CDN. Ele viaja no tarball do
# backup-ai (a lista inclui .kimi-code), então numa restauração ele volta
# inteiro. Numa instalação SEM backup, precisa ser instalado à mão.
if ! command -v kimi >/dev/null 2>&1 && [ ! -x "$HOME/.kimi-code/bin/kimi" ]; then
  echo "[ezomar][mise] Aviso: kimi ausente. Ele não vem daqui nem do npm;"
  echo "[ezomar][mise] chega pelo restore (~/.kimi-code) ou pelo instalador oficial."
fi
