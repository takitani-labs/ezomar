#!/usr/bin/env bash
set -euo pipefail

# O session.json é o único índice da frota, e o herdr o reescreve sozinho: um
# pane cujo agente morreu (OOM, crash, /exit) perde o agent_session no próximo
# snapshot do servidor, e o vínculo com a conversa some do disco.
#
# Medido no takidesk em 05/09: o backup da véspera tinha 82 panes com sessão e o
# arquivo vivo tinha 11. As cópias de hora em hora são o que transforma isso em
# um contratempo em vez de uma perda.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
TPL="$SCRIPT_DIR/../templates/herdr-snapshot"
USER_UNITS="$HOME/.config/systemd/user"

say() { echo "[ezomar][herdr-snapshot] $*"; }

[ -d "$TPL" ] || { say "Template ausente: $TPL" >&2; exit 1; }

mkdir -p "$USER_UNITS"
for unit in ezomar-herdr-snapshot.service ezomar-herdr-snapshot.timer; do
  # ExecStart aponta para o repositório onde o ezomar realmente está, que nem
  # sempre é o caminho canônico (worktree, clone de teste, outro usuário).
  sed "s#%h/work/repos/takitani-labs/ezomar#$REPO_DIR#" "$TPL/$unit" >"$USER_UNITS/$unit"
done

systemctl --user daemon-reload
systemctl --user enable --now ezomar-herdr-snapshot.timer

say "Timer ativo: $(systemctl --user is-active ezomar-herdr-snapshot.timer)."
say "Próximo disparo: $(systemctl --user list-timers ezomar-herdr-snapshot.timer --no-pager 2>/dev/null | sed -n 2p | awk '{print $1, $2, $3}')"
