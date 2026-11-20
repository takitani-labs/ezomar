#!/usr/bin/env bash
set -euo pipefail

# Shares do NAS (ZEUS) como montagens CIFS do kernel, com automount.
#
# Até 20/11/2026 eles eram montados pelo gvfs no login. O gvfs larga a montagem
# sem aviso quando o QNAP derruba a sessão ociosa e não tenta de novo: os cinco
# shares sumiam juntos (três vezes em três semanas, sem nada no log), enquanto o
# /mnt/zeus-backup, CIFS de kernel com automount desde o começo, nunca caiu.
# Agora os cinco seguem o mesmo molde dele: uma linha no /etc/fstab com
# x-systemd.automount, que monta no primeiro acesso, solta após 10 min parado e
# monta de novo no acesso seguinte, sem depender de sessão nem de chaveiro.
#
# A credencial é a conta admin do NAS, a mesma que o gvfs usava, porque três dos
# cinco shares pedem login. A senha sai do chaveiro do usuário e vai por stdin
# para um arquivo só de root (/etc/samba/credentials/zeus-shares, modo 600);
# não passa por argv nem fica no repositório. Grave-a uma vez com:
#   secret-tool store --label='ZEUS SMB' \
#     server 192.168.1.3 protocol smb user admin service zeus-mount
#
# Os links em ~/mnt/zeus continuam no mesmo lugar e passam a apontar para
# /mnt/zeus/<share>. Rodar de novo é seguro: o bloco do fstab fica entre
# marcadores e é trocado inteiro.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/zeus-mount"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SERVER="${ZEUS_HOST:-192.168.1.3}"
USER_NAME="${ZEUS_USER:-admin}"
MNT_DIR=/mnt/zeus
CRED=/etc/samba/credentials/zeus-shares
SHARES=(Multimedia Exato ExatoDigital Takitani Public)
BEGIN='# >>> ezomar: shares do ZEUS >>>'
END='# <<< ezomar: shares do ZEUS <<<'

say() { echo "[ezomar][zeus] $*"; }

[ -f "$TPL/zeus-mount" ] || { say "Template ausente: $TPL/zeus-mount" >&2; exit 1; }
install -D -m 0755 "$TPL/zeus-mount" "$BIN_DIR/zeus-mount"

command -v mount.cifs >/dev/null 2>&1 || {
  say "cifs-utils ausente; rode: sudo pacman -S --needed cifs-utils" >&2
  exit 1
}

# O serviço de login do gvfs não tem mais o que montar.
if [ -f "$UNIT_DIR/ezomar-zeus-mount.service" ]; then
  systemctl --user disable --now ezomar-zeus-mount.service >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/ezomar-zeus-mount.service"
  systemctl --user daemon-reload
fi
for s in "${SHARES[@]}"; do
  gio mount -u "smb://$SERVER/$s" >/dev/null 2>&1 || true
done

if ! sudo test -s "$CRED"; then
  pass="$(secret-tool lookup server "$SERVER" protocol smb user "$USER_NAME" service zeus-mount 2>/dev/null || true)"
  if [ -z "$pass" ]; then
    say "Senha do NAS não está no chaveiro; sem ela só o Public monta. Grave com:" >&2
    say "  secret-tool store --label='ZEUS SMB' server $SERVER protocol smb user $USER_NAME service zeus-mount" >&2
    exit 1
  fi
  printf 'username=%s\npassword=%s\n' "$USER_NAME" "$pass" \
    | sudo install -D -m 600 -o root -g root /dev/stdin "$CRED"
  unset pass
  say "Credencial gravada em $CRED (root, 600)."
fi

block="$BEGIN"$'\n'
for s in "${SHARES[@]}"; do
  name="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  sudo mkdir -p "$MNT_DIR/$name"
  block+="//$SERVER/$s $MNT_DIR/$name cifs credentials=$CRED,uid=$(id -u),gid=$(id -g),file_mode=0644,dir_mode=0755,vers=3.0,iocharset=utf8,nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=20 0 0"$'\n'
done
block+="$END"

tmp="$(mktemp)"
awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' /etc/fstab >"$tmp"
printf '%s\n' "$block" >>"$tmp"
if ! cmp -s "$tmp" /etc/fstab; then
  sudo cp /etc/fstab /etc/fstab.bak-ezomar-zeus
  sudo install -m 644 -o root -g root "$tmp" /etc/fstab
  say "fstab atualizado (backup em /etc/fstab.bak-ezomar-zeus)."
fi
rm -f "$tmp"

sudo systemctl daemon-reload
for s in "${SHARES[@]}"; do
  name="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  sudo systemctl start "$(systemd-escape -p --suffix=automount "$MNT_DIR/$name")"
done

"$BIN_DIR/zeus-mount"
