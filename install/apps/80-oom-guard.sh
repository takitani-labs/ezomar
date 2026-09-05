#!/usr/bin/env bash
set -euo pipefail

# Make running out of memory survivable, observable and escapable. Nothing here
# prevents it; a machine running agent fleets will run out.
#
# The layer exists because the primary machine froze on 2026-07-30 (36 Claude
# sessions plus Chrome, zram 100% full for 16 hours, load 283, and neither the
# kernel OOM killer nor systemd-oomd ever fired) and because, once the fleet was
# only throttled, the desktop paid for its appetite: 261 OOM kills in three
# weeks, 250 of them browser tabs. The workload moves with the owner to Omarchy;
# the protection has to move too.
#
# O modulo esta partido em duas metades desde 2026-08-28, e a divisao e entre
# CAPACIDADE e SEGURO:
#
#   Sempre: kernel.sysrq=1 + vm.admin_reserve_kbytes. Isto nao previne nada, e a
#     habilidade de agir quando ja deu errado. Sem o sysrq, um espiral de reclaim
#     so termina no botao de forca; com ele, termina em Alt+SysRq+F. Sao duas
#     linhas e nao mudam o comportamento da maquina enquanto nada acontece, entao
#     ficam no caminho padrao.
#
#   Opt-in (EZOMAR_OOM_CGROUPS=true): o piso do session.slice e o teto do
#     herdr.service. Estes SAO seguro contra a repeticao de um incidente que
#     aconteceu na maquina antiga, com metade do zram que o Omarchy usa. E os
#     numeros do teto foram medidos LA: 64G/72G saiu de um cgroup que vivia em
#     69,6G no Fedora. Chutar esses valores aqui e pior do que nao ter teto, e a
#     medicao certa e a da maquina nova, depois de ela rodar sob carga:
#       systemctl --user show herdr.service -p MemoryCurrent --value
#
# O que deliberadamente NAO veio da versao do Fedora:
#   - earlyoom: Omarchy chose systemd-oomd (PSI-based) and rejects earlyoom in
#     its own oomd.conf comments. With the fleet contained by cgroup the reason
#     earlyoom existed (picking the right victim in a mixed workload) is gone,
#     and running both produces double-kill races. Revisit if lockups return.
#   - the btrfs disk swap tier: Omarchy sizes zram to all of RAM already, and
#     ships omarchy-hibernation-setup for a disk tier below it.
#   - Omarchy's own sysctl already carries the reclaim tuning.
#
# Knobs (defaults sized from RAM; 128G gives 64G/72G, the measured working range):
#   EZOMAR_HERDR_MEMORY_HIGH   e.g. 64G
#   EZOMAR_HERDR_MEMORY_MAX    e.g. 72G

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/oom-guard"
USER_UNITS="$HOME/.config/systemd/user"

say() { echo "[ezomar][oom-guard] $*"; }

for f in 99-oom-guard.conf session-slice-memory.conf herdr-memory.conf; do
  [ -f "$TPL/$f" ] || { say "Template ausente: $TPL/$f" >&2; exit 1; }
done

say "Antes: sysrq=$(cat /proc/sys/kernel/sysrq) admin_reserve=$(cat /proc/sys/vm/admin_reserve_kbytes)K"

# --- 1. sysctl escape hatch ------------------------------------------------------
# Opt-in porque escreve em /etc, fora do $HOME. Os valores aqui nasceram de um
# congelamento medido no Fedora desta máquina; o Arch pode se comportar de outro
# jeito, e a decisão de mexer no kernel da máquina nova é de quem a opera, não
# de um instalador que só está passando.
if [ "${EZOMAR_OOM_SYSCTL:-}" != "true" ]; then
  say "sysctl é opt-in (escreve em /etc/sysctl.d). Para ligar:"
  say "  EZOMAR_OOM_SYSCTL=true bash install/apps/80-oom-guard.sh"
  say "Dá sysrq=1 (Alt+SysRq+F força um OOM kill, REISUB disponível) e reserva memória para o root."
  exit 0
fi

sudo install -m 0644 "$TPL/99-oom-guard.conf" /etc/sysctl.d/99-oom-guard.conf
sudo sysctl -q -p /etc/sysctl.d/99-oom-guard.conf
say "sysrq=$(cat /proc/sys/kernel/sysrq) (Alt+SysRq+F força um OOM kill; REISUB disponível)"

if [ "${EZOMAR_OOM_CGROUPS:-}" != "true" ]; then
  say "Limites de cgroup são opt-in; a saída manual acima já está no lugar."
  say "Se a máquina voltar a congelar sob carga de frota, meça e ative:"
  say "  systemctl --user show herdr.service -p MemoryCurrent --value"
  say "  EZOMAR_OOM_CGROUPS=true EZOMAR_HERDR_MEMORY_MAX=<medido> bash install/apps/80-oom-guard.sh"
  exit 0
fi

# --- 2. desktop floor ----------------------------------------------------------
install -D -m 0644 "$TPL/session-slice-memory.conf" "$USER_UNITS/session.slice.d/ezomar-oom-guard.conf"
say "session.slice MemoryMin=4G"

# --- 3. fleet containment ------------------------------------------------------
RAM_GB="$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo)"
HIGH_DEFAULT=$(( (RAM_GB + 8) / 16 * 8 ))   # round RAM/2 to a multiple of 8
MAX_DEFAULT=$(( HIGH_DEFAULT + 8 ))
HIGH="${EZOMAR_HERDR_MEMORY_HIGH:-${HIGH_DEFAULT}G}"
MAX="${EZOMAR_HERDR_MEMORY_MAX:-${MAX_DEFAULT}G}"

if ! systemctl --user cat herdr.service >/dev/null 2>&1; then
  say "herdr.service ausente para este usuário; pulando o limite da frota (o unit vem dos dotfiles)."
elif [ -z "${EZOMAR_HERDR_MEMORY_MAX:-}" ] && [ "$RAM_GB" -lt 32 ]; then
  say "RAM de ${RAM_GB}G é pouca para um teto padrão; defina EZOMAR_HERDR_MEMORY_HIGH/MAX se quiser conter a frota."
else
  TMP="$(mktemp)"
  sed "s/@HIGH@/$HIGH/; s/@MAX@/$MAX/" "$TPL/herdr-memory.conf" > "$TMP"
  install -D -m 0644 "$TMP" "$USER_UNITS/herdr.service.d/ezomar-oom-guard.conf"
  rm -f "$TMP"
  say "herdr.service MemoryHigh=$HIGH MemoryMax=$MAX (RAM ${RAM_GB}G), ManagedOOMPreference=avoid"
fi

systemctl --user daemon-reload

# Apply to a running fleet too, transiently; the drop-in stays the source of truth.
if systemctl --user is-active herdr.service >/dev/null 2>&1 \
   && [ -f "$USER_UNITS/herdr.service.d/ezomar-oom-guard.conf" ]; then
  systemctl --user set-property --runtime herdr.service "MemoryHigh=$HIGH" "MemoryMax=$MAX" 2>/dev/null \
    || say "Limite ao vivo recusado; vale no próximo restart do herdr."
fi

say "Pronto. Se travar de novo: Alt+SysRq+F mata o maior consumidor; Alt+SysRq+R E I S U B reinicia com segurança."
