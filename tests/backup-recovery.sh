#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

git_identity() {
  git -C "$1" config user.name "Ezomar recovery test"
  git -C "$1" config user.email "recovery-test@example.invalid"
}

# AI restore: the source archive intentionally contains managed files, as old
# ezarch archives can. The destination's real chezmoi source owns only leaves.
old_home="$TMP/ai-old"
new_home="$TMP/ai-new"
backup_dir="$TMP/ai-backups"
mkdir -p "$old_home/.claude/projects/demo" \
  "$old_home/.claude-profiles/exato" "$old_home/.ssh" \
  "$old_home/.config/herdr" "$old_home/.local/state/herdr"
printf 'archived conversation\n' >"$old_home/.claude/projects/demo/session.jsonl"
printf 'archived settings\n' >"$old_home/.claude/settings.json"
printf 'archived credential\n' >"$old_home/.claude-profiles/exato/.credentials.json"
printf 'archived profile settings\n' >"$old_home/.claude-profiles/exato/settings.json"
printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'test-only' \
  '-----END OPENSSH PRIVATE KEY-----' >"$old_home/.ssh/id_test"
printf 'archived ssh config\n' >"$old_home/.ssh/config"
printf 'archived config state\n' >"$old_home/.config/herdr/x"
printf 'archived local state\n' >"$old_home/.local/state/herdr/x"

HOME="$old_home" EZOMAR_BACKUP_ONLY='.claude .claude-profiles .ssh .config/herdr .local/state/herdr' \
  bash "$ROOT/backup/backup-ai.sh" "$backup_dir" >/dev/null
ai_backup="$(find "$backup_dir" -maxdepth 1 -name 'ezomar-ai-*.tar.zst' -print -quit)"

chezmoi_source="$new_home/.local/share/chezmoi"
mkdir -p "$chezmoi_source/dot_claude" \
  "$chezmoi_source/dot_claude-profiles/exato" "$chezmoi_source/dot_ssh"
printf 'destination managed settings\n' >"$chezmoi_source/dot_claude/settings.json"
printf 'destination managed profile settings\n' \
  >"$chezmoi_source/dot_claude-profiles/exato/settings.json"
printf 'destination managed ssh config\n' >"$chezmoi_source/dot_ssh/config"
HOME="$new_home" chezmoi apply
mkdir -p "$new_home/.config/herdr" "$new_home/.local/state/herdr"
printf 'destination config state\n' >"$new_home/.config/herdr/x"
printf 'destination local state\n' >"$new_home/.local/state/herdr/x"

printf '%s\n' 'AI managed roots (unfiltered):'
HOME="$new_home" chezmoi managed --path-style absolute \
  | grep -xE "$new_home/(\.claude|\.claude-profiles|\.ssh)"
printf '%s\n' 'AI managed leaves:'
HOME="$new_home" chezmoi managed --include=files,symlinks --path-style absolute \
  | grep -xE "$new_home/(\.claude/settings\.json|\.claude-profiles/exato/settings\.json|\.ssh/config)"

HOME="$new_home" bash "$ROOT/backup/restore-ai.sh" "$ai_backup" --force

grep -Fxq 'archived conversation' "$new_home/.claude/projects/demo/session.jsonl"
grep -Fxq 'archived credential' "$new_home/.claude-profiles/exato/.credentials.json"
grep -Fxq -- '-----BEGIN OPENSSH PRIVATE KEY-----' "$new_home/.ssh/id_test"
grep -Fxq 'destination managed settings' "$new_home/.claude/settings.json"
grep -Fxq 'destination managed profile settings' \
  "$new_home/.claude-profiles/exato/settings.json"
