#!/usr/bin/env bash
set -euo pipefail

# The pacman delta. Every module below that needs a package lists it here; no
# module shells out to pacman on its own.
#
#   zsh nodejs npm atuin unzip     measured on a clean Omarchy 3.8.4 (see README)
#   mosh                           shells that survive a bad link
#   jq                             pw-keepalive reads `op account list` with it
#   uv                             mrig setup builds its venv with it
#   libpulse espeak-ng zenity libnotify
#                                  meeting-rig: parec/pactl, self-test voice,
#                                  suggestion popup, notify-send
PKGS=(zsh nodejs npm atuin unzip mosh jq uv libpulse espeak-ng zenity libnotify)
MISSING=()
for p in "${PKGS[@]}"; do
  pacman -Qi "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if [ ${#MISSING[@]} -eq 0 ]; then
  echo "[ezomar][packages] Nada a instalar."
  exit 0
fi
echo "[ezomar][packages] Instalando: ${MISSING[*]}"

# Sincronizar os bancos e obrigatorio, e nao e detalhe: a instalacao do Omarchy
# e offline, ela consome os pacotes do proprio ISO e nunca baixa os bancos dos
# repositorios. Numa maquina recem-instalada /var/lib/pacman/sync so tem
# offline.db, e qualquer `pacman -S` morre com "target not found: zsh". Medido
# numa VM com Omarchy 4.0.1 zerado.
sudo pacman -Sy --noconfirm >/dev/null

if command -v omarchy >/dev/null 2>&1; then
  # No Omarchy, instalar sem -u e a convencao da casa, nao uma concessao: o
  # proprio `omarchy pkg add` e um `pacman -S --needed`, e um hook de
  # pre-transacao recusa `-Syu` direto ("Woah partner...") porque os upgrades
  # passam por `omarchy update`, que cuida de snapshot, keyring e migracoes.
  sudo pacman -S --needed --noconfirm "${MISSING[@]}"
  echo "[ezomar][packages] Para atualizar o resto do sistema, use: omarchy update"
else
  # Arch puro nao tem esse guarda-corpo, e ai sincronizar sem atualizar deixaria
  # a maquina num upgrade parcial, que e a forma classica de quebrar uma Arch.
  sudo pacman -Syu --needed --noconfirm "${MISSING[@]}"
fi
