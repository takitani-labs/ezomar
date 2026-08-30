#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"
fake_bin="$TMP/bin"
systemctl_log="$TMP/systemctl.log"
mkdir -p "$HOME/.config/systemd/user" "$HOME/.local/bin" "$fake_bin"
printf '%s\n' '[Unit]' '[Service]' 'ExecStart=%h/.local/bin/herdr server' \
  >"$HOME/.config/systemd/user/herdr.service"
ln -s "$TMP/missing-herdr" "$HOME/.local/bin/herdr"

cat >"$fake_bin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '%s\n' 'herdr test'; fi
SH
cat >"$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$HERDR_TEST_SYSTEMCTL_LOG"
case "$*" in
  '--user is-enabled herdr.service') printf '%s\n' masked; exit 1 ;;
  '--user enable herdr.service') exit 99 ;;
esac
SH
chmod +x "$fake_bin/herdr" "$fake_bin/systemctl"
export HERDR_TEST_SYSTEMCTL_LOG="$systemctl_log"
export PATH="$fake_bin:$PATH"

bash "$ROOT/install/apps/56-herdr.sh"

[ -L "$HOME/.local/bin/herdr" ]
[ "$(readlink "$HOME/.local/bin/herdr")" = "$fake_bin/herdr" ]
if grep -Fxq -- '--user enable herdr.service' "$systemctl_log"; then
  echo 'masked herdr.service was enabled unexpectedly' >&2
  exit 1
fi

printf '%s\n' \
  "HERDR repaired dangling binary link: $(readlink "$HOME/.local/bin/herdr")" \
  'HERDR left persistent mask enabled until final restore step' \
  'herdr install: ok'
