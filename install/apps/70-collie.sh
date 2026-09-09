#!/usr/bin/env bash
set -euo pipefail

# Collie é a interface de celular para acompanhar e responder aos agentes do
# herdr pelo Tailscale. Sem o plugin, a manada fica acessível apenas no desktop.
# A instalação é opcional e nunca inicia o bridge: iniciar publicaria um shell
# remoto no tailnet antes de revisar a identidade e a allowlist de hosts.

PLUGIN_ID="herdr.collie"
COLLIE_REPO="https://github.com/AltanS/collie.git"
COLLIE_REPO_DIR="$HOME/work/repos/references/collie"

# O bun do mise não está no PATH de um shell não interativo.
export PATH="$HOME/.local/share/mise/shims:$HOME/.bun/bin:$PATH"

# --- o PWA precisa existir em disco -----------------------------------------
# `web/dist` é gerado e está no .gitignore, então um repositório restaurado de
# backup ou clonado de novo vem sem ele e o bridge responde "not found" em `/`.
# Isso passa despercebido porque quem já tem o app instalado no celular
# continua abrindo: o service worker serve o casco do cache e só a API vai à
# rede. O celular fica preso numa versão antiga por tempo indefinido, e o que
# se nota não é "está fora do ar", é um comportamento antigo que já foi
# corrigido no código. Foi o que aconteceu aqui: o celular ficou meses sem
# quebra de linha no espelho porque o build era anterior à correção.
#
# Roda antes de qualquer decisão sobre o plugin do herdr, porque o bridge também
# é iniciado por unidade do systemd, sem o herdr no meio.
build_web_if_stale() {
  local dist="$COLLIE_REPO_DIR/web/dist/index.html"
  local newest
  if [ -f "$dist" ]; then
    newest="$(find "$COLLIE_REPO_DIR/web/src" "$COLLIE_REPO_DIR/web/index.html" \
      -newer "$dist" -print -quit 2>/dev/null || true)"
    if [ -z "$newest" ]; then
      echo "[ezomar][collie] PWA já compilado e atual."
      return 0
    fi
    echo "[ezomar][collie] Fonte mais nova que web/dist; recompilando."
  else
    echo "[ezomar][collie] Sem web/dist; compilando o PWA."
  fi
  ( cd "$COLLIE_REPO_DIR" && bun install --frozen-lockfile >/dev/null \
    && cd web && bun install --frozen-lockfile >/dev/null && bun run build >/dev/null ) \
    || { echo "[ezomar][collie] Build do PWA falhou; o bridge vai responder 404 em /." >&2; return 1; }
  echo "[ezomar][collie] PWA compilado em web/dist."
}

if [ -d "$COLLIE_REPO_DIR/web" ]; then
  if command -v bun >/dev/null 2>&1; then
    build_web_if_stale || true
  else
    echo "[ezomar][collie] bun não encontrado; não dá para compilar o PWA."
  fi
fi

if ! command -v herdr >/dev/null 2>&1; then
  echo "[ezomar][collie] herdr não encontrado. Pulando o plugin."
  exit 0
fi
if ! command -v bun >/dev/null 2>&1; then
  echo "[ezomar][collie] bun não encontrado (dependência do bridge). Pulando."
  exit 0
fi

if herdr plugin list 2>/dev/null | grep -q "$PLUGIN_ID"; then
  echo "[ezomar][collie] Já instalado. Pulando."
  echo "[ezomar][collie] Para atualizar: herdr plugin action invoke update --plugin $PLUGIN_ID"
  exit 0
fi

should_install() {
  local answer
  if [ "${EZOMAR_INSTALL_COLLIE:-}" = "true" ]; then
    return 0
  fi
  if [ "${EZOMAR_AUTOMATED:-false}" = "true" ]; then
    return 1
  fi
  if command -v gum >/dev/null 2>&1; then
    gum confirm --default=false \
      "Instalar Collie? Ele expõe um shell remoto e exige configuração de segurança."
  else
    read -r -p "Instalar Collie? Expõe shell remoto no tailnet e exige configuração. [y/N] " answer
    [[ ${answer:-} =~ ^[Yy]$ ]]
  fi
}

if ! should_install; then
  echo "[ezomar][collie] Opcional, pulando. Para instalar: EZOMAR_INSTALL_COLLIE=true bash install/apps/70-collie.sh"
  exit 0
fi

echo "[ezomar][collie] Instalando o plugin via clone completo e link..."
if [ -d "$COLLIE_REPO_DIR/.git" ]; then
  echo "[ezomar][collie] Clone já existe em $COLLIE_REPO_DIR; reaproveitando."
else
  mkdir -p "$(dirname "$COLLIE_REPO_DIR")"
  git clone "$COLLIE_REPO" "$COLLIE_REPO_DIR"
fi

herdr plugin link "$COLLIE_REPO_DIR"
bash "$COLLIE_REPO_DIR/scripts/collie-ctl.sh" build

CONFIG_DIR="$HOME/.config/herdr/plugins/config/$PLUGIN_ID"
echo "[ezomar][collie] Instalado, mas não iniciado. Passos manuais:"
echo "  1) Crie $CONFIG_DIR/.env (0600) com COLLIE_TRUSTED_USER e COLLIE_PUBLIC_HOSTS."
echo "  2) Revise a rota existente com: tailscale serve status"
echo "  3) Inicie com: herdr plugin action invoke start --plugin $PLUGIN_ID"
echo "  Nunca use tailscale funnel com o Collie."
