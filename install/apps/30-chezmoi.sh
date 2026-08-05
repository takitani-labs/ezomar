#!/usr/bin/env bash
set -euo pipefail

# chezmoi: install the binary and apply the dotfiles.
#
# Two things this handles that a plain `chezmoi init --apply` does not:
#
# 1. The dotfiles remote is git@github.com, and the repo is private, so the
#    machine needs a GitHub-capable SSH key before this can clone. That key is
#    itself inside the repo, which is circular, so it has to be placed by hand
#    first. This module checks and says so instead of failing on a git error.
#
# 2. --exclude=scripts. The repo carries run_once_after_* scripts that call
#    `sudo pacman` and expect an interactive 1Password login. Running them from
#    an automated pass hangs waiting for a TTY that is not there. They are run
#    separately, by hand, once the vaults are logged in.

export PATH="$HOME/.local/bin:$PATH"

# shellcheck source=../lib/config.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)/config.sh"

ezomar_config_require EZOMAR_DOTFILES_REPO \
  "Repositório de dotfiles (chezmoi)" \
  "git@github.com:usuario/dotfiles.git"
REPO="$EZOMAR_DOTFILES_REPO"

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "[ezomar][chezmoi] Instalando em ~/.local/bin..."
  mkdir -p "$HOME/.local/bin"
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" >/dev/null
fi
CM="$(command -v chezmoi)"
echo "[ezomar][chezmoi] $($CM --version | head -1)"

if [ ! -s "$HOME/.config/age/keys.txt" ]; then
  echo "[ezomar][chezmoi] Sem chave age. Rode o módulo 20 antes." >&2
  exit 1
fi

# Capture first, then match. `ssh -T git@github.com` always exits 1 (GitHub
# refuses shell access by design), so piping it straight into grep under
# `set -o pipefail` reports failure even when authentication worked.
GH_OUT="$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)"
if ! printf '%s' "$GH_OUT" | grep -q "successfully authenticated"; then
  echo "[ezomar][chezmoi] Sem acesso SSH ao GitHub. O repo de dotfiles é privado e as" >&2
  echo "                  chaves estão dentro dele, então a primeira tem que ser copiada" >&2
  echo "                  à mão da máquina primária:" >&2
  echo "                    scp ~/.ssh/id_rsa ~/.ssh/id_rsa.pub <esta-máquina>:.ssh/" >&2
  exit 1
fi

if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
  echo "[ezomar][chezmoi] Repositório já clonado, atualizando..."
  # Not fatal, and deliberately not --force. Claude Code rewrites
  # ~/.claude/settings.json whenever a plugin or marketplace is added, so it
  # diverges from the repo on every machine that installs plugins. chezmoi then
  # wants to prompt, and there is no TTY here. Forcing would silently drop the
  # marketplace registrations that module 40 depends on, so the run reports the
  # divergence and moves on, leaving the choice to a human.
  OUT="$($CM update --exclude=scripts 2>&1 || true)"
  printf '%s\n' "$OUT" | grep -v "could not open a new TTY" || true
  if printf '%s' "$OUT" | grep -q "has changed since chezmoi last wrote it"; then
    echo "[ezomar][chezmoi] Aviso: arquivos divergiram do repo e foram mantidos como estão."
    echo "                  Revise com: chezmoi diff   e resolva com apply ou re-add."
  fi
else
  echo "[ezomar][chezmoi] Clonando e aplicando $REPO..."
  $CM init --apply --exclude=scripts "$REPO"
fi

# The antigen external is a plain file, and chezmoi does not create the parent
# directory for it on a first run.
mkdir -p "$HOME/.config/antigen"
$CM apply --exclude=scripts "$HOME/.config/antigen/antigen.zsh" 2>/dev/null || true

echo "[ezomar][chezmoi] Aplicado."
