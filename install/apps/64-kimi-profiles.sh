#!/usr/bin/env bash
set -euo pipefail

# Cria uma pasta de conta do Kimi Code CLI para cada conta além da padrão.
#
# O kimi guarda login, sessões, histórico e device_id dentro de KIMI_CODE_HOME.
# A conta padrão (Exato) continua em ~/.kimi-code, que é também onde mora o
# binário, o PATH do zshrc e os hooks do herdr; mover essa pasta quebraria tudo
# isso junto. As outras contas ganham ~/.kimi-code-profiles/<nome>.
#
# O launcher (kimip) e o resolvedor do restore vêm do chezmoi, em
# ~/.config/zsh/kimi-profiles.zsh. Este módulo só prepara as pastas.
#
# O que cada pasta nova recebe, e por quê:
#
#   config.toml   CÓPIA do padrão, nunca symlink. O kimi grava o config com
#                 tmp+rename no caminho literal, então o symlink viraria arquivo
#                 comum na primeira escrita. A cópia leva junto os [[hooks]] do
#                 herdr, que apontam por caminho absoluto para ~/.kimi-code/hooks,
#                 então o herdr enxerga o estado das duas contas.
#   region        "global" (kimi.ai). Sem ele, uma pasta sem login cai no padrão
#                 mainland-cn e o login vai para kimi.com.
#   .skip-migration-from-kimi-cli
#                 Sem esse marcador a primeira abertura oferece migrar o ~/.kimi
#                 antigo (histórico e sessões da conta Exato) para a conta nova.
#   tui.toml      symlink para o padrão: é gravado através do link, e tema e
#                 notificações não são coisa de conta.
#
# Nunca se copia credentials/, oauth/ nem device_id: o device_id vai dentro do
# token, e uma credencial copiada de outra pasta cruza as contas.
#
# O login reescreve o config.toml e volta o modelo padrão para
# kimi-code/kimi-for-coding (visto em 30/09/2026, na primeira conta extra). Por
# isso o modelo é reaplicado a cada execução, só nas contas já logadas e só se o
# apelido existir no config: antes do login a lista de modelos nem está lá.
#
# Botões:
#   EZOMAR_KIMI_PROFILES   contas além da padrão (padrão: "personal")
#   EZOMAR_KIMI_MODEL      modelo padrão das contas extras (padrão: kimi-code/k3)

PROFILES="${EZOMAR_KIMI_PROFILES:-personal}"
MODEL="${EZOMAR_KIMI_MODEL:-kimi-code/k3}"
DEFAULT_HOME="$HOME/.kimi-code"
ROOT="$HOME/.kimi-code-profiles"
SNIPPET="$HOME/.config/zsh/kimi-profiles.zsh"

say() { echo "[ezomar][kimi-profiles] $*"; }

if [ ! -x "$DEFAULT_HOME/bin/kimi" ]; then
  say "kimi não instalado em $DEFAULT_HOME (módulo 59); pulando."
  exit 0
fi

mkdir -p "$ROOT"
chmod 700 "$ROOT"

pending=()
for profile in $PROFILES; do
  home="$ROOT/$profile"
  mkdir -p "$home"
  chmod 700 "$home"

  if [ ! -e "$home/config.toml" ] && [ -f "$DEFAULT_HOME/config.toml" ]; then
    install -m 0600 "$DEFAULT_HOME/config.toml" "$home/config.toml"
    say "$profile: config.toml copiado da conta padrão."
  elif [ -L "$home/config.toml" ]; then
    say "Aviso: $home/config.toml é symlink; o kimi o substitui na primeira escrita." >&2
  fi

  [ -e "$home/region" ] || printf 'global\n' >"$home/region"
  [ -e "$home/.skip-migration-from-kimi-cli" ] || : >"$home/.skip-migration-from-kimi-cli"
  if [ ! -e "$home/tui.toml" ] && [ -f "$DEFAULT_HOME/tui.toml" ]; then
    ln -s "$DEFAULT_HOME/tui.toml" "$home/tui.toml"
  fi

  if compgen -G "$home/credentials/*.json" >/dev/null; then
    say "$profile: autenticado."
    cfg="$home/config.toml"
    if grep -qF "[models.\"$MODEL\"]" "$cfg" 2>/dev/null \
      && ! grep -qxF "default_model = \"$MODEL\"" "$cfg"; then
      sed -i "s|^default_model = .*|default_model = \"$MODEL\"|" "$cfg"
      say "$profile: modelo padrão ajustado para $MODEL."
    fi
  else
    say "$profile: ainda não autenticado."
    pending+=("$profile")
  fi
done

if [ -f "$SNIPPET" ]; then
  say "Snippet zsh já restaurado pelo chezmoi."
else
  say "Aviso: $SNIPPET não foi encontrado; rode o módulo 30." >&2
fi

# O login é device-code: o comando mostra um endereço e um código, e quem
# aprova é o navegador. Aprove numa janela logada na conta CERTA: se o navegador
# padrão estiver logado no kimi.ai com a conta padrão, aprovar ali põe a conta
# errada na pasta nova, sem erro nenhum.
for profile in "${pending[@]}"; do
  say "Login pendente: KIMI_CODE_HOME=$ROOT/$profile kimi login --region global"
done
