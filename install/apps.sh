#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

export EZOMAR_AUTOMATED="${EZOMAR_AUTOMATED:-false}"

if sudo -n true 2>/dev/null; then
  echo "[ezomar] Sudo NOPASSWD disponível, continuando..."
else
  echo "[ezomar] Autenticação necessária para instalação de pacotes..."
  sudo -v
fi

# Keep the sudo timestamp warm for the whole run.
(while true; do sudo -n true; sleep 50; done 2>/dev/null) &
SUDO_REFRESH_PID=$!
cleanup() { kill $SUDO_REFRESH_PID 2>/dev/null || true; }
trap cleanup EXIT

# Modules run in filename order. The numbering is load-bearing: the age key
# (20) has to land before chezmoi (30), or every encrypted file fails to
# decrypt and the run looks like it worked while producing half a machine.
FAILED=()
for script in "$SCRIPT_DIR/apps"/*.sh; do
  [ -f "$script" ] || continue
  name="$(basename "$script")"
  skip=0
  if [ -n "${EZOMAR_INSTALL_ONLY:-}" ]; then
    skip=1
    for selected in $EZOMAR_INSTALL_ONLY; do
      if [ "$name" = "$selected" ]; then skip=0; break; fi
    done
  fi
  for skipped in ${EZOMAR_INSTALL_SKIP:-}; do
    if [ "$name" = "$skipped" ]; then skip=1; break; fi
  done
  if [ "$skip" -eq 1 ]; then
    echo
    echo "[ezomar][módulo] $name pulado por EZOMAR_INSTALL_SKIP."
    continue
  fi
  echo
  echo "[ezomar][módulo] $name"
  if bash "$script"; then
    :
  else
    echo "[ezomar][módulo] $name FALHOU (seguindo para o próximo)"
    FAILED+=("$name")
  fi
done

echo
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[ezomar] Módulos com falha: ${FAILED[*]}"
  echo "[ezomar] Corrija e reexecute; os módulos são idempotentes."
  exit 1
fi
