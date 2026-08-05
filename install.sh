#!/usr/bin/env bash
set -euo pipefail

trap 'echo "[ezomar] Falha na instalação. Você pode reexecutar com: bash ./install.sh"' ERR

echo "[ezomar] Verificando distribuição..."
if [ -r /etc/os-release ]; then
  . /etc/os-release
else
  echo "[ezomar] /etc/os-release não encontrado. Abortando." >&2
  exit 1
fi

if [ "${ID:-}" != "arch" ] && [[ "${ID_LIKE:-}" != *arch* ]]; then
  echo "[ezomar] Esta instalação é destinada a Arch/Omarchy. Detectado: ${ID:-desconhecido}" >&2
  exit 1
fi

# Omarchy is the expected base, but plain Arch works: the modules only add what
# is missing. Warn rather than abort, so a bare Arch install is still usable.
if [ ! -d "$HOME/.local/share/omarchy" ] && [ ! -d "/etc/omarchy" ]; then
  echo "[ezomar] Aviso: Omarchy não detectado. Seguindo mesmo assim (Arch puro é suportado)."
fi

echo "[ezomar] Atualizando índices de pacote..."
sudo pacman -Sy --noconfirm >/dev/null

echo "[ezomar] Executando módulos..."
EZOMAR_AUTOMATED=true bash "$(dirname "$0")/install/apps.sh"

echo "[ezomar] Instalação concluída."
