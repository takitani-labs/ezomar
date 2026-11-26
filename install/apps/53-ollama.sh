#!/usr/bin/env bash
set -euo pipefail

# Ollama local, na placa de vídeo daqui pelo Vulkan, para o `en` e o `en-prompt`
# (tradução de prompt para inglês, Super+Alt+E).
#
# Até 26/11/2026 o Ollama rodava no kage e chegava por um túnel ssh. O kage foi
# aposentado e a RX 7600 dele veio para o takidesk; com ela o gemma4:e4b traduz
# um prompt em 0,4 a 0,6 s, sem rede no meio, e o túnel (que tentava reconectar a
# cada 10 s, mais de 4 mil vezes por dia com o kage desligado) deixou de existir.
#
# Instala a release oficial do GitHub no home, sem sudo, e só o backend de CPU e
# o de Vulkan: as bibliotecas CUDA são da NVIDIA e somam uns 4 GB. AMD vai pelo
# Vulkan (vulkan-radeon), sem ROCm. O serviço é do usuário e escuta só em
# localhost:11434, a porta que o `en` já usa.
#
# Botões:
#   EZOMAR_OLLAMA_VERSION   release do GitHub (padrão: a mais recente)
#   EZOMAR_OLLAMA_MODELS    modelos a baixar, separados por espaço (padrão gemma4:e4b)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/ollama"
APP="$HOME/.local/share/ollama-app"
UNIT_DIR="$HOME/.config/systemd/user"
MODELS="${EZOMAR_OLLAMA_MODELS-gemma4:e4b}"

say() { echo "[ezomar][ollama] $*"; }

version="${EZOMAR_OLLAMA_VERSION:-$(gh release view -R ollama/ollama --json tagName -q .tagName 2>/dev/null || true)}"
[ -n "$version" ] || { say "Não consegui descobrir a versão do Ollama (gh)." >&2; exit 1; }

current="$("$APP/bin/ollama" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)"
if [ "v$current" = "$version" ]; then
  say "Já na $version."
else
  tmp="$(mktemp -d)"
  gh release download "$version" -R ollama/ollama -p 'ollama-linux-amd64.tar.zst' -D "$tmp"
  rm -rf "$APP.new" && mkdir -p "$APP.new"
  tar -C "$APP.new" --exclude='lib/ollama/cuda_v*' -xf "$tmp/ollama-linux-amd64.tar.zst"
  rm -rf "$tmp" "$APP" && mv "$APP.new" "$APP"
  say "Instalado $version em $APP."
fi
ln -sfn "$APP/bin/ollama" "$HOME/.local/bin/ollama"

install -D -m 0644 "$TPL/ollama.service" "$UNIT_DIR/ollama.service"
systemctl --user daemon-reload
systemctl --user enable ollama.service >/dev/null 2>&1
systemctl --user restart ollama.service

for _ in $(seq 1 30); do
  curl -fsS -m 2 localhost:11434/api/version >/dev/null 2>&1 && break
  sleep 1
done
for m in $MODELS; do
  "$HOME/.local/bin/ollama" pull "$m" >/dev/null && say "Modelo pronto: $m"
done
say "Ollama $(curl -fsS -m 2 localhost:11434/api/version | jq -r .version) em localhost:11434."
