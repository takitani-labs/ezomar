#!/usr/bin/env bash
# Run on the OLD machine, before formatting it.
#
# install.sh answers "is the new machine built?". This answers the question that
# comes before it: "will Omarchy + ezomar + the dotfiles repo rebuild everything
# this machine has?"
#
# It answers in two halves, and only the first one votes.
#
# The blocking half asks whether every piece the new machine needs already lives
# somewhere the format cannot reach. It derives the list from the live machine
# (profiles, skills, user units, configs that carry keys) and asks chezmoi
# whether each piece is captured; then it checks that the repos involved are
# committed and pushed, because a perfect source tree that only exists on the
# disk about to be wiped is worth nothing; then it sweeps every other git repo
# under the code roots, for the same reason and because there are hundreds of
# them; then it checks that the AI-state tarball is newer than the state it is
# supposed to carry.
#
# The informational half only measures: what in $HOME nobody versions at all,
# what Docker is holding, what was typed straight onto this machine, and how big
# each of those is. Nothing there can turn the verdict red. A 24G Downloads
# folder is a decision, not a defect.
#
#   bash preformat.sh          read-only report
#   bash preformat.sh --fix    run the chezmoi add/re-add it can, commit and
#                              push the dotfiles source, then re-check
#
# --fix only ever touches the chezmoi source. It does not commit, push, stash or
# clean anything the repo sweep finds, and it does not run the backup: what to do
# with uncommitted work is not a decision a script gets to make. It also never
# touches ~/.claude/settings.json (Claude Code rewrites it with plugin state; see
# README) and never adds the oom-guard drop-ins (module 80 writes its own).
#
# Runtime is dominated by the last section, which walks $HOME to size it: about
# 20s on the machine this was written for, 17 of them measuring 1.4T of ~/work.
# Everything that blocks is decided in the first two seconds.
#
# Knobs:
#   EZOMAR_REPO_ROOTS   ':'-separated roots to sweep for git repos
#                       (default ~/work/repos:~/Devel)
#   EZOMAR_BACKUP_DIR   where backup/backup-ai.sh drops its tarballs
#                       (default ~/backups)
set -uo pipefail

MODE=check
[ "${1:-}" = "--fix" ] && MODE=fix

EZOMAR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install/lib/config.sh
. "$EZOMAR_DIR/install/lib/config.sh"

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "[ezomar][preformat] chezmoi não encontrado; sem ele não há o que conferir." >&2
  exit 1
fi
SRC="$(chezmoi source-path)"
# A set, not a grep pipeline: under pipefail `grep -q` closing the pipe early
# turns a successful match into a failed pipeline.
declare -A MANAGED_SET=()
while IFS= read -r m; do MANAGED_SET["$m"]=1; done < <(chezmoi managed --path-style absolute 2>/dev/null)
managed() { [[ -n "${MANAGED_SET[$1]:-}" ]]; }

# Nothing personal is hardcoded in this repo, and these paths are personal: they
# are where this owner keeps code, and the default only matches because the same
# convention already drives EZOMAR_TOOLS_DIR.
IFS=: read -r -a REPO_ROOTS <<< "${EZOMAR_REPO_ROOTS:-$HOME/work/repos:$HOME/Devel}"
SCAN_ROOTS=()
for r in "${REPO_ROOTS[@]}"; do [ -d "$r" ] && SCAN_ROOTS+=("$r"); done
JOBS="$(nproc 2>/dev/null || echo 4)"

PEND=()       # blocking findings
ADDS=()       # paths for `chezmoi add`
ENC_ADDS=()   # paths for `chezmoi add --encrypt`
READDS=()     # paths for `chezmoi re-add`
MANUAL=0      # blocking findings --fix cannot touch

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; PEND+=("$1"); }
info() { printf '  \033[34m·\033[0m %s\n' "$1"; }
item() { printf '      %s\n' "$1"; }
section() { echo; echo "[ezomar][preformat] $1"; }

# --- 1. drift between the machine and the dotfiles source ---------------------
section "Drift entre a máquina e o source do chezmoi"
DRIFT=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  code="${line:0:2}"; rel="${line:3}"
  case "$code" in
    *M*)
      if [ "$rel" = ".claude/settings.json" ]; then
        info "$rel modificado; ignorado de propósito (o Claude Code reescreve esse arquivo)"
      else
        DRIFT+=("$HOME/$rel")
      fi ;;
  esac
