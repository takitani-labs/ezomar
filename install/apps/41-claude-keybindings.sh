#!/usr/bin/env bash
set -euo pipefail

# Keymap compartilhado do Claude Code.
#
# O Claude Code resolve keybindings.json dentro do CLAUDE_CONFIG_DIR, então um
# arquivo só em ~/.claude não vale para nenhum perfil. O módulo escreve o
# arquivo compartilhado e aponta um symlink de cada perfil para ele, igual ao
# que os perfis já fazem com projects/ e commands/.
#
# O que ele amarra, e por que precisa: o painel de diff (a barra lateral que
# mostra a árvore de trabalho ao lado da conversa) alterna pela action
# app:toggleReplTab, que não vem com tecla nenhuma (conferido na 2.1.260, cujo
# keymap padrão cobre ctrl+t, ctrl+o, ctrl+shift+b, ctrl+r, ctrl+up/down e
# ctrl+]). De fábrica a única entrada é o comando /diff. O ctrl+x d entra numa
# família de chords que já existe em vez de inventar outra: ctrl+x b cicla a
# base do diff e ctrl+x ctrl+e abre o editor externo. E fica longe do ctrl+b,
# que é o prefixo do herdr.
#
# Os diretórios de perfil pertencem ao chezmoi; aqui só criamos o symlink nos
# que já existem. Um perfil com keybindings.json próprio é preservado.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/claude/keybindings.json"
SHARED="$HOME/.claude/keybindings.json"
PROFILES_DIR="$HOME/.claude-profiles"

say() { echo "[ezomar][claude-keybindings] $*"; }

if [ ! -f "$TPL" ]; then
  say "Template ausente: $TPL. Pulando."
  exit 0
fi

mkdir -p "$HOME/.claude"
install -m 0644 "$TPL" "$SHARED"
say "Keymap compartilhado: $SHARED"

[ -d "$PROFILES_DIR" ] || { say "Sem ~/.claude-profiles; nada a linkar."; exit 0; }

for dir in "$PROFILES_DIR"/*/; do
  [ -d "$dir" ] || continue
  profile="$(basename "$dir")"
  target="$dir/keybindings.json"
  if [ -L "$target" ]; then
    ln -sfn "$SHARED" "$target"
  elif [ -e "$target" ]; then
    say "Perfil com keymap próprio, preservado: $target"
    continue
  else
    ln -s "$SHARED" "$target"
  fi
  say "Linkado: $profile"
done

say "Pronto. Vale nas sessões abertas a partir de agora."
