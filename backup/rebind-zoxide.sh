#!/usr/bin/env bash
set -euo pipefail

# Conserta o banco do zoxide depois que repos mudam de lugar.
#
#   bash backup/rebind-zoxide.sh
#
# O z guarda caminhos absolutos com um peso de uso. Depois de mover repos (ou de
# restaurar numa máquina nova) metade das entradas aponta para lugar nenhum, e o
# `z <nome>` leva para um diretório que não existe. Entradas mortas com destino
# único são remapeadas com um peso aproximado; sem destino único, some, porque o
# z reaprende com o uso e um palpite errado é pior do que nada.

command -v zoxide >/dev/null 2>&1 || { echo "[ezomar][rebind-zoxide] zoxide não instalado; pulando."; exit 0; }

ROOTS=("$HOME/work/repos" "$HOME/Devel")
say() { echo "[ezomar][rebind-zoxide] $*"; }

REMAPPED=0; DROPPED=0
while read -r score path; do
  [ -n "${path:-}" ] || continue
  [ -d "$path" ] && continue

  base="$(basename "$path")"
  mapfile -t cand < <(find "${ROOTS[@]}" -maxdepth 4 -type d -name "$base" 2>/dev/null | grep -v -- '--worktrees' | sort -u)

  zoxide remove "$path" 2>/dev/null || true
  if [ ${#cand[@]} -eq 1 ]; then
    # O zoxide não deixa escrever o peso, só somar visitas; dez é o teto que
    # aproxima bem sem gastar tempo à toa.
    n="$(printf '%.0f' "$score")"
    [ "$n" -gt 10 ] && n=10
    [ "$n" -lt 1 ] && n=1
    for _ in $(seq 1 "$n"); do zoxide add "${cand[0]}"; done
    say "  $path => ${cand[0]} (peso $n)"
    REMAPPED=$((REMAPPED + 1))
  else
    say "  $path removido (${#cand[@]} candidatos)"
    DROPPED=$((DROPPED + 1))
  fi
done < <(zoxide query --list --score 2>/dev/null || true)

# O grosso do valor está aqui: o zoxide esconde entradas mortas do `query
# --list`, então remapear sozinho não bastaria. Semear os repos atuais garante
# que `z <nome>` resolve desde o primeiro uso na máquina nova.
SEEDED=0
while IFS= read -r repo; do
  zoxide add "$repo"
  SEEDED=$((SEEDED + 1))
done < <(
  find "${ROOTS[@]}" -maxdepth 4 -name .git \( -type d -o -type f \) -prune 2>/dev/null \
    | sed 's|/\.git$||' | grep -v -- '--worktrees' | sort -u
)

say "$REMAPPED remapeado(s), $DROPPED removido(s), $SEEDED repo(s) semeado(s)."
say "O ranking fino o z reaprende com o uso."
