#!/usr/bin/env bash
set -euo pipefail

# Instala o comando que monta o home do kage aqui.
#
# O kage guarda os espelhos de backup (`mirror-fedora`, o home cru da máquina
# antiga, e `mirror-takidesk`, o espelho contínuo desta). Depois do format ele
# foi a fonte de quase tudo que não estava em repositório nem no tarball, e a
# consulta é sempre a mesma: montar, procurar, desmontar. Sem isso a linha do
# sshfs é reescrita de cabeça a cada vez, e as opções que importam (reconnect,
# idmap, somente leitura) são justamente as que ficam de fora com pressa.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/kage-mirror"
BIN_DIR="$HOME/.local/bin"

say() { echo "[ezomar][kage] $*"; }

[ -f "$TPL/kage-mirror" ] || { say "Template ausente: $TPL/kage-mirror" >&2; exit 1; }

install -D -m 0755 "$TPL/kage-mirror" "$BIN_DIR/kage-mirror"
say "Instalado: $BIN_DIR/kage-mirror"

if ! command -v sshfs >/dev/null 2>&1; then
  say "Falta o sshfs. Instale com: sudo pacman -S --needed sshfs"
fi

if ! grep -qiE '^host .*\bkage\b' "$HOME/.ssh/config" 2>/dev/null; then
  say "Sem entrada 'kage' no ~/.ssh/config; o comando vai depender de DNS."
fi
