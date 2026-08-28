#!/usr/bin/env bash
set -euo pipefail

# Religa as conversas do Claude Code depois que repos mudam de lugar.
#
#   bash backup/rebind-conversations.sh            mostra o que faria
#   bash backup/rebind-conversations.sh --apply    renomeia de verdade
#
# O Claude Code indexa conversas pelo caminho absoluto do diretório, com todo
# caractere não alfanumérico virando '-', em ~/.claude/projects/. Mover um repo
# de pasta deixa o histórico órfão no slug antigo: nada quebra, nada avisa, a
# conversa simplesmente não existe mais para quem abre o repo no lugar novo.
#
# Isto acontece no format com mais força do que no dia a dia, porque a máquina
# nova pode reconstruir a árvore em outro caminho (~/Devel virou ~/work/repos
# nesta máquina, e foi assim que o problema apareceu). O restore-repos.sh
# reclona nos caminhos originais justamente para não precisar disto; este script
# é a saída para quando o caminho mudou mesmo assim.
#
# O casamento é por basename e só age quando é único: dois repos de mesmo nome
# em pastas diferentes viram um aviso, não um palpite.

APPLY="${1:-}"
PROJECTS="$HOME/.claude/projects"
ROOTS=("$HOME/work/repos" "$HOME/Devel")

say() { echo "[ezomar][rebind-conversations] $*"; }

[ -d "$PROJECTS" ] || { say "$PROJECTS não existe; nada a religar."; exit 0; }

encode() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

mapfile -t REPOS < <(
  find "${ROOTS[@]}" -maxdepth 4 -name .git \( -type d -o -type f \) -prune 2>/dev/null \
    | sed 's|/\.git$||' | grep -v -- '--worktrees' | sort -u
)
[ ${#REPOS[@]} -gt 0 ] || { say "nenhum repo encontrado em ${ROOTS[*]}."; exit 0; }

# Slug vivo: o de um repo que existe, ou o de um subdiretório dele.
declare -A LIVE=()
for r in "${REPOS[@]}"; do LIVE["$(encode "$r")"]="$r"; done

is_live() {
  local s="$1" enc
  [ -n "${LIVE[$s]:-}" ] && return 0
  for enc in "${!LIVE[@]}"; do
    case "$s" in "$enc"-*) return 0 ;; esac
  done
  return 1
}

mapfile -t SLUGS < <(ls -1 "$PROJECTS" 2>/dev/null || true)
declare -A RENAME=()
AMBIGUOUS=()

# Passo 1: órfãos que são a raiz de um repo, casados por basename.
for s in ${SLUGS[@]+"${SLUGS[@]}"}; do
  is_live "$s" && continue
  matches=()
  for r in "${REPOS[@]}"; do
    b="$(encode "$(basename "$r")")"
    case "$s" in *-"$b") matches+=("$r") ;; esac
  done
  if [ ${#matches[@]} -eq 1 ]; then
    RENAME["$s"]="$(encode "${matches[0]}")"
  elif [ ${#matches[@]} -gt 1 ]; then
    AMBIGUOUS+=("$s -> ${matches[*]}")
  fi
done

# Passo 2: órfãos de subdiretório herdam o destino do prefixo já resolvido.
for s in ${SLUGS[@]+"${SLUGS[@]}"}; do
  is_live "$s" && continue
  [ -n "${RENAME[$s]:-}" ] && continue
  for old in "${!RENAME[@]}"; do
    case "$s" in "$old"-*) RENAME["$s"]="${RENAME[$old]}${s#"$old"}"; break ;; esac
  done
done

if [ ${#AMBIGUOUS[@]} -gt 0 ]; then
  say "Ambíguos (dois repos com o mesmo nome); resolva à mão:"
  printf '  ?? %s\n' "${AMBIGUOUS[@]}"
fi

if [ ${#RENAME[@]} -eq 0 ]; then
  say "Nada a religar: todo slug aponta para um caminho que existe."
  exit 0
fi

MOVED=0
for old in "${!RENAME[@]}"; do
  new="${RENAME[$old]}"
  sessions="$(find "$PROJECTS/$old" -maxdepth 1 -name '*.jsonl' 2>/dev/null | wc -l)"
  say "$old"
  say "  => $new  ($sessions sessões)"
  [ "$APPLY" = "--apply" ] || continue
  if [ -e "$PROJECTS/$new" ]; then
    # Destino já existe: junta o conteúdo em vez de sobrescrever, porque as duas
    # pastas são histórias do mesmo repo, feitas antes e depois da mudança.
    mv "$PROJECTS/$old"/* "$PROJECTS/$new"/ 2>/dev/null || true
    rmdir "$PROJECTS/$old" 2>/dev/null || say "  (sobrou coisa em $old, confira)"
    say "  juntado"
  else
    mv "$PROJECTS/$old" "$PROJECTS/$new"
    say "  renomeado"
  fi
  MOVED=$((MOVED + 1))
done

if [ "$APPLY" = "--apply" ]; then
  say "$MOVED slug(s) religado(s)."
else
  say "Isto foi um ensaio. Para efetivar: bash backup/rebind-conversations.sh --apply"
fi
