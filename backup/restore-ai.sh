#!/usr/bin/env bash
set -euo pipefail

# Roda na máquina NOVA. Primeiro restaura as credenciais que destravam o
# install.sh; depois do chezmoi, restaura todo o restante.
#
#   EZOMAR_BACKUP_ONLY='.ssh .gnupg' bash backup/restore-ai.sh <tar>
#   bash install.sh
#   bash backup/restore-ai.sh <tar> [--force]
#
# A PROPRIEDADE DE SEGURANÇA DESTE SCRIPT: mover de lado apenas os caminhos
# exatos que serão restaurados, nunca as raízes que os contêm.
#
# The obvious implementation moves ~/.config aside before extracting
# .config/opencode and .config/ai-usagebar into it. On this machine that is
# catastrophic and silent: ~/.config on a freshly installed Omarchy holds hypr/,
# waybar/, ghostty/, omarchy/ and everything else the install just wrote, and
# this tarball has none of it, so the desktop comes back stripped and the
# evidence is hidden inside a .pre-restore directory nobody thinks to look in.
# The same applies to ~/.local and ~/.
#
# So extraction is staged and merged without deletion. Existing files are kept
# by default; --force backs up only each overwritten leaf, never its parent.
# Paths owned by chezmoi are excluded from both modes at restore time.
#
# Knob:
#   EZOMAR_BACKUP_ONLY   restringe a restauração aos caminhos listados (mesma
#                        variável do backup-ai.sh, mesmo formato). Com ela, a
#                        extração também é limitada a esses membros.
#   EZOMAR_DEFER_HERDR_SESSION  true deixa session.json no tarball para o
#                        orquestrador colocá-lo só depois de repos e perfis.
#   EZOMAR_RESTORE_STAGING_DIR  diretório pai da área temporária; por padrão
#                        fica em ~/.ezomar-restore-staging, ao lado do destino.

PATHS_MEMBER=".ezomar-backup-paths"
STAMP="$(date +%s)"

say() { echo "[ezomar][restore-ai] $*"; }
die() { echo "[ezomar][restore-ai] $*" >&2; exit 1; }

TARBALL=""
FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -*)      die "opção desconhecida: $a" ;;
    *)       TARBALL="$a" ;;
  esac
done
[ -n "$TARBALL" ] || die "uso: restore-ai.sh <ezomar-ai-*.tar.zst> [--force]"
[ -f "$TARBALL" ] || die "$TARBALL não existe."
command -v zstd >/dev/null 2>&1 || die "zstd não instalado (pacman -S zstd)."
command -v rsync >/dev/null 2>&1 || die "rsync não instalado."

# The payload is larger than /tmp on the format-day machine. Keep staging on
# HOME's filesystem by default; an external disk can be selected explicitly.
STAGING_PARENT="${EZOMAR_RESTORE_STAGING_DIR:-$HOME/.ezomar-restore-staging}"
mkdir -p "$STAGING_PARENT"
TMP_DIR="$(mktemp -d --tmpdir="$STAGING_PARENT" restore-ai.XXXXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# The backup is deliberately only the complement of chezmoi. Restore must ask
# the current source again because ownership can grow between backup and
# restore; guessing from a stale hardcoded list would clobber the new files.
command -v chezmoi >/dev/null 2>&1 || {
  die "chezmoi não está disponível; recusando restaurar sem saber quais caminhos ele gerencia. Instale só o binário e rode de novo."
}
MANAGED_FILE="$TMP_DIR/managed-paths"
# `chezmoi managed` also prints directory ancestors. Those ancestors are not
# ownership claims over the whole subtree: ~/.claude can be listed because
# settings.json is managed while projects/ remains backup-owned. Files and
# symlinks are the actual leaves. A managed directory symlink is itself a leaf,
# and excluding that exact path correctly protects the link and its subtree.
if ! chezmoi managed --include=files,symlinks --path-style absolute >"$MANAGED_FILE" 2>/dev/null; then
  die "chezmoi não respondeu; recusando restaurar e arriscar arquivos gerenciados."
