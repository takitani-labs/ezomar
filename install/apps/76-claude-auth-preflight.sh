#!/usr/bin/env bash
set -euo pipefail

# Refuse to let herdr restore a fleet over logged-out Claude profiles.
#
# Access tokens refresh silently; refresh tokens lapse after a few days, and a
# lapsed one can only be fixed by a browser round-trip. Discovering that after
# herdr has restored 57 panes means 57 panes that die on their first command.
# scripts/claude-auth-preflight.sh in the tools repo reports which profiles will
# need a /login, raises a notification at login, and gates herdr() in the
# dotfiles' .zshrc. Its sibling claude-login.sh routes each OAuth URL into the
# right browser profile.
#
# The script installs its own user unit (--install), pointing at wherever it
# lives. It refuses when `claude` is not on PATH, on purpose: without the CLI it
# cannot tell a logged-out profile from a broken environment.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

export PATH="$HOME/.local/bin:$PATH"

if ! DIR="$(ezomar_tools_dir)"; then
  echo "[ezomar][claude-auth] EZOMAR_TOOLS_REPO não definido. Pulando."
  exit 0
fi
PRE="$DIR/scripts/claude-auth-preflight.sh"
if [ ! -x "$PRE" ]; then
  echo "[ezomar][claude-auth] $PRE não existe ou não é executável (o módulo 72 clonou?)." >&2
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "[ezomar][claude-auth] 'claude' não está no PATH; o preflight recusa instalar sem ele (Omarchy normalmente traz)." >&2
  exit 1
fi

"$PRE" --install

echo "[ezomar][claude-auth] O gate do herdr() no .zshrc dos dotfiles espera o script em:"
echo "  $PRE"
[ -x "$DIR/scripts/claude-login.sh" ] \
  && echo "[ezomar][claude-auth] Login guiado por perfil: $DIR/scripts/claude-login.sh"
