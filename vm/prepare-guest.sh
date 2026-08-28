#!/usr/bin/env bash
set -euo pipefail

# Prepara a VM recém-instalada para receber o vm-test.sh.
#
# São duas coisas que a instalação não tem como deixar prontas e que, sem elas,
# o ensaio trava no primeiro módulo:
#
#   sudo sem senha   metade dos módulos chama sudo (pacman, chsh, sysctl). Numa
#                    execução automatizada não há ninguém para digitar a senha, e
#                    o `ssh -t` ficaria pendurado no prompt. Numa VM descartável
#                    que só escuta em 127.0.0.1 isso é aceitável; na máquina real
#                    seria impensável, e por isso mora aqui e não num módulo.
#   rsync            é como o harness leva a árvore de trabalho para dentro. O
#                    Omarchy já traz, mas uma instalação futura pode não trazer.
#
# Rode uma vez depois de cada instalação (inclusive depois de vm/reset.sh --up).
#
#   bash vm/prepare-guest.sh
#   EZOMAR_VM_PASSWORD=outra bash vm/prepare-guest.sh

VM_HOST="${VM_HOST:-localhost}"
VM_PORT="${VM_PORT:-2223}"
VM_USER="${VM_USER:-${EZOMAR_VM_USER:-opik}}"
PASSWORD="${EZOMAR_VM_PASSWORD:-}"

say() { echo "[ezomar][prepare-guest] $*"; }
die() { echo "[ezomar][prepare-guest] $*" >&2; exit 1; }

SSH=(ssh -p "$VM_PORT" -o BatchMode=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$VM_USER@$VM_HOST")

"${SSH[@]}" true 2>/dev/null \
  || die "não consegui entrar em $VM_USER@$VM_HOST:$VM_PORT por chave. A VM está instalada e de pé?"

if "${SSH[@]}" 'sudo -n true' 2>/dev/null; then
  say "sudo já é sem senha."
else
  if [ -z "$PASSWORD" ]; then
    [ -t 0 ] || die "sudo pede senha e não há terminal. Use EZOMAR_VM_PASSWORD."
    read -r -s -p "[ezomar][prepare-guest] Senha de $VM_USER na VM: " PASSWORD; echo
  fi
  say "Liberando sudo sem senha para $VM_USER..."
  # A senha entra pelo stdin do sudo (-S) e nunca aparece na linha de comando,
  # que ficaria visível no ps da VM.
  printf '%s\n' "$PASSWORD" | "${SSH[@]}" \
    "sudo -S sh -c 'printf \"%s ALL=(ALL) NOPASSWD: ALL\n\" \"$VM_USER\" > /etc/sudoers.d/99-ezomar-vm && chmod 0440 /etc/sudoers.d/99-ezomar-vm && visudo -c -q'" 2>&1 \
    | grep -v '^\[sudo\]' || true
  "${SSH[@]}" 'sudo -n true' 2>/dev/null || die "não valeu; confira a senha."
  say "sudo sem senha, ok."
fi

# A host key do GitHub. Sem ela, o `claude plugin install` do modulo 40 falha em
# "No ED25519 host key is known for github.com" nos marketplaces que clonam por
# SSH, e o erro nao diz que o problema e a VM, nao o repo. Na maquina real o
# known_hosts vem do chezmoi; aqui nao vem nada.
if ! "${SSH[@]}" 'ssh-keygen -F github.com >/dev/null 2>&1'; then
  say "Registrando a host key do github.com na VM..."
  "${SSH[@]}" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null' \
    || say "Aviso: nao consegui registrar a host key (sem rede?)."
fi

MISSING="$("${SSH[@]}" 'for c in rsync git; do command -v $c >/dev/null || echo $c; done' 2>/dev/null || true)"
if [ -n "$MISSING" ]; then
  say "Instalando na VM: $MISSING"
  # shellcheck disable=SC2086
  "${SSH[@]}" "sudo pacman -Sy --needed --noconfirm $MISSING" >/dev/null \
    || die "falha ao instalar: $MISSING"
fi

say "VM pronta. Agora: ./vm-test.sh"
