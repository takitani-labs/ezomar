#!/usr/bin/env bash
set -euo pipefail

# CLIProxyAPI transforma as subscriptions dos CLIs de IA em uma API local
# compatível com OpenAI e Anthropic. Sem ele, os perfis codex e gemini que o
# chezmoi restaura apontam para a porta 8317, mas não existe binário, config com
# chave local nem unit de usuário para atender essa porta.
#
# Endpoints locais:
#   OpenAI:   http://127.0.0.1:8317/v1/chat/completions
#   Anthropic: http://127.0.0.1:8317/v1/messages

BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/cli-proxy-api"
CONF_DIR="$HOME/.cli-proxy-api"
CONF="$CONF_DIR/config.yaml"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE="$SERVICE_DIR/cli-proxy-api.service"
SERVICE_NAME="cli-proxy-api.service"

profiles_configured() {
  local profile settings
  for profile in codex gemini; do
    settings="$HOME/.claude-profiles/$profile/settings.json"
    if [ -f "$settings" ] && grep -q '{{CLIPROXY_API_KEY}}' "$settings"; then
      return 1
    fi
  done
  return 0
}

if [ -x "$BIN" ] && [ -s "$CONF" ] && [ -f "$SERVICE" ] \
  && systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1 \
  && systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1 \
  && profiles_configured; then
  echo "[ezomar][cliproxyapi] Binário, config, perfis e serviço já configurados. Pulando."
  exit 0
fi

mkdir -p "$BIN_DIR" "$CONF_DIR" "$SERVICE_DIR"

if [ -x "$BIN" ]; then
  echo "[ezomar][cliproxyapi] Binário já instalado. Pulando download."
else
  echo "[ezomar][cliproxyapi] Baixando a última release..."
  VERSION="$(curl -fsSL https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("tag_name", ""))')"
  if [ -z "$VERSION" ]; then
    echo "[ezomar][cliproxyapi] Não foi possível determinar a versão. Abortando." >&2
    exit 1
  fi

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  URL="https://github.com/router-for-me/CLIProxyAPI/releases/download/${VERSION}/CLIProxyAPI_${VERSION#v}_linux_amd64.tar.gz"
  if ! curl -fsSL -o "$TMP/cpa.tar.gz" "$URL"; then
    echo "[ezomar][cliproxyapi] Download falhou: $URL" >&2
    exit 1
  fi
  tar -xzf "$TMP/cpa.tar.gz" -C "$TMP"
  EXTRACTED="$(find "$TMP" -maxdepth 2 -type f \( -iname 'cli-proxy-api*' -o -iname 'CLIProxyAPI*' \) ! -name '*.tar.gz' | head -1)"
  if [ -z "$EXTRACTED" ]; then
    echo "[ezomar][cliproxyapi] Binário não encontrado no tarball." >&2
    exit 1
  fi
  install -m 0755 "$EXTRACTED" "$BIN"
  echo "[ezomar][cliproxyapi] Instalado $VERSION em $BIN."
fi

if [ ! -f "$CONF" ]; then
  LOCAL_KEY="cpa-local-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  umask 077
  cat >"$CONF" <<EOF
# CLIProxyAPI - gerado pelo ezomar (edite à vontade)
host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "$LOCAL_KEY"
EOF
  chmod 600 "$CONF"
  echo "[ezomar][cliproxyapi] Config criada em $CONF (chave local gerada)."
else
  echo "[ezomar][cliproxyapi] Config já existe em $CONF. Mantendo."
fi

if [ ! -f "$SERVICE" ]; then
  cat >"$SERVICE" <<'EOF'
[Unit]
Description=CLIProxyAPI (subscriptions -> API local OpenAI/Anthropic-compatible)
After=network-online.target

[Service]
WorkingDirectory=%h/.cli-proxy-api
ExecStart=%h/.local/bin/cli-proxy-api --config %h/.cli-proxy-api/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  echo "[ezomar][cliproxyapi] Serviço criado."
fi

if ! systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1 \
  || ! systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1; then
  if ! systemctl --user enable --now "$SERVICE_NAME"; then
    echo "[ezomar][cliproxyapi] Aviso: falha ao iniciar $SERVICE_NAME; consulte: journalctl --user -u $SERVICE_NAME" >&2
    exit 1
  fi
fi
if ! systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1; then
  echo "[ezomar][cliproxyapi] Aviso: $SERVICE_NAME não está ativo; consulte: journalctl --user -u $SERVICE_NAME" >&2
  exit 1
fi

CPA_KEY="$(grep -A1 'api-keys:' "$CONF" | tail -1 | sed 's/^[[:space:]]*-[[:space:]]*//; s/"//g')"
if [ -n "$CPA_KEY" ]; then
  for profile in codex gemini; do
    settings="$HOME/.claude-profiles/$profile/settings.json"
    if [ -f "$settings" ] && grep -q '{{CLIPROXY_API_KEY}}' "$settings"; then
      sed -i "s/{{CLIPROXY_API_KEY}}/$CPA_KEY/" "$settings"
      echo "[ezomar][cliproxyapi] Chave injetada no perfil Claude '$profile'."
    fi
  done
fi

echo "[ezomar][cliproxyapi] Instalado. Os logins de subscription são interativos e feitos uma vez:"
echo "  cli-proxy-api --config ~/.cli-proxy-api/config.yaml -codex-login"
echo "  cli-proxy-api --config ~/.cli-proxy-api/config.yaml -antigravity-login"
echo "  cli-proxy-api --config ~/.cli-proxy-api/config.yaml -kimi-login"
echo "  cli-proxy-api --config ~/.cli-proxy-api/config.yaml -claude-login"
