#!/usr/bin/env bash
set -euo pipefail

echo "[ezomar] Preparando ambiente e clonando o repositório..."

# Pacotes mínimos para clonar e executar
sudo pacman -S --needed --noconfirm git curl || true

TARGET_DIR="$HOME/.local/share/ezomar"
# Repositório público (HTTPS fixo), para funcionar antes de haver chave SSH
REPO_URL="https://github.com/takitani-labs/ezomar.git"
BRANCH="master"

rm -rf "$TARGET_DIR"
mkdir -p "$(dirname "$TARGET_DIR")"

git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR" || {
  echo "[ezomar] Erro ao clonar $REPO_URL (branch: $BRANCH). Verifique a rede e tente novamente."
  exit 1
}

echo "[ezomar] Iniciando instalação..."
bash "$TARGET_DIR/install.sh"
