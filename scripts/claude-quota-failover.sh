#!/usr/bin/env bash
set -uo pipefail

# Quando uma sessão bate no limite, continua a MESMA conversa na próxima conta.
#
# Chamado pelo hook `StopFailure` do Claude Code, com o matcher `rate_limit`.
# Esse evento existe para isto: dispara quando o turno morre por erro de API e
# sabe distinguir o motivo, então não é preciso caçar texto de erro no JSONL.
#
# Uma sessão em execução NÃO troca de conta: o `CLAUDE_CONFIG_DIR` é lido quando
# o processo nasce. O que existe é reexecutar a mesma conversa sob outro perfil,
# e isso funciona porque todos os perfis apontam `projects` para o mesmo
# `~/.claude/projects`. O trabalho pesado é do herdr-switch-agent-profile, o mesmo
# do Ctrl+B A.
#
# Dois modos, e a separação entre eles é o que faz isto funcionar:
#
#   hook     decide se vale trocar e para qual conta, dispara o worker e SAI.
#   worker   processo à parte: espera o pane ociosar e faz a troca.
#
# A primeira versão fazia tudo dentro do hook e travava. O hook roda DENTRO do
# Claude; o switcher manda o Claude sair e espera ele sair; o Claude não sai
# enquanto o hook dele ainda está rodando. Cada um esperando o outro, até o
# switcher desistir com "o Claude não encerrou em 15s". O teste manual sempre
# funcionou justamente porque o switcher foi disparado fora da árvore do Claude.
#
# Desligar: EZOMAR_QUOTA_FAILOVER=off no ~/.config/ezomar/config.sh

CONFIG="$HOME/.config/ezomar/config.sh"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

BEST="${CLAUDE_BEST_BIN:-$HOME/work/repos/takitani-labs/ezomar/scripts/claude-best-account.sh}"
SWITCH="${HERDR_SWITCH_BIN:-$HOME/.local/bin/herdr-switch-agent-profile}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ezomar"
LOG="$STATE/quota-failover.log"
# Depois de uma falha, a conta espera este tempo antes de tentar de novo. É por
# conta e não por sessão: quem esgota é a conta, e ela fica esgotada por horas.
COOLDOWN_MIN="${EZOMAR_QUOTA_FAILOVER_COOLDOWN_MIN:-60}"

mkdir -p "$STATE"

note() { printf '%s  %s\n' "$(date -Is)" "$*" >>"$LOG"; }

notify() {
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send "$@" 2>/dev/null || true
}

key() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

# =============================================================================
# worker
# =============================================================================
if [ "${1:-}" = "--worker" ]; then
  current="$2"
  target="$3"
  session_id="$4"
  pane="$5"
  account="$(key "$current")"
  stamp="$STATE/failover-conta-$account.stamp"

  # Uma troca por conta de cada vez. O StopFailure dispara várias vezes em
  # sequência para o mesmo turno (quatro em três segundos, no log de 15/09), e
  # sem isto cada disparo abria seu próprio switcher, todos mandando /exit no
  # mesmo pane.
  exec 9>"$STATE/failover-conta-$account.lock"
  flock -n 9 || exit 0

  # Espera o turno terminar de fato. O campo é `agent_status`, o mesmo que o
  # switcher consulta: ler outro nome não dá erro, dá uma espera que nunca espera.
  status=""
  for _ in $(seq 1 30); do
    status="$(herdr pane get "$pane" 2>/dev/null | python3 -c 'import json,sys
try: print((json.load(sys.stdin)["result"]["pane"] or {}).get("agent_status") or "")
except Exception: print("")' 2>/dev/null)"
    [ "$status" != "working" ] && break
    sleep 1
  done

  if [ "$status" = "working" ]; then
    touch "$stamp"
    notify -u critical -a "Claude" "Não consegui trocar de conta" \
      "$current esgotou, mas o pane não ficou ocioso. Ctrl+B A para trocar na mão."
    note "pane seguiu em 'working' por 30s; sessão $session_id ficou em $current"
    exit 0
  fi

  note "migrando a sessão $session_id de $current para $target"
  if HERDR_PANE_ID="$pane" HERDR_SWITCH_PROFILE="$target" "$SWITCH" >>"$LOG" 2>&1; then
    rm -f "$stamp"
    notify -a "Claude" "Conta trocada" "$current esgotou. Seguindo em $target."
    note "sessão $session_id agora em $target"
  else
    touch "$stamp"
    notify -u critical -a "Claude" "Não consegui trocar de conta" \
      "$current esgotou. Troque na mão com Ctrl+B A."
    note "o switcher falhou ao migrar $session_id para $target"
  fi
  exit 0
fi

# =============================================================================
# hook
# =============================================================================
# Daqui para baixo tudo precisa ser rápido e sair 0: é o Claude esperando.

[ "${EZOMAR_QUOTA_FAILOVER:-on}" = off ] && exit 0

payload="$(timeout 2 cat 2>/dev/null || true)"
session_id="$(printf '%s' "$payload" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id") or "")
except Exception: print("")' 2>/dev/null)"

# Fora de um pane do herdr não há o que reexecutar.
[ -n "${HERDR_PANE_ID:-}" ] || { note "fora de um pane do herdr; nada a trocar"; exit 0; }
[ -x "$SWITCH" ] || { note "switcher ausente em $SWITCH"; exit 0; }

current="$(basename "${CLAUDE_CONFIG_DIR:-}" 2>/dev/null)"
[ -n "$current" ] && [ "$current" != "." ] || { note "CLAUDE_CONFIG_DIR vazio"; exit 0; }

account="$(key "$current")"
stamp="$STATE/failover-conta-$account.stamp"
if [ -f "$stamp" ]; then
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ) / 60 ))
  [ "$age_min" -lt "$COOLDOWN_MIN" ] && exit 0
fi

# Já tem um worker cuidando desta conta: não empilhar outro.
if ! flock -n "$STATE/failover-conta-$account.lock" true 2>/dev/null; then
  exit 0
fi

target="$(bash "$BEST" --exclude "$current" 2>/dev/null)"
if [ -z "$target" ]; then
  touch "$stamp"
  notify -u critical -a "Claude" "Cota esgotada" \
    "Nenhuma outra conta tem folga agora. A sessão ficou em $current."
  note "sem conta alternativa com folga; $session_id fica em $current"
  exit 0
fi

note "cota de $current esgotada; disparando worker para $target"

# setsid + fundo: o worker sai da árvore do Claude. É isso que desfaz o impasse,
# porque o Claude pode encerrar o turno e sair enquanto o worker espera.
setsid bash "$0" --worker "$current" "$target" "$session_id" "$HERDR_PANE_ID" \
  </dev/null >/dev/null 2>&1 &

exit 0
