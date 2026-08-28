#!/usr/bin/env bash
set -euo pipefail

# Apaga o disco da VM e a NVRAM, para reinstalar do zero.
#
# Existe porque o diretório vm/storage pertence ao root (quem o cria é o
# container) e um `rm -rf` no host pediria sudo, que numa sessão automatizada
# não existe. Apagar de dentro do container resolve sem privilégio nenhum no
# host. A NVRAM vai junto de propósito: ela guarda a entrada de boot do Limine
# da instalação anterior, e sobrando ela o firmware tenta bootar um sistema que
# não existe mais antes de cair no ISO.
#
#   bash vm/reset.sh          # apaga e deixa a VM parada
#   bash vm/reset.sh --up     # apaga e sobe de novo

VM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAME="${EZOMAR_VM_NAME:-ezomar-vm}"

say() { echo "[ezomar][reset] $*"; }

if docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; then
  say "Apagando disco e NVRAM de dentro do container..."
  docker exec "$NAME" sh -c 'rm -f /storage/data.img /storage/uefi.vars /storage/screen.ppm' || true
else
  say "Container parado; nada a apagar de dentro dele."
fi

cd "$VM_DIR"
COMPOSE=(-f docker-compose.yml)
[ -f "$VM_DIR/cidata.img" ] && COMPOSE+=(-f cidata.yml)
EZOMAR_VM_ISO="${EZOMAR_VM_ISO:-/dev/null}" docker compose "${COMPOSE[@]}" down >/dev/null 2>&1 || true
say "VM derrubada e disco apagado."

if [ "${1:-}" = "--up" ]; then
  exec bash "$VM_DIR/up.sh"
fi
say "Para subir de novo: bash vm/up.sh"
