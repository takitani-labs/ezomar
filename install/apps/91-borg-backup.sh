#!/usr/bin/env bash
set -euo pipefail

# Backup diário do home com borgmatic, para dois repositórios: a storage box do
# Hetzner (offsite) e o NAS ZEUS (cópia local).
#
# Instala o config, o leitor de passphrase e o timer. Não cria repositório e não
# roda backup: `borg init` grava chave nova, e fazer isso dentro de um instalador
# que roda de novo a cada máquina é como se perde a chave da vez anterior.
#
# O que este passo NÃO faz, e precisa de root uma vez:
#   o mount cifs do ZEUS em /mnt/zeus-backup (veja docs/backup.md).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/borg-backup"
BIN_DIR="$HOME/.local/bin"
CFG_DIR="$HOME/.config/borgmatic"
UNIT_DIR="$HOME/.config/systemd/user"

say() { echo "[ezomar][borg] $*"; }

for f in borg-passphrase config.yaml ezomar-borgmatic.service ezomar-borgmatic.timer; do
  [ -f "$TPL/$f" ] || { say "Template ausente: $TPL/$f" >&2; exit 1; }
done

if ! command -v borgmatic >/dev/null 2>&1; then
  say "borgmatic não instalado. Rode: sudo pacman -S --needed borg borgmatic cifs-utils"
  exit 0
fi

install -D -m 0755 "$TPL/borg-passphrase" "$BIN_DIR/borg-passphrase"

# O config não é sobrescrito: depois da primeira instalação ele é do Andre, e as
# exclusões vão mudando conforme o que aparece no home.
if [ -f "$CFG_DIR/config.yaml" ]; then
  say "Config já existe em $CFG_DIR/config.yaml; mantido."
else
  install -D -m 0600 "$TPL/config.yaml" "$CFG_DIR/config.yaml"
  say "Config instalado em $CFG_DIR/config.yaml."
fi

install -D -m 0644 "$TPL/ezomar-borgmatic.service" "$UNIT_DIR/ezomar-borgmatic.service"
install -D -m 0644 "$TPL/ezomar-borgmatic.timer" "$UNIT_DIR/ezomar-borgmatic.timer"
systemctl --user daemon-reload

if "$BIN_DIR/borg-passphrase" >/dev/null 2>&1; then
  say "Passphrase legível do 1Password."
else
  say "Passphrase NÃO está legível. O backup vai falhar até 'ops' rodar." >&2
fi

if ! mountpoint -q /mnt/zeus-backup 2>/dev/null; then
  say "/mnt/zeus-backup não está montado; o repositório do ZEUS vai falhar."
  say "Ele é um mount cifs de kernel, feito uma vez com root. Veja docs/backup.md."
fi

systemctl --user enable --now ezomar-borgmatic.timer >/dev/null 2>&1 || true
say "Timer diário ligado. Para rodar agora: systemctl --user start ezomar-borgmatic.service"
