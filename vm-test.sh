#!/usr/bin/env bash
# Rehearse ezomar against a throwaway Omarchy VM before formatting the real one.
#
# The ezdora version of this was three lines: rsync the tree, run install.sh.
# That worked because every ezdora module stood on its own. Here they do not:
# this pipeline is built around a vault and a private dotfiles repo, and a fresh
# VM has neither. 20-age-key wants an unlocked Bitwarden, 30-chezmoi wants an
# SSH key that only exists inside the repo it is trying to clone, 62 wants a
# Claude profile only chezmoi delivers, and 90-verify asserts the finished
# machine. Running install.sh in a bare VM therefore fails four modules by
# design, and a run that is red on purpose teaches nothing about the other
# nineteen.
#
# So this runs a subset. The default is everything that genuinely works on a
# bare Omarchy; the vault-dependent ones are opt-in, for after you have logged
# into the vault inside the VM.
#
# It calls the module files directly instead of going through install/apps.sh:
# apps.sh globs the whole directory and honours no filter, and teaching it one
# for the sake of the harness would be the test changing the thing it tests.
# What it does copy from apps.sh are its two invariants: filename order, and a
# failing module does not stop the run.
#
# The tree is rsync'd from the working copy, not cloned from GitHub, so what
# gets tested is what is on disk right now, uncommitted changes included. That
# is the whole point: iterate without pushing.
#
#   ./vm-test.sh                 os módulos que rodam sozinhos numa VM zerada
#   ./vm-test.sh --list          o que é o quê, e por quê
#   ./vm-test.sh 68 80           só esses
#   ./vm-test.sh --vault         só os que dependem de cofre/dotfiles
#   ./vm-test.sh --all           tudo, inclusive o que vai falhar sem cofre
#
#   VM_HOST (localhost)  VM_PORT (2223, a do rig em vm/)  VM_USER (o usuário local)
#   VM_DEST (ezomar, relativo ao home da VM)  VM_SSH_OPTS (opções extras do ssh)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$SCRIPT_DIR/install/apps"

say()  { echo "[ezomar][vm-test] $*"; }
warn() { echo "[ezomar][vm-test] $*" >&2; }

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_BAD=""; C_DIM=""; C_OFF=""
fi

# --- classificação dos módulos -------------------------------------------------
#
# Tier "cofre" is not a guess: each of these fails on a bare VM at a specific
# line, and the line is in the note. Everything else is tier "vm", including the
# ones that no-op (50, 72, 74, 76, 82): a no-op is the correct behaviour on a
# blank machine and is worth confirming, since it is what the real install does
# before the dotfiles land.
declare -A TIER=(
  [20-age-key.sh]=cofre
  [30-chezmoi.sh]=cofre
  [62-cliproxyapi-exato.sh]=cofre
  [90-verify.sh]=cofre
)
declare -A NOTE=(
  [00-packages.sh]="pacman; precisa de rede e sudo"
  [35-shell.sh]="chsh via sudo, e só depois do chezmoi; pula sem ~/.zshrc"
  [10-bitwarden-cli.sh]="baixa o binário oficial, não faz login"
  [20-age-key.sh]="exige o Bitwarden destravado NA VM (bw login && bw unlock)"
  [30-chezmoi.sh]="exige a chave age do 20 e uma chave SSH com acesso ao repo privado"
  [40-claude-plugins.sh]="marketplaces e plugins; sai limpo se o claude não estiver no PATH"
  [50-personal.sh]="no-op enquanto o chezmoi não trouxer ~/.config/ezomar/apps"
  [56-herdr.sh]="instalador oficial; o unit é dos dotfiles, aqui só entra o binário"
  [58-npm-ai-clis.sh]="npm global em ~/.npm-global; logins ficam para depois"
  [60-cliproxyapi.sh]="gera a própria chave local, então fecha sozinho; falta só o login de subscription"
  [61-ai-usagebar.sh]="AUR (ai-usagebar-bin) ou cargo; é o módulo mais demorado"
  [62-cliproxyapi-exato.sh]="exige ~/.claude-profiles/codex-exato/settings.json, que só o chezmoi entrega"
  [64-codex-profiles.sh]="cria os homes e symlinks; avisa do snippet zsh ausente sem falhar"
  [66-claude-profile-restore.sh]="instala o helper; sem ~/.claude-profiles o mapa sai vazio"
  [68-pidbox.sh]="autocontido, e ainda prova a contenção com --check-hard"
  [70-collie.sh]="opt-in; com EZOMAR_AUTOMATED=true ele pula sem perguntar"
  [72-tools-repo.sh]="no-op sem EZOMAR_TOOLS_REPO; com ele, precisa de chave SSH na VM"
  [74-meeting-rig.sh]="pula sem o repo de ferramentas"
  [76-claude-auth-preflight.sh]="pula sem o repo de ferramentas"
  [78-pw-keepalive.sh]="instala o daemon; só avisa que op/bw faltam"
  [80-oom-guard.sh]="sysctl + drop-ins de usuário; o teto da frota depende de herdr.service"
  [82-watchdog.sh]="pula sem /dev/watchdog, que a VM não tem por padrão"
  [90-verify.sh]="afere a máquina pronta: sem cofre nem dotfiles fecha vermelho de propósito"
)

