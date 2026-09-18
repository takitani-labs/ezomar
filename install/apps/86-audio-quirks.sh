#!/usr/bin/env bash
set -euo pipefail

# Corrige o receptor USB do fone sem fio Fuxi-H3, cujo descritor de volume o
# PipeWire não consegue usar.
#
# O Fuxi-H3 NÃO é um DAC com saída de fone: é o receptor 2.4G do headset, e por
# isso também traz microfone. Tratar como DAC com cabo levou a uma tarde
# procurando plugue frouxo num aparelho que não tem plugue nenhum.
#
# Medido no takidesk: o Fuxi-H3 declara 100 passos de volume e uma faixa total
# de 0,39 dB. O PipeWire raciocina em decibéis, então ao pedir -6 dB para 50%
# não encontra nada nessa faixa e escreve o passo mínimo. Resultado: mexer no
# volume pelo painel emudecia o fone, e parecia que o painel estava quebrado.
#
# A regra manda o PipeWire atenuar por software nesse aparelho e não tocar no
# mixer dele. Como o mixer fica parado onde estiver, o módulo também garante que
# ele esteja alto e persiste isso, senão o volume de hardware continua no zero
# com que a máquina nova nasce.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/audio-quirks"
DEST="$HOME/.config/wireplumber/wireplumber.conf.d"
RULE="50-ezomar-soft-mixer.conf"

say() { echo "[ezomar][audio] $*"; }

[ -f "$TPL/$RULE" ] || { say "Template ausente: $TPL/$RULE" >&2; exit 1; }

if ! command -v wpctl >/dev/null 2>&1; then
  say "PipeWire não encontrado; nada a fazer."
  exit 0
fi

mkdir -p "$DEST"
if cmp -s "$TPL/$RULE" "$DEST/$RULE"; then
  say "Regra já instalada."
else
  install -m 0644 "$TPL/$RULE" "$DEST/$RULE"
  say "Regra instalada em $DEST/$RULE."
  # Só reinicia quando algo mudou: derrubar o áudio de quem está numa chamada
  # para reaplicar uma regra idêntica seria gratuito.
  if systemctl --user is-active wireplumber.service >/dev/null 2>&1; then
    say "Reiniciando o wireplumber (o som corta por um instante)."
    systemctl --user restart wireplumber.service || true
  fi
fi

# Com soft-mixer o PipeWire para de mexer no controle do aparelho, então ele
# precisa estar alto: é ele que define o teto do que sai. Numa instalação nova
# o estado do ALSA nasce zerado, porque /var/lib/alsa/asound.state é do sistema
# e não viaja em backup de $HOME.
CARD="$(aplay -l 2>/dev/null | grep -iE 'fuxi' | head -1 | sed 's/^card \([0-9]*\).*/\1/' || true)"
if [ -z "$CARD" ]; then
  say "Nenhum Fuxi conectado agora; a regra vale quando ele aparecer."
  exit 0
fi

# O receptor tem DOIS controles de reprodução, e os dois precisam estar altos:
#
#   PCM,0  estéreo, o volume que se vê
#   PCM,1  mono, que o chip usa como mestre
#
# Só o primeiro era ajustado. O segundo nasce em 0%, e com ele ali o fone só
# soava com tudo no máximo e só de um lado: o mestre mono zerado deixa passar
# um canal e quase nada de sinal. Como ele não aparece no painel de volume,
# nada na tela indica que existe.
for ctl in "PCM,0" "PCM,1"; do
  LEVEL="$(amixer -c "$CARD" sget "$ctl" 2>/dev/null | grep -oE '\[[0-9]+%\]' | head -1 | tr -d '[]%' || echo 0)"
  if [ "${LEVEL:-0}" -lt 70 ]; then
    amixer -c "$CARD" sset "$ctl" 100% >/dev/null 2>&1 || true
    say "$ctl do Fuxi estava em ${LEVEL:-0}%; ajustado para 100%."
  else
    say "$ctl do Fuxi em ${LEVEL}%, já suficiente."
  fi
done

# Sem isto o ajuste volta a zero no próximo boot.
if command -v alsactl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo alsactl store >/dev/null 2>&1 && say "Estado do ALSA gravado."
else
  say "Para o volume sobreviver ao reboot, rode: sudo alsactl store"
fi

# Conferir se a regra PEGOU, não só se o arquivo existe.
#
# A primeira versão desta regra casava por node.name. O arquivo era instalado, o
# wireplumber reiniciava, o módulo dizia "pronto" e nada acontecia: soft-mixer é
# opção de card, lida na criação do device, então a propriedade ficava visível
# no node e inerte. O defeito sobreviveu semanas porque o instalador só sabia
# dizer que tinha copiado um arquivo. Só um teste do efeito pega esse caso.
if command -v pw-dump >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  effective="$(pw-dump 2>/dev/null | python3 -c '
import json, sys
try:
    objs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in objs:
    if o.get("type") != "PipeWire:Interface:Device":
        continue
    props = (o.get("info") or {}).get("props") or {}
    if "XiiSound" not in (props.get("device.name") or ""):
        continue
    print(str(props.get("api.alsa.soft-mixer", "")).lower())
' 2>/dev/null | head -1)"

  case "$effective" in
    true|1)
      say "Regra confirmada no device: o PipeWire atenua por software." ;;
    "")
      say "Não consegui ler o device pelo pw-dump; regra não verificada." ;;
    *)
      say "AVISO: a regra está instalada mas o device NÃO recebeu soft-mixer." >&2
      say "       Abaixar o volume vai zerar o controle estéreo e o fone fica mono." >&2
      ;;
  esac
fi
