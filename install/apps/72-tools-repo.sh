#!/usr/bin/env bash
set -euo pipefail

# Clone (or fast-forward) the owner's private tools repo. Modules 74 and 76
# install from it. Optional: with EZOMAR_TOOLS_REPO unset this is a no-op and
# those modules skip.
#
# The default clone path is ~/work/repos/<org>/<repo>, derived from the URL. That
# is not cosmetic: the dotfiles' .zshrc and the preflight unit reference tools by
# that path, so keeping it makes them work without edits.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

if [ -z "${EZOMAR_TOOLS_REPO:-}" ]; then
  echo "[ezomar][tools] EZOMAR_TOOLS_REPO não definido; os módulos 74 e 76 vão pular."
  echo "[ezomar][tools] Para usar: export EZOMAR_TOOLS_REPO='git@github.com:usuario/tools.git' (ou em $EZOMAR_CONFIG_FILE)"
  exit 0
fi

DIR="$(ezomar_tools_dir)"

if [ -d "$DIR/.git" ]; then
  echo "[ezomar][tools] Clone existe em $DIR; atualizando (ff-only)..."
  git -C "$DIR" pull --ff-only \
    || echo "[ezomar][tools] Aviso: pull não foi fast-forward; deixando como está." >&2
else
  echo "[ezomar][tools] Clonando $EZOMAR_TOOLS_REPO em $DIR..."
  mkdir -p "$(dirname "$DIR")"
  git clone "$EZOMAR_TOOLS_REPO" "$DIR"
fi
echo "[ezomar][tools] Pronto: $DIR"