all_modules() {
  local f found=false
  for f in "$APPS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    found=true
    basename "$f"
  done
  [ "$found" = true ]
}

tier_of() { printf '%s\n' "${TIER[$1]:-vm}"; }
note_of() { printf '%s\n' "${NOTE[$1]:-não classificado (módulo novo? entra no conjunto padrão)}"; }

usage() {
  cat <<'EOF'
Uso: ./vm-test.sh [opções] [módulo...]

Sincroniza a árvore de trabalho (sem .git) para a VM e roda os módulos lá,
então o que é testado é o que está no disco agora, inclusive o não commitado.

Opções:
  --list        mostra os módulos, o tier de cada um e o porquê
  --all         roda todos, inclusive os que dependem de cofre/dotfiles
  --vault       roda só os que dependem de cofre/dotfiles
  --no-sync     não sincroniza; usa a cópia que já está na VM
  --dry-run     mostra o plano e não encosta na VM
  -h, --help    isto

Módulos podem ser abreviados pelo número: "68" resolve 68-pidbox.sh.

Conexão (variáveis de ambiente):
  VM_HOST=localhost  VM_PORT=2223  VM_USER=<usuário local>
  VM_DEST=ezomar     VM_SSH_OPTS=""

Variáveis EZOMAR_* definidas aqui viajam para a VM, então dá para testar os
módulos de cofre com, por exemplo:
  EZOMAR_AGE_ITEM='age identity' ./vm-test.sh 20
EOF
}

# --- modo remoto ---------------------------------------------------------------
#
# The trap that kills the sudo keepalive fires at exit, which is after remote_run
# has already returned, so the pid has to outlive the function. Keeping it local
# costs an "unbound variable" under set -u, and a clean run then ends in a
# failure no module caused.
SUDO_REFRESH_PID=""
remote_cleanup() {
  [ -n "$SUDO_REFRESH_PID" ] && kill "$SUDO_REFRESH_PID" 2>/dev/null
  return 0
}

