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
# What is ported, outermost first:
#   1. kernel.sysrq=1 + admin_reserve   the manual escape hatch (system, sudo)
#   2. session.slice MemoryMin          the desktop stays steerable (user unit)
#   3. herdr.service MemoryHigh/Max     the fleet gets its own OOM domain, and
#      ManagedOOMPreference=avoid       oomd never picks the whole fleet (user unit)
#
# What is deliberately NOT ported from the Fedora version:
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
sudo install -m 0644 "$TPL/99-oom-guard.conf" /etc/sysctl.d/99-oom-guard.conf
sudo sysctl -q -p /etc/sysctl.d/99-oom-guard.conf
say "sysrq=$(cat /proc/sys/kernel/sysrq) (Alt+SysRq+F força um OOM kill; REISUB disponível)"

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
