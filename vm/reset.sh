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
STORAGE="${EZOMAR_VM_STORAGE:-$VM_DIR/storage}"

say() { echo "[ezomar][reset] $*"; }

# Três caminhos, porque o dono dos arquivos depende de como a VM foi usada: o
# container os cria como root, mas quem passou pelo vm/qemu-direct.sh já teve de
# tomar posse deles. Antes isto só sabia o primeiro caminho e, com o container
# parado, dizia "nada a apagar" sem apagar nada.
TARGETS=(data.img uefi.vars screen.ppm qemu-direct.pid qemu-direct.qmp)
if docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; then
  say "Apagando disco e NVRAM de dentro do container..."
  docker exec "$NAME" sh -c "cd /storage && rm -f ${TARGETS[*]}" || true
elif [ -w "$STORAGE" ]; then
  # Testar o DIRETÓRIO, não os arquivos: unlink exige escrita no diretório que
  # contém, e o vm/storage é criado pelo container como root. Um arquivo seu
  # dentro de um diretório do root continua impossível de apagar, e o teste
  # errado fazia o reset dizer que apagou sem ter apagado nada.
  say "Apagando disco e NVRAM direto..."
  ( cd "$STORAGE" && rm -f "${TARGETS[@]}" ) || true
else
  say "Os arquivos são do root e o container está parado; apagando por um container descartável..."
  docker run --rm -v "$STORAGE:/s" alpine sh -c "cd /s && rm -f ${TARGETS[*]}" >/dev/null 2>&1 \
    || say "Não consegui apagar. Rode à mão: sudo rm -f $STORAGE/{data.img,uefi.vars}" >&2
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
