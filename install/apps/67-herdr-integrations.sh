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

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[ezomar/herdr-integrations] Falharam: ${FAILED[*]}" >&2
  exit 1
fi
echo "[ezomar/herdr-integrations] Done."
