#!/usr/bin/env bash
set -uo pipefail

# Reclona, na máquina nova, os repos do manifesto gerado antes do format, cada
# um no mesmo caminho de antes.
#
#   bash backup/restore-repos.sh [manifesto.tsv]
#
# Sem -e de propósito: um repo que falha (rede, acesso revogado, remote que
# mudou de dono) não pode derrubar o resto da lista. As falhas são coletadas e
# impressas no fim, e rodar de novo é seguro, porque o que já existe é pulado.
#
# Pré-requisito: uma chave SSH que o GitHub/GitLab aceite. Numa máquina recém
# formatada ela vem do repo de dotfiles, que por sua vez precisa da chave age,
# então este script roda depois do install.sh, não antes.

say() { echo "[ezomar][restore-repos] $*"; }

MANIFEST="${1:-}"
if [ -z "$MANIFEST" ]; then
  for c in "$HOME/.ezomar-repos-manifest.tsv" "$HOME/.ezarch-repos-manifest.tsv"; do
    [ -f "$c" ] && { MANIFEST="$c"; break; }
  done
fi
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || {
  echo "[ezomar][restore-repos] manifesto não encontrado (procurei ~/.ezomar-repos-manifest.tsv)." >&2
  echo "[ezomar][restore-repos] ele vem dentro do tarball; rode o restore-ai.sh antes." >&2
  exit 1
}
say "Manifesto: $MANIFEST"

OK=0; SKIP=0; DIRTY_LOST=0
FAIL=()

while IFS=$'\t' read -r rel url branch dirty; do
  [ -n "${rel:-}" ] || continue
  dest="$HOME/$rel"

  if [ -e "$dest/.git" ]; then
    SKIP=$((SKIP + 1))
    continue
  fi
  if [ "${url:-}" = "-" ] || [ -z "${url:-}" ]; then
    say "  ~ $rel: sem remote, não há de onde clonar"
    SKIP=$((SKIP + 1))
    continue
  fi

  mkdir -p "$(dirname "$dest")"
  if git clone --quiet "$url" "$dest" 2>/dev/null; then
    [ "${branch:-}" != "-" ] && git -C "$dest" checkout --quiet "$branch" 2>/dev/null
    OK=$((OK + 1))
    # O manifesto lembra o que estava sujo lá atrás; o clone traz só o que foi
    # commitado, então vale dizer em voz alta o que não voltou.
    [ "${dirty:-}" = "dirty" ] && { say "  + $rel (tinha trabalho não commitado, que NÃO voltou)"; DIRTY_LOST=$((DIRTY_LOST + 1)); }
  else
    FAIL+=("$rel")
  fi
done <"$MANIFEST"

say "clonados: $OK | já existiam ou sem remote: $SKIP | falhas: ${#FAIL[@]}"
[ "$DIRTY_LOST" -gt 0 ] && say "$DIRTY_LOST deles tinham mudanças locais na máquina antiga."
if [ ${#FAIL[@]} -gt 0 ]; then
  printf '  falhou: %s\n' "${FAIL[@]}"
  say "Autenticação? Configure a chave SSH e rode de novo; é idempotente."
  exit 1
fi
say "As conversas do Claude Code religam sozinhas: mesmo caminho, mesmo histórico."
