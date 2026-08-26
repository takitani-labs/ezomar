#!/usr/bin/env bash
set -euo pipefail

# The AI CLIs that ride on subscriptions, via npm:
#   @openai/codex          codex   (64 splits its accounts by CODEX_HOME)
#   @google/gemini-cli     gemini
#   @xai-official/grok     grok    (Grok Build on SuperGrok; npm instead of the
#                                  vendor install.sh, which sits behind Cloudflare)
#
# Module 40 installs the Codex *plugin* for Claude Code; this is the CLI itself.
# Claude Code is not here: Omarchy ships it through its native installer.
#
# Globals go to ~/.npm-global so no sudo is needed. The dotfiles' .zshrc already
# exports ~/.npm-global/bin; this module never edits rc files, because those are
# chezmoi's and an appended line would just be drift.

if ! command -v npm >/dev/null 2>&1; then
  echo "[ezomar][ai-cli] npm não encontrado. O módulo 00-packages deveria ter instalado." >&2
  exit 1
fi

NPM_PREFIX="$HOME/.npm-global"
if [ "$(npm config get prefix 2>/dev/null || true)" != "$NPM_PREFIX" ]; then
  mkdir -p "$NPM_PREFIX"
  npm config set prefix "$NPM_PREFIX"
  echo "[ezomar][ai-cli] npm prefix: $NPM_PREFIX"
fi
export PATH="$NPM_PREFIX/bin:$PATH"

PKGS=("@openai/codex" "@google/gemini-cli" "@xai-official/grok")
BINS=("codex" "gemini" "grok")

MISSING=()
for i in "${!PKGS[@]}"; do
  command -v "${BINS[$i]}" >/dev/null 2>&1 || MISSING+=("${PKGS[$i]}")
done

if [ ${#MISSING[@]} -eq 0 ]; then
  echo "[ezomar][ai-cli] codex, gemini e grok já instalados. Pulando."
  exit 0
fi

echo "[ezomar][ai-cli] Instalando: ${MISSING[*]}"
npm install -g "${MISSING[@]}"

echo "[ezomar][ai-cli] Concluído. Logins ficam para depois (exigem browser):"
echo "  codex login          (uma vez por CODEX_HOME, ver módulo 64)"
echo "  gemini               (OAuth no primeiro uso)"
echo "  grok login           (device code, conta SuperGrok)"