fi
# A fresh machine with only the chezmoi binary legitimately returns an empty
# list before `chezmoi init`. The non-force credential bootstrap is safe then:
# rsync still preserves every pre-existing destination. A forced restore is
# different and must wait until the dotfiles source provides an ownership map.
if [ ! -s "$MANAGED_FILE" ]; then
  if [ "$FORCE" -eq 1 ]; then
    die "chezmoi não listou nenhum arquivo/symlink gerenciado; recusando --force antes de o source de dotfiles existir."
  fi
  say "Chezmoi ainda sem source; passagem sem --force manterá tudo que já existe."
fi

if [ -f "$TARBALL.sha256" ]; then
  say "Conferindo o checksum..."
  (cd "$(dirname "$TARBALL")" && sha256sum -c "$(basename "$TARBALL").sha256") \
    || die "checksum não bate; a cópia veio corrompida."
else
  say "Sem $TARBALL.sha256; seguindo sem conferir a integridade."
fi

# Tarballs do ezarch (o repo irmão, anterior a este) não trazem o manifesto de
# caminhos. Para esses, a lista abaixo é o espelho do que aquele backup-ai.sh
# arquivava, e o conteúdo real é descoberto listando o tarball.
LEGACY_PATHS=(
  .claude .claude-profiles .claude.json
  .codex .codex-profiles .kimi .kimi-code .gemini .grok
  .config/opencode .local/share/opencode
  .cli-proxy-api .cli-proxy-api-exato .config/ai-usagebar
  .ssh .gnupg .aws .kube .config/gh .pgpass .npmrc .docker/config.json
  .bw-profiles .config/meeting-rig
)

# --- o que o tarball diz que tem -------------------------------------------------
RESTORE_PATHS=()

# --occurrence=1 faz o tar parar no primeiro membro, que o backup grava
# justamente para isso: ler a lista sem descompactar o tarball inteiro. O tar
# sai antes do fim do stream, o zstd leva SIGPIPE, e é por isso que o status
# aqui não vale nada; o que vale é o arquivo ter aparecido.
zstd -dc "$TARBALL" 2>/dev/null | tar -C "$TMP_DIR" -x --occurrence=1 -f - "$PATHS_MEMBER" 2>/dev/null || true
if [ -s "$TMP_DIR/$PATHS_MEMBER" ]; then
  mapfile -t RESTORE_PATHS <"$TMP_DIR/$PATHS_MEMBER"
  say "Manifesto embutido: ${#RESTORE_PATHS[@]} caminho(s)."
else
  say "Tarball sem $PATHS_MEMBER (formato ezarch); listando o conteúdo, o que demora."
  # Um set, não um `grep -q` num pipe: sob pipefail o grep fecha o pipe cedo e
  # transforma um casamento bem-sucedido em pipeline com erro.
  declare -A IN_TAR=()
  while IFS= read -r line; do IN_TAR["${line%/}"]=1; done < <(zstd -dc "$TARBALL" | tar -tf -)
  for p in "${LEGACY_PATHS[@]}"; do
    [ -n "${IN_TAR[$p]:-}" ] && RESTORE_PATHS+=("$p")
  done
  say "Encontrados ${#RESTORE_PATHS[@]} caminho(s) conhecidos dentro do tarball."
