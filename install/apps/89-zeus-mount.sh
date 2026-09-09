#!/usr/bin/env bash
set -euo pipefail

# Monta os shares do NAS (ZEUS) no login.
#
# Três dos cinco shares pedem login, e o gvfs só guarda senha quando alguém
# digita na janela dele. Um mount feito por script nunca passa por essa janela,
# então a senha fica no chaveiro e o `zeus-mount` a busca em tempo de execução.
# Sem isso o serviço subiria, abriria um prompt que ninguém responde, e travaria
# o login até o timeout.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/zeus-mount"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SERVER="${ZEUS_HOST:-192.168.1.3}"
USER_NAME="${ZEUS_USER:-admin}"

say() { echo "[ezomar][zeus] $*"; }

for f in zeus-mount ezomar-zeus-mount.service; do
  [ -f "$TPL/$f" ] || { say "Template ausente: $TPL/$f" >&2; exit 1; }
done

install -D -m 0755 "$TPL/zeus-mount" "$BIN_DIR/zeus-mount"
install -D -m 0644 "$TPL/ezomar-zeus-mount.service" "$UNIT_DIR/ezomar-zeus-mount.service"
systemctl --user daemon-reload

if ! command -v secret-tool >/dev/null 2>&1; then
  say "secret-tool ausente (pacote libsecret); sem ele a senha não sai do chaveiro."
elif ! secret-tool lookup server "$SERVER" protocol smb user "$USER_NAME" service zeus-mount >/dev/null 2>&1; then
  say "Senha do NAS não está no chaveiro. Grave uma vez com:"
  say "  secret-tool store --label='ZEUS SMB' \\"
  say "    server $SERVER protocol smb user $USER_NAME service zeus-mount"
  say "Sem ela, só os shares abertos montam."
fi

systemctl --user enable ezomar-zeus-mount.service >/dev/null 2>&1 || true
say "Instalado. Monta no login; na mão é: zeus-mount"
