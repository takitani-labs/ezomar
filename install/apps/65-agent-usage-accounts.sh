#!/usr/bin/env bash
set -euo pipefail

# Omarchy's native agents panel already discovers one JSON file per tab, but
# its updater only invokes each vendor collector once. Install a separate,
# periodic fan-out instead of patching Omarchy so package updates remain free
# to replace every upstream file.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/agent-usage-accounts"
BIN="$HOME/.local/bin/ezomar-agent-usage-accounts"
USAGEBAR_BRIDGE="$HOME/.local/bin/ezomar-agent-usage-ai-usagebar"
USER_UNITS="$HOME/.config/systemd/user"
SERVICE="ezomar-agent-usage-accounts.service"
TIMER="ezomar-agent-usage-accounts.timer"

say() { echo "[ezomar][agent-usage] $*"; }

for file in ezomar-agent-usage-accounts ezomar-agent-usage-ai-usagebar "$SERVICE" "$TIMER"; do
  if [ ! -f "$TPL/$file" ]; then
    say "Template ausente: $TPL/$file" >&2
    exit 1
  fi
done

for command in jq realpath; do
  if ! command -v "$command" >/dev/null 2>&1; then
    say "Comando obrigatório ausente: $command" >&2
    exit 1
  fi
done

install -D -m 0755 "$TPL/ezomar-agent-usage-accounts" "$BIN"
install -D -m 0755 "$TPL/ezomar-agent-usage-ai-usagebar" "$USAGEBAR_BRIDGE"
install -D -m 0644 "$TPL/$SERVICE" "$USER_UNITS/$SERVICE"
install -D -m 0644 "$TPL/$TIMER" "$USER_UNITS/$TIMER"

if ! systemctl --user daemon-reload >/dev/null 2>&1; then
  say "Não foi possível recarregar as unidades systemd do usuário." >&2
  exit 1
fi
if ! systemctl --user enable --now "$TIMER" >/dev/null 2>&1; then
  say "Não foi possível habilitar e iniciar $TIMER." >&2
  exit 1
fi

# Populate the panel in this install run; waiting for OnBootSec would leave a
# correctly installed feature looking absent until the first timer firing.
"$BIN"

if ! systemctl --user is-enabled "$TIMER" >/dev/null 2>&1 \
  || ! systemctl --user is-active "$TIMER" >/dev/null 2>&1; then
  say "$TIMER não ficou habilitado e ativo." >&2
  exit 1
fi

say "Contas atualizadas; $TIMER ativo (intervalo de 15 minutos)."
