#!/usr/bin/env bash
set -euo pipefail

# Registra o hook que continua a conversa em outra conta quando a cota acaba.
#
# O evento é `StopFailure` com matcher `rate_limit`: ele dispara quando o turno
# morre por erro de API e sabe distinguir o motivo. É melhor gatilho que ler o
# JSONL da conversa atrás da mensagem de erro, que muda de forma a cada versão.
#
# Vai em TODOS os perfis Claude, porque qualquer um deles pode ser o que esgota.
# Idempotente: se o hook já está lá, não duplica.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HANDLER="$SCRIPT_DIR/../../scripts/claude-quota-failover.sh"
PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"

say() { echo "[ezomar][quota-failover] $*"; }

[ -f "$HANDLER" ] || { say "handler ausente: $HANDLER" >&2; exit 1; }
chmod +x "$HANDLER"

if [ ! -d "$PROFILES_ROOT" ]; then
  say "sem perfis em $PROFILES_ROOT; nada a fazer."
  exit 0
fi

if [ ! -x "$HOME/.local/bin/herdr-switch-agent-profile" ]; then
  say "herdr-switch-agent-profile não instalado; rode o módulo 69 antes."
  say "O hook vai ser registrado assim mesmo e só age quando o switcher existir."
fi

HANDLER="$(readlink -f "$HANDLER")" PROFILES_ROOT="$PROFILES_ROOT" python3 <<'PYEOF'
import json
import os
import pathlib

handler = os.environ["HANDLER"]
root = pathlib.Path(os.environ["PROFILES_ROOT"])
command = f'bash {handler}'
touched = []

for profile in sorted(root.iterdir()):
    settings = profile / "settings.json"
    if not settings.is_file():
        continue
    try:
        data = json.loads(settings.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        continue

    hooks = data.setdefault("hooks", {})
    entries = hooks.setdefault("StopFailure", [])

    # Já registrado? Sair sem duplicar. O instalador roda de novo a cada
    # máquina e a cada atualização do ezomar.
    if any(
        h.get("command") == command
        for entry in entries
        for h in (entry.get("hooks") or [])
    ):
        continue

    entries.append({
        "matcher": "rate_limit",
        "hooks": [{"type": "command", "command": command}],
    })
    # Escrita atômica: um settings.json truncado deixa o perfil sem configuração
    # nenhuma, e isso só aparece na próxima vez que ele for aberto.
    tmp = settings.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(settings)
    touched.append(profile.name)

print("  registrado em: " + (", ".join(touched) if touched else "(nenhum, já estava em todos)"))
PYEOF

say "Pronto. Para desligar: EZOMAR_QUOTA_FAILOVER=off em ~/.config/ezomar/config.sh"
say "Log das trocas: ~/.local/state/ezomar/quota-failover.log"