done < <(chezmoi status 2>/dev/null)
if [ ${#DRIFT[@]} -eq 0 ]; then
  ok "nenhum arquivo gerenciado alterado fora do source"
else
  bad "${#DRIFT[@]} arquivo(s) gerenciado(s) alterado(s) na máquina e não no source (chezmoi re-add)"
  for f in "${DRIFT[@]}"; do info "${f#"$HOME"/}"; done
  READDS+=("${DRIFT[@]}")
fi

# --- 2. Claude skills ----------------------------------------------------------
section "Skills do Claude (~/.claude/skills)"
N=0; MISSING=()
for d in "$HOME"/.claude/skills/*/; do
  [ -d "$d" ] || continue
  N=$((N + 1))
  managed "${d%/}" || MISSING+=("${d%/}")
done
if [ ${#MISSING[@]} -eq 0 ]; then
  ok "$N skills, todas no source"
else
  bad "${#MISSING[@]} skill(s) fora do source: $(printf '%s ' "${MISSING[@]##*/}")"
  ADDS+=("${MISSING[@]}")
fi

# --- 3. Claude profiles --------------------------------------------------------
section "Perfis do Claude (~/.claude-profiles)"
for p in "$HOME"/.claude-profiles/*/; do
  [ -d "$p" ] || continue
  name="$(basename "$p")"; gaps=()
  for f in settings.json CLAUDE.md settings.local.json; do
    [ -e "$p$f" ] && ! managed "$p$f" && gaps+=("$f")
  done
  for l in commands skills projects; do
    [ -L "$p$l" ] && ! managed "$p$l" && gaps+=("$l@")
  done
  [ -e "${p}settings.json" ] || gaps+=("sem settings.json")
  if [ ${#gaps[@]} -eq 0 ]; then
    ok "$name"
  else
    bad "$name: falta no source: ${gaps[*]}"
    for g in "${gaps[@]}"; do
      case "$g" in
        "sem settings.json") ;;
        *@) ADDS+=("$p${g%@}") ;;
        *)  ADDS+=("$p$g") ;;
      esac
    done
  fi
done

# --- 4. systemd user units -------------------------------------------------------
section "Units systemd de usuário (~/.config/systemd/user)"
UNITS="$HOME/.config/systemd/user"
shopt -s nullglob
for u in "$UNITS"/*.service "$UNITS"/*.timer "$UNITS"/*.d/*.conf; do
  rel="${u#"$UNITS"/}"
  case "$rel" in
    cli-proxy-api*.service)          info "$rel: o módulo 60/62 recria" ;;
    claude-auth-preflight.service)   info "$rel: o módulo 76 recria" ;;
    kde-*|app-org.kde.*)             info "$rel: KDE, morre com o format" ;;
    */ez*-oom-guard.conf)            info "$rel: o módulo 80 escreve o dele" ;;
    *)
      if managed "$u"; then ok "$rel"; else bad "$rel fora do source"; ADDS+=("$u"); fi ;;
  esac
done
shopt -u nullglob

# --- 5. configs that carry keys, and the ezomar seed values ---------------------
section "Configs com chave e valores do ezomar"
CFG="$HOME/.config/ai-usagebar/config.toml"
if [ -f "$CFG" ]; then
  managed "$CFG" && ok "ai-usagebar/config.toml no source" \
    || { bad "ai-usagebar/config.toml fora do source (chezmoi add --encrypt)"; ENC_ADDS+=("$CFG"); }
else
  info "sem ~/.config/ai-usagebar/config.toml nesta máquina"
fi
if [ -f "$EZOMAR_CONFIG_FILE" ]; then
  managed "$EZOMAR_CONFIG_FILE" && ok "config do ezomar no source" || { bad "config do ezomar fora do source"; ADDS+=("$EZOMAR_CONFIG_FILE"); }
  for v in EZOMAR_DOTFILES_REPO EZOMAR_AGE_ITEM; do
    grep -q "^$v=" "$EZOMAR_CONFIG_FILE" && ok "$v definido" || bad "$v ausente em $EZOMAR_CONFIG_FILE"
  done
  grep -q '^EZOMAR_TOOLS_REPO=' "$EZOMAR_CONFIG_FILE" && ok "EZOMAR_TOOLS_REPO definido" \
    || bad "EZOMAR_TOOLS_REPO ausente: sem ele mrig e o preflight não voltam (uma linha em $EZOMAR_CONFIG_FILE)"
