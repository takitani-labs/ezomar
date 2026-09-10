#!/usr/bin/env bash
set -uo pipefail

# Liga e desliga o microfone nas DUAS camadas de uma vez.
#
#   mic            mostra o estado das duas
#   mic on         liga as duas
#   mic off        desliga as duas
#   mic toggle     alterna as duas juntas
#
# Áudio no Linux tem duas camadas e o sintoma é idêntico nas duas, o que engana
# muito: o PipeWire tem a própria flag de mudo, e a placa tem um switch de
# captura em hardware. Basta uma estar cortando para não passar som, e quem
# desliga uma não vê a outra.
#
# Foi exatamente isso aqui: o botão do tray fala só com o PipeWire, e o
# microfone estava mudo também no ALSA. Desmutar pelo tray mudava a flag de
# software e o som continuava sem passar, então o botão parecia quebrado.
#
# Nada é hardcoded: a placa sai da fonte padrão do PipeWire, e o controle é o
# primeiro da placa que tenha switch de captura (`cswitch`). Assim continua
# funcionando quando você trocar de microfone.

say() { echo "[mic] $*"; }

command -v wpctl >/dev/null 2>&1 || { say "wpctl não encontrado (PipeWire)." >&2; exit 1; }

# --- descobrir a placa e o controle ------------------------------------------
CARD="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | awk -F'"' '/alsa\.card =/{print $2; exit}')"
NAME="$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | awk -F'"' '/node\.nick =/{print $2; exit}')"
[ -n "$NAME" ] || NAME="microfone padrão"

CONTROL=""
if [ -n "$CARD" ] && command -v amixer >/dev/null 2>&1; then
  # `cswitch` é o que liga e desliga a captura. Um controle só de volume não
  # serve, e é por isso que a busca é pela capacidade e não pelo nome: em outro
  # aparelho o controle pode se chamar "Capture" em vez de "Mic".
  while IFS= read -r ctl; do
    if amixer -c "$CARD" sget "$ctl" 2>/dev/null | grep -q "cswitch"; then
      CONTROL="$ctl"
      break
    fi
  done < <(amixer -c "$CARD" scontrols 2>/dev/null | sed "s/^Simple mixer control '\(.*\)',.*/\1/")
fi

pw_muted() { wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q MUTED; }

alsa_muted() {
  [ -n "$CONTROL" ] || return 1   # sem switch de hardware, nada a barrar
  amixer -c "$CARD" sget "$CONTROL" 2>/dev/null | grep -oE "Capture .*\[(on|off)\]" | grep -q "\[off\]"
}

status() {
  local pw alsa
  pw=$(pw_muted && echo "MUDO" || echo "ligado")
  if [ -n "$CONTROL" ]; then
    alsa=$(alsa_muted && echo "MUDO" || echo "ligado")
    alsa="$alsa  (placa $CARD, controle $CONTROL)"
  else
    alsa="sem switch de captura em hardware"
  fi
  echo "  $NAME"
  echo "    PipeWire: $pw"
  echo "    ALSA:     $alsa"
  if pw_muted || alsa_muted; then
    echo "    -> não está passando som"
  else
    echo "    -> captando"
  fi
}

set_state() {
  local want="$1"   # on | off
  if [ "$want" = on ]; then
    wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0 >/dev/null 2>&1
    [ -n "$CONTROL" ] && amixer -c "$CARD" sset "$CONTROL" cap >/dev/null 2>&1
  else
    wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1 >/dev/null 2>&1
    [ -n "$CONTROL" ] && amixer -c "$CARD" sset "$CONTROL" nocap >/dev/null 2>&1
  fi
  sleep 0.3
}

case "${1:-status}" in
  status | "")
    status
    ;;
  on | unmute)
    set_state on
    say "ligado nas duas camadas."
    status
    ;;
  off | mute)
    set_state off
    say "desligado nas duas camadas."
    status
    ;;
  toggle | t)
    # Mudo se QUALQUER camada estiver cortando: é isso que decide se sai som,
    # e é o que o alternar tem de inverter.
    if pw_muted || alsa_muted; then set_state on; say "ligado."; else set_state off; say "desligado."; fi
    status
    ;;
  -h | --help)
    sed -n '3,8p' "$0" | sed 's/^# \?//'
    ;;
  *)
    say "uso: mic [status|on|off|toggle]" >&2
    exit 2
    ;;
esac
