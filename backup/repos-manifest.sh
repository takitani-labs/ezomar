#!/usr/bin/env bash
set -euo pipefail

# Fotografa os repos git desta máquina num TSV, que viaja dentro do tarball do
# backup-ai.sh e é lido pelo restore-repos.sh do outro lado.
#
#   bash backup/repos-manifest.sh [saída.tsv]
#
# Why the path of every repo is worth preserving to the character: the Claude
# Code conversations are indexed by the slugified ABSOLUTE path of the directory
# they happened in (~/.claude/projects/-home-opik-work-repos-...). Recloning a
# repo one directory to the left leaves its entire history orphaned under the
# old slug, silently, with no error anywhere. Same path in, same history back.
#
# O manifesto guarda o estado sujo de propósito: um repo com trabalho não
# commitado não cabe num reclone, e é melhor descobrir isso aqui, antes de
# formatar, do que do outro lado.

ROOTS=("$HOME/work/repos" "$HOME/Devel")
OUT="${1:-$HOME/.ezomar-repos-manifest.tsv}"

say() { echo "[ezomar][repos-manifest] $*"; }

: >"$OUT"
TOTAL=0
DIRTY=()
UNPUSHED=()
NOREMOTE=()

while IFS= read -r gitdir; do
  repo="$(dirname "$gitdir")"
  # Worktrees do git guardam um .git dentro do diretório administrativo do repo
  # principal; reclonar isso não faz sentido nenhum.
  # O terceiro padrão existe porque esta máquina tem um .git/.git dentro do
  # mantis: o find acha o interno, o dirname devolve ".../mantis/.git", e sem
  # ele o manifesto registra o diretório administrativo como se fosse um repo.
  case "$repo" in *--worktrees*|*/.git/*|*/.git) continue ;; esac

  rel="${repo#"$HOME"/}"
  url="$(git -C "$repo" remote get-url origin 2>/dev/null || echo '-')"
  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo '-')"

  dirty=clean
  [ -n "$(git -C "$repo" status --porcelain 2>/dev/null | head -1)" ] && { dirty=dirty; DIRTY+=("$rel"); }
  [ "$url" = "-" ] && NOREMOTE+=("$rel")
  [ -n "$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ] && UNPUSHED+=("$rel")

  printf '%s\t%s\t%s\t%s\n' "$rel" "$url" "$branch" "$dirty" >>"$OUT"
  TOTAL=$((TOTAL + 1))
done < <(find "${ROOTS[@]}" -maxdepth 4 -name .git \( -type d -o -type f \) 2>/dev/null | sort)

say "$TOTAL repos em $OUT"

# Estes três avisos são o mesmo assunto do preformat.sh, e aparecem aqui de novo
# porque o backup é a última coisa que roda antes do format: é a última chance.
report() {
  local label="$1"; shift
  [ "$#" -gt 0 ] || return 0
  say "ATENÇÃO: $# repo(s) $label:"
  printf '  - %s\n' "$@"
}
report "com mudanças não commitadas (não entram no reclone)" ${DIRTY[@]+"${DIRTY[@]}"}
report "com commits não enviados" ${UNPUSHED[@]+"${UNPUSHED[@]}"}
report "sem remote (só existem aqui)" ${NOREMOTE[@]+"${NOREMOTE[@]}"}
