#!/usr/bin/env bash
set -euo pipefail

# Põe o usuário no grupo docker, para o `docker` rodar sem sudo.
#
# O Omarchy 4 deixa o usuário FORA desse grupo de propósito
# (/usr/share/omarchy/install/config/docker.sh), e com razão: o daemon roda
# como root, então estar no grupo docker equivale a root sem senha. Qualquer
# processo do usuário pode rodar `docker run -v /:/host` e reescrever o sistema.
#
# Aqui a escolha é a oposta, e foi feita sabendo disso: os agentes desta
# máquina sobem containers o tempo todo, e cada `docker` passando por sudo
# travava o agente num pedido de senha que ninguém estava olhando para
# responder. O custo é real: como os agentes rodam em bypassPermissions, eles
# têm root sem prompt através do docker.
#
# O próprio Omarchy oferece o mesmo passo em omarchy-setup-security-sudoless-docker,
# mas aquele script pede confirmação interativa pelo gum. Este faz a mesma coisa
# sem perguntar e usa o omarchy-sudo-docker para decidir, como os scripts dele.
#
# O grupo só vale para sessões criadas depois. Segundo o Omarchy, logout ou
# newgrp não bastam na prática: só o reboot aplica de forma confiável. Até lá,
# num terminal já aberto, `sg docker -c 'docker ...'` funciona.
#
# Botão:
#   EZOMAR_SUDOLESS_DOCKER=false   mantém o padrão do Omarchy (docker via sudo)
#
# Para desfazer depois: omarchy-remove-security-sudoless-docker

say() { echo "[ezomar][docker] $*"; }

if [ "${EZOMAR_SUDOLESS_DOCKER:-true}" = false ]; then
  say "Desligado por EZOMAR_SUDOLESS_DOCKER; docker continua passando por sudo."
  exit 0
fi

if ! getent group docker >/dev/null; then
  say "Grupo docker não existe (docker não instalado?); nada a fazer."
  exit 0
fi

# Pergunta pela configuração da conta, não pela sessão atual: logo depois do
# usermod a sessão ainda não tem o grupo, e isso não é motivo para repetir.
if command -v omarchy-sudo-docker >/dev/null 2>&1; then
  if ! omarchy-sudo-docker --configured; then
    configured=true
  else
    configured=false
  fi
elif id -nG "$USER" | grep -qw docker; then
  configured=true
else
  configured=false
fi

if [ "$configured" = true ]; then
  if [ -w /var/run/docker.sock ]; then
    say "$USER já está no grupo docker, e esta sessão já usa."
  else
    say "$USER já está no grupo docker; vale depois do próximo reboot."
  fi
  exit 0
fi

if sudo -n true 2>/dev/null || [ -t 0 ]; then
  sudo usermod -aG docker "$USER"
  # O omarchy-update-restart lê este estado e avisa que falta reiniciar.
  command -v omarchy-state >/dev/null 2>&1 && omarchy-state set reboot-required
  say "$USER adicionado ao grupo docker; vale depois do próximo reboot."
else
  say "Sem sudo disponível. Para o docker sem sudo, rode e reinicie:"
  say "  sudo usermod -aG docker $USER"
fi
