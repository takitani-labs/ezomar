#!/usr/bin/env bash
set -euo pipefail

# Instala o tropa, o helper do skill tropadobolsonaro do Claude Code.
#
# O skill põe agentes que não são Claude (Codex nas duas contas, Kimi nas duas,
# GLM pela Z.AI, OpenCode Go, Grok e Muse) para tocar tarefas em paralelo, cada
# uma na sua worktree e na sua aba do herdr, com a sessão do Claude orquestrando
# e revisando antes do merge. A parte mecânica mora neste script e não no texto
# do skill porque é ali que os detalhes quebram: CODEX_HOME por conta, o arquivo
# de confiança que o Kimi exige em toda worktree nova, o --env do herdr que só
# chega no painel raiz da aba.
#
# O SKILL.md vem do chezmoi, como os outros skills: o skills/ de cada perfil do
# Claude é um symlink para ~/.claude/skills, então um skill novo vale para todos
# os perfis de uma vez. Este módulo cuida só do binário e da configuração.
#
# roster.json (quem entra em campo, com que modelo e esforço) e memes.json (os
# rótulos e as falas) vão para ~/.config/tropa e são feitos para editar. Por
# isso o módulo guarda uma cópia do template instalado (.orig): se o arquivo
# ainda é igual a ela, o template novo entra direto; se o usuário mexeu, o novo
# fica ao lado como .new, sem pisar na edição.
#
# Cada passo de dinossauro roda com a guarda do tropa: wrappers de dotnet, git,
# mise, psql e aws na frente do PATH, gerados em ~/.local/state/tropa/_guard.
#
#   tropa roster          quem está logado e com cota
#   tropa smoke <dino>    um "Reply with exactly: OK" headless no dinossauro
#   tropa guard --check <repo>   a guarda fica na frente num bash -l e num zsh -l?

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/tropa"
BIN_DIR="$HOME/.local/bin"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tropa"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tropa"

say() { echo "[ezomar][tropa] $*"; }

for file in tropa roster.json memes.json; do
  if [ ! -f "$TPL/$file" ]; then
    say "Template ausente: $TPL/$file" >&2
    exit 1
  fi
done

# jq lê e grava o estado; flock serializa as esperas que rodam em paralelo;
# sha256sum dá o nome do arquivo de confiança do Kimi; column monta as tabelas;
# timeout corta o passo headless que trava.
for command in jq git flock sha256sum column timeout; do
  if ! command -v "$command" >/dev/null 2>&1; then
    say "Comando obrigatório ausente: $command" >&2
    exit 1
  fi
done

# JSON quebrado no template viraria erro só na primeira escalação, no meio de
# uma run. Melhor falhar aqui.
for file in roster.json memes.json; do
  if ! jq empty "$TPL/$file" 2>/dev/null; then
    say "JSON inválido no template: $TPL/$file" >&2
    exit 1
  fi
done

install -D -m 0755 "$TPL/tropa" "$BIN_DIR/tropa"
mkdir -p "$CONF_DIR" "$STATE_DIR"

install_config() {
  local name="$1"
  local src="$TPL/$name" dst="$CONF_DIR/$name" orig="$CONF_DIR/.$name.orig"
  if [ ! -e "$dst" ]; then
    install -m 0644 "$src" "$dst"
    install -m 0644 "$src" "$orig"
    say "$name instalado."
  elif cmp -s "$src" "$dst"; then
    install -m 0644 "$src" "$orig"
    rm -f -- "$dst.new"
    say "$name já está atualizado."
  elif [ -e "$orig" ] && cmp -s "$dst" "$orig"; then
    install -m 0644 "$src" "$dst"
    install -m 0644 "$src" "$orig"
    say "$name atualizado (não tinha edição local)."
  elif [ -e "$orig" ] && cmp -s "$src" "$orig"; then
    say "$name tem edição local e o template não mudou; mantido."
  else
    install -m 0644 "$src" "$dst.new"
    say "$name tem edição local; a versão nova ficou em $dst.new para comparar."
  fi
}
install_config roster.json
install_config memes.json

if ! command -v herdr >/dev/null 2>&1; then
  say "herdr ausente: até o módulo 56 instalar, o tropa só roda com 'tropa up <run> --repo <caminho> --headless'."
fi

say "Instalado em $BIN_DIR/tropa ($("$BIN_DIR/tropa" version))."
say "Elenco e cotas: tropa roster"