grep -Fxq 'destination managed ssh config' "$new_home/.ssh/config"
grep -Fxq 'archived config state' "$new_home/.config/herdr/x"
grep -Fxq 'archived local state' "$new_home/.local/state/herdr/x"
pre_restore="$(find "$new_home/.ezomar-pre-restore" -mindepth 1 -maxdepth 1 -type d -print -quit)"
grep -Fxq 'destination config state' "$pre_restore/.config/herdr/x"
grep -Fxq 'destination local state' "$pre_restore/.local/state/herdr/x"
printf '%s\n' \
  "RESTORED conversation: $(<"$new_home/.claude/projects/demo/session.jsonl")" \
  "RESTORED credential: $(<"$new_home/.claude-profiles/exato/.credentials.json")" \
  "PRESERVED Claude settings: $(<"$new_home/.claude/settings.json")" \
  "PRESERVED SSH config: $(<"$new_home/.ssh/config")" \
  "DISTINCT force backups: $(<"$pre_restore/.config/herdr/x") / $(<"$pre_restore/.local/state/herdr/x")"

# WIP restore: unpushed branch, detached HEAD, unborn staged+unstaged content,
# a deep bare tag-only repo, and an untracked directory/type collision.
wip_old="$TMP/wip-old"
wip_new="$TMP/wip-new"
remotes="$TMP/remotes"
wip_backups="$TMP/wip-backups"
mkdir -p "$wip_old/work/repos/deep/nested" "$remotes"

git init --bare --quiet "$remotes/branch.git"
git clone --quiet "$remotes/branch.git" "$wip_old/work/repos/branch"
git_identity "$wip_old/work/repos/branch"
printf 'base\n' >"$wip_old/work/repos/branch/file"
git -C "$wip_old/work/repos/branch" add file
git -C "$wip_old/work/repos/branch" commit --quiet -m base
git -C "$wip_old/work/repos/branch" push --quiet -u origin HEAD:main
git --git-dir="$remotes/branch.git" symbolic-ref HEAD refs/heads/main
git -C "$wip_old/work/repos/branch" switch --quiet -c feature
printf 'feature commit\n' >"$wip_old/work/repos/branch/file"
git -C "$wip_old/work/repos/branch" commit --quiet -am feature
printf 'feature worktree\n' >>"$wip_old/work/repos/branch/file"

git init --bare --quiet "$remotes/detached.git"
git clone --quiet "$remotes/detached.git" "$wip_old/work/repos/detached"
git_identity "$wip_old/work/repos/detached"
printf 'base\n' >"$wip_old/work/repos/detached/file"
git -C "$wip_old/work/repos/detached" add file
git -C "$wip_old/work/repos/detached" commit --quiet -m base
git -C "$wip_old/work/repos/detached" push --quiet -u origin HEAD:main
git --git-dir="$remotes/detached.git" symbolic-ref HEAD refs/heads/main
git -C "$wip_old/work/repos/detached" checkout --quiet --detach
printf 'detached commit\n' >"$wip_old/work/repos/detached/file"
git -C "$wip_old/work/repos/detached" commit --quiet -am detached
detached_head="$(git -C "$wip_old/work/repos/detached" rev-parse HEAD)"

git init --quiet --initial-branch=planned "$wip_old/work/repos/unborn"
git_identity "$wip_old/work/repos/unborn"
printf 'staged\n' >"$wip_old/work/repos/unborn/file"
git -C "$wip_old/work/repos/unborn" add file
printf 'unstaged\n' >>"$wip_old/work/repos/unborn/file"

git init --bare --quiet "$remotes/conflict.git"
git clone --quiet "$remotes/conflict.git" "$wip_old/work/repos/conflict"
git_identity "$wip_old/work/repos/conflict"
printf 'base\n' >"$wip_old/work/repos/conflict/base"
git -C "$wip_old/work/repos/conflict" add base
git -C "$wip_old/work/repos/conflict" commit --quiet -m base
git -C "$wip_old/work/repos/conflict" branch -M main
git -C "$wip_old/work/repos/conflict" push --quiet -u origin HEAD:main
git --git-dir="$remotes/conflict.git" symbolic-ref HEAD refs/heads/main
mkdir -p "$wip_old/work/repos/conflict/cache"
printf 'untracked\n' >"$wip_old/work/repos/conflict/cache/item"

