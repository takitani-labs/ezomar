#!/usr/bin/env bash
set -euo pipefail

# Sobe a MESMA VM sem o container, para ter GPU de verdade no guest.
#
# Por que existe: o qemux/qemu recusa aceleração quando o host tem CPU AMD
# (`isAmdCpu` no /run/display.sh dele), então num Ryzen o guest cai em llvmpipe.
# O Omarchy roda Hyprland como compositor até na tela de login, e por software
# ele fica lento E redesenha errado. Aqui o QEMU é chamado direto, com
# virtio-vga-gl e egl-headless sobre o render node do host, que é o caminho que
# dá GL ao guest.
#
# O disco é o mesmo de vm/storage, então a instalação feita pelo container
# continua valendo; muda o motor e o cliente (SPICE em vez de VNC).
#
#   bash vm/qemu-direct.sh          # sobe e imprime como conectar
#   bash vm/qemu-direct.sh --stop   # desliga
#
# Botões: EZOMAR_VM_RAM, EZOMAR_VM_CPUS, EZOMAR_VM_SSH_PORT (2223),
#         EZOMAR_VM_SPICE_PORT (5902), EZOMAR_VM_RENDERNODE

VM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STORAGE="${EZOMAR_VM_STORAGE:-$VM_DIR/storage}"
DISK="$STORAGE/data.img"
VARS="$STORAGE/uefi.vars"
# Runtime fica fora de vm/storage: aquele diretório é criado pelo container e
# pertence ao root, e um pidfile não tem por que morar junto do disco.
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/ezomar-vm"
mkdir -p "$RUNTIME"
PIDFILE="$RUNTIME/qemu-direct.pid"
QMP="$RUNTIME/qemu-direct.qmp"
RAM="${EZOMAR_VM_RAM:-8G}"
CPUS="${EZOMAR_VM_CPUS:-6}"
SSH_PORT="${EZOMAR_VM_SSH_PORT:-2223}"
SPICE_PORT="${EZOMAR_VM_SPICE_PORT:-5902}"
RENDERNODE="${EZOMAR_VM_RENDERNODE:-/dev/dri/renderD128}"
# O firmware TEM que casar com a NVRAM: pflash é um par, e code de 1,9M com vars
# de 528K não boota (o guest fica em "Display output is not active"). O container
# escreveu uefi.rom/uefi.vars como par de 4M, então reusar o rom dele é o que
# preserva a entrada de boot do Limine que já está gravada.
if [ -f "$STORAGE/uefi.rom" ]; then
  OVMF_CODE="${EZOMAR_VM_OVMF_CODE:-$STORAGE/uefi.rom}"
else
  OVMF_CODE="${EZOMAR_VM_OVMF_CODE:-/usr/share/edk2/ovmf/OVMF_CODE.fd}"
fi

say() { echo "[ezomar][vm-direct] $*"; }
die() { echo "[ezomar][vm-direct] $*" >&2; exit 1; }

running_pid() {
  [ -f "$PIDFILE" ] || return 1
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
}

if [ "${1:-}" = "--stop" ]; then
  if pid="$(running_pid)"; then
    # ACPI shutdown pelo QMP, não SIGKILL: o guest é um sistema instalado, e
    # matar o processo é o mesmo que arrancar a tomada num btrfs montado.
    if command -v python3 >/dev/null 2>&1 && [ -S "$QMP" ]; then
      python3 - "$QMP" <<'PY' || true
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1]); s.settimeout(3)
s.recv(65536)
s.sendall(b'{"execute":"qmp_capabilities"}\n'); time.sleep(0.2); s.recv(65536)
s.sendall(b'{"execute":"system_powerdown"}\n'); time.sleep(0.2)
PY
      say "Desligamento ACPI enviado; aguardando o guest fechar..."
      for _ in $(seq 1 30); do running_pid >/dev/null || break; sleep 2; done
    fi
    if pid="$(running_pid)"; then
      say "O guest não fechou sozinho; encerrando o processo."
      kill "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$PIDFILE" "$QMP"
  say "Parada."
  exit 0
fi

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 não encontrado."
[ -e /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm inacessível."
[ -f "$DISK" ] || die "disco não encontrado: $DISK (a VM já foi instalada pelo container?)"
[ -w "$DISK" ] || die "sem permissão de escrita em $DISK. O container o cria como root; ajuste com:
  docker run --rm -v \"$STORAGE:/s\" alpine chown $(id -u):$(id -g) /s/data.img /s/uefi.vars"
[ -f "$OVMF_CODE" ] || die "firmware UEFI não encontrado: $OVMF_CODE"

if pid="$(running_pid)"; then
  say "Já está rodando (pid $pid). Para desligar: bash vm/qemu-direct.sh --stop"
  exit 0
fi
if docker inspect -f '{{.State.Running}}' "${EZOMAR_VM_NAME:-ezomar-vm}" 2>/dev/null | grep -q true; then
  die "o container ainda está de pé e usaria o mesmo disco. Pare com: docker stop ${EZOMAR_VM_NAME:-ezomar-vm}"
fi

# A NVRAM precisa ser gravável: é onde mora a entrada de boot do Limine.
if [ ! -f "$VARS" ]; then
  for c in /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -f "$c" ] && { cp "$c" "$VARS"; break; }
  done
  [ -f "$VARS" ] || die "não achei um OVMF_VARS para semear $VARS"
fi
[ -w "$VARS" ] || die "sem permissão de escrita em $VARS (veja a dica acima)."

GL_ARGS=()
if [ -e "$RENDERNODE" ] && [ -r "$RENDERNODE" ] && [ -w "$RENDERNODE" ]; then
  # virtio-vga-gl + egl-headless é o par que entrega virgl ao guest e deixa o
  # SPICE só transportando o resultado. Sem isto o guest volta ao llvmpipe, que
  # é exatamente o que motivou este script.
  GL_ARGS=(-device virtio-vga-gl -display "egl-headless,rendernode=$RENDERNODE")
  say "GL ligado sobre $RENDERNODE."
else
  GL_ARGS=(-device virtio-vga -display none)
  say "Sem acesso a $RENDERNODE; subindo sem GL (vai renderizar por software)."
fi

say "Disco: $DISK  RAM: $RAM  vCPU: $CPUS"
qemu-system-x86_64 \
  -name ezomar-vm-direct \
  -machine q35,accel=kvm,smm=off \
  -cpu host -smp "$CPUS" -m "$RAM" \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$VARS" \
  -object iothread,id=io1 \
  -device virtio-scsi-pci,id=scsi0,iothread=io1 \
  -drive "file=$DISK,if=none,id=hd0,format=raw,cache=none,aio=native,discard=unmap,detect-zeroes=on" \
  -device scsi-hd,drive=hd0,bus=scsi0.0 \
  -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22" \
  -device virtio-net-pci,netdev=net0 \
  "${GL_ARGS[@]}" \
  -spice "port=$SPICE_PORT,addr=127.0.0.1,disable-ticketing=on" \
  -device virtio-serial-pci \
  -chardev spicevmc,id=vdagent,name=vdagent \
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  -qmp "unix:$QMP,server,nowait" \
  -pidfile "$PIDFILE" \
  -daemonize

sleep 2
pid="$(running_pid)" || die "o QEMU não subiu; rode sem -daemonize para ver o erro."
say "Rodando (pid $pid)."
say ""
say "Tela:  remote-viewer spice://127.0.0.1:$SPICE_PORT"
say "SSH:   ssh -p $SSH_PORT opik@localhost"
say "Parar: bash vm/qemu-direct.sh --stop"
