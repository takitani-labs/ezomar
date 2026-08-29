#!/usr/bin/env bash
set -euo pipefail

# Ctrl+B, A opens a temporary Herdr pane, detects Codex or Claude, asks for the
# target account and resumes the same native session under that profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/herdr-profile-switch"
BIN_DIR="$HOME/.local/bin"
SWITCH_BIN="$BIN_DIR/herdr-switch-agent-profile"
COMPAT_BIN="$BIN_DIR/herdr-server-compat"
CONFIG="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"

if ! command -v herdr >/dev/null 2>&1; then
  echo "[ezomar/herdr-profile-switch] herdr not found; skipping."
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[ezomar/herdr-profile-switch] jq ausente; ele é requisito do ambiente base." >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$(dirname "$CONFIG")"
install -m 0755 "$TPL/herdr-switch-agent-profile" "$SWITCH_BIN"
touch "$CONFIG"

# If the standalone updater replaced the binary but deliberately left a busy
# older server alive, the new CLI cannot speak the old socket protocol. Keep a
# copy of the executable inode used by that server until its next restart.
installed_version="$(herdr --version 2>/dev/null || true)"
while IFS= read -r server_pid; do
  server_exe="/proc/$server_pid/exe"
  [ -x "$server_exe" ] || continue
  server_version="$("$server_exe" --version 2>/dev/null || true)"
  if [ -n "$server_version" ] && [ "$server_version" != "$installed_version" ]; then
    install -m 0755 "$server_exe" "$COMPAT_BIN"
    echo "[ezomar/herdr-profile-switch] Preserved server-compatible CLI: $server_version"
    break
  fi
done < <(pgrep -u "$(id -u)" -f '(^|/)herdr server($| )' || true)

python3 - "$CONFIG" "$SWITCH_BIN" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
command = json.dumps(sys.argv[2])
start = "# >>> herdr agent profile switch (ezdora/ezomar) >>>"
end = "# <<< herdr agent profile switch (ezdora/ezomar) <<<"
block = f'''{start}
[[keys.command]]
key = "prefix+a"
type = "pane"
command = {command}
description = "switch agent account and resume session"
{end}'''

content = path.read_text()
managed_pairs = [
    (start, end),
    ("# >>> ezdora: herdr Codex profile switch >>>", "# <<< ezdora: herdr Codex profile switch <<<"),
    ("# >>> ezomar: herdr agent profile switch >>>", "# <<< ezomar: herdr agent profile switch <<<"),
]
for managed_start, managed_end in managed_pairs:
    while managed_start in content:
        before, rest = content.split(managed_start, 1)
        if managed_end not in rest:
            raise SystemExit(f"managed block starts but does not end in {path}")
        _, after = rest.split(managed_end, 1)
        content = before.rstrip() + "\n" + after.lstrip("\n")
content = content.rstrip() + "\n\n" + block + "\n"
path.write_text(content)
PY

echo "[ezomar/herdr-profile-switch] Installed $SWITCH_BIN"
echo "[ezomar/herdr-profile-switch] Shortcut: Ctrl+B, then A"

# Make the invoking Codex pane usable immediately. Normally SessionStart hooks
# provide this id; the current process predates the just-installed integration.
control_bin="herdr"
if ! herdr pane get "${HERDR_PANE_ID:-__none__}" >/dev/null 2>&1 \
    && [ -x "$COMPAT_BIN" ]; then
  control_bin="$COMPAT_BIN"
fi

if [ -n "${HERDR_PANE_ID:-}" ] && [ -n "${CODEX_THREAD_ID:-}" ]; then
  "$control_bin" pane report-agent-session "$HERDR_PANE_ID" \
    --source herdr:codex --agent codex --agent-session-id "$CODEX_THREAD_ID" \
    >/dev/null 2>&1 || true
fi

if "$control_bin" status server >/dev/null 2>&1; then
  "$control_bin" server reload-config >/dev/null \
    && echo "[ezomar/herdr-profile-switch] Running server reloaded." \
    || echo "[ezomar/herdr-profile-switch] Reload failed; shortcut applies on the next Herdr restart."
fi
