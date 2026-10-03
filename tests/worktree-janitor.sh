#!/usr/bin/env bash
set -euo pipefail

# Monta um repositório com uma worktree para cada caso e confere que o janitor só
# apaga a que deve, guardando antes os arquivos ignorados (o que a primeira versão
# perdia) e nunca o cache.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
JANITOR="$ROOT/install/templates/worktree-janitor/ezomar-worktree-janitor"
TMP="$(mktemp -d)"
SLEEPER=""
cleanup() { [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf -- "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$TMP/root" "$TMP/transcripts"
OLD="$(date -d '10 days ago' '+%Y-%m-%dT%H:%M:%S')"

fail() { echo "FALHOU: $*" >&2; exit 1; }
age() { # deixa a worktree inteira com cara de parada há 10 dias
  find "$1" -exec touch -h -d "$OLD" {} +
  find "$(git -C "$1" rev-parse --absolute-git-dir)" -maxdepth 2 -exec touch -h -d "$OLD" {} +
}
old_commit() { GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git -C "$1" commit -q -m "$2"; }

git init -q --bare -b master "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/root/proj" 2>/dev/null
P="$TMP/root/proj"
printf '.lane/\n.venv/\n' >"$P/.gitignore"
echo base >"$P/base.txt"
git -C "$P" add -A && old_commit "$P" base
git -C "$P" push -q origin master
git -C "$P" remote set-head origin master >/dev/null

wt() { git -C "$P" worktree add -q -b "$1" "$TMP/root/proj--worktrees/$1" master; echo "$TMP/root/proj--worktrees/$1"; }
land() { git -C "$P" merge -q --ff-only "$1" && git -C "$P" push -q origin master; }

# landed: mergeada, parada, com relatório ignorado, nota não rastreada e cache
A="$(wt landed)"; echo a >"$A/a.txt"; git -C "$A" add a.txt; old_commit "$A" a; land landed
mkdir -p "$A/.lane" "$A/.venv"; echo relatorio >"$A/.lane/REPORT.md"; echo nota >"$A/notes.md"; echo lixo >"$A/.venv/cache.bin"
# unmerged: commit que o master não tem
B="$(wt unmerged)"; echo b >"$B/b.txt"; git -C "$B" add b.txt; old_commit "$B" b
# dirty: mergeada, mas com alteração rastreada pendente
C="$(wt dirty)"; echo c >"$C/c.txt"; git -C "$C" add c.txt; old_commit "$C" c; land dirty; echo mexido >>"$C/c.txt"
# fresh: mergeada, mas com commit de agora
D="$(wt fresh)"; echo d >"$D/d.txt"; git -C "$D" add d.txt; git -C "$D" commit -q -m d; land fresh
# talked: mergeada e parada, mas um agente fez cd nela
E="$(wt talked)"; echo e >"$E/e.txt"; git -C "$E" add e.txt; old_commit "$E" e; land talked
printf '{"cmd":"cd %s && pytest"}\n' "$E" >"$TMP/transcripts/session.jsonl"
# blank: nunca commitou, mas tem arquivo novo
F="$(wt blank)"; echo novo >"$F/novo.txt"
# pinned: mergeada e parada, mas com processo dentro
G="$(wt pinned)"; echo g >"$G/g.txt"; git -C "$G" add g.txt; old_commit "$G" g; land pinned

for w in "$A" "$B" "$C" "$E" "$F" "$G"; do age "$w"; done
(cd "$G" && exec sleep 300) & SLEEPER=$!

export EZOMAR_JANITOR_ROOTS="$TMP/root" EZOMAR_JANITOR_GRAVE="$TMP/grave" EZOMAR_JANITOR_IDLE_HOURS=24 \
  EZOMAR_JANITOR_TRANSCRIPTS="$TMP/transcripts/*.jsonl" EZOMAR_JANITOR_NO_HERDR=1

python3 "$JANITOR" --dry-run >/dev/null
[ -d "$A" ] || fail "o dry-run apagou a worktree"
grep -q '"action": "would remove"' "$TMP"/grave/*/janitor-*-dryrun.jsonl || fail "o dry-run não previu a remoção"

python3 "$JANITOR" >"$TMP/run.log" || fail "saiu com erro: $(cat "$TMP/run.log")"

[ ! -e "$A" ] || fail "a worktree mergeada e parada continuou"
for w in "$B" "$C" "$D" "$E" "$F" "$G"; do [ -d "$w" ] || fail "apagou $(basename "$w"), que devia ficar"; done

tarball="$(ls "$TMP"/grave/*/proj__landed__*.tar.gz)"
listing="$(tar tzf "$tarball")"
grep -qx '.lane/REPORT.md' <<<"$listing" || fail "o arquivo ignorado .lane/REPORT.md ficou fora do backup"
grep -qx 'notes.md' <<<"$listing" || fail "o arquivo não rastreado ficou fora do backup"
! grep -q '.venv' <<<"$listing" || fail "o cache .venv entrou no backup"

git -C "$P" rev-parse --verify -q refs/heads/landed >/dev/null && fail "a branch antiga e mergeada não foi apagada"
grep -q "\"branch\": \"landed\"" "$TMP"/grave/*/janitor-*[0-9].jsonl || fail "o manifesto não registrou a branch"

manifest="$(ls "$TMP"/grave/*/janitor-*[0-9].jsonl)"
for pair in "unmerged:not merged" "dirty:tracked changes" "fresh:active in last" "talked:mentioned by an agent" \
            "blank:never committed" "pinned:process inside"; do
  name="${pair%%:*}" why="${pair#*:}"
  grep -F "\"branch\": \"$name\"" "$manifest" | grep -qF "$why" || fail "$name não foi pulada por '$why'"
done

echo "worktree-janitor: ok"
