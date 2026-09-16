#!/usr/bin/env bash
set -euo pipefail

# Expansão de texto sem nada lendo o teclado.
#
# Super+; abre um submapa e a próxima letra cola imediatamente. O menu do
# Omarchy continua em Super+Shift+; e `ezomar-snippets pick` oferece um seletor
# opcional pelo fuzzel. Nenhum deles vigia o teclado como faria um expansor
# inline (espanso, AutoKey), inclusive enquanto uma senha é digitada.
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
install -C -D -m 0755 "$TPL" "$BIN"
say "Instalado: $BIN"

command -v wtype >/dev/null 2>&1 \
  || say "wtype not found; snippets can be listed but not typed."

if [ ! -f "$SNIPPETS" ]; then
  say "Sem $SNIPPETS (ele vem do chezmoi). Nada a sincronizar ainda."
  exit 0
fi

"$BIN" sync
