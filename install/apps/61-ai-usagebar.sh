#!/usr/bin/env bash
set -euo pipefail

# Keep ai-usagebar only as a collector backend for providers Omarchy does not
# support. Its bar widget was removed because it duplicated Omarchy's native
# agents panel; installing the binary alone lets module 65 fill those gaps in
# the one panel without adding another widget or shell plugin.

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

say() { echo "[ezomar][ai-usagebar] $*"; }

install_bin() {
  local helper

  if command -v omarchy >/dev/null 2>&1 \
    && omarchy pkg aur add ai-usagebar-bin; then
    return 0
  fi
  for helper in yay paru; do
    if command -v "$helper" >/dev/null 2>&1 \
      && "$helper" -S --needed --noconfirm ai-usagebar-bin; then
      return 0
    fi
  done
  if command -v cargo >/dev/null 2>&1 && cargo install ai-usagebar; then
    return 0
  fi
  return 1
}

if command -v ai-usagebar >/dev/null 2>&1; then
  say "Já instalado: $(ai-usagebar --version 2>/dev/null | head -1)"
  exit 0
fi

say "Instalando o backend de coleta (AUR ai-usagebar-bin, ou cargo)..."
if ! install_bin; then
  say "Não consegui instalar. Opções manuais:" >&2
  echo "  omarchy pkg aur add ai-usagebar-bin   |   yay -S ai-usagebar-bin   |   cargo install ai-usagebar" >&2
  exit 1
fi

say "Backend instalado; o painel nativo será atualizado pelo módulo 65."
