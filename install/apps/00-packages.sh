#!/usr/bin/env bash
set -euo pipefail

# The delta between what Omarchy ships and what the dotfiles expect.
#
# Omarchy already provides claude, gh, op, mise, git, docker and python, so this
# list is deliberately short. Each entry below was found by something breaking
# on a fresh machine, not by guesswork:
#
#   zsh     the login shell the dotfiles are written for; without it .zshrc,
#           and therefore bws/ops/bw-exec, simply do not exist
#   nodejs  ~/.claude/settings.local.json hooks call `node .../hook.mjs`, and
#           they are guarded by `[ ! -f ... ]`, so a missing node makes them
#           fail silently, which is the worst way to break
#   atuin   shell history; .zshrc degrades to a warning without it
#   unzip   needed by several installers further down

PKGS=(zsh nodejs npm atuin unzip)

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
