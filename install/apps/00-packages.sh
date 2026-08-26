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
sudo pacman -S --needed --noconfirm "${MISSING[@]}"