else
  bad "$EZOMAR_CONFIG_FILE não existe"
fi
[ -s "$HOME/.config/age/keys.txt" ] && ok "identidade age presente (confira que o item '${EZOMAR_AGE_ITEM:-?}' no cofre tem a mesma chave)" \
  || bad "\$HOME/.config/age/keys.txt ausente"
if ls "$HOME"/.ssh/id_* >/dev/null 2>&1; then
  info "primeira chave SSH tem que ir à mão (scp) para a máquina nova; o resto vem dos dotfiles"
fi

# --- 6. the repos ezomar itself needs ---------------------------------------------
section "Repos do ezomar commitados e no remoto"
repo_state() {  # $1=label $2=dir
  local label="$1" dir="$2" dirty ahead
  [ -d "$dir/.git" ] || { bad "$label: $dir não é um repo git"; return; }
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l)"
  ahead="$(git -C "$dir" log --oneline '@{u}..HEAD' 2>/dev/null | wc -l)"
  if ! git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    bad "$label: branch sem upstream"
  elif [ "$dirty" -gt 0 ]; then
    bad "$label: $dirty alteração(ões) não commitada(s)"
  elif [ "$ahead" -gt 0 ]; then
    bad "$label: $ahead commit(s) não enviado(s)"
  else
    ok "$label limpo e no remoto"
  fi
}
repo_state "dotfiles ($SRC)" "$SRC"
repo_state "ezomar" "$EZOMAR_DIR"
if TOOLS_DIR="$(ezomar_tools_dir 2>/dev/null)"; then
  repo_state "ferramentas ($TOOLS_DIR)" "$TOOLS_DIR"
fi

