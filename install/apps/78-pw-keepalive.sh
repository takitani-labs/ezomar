#!/usr/bin/env bash
set -euo pipefail

# Daemon that keeps the 1Password (~/.op_session) and Bitwarden sessions alive
# by pinging them every ten minutes. The vault helpers in the dotfiles' .zshrc
# (ops, bws, bw-exec) start it and report on it, so without the binary they
# degrade to "Keepalive: não instalado" and sessions expire mid-day.
#
# Generic on purpose: the 1Password account comes from OP_ACCOUNT in
# ~/.ezdora-config when present, else from `op account list`. Needs op, bw, jq.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/../templates/pw-keepalive/pw-keepalive"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/pw-keepalive"

if [ ! -f "$SOURCE" ]; then
  echo "[ezomar][pw-keepalive] Template ausente: $SOURCE" >&2
  exit 1
fi

for c in op bw jq; do
  command -v "$c" >/dev/null 2>&1 \
    || echo "[ezomar][pw-keepalive] Aviso: '$c' não está no PATH; o daemon só pinga o que encontrar." >&2
done

if [ -x "$BIN" ] && cmp -s "$SOURCE" "$BIN"; then
  echo "[ezomar][pw-keepalive] Já instalado e atualizado. Pulando."
  exit 0
fi

mkdir -p "$BIN_DIR"
install -m 0755 "$SOURCE" "$BIN"
echo "[ezomar][pw-keepalive] Instalado em $BIN. O .zshrc chama 'pw-keepalive start' ao logar nos cofres."
