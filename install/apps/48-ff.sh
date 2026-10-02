#!/usr/bin/env bash
set -euo pipefail

# Instala o ff, a busca de arquivos estilo Everything: plocate para o disco
# inteiro na hora, fd ao vivo para o que nasceu depois da indexação do dia, fzf
# por cima, e Enter mostra o arquivo na pasta.
#
# Ele existia na máquina Fedora só como arquivo solto em ~/.local/bin, sem
# repositório nenhum, e depois do format só foi achado no espelho do kage. A
# busca do Flea não substitui: varre a home ao vivo a cada busca (18s aqui) e
# não aceita colar na linha de busca. Por isso o ff mora aqui agora.
#
# O atalho (Super+Shift+Espaço) e a regra de janela flutuante ficam no
# bindings.lua, que vem do chezmoi. Este módulo instala o script e o .desktop,
# que deixa o ff achável no lançador do Omarchy (Super+Espaço) por "busca",
# "arquivo", "everything".
#
# As dependências (plocate, fd, fzf) já vêm na base do Omarchy, e o timer do
# updatedb é dele também.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/ff"

say() { echo "[ezomar][ff] $*"; }

for dep in plocate fd fzf busctl; do
  command -v "$dep" >/dev/null 2>&1 || say "Aviso: $dep ausente; o ff depende dele." >&2
done

install -D -m 0755 "$TPL/ff" "$HOME/.local/bin/ff"
install -D -m 0644 "$TPL/ff.desktop" "$HOME/.local/share/applications/ff.desktop"
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# Sem timer ativo o índice congela no dia da instalação e a busca passa a depender
# só da camada ao vivo, que cobre a home e não o disco.
if ! systemctl is-active -q plocate-updatedb.timer 2>/dev/null; then
  say "Aviso: plocate-updatedb.timer não está ativo; o índice não se atualiza." >&2
  say "  sudo systemctl enable --now plocate-updatedb.timer" >&2
fi

say "ff instalado: Super+Shift+Espaço, o lançador, ou \`ff termo\` num terminal."
