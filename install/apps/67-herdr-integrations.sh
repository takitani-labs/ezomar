#!/usr/bin/env bash
set -euo pipefail

# Install Herdr's official session reporters everywhere an agent may start.
# This is deliberately provisioned instead of left as a one-off CLI command:
# without it Herdr can detect the process, but it does not know the native
# session id needed for restore or for the account-switch handoff.

if ! command -v herdr >/dev/null 2>&1; then
  echo "[ezomar/herdr-integrations] herdr not found; skipping."
  exit 0
fi

# A failing integration must not stop the ones after it: the Codex hook and the
# five Claude profiles are independent, and losing all of them because the first
# one had a malformed config is how a whole fleet ends up without session ids.
# Failures are collected and reported at the end, and the module still exits
# non-zero, so nothing is silently swallowed.
FAILED=()
install_integration() { # $1=rótulo, resto=comando
  local label="$1"; shift
  echo "[ezomar/herdr-integrations] $label..."
  "$@" || FAILED+=("$label")
}

CODEX_ROOT="$HOME/.codex-profiles"
CODEX_DEFAULT="${EZOMAR_CODEX_DEFAULT:-personal}"

# hooks.json and config.toml are shared by the Codex profiles. Install one hook
# at the stable default-profile path; both accounts execute that shared entry.
if [ -d "$CODEX_ROOT/$CODEX_DEFAULT" ]; then
  install_integration "Codex ($CODEX_DEFAULT; hooks shared by every account)" \
    env CODEX_HOME="$CODEX_ROOT/$CODEX_DEFAULT" herdr integration install codex
elif [ -d "$HOME/.codex" ]; then
  install_integration "Codex (default home)" \
    env CODEX_HOME="$HOME/.codex" herdr integration install codex
fi

claude_count=0
if [ -d "$HOME/.claude-profiles" ]; then
  for profile_dir in "$HOME"/.claude-profiles/*/; do
    [ -d "$profile_dir" ] || continue
    profile="$(basename "$profile_dir")"
    install_integration "Claude ($profile)" \
      env CLAUDE_CONFIG_DIR="${profile_dir%/}" herdr integration install claude
    claude_count=$((claude_count + 1))
  done
fi

if [ "$claude_count" -eq 0 ] && [ -d "$HOME/.claude" ]; then
  install_integration "Claude (default home)" \
    env CLAUDE_CONFIG_DIR="$HOME/.claude" herdr integration install claude
fi

# Every other agent herdr knows about, and not just the two we wired by hand.
#
# Claude e Codex acima são casos especiais porque têm VÁRIAS contas, cada uma com
# o seu diretório de configuração, e cada uma precisa do hook. Os demais têm um
# diretório só e o herdr instala sozinho.
#
# Por que faltavam: este módulo nasceu com claude e codex escritos na mão e
# nunca cresceu junto com a máquina. O herdr já suportava kimi, grok e opencode,
# e os três estavam simplesmente desligados. O sintoma não era erro nenhum: as
# abas desses agentes voltavam de um restart sem sessão para retomar, e parecia
# limitação do herdr quando era integração que ninguém instalou.
#
# A LISTA VEM DO HERDR, não daqui. `herdr integration` imprime o que ele sabe
# instalar, e é ele quem decide se o agente existe nesta máquina: quando não
# existe, recusa com "config directory not found ... install X first". Essa
# recusa é resposta correta, não falha, então não entra em FAILED. Manter uma
# lista própria aqui garantiria que o próximo agente suportado ficasse de fora
# pelo mesmo motivo que estes ficaram.
# `herdr integration` sem subcomando imprime o uso e sai com 2. Sob set -e isso
# derruba o módulo inteiro antes de chegar aqui, que foi exatamente o que
# aconteceu na primeira versão: nada instalava e nem o "Done." saía.
KNOWN="$(herdr integration 2>&1 | grep -oE 'herdr integration install [a-z0-9-]+' | awk '{print $4}' | sort -u || true)"
for agent in $KNOWN; do
  case "$agent" in
    claude | codex) continue ;;  # tratados acima, por conta
  esac
  if herdr integration install "$agent" >/dev/null 2>&1; then
    echo "[ezomar/herdr-integrations] $agent: instalado."
  fi
done

# As contas Kimi além da padrão (módulo 64) moram em ~/.kimi-code-profiles, e o
# laço acima só instala na ~/.kimi-code. Sem hook, o herdr não guarda o id da
# sessão, e a aba dessa conta volta de um restart vazia.
#
# Só instala onde ainda não há hook NENHUM. O login do kimi reescreve o
# config.toml inteiro e apaga os comentários, inclusive os marcadores com que o
# herdr reconhece o próprio bloco. Rodar o install de novo numa conta já logada
# duplica os 12 hooks (medido: 12 viram 24), e cada evento passa a ser
# reportado duas vezes. O hook pode apontar para a pasta da própria conta ou
# para ~/.kimi-code/hooks (quando o config foi copiado pelo módulo 64); os dois
# servem.
for home in "$HOME"/.kimi-code-profiles/*/; do
  [ -d "$home" ] || continue
  home="${home%/}"
  if grep -q 'herdr-agent-state.sh' "$home/config.toml" 2>/dev/null; then
    echo "[ezomar/herdr-integrations] kimi ($(basename "$home")): hooks já presentes."
    continue
  fi
  install_integration "Kimi ($(basename "$home"))" \
    env KIMI_CODE_HOME="$home" herdr integration install kimi
done

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[ezomar/herdr-integrations] Falharam: ${FAILED[*]}" >&2
  exit 1
fi
echo "[ezomar/herdr-integrations] Done."