git init --bare --quiet "$remotes/conflict-file.git"
git clone --quiet "$remotes/conflict-file.git" "$wip_old/work/repos/conflict-file"
git_identity "$wip_old/work/repos/conflict-file"
printf 'base\n' >"$wip_old/work/repos/conflict-file/base"
git -C "$wip_old/work/repos/conflict-file" add base
git -C "$wip_old/work/repos/conflict-file" commit --quiet -m base
git -C "$wip_old/work/repos/conflict-file" branch -M main
git -C "$wip_old/work/repos/conflict-file" push --quiet -u origin HEAD:main
git --git-dir="$remotes/conflict-file.git" symbolic-ref HEAD refs/heads/main
mkdir -p "$wip_old/work/repos/conflict-file/cache"
printf 'untracked\n' >"$wip_old/work/repos/conflict-file/cache/item"

tag_seed="$TMP/tag-seed"
git init --quiet "$tag_seed"
git_identity "$tag_seed"
printf 'tag only\n' >"$tag_seed/file"
git -C "$tag_seed" add file
git -C "$tag_seed" commit --quiet -m tagged
git -C "$tag_seed" tag only-tag
git init --bare --quiet "$wip_old/work/repos/deep/nested/archive.git"
git -C "$tag_seed" push --quiet \
  "$wip_old/work/repos/deep/nested/archive.git" refs/tags/only-tag

HOME="$wip_old" EZOMAR_REPO_ROOTS="$wip_old/work/repos" \
  bash "$ROOT/backup/backup-wip.sh" "$wip_backups"
wip_backup="$(find "$wip_backups" -maxdepth 1 -name 'ezomar-wip-*.tar.zst' -print -quit)"

# The destination clone gained a tracked symlink after the snapshot. Restoring
# cache/item must report the type conflict and leave the symlink untouched.
git -C "$wip_old/work/repos/conflict" clean -fdq
ln -s base "$wip_old/work/repos/conflict/cache"
git -C "$wip_old/work/repos/conflict" add cache
git -C "$wip_old/work/repos/conflict" commit --quiet -m 'tracked cache symlink'
git -C "$wip_old/work/repos/conflict" push --quiet origin HEAD:main
git -C "$wip_old/work/repos/conflict-file" clean -fdq
printf 'tracked regular cache\n' >"$wip_old/work/repos/conflict-file/cache"
git -C "$wip_old/work/repos/conflict-file" add cache
git -C "$wip_old/work/repos/conflict-file" commit --quiet -m 'tracked cache file'
git -C "$wip_old/work/repos/conflict-file" push --quiet origin HEAD:main

mkdir -p "$wip_new"
set +e
restore_output="$(HOME="$wip_new" bash "$ROOT/backup/restore-wip.sh" "$wip_backup" 2>&1)"
restore_status=$?
set -e
printf '%s\n' "$restore_output"
[ "$restore_status" -eq 1 ]

[ "$(git -C "$wip_new/work/repos/branch" branch --show-current)" = feature ]
grep -Fxq 'feature worktree' "$wip_new/work/repos/branch/file"
[ "$(git -C "$wip_new/work/repos/detached" rev-parse HEAD)" = "$detached_head" ]
grep -Fxq 'detached commit' "$wip_new/work/repos/detached/file"
[ "$(git -C "$wip_new/work/repos/unborn" branch --show-current)" = planned ]
printf 'staged\nunstaged\n' | cmp - "$wip_new/work/repos/unborn/file"
git --git-dir="$wip_new/work/repos/deep/nested/archive.git" \
  rev-parse --verify refs/tags/only-tag >/dev/null
[ -L "$wip_new/work/repos/conflict/cache" ]
[ "$(readlink "$wip_new/work/repos/conflict/cache")" = base ]
[ -f "$wip_new/work/repos/conflict-file/cache" ]
grep -Fxq 'tracked regular cache' "$wip_new/work/repos/conflict-file/cache"
grep -Fq 'conflito(s) de tipo/conteúdo em não rastreados' <<<"$restore_output"

printf '%s\n' \
  'WIP RESTORED unpushed branch + worktree patch' \
  'WIP RESTORED detached HEAD' \
  'WIP RESTORED unborn staged + later unstaged edits' \
  'WIP RESTORED deep bare tag-only commit' \
  'WIP PRESERVED tracked cache symlink on untracked-directory conflict' \
  'WIP REPORTED tracked regular-file conflict without aborting the repo loop' \
  'backup recovery: ok'
