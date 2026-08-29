#!/usr/bin/env bash
set -euo pipefail

# Remove os web apps que o Omarchy instala por padrão e que esta máquina não usa.
#
# Eles são atalhos .desktop que abrem um site no Chromium, e o custo de existir
# não é disco, é ruído: aparecem no menu de aplicativos, no launcher e no
# alt-tab, competindo com o que você realmente abre. O Omarchy entrega HEY,
# Basecamp, WhatsApp, X, YouTube, Zoom, Discord e os do Google.
#
# `omarchy webapp remove <nome>` aceita o nome como argumento e apaga o .desktop
# e os ícones; sem argumento ele abre um menu, que não serve numa execução
# automatizada. OMARCHY_REMOVE_NOTIFY=false evita a notificação de desktop, que
# por ssh não teria para onde ir.
#
# Botão: EZOMAR_REMOVE_WEBAPPS (lista separada por espaço; vazio não remove nada)

REMOVE="${EZOMAR_REMOVE_WEBAPPS-HEY}"
DESKTOP_DIR="$HOME/.local/share/applications"

say() { echo "[ezomar][webapps] $*"; }

if ! command -v omarchy >/dev/null 2>&1; then
  say "Sem o CLI 'omarchy'; os web apps são coisa dele. Pulando."
  exit 0
fi
if [ -z "$REMOVE" ]; then
  say "Nenhum web app na lista de remoção."
  exit 0
fi

export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
removed=0
for app in $REMOVE; do
  if [ ! -f "$DESKTOP_DIR/$app.desktop" ]; then
    say "$app já não está instalado."
    continue
  fi
  if OMARCHY_REMOVE_NOTIFY=false omarchy webapp remove "$app" >/dev/null 2>&1; then
    say "$app removido."
    removed=$((removed + 1))
  else
    say "Não consegui remover $app; à mão: omarchy webapp remove $app" >&2
  fi
done

[ "$removed" -gt 0 ] && say "$removed web app(s) removido(s)."
exit 0
