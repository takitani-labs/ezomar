#!/usr/bin/env bash
set -uo pipefail

# Um retrato de quem está logado em cada agente, e o comando exato para
# consertar quem não está.
#
#   bash scripts/agent-auth-preflight.sh            relatório
#   bash scripts/agent-auth-preflight.sh --gate     idem, e sai 1 se algo está deslogado
#   bash scripts/agent-auth-preflight.sh --fix      percorre os pendentes, um a um
#
# Por que existe: no restore o herdr roda `claude --resume <id>` sem abrir
# navegador nenhum. Um perfil deslogado não falha na hora de subir, falha no
# primeiro comando de cada pane, e aí já são dezenas de panes abertas em cima de
# uma credencial morta. Antes valia só para o Claude; os outros fornecedores
# ficavam de fora e o restore voltava "quase" inteiro.
#
# Cada fornecedor guarda credencial de um jeito diferente, e o que conta é
# sempre o token de REFRESH ou a chave, nunca o access token, que se renova
# sozinho e nunca é o problema:
#
#   Claude OAuth   ~/.claude-profiles/<p>/.credentials.json  refreshTokenExpiresAt
#   Claude por API ~/.claude-profiles/<p>/settings.json      env.ANTHROPIC_AUTH_TOKEN
#   Claude por proxy  idem, mas ANTHROPIC_BASE_URL aponta para 127.0.0.1: quem
#                     autentica é o cli-proxy-api, então o que se checa é o serviço
#   Codex          ~/.codex-profiles/<p>/auth.json           tokens.refresh_token
#   Gemini         ~/.gemini/oauth_creds.json                expiry_date (ms)
#   Grok           ~/.grok/active_sessions.json              lista vazia = sem sessão
#
# Variáveis:
#   EZOMAR_AUTH_WARN_DAYS   avisa tantos dias antes de um refresh vencer (padrão 5)

GATE=false
FIX=false
case "${1:-}" in
  --gate) GATE=true ;;
  --fix)  FIX=true ;;
esac

WARN_DAYS="${EZOMAR_AUTH_WARN_DAYS:-5}"

command -v python3 >/dev/null 2>&1 || {
  echo "[ezomar][auth] python3 ausente; não dá para ler as credenciais." >&2
  exit 0
}

