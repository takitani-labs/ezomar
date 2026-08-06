#!/usr/bin/env bash
set -euo pipefail

# O herdr restaura cwd, agente e sessionId, mas não o CLAUDE_CONFIG_DIR de cada
# pane. Sem este helper, panes de perfis diferentes voltam todos no perfil
# padrão. O binário deriva sessionId -> perfil dos history.jsonl e alimenta o
# snippet zsh que o chezmoi já restaura.
#
# O módulo instala apenas o binário e gera o cache derivado; não toca no snippet
# nem nos diretórios de perfil pertencentes ao chezmoi.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/claude-profile-restore"
SOURCE="$TPL/claude-session-profile"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/claude-session-profile"
CACHE="${CLAUDE_SESSION_PROFILE_CACHE:-$HOME/.local/state/claude-session-profile.tsv}"
SNIPPET="$HOME/.config/zsh/claude-profile-restore.zsh"

if [ ! -f "$SOURCE" ]; then
  echo "[ezomar][claude-profile-restore] Template ausente: $SOURCE" >&2
  exit 1
fi

if [ -x "$BIN" ] && cmp -s "$SOURCE" "$BIN" && [ -f "$CACHE" ]; then
  echo "[ezomar][claude-profile-restore] Helper já instalado; atualizando o mapa de sessões."
  SKIP_INSTALL=true
else
  SKIP_INSTALL=false
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ezomar][claude-profile-restore] python3 não encontrado (o Omarchy normalmente traz). Pulando." >&2
  exit 0
fi

if [ ! -d "$HOME/.claude-profiles" ]; then
  echo "[ezomar][claude-profile-restore] Aviso: ~/.claude-profiles não existe; o mapa ficará vazio." >&2
fi
if [ ! -f "$SNIPPET" ]; then
  echo "[ezomar][claude-profile-restore] Aviso: $SNIPPET não foi restaurado pelo chezmoi." >&2
fi

mkdir -p "$BIN_DIR"
if [ "$SKIP_INSTALL" != true ]; then
  install -m 0755 "$SOURCE" "$BIN"
fi
echo "[ezomar][claude-profile-restore] Construindo o mapa de sessões..."
"$BIN" build
echo "[ezomar][claude-profile-restore] Helper instalado; vale para panes restaurados daqui em diante."
