#!/usr/bin/env bash
set -euo pipefail

# Make zsh the login shell.
#
# Installing zsh is not enough: Omarchy leaves the user on bash, so the 591-line
# .zshrc chezmoi delivers never loads and none of the vault helpers (bws, ops,
# bw-exec) are defined. The machine looks configured and behaves like it is not.

ZSH_BIN="$(command -v zsh || true)"
if [ -z "$ZSH_BIN" ]; then
  echo "[ezomar][shell] zsh não encontrado. O módulo 00-packages deveria ter instalado." >&2
  exit 1
fi

CURRENT="$(getent passwd "$USER" | cut -d: -f7)"
if [ "$CURRENT" = "$ZSH_BIN" ]; then
  echo "[ezomar][shell] Já é $ZSH_BIN. Nada a fazer."
  exit 0
fi

grep -qxF "$ZSH_BIN" /etc/shells || echo "$ZSH_BIN" | sudo tee -a /etc/shells >/dev/null

echo "[ezomar][shell] Trocando shell de $CURRENT para $ZSH_BIN"
sudo chsh -s "$ZSH_BIN" "$USER"
echo "[ezomar][shell] Vale a partir do próximo login."
