#!/usr/bin/env bash
set -euo pipefail

# O delta de pacotes. Todo módulo que precisa de pacote lista aqui; nenhum outro
# chama o pacman por conta própria.
#
# A lista é curta porque foi medida numa instalação limpa, não montada por
# precaução, e encolheu quando foi remedida no Omarchy 4.0.1. O que saiu, e por
# quê, está no README; o caso que importa é o `nodejs`: o Omarchy administra o
# node pelo mise, e instalar a versão do pacman por cima faz o /usr/bin/node
# sombrear o shim do mise. Hoje as duas versões coincidem, e no dia em que
# divergirem o sintoma aparece longe da causa.
#
#   zsh     o shell de login; sem ele o .zshrc de 591 linhas nunca carrega
#   atuin   histórico de shell; o .zshrc degrada com aviso sem ele
#   unzip   usado pelos instaladores que baixam zip
#   mosh    shells que sobrevivem a um link ruim
PKGS=(zsh atuin unzip mosh)

# Dependências do meeting-rig (módulo 74), que só roda quando o repo de
# ferramentas está configurado. Instalar sempre deixaria dois pacotes de áudio e
# um de diálogo GTK numa máquina que nunca vai usá-los. libpulse e libnotify,
# que ele também precisa, já vêm no Omarchy.
if [ -n "${EZOMAR_TOOLS_REPO:-}" ]; then
  PKGS+=(uv espeak-ng zenity)
fi

MISSING=()
for p in "${PKGS[@]}"; do
  pacman -Qi "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if [ ${#MISSING[@]} -eq 0 ]; then
  echo "[ezomar][packages] Nada a instalar."
  exit 0
fi
echo "[ezomar][packages] Instalando: ${MISSING[*]}"

# Sincronizar os bancos e obrigatorio, e nao e detalhe: a instalacao do Omarchy
# e offline, ela consome os pacotes do proprio ISO e nunca baixa os bancos dos
# repositorios. Numa maquina recem-instalada /var/lib/pacman/sync so tem
# offline.db, e qualquer `pacman -S` morre com "target not found: zsh". Medido
# numa VM com Omarchy 4.0.1 zerado.
sudo pacman -Sy --noconfirm >/dev/null

if command -v omarchy >/dev/null 2>&1; then
  # No Omarchy, instalar sem -u e a convencao da casa, nao uma concessao: o
  # proprio `omarchy pkg add` e um `pacman -S --needed`, e um hook de
  # pre-transacao recusa `-Syu` direto ("Woah partner...") porque os upgrades
  # passam por `omarchy update`, que cuida de snapshot, keyring e migracoes.
  sudo pacman -S --needed --noconfirm "${MISSING[@]}"
  echo "[ezomar][packages] Para atualizar o resto do sistema, use: omarchy update"
else
  # Arch puro nao tem esse guarda-corpo, e ai sincronizar sem atualizar deixaria
  # a maquina num upgrade parcial, que e a forma classica de quebrar uma Arch.
  sudo pacman -Syu --needed --noconfirm "${MISSING[@]}"
fi
