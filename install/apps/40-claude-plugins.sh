#!/usr/bin/env bash
set -euo pipefail

# Claude Code plugins, em todos os perfis.
#
# Não são versionados no repositório de dotfiles de propósito: são instalações
# de terceiro carregando binários, então são refeitas a partir dos marketplaces.
# O resto do Claude (skills, os perfis, CLAUDE.md, hooks) vem do chezmoi e não é
# tocado aqui.
#
# ---------------------------------------------------------------------------
# Por que isto passou a varrer perfil por perfil
#
# O `skills/` de cada perfil é um symlink para ~/.claude/skills, então um skill
# instalado aparece em todos de uma vez. O `plugins/` NÃO é: cada perfil tem o
# seu, com o próprio installed_plugins.json. Como este módulo rodava sem dizer
# em qual perfil, ele atendia apenas o que estivesse ativo na hora.
#
# O resultado foi desvio silencioso. Medido em 19/09/2026, antes desta mudança:
#
#   plugin                  .claude  papi  personal  proton  team  team-max
#   feature-dev                sim     -      sim       -      -       -
#   playwright                 sim     -      sim       -      -       -
#   typesafe                    -      -       -       sim     -       -
#
# Ninguém tinha desinstalado nada: quatro perfis simplesmente nunca estiveram
# ativos quando o módulo rodou. E o sintoma é do tipo que não se reconhece como
# sintoma, porque um comando some sem erro nenhum, só num perfil.
#
# ---------------------------------------------------------------------------
# Quais perfis contam
#
# Os de proxy (codex, gemini, kimi, minimax) são Claude Code apontado para outro
# provedor, e se distinguem por terem ANTHROPIC_BASE_URL no settings.json. Ficam
# de fora porque nunca tiveram plugins e instalar neles seria decidir por você.
#
# A regra é derivada em vez de listada para não ter que lembrar de editar este
# arquivo cada vez que uma conta nova aparecer.

export PATH="$HOME/.local/bin:$PATH"

say() { echo "[ezomar][claude-plugins] $*"; }

if ! command -v claude >/dev/null 2>&1; then
  say "claude não encontrado (o Omarchy normalmente traz). Pulando." >&2
  exit 0
fi

MARKETPLACES=(
  anthropics/claude-plugins-official
  anthropics/claude-code
  openai/codex-plugin-cc
  microsoft/Webwright
  typesafe-ai/skills
)

PLUGINS=(
  codex@openai-codex
  webwright@webwright
  feature-dev@claude-plugins-official
  frontend-design@claude-plugins-official
  playwright@claude-plugins-official
  csharp-lsp@claude-plugins-official
  typescript-lsp@claude-plugins-official
  pyright-lsp@claude-plugins-official
  gopls-lsp@claude-plugins-official
  rust-analyzer-lsp@claude-plugins-official
  typesafe@typesafe-ai
)

# Um perfil de verdade é o que fala com a Anthropic. Quem tem base URL própria
# está apontando para outro lugar.
is_proxy_profile() {
  local url
  url="$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$1/settings.json" 2>/dev/null)" || return 1
  [ -n "$url" ]
}

profiles() {
  local d
  [ -d "$HOME/.claude" ] && printf '%s\n' "$HOME/.claude"
  for d in "$HOME"/.claude-profiles/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "$d/settings.json" ] || continue
    is_proxy_profile "$d" && continue
    printf '%s\n' "$d"
  done
}

total_missing=0

while read -r profile; do
  [ -n "$profile" ] || continue
  name="$(basename "$profile")"
  [ "$profile" = "$HOME/.claude" ] && name="default"
  say "--- perfil $name"

  export CLAUDE_CONFIG_DIR="$profile"

  for m in "${MARKETPLACES[@]}"; do
    claude plugin marketplace add "$m" >/dev/null 2>&1 || true
  done

  # Uma leitura por perfil em vez de uma por plugin: `claude plugin list` é a
  # parte cara do laço.
  installed="$(claude plugin list 2>/dev/null || true)"

  for p in "${PLUGINS[@]}"; do
    if printf '%s' "$installed" | grep -qF "$p"; then
      status="já tinha"
    else
      if claude plugin install "$p" >/dev/null 2>&1; then
        status="INSTALADO agora"
        total_missing=$(( total_missing + 1 ))
      else
        say "  $p: FALHA ao instalar"
        continue
      fi
    fi
    # Habilitar sempre, não só depois de instalar. Os arquivos do plugin
    # estarem em disco e o plugin estar habilitado são fatos separados,
    # guardados no settings.json, que o módulo 30 restaura do repositório. Sem
    # isto, uma máquina que já tinha os arquivos termina com eles instalados e
    # desligados, e o `claude plugin list` continua dizendo "installed", então
    # nada parece errado.
    claude plugin enable "$p" >/dev/null 2>&1 || true
    [ "$status" = "já tinha" ] || say "  $p: $status"
  done
done < <(profiles)

unset CLAUDE_CONFIG_DIR

if [ "$total_missing" -gt 0 ]; then
  say "$total_missing instalações que faltavam foram feitas."
else
  say "Todos os perfis já estavam completos."
fi