# Reentrant on purpose: the copy that lands in the VM is this same file, so the
# harness needs no second artefact to transfer and cannot go out of sync with
# itself. Nothing below this point runs on the host.
remote_run() {
  local modules=("$@")

  # An ssh command is non-interactive and non-login, so the dotfiles' PATH never
  # loads. The real pipeline runs from a login shell, so add the same dirs by
  # hand; otherwise modules report a missing binary that the machine does have.
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin:$PATH"

  # Same value install.sh uses: it is what makes 70-collie skip instead of
  # asking a question, and the harness is testing the automated path.
  export EZOMAR_AUTOMATED="${EZOMAR_AUTOMATED:-true}"
  # Default off in a VM: mrig setup downloads a whisper model, which is minutes
  # and gigabytes for a machine that gets deleted. Override to exercise it.
  export EZOMAR_SKIP_MRIG_SETUP="${EZOMAR_SKIP_MRIG_SETUP:-true}"

  local m missing=()
  for m in "${modules[@]}"; do
    [ -f "$APPS_DIR/$m" ] || missing+=("$m")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "Módulos ausentes na cópia da VM: ${missing[*]}"
    warn "A sincronização falhou ou a cópia está velha; rode sem --no-sync."
    exit 1
  fi

  # 60, 62 and 80 write user units and call `systemctl --user`. Over ssh that
  # only works when the user manager is up for this login. Warn instead of
  # failing: the other modules do not care, and the fix is one command.
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    warn "Aviso: sem barramento de usuário nesta sessão; 60, 62 e 80 vão falhar."
    warn "       Na VM: loginctl enable-linger \$USER, e reconecte."
  fi

  # Only ask for a password when something is going to need one. apps.sh always
  # asks because it always runs 00-packages; here `./vm-test.sh 68` should not
  # demand a password it will never use. The helpers are in the pattern because
  # 61 reaches pacman through them without ever writing "sudo".
  #
  # Comment lines are stripped first, or 30 and 58 would ask for a password on
  # the strength of a comment that says they do not need one. Process
  # substitution and not a pipe: under pipefail, `grep -q` closing the pipe
  # early turns a successful match into a failed pipeline.
  local needs_sudo=false
  for m in "${modules[@]}"; do
    if grep -qE '(^|[^[:alnum:]_])(sudo|pacman|yay|paru|omarchy pkg)([^[:alnum:]_]|$)' \
         <(grep -vE '^[[:space:]]*#' "$APPS_DIR/$m"); then
      needs_sudo=true
      break
    fi
  done
  if [ "$needs_sudo" = true ]; then
    if sudo -n true 2>/dev/null; then
      say "Sudo NOPASSWD disponível."
    else
      say "Autenticação necessária (módulos que instalam pacotes)..."
      sudo -v
    fi
    # Keep the timestamp warm for the whole run, exactly as apps.sh does.
    (while true; do sudo -n true; sleep 50; done 2>/dev/null) &
    SUDO_REFRESH_PID=$!
  fi
  trap remote_cleanup EXIT

  local results=() failed=()
  local started elapsed code
  for m in "${modules[@]}"; do
    echo
    echo "[ezomar][vm-test][módulo] $m"
    started=$SECONDS
    code=0
    bash "$APPS_DIR/$m" || code=$?
    elapsed=$((SECONDS - started))
    results+=("$m|$code|$elapsed")
    if [ "$code" -ne 0 ]; then
      echo "[ezomar][vm-test][módulo] $m FALHOU (saída $code), seguindo para o próximo"
      failed+=("$m")
    fi
  done

  echo
  say "Resumo: $(( ${#results[@]} - ${#failed[@]} )) ok, ${#failed[@]} com falha"
  local entry name secs
  for entry in "${results[@]}"; do
    IFS='|' read -r name code secs <<<"$entry"
    if [ "$code" -eq 0 ]; then
      printf '  %s✓%s %-30s %ss\n' "$C_OK" "$C_OFF" "$name" "$secs"
    else
      printf '  %s✗%s %-30s %ss (saída %s)\n' "$C_BAD" "$C_OFF" "$name" "$secs" "$code"
    fi
  done

  if [ ${#failed[@]} -gt 0 ]; then
    local short=()
    for name in "${failed[@]}"; do short+=("${name%%-*}"); done
    echo
    say "Para repetir só o que falhou: ./vm-test.sh ${short[*]}"
    exit 1
  fi
  echo
  say "Todos passaram."
}

if [ "${1:-}" = "--remote-run" ]; then
  shift
  [ $# -gt 0 ] || { warn "--remote-run sem módulos."; exit 2; }
  remote_run "$@"
  exit 0
fi

# --- daqui para baixo, só o lado do host ---------------------------------------
VM_HOST="${VM_HOST:-localhost}"
VM_PORT="${VM_PORT:-2223}"
VM_USER="${VM_USER:-$(id -un)}"
VM_DEST="${VM_DEST:-ezomar}"

# O que NÃO atravessa para a VM. A regra que importa é a primeira: o repo passou
# a carregar o disco da VM de ensaio (vm/storage/data.img, 64 GB) e o drive de
# autoinstall, e sem isto a sincronização tenta copiar a VM para dentro dela
# mesma, enchendo o disco do guest. Ler o .gitignore em vez de listar nomes faz
# a regra continuar valendo para o próximo artefato grande que alguém ignorar.
SYNC_EXCLUDES=(
  --filter=':- .gitignore'
  --exclude '.git'
  --exclude '*.log'
  --exclude 'vm/storage'
  --exclude '*.img'
  --exclude '*.iso'
  --exclude '*.qcow2'
)

# A throwaway VM is rebuilt often and always answers on the same localhost port
# with a brand new host key. StrictHostKeyChecking=accept-new (what ezdora used)
# then refuses every run after the first, and the fix is hand-editing
# known_hosts. Keep the churn out of the file instead; set VM_SSH_OPTS to
# restore normal checking when pointing this at a machine that is not disposable.
SSH_OPTS=(-p "$VM_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR)
if [ -n "${VM_SSH_OPTS:-}" ]; then
  read -r -a extra_ssh_opts <<<"$VM_SSH_OPTS"
  SSH_OPTS+=("${extra_ssh_opts[@]}")
fi

MODE=default
DO_SYNC=true
DRY_RUN=false
TOKENS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list)    MODE=list ;;
    --all)     MODE=all ;;
    --vault|--cofre) MODE=vault ;;
    --no-sync) DO_SYNC=false ;;
    --dry-run) DRY_RUN=true ;;
    -*)        warn "Opção desconhecida: $1"; usage >&2; exit 2 ;;
    *)         TOKENS+=("$1") ;;
  esac
  shift
