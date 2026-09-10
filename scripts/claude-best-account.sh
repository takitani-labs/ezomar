#!/usr/bin/env bash
set -uo pipefail

# Diz qual conta Claude usar agora, para quem tem várias assinaturas.
#
#   claude-best-account.sh            imprime só o nome do perfil (papi-max)
#   claude-best-account.sh --list     mostra o ranking inteiro, com o porquê
#
# A pergunta ao começar algo novo não é "onde sobra mais", é "o que eu perco se
# não usar". Cota que zera sem ser usada é cota jogada fora, então entre duas
# contas com folga a certa é a que RENOVA ANTES.
#
# Cada provedor reporta DUAS janelas, e elas não respondem a mesma coisa:
#
#   a de 5 horas é um FREIO. Volta sozinha várias vezes por dia, e quando ela
#   vira não se perde nada. Serve para dizer se dá para começar AGORA.
#
#   a semanal é o ORÇAMENTO. Vira uma vez, na data, e o que não foi usado até
#   lá não volta. É ela que decide a ordem.
#
# Confundir as duas foi o bug do painel: a conta Team subia ao topo porque a
# janela de 5 horas dela virava em uma hora, enquanto a semana só fechava seis
# dias depois. O conselho apontava para quem não tinha nada a perder.
#
# Só imprime nome de perfil no stdout. Aviso e ranking vão para o stderr, para
# `_claude_profile "$(claude-best-account.sh)"` continuar funcionando.

USAGE_DIR="${CLAUDE_USAGE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage}"
PROFILE_DIR="${CLAUDE_PROFILE_DIR:-$HOME/.claude-profiles}"
# Abaixo disso a conta não tem o que aproveitar antes do reset e sai da disputa.
FLOOR="${CLAUDE_BEST_FLOOR:-0.10}"
# Dado velho escolhe a conta errada com cara de certeza.
MAX_AGE_MIN="${CLAUDE_BEST_MAX_AGE_MIN:-15}"

MODE="${1:-pick}"
case "$MODE" in
  --list | -l) MODE=list ;;
  "" | pick) MODE=pick ;;
  -h | --help)
    sed -n '3,8p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *) echo "uso: $(basename "$0") [--list]" >&2; exit 2 ;;
esac

[ -d "$USAGE_DIR" ] || { echo "[claude-best] sem $USAGE_DIR" >&2; exit 1; }

# Se ninguém coletou há um tempo, coletar antes de decidir. `--limits-only` pega
# só as cotas, que é o que interessa aqui, e é bem mais rápido que a coleta
# completa. Falha não é fatal: melhor decidir com dado de 20 minutos atrás do
# que não decidir.
newest="$(find "$USAGE_DIR" -maxdepth 1 -name 'claude*.json' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
if [ -n "$newest" ]; then
  age_min=$(( ( $(date +%s) - ${newest%.*} ) / 60 ))
  if [ "$age_min" -ge "$MAX_AGE_MIN" ] && command -v omarchy-agent-usage-update >/dev/null 2>&1; then
    echo "[claude-best] dados com ${age_min}min; atualizando as cotas…" >&2
    timeout 45 omarchy-agent-usage-update --limits-only >/dev/null 2>&1 || true
  fi
fi

USAGE_DIR="$USAGE_DIR" PROFILE_DIR="$PROFILE_DIR" FLOOR="$FLOOR" MODE="$MODE" python3 <<'PYEOF'
import glob
import json
import os
import sys
from datetime import datetime, timezone

USAGE_DIR = os.environ["USAGE_DIR"]
PROFILE_DIR = os.environ["PROFILE_DIR"]
FLOOR = float(os.environ["FLOOR"])
MODE = os.environ["MODE"]
now = datetime.now(timezone.utc)


def is_long(label):
    """A janela do orçamento. Os provedores escrevem isto de jeitos diferentes:
    'Weekly (7-day)', 'Weekly quota', 'Weekly'."""
    t = (label or "").lower()
    return "week" in t or "7-day" in t or "7 day" in t