# --- 7. every other git repo under the code roots ---------------------------------
# Section 6 covers the three repos ezomar needs to rebuild itself. The format
# takes the other two hundred too, and checking three of them was the largest
# hole in this script: a repo with a day of uncommitted work looked exactly like
# a repo that was never there.
scan_repo() {
  # One repo per call, run under xargs -P. `git status` on the 681 trees of the
  # machine this was written for takes 13s in sequence and under 2s across the
  # cores, which is the difference between a check you run and one you skip.
  local dir="${1%/.git}" kind=repo flags=""
  case "$dir" in *--worktrees/*) kind=wt ;; esac
  [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -1)" ] && flags+=" nao-commitado"
  # A linked worktree shares the parent's object store and refs, so a commit made
  # inside one is already counted as unpushed under the parent. Only its dirty
  # files are invisible from there, so that is all we ask a worktree.
  if [ "$kind" = repo ]; then
    [ -n "$(git -C "$dir" remote 2>/dev/null | head -1)" ] || flags+=" sem-remote"
    # "is this commit on any remote?" is the real question. `@{u}..HEAD` answers
    # a narrower one and says nothing about the branches you are not standing on.
    [ -n "$(git -C "$dir" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ] && flags+=" nao-pushado"
  fi
  [ -n "$flags" ] && printf '%s\t%s\t%s\n' "$kind" "${flags# }" "$dir"
  return 0
}
export -f scan_repo

ROOTS_LABEL=""
for r in "${REPO_ROOTS[@]}"; do
  case "$r" in
    "$HOME"/*) ROOTS_LABEL+="${ROOTS_LABEL:+, }~/${r#"$HOME"/}" ;;
    *)         ROOTS_LABEL+="${ROOTS_LABEL:+, }$r" ;;
  esac
done
section "Todos os repos sob $ROOTS_LABEL"
if [ ${#SCAN_ROOTS[@]} -eq 0 ]; then
  info "nenhuma dessas raízes existe aqui (EZOMAR_REPO_ROOTS ajusta)"
else
  # -prune stops the descent at each .git, which is both faster and correct:
  # without it a stray directory inside .git is reported as a repo of its own.
  # maxdepth 4 reaches org/repo/.git and org/repo--worktrees/nome/.git.
  GITDIRS=()
  mapfile -d '' GITDIRS < <(find "${SCAN_ROOTS[@]}" -maxdepth 4 -name .git \( -type d -o -type f \) -prune -print0 2>/dev/null)

  SWEEP_T0=$SECONDS
  SW_DIRTY=(); SW_NOREMOTE=(); SW_UNPUSHED=(); SW_DETAIL=()
  declare -A WT_DIRTY=()
  if [ ${#GITDIRS[@]} -gt 0 ]; then
    while IFS=$'\t' read -r kind flags dir; do
      if [ "$kind" = wt ]; then
        parent="${dir%%--worktrees/*}"
        WT_DIRTY["$parent"]=$(( ${WT_DIRTY["$parent"]:-0} + 1 ))
        continue
      fi
      SW_DETAIL+=("$flags|$dir")
      case "$flags" in *nao-commitado*) SW_DIRTY+=("$dir") ;; esac
      case "$flags" in *sem-remote*)    SW_NOREMOTE+=("$dir") ;; esac
      case "$flags" in *nao-pushado*)   SW_UNPUSHED+=("$dir") ;; esac
    done < <(printf '%s\0' "${GITDIRS[@]}" \
             | xargs -0 -r -P "$JOBS" -I{} bash -c 'scan_repo "$1"' _ {} \
             | sort -t"$(printf '\t')" -k3)
  fi
  SWEEP_SECS=$(( SECONDS - SWEEP_T0 ))

  if [ ${#SW_DETAIL[@]} -eq 0 ] && [ ${#WT_DIRTY[@]} -eq 0 ]; then
    ok "${#GITDIRS[@]} repo(s) varrido(s) em ${SWEEP_SECS}s, todos commitados e no remoto"
  else
    [ ${#SW_DIRTY[@]} -gt 0 ]    && bad "${#SW_DIRTY[@]} repo(s) com alteração não commitada"
    [ ${#SW_NOREMOTE[@]} -gt 0 ] && bad "${#SW_NOREMOTE[@]} repo(s) sem remote nenhum (nada sai deles)"
    [ ${#SW_UNPUSHED[@]} -gt 0 ] && bad "${#SW_UNPUSHED[@]} repo(s) com commit que não está em remote nenhum"
    WT_TOTAL=0
    for c in "${WT_DIRTY[@]:-}"; do WT_TOTAL=$(( WT_TOTAL + ${c:-0} )); done
    [ "$WT_TOTAL" -gt 0 ] && bad "$WT_TOTAL worktree(s) com alteração não commitada, em ${#WT_DIRTY[@]} repo(s)"
    MANUAL=1
    info "${#GITDIRS[@]} varrido(s) em ${SWEEP_SECS}s; os limpos não aparecem"
    for d in "${SW_DETAIL[@]}"; do
      dir="${d#*|}"
      item "$(printf '%-36s %s' "${d%%|*}" "${dir#"$HOME"/}")"
    done
    if [ "$WT_TOTAL" -gt 0 ]; then
      mapfile -t WT_PARENTS < <(printf '%s\n' "${!WT_DIRTY[@]}" | sort)
      for p in "${WT_PARENTS[@]}"; do
        item "$(printf '%-36s %s' "${WT_DIRTY[$p]} nao-commitado" "${p#"$HOME"/}--worktrees/")"
      done
    fi
  fi
fi

# --- 7b. remotes that no longer answer ----------------------------------------------
#
# restore-repos.sh reclona do remote, e backup-wip.sh só empacota o que NÃO está
# no remote. Quando o remote morre, as duas premissas caem juntas: os refs
# origin/* continuam no disco, então o bundle sai vazio, e o clone não acha nada.
# O repositório inteiro vive apenas na cópia local que o format apaga. Medido na
# máquina de reserva: 6 repos nessa situação, um deles com 17 commits de trabalho.
if [ "${EZOMAR_SKIP_REMOTE_CHECK:-}" = true ]; then
  info "checagem de remotes pulada (EZOMAR_SKIP_REMOTE_CHECK)"
elif [ ${#GITDIRS[@]} -eq 0 ]; then
  :
else
  section "remotes que ainda respondem"
  REMOTE_T0=$SECONDS
  declare -A URL_REPOS=()
  for dir in "${GITDIRS[@]}"; do
    url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    [ -n "$url" ] || continue
    URL_REPOS["$url"]="${URL_REPOS["$url"]:-}${URL_REPOS["$url"]:+ }${dir#"$HOME"/}"
  done

  DEAD=()
  if [ ${#URL_REPOS[@]} -gt 0 ]; then
    # Um teste por URL distinta, não por repositório: dezenas de worktrees e
    # clones compartilham o mesmo remote, e a rede é o gargalo.
    mapfile -t DEAD < <(printf '%s\n' "${!URL_REPOS[@]}" \
      | xargs -r -P "$JOBS" -I{} bash -c '
          GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=8" \
            timeout 20 git ls-remote --exit-code "$1" HEAD >/dev/null 2>&1 || printf "%s\n" "$1"
        ' _ {} | sort)
  fi
  REMOTE_SECS=$(( SECONDS - REMOTE_T0 ))

  if [ ${#DEAD[@]} -eq 0 ]; then
    ok "${#URL_REPOS[@]} remote(s) distintos respondem (${REMOTE_SECS}s)"
  else
    bad "${#DEAD[@]} remote(s) não respondem; esses repos NÃO voltam por clone"
    MANUAL=1
    for url in "${DEAD[@]}"; do
      for rel in ${URL_REPOS["$url"]}; do
        # Quanto existe só aqui decide a gravidade: 0 quer dizer que o bundle do
        # backup-wip sai vazio e a história inteira depende desta máquina.
        solo="$(git -C "$HOME/$rel" rev-list --branches --tags --not --remotes --count 2>/dev/null || echo '?')"
        total="$(git -C "$HOME/$rel" rev-list --all --count 2>/dev/null || echo '?')"
        item "$(printf '%-46s %s commits, %s fora do remote' "$rel" "$total" "$solo")"
      done
      item "$(printf '%-46s %s' '' "$url")"
    done
    info "empurre para outro remote antes de formatar, ou aceite perder a história"
  fi
fi

# --- 8. the AI-state tarball -------------------------------------------------------
# chezmoi carries the dotfiles, the profiles and the skills. It deliberately does
# not carry the state that churns: the Claude Code conversations, the 227 MCP
# entries in ~/.claude.json, the CLI tokens, the keys. backup/backup-ai.sh is
# what carries those, and it is only worth what its timestamp says: a tarball
# taken before the last day of work leaves that day on the disk being wiped.
#
# Referenced by path on purpose. What goes inside the tarball is that script's
# business; this only asks whether one exists and whether it is still current.
section "Backup do estado de IA"
BACKUP_DIR="${EZOMAR_BACKUP_DIR:-$HOME/backups}"
BACKUP_SCRIPT="backup/backup-ai.sh"
# The short list of things that only the tarball carries. Used as the clock the
# backup is compared against, not as a description of what it contains.
AI_STATE=(
  "$HOME/.claude/projects"          # as conversas do Claude Code
  "$HOME/.claude.json"              # servidores MCP e tokens
  "$HOME/.codex" "$HOME/.kimi" "$HOME/.cli-proxy-api"
  "$HOME/.config/ai-usagebar"
  "$HOME/.config/herdr/session.json"
  "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.kube" "$HOME/.config/gh"
)
LAST_BACKUP=""
shopt -s nullglob
# Two patterns: the tarballs this repo writes now, and the ai-backup-* ones the
# ezarch version left on this machine. An older tarball taken by the older script
# is still a backup, and pretending it is not would say "you have nothing".
for f in "$BACKUP_DIR"/ezomar-ai-*.tar.zst "$BACKUP_DIR"/ai-backup-*.tar.zst; do
  [ -f "$f" ] || continue
  if [ -z "$LAST_BACKUP" ] || [ "$f" -nt "$LAST_BACKUP" ]; then LAST_BACKUP="$f"; fi
done
shopt -u nullglob
if [ -z "$LAST_BACKUP" ]; then
  bad "nenhum tarball de estado de IA em $BACKUP_DIR; rode $BACKUP_SCRIPT antes de desligar"
  MANUAL=1
else
  AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LAST_BACKUP") ) / 3600 ))
  if   [ "$AGE_H" -le 0 ];  then AGE="de agora há pouco"
  elif [ "$AGE_H" -ge 48 ]; then AGE="de $(( AGE_H / 24 )) dia(s) atrás"
  else                           AGE="de ${AGE_H}h atrás"; fi
  # -maxdepth 2 -quit: the answer is "did anything change", so the first hit ends
  # the walk. Without the bound, the green case would walk 15G of ~/.claude.
  CHANGED=()
  for p in "${AI_STATE[@]}"; do
    [ -e "$p" ] || continue
    [ -n "$(find "$p" -maxdepth 2 -newer "$LAST_BACKUP" -print -quit 2>/dev/null)" ] && CHANGED+=("$p")
  done
  if [ ${#CHANGED[@]} -eq 0 ]; then
    ok "$(basename "$LAST_BACKUP") $AGE, e nada que só ele carrega mudou desde então"
  else
    bad "$(basename "$LAST_BACKUP") $AGE é anterior a ${#CHANGED[@]} coisa(s) que ninguém mais versiona; refaça com $BACKUP_SCRIPT"
    MANUAL=1
    for c in "${CHANGED[@]}"; do item "mudou depois do backup: ${c#"$HOME"/}"; done
  fi
  info "o tarball está no disco que vai ser apagado; copie para fora (tailscale, NAS) e confira o .sha256"
fi

# --- 8b. herdr fleet ---------------------------------------------------------------
# session.json is both tiny and order-sensitive: starting herdr without it lets
# the server replace the fleet with an empty snapshot before restore can help.
section "Frota do herdr (~/.config/herdr/session.json)"
HERDR_SESSION="$HOME/.config/herdr/session.json"
if [ ! -f "$HERDR_SESSION" ]; then
  bad "session.json do herdr ausente"
  MANUAL=1
elif ! command -v jq >/dev/null 2>&1 || ! jq -e '.version and (.workspaces | type == "array")' "$HERDR_SESSION" >/dev/null 2>&1; then
  bad "session.json do herdr não pôde ser lido como índice válido"
  MANUAL=1
else
  read -r HERDR_WORKSPACES HERDR_TABS HERDR_PANES HERDR_AGENTS < <(
    jq -r '[
      (.workspaces | length),
      ([.workspaces[].tabs[]] | length),
      ([.workspaces[].tabs[].panes[]] | length),
      ([.workspaces[].tabs[].panes[] | select(.agent_session != null)] | length)
    ] | @tsv' "$HERDR_SESSION"
  )
  info "herdr: $HERDR_WORKSPACES workspace(s), $HERDR_TABS tab(s), $HERDR_PANES pane(s), $HERDR_AGENTS sessão(ões) de agente"

  HERDR_IN_BACKUP=""
  if [ -n "$LAST_BACKUP" ]; then
    HERDR_IN_BACKUP="$(zstd -dc "$LAST_BACKUP" 2>/dev/null \
      | tar -tf - --occurrence=1 .config/herdr/session.json 2>/dev/null || true)"
  fi
  if [ -n "$HERDR_IN_BACKUP" ]; then
    ok "session.json do herdr está no backup mais novo: $(basename "$LAST_BACKUP")"
  else
    bad "session.json do herdr não está no backup mais novo; refaça com $BACKUP_SCRIPT"
    MANUAL=1
  fi
fi

# --- fix ---------------------------------------------------------------------------
# Deliberately here, between the two halves: in fix mode nothing below this point
# is worth printing twice, since the re-check reprints all of it.
if [ "$MODE" = "fix" ]; then
  echo
  echo "[ezomar][preformat] Aplicando correções no source do chezmoi..."
  [ ${#ADDS[@]} -gt 0 ]     && { echo "  chezmoi add (${#ADDS[@]})";       chezmoi add "${ADDS[@]}"; }
  [ ${#ENC_ADDS[@]} -gt 0 ] && { echo "  chezmoi add --encrypt (${#ENC_ADDS[@]})"; chezmoi add --encrypt "${ENC_ADDS[@]}"; }
  [ ${#READDS[@]} -gt 0 ]   && { echo "  chezmoi re-add (${#READDS[@]})";  chezmoi re-add "${READDS[@]}"; }
  if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
    echo "  commit e push do source"
    git -C "$SRC" add -A
    git -C "$SRC" commit -q -m "Capture the live machine before the format ($(date +%F))"
    git -C "$SRC" push -q
  fi
  echo "[ezomar][preformat] Conferindo de novo..."
  exec bash "$0"
fi

echo
echo "[ezomar][preformat] ── daqui para baixo é só medição; nada disso reprova o format ──"

# --- 9. state nothing versions (copy by hand if it matters) --------------------
section "Estado que ninguém versiona (copie à mão se importar)"
for s in "$HOME/.claude.json|servers MCP e estado do Claude Code (reaplicar com claude mcp add)" \
         "$HOME/.local/state/meeting-rig|transcrições e recaps do mrig" \
         "$HOME/.config/meeting-rig/context.md|contexto pessoal do mrig" \
         "$HOME/.config/herdr/session.json|índice persistente da frota do herdr" \
         "$HOME/.grok|login do Grok (refazer com grok login)"; do
  path="${s%%|*}"; what="${s#*|}"
  [ -e "$path" ] && info "${path#"$HOME"/}: $what"
done

# --- 10. project directories with no git anywhere inside ---------------------------
# A directory under a code root with no repo inside it is carried by nothing: not
# chezmoi, not a remote, not the tarball. Reported outermost first, so a whole
# unversioned tree is one line instead of forty. Dot-directories are skipped: at
# this level they are tool state, not projects.
section "Diretórios de projeto sem git nenhum dentro"
has_git_below() { [ -n "$(find "$1" -name .git -prune -print -quit 2>/dev/null)" ]; }
report_nogit() {
  local sz
  sz="$(du -sh -x "$1" 2>/dev/null | cut -f1)"
  # An empty tree carries nothing, and "0" is exactly how du says so. This is
  # what drops the leftovers of a bind mount: directories, no bytes.
  [ -n "$sz" ] && [ "$sz" != 0 ] || return 0
  item "$(printf '%-7s %s' "$sz" "${1#"$HOME"/}")"
  NOGIT=$(( NOGIT + 1 ))
}
NOGIT=0
for root in "${SCAN_ROOTS[@]}"; do
  for d in "$root"/*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    [ -e "$d/.git" ] && continue
    if ! has_git_below "$d"; then report_nogit "$d"; continue; fi
    for e in "$d"/*/; do
      e="${e%/}"
      [ -d "$e" ] || continue
      [ -e "$e/.git" ] && continue
      has_git_below "$e" || report_nogit "$e"
    done
  done
done
[ "$NOGIT" -eq 0 ] && info "nenhum" || info "$NOGIT diretório(s): decida git, tarball ou lixo"

# --- 11. things typed straight onto this machine ------------------------------------
# The systemd user units are already checked against chezmoi in section 4, with a
# wider net than a listing gives (timers and .d drop-ins too), so they are not
# repeated here. What is left is what has no other home.
section "Feito à mão nesta máquina"
BIN_N=0; BIN_KNOWN=0; HANDMADE=()
shopt -s nullglob
for f in "$HOME"/.local/bin/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  # Bounded read: some of these are 100MB binaries, and only the shebang matters.
  # `tr -d '\0'` because a NUL in a command substitution makes bash warn per file.
  head="$(head -c 200 -- "$f" 2>/dev/null | tr -d '\0')"; head="${head%%$'\n'*}"
  case "$head" in '#!'*sh|'#!'*sh\ *|'#!'*bash*|'#!'*zsh*) ;; *) continue ;; esac
  BIN_N=$(( BIN_N + 1 ))
  case "${f##*/}" in
    bw|chezmoi|cli-proxy-api|ai-usagebar*|pidbox|mrig|pw-keepalive|claude-session-profile|herdr-switch-agent-profile)
      BIN_KNOWN=$(( BIN_KNOWN + 1 )) ;;                      # um módulo do ezomar reinstala
    distrobox-*|jetbrains-toolbox|activate-global-python-argcomplete)
      BIN_KNOWN=$(( BIN_KNOWN + 1 )) ;;                      # vem de pacote
    *)
      if managed "$f"; then BIN_KNOWN=$(( BIN_KNOWN + 1 )); else HANDMADE+=("${f##*/}"); fi ;;
  esac
