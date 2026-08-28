#!/usr/bin/env bash
set -euo pipefail

# Conversa com o monitor do QEMU dentro do container: tira print da tela e manda
# teclas. Serve para acompanhar o ensaio sem depender do browser, e para provar
# depois em que passo o instalador estava.
#
#   bash vm/console.sh shot [saida.png]   # print da tela
#   bash vm/console.sh key ret            # manda uma tecla (ret, down, tab...)
#   bash vm/console.sh key a b c          # várias em sequência
#   bash vm/console.sh type "texto"       # digita um texto
#   bash vm/console.sh cmd "info status"  # comando cru do monitor
#
# A imagem sai do QEMU em PPM e é convertida para PNG aqui, porque o monitor não
# sabe gerar PNG e nenhum visualizador decente abre PPM.

VM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAME="${EZOMAR_VM_NAME:-ezomar-vm}"
MONITOR=/run/shm/monitor.sock

die() { echo "[ezomar][console] $*" >&2; exit 1; }
docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true \
  || die "container $NAME não está rodando. Suba com: bash vm/up.sh"

# O monitor é um socket unix dentro do container e não há socat na imagem, então
# a conversa vai por python, que existe lá.
monitor() {
  docker exec -i "$NAME" python3 -c '
import socket, sys, time
cmds = sys.argv[1:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("'"$MONITOR"'")
s.settimeout(3)
time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
out = []
for c in cmds:
    s.sendall(c.encode() + b"\n")
    time.sleep(0.35)
    try: out.append(s.recv(65536).decode(errors="replace"))
    except Exception: pass
# O monitor ecoa cada caractere digitado; só interessa o que veio depois disso.
print("".join(out).replace("\r", ""))
' "$@"
}

case "${1:-}" in
  shot)
    OUT="${2:-$VM_DIR/screen.png}"
    monitor "screendump /storage/screen.ppm" >/dev/null
    sleep 1
    sudo chmod a+r "$VM_DIR/storage/screen.ppm" 2>/dev/null || true
    python3 -c "
from PIL import Image
im = Image.open('$VM_DIR/storage/screen.ppm')
im.save('$OUT')
print('[ezomar][console] $OUT', im.size)
"
    ;;
  key)
    shift
    [ $# -gt 0 ] || die "uso: vm/console.sh key <tecla> [tecla...]"
    for k in "$@"; do monitor "sendkey $k" >/dev/null; sleep 0.2; done
    echo "[ezomar][console] teclas enviadas: $*"
    ;;
  type)
    shift
    [ $# -gt 0 ] || die "uso: vm/console.sh type <texto>"
    # sendkey aceita uma tecla por vez, então o texto vira uma sequência delas.
    text="$*"
    for (( i=0; i<${#text}; i++ )); do
      c="${text:$i:1}"
      case "$c" in
        [a-z0-9]) k="$c" ;;
        [A-Z])    k="shift-$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]')" ;;
        ' ')      k="spc" ;;
        '.')      k="dot" ;;
        '-')      k="minus" ;;
        '/')      k="slash" ;;
        '_')      k="shift-minus" ;;
        *) echo "[ezomar][console] caractere não mapeado, pulando: '$c'" >&2; continue ;;
      esac
      monitor "sendkey $k" >/dev/null
      sleep 0.12
    done
    echo "[ezomar][console] digitado: $text"
    ;;
  cmd)
    shift
    [ $# -gt 0 ] || die "uso: vm/console.sh cmd '<comando do monitor>'"
    monitor "$@"
    ;;
  *)
    die "uso: vm/console.sh {shot|key|type|cmd}"
    ;;
esac
