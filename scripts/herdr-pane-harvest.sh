#!/usr/bin/env bash
set -uo pipefail

# Colhe, do scrollback de cada pane vivo, o uuid da sessão que ele estava
# rodando, e guarda num arquivo que sobrevive ao servidor.
#
#   bash scripts/herdr-pane-harvest.sh
#
# Por que existe: quando o agente de um pane morre (OOM, crash, /exit), o herdr
# reescreve o session.json sem o agent_session daquele pane. O vínculo
# pane -> conversa some do índice, e o único lugar onde o uuid ainda aparece é o
# scrollback, que o herdr mantém em MEMÓRIA e perde em qualquer restart.
#
# Medido no takidesk em 05/09: o backup da véspera tinha 82 panes com sessão e o
# índice vivo tinha 11. Setenta e um vínculos existiam apenas na tela.
#
# O arquivo colhido é consultado por herdr-pane-session.sh depois do session.json
# e dos snapshots. Nada aqui escreve no session.json: o herdr é dono dele e
# reescreve quando quer.

DEST="${EZOMAR_PANE_HARVEST:-$HOME/.local/state/ezomar/pane-session-harvest.tsv}"

say() { echo "[ezomar][pane-harvest] $*"; }

command -v herdr >/dev/null 2>&1 || { say "herdr não está no PATH." >&2; exit 1; }
herdr pane list >/dev/null 2>&1 || { say "nenhum servidor herdr respondendo; não há scrollback para ler." >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp "${DEST}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

[ -f "$DEST" ] && cat "$DEST" >"$TMP"

FOUND=0
NEW=0
while IFS=$'\t' read -r pane_id cwd label; do
  [ -n "$pane_id" ] || continue
  # A última ocorrência é a sessão mais recente daquele pane: um pane que rodou
  # várias conversas ao longo do dia deixa todas na tela, em ordem.
  uuid="$(herdr pane read "$pane_id" --source recent-unwrapped 2>/dev/null \
    | grep -oE '(--resume|resume) +[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | tail -1)"
  [ -n "$uuid" ] || continue
  FOUND=$((FOUND + 1))
  grep -qF "	$uuid	" "$TMP" 2>/dev/null && continue
  printf '%s\t%s\t%s\t%s\n' "$pane_id" "$uuid" "$cwd" "${label:-?}" >>"$TMP"
  NEW=$((NEW + 1))
done < <(
  # O rótulo importa mais que o id: os ids de pane da API não são as chaves do
  # session.json, e quem procura depois procura pelo nome que vê na tela
  # ("datajud/tjsp"), não por "wC:pJ".
  {
    herdr workspace list 2>/dev/null
    echo "---"
    herdr tab list 2>/dev/null
    echo "---"
    herdr pane list 2>/dev/null
  } | python3 -c '
import json, sys

blocks = sys.stdin.read().split("---")
def parse(block, key):
    try:
        return json.loads(block)["result"][key]
    except Exception:
        return []

workspaces = {w.get("workspace_id") or w.get("id"): w.get("label") for w in parse(blocks[0], "workspaces")}
tabs = {t["tab_id"]: (workspaces.get(t.get("workspace_id")) or t.get("workspace_id") or "?", t.get("label") or "?")
        for t in parse(blocks[1], "tabs")}
for pane in parse(blocks[2], "panes"):
    ws, tab = tabs.get(pane.get("tab_id"), ("?", "?"))
    print("%s\t%s\t%s/%s" % (pane["pane_id"], pane.get("cwd") or "", ws, tab))
')

sort -u -o "$TMP" "$TMP"
mv "$TMP" "$DEST"
trap - EXIT

say "$FOUND pane(s) com uuid na tela; $NEW novo(s). Total guardado: $(wc -l <"$DEST")."
say "Arquivo: $DEST"
