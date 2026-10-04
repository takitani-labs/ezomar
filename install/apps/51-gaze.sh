#!/usr/bin/env bash
set -euo pipefail

# Instala o Gaze (github.com/GunduLabs/gaze): reconhecimento facial no
# desbloqueio de tela do Omarchy e no sudo.
#
# Quem instala é o instalador oficial, e não este módulo, porque ele já sabe o
# caminho certo no Arch com Omarchy: gaze-bin, gaze-gui-bin e gaze-omarchy-bin
# pelo AUR, `gaze-omarchy enable` para o lock, e o pam_gaze.so no
# /etc/pam.d/sudo. Cuidado com o nome: o pacote `gaze` do AUR é outro projeto
# (wtetsu/gaze), e só os -bin acima são este.
#
# O sudo foi escolha consciente, em 03/10/2026, sabendo o custo. A câmera daqui
# é uma C920e, RGB e sem infravermelho, então o anti-spoofing é só software. E
# os agentes rodam em bypassPermissions: com o rosto na frente da câmera, um
# `sudo` de agente passa sem senha. O pam_gaze entra como `sufficient`, então
# rosto não reconhecido cai na senha de sempre. Para tirar o sudo e manter o
# lock, apague a linha pam_gaze do /etc/pam.d/sudo: o instalador grava um
# opt-out e não a recoloca.
#
# O instalador é baixado para um arquivo e executado, em vez de `curl | sh`,
# para o que roda ser o que está no disco. Precisa de terminal e sudo.
#
# Botão:
#   EZOMAR_GAZE=false   não instala

say() { echo "[ezomar][gaze] $*"; }

if [ "${EZOMAR_GAZE:-true}" = false ]; then
  say "Desligado por EZOMAR_GAZE."
  exit 0
fi

if ! ls /dev/video* >/dev/null 2>&1; then
  say "Nenhuma câmera em /dev/video*; pulando."
  exit 0
fi

if pacman -Qq gaze-bin gaze-omarchy-bin >/dev/null 2>&1; then
  say "Gaze já instalado ($(pacman -Q gaze-bin | awk '{print $2}'))."
  if grep -q pam_gaze /etc/pam.d/sudo 2>/dev/null; then say "sudo: pam_gaze ativo."; else say "sudo: sem pam_gaze."; fi
  exit 0
fi

if [ ! -t 0 ]; then
  say "Precisa de terminal interativo (sudo e AUR). Rode este módulo num terminal." >&2
  exit 1
fi

# O instalador só põe o gaze-omarchy-bin (lock) e o gaze-gui-bin quando enxerga
# uma sessão do Hyprland, e decide isso pela HYPRLAND_INSTANCE_SIGNATURE. Num
# pane do herdr ela não existe: na primeira instalação daqui (03/10/2026) ele
# instalou só o gaze-bin e o sudo, sem desbloqueio de tela.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && [ -d "/run/user/$(id -u)/hypr" ]; then
  HYPRLAND_INSTANCE_SIGNATURE="$(find "/run/user/$(id -u)/hypr" -mindepth 1 -maxdepth 1 \
    -printf '%T@ %f\n' | sort -rn | awk 'NR==1{print $2}')"
  export HYPRLAND_INSTANCE_SIGNATURE
fi

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl -fsSL https://gaze.gundulabs.com/install.sh -o "$tmp/install.sh"
sh "$tmp/install.sh"

say "Falta cadastrar o rosto, na frente da câmera: gaze add-face \"$USER\""
