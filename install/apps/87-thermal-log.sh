#!/usr/bin/env bash
set -euo pipefail

# Registra a térmica do processador, que nada aqui registrava.
#
# A pergunta que motivou isto foi "estou torrando o processador?", e ela não
# tinha como ser respondida: sem sysstat, sem log de sensores, sem nada. Só dava
# para olhar o instante e opinar. Uma semana de amostras troca opinião por dado.
#
# Um minuto entre amostras, ~1440 linhas por dia, algo como 100 KB por mês.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/thermal-log"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

say() { echo "[ezomar][thermal] $*"; }

if ! command -v sensors >/dev/null 2>&1; then
  say "lm_sensors não instalado; sem ele não há o que amostrar." >&2
  exit 0
fi

install -D -m 0755 "$TPL/ezomar-thermal-log" "$BIN_DIR/ezomar-thermal-log"
install -D -m 0644 "$TPL/ezomar-thermal-log.service" "$UNIT_DIR/ezomar-thermal-log.service"
install -D -m 0644 "$TPL/ezomar-thermal-log.timer" "$UNIT_DIR/ezomar-thermal-log.timer"

systemctl --user daemon-reload
systemctl --user enable --now ezomar-thermal-log.timer >/dev/null 2>&1 || true

say "Amostrando a cada minuto. Resumo: ezomar-thermal-log report"
