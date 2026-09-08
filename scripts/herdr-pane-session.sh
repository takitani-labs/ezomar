#!/usr/bin/env bash
set -uo pipefail

# Diz qual sessão do Claude pertence a cada pane, e monta o comando de retomada.
#
#   bash scripts/herdr-pane-session.sh              todos os panes
#   bash scripts/herdr-pane-session.sh tjsp         só os que casam com o texto
#   bash scripts/herdr-pane-session.sh --here       o pane onde o comando roda
#   bash scripts/herdr-pane-session.sh --resume     idem, e já retoma a conversa
#
# O modo --here existe porque a pergunta real nunca é "quais panes existem": é
# "eu estou olhando para um pane vazio, o que rodava AQUI". O herdr exporta
# HERDR_PANE_ID e HERDR_TAB_ID no ambiente de cada pane, então o pane sabe quem
# é e não há nada para o humano digitar nem adivinhar.
#
# Por que existe: o herdr guarda o scrollback na MEMÓRIA do servidor, nunca em
# disco. Então o histórico do pane, onde o `claude --resume <uuid>` ficava
# visível para rolar e copiar, morre em qualquer restart e não viaja em backup
# nenhum. Numa máquina restaurada os panes voltam nos diretórios certos e com a
# tela limpa, e uma sessão derrubada pelo OOM vira uma sessão sem volta.
#
# O uuid, porém, nunca dependeu do scrollback: ele está no session.json. O
# problema é que o herdr REESCREVE esse arquivo quando um pane fica sem agente
# vivo, apagando justamente o vínculo que se quer recuperar. Por isso aqui se
# olha o arquivo atual e, para o que já sumiu dele, os snapshots por ordem de
# recência.

MODE="${1:-}"
if [ "$MODE" = "--here" ] || [ "$MODE" = "--resume" ]; then
  [ -n "${HERDR_TAB_ID:-}" ] || {
    echo "[ezomar][pane-session] Este comando só funciona dentro de um pane do herdr." >&2
    exit 1
  }
  # O rótulo da aba é o que casa com o que foi colhido; o id não serve, porque
  # os ids da API mudam a cada sessão do servidor.
  LABEL="$(herdr tab list 2>/dev/null | python3 -c '
import json, os, sys
want = os.environ.get("HERDR_TAB_ID")
try:
    for t in json.load(sys.stdin)["result"]["tabs"]:
        if t.get("tab_id") == want:
            print(t.get("label") or "")
            break
except Exception:
    pass
')"
  [ -n "$LABEL" ] || {
    echo "[ezomar][pane-session] Não consegui descobrir o nome desta aba." >&2
    exit 1
  }
  set -- "$LABEL"
fi

SESSION="$HOME/.config/herdr/session.json"
SNAPSHOTS="$HOME/.config/herdr/session-snapshots"
PROFILE_MAP="${CLAUDE_SESSION_PROFILE_CACHE:-$HOME/.local/state/claude-session-profile.tsv}"
HARVEST="${EZOMAR_PANE_HARVEST:-$HOME/.local/state/ezomar/pane-session-harvest.tsv}"

