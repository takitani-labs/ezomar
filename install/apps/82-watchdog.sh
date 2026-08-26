#!/usr/bin/env bash
set -euo pipefail

# Make a silent hard lockup self-recover instead of leaving the box dead.
#
# The primary machine locks up completely every few weeks: the journal cuts
# mid-line, no panic, no MCE, empty pstore, and nothing reboots until someone
# holds the power button. The board has a hardware watchdog (SP5100 TCO on AMD)
# that systemd only arms at shutdown; this arms it at runtime. The hardware
# follows the machine through a format, so the protection must too.
#
# It reboots blind (no pretimeout on that chip), so it is damage control, not
# diagnostics. Machines without /dev/watchdog are skipped, not failed.
#
# Knob:
#   EZOMAR_WATCHDOG_SEC   timeout in seconds (default 60, floor 30)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/watchdog/99-watchdog.conf"
DROPIN="/etc/systemd/system.conf.d/99-watchdog.conf"
SEC="${EZOMAR_WATCHDOG_SEC:-60}"
WD_SYS=/sys/class/watchdog/watchdog0

say() { echo "[ezomar][watchdog] $*"; }

[ -f "$TPL" ] || { say "Template ausente: $TPL" >&2; exit 1; }

if [ ! -e /dev/watchdog ]; then
  say "Sem /dev/watchdog nesta máquina; nada a armar. Pulando."
  exit 0
fi
IDENTITY="$(cat "$WD_SYS/identity" 2>/dev/null || echo desconhecido)"

if [ "$SEC" -lt 30 ]; then
  say "EZOMAR_WATCHDOG_SEC=$SEC é agressivo demais: abaixo de 30s uma máquina ocupada reinicia viva." >&2
  exit 1
fi
MAX_TIMEOUT="$(cat "$WD_SYS/max_timeout" 2>/dev/null || echo 0)"
if [ "$MAX_TIMEOUT" -gt 0 ] && [ "$SEC" -gt "$MAX_TIMEOUT" ]; then
  say "${SEC}s excede o que $IDENTITY suporta (máx ${MAX_TIMEOUT}s)." >&2
  exit 1
fi
# A userspace watchdog daemon would fight systemd over the device; first opener wins.
if pacman -Qi watchdog >/dev/null 2>&1; then
  say "O pacote 'watchdog' está instalado e disputaria /dev/watchdog com o systemd. Remova-o (sudo pacman -R watchdog) ou não use este módulo." >&2
  exit 1
fi

say "Antes: RuntimeWatchdogUSec=$(systemctl show -p RuntimeWatchdogUSec --value) device=$IDENTITY"

sudo install -D -m 0644 "$TPL" "$DROPIN"
[ "$SEC" = "60" ] || sudo sed -i "s/^RuntimeWatchdogSec=.*/RuntimeWatchdogSec=${SEC}/" "$DROPIN"

# Manager settings only take effect when PID 1 re-execs; daemon-reload is not enough.
sudo systemctl daemon-reexec

RUNTIME="$(systemctl show -p RuntimeWatchdogUSec --value)"
if [ -z "$RUNTIME" ] || [ "$RUNTIME" = "0" ]; then
  say "systemd ainda reporta RuntimeWatchdogUSec=$RUNTIME. Confira $DROPIN." >&2
  exit 1
fi
STATE="?"
for _ in 1 2 3 4 5; do
  STATE="$(cat "$WD_SYS/state" 2>/dev/null || echo '?')"
  [ "$STATE" = "active" ] && break
  sleep 1
done
say "Depois: RuntimeWatchdogUSec=$RUNTIME state=$STATE timeout=$(cat "$WD_SYS/timeout" 2>/dev/null || echo '?')s"
if [ "$STATE" != "active" ]; then
  say "systemd aceitou mas o dispositivo lê '$STATE'. Veja: journalctl -b | grep -i watchdog" >&2
  exit 1
fi
say "Armado: se o kernel morrer, a placa reinicia em ~${SEC}s. Conferir com: wdctl"
