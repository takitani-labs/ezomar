#!/usr/bin/env bash
set -euo pipefail

# Instala a checagem que responde se dá para hibernar AGORA.
#
# O `omarchy hibernation available` responde se a máquina SUPORTA hibernar, e
# isso não muda ao longo do dia. Numa máquina com muitos agentes abertos a
# pergunta que importa é a outra: com o que está carregado neste momento, a
# hibernação termina ou fica dez minutos na tela preta?

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/../../scripts/hibernate-check.sh"
BIN="$HOME/.local/bin/hibernate-check"

say() { echo "[ezomar][hibernate] $*"; }

[ -f "$SRC" ] || { say "script ausente: $SRC" >&2; exit 1; }
install -D -m 0755 "$SRC" "$BIN"
say "Instalado: $BIN"

if ! omarchy hibernation available >/dev/null 2>&1; then
  say "A máquina não está com hibernação configurada."
  say "Para configurar: omarchy hibernation setup"
fi
