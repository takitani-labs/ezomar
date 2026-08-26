#!/usr/bin/env bash
# Sourced by the modules that need machine-specific values.
#
# Nothing personal is hardcoded in this repo. Two values are needed before
# chezmoi can run, and they cannot come from the private dotfiles repo, because
# they are what unlocks it:
#
#   EZOMAR_DOTFILES_REPO  the chezmoi source repo
#   EZOMAR_AGE_ITEM       vault item holding the age identity that decrypts it
#
# Resolution order: environment, then ~/.config/ezomar/config.sh, then a prompt
# (saved back to that file, so it is asked once). Under EZOMAR_AUTOMATED with no
# TTY it fails loudly instead of guessing, since a wrong repo here produces a
# machine that looks provisioned and is not.

EZOMAR_CONFIG_FILE="${EZOMAR_CONFIG_FILE:-$HOME/.config/ezomar/config.sh}"

# shellcheck disable=SC1090
[ -r "$EZOMAR_CONFIG_FILE" ] && . "$EZOMAR_CONFIG_FILE"

ezomar_config_require() {
  local var="$1" prompt="$2" example="$3" value="${!1:-}"

  if [ -n "$value" ]; then
    printf -v "$var" '%s' "$value"
    export "${var?}"
    return 0
  fi

  if [ ! -t 0 ]; then
    echo "[ezomar][config] $var não definido e sem terminal para perguntar." >&2
    echo "                 Defina em $EZOMAR_CONFIG_FILE ou exporte:" >&2
    echo "                   export $var='$example'" >&2
    return 1
  fi

  read -r -p "[ezomar] $prompt: " value
  [ -n "$value" ] || { echo "[ezomar][config] $var é obrigatório." >&2; return 1; }

  printf -v "$var" '%s' "$value"
  export "${var?}"

  install -d -m 0700 "$(dirname "$EZOMAR_CONFIG_FILE")"
  touch "$EZOMAR_CONFIG_FILE"
  chmod 0600 "$EZOMAR_CONFIG_FILE"
  # Replace any previous line for this var, then append the current one.
  sed -i "/^${var}=/d" "$EZOMAR_CONFIG_FILE"
  printf '%s=%q\n' "$var" "$value" >> "$EZOMAR_CONFIG_FILE"
  echo "[ezomar][config] Salvo em $EZOMAR_CONFIG_FILE"
}

# Optional: the owner's private tools repo. Some tools are too personal for this
# repo yet too alive for a vendored copy (a copy is a second source of truth that
# quietly goes stale, which is the failure this repo keeps finding). Modules 72
# to 76 install straight from a clone of that repo, and skip when it is unset.
#
#   EZOMAR_TOOLS_REPO   git URL, e.g. git@github.com:user/tools.git
#   EZOMAR_TOOLS_DIR    clone path; default ~/work/repos/<org>/<repo> from the URL
#
# The layout those modules expect is tools/<name>/ and scripts/*.sh.
ezomar_tools_dir() {
  if [ -n "${EZOMAR_TOOLS_DIR:-}" ]; then
    printf '%s\n' "$EZOMAR_TOOLS_DIR"
    return 0
  fi
  [ -n "${EZOMAR_TOOLS_REPO:-}" ] || return 1
  local path="${EZOMAR_TOOLS_REPO%.git}"
  path="${path##*:}"     # git@host:org/repo   -> org/repo ; https://host/org/repo -> //host/org/repo
  path="${path#//*/}"    # //host/org/repo     -> org/repo
  printf '%s/work/repos/%s\n' "$HOME" "$path"
}
