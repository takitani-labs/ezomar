#!/usr/bin/env bash
set -euo pipefail

# "Os repos mudaram de lugar" — religa as três coisas que guardam caminho
# absoluto e quebram caladas quando ele muda.
#
#   bash backup/rebind.sh            ensaio das conversas, resto intocado
#   bash backup/rebind.sh --apply    aplica os três
#
#   1. conversas do Claude Code   ~/.claude/projects, indexado por caminho
#   2. banco do zoxide            o z leva para diretórios que não existem mais
#   3. trust do mise              é chaveado por caminho, e sem ele todo repo
#                                 movido volta a pedir confirmação
#
# As conversas são o único item destrutivo (renomeia diretórios), e por isso são
# as únicas que rodam em ensaio por padrão.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPLY="${1:-}"
ROOTS=("$HOME/work/repos" "$HOME/Devel")

say() { echo "[ezomar][rebind] $*"; }

say "== conversas do Claude Code =="
bash "$SCRIPT_DIR/rebind-conversations.sh" ${APPLY:+"$APPLY"}

if [ "$APPLY" != "--apply" ]; then
  say ""
  say "zoxide e mise não foram tocados. Para fazer tudo: bash backup/rebind.sh --apply"
  exit 0
fi

echo
say "== zoxide =="
bash "$SCRIPT_DIR/rebind-zoxide.sh"

echo
say "== mise trust =="
if command -v mise >/dev/null 2>&1; then
  COUNT=0
  while IFS= read -r f; do
    mise trust "$f" >/dev/null 2>&1 && COUNT=$((COUNT + 1))
  done < <(
    find "${ROOTS[@]}" -maxdepth 5 \
      \( -name mise.toml -o -name .mise.toml -o -name .tool-versions \) \
      -not -path '*--worktrees*' 2>/dev/null
  )
  say "$COUNT configuração(ões) do mise trustada(s)."
else
  say "mise não instalado; pulando."
fi
