#!/usr/bin/env bash
set -euo pipefail

# Torna o zsh o shell de login.
#
# Instalar o zsh não basta: o Omarchy deixa o usuário no bash, então o .zshrc de
# 591 linhas que o chezmoi entrega nunca carrega e nenhum dos helpers de cofre
# (bws, ops, bw-exec) existe. A máquina parece configurada e se comporta como se
# não estivesse.
#
# POR QUE ESTE MÓDULO É 35 E NÃO 05, que é onde ele nasceu: trocar o shell antes
# do chezmoi (30) abre uma janela em que o zsh é o shell de login e não existe
# nenhum arquivo de inicialização dele. Se a execução falhar no meio dessa janela
# (o 20 depende de um login interativo no Bitwarden, e sem ele o 30 não roda), o
# próximo login cai no `zsh-newuser-install`, o assistente de usuário novo do
# zsh, perguntando se você quer configurar histórico e keybindings. Medido numa
# VM em que o cofre não existia. O `chsh` só vale no próximo login de qualquer
# forma, então adiantá-lo não comprava nada e custava isto.
#
# Pela mesma razão o módulo se recusa a trocar o shell quando não há arquivo de
# inicialização nenhum: é melhor deixar a máquina no bash, que é o estado em que
# ela já estava, do que entregá-la num zsh pelado.

ZSH_BIN="$(command -v zsh || true)"
if [ -z "$ZSH_BIN" ]; then
  echo "[ezomar][shell] zsh não encontrado. O módulo 00-packages deveria ter instalado." >&2
  exit 1
fi

CURRENT="$(getent passwd "$USER" | cut -d: -f7)"
if [ "$CURRENT" = "$ZSH_BIN" ]; then
  echo "[ezomar][shell] Já é $ZSH_BIN. Nada a fazer."
  exit 0
fi

# Qualquer um destes basta para o zsh não achar que é a primeira vez.
HAS_RC=false
for f in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile"; do
  [ -e "$f" ] && { HAS_RC=true; break; }
done
if [ "$HAS_RC" = false ]; then
  echo "[ezomar][shell] Sem ~/.zshrc: o chezmoi (módulo 30) não entregou os dotfiles."
  echo "[ezomar][shell] Deixando o shell em $CURRENT. Trocar agora daria um zsh pelado,"
  echo "[ezomar][shell] com o assistente zsh-newuser-install a cada login."
  echo "[ezomar][shell] Rode este módulo de novo depois que o chezmoi aplicar:"
  echo "[ezomar][shell]   bash install/apps/35-shell.sh"
  exit 0
fi

grep -qxF "$ZSH_BIN" /etc/shells || echo "$ZSH_BIN" | sudo tee -a /etc/shells >/dev/null

echo "[ezomar][shell] Trocando shell de $CURRENT para $ZSH_BIN"
sudo chsh -s "$ZSH_BIN" "$USER"
echo "[ezomar][shell] Vale a partir do próximo login."
