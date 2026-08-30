#!/usr/bin/env bash
set -euo pipefail

# herdr is the fleet manager the whole agent layer assumes: 66 restores its
# panes to the right profile, 70 plugs Collie into it, 80 bounds its memory.
# Until now nothing installed it, and 70 politely skipped when it was missing.
#
# The binary comes from the vendor's installer (same shape as the Claude Code
# native installer). The user unit does not: ~/.config/systemd/user/herdr.service
# and its drop-ins are the owner's and come from the dotfiles repo. This module
# only enables the unit when chezmoi has already delivered it.
#
# Knob:
#   EZOMAR_HERDR_CHANNEL   stable (installer default) or preview

export PATH="$HOME/.local/bin:$PATH"

if command -v herdr >/dev/null 2>&1; then
  echo "[ezomar][herdr] Já instalado: $(herdr --version 2>/dev/null | head -1)"
else
  echo "[ezomar][herdr] Instalando pelo instalador oficial..."
  curl -fsSL https://herdr.dev/install.sh | sh
  hash -r
  if ! command -v herdr >/dev/null 2>&1; then
    echo "[ezomar][herdr] Instalador terminou mas 'herdr' não está no PATH ($PATH)." >&2
    exit 1
  fi
  echo "[ezomar][herdr] Instalado: $(herdr --version 2>/dev/null | head -1)"
fi

if [ -n "${EZOMAR_HERDR_CHANNEL:-}" ]; then
  echo "[ezomar][herdr] Canal: $EZOMAR_HERDR_CHANNEL"
  herdr channel set "$EZOMAR_HERDR_CHANNEL" && herdr update \
    || echo "[ezomar][herdr] Aviso: não consegui trocar o canal; faça à mão com: herdr channel set $EZOMAR_HERDR_CHANNEL && herdr update" >&2
fi

# Omarchy can expose herdr from its own bin directory while the carried user
# unit points at ~/.local/bin/herdr. Leaving that mismatch until format day
# makes systemd fail with 203/EXEC after session.json is finally in place.
HERDR_BIN="$(command -v herdr)"
UNIT_FILE="$HOME/.config/systemd/user/herdr.service"
if [ -r "$UNIT_FILE" ]; then
  UNIT_TEXT="$(<"$UNIT_FILE")"
else
  UNIT_TEXT="$(systemctl --user cat herdr.service 2>/dev/null || true)"
fi
if [[ "$UNIT_TEXT" == *'%h/.local/bin/herdr'* || "$UNIT_TEXT" == *"$HOME/.local/bin/herdr"* ]] \
   && [ ! -x "$HOME/.local/bin/herdr" ]; then
  mkdir -p "$HOME/.local/bin"
  if [ -L "$HOME/.local/bin/herdr" ]; then
    # -f replaces a dangling or stale symlink, which plain ln -s cannot do.
    ln -sfn "$HERDR_BIN" "$HOME/.local/bin/herdr"
  else
    if [ -e "$HOME/.local/bin/herdr" ]; then
      old_bin="$HOME/.local/bin/herdr.pre-ezomar.$(date +%s).$$"
      mv -- "$HOME/.local/bin/herdr" "$old_bin"
      echo "[ezomar][herdr] Binário não executável preservado em $old_bin."
    fi
    ln -s "$HERDR_BIN" "$HOME/.local/bin/herdr"
  fi
  echo "[ezomar][herdr] Unit aponta para ~/.local/bin/herdr; link criado para $HERDR_BIN."
fi

if [ -r "$UNIT_FILE" ] || systemctl --user cat herdr.service >/dev/null 2>&1; then
  UNIT_STATE="$(systemctl --user is-enabled herdr.service 2>/dev/null || true)"
  if [ "$UNIT_STATE" = enabled ]; then
    echo "[ezomar][herdr] herdr.service já habilitado."
  elif [[ "$UNIT_STATE" == masked* ]]; then
    echo "[ezomar][herdr] herdr.service está mascarado; habilitação adiada até o restore validar session.json."
  else
    systemctl --user enable herdr.service
    echo "[ezomar][herdr] herdr.service habilitado. Inicie com: systemctl --user start herdr.service"
  fi
else
  echo "[ezomar][herdr] herdr.service ausente. O unit e os drop-ins (herdr.service.d/) são seus:"
  echo "[ezomar][herdr]   versione ~/.config/systemd/user/herdr.service no repo de dotfiles."
fi
