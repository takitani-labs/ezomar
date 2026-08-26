#!/usr/bin/env bash
set -euo pipefail

# meeting-rig (mrig): live local transcription of calls with AI reply
# suggestions. Code lives in the tools repo (tools/meeting-rig); this links it
# into ~/.local/bin and runs its own setup (uv venv + whisper model).
#
# The runtime is already portable: parec/pactl talk to PipeWire's pulse compat,
# pw-play is PipeWire's own, zenity and notify-send are GTK and libnotify. Only
# the installer was Fedora (dnf), which is what this replaces. Packages are in
# 00-packages; this module fails loudly if any is missing instead of installing.
#
# What is NOT here: the hotkey. On KDE it was a custom shortcut; on Hyprland it is
# a bind in the dotfiles, e.g.  bind = SUPER, M, exec, ~/.local/bin/mrig suggest --notify
#
# Knob:
#   EZOMAR_SKIP_MRIG_SETUP=true   link only; skip the venv/model download

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

export PATH="$HOME/.local/bin:$PATH"

if ! DIR="$(ezomar_tools_dir)"; then
  echo "[ezomar][meeting-rig] EZOMAR_TOOLS_REPO não definido. Pulando."
  exit 0
fi
RIG="$DIR/tools/meeting-rig/mrig"
if [ ! -x "$RIG" ]; then
  echo "[ezomar][meeting-rig] $RIG não existe ou não é executável (o módulo 72 clonou?)." >&2
  exit 1
fi

MISSING=()
for c in parec pactl pw-play espeak-ng zenity notify-send uv; do
  command -v "$c" >/dev/null 2>&1 || MISSING+=("$c")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[ezomar][meeting-rig] Faltam no PATH: ${MISSING[*]}. Os pacotes estão em 00-packages (libpulse pipewire espeak-ng zenity libnotify uv)." >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin"
ln -sfn "$RIG" "$HOME/.local/bin/mrig"
echo "[ezomar][meeting-rig] ~/.local/bin/mrig -> $RIG"

if [ "${EZOMAR_SKIP_MRIG_SETUP:-false}" = "true" ]; then
  echo "[ezomar][meeting-rig] Setup pulado (EZOMAR_SKIP_MRIG_SETUP). Depois: mrig setup"
else
  echo "[ezomar][meeting-rig] Rodando mrig setup (venv + modelo whisper; demora na primeira vez)..."
  "$RIG" setup
fi

echo "[ezomar][meeting-rig] Concluído. Valide com: mrig test"
echo "[ezomar][meeting-rig] Hotkey no Hyprland (dotfiles): bind = SUPER, M, exec, ~/.local/bin/mrig suggest --notify"
