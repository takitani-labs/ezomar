#!/usr/bin/env bash
set -euo pipefail

# Google Cloud SDK.
#
# Instalado pelo tarball oficial em ~/google-cloud-sdk, e não por pacote. A
# escolha não é gosto: o SDK se atualiza sozinho com `gcloud components update`,
# e é assim que ele espera viver. Empacotado na AUR, o autoupdate briga com o
# gerenciador de pacotes e a cada `omarchy update` um dos dois desfaz o outro.
#
# O `bq` vem junto e é o que importa na prática aqui: ele é o cliente do
# BigQuery, e o warehouse da Exato é consultado por ele.
#
# O .zshrc já carrega path.zsh.inc e completion.zsh.inc (linhas 677 e 680,
# versionadas no chezmoi), então quem instala o SDK ganha PATH e autocompletar
# sem tocar em nada. Este módulo existe só para o diretório aparecer numa
# máquina nova: sem ele, aquelas duas linhas do .zshrc apontam para um caminho
# que não existe e falham em silêncio, que é o pior jeito de descobrir.
#
# A AUTENTICAÇÃO NÃO É FEITA AQUI. `gcloud auth login` abre navegador e exige
# uma pessoa; um instalador que tenta isso trava a execução inteira esperando
# um clique que ninguém vai dar. O módulo diz o que falta e segue.

SDK_DIR="$HOME/google-cloud-sdk"
SDK_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz"

say() { echo "[ezomar][gcloud] $*"; }

export PATH="$SDK_DIR/bin:$PATH"

if [ -x "$SDK_DIR/bin/gcloud" ]; then
  say "Já instalado: $(cat "$SDK_DIR/VERSION" 2>/dev/null || echo '?')"
else
  say "Baixando o SDK oficial..."
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" EXIT
  if ! curl -fsSL "$SDK_URL" -o "$tmp/sdk.tar.gz"; then
    say "Download falhou. Instale à mão: $SDK_URL" >&2
    exit 1
  fi
  tar -xzf "$tmp/sdk.tar.gz" -C "$HOME"
  # --command-completion e --path-update ficam em false: quem cuida do .zshrc é
  # o chezmoi, e deixar o instalador acrescentar as linhas por conta própria
  # cria a segunda cópia delas no arquivo a cada reinstalação.
  "$SDK_DIR/install.sh" --quiet --usage-reporting=false \
    --command-completion=false --path-update=false >/dev/null
  say "Instalado: $(cat "$SDK_DIR/VERSION" 2>/dev/null || echo '?')"
fi

# Conta ativa, que é a diferença entre "o binário existe" e "dá para usar".
account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1 || true)"
if [ -n "$account" ]; then
  say "Autenticado como $account."
else
  say "Sem conta ativa. Rode: gcloud auth login"
  say "E para as bibliotecas acharem credencial: gcloud auth application-default login"
fi
