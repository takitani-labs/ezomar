#!/usr/bin/env bash
set -euo pipefail

# Instala o aviso de /tmp cheio.
#
# Duas vezes o /tmp encheu aqui e o sintoma apareceu longe da causa: um backup
# truncado no meio da compressão, e um terminal que parou de devolver saída.
# Nos dois casos o tempo foi gasto investigando o sintoma.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/tmp-guard"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

say() { echo "[ezomar][tmp-guard] $*"; }

for f in ezomar-tmp-guard ezomar-tmp-guard.service ezomar-tmp-guard.timer; do
  [ -f "$TPL/$f" ] || { say "Template ausente: $TPL/$f" >&2; exit 1; }
done

install -D -m 0755 "$TPL/ezomar-tmp-guard" "$BIN_DIR/ezomar-tmp-guard"
install -D -m 0644 "$TPL/ezomar-tmp-guard.service" "$UNIT_DIR/ezomar-tmp-guard.service"
install -D -m 0644 "$TPL/ezomar-tmp-guard.timer" "$UNIT_DIR/ezomar-tmp-guard.timer"
systemctl --user daemon-reload
systemctl --user enable --now ezomar-tmp-guard.timer >/dev/null 2>&1 || true
say "Avisa quando o disco passar de ${EZOMAR_DISK_WARN:-85}%, dizendo quem ocupa. Log: ~/.local/state/ezomar/tmp-guard.log"
