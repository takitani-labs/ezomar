#!/usr/bin/env bash
set -euo pipefail

# A conta Codex de trabalho precisa de uma segunda instância do CLIProxyAPI.
# Duas contas no mesmo processo entram no round-robin do provider e não há como
# escolher qual paga uma chamada; separar a porta 8318 da pessoal na 8317 evita
# misturar atribuição, credenciais e consumo.
#
# O chezmoi já restaura o perfil Claude codex-exato. Este módulo não recria esse
# perfil: só injeta nele a chave secreta que não pode ficar no repositório.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates"

PORT="${EZOMAR_CPA_EXATO_PORT:-8318}"
BIN="$HOME/.local/bin/cli-proxy-api"
CONF_DIR="$HOME/.cli-proxy-api-exato"
CONF="$CONF_DIR/config.yaml"
UNIT="$HOME/.config/systemd/user/cli-proxy-api-exato.service"
SERVICE_NAME="cli-proxy-api-exato.service"
PROFILE_SETTINGS="$HOME/.claude-profiles/codex-exato/settings.json"
USAGE_TEMPLATE="$TPL/cliproxyapi-exato/ai-usagebar-codex.config.toml"

if [ ! -x "$BIN" ]; then
  echo "[ezomar][cliproxyapi-exato] $BIN não existe. Rode o módulo 60 antes." >&2
  exit 1
fi
if [ ! -f "$PROFILE_SETTINGS" ]; then
  echo "[ezomar][cliproxyapi-exato] $PROFILE_SETTINGS não existe. O módulo 30 deveria restaurá-lo." >&2
  exit 1
fi
if [ ! -f "$USAGE_TEMPLATE" ]; then
  echo "[ezomar][cliproxyapi-exato] Template ausente: $USAGE_TEMPLATE" >&2
  exit 1
fi

KEY="$(grep -oE 'cpa-exato-[a-f0-9]+' "$CONF" 2>/dev/null | head -1 || true)"

# Sem credencial o modulo nao esta pronto, mesmo com config, unit e perfil no
# lugar: o proxy sobe e responde 401 em toda chamada.
credential_missing() {
  ! ls "$CONF_DIR"/codex-*.json >/dev/null 2>&1
}

already_configured() {
  [ -n "$KEY" ] || return 1
  [ -f "$UNIT" ] || return 1
  systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1 || return 1
  systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1 || return 1
  grep -q "port: $PORT" "$CONF" || return 1
  grep -qF "http://127.0.0.1:$PORT" "$PROFILE_SETTINGS" || return 1
  grep -qF "$KEY" "$PROFILE_SETTINGS" || return 1
  [ -f "$HOME/.config/ai-usagebar-codex-personal/ai-usagebar/config.toml" ] || return 1
  [ -f "$HOME/.config/ai-usagebar-codex-exato/ai-usagebar/config.toml" ] || return 1
  credential_missing && return 1
  return 0
}

if already_configured; then
  echo "[ezomar][cliproxyapi-exato] Instância, perfil, configs e serviço já configurados. Pulando."
  exit 0
fi

echo "[ezomar][cliproxyapi-exato] Configurando a conta de trabalho na porta $PORT."
mkdir -p "$CONF_DIR"
if [ -z "$KEY" ]; then
  KEY="cpa-exato-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
umask 077
cat >"$CONF" <<EOF
# CLIProxyAPI - instância da conta Codex de trabalho (gerado pelo ezomar)
# A conta pessoal fica na porta 8317 com auth-dir ~/.cli-proxy-api.
host: "127.0.0.1"
port: $PORT
auth-dir: "$CONF_DIR"
api-keys:
  - "$KEY"
EOF
chmod 600 "$CONF"

mkdir -p "$(dirname "$UNIT")"
cat >"$UNIT" <<'EOF'
[Unit]
Description=CLIProxyAPI (conta Codex de trabalho) -> API local OpenAI/Anthropic-compatible
After=network-online.target

[Service]
WorkingDirectory=%h/.cli-proxy-api-exato
ExecStart=%h/.local/bin/cli-proxy-api --config %h/.cli-proxy-api-exato/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
START_FAILED=false
if ! systemctl --user enable --now "$SERVICE_NAME" >/dev/null 2>&1; then
  START_FAILED=true
fi
ACTIVE="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
echo "[ezomar][cliproxyapi-exato] Serviço: ${ACTIVE:-inativo}."
if [ "$START_FAILED" = true ] || [ "$ACTIVE" != active ]; then
  echo "[ezomar][cliproxyapi-exato] Aviso: falha ao iniciar $SERVICE_NAME; consulte: journalctl --user -u $SERVICE_NAME" >&2
  exit 1
fi

# Atualiza somente os dois campos locais; o restante do settings.json continua
# sendo propriedade do chezmoi.
python3 - "$PROFILE_SETTINGS" "$PORT" "$KEY" <<'PY'
import json
import sys

path, port, key = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
env = data.setdefault("env", {})
env["ANTHROPIC_BASE_URL"] = f"http://127.0.0.1:{port}"
env["ANTHROPIC_AUTH_TOKEN"] = key
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY
echo "[ezomar][cliproxyapi-exato] Chave e porta injetadas no perfil codex-exato."

for acct in personal exato; do
  usage_dir="$HOME/.config/ai-usagebar-codex-$acct/ai-usagebar"
  mkdir -p "$usage_dir"
  sed "s|{{CODEX_AUTH_PATH}}|$HOME/.codex-profiles/$acct/auth.json|" \
    "$USAGE_TEMPLATE" >"$usage_dir/config.toml"
done

# O CLIProxyAPI precisa da SUA PROPRIA credencial, obtida por ele. Nao copie a do
# Codex CLI: a OpenAI rotaciona o refresh token, entao o primeiro dos dois cofres
# que renovar invalida o outro. Aconteceu em 2026-08-06, ~18h depois de uma copia
# dessas: o Codex CLI renovou, o proxy ficou com token morto, tomou 401 e o
# circuit breaker interno marcou a credencial como "cooling down". Dai em diante
# ele recusava LOCALMENTE em 0-1ms, sem chamar a OpenAI, e os agentes concluiram
# que a conta tinha estourado quando ela estava com 24% da janela semanal.
#
# Sintoma: 429 "All credentials for model X are cooling down via provider codex"
# respondido em ~1ms. Latencia baixa demais para ter ido ate o upstream. O
# cooldown vive em memoria, entao reiniciar a unit revela o erro real por tras.
if ! ls "$CONF_DIR"/codex-*.json >/dev/null 2>&1; then
  echo "[ezomar][cliproxyapi-exato] Sem credencial. Faca o login DESTA instancia (interativo):"
  echo "  $BIN --config $CONF -codex-login"
  echo "[ezomar][cliproxyapi-exato] Use a conta de trabalho. Nao copie o auth.json do Codex CLI."
else
  count=$(ls "$CONF_DIR"/codex-*.json 2>/dev/null | wc -l)
  if [ "$count" -gt 1 ]; then
    echo "[ezomar][cliproxyapi-exato] AVISO: $count credenciais codex neste auth-dir." >&2
    echo "[ezomar][cliproxyapi-exato] O proxy faz round-robin entre elas; uma morta derruba metade" >&2
    echo "[ezomar][cliproxyapi-exato] das chamadas e re-arma o cooldown. Deixe apenas a boa." >&2
  fi
fi

echo "[ezomar][cliproxyapi-exato] Configuração concluída."
