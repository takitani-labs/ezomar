#!/usr/bin/env bash
set -euo pipefail

# Atalho para abrir o hachi sempre compilado do código atual.
#
# O binário compilado envelhece sem avisar, e rodar uma versão velha custa caro:
# você depura um comportamento que já consertou. O lançador deixa o cargo
# decidir o que refazer, então quando nada mudou ele abre na hora.
#
# Instala o comando `hachi-dev` e uma entrada de menu que o chama, para o app
# aparecer no launcher do Omarchy como qualquer outro.
#
# Instala tambem o `hachi-secrets-from-pgpass` e o roda. O hachi guarda as senhas
# no cofre do sistema, e cofre nao viaja entre ambientes: o que o KDE gravou no
# kwallet o gnome-keyring do Hyprland nao le. Depois de migrar, as conexoes
# aparecem na lista e falham com "invalid configuration", que parece config
# corrompida e e so senha ausente. O ~/.pgpass viaja no backup e tem as senhas.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/hachi-launcher"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
REPO="${HACHI_REPO:-$HOME/work/repos/takitani-labs/hachi}"

say() { echo "[ezomar][hachi] $*"; }

for f in hachi-dev hachi-dev.desktop hachi-secrets-from-pgpass; do
  [ -f "$TPL/$f" ] || { say "Template ausente: $TPL/$f" >&2; exit 1; }
done

if [ ! -d "$REPO" ]; then
  say "Repositório do hachi não está em $REPO; instalando o lançador mesmo assim."
  say "Ele avisa na tela se o caminho não existir na hora de abrir."
fi

install -D -m 0755 "$TPL/hachi-dev" "$BIN_DIR/hachi-dev"
install -D -m 0755 "$TPL/hachi-secrets-from-pgpass" "$BIN_DIR/hachi-secrets-from-pgpass"
install -D -m 0644 "$TPL/hachi-dev.desktop" "$APPS_DIR/hachi-dev.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true

say "Instalado: $BIN_DIR/hachi-dev e entrada de menu."

# So roda quando ja existe binario: numa maquina recem formatada o hachi ainda
# nao foi compilado, e ai o passo nao tem o que fazer. Falha aqui nao derruba a
# instalacao, porque o cofre e recuperavel depois com um comando.
if [ -f "$HOME/.pgpass" ]; then
  "$BIN_DIR/hachi-secrets-from-pgpass" || \
    say "Cofre nao repovoado agora; rode hachi-secrets-from-pgpass depois de compilar."
else
  say "Sem ~/.pgpass; rode hachi-secrets-from-pgpass quando ele estiver restaurado."
fi

say "Para um atalho de teclado, acrescente ao ~/.config/hypr/bindings.lua:"
say '  o.bind("SUPER + SHIFT + H", "Hachi (compila e abre)", "hachi-dev")'
