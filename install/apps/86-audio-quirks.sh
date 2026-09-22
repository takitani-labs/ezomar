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

# Levantar o mixer sempre que o aparelho aparecer, e não só agora.
#
# O ajuste acima só acontece se o fone estiver plugado no instante da
# instalação. Numa máquina recém-formatada isso é uma aposta: quem roda o
# ezomar com o headset na gaveta fica com toda a configuração correta e o fone
# mudo quando plugar, porque o asound.state nasce vazio e o soft-mixer impede o
# PipeWire de levantar o controle. A regra udev tira a ordem das coisas da
# equação.
#
# Mora em /etc e /usr/local, fora do $HOME, então precisa de root e não volta
# sozinho num restore de backup: é justamente por isso que fica versionado aqui.
install_system_quirk() {
  local src="$1" dst="$2" mode="$3"
  if cmp -s "$src" "$dst" 2>/dev/null; then
    return 1
  fi
  sudo install -m "$mode" "$src" "$dst"
  return 0
}

SYS_FILES_OK=1
for pair in \
  "ezomar-fuxi-levels|/usr/local/bin/ezomar-fuxi-levels|0755" \
  "ezomar-fuxi-levels@.service|/etc/systemd/system/ezomar-fuxi-levels@.service|0644" \
  "99-ezomar-fuxi.rules|/etc/udev/rules.d/99-ezomar-fuxi.rules|0644"
do
  IFS='|' read -r f d m <<<"$pair"
  [ -f "$TPL/$f" ] || continue
  if ! cmp -s "$TPL/$f" "$d" 2>/dev/null; then
    SYS_FILES_OK=0
  fi
done

if [ "$SYS_FILES_OK" = 1 ]; then
  say "Gatilho udev já instalado."
elif sudo -n true 2>/dev/null; then
  changed=0
  for pair in \
    "ezomar-fuxi-levels|/usr/local/bin/ezomar-fuxi-levels|0755" \
    "ezomar-fuxi-levels@.service|/etc/systemd/system/ezomar-fuxi-levels@.service|0644" \
    "99-ezomar-fuxi.rules|/etc/udev/rules.d/99-ezomar-fuxi.rules|0644"
  do
    IFS='|' read -r f d m <<<"$pair"
    [ -f "$TPL/$f" ] || continue
    install_system_quirk "$TPL/$f" "$d" "$m" && changed=1
  done
  if [ "$changed" = 1 ]; then
    sudo systemctl daemon-reload || true
    sudo udevadm control --reload-rules || true
    say "Gatilho udev instalado: o mixer sobe sozinho quando o fone aparecer."
  fi
else
  say "Falta instalar o gatilho udev (precisa de root). Rode:"
  say "  sudo install -m 0755 $TPL/ezomar-fuxi-levels /usr/local/bin/ezomar-fuxi-levels"
  say "  sudo install -m 0644 $TPL/ezomar-fuxi-levels@.service /etc/systemd/system/ezomar-fuxi-levels@.service"
  say "  sudo install -m 0644 $TPL/99-ezomar-fuxi.rules /etc/udev/rules.d/99-ezomar-fuxi.rules"
  say "  sudo systemctl daemon-reload && sudo udevadm control --reload-rules"
fi

# Semear a preferência de saída numa máquina nova.
#
# Quem decide o dispositivo padrão no WirePlumber não é a prioridade do
# aparelho: é o nome guardado em default.configured.audio.sink, que vale +30000
# na disputa (find-selected-default-node.lua). Medido aqui em 21/09/2026, o fone
# tem priority.session 1109 e o HDMI do monitor 696, então sem nada guardado
# quem ganha é uma escolha antiga qualquer, e numa instalação nova é o HDMI que
# acaba levando. O sintoma é "o fone mutou": o som está tocando, no monitor.
#
# O arquivo mora em ~/.local/state, fora do $HOME versionado e fora de qualquer
# backup de configuração, então ele é exatamente a categoria de coisa que uma
# formatação leva sem avisar.
#
# SÓ SEMEIA SE NÃO EXISTIR. O arquivo é uma pilha que o WirePlumber reescreve
# sempre que alguém escolhe uma saída no painel; sobrescrever aqui desfaria a
# escolha do dono a cada execução do instalador, que é pior do que o problema.
seed_default_nodes() {
  local state="${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber"
  local file="$state/default-nodes"
  local sink="alsa_output.usb-XiiSound_Technology_Corporation_Fuxi-H3-00.analog-stereo"
  local source="alsa_input.usb-3142_fifine_Microphone-00.analog-stereo"

  if [ -e "$file" ]; then
    say "Preferência de saída já existe; não mexo (é o dono quem escolhe)."
    return 0
  fi

  mkdir -p "$state"
  cat > "$file" <<EOF
[default-nodes]
default.configured.audio.sink=$sink
default.configured.audio.source=$source
EOF
  say "Preferência semeada: saída no fone, entrada no fifine."
  say "Vale no próximo start do wireplumber."
}

seed_default_nodes

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