def seconds_until(entry):
    raw = (entry or {}).get("resetsAt")
    if not raw:
        return -1
    try:
        return (datetime.fromisoformat(raw.replace("Z", "+00:00")) - now).total_seconds()
    except ValueError:
        return -1


def duration(seconds):
    if seconds <= 0:
        return "-"
    d, h, m = int(seconds // 86400), int(seconds // 3600) % 24, int(seconds // 60) % 60
    if d:
        return f"{d}d {h}h"
    return f"{h}h {m}m" if h else f"{m}m"


rows = []
for path in sorted(glob.glob(os.path.join(USAGE_DIR, "claude*.json"))):
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        continue

    provider = str(doc.get("id") or "")
    # `claude` sozinho é o ~/.claude padrão, que nesta máquina não é usado para
    # trabalho: as contas todas moram em perfis.
    if not provider.startswith("claude-"):
        continue
    profile = provider[len("claude-"):]
    if not os.path.isdir(os.path.join(PROFILE_DIR, profile)):
        continue

    limits = [l for l in (doc.get("limits") or []) if isinstance(l.get("percent"), (int, float))]
    if not limits:
        continue

    longs = [l for l in limits if is_long(l.get("label"))]
    shorts = [l for l in limits if not is_long(l.get("label"))]

    # Limite da conta inteira ganha de limite de um modelo só ("Fable Weekly"),
    # mesmo estando menos cheio: é ele que decide se a conta serve para
    # qualquer trabalho, e não só para um modelo.
    budget = None
    for entry in longs:
        scoped = bool(entry.get("title"))
        if budget is None:
            budget = entry
            continue
        if bool(budget.get("title")) != scoped:
            if not scoped:
                budget = entry
            continue
        if entry["percent"] > budget["percent"]:
            budget = entry
    if budget is None:
        budget = max(limits, key=lambda l: l["percent"])

    throttle = max(shorts, key=lambda l: l["percent"]) if shorts else None

    free = 1 - budget["percent"]
    throttle_free = 1 - throttle["percent"] if throttle else 1.0
    rows.append({
        "profile": profile,
        "name": str(doc.get("name") or profile),
        "tier": str(doc.get("tierLabel") or ""),
        "free": free,
        "reset": seconds_until(budget),
        "blocked": throttle_free < FLOOR,
        "throttle_pct": throttle["percent"] if throttle else -1,
        "throttle_reset": seconds_until(throttle),
        "budget_pct": budget["percent"],
        "usable": free >= FLOOR and throttle_free >= FLOOR,
    })

if not rows:
    print("[claude-best] nenhuma conta Claude com cota conhecida.", file=sys.stderr)
    sys.exit(1)

# Inutilizável vai para o fim. Entre as boas, a que vence antes; empate decide
# pela que tem mais folga.
rows.sort(key=lambda r: (
    0 if r["usable"] else 1,
    r["reset"] if r["reset"] > 0 else float("inf"),
    -r["free"],
))

best = rows[0] if rows[0]["usable"] else None

if MODE == "list":
    width = max(len(r["name"]) for r in rows)
    for row in rows:
        mark = "->" if best and row is best else "  "
        if row["blocked"]:
            why = "janela cheia, volta em " + duration(row["throttle_reset"])
        elif not row["usable"]:
            why = "sem folga na semana"
        else:
            why = "vence em " + duration(row["reset"])
        print("%s %-*s  %-14s  semana %3d%%  %s" % (
            mark, width, row["name"], row["tier"], round(row["budget_pct"] * 100), why))
    sys.exit(0)

if not best:
    print("[claude-best] todas as contas estão sem folga ou com a janela cheia.", file=sys.stderr)
    print("[claude-best] a que volta primeiro: %s, em %s" % (
        rows[0]["name"], duration(rows[0]["throttle_reset"])), file=sys.stderr)
    sys.exit(1)

print("[claude-best] %s (%s) — semana em %d%%, vence em %s" % (
    best["name"], best["tier"], round(best["budget_pct"] * 100), duration(best["reset"])),
    file=sys.stderr)
print(best["profile"])
PYEOF
