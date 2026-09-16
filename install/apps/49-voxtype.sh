#!/usr/bin/env bash
set -euo pipefail

# Ditado em português, e microfone ligado antes de gravar.
#
# Duas coisas que o padrão do Omarchy não cobre nesta máquina.
#
# 1. O modelo de fábrica é `base.en`, que é SÓ inglês. Modelo com sufixo `.en`
#    não transcreve português de jeito nenhum, então o ditado nasce inútil para
#    quem fala português. Aqui baixamos o `small`, que é o menor multilíngue com
#    qualidade decente, e fixamos `language = pt`.
#
# 2. O atalho de fábrica chama `voxtype record start` direto. Pedir áudio de um
#    microfone mudo não dá erro, dá silêncio, e o Whisper diante de silêncio
#    alucina: escreve "you" para tudo. O sintoma parece falha de reconhecimento
#    e é microfone cortado. O `voxtype-dictate` liga antes de gravar.
#
# O bind do F9 fica no bindings.lua do chezmoi, não aqui: é configuração do
# Hyprland e precisa de `hl.unbind` antes, para sobrescrever o padrão.
#
# Botões:
#   EZOMAR_VOXTYPE_MODEL     padrão small
#   EZOMAR_VOXTYPE_LANGUAGE  padrão pt

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/voxtype"
BIN_DIR="$HOME/.local/bin"
MODEL="${EZOMAR_VOXTYPE_MODEL:-small}"
LANGUAGE="${EZOMAR_VOXTYPE_LANGUAGE:-pt}"
MODEL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/voxtype/models"

say() { echo "[ezomar][voxtype] $*"; }

[ -f "$TPL/voxtype-dictate" ] || { say "Template ausente: $TPL/voxtype-dictate" >&2; exit 1; }
install -D -m 0755 "$TPL/voxtype-dictate" "$BIN_DIR/voxtype-dictate"
say "Instalado: $BIN_DIR/voxtype-dictate"

if ! command -v voxtype >/dev/null 2>&1; then
  say "voxtype não encontrado; o resto depende dele. Pulando."
  exit 0
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
    say "Não consegui baixar o modelo $MODEL; o ditado segue em inglês." >&2
    exit 0
  fi
fi

voxtype config set whisper.model "$MODEL" >/dev/null 2>&1 || true
voxtype config set whisper.language "$LANGUAGE" >/dev/null 2>&1 || true
systemctl --user restart voxtype >/dev/null 2>&1 || true
say "Ditado em '$LANGUAGE' com o modelo '$MODEL'."