report() {
  EZOMAR_AUTH_WARN_DAYS="$WARN_DAYS" python3 - "$1" "${2:-false}" <<'PY'
import base64
import glob
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

GATE = sys.argv[1] == "true"
# No modo lista o relatorio sai pelo stderr e o stdout carrega so os
# comandos de conserto, um por linha, para o shell consumir sem precisar
# analisar a tabela.
LIST_FIXES = len(sys.argv) > 2 and sys.argv[2] == "true"
OUTPUT = sys.stderr if LIST_FIXES else sys.stdout
WARN_DAYS = float(os.environ.get("EZOMAR_AUTH_WARN_DAYS", "5"))
HOME = os.path.expanduser("~")
NOW = datetime.now(timezone.utc)

# 0 = ok, 1 = expira em breve (avisa e deixa passar), 2 = deslogado (bloqueia)
OK, SOON, OUT = 0, 1, 2
rows = []


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def days_left(when):
    return (when - NOW).total_seconds() / 86400


def from_epoch(value, unit_ms=False):
    try:
        n = float(value)
    except (TypeError, ValueError):
        return None
    if unit_ms:
        n /= 1000.0
    try:
        return datetime.fromtimestamp(n, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def jwt_claims(token):
    # O id_token do Codex carrega e-mail e validade, e ler o payload não exige
    # verificar assinatura: aqui só se quer rotular a linha, não confiar nele.
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


def expiry_row(vendor, name, when, detail, fix):
    if when is None:
        rows.append((OK, vendor, name, "OK", f"{detail}, sem data registrada", fix))
        return
    left = days_left(when)
    stamp = when.strftime("%d/%m %H:%M")
    if left <= 0:
        rows.append((OUT, vendor, name, "EXPIRADO", f"{detail}, venceu {stamp}", fix))
    elif left <= WARN_DAYS:
        rows.append((SOON, vendor, name, "EXPIRA EM BREVE", f"{detail}, vence {stamp} ({left:.1f}d)", fix))
    else:
        rows.append((OK, vendor, name, "OK", f"{detail}, vence {stamp} ({left:.0f}d)", fix))


def proxy_alive(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            return 200 <= resp.status < 500
    except Exception:
        return False


def codex_logged_in(profile_dir):
    try:
        env = dict(os.environ, CODEX_HOME=profile_dir)
        out = subprocess.run(
            ["codex", "login", "status"],
            capture_output=True, text=True, timeout=15, env=env,
        )
    except Exception:
        return None
    text = (out.stdout + out.stderr).lower()
    if "logged in" in text and "not logged in" not in text:
        return True
    return False


def service_active(unit):
    try:
        out = subprocess.run(
            ["systemctl", "--user", "is-active", unit],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip() == "active"
    except Exception:
        return False


# --- Claude: OAuth, chave de API e proxy local moram todos em .claude-profiles
proxies_needed = set()
for path in sorted(glob.glob(os.path.join(HOME, ".claude-profiles", "*"))):
    if not os.path.isdir(path):
        continue
    name = os.path.basename(path)
    settings = load(os.path.join(path, "settings.json")) or {}
    env = settings.get("env") or {}
    base = env.get("ANTHROPIC_BASE_URL") or ""
    creds = load(os.path.join(path, ".credentials.json"))
    fix = f"CLAUDE_CONFIG_DIR={path} claude   (depois /login)"

    if base.startswith("http://127.0.0.1") or base.startswith("http://localhost"):
        proxies_needed.add(base)
        if proxy_alive(base):
            rows.append((OK, "claude", name, "OK", f"proxy local {base} responde", "-"))
        else:
            rows.append((OUT, "claude", name, "PROXY FORA", f"{base} não responde",
                         "systemctl --user restart cli-proxy-api.service"))
        continue

    if env.get("ANTHROPIC_AUTH_TOKEN"):
        # Chave de API não expira sozinha nem se renova: ou está lá, ou não está.
        rows.append((OK, "claude", name, "OK", f"chave de API para {base or 'provedor externo'}", "-"))
        continue

    if not creds:
        if not settings:
            continue  # diretório que não é perfil
        rows.append((OUT, "claude", name, "PRECISA LOGIN", "sem .credentials.json", fix))
        continue

    oauth = creds.get("claudeAiOauth") or creds
    # O e-mail não está no .credentials.json: fica no .claude.json do perfil,
    # junto do resto do estado da conta.
    account = (load(os.path.join(path, ".claude.json")) or {}).get("oauthAccount") or {}
    mail = account.get("emailAddress") or oauth.get("emailAddress") or "?"
    tier = oauth.get("subscriptionType") or ""
    label = f"{mail} ({tier})" if tier else mail
    expiry_row("claude", name, from_epoch(oauth.get("refreshTokenExpiresAt"), unit_ms=True), label, fix)

# --- Codex: um CODEX_HOME por conta
for path in sorted(glob.glob(os.path.join(HOME, ".codex-profiles", "*"))):
    if not os.path.isdir(path):
        continue
    name = os.path.basename(path)
    auth = load(os.path.join(path, "auth.json"))
    fix = f"CODEX_HOME={path} codex login"
    if not auth:
        # O perfil "shared" guarda config e plugins, não credencial; a ausência
        # de auth.json ali é o desenho, não uma falha.
        if name == "shared":
            continue
        rows.append((OUT, "codex", name, "PRECISA LOGIN", "sem auth.json", fix))
        continue
    tokens = auth.get("tokens") or {}
    if not tokens.get("refresh_token") and not auth.get("OPENAI_API_KEY"):
        rows.append((OUT, "codex", name, "PRECISA LOGIN", "sem refresh token nem chave", fix))
        continue
    claims = jwt_claims(tokens.get("id_token", ""))
    mail = claims.get("email") or auth.get("auth_mode") or "?"
    # Deliberado: NÃO se olha o exp do id_token aqui. Ele dura horas e se renova
    # pelo refresh token, então um id_token vencido é o estado normal de uma
    # conta perfeitamente logada. Medido no takidesk: os dois perfis tinham
    # id_token vencido havia uma semana e o `codex login status` dizia
    # "Logged in using ChatGPT". Quem responde é o próprio CLI.
    if codex_logged_in(path):
        rows.append((OK, "codex", name, "OK", f"{mail}, sessão válida", "-"))
    else:
        rows.append((OUT, "codex", name, "PRECISA LOGIN", f"{mail}, o CLI não reconhece a sessão", fix))

# --- Gemini: um OAuth só, no home do próprio CLI
gem = load(os.path.join(HOME, ".gemini", "oauth_creds.json"))
if gem is not None:
    accounts = load(os.path.join(HOME, ".gemini", "google_accounts.json")) or {}
    mail = accounts.get("active") or "?"
    if not gem.get("refresh_token"):
        rows.append((OUT, "gemini", "default", "PRECISA LOGIN", "sem refresh token", "gemini   (conclua o navegador)"))
    else:
        # O expiry_date é do access token, que se renova sozinho enquanto houver
        # refresh token. Vencido não é problema; ausência de refresh é.
        rows.append((OK, "gemini", "default", "OK", f"{mail}, refresh presente", "-"))

# --- Grok: sessões ativas, uma lista que fica vazia quando não há login
grok_path = os.path.join(HOME, ".grok", "active_sessions.json")
if os.path.exists(grok_path):
    sessions = load(grok_path)
    fix = "grok   (conclua o login)"
    if isinstance(sessions, list) and sessions:
        rows.append((OK, "grok", "default", "OK", f"{len(sessions)} sessão(ões) ativa(s)", "-"))
    else:
        rows.append((OUT, "grok", "default", "PRECISA LOGIN", "nenhuma sessão ativa", fix))

# --- o proxy que três perfis dependem
if proxies_needed and not service_active("cli-proxy-api.service"):
    rows.append((OUT, "proxy", "cli-proxy-api", "SERVIÇO PARADO",
                 "perfis apontados para ele vão falhar",
                 "systemctl --user enable --now cli-proxy-api.service"))

if not rows:
    print("[ezomar][auth] Nenhum perfil de agente encontrado.", file=OUTPUT)
    sys.exit(0)

width_v = max(len(r[1]) for r in rows)
width_n = max(len(r[2]) for r in rows)
print(f"{'':2}{'FORNECEDOR'.ljust(width_v)}  {'PERFIL'.ljust(width_n)}  {'ESTADO'.ljust(15)}  DETALHE", file=OUTPUT)
for level, vendor, name, state, detail, _fix in sorted(rows, key=lambda r: (-r[0], r[1], r[2])):
    mark = {OK: " ", SOON: "!", OUT: "X"}[level]
    print(f"{mark} {vendor.ljust(width_v)}  {name.ljust(width_n)}  {state.ljust(15)}  {detail}", file=OUTPUT)

blocked = [r for r in rows if r[0] == OUT]
soon = [r for r in rows if r[0] == SOON]

if blocked:
    print("---", file=OUTPUT)
    print("BLOQUEIA: " + ", ".join(f"{r[1]}/{r[2]}" for r in blocked), file=OUTPUT)
    for r in blocked:
        print(f"  {r[1]}/{r[2]}: {r[5]}", file=OUTPUT)
if soon:
    print("AVISO: expira em breve: " + ", ".join(f"{r[1]}/{r[2]}" for r in soon), file=OUTPUT)
    for r in soon:
        print(f"  {r[1]}/{r[2]}: {r[5]}", file=OUTPUT)

# O portão só barra o que está de fato deslogado. Barrar por "vence em quatro
# dias" seria pior que o problema que ele evita.
if LIST_FIXES:
    for r in blocked:
        print(r[5])

sys.exit(1 if (GATE and blocked) else 0)
PY
}

# O modo interativo existe porque a lista de consertos e sempre a mesma
# sequencia chata: um comando por fornecedor, cada um abrindo navegador. Ele
# pergunta antes de cada um, para ninguem ser jogado num fluxo de login que
# nao pediu, e reimprime o estado no fim.
if [ "$FIX" = true ]; then
  mapfile -t FIXES < <(report false true)
  if [ "${#FIXES[@]}" -eq 0 ]; then
    echo "[ezomar][auth] Nada para consertar."
    exit 0
  fi
  echo
  echo "[ezomar][auth] ${#FIXES[@]} login(s) pendente(s)."
  for cmd in "${FIXES[@]}"; do
    [ "$cmd" = "-" ] && continue
    echo
    echo "[ezomar][auth] > $cmd"
    read -r -p "[ezomar][auth] rodar agora? [s/N/q] " answer </dev/tty || answer=q
    case "$answer" in
      [Ss]*) eval "$cmd" </dev/tty ;;
      [Qq]*) echo "[ezomar][auth] Parando aqui."; break ;;
      *)     echo "[ezomar][auth] Pulado." ;;
    esac
  done
  echo
  echo "[ezomar][auth] Estado final:"
  report false
  exit $?
fi

report "$GATE"
