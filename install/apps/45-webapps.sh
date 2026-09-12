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
# Também instala os que esta máquina usa e o Omarchy não traz. Eles são a mesma
# coisa que os de fábrica: um .desktop que abre o site no Chromium em modo app,
# com janela e ícone próprios. O WhatsApp daqui é assim, e o Slack passa a ser.
#
# Declarar aqui em vez de rodar `omarchy webapp install` na mão é o que faz
# sobreviver ao próximo format: senão some junto com o resto do ~/.local/share.
#
# Botões:
#   EZOMAR_REMOVE_WEBAPPS  lista separada por espaço (vazio não remove nada)
#   EZOMAR_ADD_WEBAPPS     linhas "Nome|url|icone-url", separadas por ponto e vírgula

REMOVE="${EZOMAR_REMOVE_WEBAPPS-HEY}"
# O ícone precisa de URL: passar só um nome deixa o lançador sem ícone quando o
# sistema não tem um com aquele nome, que é o caso do Slack. Os de fábrica do
# Omarchy vêm com PNG em /usr/share/icons, os nossos não.
ADD="${EZOMAR_ADD_WEBAPPS-Slack|https://app.slack.com/client|https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/slack.png}"
DESKTOP_DIR="$HOME/.local/share/applications"

say() { echo "[ezomar][webapps] $*"; }

if ! command -v omarchy >/dev/null 2>&1; then
  say "Sem o CLI 'omarchy'; os web apps são coisa dele. Pulando."
  exit 0
fi
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

# --- instalar o que falta -----------------------------------------------------
added=0
if [ -n "$ADD" ]; then
  # Ponto e vírgula separa as entradas porque URL tem barra e o nome pode ter
  # espaço; a barra vertical separa os três campos dentro de cada uma.
  # A quebra de linha no fim é obrigatória: sem ela a última (e aqui única)
  # entrada sai sem terminador, o `read` devolve falso e o laço não roda nenhuma
  # vez, em silêncio.
  printf '%s\n' "$ADD" | tr ';' '\n' | while IFS='|' read -r wname wurl wicon; do
    [ -n "${wname:-}" ] && [ -n "${wurl:-}" ] || continue
    if [ -f "$DESKTOP_DIR/$wname.desktop" ]; then
      say "$wname já instalado."
      continue
    fi
    if omarchy webapp install "$wname" "$wurl" "$wicon" >/dev/null 2>&1; then
      say "$wname instalado."
    else
      say "Não consegui instalar $wname; à mão: omarchy webapp install '$wname' '$wurl' '$wicon'" >&2
    fi
  done
fi

if [ -z "$REMOVE" ]; then
  say "Nenhum web app na lista de remoção."
  exit 0
fi

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
