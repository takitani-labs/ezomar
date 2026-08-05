#!/usr/bin/env bash
set -euo pipefail

# Hook for machine-owner modules that do not belong in a public repo.
#
# Runs anything executable in ~/.config/ezomar/apps/, in filename order. That
# directory is expected to come from the private dotfiles repo via chezmoi,
# which is why this module sits after 30: before chezmoi has run, the directory
# does not exist yet and this is simply a no-op.
#
# The split follows what each piece needs in order to work. The two values in
# config.sh are needed *before* chezmoi and therefore cannot live in the repo
# they unlock. Everything else personal is needed *after* it, so it rides along
# with the dotfiles like any other private config.

USER_APPS="${EZOMAR_USER_APPS:-$HOME/.config/ezomar/apps}"

if [ ! -d "$USER_APPS" ]; then
  echo "[ezomar][personal] Nenhum módulo pessoal em $USER_APPS. Pulando."
  exit 0
fi

shopt -s nullglob
SCRIPTS=("$USER_APPS"/*.sh)
shopt -u nullglob

if [ ${#SCRIPTS[@]} -eq 0 ]; then
  echo "[ezomar][personal] $USER_APPS está vazio. Pulando."
  exit 0
fi

FAILED=()
for s in "${SCRIPTS[@]}"; do
  name="$(basename "$s")"
  echo "[ezomar][personal] $name"
  bash "$s" || { echo "[ezomar][personal] $name FALHOU"; FAILED+=("$name"); }
done

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[ezomar][personal] Falharam: ${FAILED[*]}" >&2
  exit 1
fi
