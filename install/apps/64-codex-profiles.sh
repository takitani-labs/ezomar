#!/usr/bin/env bash
set -euo pipefail

# O Codex CLI guarda autenticação dentro de CODEX_HOME. Sem separar esse home,
# trocar `--profile` muda apenas configurações e mantém uma única conta. Este
# módulo migra o home antigo e cria homes por conta, compartilhando config,
# hooks, plugins e memórias por symlink para evitar deriva entre os perfis.
#
# O snippet zsh já vem do chezmoi e não é escrito aqui.

PROFILES="${EZOMAR_CODEX_PROFILES:-personal exato}"
DEFAULT_PROFILE="${EZOMAR_CODEX_DEFAULT:-personal}"
ROOT="$HOME/.codex-profiles"
SHARED="$ROOT/shared"
SHARED_ITEMS=(config.toml hooks.json plugins memories)
SNIPPET="$HOME/.config/zsh/codex-profiles.zsh"

profile_is_listed=false
for profile in $PROFILES; do
  if [ "$profile" = "$DEFAULT_PROFILE" ]; then
    profile_is_listed=true
    break
  fi
done
if [ "$profile_is_listed" != true ]; then
  echo "[ezomar][codex-profiles] Perfil padrão '$DEFAULT_PROFILE' não está em: $PROFILES" >&2
  exit 1
fi

# Reparo, antes de qualquer coisa: um .json compartilhado de zero byte NÃO é JSON
# válido, e quem for lê-lo morre em "EOF while parsing a value at line 1 column
# 0". Foi assim que o `herdr integration install codex` do módulo 67 falhou. Vem
# antes do already_configured de propósito: aquele teste só olha se os symlinks
# apontam para o lugar certo, então uma máquina com o arquivo quebrado sairia
# cedo por "já configurado" e ficaria quebrada para sempre.
for item in "${SHARED_ITEMS[@]}"; do
  case "$item" in
    *.json)
      if [ -f "$SHARED/$item" ] && [ ! -s "$SHARED/$item" ]; then
        printf '{}\n' >"$SHARED/$item"
        echo "[ezomar][codex-profiles] $item estava vazio e não era JSON válido; semeado com {}."
      fi
      ;;
  esac
done

already_configured() {
  local profile item target
  [ -d "$SHARED" ] || return 1
  [ -L "$HOME/.codex" ] || return 1
  [ "$(readlink "$HOME/.codex")" = "$ROOT/$DEFAULT_PROFILE" ] || return 1
  for item in "${SHARED_ITEMS[@]}"; do
    [ -e "$SHARED/$item" ] || return 1
  done
  for profile in $PROFILES; do
    [ -d "$ROOT/$profile" ] || return 1
    for item in "${SHARED_ITEMS[@]}"; do
      target="$ROOT/$profile/$item"
      [ -L "$target" ] || return 1
      [ "$(readlink "$target")" = "$SHARED/$item" ] || return 1
    done
  done
  return 0
}

if already_configured; then
  echo "[ezomar][codex-profiles] Perfis $PROFILES já configurados; padrão $DEFAULT_PROFILE. Pulando."
  exit 0
fi

if pgrep -x codex >/dev/null 2>&1; then
  echo "[ezomar][codex-profiles] O Codex está rodando. Feche-o antes; este módulo move o home dele." >&2
  exit 1
fi

mkdir -p "$ROOT" "$SHARED"

if [ -d "$HOME/.codex" ] && [ ! -L "$HOME/.codex" ]; then
  if [ -e "$ROOT/$DEFAULT_PROFILE" ]; then
    echo "[ezomar][codex-profiles] $ROOT/$DEFAULT_PROFILE já existe; não vou sobrescrever." >&2
    exit 1
  fi
  echo "[ezomar][codex-profiles] Migrando ~/.codex para $ROOT/$DEFAULT_PROFILE..."
  mv "$HOME/.codex" "$ROOT/$DEFAULT_PROFILE"
fi

for item in "${SHARED_ITEMS[@]}"; do
  src="$ROOT/$DEFAULT_PROFILE/$item"
  if [ -e "$src" ] && [ ! -L "$src" ]; then
    if [ -e "$SHARED/$item" ]; then
      backup="${src}.bak-ezomar"
      mv "$src" "$backup"
      ln -s "$SHARED/$item" "$src"
      echo "[ezomar][codex-profiles] $SHARED/$item mantido; conflito em $src movido para $backup e symlink recriado."
      continue
    fi
    mv "$src" "$SHARED/$item"
    echo "[ezomar][codex-profiles] Compartilhado: $item."
  fi
  # Semear o placeholder certo importa: um .json de zero byte NÃO é JSON válido, e
  # quem for lê-lo morre em "EOF while parsing a value at line 1 column 0". Foi
  # exatamente assim que o `herdr integration install codex` do módulo 67 falhou.
  # Um .toml vazio, ao contrário, é um documento TOML válido.
  #
  # O reparo também vale para arquivo que já existe: um .json vazio no disco veio
  # de uma execução anterior deste módulo e continua quebrado até alguém escrever
  # nele. Conserta em vez de deixar a máquina num estado que só falha depois.
  case "$item" in
    *.json)
      if [ ! -e "$SHARED/$item" ] || [ ! -s "$SHARED/$item" ]; then
        printf '{}\n' >"$SHARED/$item"
      fi
      ;;
    *.toml)
      [ -e "$SHARED/$item" ] || : >"$SHARED/$item"
      ;;
    *)
      [ -e "$SHARED/$item" ] || mkdir -p "$SHARED/$item"
      ;;
  esac
done

for profile in $PROFILES; do
  mkdir -p "$ROOT/$profile"
  for item in "${SHARED_ITEMS[@]}"; do
    target="$ROOT/$profile/$item"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      rm -rf -- "$target"
    elif [ -L "$target" ] && [ "$(readlink "$target")" != "$SHARED/$item" ]; then
      rm -- "$target"
    fi
    [ -L "$target" ] || ln -s "$SHARED/$item" "$target"
  done
  if [ -f "$ROOT/$profile/auth.json" ]; then
    echo "[ezomar][codex-profiles] $profile: autenticado."
  else
    echo "[ezomar][codex-profiles] $profile: ainda não autenticado."
  fi
done

if [ -L "$HOME/.codex" ] && [ "$(readlink "$HOME/.codex")" != "$ROOT/$DEFAULT_PROFILE" ]; then
  rm -- "$HOME/.codex"
fi
if [ ! -e "$HOME/.codex" ]; then
  ln -s "$ROOT/$DEFAULT_PROFILE" "$HOME/.codex"
  echo "[ezomar][codex-profiles] ~/.codex aponta para $ROOT/$DEFAULT_PROFILE."
fi

if [ -f "$SNIPPET" ]; then
  echo "[ezomar][codex-profiles] Snippet zsh já restaurado pelo chezmoi."
else
  echo "[ezomar][codex-profiles] Aviso: $SNIPPET não foi encontrado; rode o módulo 30." >&2
fi

for profile in $PROFILES; do
  if [ ! -f "$ROOT/$profile/auth.json" ]; then
    echo "[ezomar][codex-profiles] Login pendente: CODEX_HOME=$ROOT/$profile codex login"
  fi
done
