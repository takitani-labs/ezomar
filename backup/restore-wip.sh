#!/usr/bin/env bash
set -euo pipefail

# Run after restore-repos.sh. Every update is a fast-forward or a clean apply;
# divergence and collisions are reported because format recovery is the worst
# possible time to turn an implicit force into data loss.
#
#   bash backup/restore-wip.sh <ezomar-wip-*.tar.zst>

say() { echo "[ezomar][restore-wip] $*"; }
die() { echo "[ezomar][restore-wip] $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "uso: restore-wip.sh <ezomar-wip-*.tar.zst>"
TARBALL="$1"
[ -f "$TARBALL" ] || die "$TARBALL não existe."
command -v zstd >/dev/null 2>&1 || die "zstd não encontrado."
command -v rsync >/dev/null 2>&1 || die "rsync não encontrado."

if [ -f "$TARBALL.sha256" ]; then
  (cd "$(dirname "$TARBALL")" && sha256sum -c "$(basename "$TARBALL").sha256") \
    || die "checksum não bate."
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
zstd -dc "$TARBALL" | tar -C "$TMP_DIR" -xpf -
[ -s "$TMP_DIR/manifest.tsv" ] || die "manifesto ausente."

OK=0
PARTIAL=0
FAIL=0

bundle_has_prerequisite() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || return 1
    case "$line" in -*) return 0 ;; esac
  done <"$1"
  return 1
}

