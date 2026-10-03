#!/usr/bin/env bash
set -euo pipefail

# Apaga as worktrees cujo trabalho já entrou no master, de 6 em 6 horas.
#
# Os orquestradores de agentes criam uma worktree por lane e nunca removem. Em
# 29/09/2026 eram 390 worktrees e 1,1 TB de disco; três dias depois da limpeza
# manual o mantis tinha voltado de 71 para 290. Quem as prende são processos
# esquecidos: o Codex parado no painel do herdr e o daemon do plugin do Codex
# (app-server-broker) que nunca encerra.
#
# As regras e os sinais de vida estão no topo do script. O que ele apaga vai
# para ~/work/repos/.worktree-graveyard, com o SHA de cada branch e um tarball
# dos arquivos não rastreados e ignorados (fora caches).
#
#   ezomar-worktree-janitor --dry-run     mostra o que apagaria
#   journalctl --user -u ezomar-worktree-janitor   o que cada rodada fez

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/worktree-janitor"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

say() { echo "[ezomar][worktree-janitor] $*"; }

[ -d "$TPL" ] || { say "Template ausente: $TPL" >&2; exit 1; }

install -D -m 0755 "$TPL/ezomar-worktree-janitor" "$BIN_DIR/ezomar-worktree-janitor"
for unit in ezomar-worktree-janitor.service ezomar-worktree-janitor.timer ezomar-worktree-janitor-failure.service; do
  install -D -m 0644 "$TPL/$unit" "$UNIT_DIR/$unit"
done

systemctl --user daemon-reload
systemctl --user enable --now ezomar-worktree-janitor.timer >/dev/null 2>&1 || true

say "Timer: $(systemctl --user is-active ezomar-worktree-janitor.timer 2>/dev/null || echo inativo)."
say "Prévia sem apagar nada: ezomar-worktree-janitor --dry-run"
