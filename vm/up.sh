#!/usr/bin/env bash
set -euo pipefail

# Sobe a VM de ensaio do Omarchy e diz onde olhar.
#
# Existe porque o docker-compose.yml sozinho não responde as perguntas que fazem
# a subida falhar na prática: qual ISO usar, se o KVM está acessível, e se as
# portas já estão tomadas por outra VM (esta máquina roda mais de uma).
#
#   bash vm/up.sh                      # ISO mais recente em ~/Downloads
#   bash vm/up.sh ~/Downloads/x.iso    # ISO específico
#
# Botões: EZOMAR_VM_RAM, EZOMAR_VM_CPUS, EZOMAR_VM_DISK, EZOMAR_VM_NAME,
#         EZOMAR_VM_WEB_PORT, EZOMAR_VM_VNC_PORT, EZOMAR_VM_SSH_PORT,
#         EZOMAR_VM_STORAGE

VM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

say() { echo "[ezomar][vm] $*"; }
die() { echo "[ezomar][vm] $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker não encontrado."
docker compose version >/dev/null 2>&1 || die "plugin 'docker compose' não encontrado."
[ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] \
  || die "/dev/kvm inacessível. Sem KVM a VM roda por emulação e é inutilizável."

# ISO: o do argumento, ou o omarchy-*.iso mais recente em ~/Downloads. Resolver
# aqui em vez de fixar a versão no compose evita ter que editar o arquivo a cada
# release nova.
ISO="${1:-${EZOMAR_VM_ISO:-}}"
if [ -z "$ISO" ]; then
  ISO="$(ls -t "$HOME"/Downloads/omarchy-*.iso 2>/dev/null | head -1 || true)"
  [ -n "$ISO" ] || die "Nenhum omarchy-*.iso em ~/Downloads. Passe o caminho: bash vm/up.sh <iso>"
fi
[ -f "$ISO" ] || die "ISO não encontrado: $ISO"
ISO="$(readlink -f "$ISO")"

WEB="${EZOMAR_VM_WEB_PORT:-8007}"
SSH_PORT="${EZOMAR_VM_SSH_PORT:-2223}"
VNC="${EZOMAR_VM_VNC_PORT:-5901}"
NAME="${EZOMAR_VM_NAME:-ezomar-vm}"

# Portas ocupadas por OUTRO container são o modo mais comum de a subida falhar
# com uma mensagem que não explica nada. Cheque antes, e diga quem está lá.
BUSY=()
for p in "$WEB" "$SSH_PORT" "$VNC"; do
  ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN && BUSY+=("$p")
done
if [ ${#BUSY[@]} -gt 0 ]; then
  say "Portas ocupadas: ${BUSY[*]}"
  docker ps --format '  {{.Names}} ({{.Image}}) -> {{.Ports}}' | grep -E "$(IFS='|'; echo "${BUSY[*]}")" || true
  die "Libere as portas, pare o outro container, ou use EZOMAR_VM_WEB_PORT/SSH_PORT/VNC_PORT."
fi

say "ISO:  $ISO ($(numfmt --to=iec --suffix=B "$(stat -c%s "$ISO")" 2>/dev/null || echo '?'))"
say "VM:   $NAME  ${EZOMAR_VM_RAM:-8G} RAM, ${EZOMAR_VM_CPUS:-6} vCPU, disco ${EZOMAR_VM_DISK:-64G}"

# O autoinstall é opcional: existindo o drive, a VM instala sozinha; não
# existindo, sobe o assistente interativo na tela.
COMPOSE=(-f docker-compose.yml)

# Aceleração: o Omarchy roda o Hyprland como compositor até na tela de login, e
# sem GPU ele cai no llvmpipe, que além de lento redesenha errado (retângulos
# pretos que só somem ao passar outra janela por cima). Com /dev/dri no host, o
# qemux expõe virgl e o guest ganha GL de verdade.
if [ "${EZOMAR_VM_GPU:-}" = "N" ]; then
  say "GPU desligada por EZOMAR_VM_GPU=N."
elif [ -e /dev/dri/renderD128 ]; then
  COMPOSE+=(-f gpu.yml)
  export EZOMAR_VM_GPU=Y
  say "GPU: /dev/dri encontrado, aceleração ligada."
else
  say "GPU: sem /dev/dri neste host; o guest vai renderizar por software."
fi

if [ -f "$VM_DIR/cidata.img" ]; then
  COMPOSE+=(-f cidata.yml)
  say "Autoinstall: cidata.img presente, a instalação roda sem intervenção."
else
  say "Autoinstall: sem cidata.img, a instalação será interativa na tela."
  say "             Para desatendida: bash vm/autoinstall.sh"
fi

cd "$VM_DIR"
EZOMAR_VM_ISO="$ISO" docker compose "${COMPOSE[@]}" up -d

say ""
say "Tela da VM:  http://localhost:$WEB"
if [ -f "$VM_DIR/cidata.img" ]; then
  say "A instalação corre sozinha (~10-25 min) e a VM reinicia no sistema instalado."
  say "O sshd e a regra de ufw já saem prontos, com sua chave."
else
  say "Instale o Omarchy por ali. Depois, dentro do guest:"
  say "  omarchy-setup-security-sshd --key=\"\$(cat ~/.ssh/id_ed25519.pub)\""
fi
say "Depois, na máquina host:"
say "  bash vm-test.sh                 # roda este repo dentro da VM"
say ""
say "Parar sem apagar o disco:  docker compose -f vm/docker-compose.yml stop"
say "Apagar tudo e recomeçar:   bash vm/reset.sh --up"