[ -s "$SESSION" ] || { echo "[ezomar][pane-session] $SESSION ausente." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[ezomar][pane-session] python3 ausente." >&2; exit 1; }

# No --resume o script vira uma coisa so: descobre e executa. Imprimir um
# comando para a pessoa copiar e colar dentro do mesmo terminal onde ela ja
# esta seria trabalho a toa.
ONLY_CMD=false
[ "$MODE" = "--resume" ] && ONLY_CMD=true

OUT="$(SESSION="$SESSION" SNAPSHOTS="$SNAPSHOTS" PROFILE_MAP="$PROFILE_MAP" HARVEST="$HARVEST" \
  ONLY_CMD="$ONLY_CMD" python3 - "${1:-}" <<'PYEOF'
import glob
import json
import os
import sys

FILTER = (sys.argv[1] if len(sys.argv) > 1 else "").lower()
ONLY_CMD = os.environ.get("ONLY_CMD") == "true"
SESSION = os.environ["SESSION"]
SNAPSHOTS = os.environ["SNAPSHOTS"]
PROFILE_MAP = os.environ["PROFILE_MAP"]
HARVEST = os.environ["HARVEST"]
HOME = os.path.expanduser("~")


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def walk(doc):
    """(chave estável, rótulo, cwd, uuid ou None) por pane."""
    for ws in (doc or {}).get("workspaces") or []:
        ws_name = ws.get("custom_name") or ws.get("id") or "?"
        for tab in ws.get("tabs") or []:
            tab_name = tab.get("custom_name") or "?"
            for pane_key, pane in (tab.get("panes") or {}).items():
                if not isinstance(pane, dict):
                    continue
                agent = pane.get("agent_session") or {}
                key = (ws.get("id") or ws_name, tab_name, str(pane_key))
                yield key, f"{ws_name}/{tab_name}", pane.get("cwd") or "?", agent.get("value")


profiles = {}
if os.path.exists(PROFILE_MAP):
    for line in open(PROFILE_MAP, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            profiles[parts[0]] = parts[1]

current = load(SESSION)
rows = {}
for key, label, cwd, uuid in walk(current):
    rows[key] = [label, cwd, uuid, "atual" if uuid else ""]

# Para os panes que perderam o vínculo, procurar nos snapshots do mais novo para
# o mais antigo e parar no primeiro que ainda tinha o uuid.
missing = [k for k, v in rows.items() if not v[2]]
if missing and os.path.isdir(SNAPSHOTS):
    for snap in sorted(glob.glob(os.path.join(SNAPSHOTS, "session.json.*")), reverse=True):
        if not missing:
            break
        doc = load(snap)
        stamp = os.path.basename(snap).replace("session.json.", "")
        for key, _label, _cwd, uuid in walk(doc):
            if uuid and key in rows and not rows[key][2]:
                rows[key][2] = uuid
                rows[key][3] = f"snapshot {stamp}"
        missing = [k for k, v in rows.items() if not v[2]]

# O que foi colhido da tela entra como fonte própria, não como complemento do
# índice: os ids de pane da API não são as chaves do session.json, então não há
# como casar linha a linha. O que se casa é o rótulo que a pessoa lê ("datajud/
# tjsp"), e por isso essas entradas aparecem inteiras, com a marca de onde vieram.
harvested = []
if os.path.exists(HARVEST):
    known = {v[2] for v in rows.values() if v[2]}
    for line in open(HARVEST, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 3 or parts[1] in known:
            continue
        label = parts[3] if len(parts) > 3 and parts[3] != "?" else parts[0]
        harvested.append((label, parts[2], parts[1], "colhido da tela"))


def matches(label, cwd, uuid):
    return not FILTER or FILTER in f"{label} {cwd} {uuid or ''}".lower()


# Ordem de confianca, e ela importa porque --resume usa a PRIMEIRA linha: o
# indice vivo sabe o que roda agora, o snapshot sabe o que rodava ha pouco, e a
# colheita e memoria de tela, util so para o que os dois ja esqueceram. Antes a
# colheita vinha na frente e podia responder por um pane que o indice conhecia.
selected = []
for key, (label, cwd, uuid, origin) in rows.items():
    if not matches(label, cwd, uuid):
        continue
    selected.append((label, cwd, uuid, origin))
selected.sort(key=lambda r: 0 if r[3] == "atual" else 1)
selected += [row for row in harvested if matches(row[0], row[1], row[2])]

if not selected:
    print("[ezomar][pane-session] Nenhum pane bate com o filtro.")
    sys.exit(0)

# Confianca primeiro, nome depois. Uma ordenacao puramente alfabetica aqui
# desfazia a prioridade montada acima, e como --resume pega a primeira linha,
# bastava o nome da aba comecar com letra menor para a colheita ganhar do
# indice.
selected.sort(key=lambda r: (0 if r[3] == "atual" else 1 if str(r[3]).startswith("snapshot") else 2, r[0]))
width = max(len(r[0]) for r in selected)
lost = 0
for label, cwd, uuid, origin in selected:
    short = cwd.replace(HOME, "~")
    if not uuid:
        lost += 1
        print(f"  {label.ljust(width)}  {short}")
        print(f"  {''.ljust(width)}  sem sessão registrada nem em snapshot")
        continue
    profile = profiles.get(uuid)
    cmd = f"claude --resume {uuid}"
    if profile:
        cmd = f"CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/{profile} {cmd}"
    if ONLY_CMD:
        # So a primeira, e crua: quem consome e o shell, nao um humano.
        print(f'cd "{cwd}" && {cmd}')
        break
    print(f"  {label.ljust(width)}  {short}  [{origin}]")
    print(f"  {''.ljust(width)}  cd {short} && {cmd}")

if lost:
    print()
    print(f"[ezomar][pane-session] {lost} pane(s) sem uuid recuperável.")
    if not os.path.isdir(SNAPSHOTS):
        print("[ezomar][pane-session] Não há snapshots. Ligue o timer:")
        print("[ezomar][pane-session]   systemctl --user enable --now ezomar-herdr-snapshot.timer")
PYEOF
)"

if [ "$ONLY_CMD" != true ]; then
  printf '%s\n' "$OUT"
  exit 0
fi

CMD="$(printf '%s\n' "$OUT" | grep -m1 '^cd ' || true)"
if [ -z "$CMD" ]; then
  echo "[ezomar][pane-session] Nenhuma sessao conhecida para esta aba." >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi

echo "[ezomar][pane-session] Retomando: $CMD"
eval "$CMD"
