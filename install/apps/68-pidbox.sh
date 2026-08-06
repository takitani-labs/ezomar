#!/usr/bin/env bash
set -euo pipefail

# Um kill(-1) disparado por uma suíte de testes alcança todos os processos que
# o usuário enxerga e pode derrubar a sessão inteira. Cgroups não limitam esse
# sinal; o pidbox cria um namespace de PID para que o estrago fique dentro da
# própria execução.
#
# No Arch, unshare vem de util-linux, parte do base. A ausência indica uma
# instalação quebrada e deve falhar claramente, sem instalar pacotes aqui.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/pidbox"
SOURCE="$TPL/pidbox"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/pidbox"

if ! command -v unshare >/dev/null 2>&1; then
  echo "[ezomar][pidbox] unshare não encontrado. No Arch ele vem de util-linux e deveria estar no sistema base." >&2
  exit 1
fi
if [ ! -f "$SOURCE" ]; then
  echo "[ezomar][pidbox] Template ausente: $SOURCE" >&2
  exit 1
fi

if [ -x "$BIN" ] && cmp -s "$SOURCE" "$BIN"; then
  echo "[ezomar][pidbox] Binário já instalado e atualizado. Pulando."
  exit 0
fi

MAX_USERNS="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)"
if [ "$MAX_USERNS" -lt 1 ]; then
  echo "[ezomar][pidbox] Aviso: namespaces de usuário sem privilégio estão desabilitados." >&2
  echo "[ezomar][pidbox] O pidbox recusará executar até user.max_user_namespaces ser habilitado." >&2
fi

mkdir -p "$BIN_DIR"
install -m 0755 "$SOURCE" "$BIN"

echo "[ezomar][pidbox] Verificando se o isolamento é real..."
if "$BIN" --check; then
  echo "[ezomar][pidbox] Provando que um kill(-1) real fica contido..."
  "$BIN" --check-hard || echo "[ezomar][pidbox] Aviso: a prova de contenção falhou." >&2
else
  echo "[ezomar][pidbox] Aviso: o isolamento falhou; o pidbox recusará executar." >&2
fi

echo "[ezomar][pidbox] Instalado. Exemplos: pidbox uv run pytest; pidbox npm test."