done
shopt -u nullglob
info "scripts de shell em ~/.local/bin: $BIN_N, sendo $BIN_KNOWN de origem conhecida (chezmoi, pacote ou módulo do ezomar); binários são ignorados porque reinstalam"
[ ${#HANDMADE[@]} -gt 0 ] && info "sem origem, copie se importar: ${HANDMADE[*]}"

if crontab -l >/dev/null 2>&1; then
  mapfile -t CRON < <(crontab -l 2>/dev/null | grep -vE '^[[:space:]]*(#|$)')
  if [ ${#CRON[@]} -gt 0 ]; then
    info "crontab com ${#CRON[@]} linha(s); nada aqui recria isso do outro lado"
    for c in "${CRON[@]}"; do item "$c"; done
  fi
fi

PLASMOIDS_DIR="$HOME/.local/share/plasma/plasmoids"
if [ -d "$PLASMOIDS_DIR" ]; then
  mapfile -t PLASMOIDS < <(ls -1 "$PLASMOIDS_DIR" 2>/dev/null)
  [ ${#PLASMOIDS[@]} -gt 0 ] && info "plasmoides do KDE, sem equivalente no Hyprland (o caminho é plugin de waybar): ${PLASMOIDS[*]}"
fi

# --- 12. Docker ---------------------------------------------------------------------
# Volumes are the reason this section exists: a named volume is usually a
# database, and it is the one thing here that neither git nor the tarball holds.
section "Inodes do /tmp (o limite que trava a máquina antes de o disco encher)"
if IT="$(df -i /tmp 2>/dev/null | awk 'NR==2{print $2}')" && [ -n "$IT" ]; then
  IP="$(df -i /tmp 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  info "teto $IT, uso ${IP}%"
  # Quem consome, e não é o total: um scratchpad de sessão com um venv dentro
  # come centenas de milhares de inodes sozinho.
  for d in /tmp/*/; do
    n="$(find "$d" 2>/dev/null | wc -l)"
    [ "$n" -gt 20000 ] && info "$(printf '%8d' "$n")  ${d}"
  done
fi

section "Docker (dados de banco moram em volume)"
DOCKER=(docker)
command -v timeout >/dev/null 2>&1 && DOCKER=(timeout 5 docker)
if ! command -v docker >/dev/null 2>&1; then
  info "sem docker nesta máquina"
elif ! "${DOCKER[@]}" info >/dev/null 2>&1; then
  info "docker instalado mas sem responder; suba o daemon se houver volume para salvar"
else
  mapfile -t CONTAINERS < <("${DOCKER[@]}" ps --format '{{.Names}} ({{.Image}})' 2>/dev/null)
  mapfile -t VOLUMES < <("${DOCKER[@]}" volume ls --format '{{.Name}}' 2>/dev/null)
  NAMED=(); ANON=0
  for v in "${VOLUMES[@]}"; do
    if [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then ANON=$(( ANON + 1 )); else NAMED+=("$v"); fi
  done
  info "${#CONTAINERS[@]} container(s) de pé"
  for c in "${CONTAINERS[@]}"; do item "$c"; done
  info "${#NAMED[@]} volume(s) nomeado(s), $ANON anônimo(s) (esses são descartáveis)"
  for v in "${NAMED[@]}"; do item "$v"; done
fi

# --- 13. personal data and the biggest things in $HOME -------------------------------
# Sizes, to decide what to copy out. This is the slow section, and it is last on
# purpose: everything that blocks has already been printed by the time du starts.
section "Dados pessoais e os maiores diretórios do \$HOME"
info "medindo (é a parte lenta, e mede o disco inteiro; ~/.cache fica de fora)"
SIZES="$(mktemp)"
trap 'rm -f "$SIZES"' EXIT
ENTRIES=()
shopt -s nullglob
for e in "$HOME"/* "$HOME"/.[!.]*; do
  [ "${e##*/}" = ".cache" ] && continue
  ENTRIES+=("$e")
done
shopt -u nullglob
# One du per top-level entry, in parallel: 53s in sequence, 17s across the cores,
# and ~/work alone accounts for almost all of what is left.
[ ${#ENTRIES[@]} -gt 0 ] && printf '%s\0' "${ENTRIES[@]}" \
  | xargs -0 -r -P "$JOBS" -n1 du -sh -x 2>/dev/null > "$SIZES"

for d in Documents Pictures Videos Music Downloads Desktop Dropbox backups; do
  [ -d "$HOME/$d" ] || continue
  sz="$(awk -F'\t' -v p="$HOME/$d" '$2 == p { print $1 }' "$SIZES")"
  item "$(printf '%-7s ~/%s' "${sz:-?}" "$d")"
done
info "maiores do \$HOME:"
while IFS=$'\t' read -r sz path; do
  item "$(printf '%-7s ~/%s' "$sz" "${path#"$HOME"/}")"
done < <(sort -rh "$SIZES" | head -15)

# --- verdict -------------------------------------------------------------------------
echo
if [ ${#PEND[@]} -eq 0 ]; then
  echo "[ezomar][preformat] OK, pode formatar, bruxão."
  exit 0
fi
echo "[ezomar][preformat] ${#PEND[@]} pendência(s):"
for p in "${PEND[@]}"; do echo "  - $p"; done
FIXABLE=$(( ${#ADDS[@]} + ${#ENC_ADDS[@]} + ${#READDS[@]} ))
[ "$FIXABLE" -gt 0 ] && echo "[ezomar][preformat] As de chezmoi ($FIXABLE caminhos) o --fix resolve: bash preformat.sh --fix"
[ "$MANUAL" -eq 1 ] && echo "[ezomar][preformat] As de repo e de backup são suas: o --fix não commita, não faz push do seu trabalho nem roda o backup."
exit 1
