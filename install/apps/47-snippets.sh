#!/usr/bin/env bash
set -euo pipefail

# Expansão de texto sem nada lendo o teclado.
#
# Super+; abre a lista no menu do Omarchy e o wtype digita o escolhido. A
# alternativa seria um expansor inline (espanso, AutoKey), mas para detectar que
# você digitou uma abreviação ele precisa ler TODA tecla, em TODA janela,
# inclusive senha. Numa máquina com ~/.ssh, .pgpass e sessão do 1Password isso
# custa caro, e o pacote do espanso no AUR ainda concede `cap_dac_override` ao
# binário, que ignora permissão de arquivo. A troca aqui é consciente: chamar o
# menu em vez de ser vigiado.
#
# Isto substitui o esquema antigo do ~/.XCompose, que inseria nome e email pela
# tecla Compose e dependia do Caps Lock deixar de ser Caps Lock.
#
# A lista fica no chezmoi (tem email pessoal); aqui só o programa e o menu.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/snippets/ezomar-snippets"
BIN="$HOME/.local/bin/ezomar-snippets"
SNIPPETS="$HOME/.config/ezomar/snippets.tsv"

say() { echo "[ezomar][snippets] $*"; }

[ -f "$TPL" ] || { say "Template ausente: $TPL" >&2; exit 1; }
install -D -m 0755 "$TPL" "$BIN"
say "Instalado: $BIN"

command -v wtype >/dev/null 2>&1 \
  || say "wtype não encontrado; sem ele o menu abre mas não digita nada."

if [ ! -f "$SNIPPETS" ]; then
  say "Sem $SNIPPETS (ele vem do chezmoi). Nada a sincronizar ainda."
  exit 0
fi

"$BIN" sync
say "Atalho: Super+; (definido no bindings.lua do chezmoi)"
