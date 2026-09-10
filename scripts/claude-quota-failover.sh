#!/usr/bin/env bash
set -uo pipefail

# Quando uma sessão bate no limite, continua a MESMA conversa na próxima conta.
#
# Chamado pelo hook `StopFailure` do Claude Code, com o matcher `rate_limit`.
# Esse evento existe para isto: dispara quando o turno morre por erro de API, e
# `rate_limit` é um dos motivos que ele sabe distinguir. Não é preciso caçar
# texto de erro dentro do JSONL da conversa, que mudaria de forma a cada versão.
#
# Uma sessão em execução NÃO troca de conta: o `CLAUDE_CONFIG_DIR` é lido quando
# o processo nasce. O que existe é reexecutar a mesma conversa sob outro perfil,
# e isso funciona porque todos os perfis apontam `projects` para o mesmo
# `~/.claude/projects`. É o que o Ctrl+B A já faz na mão; aqui só o gatilho é
# automático, e o trabalho pesado continua sendo do herdr-switch-agent-profile.
#
# Desligar: EZOMAR_QUOTA_FAILOVER=off no ~/.config/ezomar/config.sh

CONFIG="$HOME/.config/ezomar/config.sh"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

BEST="${CLAUDE_BEST_BIN:-$HOME/work/repos/takitani-labs/ezomar/scripts/claude-best-account.sh}"
SWITCH="${HERDR_SWITCH_BIN:-$HOME/.local/bin/herdr-switch-agent-profile}"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/ezomar/quota-failover.log"

note() {
  mkdir -p "$(dirname "$LOG")"
  printf '%s  %s\n' "$(date -Is)" "$*" >>"$LOG"
}

# Hook sempre sai 0. Um failover que não deu certo não pode virar erro em cima
# do erro de cota que a pessoa já está vendo.
give_up() { note "$*"; exit 0; }

[ "${EZOMAR_QUOTA_FAILOVER:-on}" = off ] && give_up "desligado por configuração"

# O payload do hook chega no stdin; só o session_id interessa, e mesmo ele é
# opcional porque o switcher pergunta ao herdr qual sessão o pane está rodando.
payload="$(timeout 2 cat 2>/dev/null || true)"
session_id="$(printf '%s' "$payload" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id") or "")
except Exception: print("")' 2>/dev/null)"

# Fora de um pane do herdr não há o que reexecutar: o switcher trabalha mandando
# o pane sair e subir de novo, e sem pane isso não existe.
[ -n "${HERDR_PANE_ID:-}" ] || give_up "fora de um pane do herdr; nada a trocar"
[ -x "$SWITCH" ] || give_up "herdr-switch-agent-profile não encontrado em $SWITCH"

current="$(basename "${CLAUDE_CONFIG_DIR:-}" 2>/dev/null)"
[ -n "$current" ] && [ "$current" != "." ] || give_up "não descobri o perfil atual (CLAUDE_CONFIG_DIR vazio)"

# A conta que acabou de recusar sai da disputa, senão o failover devolve ela
# mesma e a troca não sai do lugar.
target="$(bash "$BEST" --exclude "$current" 2>/dev/null)"
[ -n "$target" ] || {
  command -v notify-send >/dev/null 2>&1 && notify-send -u critical -a "Claude" \
    "Cota esgotada" "Nenhuma outra conta tem folga agora. A sessão ficou onde está." || true
  give_up "sem conta alternativa com folga; sessão $session_id fica em $current"
}

note "cota de $current esgotada; migrando a sessão $session_id para $target"
command -v notify-send >/dev/null 2>&1 && notify-send -a "Claude" \
  "Trocando de conta" "$current esgotou. Continuando em $target." || true

# O switcher já sabe fazer tudo; a única coisa que ele pede de fora é qual
# perfil, e ele aceita isso por variável em vez de menu.
HERDR_SWITCH_PROFILE="$target" "$SWITCH" >>"$LOG" 2>&1 \
  || give_up "o switcher falhou ao migrar para $target"

note "sessão $session_id agora em $target"
exit 0