done

if [ ! -d "$APPS_DIR" ]; then
  warn "$APPS_DIR não existe. Rode este script de dentro do repositório ezomar."
  exit 1
fi

mapfile -t ALL < <(all_modules)
if [ ${#ALL[@]} -eq 0 ]; then
  warn "Nenhum módulo em $APPS_DIR."
  exit 1
fi

if [ "$MODE" = list ]; then
  say "Módulos, e o que cada um consegue fazer numa VM zerada"
  for m in "${ALL[@]}"; do
    tier="$(tier_of "$m")"
    if [ "$tier" = vm ]; then
      printf '  %svm   %s %-30s %s\n' "$C_OK" "$C_OFF" "$m" "$(note_of "$m")"
    else
      printf '  %scofre%s %-30s %s\n' "$C_DIM" "$C_OFF" "$m" "$(note_of "$m")"
    fi
  done
  echo
  say "Padrão: os 'vm'. Os 'cofre' entram com --vault, --all, ou pelo nome."
  exit 0
fi

# Resolve "68" or "68-pidbox" or "68-pidbox.sh" to the real filename, so the
# summary line above can be pasted straight back in.
resolve_module() {
  local want="${1%.sh}" m base hits=()
  for m in "${ALL[@]}"; do
    base="${m%.sh}"
    if [ "$base" = "$want" ] || [[ "$base" == "$want"-* ]]; then
      hits+=("$m")
    fi
  done
  case ${#hits[@]} in
    1) printf '%s\n' "${hits[0]}" ;;
    0) warn "Módulo desconhecido: $1 (veja ./vm-test.sh --list)"; return 1 ;;
    *) warn "Módulo ambíguo: $1 -> ${hits[*]}"; return 1 ;;
  esac
}

RUN=()
if [ ${#TOKENS[@]} -gt 0 ]; then
  # Explicit names win over the mode, and are re-sorted into filename order:
  # the numbering is a dependency (20 before 30), so honouring the order they
  # were typed in would let the harness run a sequence the real install cannot.
  picked=()
  for t in "${TOKENS[@]}"; do
    picked+=("$(resolve_module "$t")")
  done
  mapfile -t RUN < <(printf '%s\n' "${picked[@]}" | sort -u)
else
  for m in "${ALL[@]}"; do
    tier="$(tier_of "$m")"
    case "$MODE" in
      all)                                     RUN+=("$m") ;;
      vault)   [ "$tier" = cofre ] && RUN+=("$m") ;;
      default) [ "$tier" = vm ]    && RUN+=("$m") ;;
    esac
  done
fi