while IFS=$'\t' read -r id rel64 branch64 remote64 common_key owns_refs head64 is_bare; do
  [ -n "${id:-}" ] || continue
  rel="$(printf '%s' "$rel64" | base64 -d)"
  branch="$(printf '%s' "$branch64" | base64 -d)"
  remote="$(printf '%s' "$remote64" | base64 -d)"
  head="-"
  [ -z "${head64:-}" ] || head="$(printf '%s' "$head64" | base64 -d)"
  is_bare="${is_bare:-false}"
  artifact="$TMP_DIR/repos/$id"
  commits_bundle="$TMP_DIR/shared/$common_key-commits.bundle"
  stash_bundle="$TMP_DIR/shared/$common_key-stash.bundle"
  detached_bundle="$artifact/detached.bundle"
  [ -d "$artifact" ] || [ -f "$commits_bundle" ] || [ -f "$stash_bundle" ] || continue
  repo="$HOME/$rel"
  applied=()
  missed=()
  checkout_ok=true

  repo_exists() {
    if [ "$is_bare" = true ]; then
      [ -d "$repo" ] && git --git-dir="$repo" rev-parse --git-dir >/dev/null 2>&1
    else
      [ -e "$repo/.git" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1
    fi
  }
  repo_git() {
    if [ "$is_bare" = true ]; then
      git --git-dir="$repo" "$@"
    else
      git -C "$repo" "$@"
    fi
  }

  if ! repo_exists && [ "$remote" != "-" ]; then
    mkdir -p "$(dirname "$repo")"
    clone_args=(--quiet)
    [ "$is_bare" = false ] || clone_args+=(--bare)
    if git clone "${clone_args[@]}" "$remote" "$repo" 2>/dev/null; then
      applied+=("repo reclonado pelo remote do WIP")
    else
      missed+=("remote não pôde recriar o repo ausente")
    fi
  fi

  if ! repo_exists && [ -f "$commits_bundle" ]; then
    # A bundle without prerequisites belongs to a repo with no remote at all
    # and can seed it. A thin bundle needs restore-repos to provide its base.
    if ! bundle_has_prerequisite "$commits_bundle"; then
      mkdir -p "$(dirname "$repo")"
      clone_args=(--quiet)
      [ "$is_bare" = false ] || clone_args+=(--bare)
      # A bare tag-only repo still has a symbolic HEAD name (often master), but
      # no branch by that name. Let clone seed every advertised ref; the normal
      # import/checkout path below selects an archived branch when one exists.
      if git clone "${clone_args[@]}" "$commits_bundle" "$repo" 2>/dev/null; then
        applied+=("repo recriado do bundle")
      else
        missed+=("não consegui recriar o repo pelo bundle")
      fi
    fi
  fi

  if ! repo_exists && [ -f "$detached_bundle" ] \
     && ! bundle_has_prerequisite "$detached_bundle" && [ "$is_bare" = false ]; then
    mkdir -p "$repo"
    git -C "$repo" init --quiet
    if git -C "$repo" fetch --quiet "$detached_bundle" HEAD 2>/dev/null; then
      applied+=("repo recriado do bundle de HEAD destacado")
    fi
  fi

  # An unborn repository has no commit to bundle. Its two patches and
  # untracked archive are nevertheless a complete content snapshot, so create
  # an empty checkout on the archived branch instead of reporting it absent.
  # This is also what lets worktree.patch (index vs. empty tree) land before
  # unstaged.patch (working tree vs. index), preserving later unstaged edits.
  if ! repo_exists && [ "$is_bare" = false ] && [ "$head" = - ] \
     && { [ -f "$artifact/worktree.patch" ] \
          || [ -f "$artifact/unstaged.patch" ] \
          || [ -f "$artifact/untracked.tar" ]; }; then
    mkdir -p "$repo"
    init_args=(--quiet)
    [ "$branch" = - ] || init_args+=(--initial-branch="$branch")
    if git -C "$repo" init "${init_args[@]}"; then
      if [ "$remote" != - ]; then
        git -C "$repo" remote add origin "$remote" 2>/dev/null || true
      fi
      applied+=("repo vazio recriado para o WIP sem commits")
    else
      missed+=("repo vazio não pôde ser recriado")
    fi
  fi

  if ! repo_exists; then
    say "  ! $rel: repo ausente; restore-repos não forneceu a base"
    FAIL=$((FAIL + 1))
    continue
  fi

  if [ -f "$commits_bundle" ]; then
    namespace="refs/ezomar-wip/$id"
    if repo_git bundle verify "$commits_bundle" >/dev/null 2>&1; then
      while IFS=' ' read -r sha ref; do
        [ -n "${ref:-}" ] || continue
        case "$ref" in
          refs/heads/*)
            name="${ref#refs/heads/}"
            if [ "$owns_refs" != true ] && [ "$name" != "$branch" ]; then
              continue
            fi
            source_ref="$namespace/heads/$name"
            if ! repo_git fetch --quiet --no-tags "$commits_bundle" "$ref:$source_ref" 2>/dev/null; then
              missed+=("branch $name não pôde ser lida do bundle")
              continue
            fi
            dest_ref="refs/heads/$name"
            if ! old="$(repo_git rev-parse --verify "$dest_ref" 2>/dev/null)"; then
              repo_git branch "$name" "$source_ref" >/dev/null
              applied+=("branch $name criada")
            elif repo_git merge-base --is-ancestor "$old" "$sha"; then
              current="$(repo_git symbolic-ref --short HEAD 2>/dev/null || true)"
              if [ "$is_bare" = false ] && [ "$current" = "$name" ]; then
                if repo_git merge --ff-only --quiet "$source_ref" 2>/dev/null; then
                  applied+=("branch $name avançada")
                else
                  missed+=("branch $name não avançou com fast-forward limpo")
                fi
              elif [ "$is_bare" = false ] \
                   && repo_git worktree list --porcelain | grep -Fxq "branch $dest_ref"; then
                applied+=("branch $name pertence a outro worktree; adiada para ele")
              elif repo_git update-ref "$dest_ref" "$sha" "$old"; then
                applied+=("branch $name avançada")
              else
                missed+=("branch $name mudou durante a restauração")
              fi
            elif repo_git merge-base --is-ancestor "$sha" "$old"; then
              applied+=("branch $name já continha o bundle")
            else
              missed+=("branch $name divergiu; nenhuma força aplicada")
            fi
            ;;
          refs/tags/*)
            [ "$owns_refs" = true ] || continue
            name="${ref#refs/tags/}"
            source_ref="$namespace/tags/$name"
            if ! repo_git fetch --quiet --no-tags "$commits_bundle" "$ref:$source_ref" 2>/dev/null; then
              missed+=("tag $name não pôde ser lida do bundle")
              continue
            fi
            dest_ref="refs/tags/$name"
            if ! old="$(repo_git rev-parse --verify "$dest_ref" 2>/dev/null)"; then
              repo_git update-ref "$dest_ref" "$sha"
              applied+=("tag $name criada")
            elif [ "$old" = "$sha" ]; then
              applied+=("tag $name já presente")
            else
              missed+=("tag $name divergiu; nenhuma força aplicada")
            fi
            ;;
        esac
      done < <(git bundle list-heads "$commits_bundle" | grep -E ' refs/(heads|tags)/' || true)
    else
      missed+=("bundle de commits precisa de uma base que não está neste clone")
    fi
  fi

  if [ "$owns_refs" = true ] && [ -f "$stash_bundle" ]; then
    stash_ref="refs/ezomar-wip/$id/stash"
    if repo_git fetch --quiet --no-tags "$stash_bundle" "refs/stash:$stash_ref" 2>/dev/null; then
      stash_sha="$(repo_git rev-parse "$stash_ref")"
      if repo_git reflog show --format=%H refs/stash 2>/dev/null | grep -Fxq "$stash_sha"; then
        applied+=("stash já presente")
      elif [ "$is_bare" = false ] && repo_git stash store -m "ezomar format recovery" "$stash_sha" >/dev/null; then
        applied+=("stash restaurado")
      elif [ "$is_bare" = true ] && repo_git update-ref refs/stash "$stash_sha"; then
        applied+=("stash restaurado")
      else
        missed+=("stash não pôde ser registrado")
      fi
    else
      missed+=("bundle do stash não aplicou")
    fi
  fi

  if [ -f "$detached_bundle" ]; then
    detached_ref="refs/ezomar-wip/$id/detached"
    if repo_git fetch --quiet --no-tags "$detached_bundle" "HEAD:$detached_ref" 2>/dev/null; then
      [ "$head" != - ] || head="$(repo_git rev-parse "$detached_ref")"
      applied+=("HEAD destacado importado")
    else
      missed+=("bundle do HEAD destacado não aplicou")
      checkout_ok=false
    fi
  fi

  # Always select the archived checkout before applying its patch. restore-repos
  # can leave an already-existing repo on main even when the saved WIP belongs
  # to an unpushed branch.
  if [ "$is_bare" = false ]; then
    if [ "$branch" != - ]; then
      current="$(repo_git symbolic-ref --short HEAD 2>/dev/null || true)"
      if [ "$current" != "$branch" ]; then
        if ! repo_git show-ref --verify --quiet "refs/heads/$branch" \
           && [ "$head" != - ] \
           && repo_git cat-file -e "$head^{commit}" 2>/dev/null; then
          if repo_git branch "$branch" "$head" >/dev/null 2>&1; then
            applied+=("branch $branch recriada no HEAD arquivado")
          fi
        fi
        if repo_git checkout --quiet "$branch" 2>/dev/null; then
          applied+=("branch $branch selecionada")
        else
          missed+=("branch $branch não pôde ser selecionada; patches não aplicados")
          checkout_ok=false
        fi
      fi
    elif [ "$head" != - ]; then
      if repo_git cat-file -e "$head^{commit}" 2>/dev/null \
         && repo_git checkout --quiet --detach "$head" 2>/dev/null; then
        applied+=("HEAD destacado selecionado")
      else
        missed+=("HEAD destacado $head não pôde ser selecionado; patches não aplicados")
        checkout_ok=false
      fi
    elif [ -f "$artifact/worktree.patch" ] || [ -f "$artifact/unstaged.patch" ]; then
      missed+=("backup antigo sem branch/HEAD; patches não aplicados fora do checkout original")
      checkout_ok=false
    fi
  fi

  for patch_name in worktree.patch unstaged.patch; do
    patch="$artifact/$patch_name"
    [ -f "$patch" ] || continue
    if [ "$checkout_ok" = false ]; then
      continue
    elif repo_git apply --check "$patch" 2>/dev/null; then
      repo_git apply "$patch"
      applied+=("$patch_name aplicado")
    elif repo_git apply --reverse --check "$patch" 2>/dev/null; then
      applied+=("$patch_name já estava aplicado")
    else
      missed+=("$patch_name conflita; mantido no tarball")
    fi
  done

  if [ -f "$artifact/untracked.tar" ]; then
    if [ "$checkout_ok" = false ] || [ "$is_bare" = true ]; then
      missed+=("não rastreados não aplicados fora do checkout arquivado")
    else
      untracked="$TMP_DIR/untracked-$id"
      mkdir -p "$untracked"
      tar -C "$untracked" -xf "$artifact/untracked.tar"
      added=0
      conflicts=0
      blocked=()
      untracked_excludes=()
      while IFS= read -r -d '' source; do
        item="${source#"$untracked"/}"
        is_blocked=false
        for blocked_item in "${blocked[@]}"; do
          case "$item" in "$blocked_item"/*) is_blocked=true; break ;; esac
        done
        [ "$is_blocked" = false ] || continue
        target="$repo/$item"
        if [ -L "$source" ]; then
          source_kind="link"
        elif [ -d "$source" ]; then
          source_kind="dir"
        elif [ -f "$source" ]; then
          source_kind="file"
        else
          source_kind="other"
        fi

        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
          [ "$source_kind" = dir ] || added=$((added + 1))
        elif [ "$source_kind" = dir ] && [ -d "$target" ] && [ ! -L "$target" ]; then
          :
        elif [ "$source_kind" = file ] && [ -f "$target" ] && [ ! -L "$target" ] \
             && cmp -s "$source" "$target"; then
          untracked_excludes+=(--exclude="/$item")
        elif [ "$source_kind" = link ] && [ -L "$target" ] \
             && [ "$(readlink "$source")" = "$(readlink "$target")" ]; then
          untracked_excludes+=(--exclude="/$item")
        else
          conflicts=$((conflicts + 1))
          untracked_excludes+=(--exclude="/$item")
          [ "$source_kind" != dir ] || blocked+=("$item")
        fi
      done < <(find "$untracked" -mindepth 1 -print0 | sort -z)

      if rsync -a --ignore-existing "${untracked_excludes[@]}" "$untracked/" "$repo/"; then
        applied+=("$added não rastreado(s) restaurado(s)")
      else
        missed+=("rsync dos não rastreados falhou; resultado parcial, artefato mantido")
      fi
      [ "$conflicts" -eq 0 ] || missed+=("$conflicts conflito(s) de tipo/conteúdo em não rastreados")
    fi
  fi

  say "  + $rel: ${applied[*]:-nada a aplicar}"
  if [ ${#missed[@]} -gt 0 ]; then
    printf '[ezomar][restore-wip]     ! %s\n' "${missed[@]}"
    PARTIAL=$((PARTIAL + 1))
  else
    OK=$((OK + 1))
  fi
done <"$TMP_DIR/manifest.tsv"

say "repos completos: $OK | parciais: $PARTIAL | ausentes: $FAIL"
[ "$PARTIAL" -eq 0 ] && [ "$FAIL" -eq 0 ] || exit 1
