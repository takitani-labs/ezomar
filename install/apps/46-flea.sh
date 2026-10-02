#!/usr/bin/env bash
set -euo pipefail

# Instala o Flea (github.com/thisisgm/flea) e o torna o gerenciador de arquivos
# padrão: pastas, "mostrar na pasta", diálogos de abrir/salvar e o Super+Shift+F.
#
# O pacote é o flea-bin do AUR, que baixa o binário da release do GitHub e fixa
# o sha256 dela (conferido na v0.3.7 contra o digest do asset, publicado pelo
# GitHub Actions do repo). NÃO é o `flea` do repositório do Omarchy, por
# escolha: aquele chega um dia ou mais depois da release, e em 01/10/2026 o
# 0.3.4-1 dele veio quebrado (abaixo). Os dois conflitam, e o pacman não troca
# um pelo outro sem perguntar, então a troca é manual (`yay -S flea-bin`).
#
# Quem configura o padrão é o próprio `flea --default`, e
# não este módulo, porque são quatro lugares e o Flea sabe desfazer todos
# (`flea --default off`):
#
#   ~/.config/mimeapps.list                    inode/directory
#   ~/.local/share/dbus-1/services/...FileManager1.service
#   ~/.config/hypr/bindings.lua                bloco entre marcadores
#   ~/.config/xdg-desktop-portal/portals.conf  FileChooser
#
# Roda depois do 30-chezmoi de propósito. O bindings.lua vem do chezmoi já com o
# bloco do Flea; se este módulo rodasse antes, o Flea escreveria no arquivo
# padrão do Omarchy e o chezmoi apply depois sobrescreveria por cima. Rodar de
# novo é seguro: o Flea troca o bloco entre os marcadores, não duplica (medido).
#
# O portal só lê o portals.conf ao subir. Fora de um terminal o próprio Flea não
# o reinicia, então este módulo faz isso, com try-restart para não subir um
# portal que não estava rodando.
#
# Botão:
#   EZOMAR_FLEA_DEFAULT=false   instala o Flea mas mantém o Nautilus como padrão

say() { echo "[ezomar][flea] $*"; }

install_flea_bin() {
  local helper
  if command -v omarchy >/dev/null 2>&1 && omarchy pkg aur add flea-bin; then
    return 0
  fi
  for helper in yay paru; do
    if command -v "$helper" >/dev/null 2>&1 \
      && "$helper" -S --needed --noconfirm flea-bin; then
      return 0
    fi
  done
  return 1
}

if pacman -Qq flea-bin >/dev/null 2>&1 || pacman -Qq flea-git >/dev/null 2>&1; then
  :
elif pacman -Qq flea >/dev/null 2>&1; then
  # --noconfirm responde "não" ao "Remove flea?" do pacman, então nem o
  # `omarchy pkg aur add` nem o yay automático fazem essa troca.
  say "O flea instalado é o do repositório do Omarchy. Troque pela release do GitHub:" >&2
  say "  yay -S flea-bin    (responda y quando o pacman pedir para remover o flea)" >&2
  exit 1
elif ! install_flea_bin; then
  say "Não consegui instalar o flea-bin pelo AUR; rode: yay -S flea-bin" >&2
  exit 1
fi

if [ "${EZOMAR_FLEA_DEFAULT:-true}" = false ]; then
  say "Desligado por EZOMAR_FLEA_DEFAULT; o padrão continua o do Omarchy."
  exit 0
fi

# Não promove um Flea que não abre. O pacote 0.3.4-1 do Omarchy saiu sem a pasta
# ui/boot, de onde o binário sobe a interface (thisisgm/flea#216, corrigido no
# 0.3.5): o Flea instalava, o `flea --default` passava, e todo clique depois
# falhava com "the shell config is missing". Em 01/10/2026 isso derrubou a
# janela de anexar arquivo do Chrome, porque o portal passou a chamar o Flea.
# Falhar aqui deixa o Nautilus no lugar e põe o módulo na lista de falhas.
if [ ! -e /usr/share/flea/ui/boot/shell.qml ]; then
  say "O Flea instalado não traz ui/boot/shell.qml e não abre ($(pacman -Q flea 2>/dev/null))." >&2
  say "Atualize (omarchy update) antes de torná-lo padrão; o Nautilus continua." >&2
  exit 1
fi

if [ "$(xdg-mime query default inode/directory 2>/dev/null)" = com.thisisgm.flea.desktop ] \
  && grep -qs 'flea' "$HOME/.config/xdg-desktop-portal/portals.conf"; then
  say "Flea já é o padrão."
  exit 0
fi

# O `flea --default` recarrega o Hyprland, e o hyprctl precisa saber qual
# instância. Num pane do herdr essa variável não vem do ambiente.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && [ -d "/run/user/$(id -u)/hypr" ]; then
  HYPRLAND_INSTANCE_SIGNATURE="$(find "/run/user/$(id -u)/hypr" -mindepth 1 -maxdepth 1 \
    -printf '%T@ %f\n' | sort -rn | awk 'NR==1{print $2}')"
  export HYPRLAND_INSTANCE_SIGNATURE
fi

flea --default
systemctl --user try-restart xdg-desktop-portal.service 2>/dev/null || true
say "Flea é o padrão agora. Para voltar: flea --default off"
