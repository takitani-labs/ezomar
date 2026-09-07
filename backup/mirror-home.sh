#!/usr/bin/env bash
set -euo pipefail

# Espelha o $HOME inteiro, cru, para outra máquina da rede.
#
#   bash backup/mirror-home.sh kage                    espelha em kage:~/mirror-takidesk
#   bash backup/mirror-home.sh kage /mnt/big/espelho   escolhe o destino
#
# Por que existe, ao lado do backup-ai.sh: aquele é uma lista curada, e uma lista
# curada vale exatamente o que quem a escreveu lembrou de pôr nela. Medido hoje,
# depois de semanas de ajuste: Desktop, Public, Downloads, os consoles do
# DataGrip, as abas do Chrome e os cinco perfis do Firefox não estavam lá. São
# 27 GB de pastas comuns e mais um punhado de estado de aplicativo que ninguém
# repõe. Este script não decide nada: copia tudo e deixa a escolha para depois
# do format, quando dá para olhar com calma o que ficou.
#
# É seguro rodar com a frota viva. Nada aqui escreve no $HOME de origem, e o
# --delete atua apenas dentro do diretório de destino.
#
# Botões:
#   EZOMAR_MIRROR_DEST   caminho no destino (padrão ~/mirror-<hostname>)
#   EZOMAR_MIRROR_LEAN   true pula o que se regenera (node_modules, .venv,
#                        target, caches). Padrão false: numa cópia de segurança
#                        antes de formatar, o barato é copiar demais.

REMOTE="${1:-}"
DEST="${2:-${EZOMAR_MIRROR_DEST:-}}"
LEAN="${EZOMAR_MIRROR_LEAN:-false}"

say() { echo "[ezomar][mirror] $*"; }
die() { echo "[ezomar][mirror] $*" >&2; exit 1; }

[ -n "$REMOTE" ] || die "uso: bash backup/mirror-home.sh <host-ssh> [destino]"
command -v rsync >/dev/null 2>&1 || die "rsync ausente."

DEST="${DEST:-\$HOME/mirror-$(hostname)}"

ssh -o BatchMode=yes "$REMOTE" true 2>/dev/null \
  || die "não consigo abrir ssh sem senha para $REMOTE."

# Sempre fora: sockets e arquivos vivos que não sobrevivem à cópia, e a árvore
# de espelho do próprio destino, se alguém apontar para dentro do $HOME.
EXCLUDES=(
  --exclude='.gvfs/'
  --exclude='.cache/thumbnails/'
  --exclude='*.sock'
  --exclude='.Trash/'
  --exclude='.local/share/Trash/'
  --exclude='mirror-*/'
  # Um tmpfs montado dentro do $HOME copiaria RAM para disco sem ganho nenhum.
  --exclude='.cache/ksycoca*'
)

if [ "$LEAN" = true ]; then
  say "Modo enxuto: pulando o que se regenera."
  EXCLUDES+=(
    --exclude='node_modules/'
    --exclude='.venv/'
    --exclude='venv/'
    --exclude='target/debug/'
    --exclude='.cache/'
    --exclude='.local/share/JetBrains/Toolbox/'
    --exclude='.config/google-chrome/*/Service Worker/'
    --exclude='.config/google-chrome/*/IndexedDB/'
  )
fi

say "Origem : $HOME"
say "Destino: $REMOTE:$DEST"
say "Medindo o que vai (pode levar um minuto)..."

# --dry-run primeiro para o número aparecer antes de a cópia começar, e não
# depois de horas. O -H preserva hardlinks, o -A e o -X preservam ACL e xattr:
# este $HOME é cheio de symlink e de arquivo com atributo estendido, e uma cópia
# que os perde volta parecendo certa e quebra em detalhe meses depois.
TOTAL="$(rsync -aHAX --dry-run --stats "${EXCLUDES[@]}" \
  "$HOME/" "$REMOTE:$DEST/" 2>/dev/null \
  | grep -m1 'Total file size' | sed 's/.*: //' || true)"
say "Volume estimado: ${TOTAL:-desconhecido}"

say "Copiando. Interromper e rodar de novo continua de onde parou."
rsync -aHAX --info=progress2 --partial --delete-after "${EXCLUDES[@]}" \
  "$HOME/" "$REMOTE:$DEST/"

say "Pronto. Conferindo o que chegou:"
ssh "$REMOTE" "du -sh $DEST 2>/dev/null; echo; for d in Desktop Public Documents Downloads .mozilla .config/JetBrains; do
  [ -e \"$DEST/\$d\" ] && printf '  %-22s %s\n' \"\$d\" \"\$(du -sh \"$DEST/\$d\" 2>/dev/null | cut -f1)\"
done"
