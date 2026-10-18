#!/usr/bin/env bash
set -euo pipefail

# Deixa o TRIM atravessar a criptografia (LUKS) até o SSD.
#
# O instalador do Omarchy monta o disco com LUKS e btrfs, mas não põe
# `:allow-discards` no `cryptdevice=` do Limine. Sem isso o dm-crypt engole todo
# TRIM: o btrfs até monta com discard=async, mas o aviso de "bloco apagado"
# nunca chega ao SSD, e ele passa a tratar como ocupado tudo que já foi escrito
# um dia. O sintoma é gravação longa lenta e load alto em build pesado. A
# correção é a do PR omacom/omarchy#5332 (ainda aberto em 17/10/2026).
#
# Medido aqui em 17/10/2026 (WD_BLACK SN850X 2 TB, 76% cheio, dados aleatórios
# com O_DIRECT), antes e depois de ligar e rodar um fstrim (475 GiB avisados):
#
#   primeira gravação de 4 GB    418 MB/s  ->  1,0 GB/s
#   24 GB seguidos               681 MB/s  ->  1,5 GB/s
#
# Checa antes de mexer: se o Omarchy já tiver corrigido no instalador, o
# mapper do root já anuncia discard e o módulo só confirma e sai.
#
# O que ele faz quando falta:
#   1. acrescenta :allow-discards no cryptdevice= de /etc/default/limine e roda
#      limine-update. Isso vale a partir do próximo boot e não pede senha.
#   2. com terminal, liga na hora (`cryptsetup --persistent refresh`), o que
#      pede a senha do disco, a mesma da tela de boot; remonta o / com
#      discard=async e roda um fstrim inicial.
#
# Botão:
#   EZOMAR_LUKS_TRIM=false   não mexe

say() { echo "[ezomar][luks-trim] $*"; }

if [ "${EZOMAR_LUKS_TRIM:-true}" = false ]; then
  say "Desligado por EZOMAR_LUKS_TRIM."
  exit 0
fi

src="$(findmnt -no SOURCE / | sed 's/\[.*//')"
case "$src" in
  /dev/mapper/*) ;;
  *) say "O / não está em LUKS ($src). Nada a fazer."; exit 0 ;;
esac
name="${src#/dev/mapper/}"

# Disco por baixo sem TRIM (HD, disco virtual): não há o que repassar.
# (lsblk -s anda para baixo: mapper, partição, disco; a última linha é o disco.)
disk="$(lsblk -snro NAME,TYPE "$src" | awk '$2=="disk"{d=$1} END{print d}')"
if [ -z "$disk" ] || [ "$(lsblk -dno DISC-MAX "/dev/$disk" | tr -d ' ')" = 0B ]; then
  say "O disco físico não aceita TRIM. Nada a fazer."
  exit 0
fi

conf=/etc/default/limine
live="$(lsblk -dno DISC-MAX "$src" | tr -d ' ')"
boot=no
grep -q "cryptdevice=[^ ]*:${name}:[^ ]*allow-discards" "$conf" 2>/dev/null && boot=yes

if [ "$live" != 0B ] && [ "$boot" = yes ]; then
  say "TRIM já atravessa o LUKS ($name, DISC-MAX $live) e o boot já tem allow-discards."
  exit 0
fi

if [ "$boot" = no ]; then
  if ! grep -q "cryptdevice=[^ ]*:${name}\b" "$conf" 2>/dev/null; then
    say "Não achei cryptdevice=...:$name em $conf. Instalação diferente da do Omarchy; não mexo." >&2
    exit 1
  fi
  sudo cp "$conf" "$conf.bak-trim"
  sudo sed -i "s/\(cryptdevice=[^ :]*:${name}\)\([ \"]\)/\1:allow-discards\2/" "$conf"
  sudo limine-update
  say "Boot: allow-discards no cryptdevice= (backup em $conf.bak-trim)."
fi

if [ "$live" = 0B ]; then
  if [ ! -t 0 ]; then
    say "Vale a partir do próximo boot. Para ligar já, rode este módulo num terminal."
    exit 0
  fi
  say "Ligando agora: o cryptsetup vai pedir a senha do disco (a mesma do boot)."
  sudo cryptsetup --allow-discards --persistent refresh "$name"
  sudo mount -o remount,discard=async /
  sudo fstrim -v /
fi

say "Pronto: $(lsblk -dno DISC-MAX "$src" | tr -d ' ') de DISC-MAX no $name."
