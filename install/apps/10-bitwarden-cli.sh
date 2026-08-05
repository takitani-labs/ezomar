#!/usr/bin/env bash
set -euo pipefail

# Bitwarden CLI, installed to ~/.local/bin so it needs no root.
#
# It is not just another tool here: the age identity that decrypts the dotfiles
# lives in this vault, so module 20 cannot run without it. The AUR package
# (bitwarden-cli) builds from source and is slow and fragile on a fresh machine,
# so the official binary is used instead.

export PATH="$HOME/.local/bin:$PATH"

if command -v bw >/dev/null 2>&1; then
  echo "[ezomar][bitwarden-cli] Já instalado ($(bw --version 2>/dev/null | tail -1)). Pulando."
  exit 0
fi

mkdir -p "$HOME/.local/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[ezomar][bitwarden-cli] Baixando binário oficial..."
curl -fsSL -o "$TMP/bw.zip" "https://vault.bitwarden.com/download/?app=cli&platform=linux"

unzip -qo "$TMP/bw.zip" -d "$TMP"
install -m 0755 "$TMP/bw" "$HOME/.local/bin/bw"

echo "[ezomar][bitwarden-cli] Instalado: $("$HOME/.local/bin/bw" --version 2>/dev/null | tail -1)"
