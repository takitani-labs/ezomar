#!/usr/bin/env bash
set -euo pipefail

# Usage meter for the AI subscriptions, from akitaonrails/ai-usagebar upstream.
#
# The primary machine showed this in a KDE plasmoid fed by a fork of this very
# project. Measured before porting: the fork had zero commits of its own, and
# every customization lived in the aggregator script (restored by chezmoi) and in
# config.toml. So there is nothing to port; upstream ships the Omarchy front-end
# (a Quattro plugin) and a waybar module, and reads the same config.toml.
#
# What stays personal and does NOT come from here: ~/.config/ai-usagebar/config.toml
# carries API keys (Kimi, Grok) and belongs in the dotfiles repo, encrypted.
# Module 62 still writes the two per-account Codex configs it always did.

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

install_bin() {
  if command -v omarchy >/dev/null 2>&1 && omarchy pkg aur add ai-usagebar-bin; then return 0; fi
  local helper
  for helper in yay paru; do
    if command -v "$helper" >/dev/null 2>&1 && "$helper" -S --needed --noconfirm ai-usagebar-bin; then return 0; fi
  done
  if command -v cargo >/dev/null 2>&1 && cargo install ai-usagebar; then return 0; fi
  return 1
}

if command -v ai-usagebar >/dev/null 2>&1; then
  echo "[ezomar][ai-usagebar] Já instalado: $(ai-usagebar --version 2>/dev/null | head -1)"
else
  echo "[ezomar][ai-usagebar] Instalando (AUR ai-usagebar-bin, ou cargo)..."
  if ! install_bin; then
    echo "[ezomar][ai-usagebar] Não consegui instalar. Opções manuais:" >&2
    echo "  omarchy pkg aur add ai-usagebar-bin   |   yay -S ai-usagebar-bin   |   cargo install ai-usagebar" >&2
    exit 1
  fi
fi

if command -v omarchy >/dev/null 2>&1; then
  # Rodando por ssh (que e como o ensaio em VM roda, e como uma maquina headless
  # rodaria) o ambiente do Omarchy nao esta carregado, e o plugin add termina em
  # "OMARCHY_PATH is not set" depois de ja ter clonado o plugin.
  export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
  # Idempotencia: reexecutar o modulo nao pode virar aviso. O `plugin add` recusa
  # um id ja usado e sai com erro, o que e correto da parte dele e ruidoso da
  # nossa, entao a checagem vem antes.
  PLUGIN_DIR="$HOME/.config/omarchy/plugins/akitaonrails.ai-usagebar"
  if [ -d "$PLUGIN_DIR" ]; then
    echo "[ezomar][ai-usagebar] Plugin do Omarchy já adicionado. Para atualizar: omarchy plugin update akitaonrails.ai-usagebar"
  # --yes porque o omarchy-plugin-add exige confirmacao interativa (plugin roda
  # codigo sem sandbox dentro do omarchy-shell) e aqui nao ha ninguem para
  # confirmar. A decisao de confiar neste repo ja foi tomada ao portar o modulo.
  elif omarchy plugin add https://github.com/akitaonrails/ai-usagebar.git --enable --yes; then
    echo "[ezomar][ai-usagebar] Plugin do Omarchy habilitado (clique abre o painel, s = configurações)."
  else
    echo "[ezomar][ai-usagebar] Aviso: o plugin do Omarchy não entrou; tente à mão:" >&2
    echo "  omarchy plugin add https://github.com/akitaonrails/ai-usagebar.git --enable --yes" >&2
  fi
else
  echo "[ezomar][ai-usagebar] Sem o CLI 'omarchy': em waybar puro, use o módulo custom da documentação upstream."
fi

CFG="$HOME/.config/ai-usagebar/config.toml"
if [ -f "$CFG" ]; then
  echo "[ezomar][ai-usagebar] config.toml presente."
else
  echo "[ezomar][ai-usagebar] $CFG ausente. Ele carrega chaves e é seu: versione encriptado no repo de dotfiles."
fi
