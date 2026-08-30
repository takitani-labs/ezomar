#!/usr/bin/env bash
set -euo pipefail

# Capture the parts of a working tree that a clone cannot reconstruct, while
# agents keep writing. GIT_OPTIONAL_LOCKS prevents read-only Git commands from
# refreshing indexes, so this script does not quietly mutate the repos it saves.
#
#   bash backup/backup-wip.sh [diretório-destino]
#
# Knob:
#   EZOMAR_REPO_ROOTS   ':'-separated roots (default ~/work/repos:~/Devel)

DEST_DIR="${1:-$HOME/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST_DIR/ezomar-wip-$STAMP.tar.zst"
export GIT_OPTIONAL_LOCKS=0

say() { echo "[ezomar][backup-wip] $*"; }
die() { echo "[ezomar][backup-wip] $*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git não encontrado."
command -v zstd >/dev/null 2>&1 || die "zstd não encontrado."

IFS=: read -r -a ROOTS <<<"${EZOMAR_REPO_ROOTS:-$HOME/work/repos:$HOME/Devel}"
SCAN_ROOTS=()
for root in "${ROOTS[@]}"; do [ -d "$root" ] && SCAN_ROOTS+=("$root"); done
[ ${#SCAN_ROOTS[@]} -gt 0 ] || die "nenhuma raiz de repos existe."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MANIFEST="$TMP_DIR/manifest.tsv"
: >"$MANIFEST"
mkdir -p "$TMP_DIR/repos"
mkdir -p "$TMP_DIR/shared"
TOTAL=0
WITH_WIP=0
CAPTURE_FAIL=0

while IFS= read -r -d '' gitdir; do
  is_bare=false
  if [ "${gitdir##*/}" = .git ]; then
    repo="${gitdir%/.git}"
  elif [ -d "$gitdir" ] \
       && [ "$(git --git-dir="$gitdir" rev-parse --is-bare-repository 2>/dev/null || true)" = true ]; then
    repo="$gitdir"
    is_bare=true
  else
    continue
  fi
  case "$repo" in */.git/*) continue ;; esac
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    say "Aviso: $repo tem .git inválido; não há um repositório legível para capturar."
    continue
  fi
  TOTAL=$((TOTAL + 1))
  id="$(printf '%06d' "$TOTAL")"
  artifact="$TMP_DIR/repos/$id"
  mkdir -p "$artifact"
  rel="${repo#"$HOME"/}"
  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || printf '%s' '-')"
  head="$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null || printf '%s' '-')"
  remote="$(git -C "$repo" remote get-url origin 2>/dev/null || printf '%s' '-')"
  common_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  common_key="$(printf '%s' "$(readlink -f "$common_dir")" | sha256sum | cut -d' ' -f1)"
  owns_refs=false
  if [ "$is_bare" = true ] \
     || [ "$(readlink -f "$common_dir")" = "$(readlink -f "$repo/.git")" ]; then
    owns_refs=true
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" \
    "$(printf '%s' "$rel" | base64 -w0)" \
    "$(printf '%s' "$branch" | base64 -w0)" \
    "$(printf '%s' "$remote" | base64 -w0)" \
    "$common_key" \
    "$owns_refs" \
    "$(printf '%s' "$head" | base64 -w0)" \
    "$is_bare" >>"$MANIFEST"
  kept=0

  # Linked worktrees share every ref and object with the main checkout. Bundling
  # refs in each worktree multiplies gigabytes without preserving one extra
  # commit; the main checkout owns the bundle while every distinct patch and
  # untracked file is still captured below.
  if [ "$owns_refs" = true ] && [ -n "$(git -C "$repo" rev-list --branches --tags --not --remotes 2>/dev/null | head -1)" ]; then
    if git -C "$repo" bundle create "$TMP_DIR/shared/$common_key-commits.bundle" --branches --tags --not --remotes >/dev/null 2>&1; then
      kept=$((kept + 1))
    else
      rm -f "$TMP_DIR/shared/$common_key-commits.bundle"
      say "Aviso: $rel tem commits sem remote, mas o bundle falhou."
      CAPTURE_FAIL=$((CAPTURE_FAIL + 1))
    fi
  fi

  # A linked worktree's detached HEAD has no ref in the shared common dir. Give
  # it an artifact of its own whenever the commit is not recoverable remotely.
  if [ "$branch" = - ] && [ "$head" != - ] \
     && [ -n "$(git -C "$repo" rev-list HEAD --not --remotes 2>/dev/null | head -1)" ]; then
    if git -C "$repo" bundle create "$artifact/detached.bundle" HEAD --not --remotes >/dev/null 2>&1; then
      kept=$((kept + 1))
    else
      rm -f "$artifact/detached.bundle"
      say "Aviso: não consegui empacotar o HEAD destacado de $rel."
      CAPTURE_FAIL=$((CAPTURE_FAIL + 1))
    fi
  fi

  if [ "$owns_refs" = true ] && git -C "$repo" rev-parse --verify refs/stash >/dev/null 2>&1; then
    if git -C "$repo" bundle create "$TMP_DIR/shared/$common_key-stash.bundle" refs/stash >/dev/null 2>&1; then
      kept=$((kept + 1))
    else
      rm -f "$TMP_DIR/shared/$common_key-stash.bundle"
      say "Aviso: não consegui empacotar o stash de $rel."
      CAPTURE_FAIL=$((CAPTURE_FAIL + 1))
    fi
  fi

  if [ "$is_bare" = false ] && git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$repo" diff --binary HEAD >"$artifact/worktree.patch"
  elif [ "$is_bare" = false ]; then
    git -C "$repo" diff --binary --cached >"$artifact/worktree.patch"
    git -C "$repo" diff --binary >"$artifact/unstaged.patch"
  fi
  for patch in "$artifact/worktree.patch" "$artifact/unstaged.patch"; do
    if [ -s "$patch" ]; then kept=$((kept + 1)); else rm -f "$patch"; fi
  done

  if [ "$is_bare" = false ]; then
    git -C "$repo" ls-files --others --exclude-standard -z >"$artifact/untracked.list"
    if [ -s "$artifact/untracked.list" ]; then
      tar -C "$repo" --null --verbatim-files-from -T "$artifact/untracked.list" -cf "$artifact/untracked.tar"
      kept=$((kept + 1))
    fi
    rm -f "$artifact/untracked.list"
  fi

  if [ "$kept" -eq 0 ]; then
    rmdir "$artifact"
  else
    WITH_WIP=$((WITH_WIP + 1))
    say "$rel: $kept artefato(s)."
  fi
done < <(find "${SCAN_ROOTS[@]}" \
  \( -type d -name '*.git' -prune -print0 \) -o \
  \( -type f -name .git -print0 \) 2>/dev/null | sort -z)

[ "$CAPTURE_FAIL" -eq 0 ] || die "$CAPTURE_FAIL artefato(s) obrigatório(s) falharam; nenhum tarball incompleto será mantido."
mkdir -p "$DEST_DIR"
# Git bundles are already compressed and can be gigabytes. Removing each staged
# artifact only after tar has streamed it prevents staging plus final output
# from briefly requiring twice the fleet's size; the trap still owns leftovers.
tar --remove-files -C "$TMP_DIR" -cf - manifest.tsv repos shared 2>/dev/null | zstd -T0 -8 -q -o "$OUT"
(cd "$DEST_DIR" && sha256sum "$(basename "$OUT")" >"$(basename "$OUT").sha256")

say "OK: $OUT ($(du -h "$OUT" | cut -f1))"
say "$TOTAL repo(s) lidos sem alterar histórico; $WITH_WIP com artefatos não vazios."
say "Checksum: $OUT.sha256"
