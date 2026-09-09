#!/usr/bin/env bash
set -euo pipefail

# Monta o share Takitani do ZEUS por cifs de kernel, para o borg escrever nele.
#
# O mount gvfs que já existe em ~/mnt/zeus não serve para repositório borg: é
# FUSE sobre SMB, lento para milhares de arquivos pequenos, e o lock do borg em
# filesystem de rede via FUSE não é confiável. cifs de kernel resolve os dois.
#
# A senha vem por stdin, não por argumento nem por arquivo que eu tenha escrito:
#
#   secret-tool lookup server 192.168.1.3 protocol smb user admin service zeus-mount \
#     | sudo bash setup-zeus-cifs.sh

SHARE="//192.168.1.3/Takitani"
MOUNT="/mnt/zeus-backup"
CREDS="/etc/samba/credentials/zeus"
USER_NAME="admin"
UID_N="$(id -u opik)"
GID_N="$(id -g opik)"

PASS="$(cat)"
[ -n "$PASS" ] || { echo "sem senha no stdin" >&2; exit 1; }

install -d -m 0700 /etc/samba/credentials
umask 077
printf 'username=%s\npassword=%s\n' "$USER_NAME" "$PASS" > "$CREDS"
chmod 0600 "$CREDS"

mkdir -p "$MOUNT"

# nofail + x-systemd.automount: o NAS desligado não pode segurar o boot, e o
# mount só acontece quando alguém encosta no diretório.
LINE="$SHARE $MOUNT cifs credentials=$CREDS,uid=$UID_N,gid=$GID_N,file_mode=0640,dir_mode=0750,vers=3.0,nofail,_netdev,x-systemd.automount,x-systemd.idle-timeout=600 0 0"

if grep -q "^$SHARE " /etc/fstab; then
  sed -i "s|^$SHARE .*|$LINE|" /etc/fstab
  echo "fstab: linha atualizada"
else
  printf '\n# ZEUS (NAS) para o repositorio borg\n%s\n' "$LINE" >> /etc/fstab
  echo "fstab: linha adicionada"
fi

systemctl daemon-reload
mount "$MOUNT" 2>/dev/null || systemctl start "$(systemd-escape -p --suffix=mount "$MOUNT")"
mountpoint -q "$MOUNT" && echo "montado em $MOUNT" || { echo "nao montou" >&2; exit 1; }

install -d -o opik -g opik -m 0755 "$MOUNT/backups/borg"
echo "pronto: $MOUNT/backups/borg"