if [ ${#RUN[@]} -eq 0 ]; then
  warn "Nenhum módulo selecionado."
  exit 1
fi

# EZOMAR_* set on the host travel with the run, which is how the vault modules
# get their two values without a config file inside the VM. Nothing else from
# the environment is forwarded: session tokens are the VM's own business.
REMOTE_ENV=()
for name in "${!EZOMAR_@}"; do
  REMOTE_ENV+=("$(printf '%s=%q' "$name" "${!name}")")
done

# The tilde stays literal here (double quotes suppress expansion on this side)
# so the VM's shell resolves it against the VM's home, not this machine's.
REMOTE_CMD="cd ~/$(printf '%q' "$VM_DEST") && "
[ ${#REMOTE_ENV[@]} -gt 0 ] && REMOTE_CMD+="env ${REMOTE_ENV[*]} "
REMOTE_CMD+="bash vm-test.sh --remote-run"
for m in "${RUN[@]}"; do
  REMOTE_CMD+=" $(printf '%q' "$m")"
done

say "Alvo: $VM_USER@$VM_HOST:$VM_PORT (~/$VM_DEST)"
say "Módulos (${#RUN[@]}): ${RUN[*]}"

if [ "$DRY_RUN" = true ]; then
  echo
  say "Dry-run, nada foi enviado. Seria executado:"
  [ "$DO_SYNC" = true ] && printf '  rsync -azs --delete %s %q %q\n' \
    "${SYNC_EXCLUDES[*]}" "$SCRIPT_DIR/" "$VM_USER@$VM_HOST:$VM_DEST/"
  echo "  ssh -t ${SSH_OPTS[*]} $VM_USER@$VM_HOST '$REMOTE_CMD'"
  exit 0
fi

# --- preflight -----------------------------------------------------------------
#
# Two failures look identical from rsync ("connection closed") and have opposite
# fixes, so they are separated here: nothing listening (VM down, wrong port, ISO
# still at the installer) versus listening but refusing the key (sshd is up and
# your key is not in the VM). Both cost a round trip; a wrong guess costs a
# debugging session.
if ! timeout 5 bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "$VM_HOST" "$VM_PORT" 2>/dev/null; then
  warn "Nada escutando em $VM_HOST:$VM_PORT."
  warn "  - a VM está de pé? (no cobaia, a porta vem do hostfwd tcp::$VM_PORT-:22)"
  warn "  - o Omarchy recém-instalado não sobe sshd sozinho. Dentro da VM:"
  warn "      sudo pacman -S --needed openssh && sudo systemctl enable --now sshd"
  exit 1
fi

PROBE_SCRIPT='command -v rsync >/dev/null 2>&1 && echo rsync=sim || echo rsync=nao
command -v bash  >/dev/null 2>&1 && echo bash=sim  || echo bash=nao
. /etc/os-release 2>/dev/null || true
echo id=${ID:-desconhecido}
echo id_like=${ID_LIKE:-}'
if ! PROBE="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_OPTS[@]}" \
    "$VM_USER@$VM_HOST" "$PROBE_SCRIPT" 2>&1)"; then
  warn "A porta $VM_PORT responde, mas o ssh não autenticou como $VM_USER."
  warn "Resposta do ssh:"
  printf '  %s\n' "$PROBE" >&2
  warn "Provavelmente falta a sua chave lá dentro. Na máquina host:"
  warn "  ssh-copy-id -p $VM_PORT $VM_USER@$VM_HOST"
  warn "(senha por prompt não serve: o rsync e o ssh pediriam duas vezes por execução)"
  exit 1
fi

if [[ "$PROBE" != *"bash=sim"* ]]; then
  warn "A VM não tem bash, e os módulos e este próprio script rodam nele."
  exit 1
fi
case "$PROBE" in
  # O Omarchy responde ID=omarchy e ID_LIKE=arch, que e o mesmo criterio que o
  # install.sh usa para aceitar a maquina. Olhar so o ID daria um aviso falso.
  *"id=arch"*|*"id_like="*"arch"*) : ;;
  *) warn "Aviso: a VM não se identifica como Arch ($(printf '%s' "$PROBE" | sed -n 's/^id=//p')),"
     warn "       então 00-packages e 35-shell provavelmente vão falhar." ;;
esac
say "VM alcançável."

# --- sincronização -------------------------------------------------------------
if [ "$DO_SYNC" = true ]; then
  say "Sincronizando a árvore de trabalho (sem .git)..."
  if command -v rsync >/dev/null 2>&1 && [[ "$PROBE" == *"rsync=sim"* ]]; then
    rsync -azs --delete "${SYNC_EXCLUDES[@]}" \
      -e "ssh ${SSH_OPTS[*]}" \
      "$SCRIPT_DIR/" "$VM_USER@$VM_HOST:$VM_DEST/"
  else
    # Arch base carries tar but not rsync, and a fresh Omarchy may have neither
    # installed nor a reason to. tar over ssh needs nothing extra; it just does
    # not delete files removed since the last sync, which in a disposable VM is
    # a fair trade for not having to install a package before testing one.
    say "rsync indisponível de um dos lados; usando tar sobre ssh (sem --delete)."
    tar -C "$SCRIPT_DIR" --exclude '.git' --exclude './vm/storage' \
        --exclude '*.img' --exclude '*.iso' --exclude '*.qcow2' -czf - . \
      | ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_HOST" \
          "mkdir -p ~/$(printf '%q' "$VM_DEST") && tar -C ~/$(printf '%q' "$VM_DEST") -xzf -"
  fi
else
  say "Sem sincronizar (--no-sync): rodando a cópia que já está na VM."
fi

# -t because the modules prompt: sudo wants a password, and config.sh asks for
# EZOMAR_AGE_ITEM / EZOMAR_DOTFILES_REPO when they were not passed in.
say "Executando na VM..."
echo
RC=0
ssh -t "${SSH_OPTS[@]}" "$VM_USER@$VM_HOST" "$REMOTE_CMD" || RC=$?

echo
if [ "$RC" -eq 0 ]; then
  say "${C_OK}Fim: sem falhas.${C_OFF}"
else
  say "${C_BAD}Fim: houve falha (saída $RC). O resumo por módulo está acima.${C_OFF}"
fi
exit "$RC"
