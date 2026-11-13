#!/usr/bin/env bash
set -euo pipefail

# Instala o Claude Desktop, que traz o Cowork, o agente de desktop da Anthropic
# (o equivalente ao Grok Bot da xAI). Também tem o chat e o Claude Code.
#
# O pacote é o claude-desktop do AUR. Ele não compila nada: baixa o .deb do
# repositório apt oficial da Anthropic (downloads.claude.ai), fixa o sha256 e só
# reempacota. Revisado em 13/11/2026, na 5.11492.2. O que ele acrescenta ao .deb:
#
#   - um lançador que liga o backend Wayland do Electron, sem o qual a janela
#     roda no XWayland e fica borrada em monitor com escala (o portátil é 1.25);
#   - links para os caminhos do Debian que o Cowork espera (virtiofsd, firmware
#     OVMF), porque as tarefas do Cowork rodam numa VM.
#
# Por causa dessa VM ele puxa qemu-system-x86 e edk2-ovmf, algumas centenas de
# MB. O módulo vhost_vsock do kernel, que liga o app à VM, carrega sozinho no
# primeiro uso.
#
# O OpenAI Dots, o terceiro desse trio, não tem o que instalar: roda dentro do
# ChatGPT, num computador na nuvem da OpenAI, e se usa pelo chatgpt.com.
#
# Botão:
#   EZOMAR_CLAUDE_DESKTOP=false   não instala

say() { echo "[ezomar][claude-desktop] $*"; }

if [ "${EZOMAR_CLAUDE_DESKTOP:-true}" = false ]; then
  say "Desligado por EZOMAR_CLAUDE_DESKTOP."
  exit 0
fi

if pacman -Qq claude-desktop >/dev/null 2>&1; then
  say "Já instalado ($(pacman -Q claude-desktop | cut -d' ' -f2))."
  exit 0
fi

install_claude_desktop() {
  local helper
  if command -v omarchy >/dev/null 2>&1 && omarchy pkg aur add claude-desktop; then
    return 0
  fi
  for helper in yay paru; do
    if command -v "$helper" >/dev/null 2>&1 \
      && "$helper" -S --needed --noconfirm claude-desktop; then
      return 0
    fi
  done
  return 1
}

if ! install_claude_desktop; then
  say "Não consegui instalar pelo AUR; rode: yay -S claude-desktop" >&2
  exit 1
fi
say "Instalado ($(pacman -Q claude-desktop | cut -d' ' -f2))."
