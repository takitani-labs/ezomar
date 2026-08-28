#!/usr/bin/env bash
set -euo pipefail

# Roda na máquina NOVA, depois do install.sh. Restaura o tarball do backup-ai.sh.
#
#   bash backup/restore-ai.sh <ezomar-ai-*.tar.zst> [--force]
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
# So the move-aside set is always the leaf paths the backup actually archived
# (.config/opencode, .config/ai-usagebar, .local/share/opencode, .claude, ...),
# never their parents, and the parents are only ever created by tar itself.
# That list comes from the tarball (see PATHS_MEMBER below), so it cannot drift
# away from what the backup put in, which is how this property could rot.
#
# Knob:
#   EZOMAR_BACKUP_ONLY   restringe a restauração aos caminhos listados (mesma
#                        variável do backup-ai.sh, mesmo formato). Com ela, a
#                        extração também é limitada a esses membros.

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

# Nunca extraídos por cima: no ezomar o chezmoi é dono deles, e um tarball do
# ezarch os traz. Sobrescrever aqui trocaria calado o .zshrc de 591 linhas dos
# dotfiles pela versão de outra máquina. Viram *.from-backup, para merge à mão.
SAFE_SKIP=(.zshrc .tmux.conf .gitconfig)

# --- o que o tarball diz que tem -------------------------------------------------
RESTORE_PATHS=()
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

# --- conflitos --------------------------------------------------------------------
CONFLICTS=()
for p in "${RESTORE_PATHS[@]}"; do
  if [ -e "$HOME/$p" ] || [ -L "$HOME/$p" ]; then CONFLICTS+=("$p"); fi
done

if [ ${#CONFLICTS[@]} -gt 0 ] && [ "$FORCE" -ne 1 ]; then
  say "Já existem em \$HOME: ${CONFLICTS[*]}" >&2
  say "Rode com --force para movê-los para *.pre-restore.$STAMP e extrair." >&2
  exit 1
fi

for c in "${CONFLICTS[@]}"; do
  say "Movendo $c -> $c.pre-restore.$STAMP"
  mv "$HOME/$c" "$HOME/$c.pre-restore.$STAMP"
done

# --- extração ----------------------------------------------------------------------
MEMBERS=()
[ -n "${EZOMAR_BACKUP_ONLY:-}" ] && MEMBERS=("${RESTORE_PATHS[@]}")

say "Extraindo em \$HOME..."
set +e
zstd -dc "$TARBALL" | tar -C "$HOME" -xpf - \
  --transform='s|^\.zshrc$|.zshrc.from-backup|' \
  --transform='s|^\.tmux\.conf$|.tmux.conf.from-backup|' \
  --transform='s|^\.gitconfig$|.gitconfig.from-backup|' \
  ${MEMBERS[@]+"${MEMBERS[@]}"}
STATUS=("${PIPESTATUS[@]}")
set -e
[ "${STATUS[0]}" -eq 0 ] || die "zstd falhou (status ${STATUS[0]}); restauração incompleta."
[ "${STATUS[1]}" -le 1 ] || die "tar falhou (status ${STATUS[1]}); restauração incompleta."

for s in "${SAFE_SKIP[@]}"; do
  [ -e "$HOME/$s.from-backup" ] && say "$s veio como $s.from-backup (o chezmoi é dono do original)."
done

say "OK. Daqui:"
say "  1. bash backup/restore-repos.sh   reclona os repos nos mesmos caminhos"
say "  2. systemctl --user enable --now cli-proxy-api.service"
say "  3. conferir: claude, codex, ai-usagebar --vendor kimi"
[ ${#CONFLICTS[@]} -gt 0 ] && say "  (os *.pre-restore.$STAMP podem sumir depois de conferir)"
exit 0
