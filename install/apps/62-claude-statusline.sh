#!/usr/bin/env bash
set -euo pipefail

# A linha de status que diz qual assinatura está em uso.
#
# Cada perfil do Claude aponta seu statusLine para este script, que pergunta ao
# ai-usagebar quanto resta da janela e imprime "Max 20x · S 2% (3h 28m) · W 0%
# (2h 08m) [team-max]". Sem ele a linha some e não se sabe em que conta se está
# trabalhando, o que com sete assinaturas é justamente a informação que importa.
#
# Ele vivia só em ~/.local/bin, que o backup-ai não leva (é código, não estado),
# e não era repo git, então o restore-repos também não o trazia. Numa máquina
# nova simplesmente não existia, e o sintoma era a linha sumir sem erro nenhum.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/claude-statusline"
BIN="$HOME/.local/bin/claude-usagebar-statusline"

say() { echo "[ezomar][statusline] $*"; }

[ -f "$TPL/claude-usagebar-statusline" ] || { say "Template ausente." >&2; exit 1; }

install -D -m 0755 "$TPL/claude-usagebar-statusline" "$BIN"
say "Instalado: $BIN"

if ! command -v ai-usagebar >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/ai-usagebar" ]; then
  say "Aviso: ai-usagebar ausente; a linha vai dizer 'usage n/a'."
  say "O módulo 61 instala. Rode: bash install/apps/61-ai-usagebar.sh"
fi
