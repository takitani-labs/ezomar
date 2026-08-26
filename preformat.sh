#!/usr/bin/env bash
# Run on the OLD machine, before formatting it.
#
# install.sh answers "is the new machine built?". This answers the question that
# comes before it: "will Omarchy + ezomar + the dotfiles repo rebuild everything
# this machine has?" It derives the answer from the live machine (profiles,
# skills, user units, configs that carry keys) and asks chezmoi whether each
# piece is captured, then checks that the repos involved are committed and
# pushed, because a perfect source tree that only exists on the disk about to
# be wiped is worth nothing.
#
#   bash preformat.sh          read-only report
#   bash preformat.sh --fix    run the chezmoi add/re-add it can, commit and
#                              push the dotfiles source, then re-check
#
# --fix never touches ~/.claude/settings.json (Claude Code rewrites it with
# plugin state; see README) and never adds the oom-guard drop-ins (module 80
# writes its own on the new machine).
set -uo pipefail

MODE=check
[ "${1:-}" = "--fix" ] && MODE=fix

EZOMAR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install/lib/config.sh
. "$EZOMAR_DIR/install/lib/config.sh"

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "[preformat] chezmoi não encontrado; sem ele não há o que conferir." >&2
  exit 1
fi
SRC="$(chezmoi source-path)"
# A set, not a grep pipeline: under pipefail `grep -q` closing the pipe early
# turns a successful match into a failed pipeline.
declare -A MANAGED_SET=()
while IFS= read -r m; do MANAGED_SET["$m"]=1; done < <(chezmoi managed --path-style absolute 2>/dev/null)
managed() { [[ -n "${MANAGED_SET[$1]:-}" ]]; }

PEND=()       # blocking findings
ADDS=()       # paths for `chezmoi add`
ENC_ADDS=()   # paths for `chezmoi add --encrypt`
READDS=()     # paths for `chezmoi re-add`

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; PEND+=("$1"); }
info() { printf '  \033[34m·\033[0m %s\n' "$1"; }
section() { echo; echo "[preformat] $1"; }

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

# --- 6. repos committed and pushed -----------------------------------------------
section "Repos commitados e no remoto"
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

# --- 7. state nothing versions (copy by hand if it matters) --------------------
section "Estado que ninguém versiona (copie à mão se importar)"
for s in "$HOME/.claude.json|servers MCP e estado do Claude Code (reaplicar com claude mcp add)" \
         "$HOME/.local/state/meeting-rig|transcrições e recaps do mrig" \
         "$HOME/.config/meeting-rig/context.md|contexto pessoal do mrig" \
         "$HOME/.local/share/herdr|sessões do herdr" \
         "$HOME/.grok|login do Grok (refazer com grok login)"; do
  path="${s%%|*}"; what="${s#*|}"
  [ -e "$path" ] && info "${path#"$HOME"/}: $what"
done

# --- fix ---------------------------------------------------------------------------
if [ "$MODE" = "fix" ]; then
  echo
  echo "[preformat] Aplicando correções no source do chezmoi..."
  [ ${#ADDS[@]} -gt 0 ]     && { echo "  chezmoi add (${#ADDS[@]})";       chezmoi add "${ADDS[@]}"; }
  [ ${#ENC_ADDS[@]} -gt 0 ] && { echo "  chezmoi add --encrypt (${#ENC_ADDS[@]})"; chezmoi add --encrypt "${ENC_ADDS[@]}"; }
  [ ${#READDS[@]} -gt 0 ]   && { echo "  chezmoi re-add (${#READDS[@]})";  chezmoi re-add "${READDS[@]}"; }
  if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
    echo "  commit e push do source"
    git -C "$SRC" add -A
    git -C "$SRC" commit -q -m "Capture the live machine before the format ($(date +%F))"
    git -C "$SRC" push -q
  fi
  echo "[preformat] Conferindo de novo..."
  exec bash "$0"
fi

# --- verdict -------------------------------------------------------------------------
echo
if [ ${#PEND[@]} -eq 0 ]; then
  echo "[preformat] OK, pode formatar, bruxão."
  exit 0
fi
echo "[preformat] ${#PEND[@]} pendência(s):"
for p in "${PEND[@]}"; do echo "  - $p"; done
FIXABLE=$(( ${#ADDS[@]} + ${#ENC_ADDS[@]} + ${#READDS[@]} ))
[ "$FIXABLE" -gt 0 ] && echo "[preformat] As de chezmoi ($FIXABLE caminhos) o --fix resolve: bash preformat.sh --fix"
exit 1
