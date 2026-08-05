#!/usr/bin/env bash
set -euo pipefail

# Restore the age identity that decrypts the dotfiles.
#
# This is the one step that cannot be reordered or skipped. Everything
# encrypted in the dotfiles repo (.bashrc, .zshrc.local, .ssh/config and the
# four Claude profile settings holding API tokens) is unreadable without it,
# and chezmoi does not fail loudly when it is missing: you get a machine that
# applied 400 files and is still broken.
#
# The key deliberately does not live in the dotfiles repo. It is the bootstrap
# secret, so it has to arrive out of band, from the vault.

export PATH="$HOME/.local/bin:$PATH"

KEY_FILE="$HOME/.config/age/keys.txt"
ITEM="${EZOMAR_AGE_ITEM:-Dotfiles age identity (chezmoi)}"
BW_PROFILE_DIR="${BITWARDENCLI_APPDATA_DIR:-$HOME/.bw-profiles/personal}"

if [ -s "$KEY_FILE" ] && grep -q "AGE-SECRET-KEY-1" "$KEY_FILE"; then
  echo "[ezomar][age] Chave já presente em $KEY_FILE. Pulando."
  exit 0
fi

command -v bw >/dev/null 2>&1 || { echo "[ezomar][age] bw não encontrado." >&2; exit 1; }

export BITWARDENCLI_APPDATA_DIR="$BW_PROFILE_DIR"

# Reuse an unlocked session if the shell helpers already created one.
SESSION_FILE="$HOME/.bw_session_personal"
if [ -z "${BW_SESSION:-}" ] && [ -s "$SESSION_FILE" ]; then
  BW_SESSION="$(<"$SESSION_FILE")"
  export BW_SESSION
fi

if [ "$(bw status 2>/dev/null | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')" != "unlocked" ]; then
  echo "[ezomar][age] Cofre bloqueado. Faça login/unlock e reexecute:"
  echo "                bw login          # se for a primeira vez nesta máquina"
  echo "                bws personal      # ou o helper do zshrc, que salva a sessão"
  exit 1
fi

echo "[ezomar][age] Buscando \"$ITEM\"..."
NOTES="$(bw get notes "$ITEM" 2>/dev/null || true)"

if ! printf '%s' "$NOTES" | grep -q "AGE-SECRET-KEY-1"; then
  echo "[ezomar][age] Item não encontrado ou sem identidade age nas notas." >&2
  exit 1
fi

install -d -m 0700 "$(dirname "$KEY_FILE")"
umask 077
printf '%s\n' "$NOTES" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

echo "[ezomar][age] Instalada em $KEY_FILE (0600)."