fi
[ ${#RESTORE_PATHS[@]} -gt 0 ] || die "não há nada reconhecível para restaurar neste tarball."

if [ -n "${EZOMAR_BACKUP_ONLY:-}" ]; then
  read -r -a ONLY <<<"$EZOMAR_BACKUP_ONLY"
  FILTERED=()
  for p in "${RESTORE_PATHS[@]}"; do
    for o in "${ONLY[@]}"; do
      if [ "$p" = "$o" ]; then FILTERED+=("$p"); break; fi
    done
  done
  RESTORE_PATHS=("${FILTERED[@]}")
  [ ${#RESTORE_PATHS[@]} -gt 0 ] || die "EZOMAR_BACKUP_ONLY não casa com nada dentro do tarball."
  say "EZOMAR_BACKUP_ONLY ativo: restaurando só ${RESTORE_PATHS[*]}"
fi

# --- ownership and staged extraction ---------------------------------------------
# A managed leaf is kept even when absent: restoring an old copy there would
# still steal ownership from the dotfiles source on the next apply.
MANAGED_PATHS=()
PRESERVED=0
while IFS= read -r absolute; do
  [ -n "$absolute" ] || continue
  case "$absolute" in "$HOME"/*) managed="${absolute#"$HOME"/}" ;; *) continue ;; esac
  for root in "${RESTORE_PATHS[@]}"; do
    case "$managed" in "$root"|"$root"/*)
      MANAGED_PATHS+=("$managed")
      PRESERVED=$((PRESERVED + 1))
      break
      ;;
    esac
  done
done <"$MANAGED_FILE"
if [ "${EZOMAR_DEFER_HERDR_SESSION:-false}" = "true" ]; then
  say "session.json do herdr ficará no tarball até a etapa final."
fi
say "Caminhos gerenciados pelo chezmoi preservados: $PRESERVED."

PAYLOAD="$TMP_DIR/payload"
mkdir -p "$PAYLOAD"

# Measure the selected uncompressed members, not the compressed tarball. A zstd
# ratio is not a capacity estimate, and /tmp is a 62 GiB tmpfs on the target.
SIZE_FILE="$TMP_DIR/payload-bytes"
say "Medindo o payload descompactado antes de reservar espaço..."
set +e
LC_ALL=C zstd -dc "$TARBALL" \
  | LC_ALL=C tar -tvf - "${RESTORE_PATHS[@]}" \
  | awk '$1 ~ /^-/ { total += $3 } END { printf "%.0f\n", total + 0 }' >"$SIZE_FILE"
STATUS=("${PIPESTATUS[@]}")
set -e
[ "${STATUS[0]}" -eq 0 ] || die "zstd falhou ao medir o payload (status ${STATUS[0]})."
[ "${STATUS[1]}" -le 1 ] || die "tar falhou ao medir o payload (status ${STATUS[1]})."
[ "${STATUS[2]}" -eq 0 ] || die "não consegui somar o tamanho do payload."
PAYLOAD_BYTES="$(<"$SIZE_FILE")"
AVAILABLE_BYTES="$(df -Pk "$TMP_DIR" | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')"
SAFETY_BYTES=$((PAYLOAD_BYTES / 20))
[ "$SAFETY_BYTES" -ge 1073741824 ] || SAFETY_BYTES=1073741824
STAGING_DEVICE="$(stat -c %d "$TMP_DIR")"
HOME_DEVICE="$(stat -c %d "$HOME")"
if [ "$STAGING_DEVICE" = "$HOME_DEVICE" ]; then
  # Until the trap removes staging, rsync needs both the extracted source and
  # the merged destination. Forced backups are renames on this same filesystem.
  REQUIRED_BYTES=$((PAYLOAD_BYTES * 2 + SAFETY_BYTES))
  if [ "$AVAILABLE_BYTES" -lt "$REQUIRED_BYTES" ]; then
    die "espaço insuficiente em $STAGING_PARENT: extração+mesclagem=$((PAYLOAD_BYTES * 2)) bytes, margem=$SAFETY_BYTES, livre=$AVAILABLE_BYTES. Defina EZOMAR_RESTORE_STAGING_DIR para outro disco."
  fi
else
  REQUIRED_BYTES=$((PAYLOAD_BYTES + SAFETY_BYTES))
  HOME_AVAILABLE_BYTES="$(df -Pk "$HOME" | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }')"
  if [ "$AVAILABLE_BYTES" -lt "$REQUIRED_BYTES" ]; then
    die "espaço insuficiente no staging $STAGING_PARENT: payload=$PAYLOAD_BYTES bytes, margem=$SAFETY_BYTES, livre=$AVAILABLE_BYTES."
  fi
  if [ "$HOME_AVAILABLE_BYTES" -lt "$REQUIRED_BYTES" ]; then
    die "espaço insuficiente em $HOME para mesclar: payload=$PAYLOAD_BYTES bytes, margem=$SAFETY_BYTES, livre=$HOME_AVAILABLE_BYTES."
  fi
fi
say "Espaço conferido em $STAGING_PARENT: payload=$PAYLOAD_BYTES bytes; livre=$AVAILABLE_BYTES."

say "Extraindo o conteúdo pedido para uma área temporária..."
set +e
zstd -dc "$TARBALL" | tar -C "$PAYLOAD" -xpf - "${RESTORE_PATHS[@]}"
STATUS=("${PIPESTATUS[@]}")
set -e
[ "${STATUS[0]}" -eq 0 ] || die "zstd falhou (status ${STATUS[0]}); restauração incompleta."
[ "${STATUS[1]}" -le 1 ] || die "tar falhou (status ${STATUS[1]}); restauração incompleta."

RSYNC_ARGS=(-a --omit-dir-times)
if [ "$FORCE" -eq 1 ]; then
  BACKUP_DIR="$HOME/.ezomar-pre-restore/$STAMP"
  mkdir -p "$BACKUP_DIR"
  say "Mesclando em \$HOME; folhas substituídas vão para $BACKUP_DIR."
else
  RSYNC_ARGS+=(--ignore-existing)
  say "Mesclando em \$HOME sem sobrescrever caminhos existentes."
fi
for root in "${RESTORE_PATHS[@]}"; do
  [ -e "$PAYLOAD/$root" ] || [ -L "$PAYLOAD/$root" ] || continue
  # Passing each archived root avoids treating $HOME itself as a transfer
  # member. Its permissions belong to the installed OS, not to this tarball.
  parent="${root%/*}"
  [ "$parent" = "$root" ] && parent="."
  dest_parent="$HOME/$parent"
  mkdir -p "$dest_parent"
  ROOT_RSYNC_ARGS=("${RSYNC_ARGS[@]}")
  if [ "$FORCE" -eq 1 ]; then
    # Preserve the archived root's parent in the backup tree. Otherwise
    # .config/herdr/x and .local/state/herdr/x both become herdr/x and collide.
    mkdir -p "$BACKUP_DIR/$parent"
    ROOT_RSYNC_ARGS+=(--backup --backup-dir="$BACKUP_DIR/$parent")
  fi
  ROOT_EXCLUDES=()
  for managed in "${MANAGED_PATHS[@]}"; do
    case "$managed" in "$root"|"$root"/*)
      transfer_path="$managed"
      [ "$parent" = "." ] || transfer_path="${managed#"$parent"/}"
      ROOT_EXCLUDES+=(--exclude="/$transfer_path")
      ;;
    esac
  done
  if [ "${EZOMAR_DEFER_HERDR_SESSION:-false}" = "true" ]; then
    deferred_session=".config/herdr/session.json"
    case "$deferred_session" in "$root"|"$root"/*)
      transfer_path="$deferred_session"
      [ "$parent" = "." ] || transfer_path="${transfer_path#"$parent"/}"
      ROOT_EXCLUDES+=(--exclude="/$transfer_path")
      ;;
    esac
  fi
  rsync "${ROOT_RSYNC_ARGS[@]}" "${ROOT_EXCLUDES[@]}" "$PAYLOAD/$root" "$dest_parent/"
done

say "OK. Daqui:"
say "  1. bash backup/restore-repos.sh   reclona os repos nos mesmos caminhos"
say "  2. systemctl --user enable --now cli-proxy-api.service"
say "  3. conferir: claude, codex, ai-usagebar --vendor kimi"
if [ "$FORCE" -eq 1 ]; then
  say "  (a árvore $BACKUP_DIR pode sumir depois de conferir)"
fi
exit 0
