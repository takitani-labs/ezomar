#!/usr/bin/env bash
set -euo pipefail

# Ditado em português, microfone ligado antes de gravar, e transcrição na placa
# de vídeo daqui quando ela existe.
#
# Três coisas que o padrão do Omarchy não cobre nesta máquina.
#
# 1. O modelo de fábrica é `base.en`, que é SÓ inglês. Modelo com sufixo `.en`
#    não transcreve português de jeito nenhum, então o ditado nasce inútil para
#    quem fala português. Aqui baixamos o `large-v3-turbo` e fixamos
#    `language = pt`.
#
# 2. O atalho de fábrica chama `voxtype record start` direto. Pedir áudio de um
#    microfone mudo não dá erro, dá silêncio, e o Whisper diante de silêncio
#    alucina: escreve "you" para tudo. O sintoma parece falha de reconhecimento
#    e é microfone cortado. O `voxtype-dictate` liga antes de gravar.
#
# 3. Com placa de vídeo dedicada, o voxtype passa para o binário Vulkan
#    (`voxtype setup gpu --enable`), que troca o /usr/bin/voxtype e por isso
#    pede sudo. Medido em 15/11/2026, 25 s de fala no large-v3-turbo: 0,4 s na
#    RX 7600, contra 5,8 s na CPU (9950X, uma thread por núcleo físico) e 10 s
#    na Radeon 610M integrada, que perde para a CPU e por isso não conta. AMD
#    vai pelo Vulkan do vulkan-radeon, sem ROCm.
#
#    Até então a transcrição ia para a GPU do kage por um túnel ssh, com a CPU
#    daqui de reserva. O kage passou semanas desligado, e cada queda deixava o
#    ditado lento; com a placa aqui isso deixou de existir, e o remoto saiu.
#
# O bind do F9 fica no bindings.lua do chezmoi, não aqui: é configuração do
# Hyprland e precisa de `hl.unbind` antes, para sobrescrever o padrão.
#
# Botões:
#   EZOMAR_VOXTYPE_MODEL     padrão large-v3-turbo
#   EZOMAR_VOXTYPE_LANGUAGE  padrão pt
#   EZOMAR_VOXTYPE_GPU       padrão auto; false mantém o voxtype na CPU

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/voxtype"
BIN_DIR="$HOME/.local/bin"
MODEL="${EZOMAR_VOXTYPE_MODEL:-large-v3-turbo}"
LANGUAGE="${EZOMAR_VOXTYPE_LANGUAGE:-pt}"
GPU="${EZOMAR_VOXTYPE_GPU:-auto}"
MODEL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/voxtype/models"

say() { echo "[ezomar][voxtype] $*"; }

[ -f "$TPL/voxtype-dictate" ] || { say "Template ausente: $TPL/voxtype-dictate" >&2; exit 1; }
install -D -m 0755 "$TPL/voxtype-dictate" "$BIN_DIR/voxtype-dictate"
say "Instalado: $BIN_DIR/voxtype-dictate"

if ! command -v voxtype >/dev/null 2>&1; then
  say "voxtype não encontrado; o resto depende dele. Pulando."
  exit 0
fi

# Núcleos físicos, não threads: o SMT não acelera o whisper.cpp e só disputa
# com o resto da máquina.
cores="$(lscpu -p=CORE,SOCKET 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
[ "$cores" -gt 0 ] 2>/dev/null || cores="$(nproc)"

# Tudo que não depende do modelo vem antes do download, para uma falha nele não
# deixar o ditado sem língua nem modo.
voxtype config set whisper.language "$LANGUAGE" >/dev/null 2>&1 || true
voxtype config set whisper.threads "$cores" >/dev/null 2>&1 || true
voxtype config set whisper.mode local >/dev/null 2>&1 || true
voxtype config unset whisper.remote_endpoint >/dev/null 2>&1 || true

# Placa dedicada: o lspci lista "VGA"/"3D" e o vulkan-radeon a enxerga. A
# integrada do Ryzen também aparece como VGA, então o critério é haver mais de
# um controlador de vídeo ou um que não seja a integrada (Granite Ridge,
# Raphael, Phoenix).
dgpu=0
if lspci 2>/dev/null | grep -E 'VGA|3D|Display' \
    | grep -viE 'Granite Ridge|Raphael|Phoenix|Rembrandt|Cezanne|Renoir' | grep -q .; then
  dgpu=1
fi
if [ "$GPU" != false ] && [ "$dgpu" = 1 ]; then
  if [ "$(readlink -f /usr/bin/voxtype)" = /usr/lib/voxtype/voxtype-vulkan ]; then
    say "Já na GPU (Vulkan)."
  elif sudo voxtype setup gpu --enable >/dev/null 2>&1; then
    say "Voxtype na GPU (Vulkan)."
  else
    say "Não consegui ligar a GPU; o ditado segue na CPU. Rode: sudo voxtype setup gpu --enable" >&2
  fi
fi

# O download oficial (`voxtype setup model`) é interativo e não serve em
# instalação automatizada. Os modelos são ggml padrão, então buscamos o arquivo
# direto e deixamos o voxtype apenas apontar para ele.
if [ -f "$MODEL_DIR/ggml-$MODEL.bin" ]; then
  say "Modelo $MODEL já baixado."
else
  say "Baixando o modelo $MODEL (multilíngue)…"
  mkdir -p "$MODEL_DIR"
  if curl -fL --retry 2 -o "$MODEL_DIR/ggml-$MODEL.bin.part" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"; then
    mv "$MODEL_DIR/ggml-$MODEL.bin.part" "$MODEL_DIR/ggml-$MODEL.bin"
    say "Modelo $MODEL pronto."
  else
    rm -f "$MODEL_DIR/ggml-$MODEL.bin.part"
    say "Não consegui baixar o modelo $MODEL; o local fica com '$(voxtype config get whisper.model 2>/dev/null)'. Rode de novo para tentar." >&2
  fi
fi
[ -f "$MODEL_DIR/ggml-$MODEL.bin" ] && voxtype config set whisper.model "$MODEL" >/dev/null 2>&1

systemctl --user restart voxtype >/dev/null 2>&1 || true
say "Ditado em '$LANGUAGE' com '$(voxtype config get whisper.model 2>/dev/null)' ($(basename "$(readlink -f /usr/bin/voxtype)"))."
