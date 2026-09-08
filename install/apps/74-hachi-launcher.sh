#!/usr/bin/env bash
set -euo pipefail

# Atalho para abrir o hachi sempre compilado do código atual.
#
# O binário compilado envelhece sem avisar, e rodar uma versão velha custa caro:
# você depura um comportamento que já consertou. O lançador deixa o cargo
# decidir o que refazer, então quando nada mudou ele abre na hora.
#
# Instala o comando `hachi-dev` e uma entrada de menu que o chama, para o app
# aparecer no launcher do Omarchy como qualquer outro.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/hachi-launcher"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
REPO="${HACHI_REPO:-$HOME/work/repos/takitani-labs/hachi}"

say() { echo "[ezomar][hachi] $*"; }

for f in hachi-dev hachi-dev.desktop; do
  [ -f "$TPL/$f" ] || { say "Template ausente: $TPL/$f" >&2; exit 1; }
done

if [ ! -d "$REPO" ]; then
  say "Repositório do hachi não está em $REPO; instalando o lançador mesmo assim."
  say "Ele avisa na tela se o caminho não existir na hora de abrir."
fi

install -D -m 0755 "$TPL/hachi-dev" "$BIN_DIR/hachi-dev"
install -D -m 0644 "$TPL/hachi-dev.desktop" "$APPS_DIR/hachi-dev.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true

say "Instalado: $BIN_DIR/hachi-dev e entrada de menu."
say "Para um atalho de teclado, acrescente ao ~/.config/hypr/bindings.lua:"
say '  o.bind("SUPER + SHIFT + H", "Hachi (compila e abre)", "hachi-dev")'
