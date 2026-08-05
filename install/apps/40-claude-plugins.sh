#!/usr/bin/env bash
set -euo pipefail

# Claude Code plugins.
#
# These are not versioned in the dotfiles repo on purpose: they are third-party
# installs carrying binaries, so they are rebuilt from the marketplaces instead.
# Everything else about Claude (skills, the eight profiles, CLAUDE.md, hooks)
# comes from chezmoi and is deliberately not touched here.

export PATH="$HOME/.local/bin:$PATH"

if ! command -v claude >/dev/null 2>&1; then
  echo "[ezomar][claude-plugins] claude não encontrado (o Omarchy normalmente traz). Pulando." >&2
  exit 0
fi

MARKETPLACES=(
  anthropics/claude-plugins-official
  anthropics/claude-code
  openai/codex-plugin-cc
  microsoft/Webwright
)

PLUGINS=(
  codex@openai-codex
  webwright@webwright
  feature-dev@claude-plugins-official
  frontend-design@claude-plugins-official
  playwright@claude-plugins-official
  csharp-lsp@claude-plugins-official
  typescript-lsp@claude-plugins-official
  pyright-lsp@claude-plugins-official
  gopls-lsp@claude-plugins-official
  rust-analyzer-lsp@claude-plugins-official
)

for m in "${MARKETPLACES[@]}"; do
  printf '[ezomar][claude-plugins] marketplace %-38s ' "$m"
  claude plugin marketplace add "$m" >/dev/null 2>&1 && echo "ok" || echo "já existe"
done

INSTALLED="$(claude plugin list 2>/dev/null || true)"
for p in "${PLUGINS[@]}"; do
  printf '[ezomar][claude-plugins] %-42s ' "$p"
  if printf '%s' "$INSTALLED" | grep -qF "$p"; then
    printf 'instalado, '
  else
    claude plugin install "$p" >/dev/null 2>&1 || { echo "FALHA ao instalar"; continue; }
    printf 'instalado agora, '
  fi
  # Enable unconditionally, not just after a fresh install. The plugin files
  # living on disk and the plugin being enabled are separate facts, recorded in
  # settings.json, which module 30 restores from the repo. Without this, a
  # machine that already had the files ends up with them installed and switched
  # off, and `claude plugin list` still says "installed", so nothing looks wrong.
  claude plugin enable "$p" >/dev/null 2>&1 && echo "habilitado" || echo "habilitado (ou já estava)"
done
