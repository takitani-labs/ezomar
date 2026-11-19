#!/usr/bin/env bash
set -euo pipefail

# Fone Bluetooth que fica sem som por um tempo é desconectado, para desligar
# sozinho. O porquê está no próprio bt-idle-off; aqui só instala o script e o
# serviço do usuário.
#
# Botão:
#   EZOMAR_BT_IDLE_MIN   minutos sem som antes de desconectar (padrão 20),
#                        gravado no serviço por um drop-in.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/bt-idle-off"
USER_UNITS="$HOME/.config/systemd/user"

say() { echo "[ezomar][bt-idle-off] $*"; }

[ -d "$TPL" ] || { say "Template ausente: $TPL" >&2; exit 1; }
install -D -m 0755 "$TPL/bt-idle-off" "$HOME/.local/bin/bt-idle-off"
install -D -m 0644 "$TPL/ezomar-bt-idle-off.service" "$USER_UNITS/ezomar-bt-idle-off.service"

if [ -n "${EZOMAR_BT_IDLE_MIN:-}" ]; then
  mkdir -p "$USER_UNITS/ezomar-bt-idle-off.service.d"
  printf '[Service]\nEnvironment=EZOMAR_BT_IDLE_MIN=%s\n' "$EZOMAR_BT_IDLE_MIN" \
    >"$USER_UNITS/ezomar-bt-idle-off.service.d/idle.conf"
fi

systemctl --user daemon-reload
systemctl --user enable ezomar-bt-idle-off.service >/dev/null 2>&1
systemctl --user restart ezomar-bt-idle-off.service
say "Ativo: $(systemctl --user is-active ezomar-bt-idle-off.service), desconecta após ${EZOMAR_BT_IDLE_MIN:-20} min sem som."
