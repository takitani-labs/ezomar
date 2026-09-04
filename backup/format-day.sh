#!/usr/bin/env bash
set -euo pipefail

# This is a checkpointed handrail, not an unattended installer. Browser and
# vault authentication remains under human control, while every transition is
# verified before it is written to the checkpoint file.
#
#   EZOMAR_AI_BACKUP=/mnt/nas/ezomar-ai-....tar.zst \
#   EZOMAR_WIP_BACKUP=/mnt/nas/ezomar-wip-....tar.zst \
#     bash backup/format-day.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STATE="${EZOMAR_FORMAT_STATE:-$HOME/.local/state/ezomar/format-day.done}"
AI_BACKUP="${EZOMAR_AI_BACKUP:-${1:-}}"
WIP_BACKUP="${EZOMAR_WIP_BACKUP:-${2:-}}"
HERDR_GUARD="$HOME/.config/systemd/user.control/herdr.service"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

say() { echo "[ezomar][format-day] $*"; }
die() { echo "[ezomar][format-day] $*" >&2; exit 1; }
[ -n "$AI_BACKUP" ] && [ -f "$AI_BACKUP" ] || die "defina EZOMAR_AI_BACKUP com o tarball copiado para fora da máquina antiga."
[ -n "$WIP_BACKUP" ] && [ -f "$WIP_BACKUP" ] || die "defina EZOMAR_WIP_BACKUP com o tarball de WIP."

backup_identity() {
  local backup="$1" digest
  # The checkpoint is a claim about content, not a filename. Hash the artifact
  # itself even when there is a sidecar: a corrected tarball copied in place
  # must replay completed restore steps, and a stale sidecar must not make the
  # old checkpoints look applicable. The restore scripts still verify any
  # sidecar before consuming the artifact.
  digest="$(sha256sum "$backup" | awk '{ print $1 }')"
  printf '%s|%s' "$(readlink -f "$backup")" "$digest"
}

# Scope every checkpoint to the two input artifacts. A corrected tarball must
# replay earlier restore steps even when an old state file says their names ran.
RUN_ID="$(printf '%s\n%s\n' "$(backup_identity "$AI_BACKUP")" "$(backup_identity "$WIP_BACKUP")" | sha256sum | cut -d' ' -f1)"
done_before() { [ -f "$STATE" ] && grep -Fxq "$RUN_ID:$1" "$STATE"; }
mark_done() { mkdir -p "$(dirname "$STATE")"; grep -Fxq "$RUN_ID:$1" "$STATE" 2>/dev/null || printf '%s:%s\n' "$RUN_ID" "$1" >>"$STATE"; }

run_step() {
  local id="$1" label="$2" fn="$3"
  if done_before "$id"; then
    say "Já concluído: $label"
    return 0
  fi
  say "Etapa: $label"
  "$fn"
  mark_done "$id"
}

wait_for_human() {
  local label="$1" instruction="$2" verify="$3"
  while ! "$verify"; do
    [ -t 0 ] || die "$label precisa de um terminal humano. $instruction"
    say "$instruction"
    read -r -p "[ezomar][format-day] Depois de concluir '$label', pressione Enter para verificar: "
  done
  say "$label verificado."
}

verify_bw() {
  local session_file base profile session profile_dir
  shopt -s nullglob
  for session_file in "$HOME/.bw_session" "$HOME"/.bw_session_*; do
    [ -s "$session_file" ] || continue
    session="$(<"$session_file")"
    base="${session_file##*/}"
    if [[ "$base" == .bw_session_* ]]; then
      profile="${base#.bw_session_}"
      profile_dir="$HOME/.bw-profiles/$profile"
      if BITWARDENCLI_APPDATA_DIR="$profile_dir" BW_SESSION="$session" bw status 2>/dev/null \
        | grep -Eq '"status"[[:space:]]*:[[:space:]]*"unlocked"'; then
        shopt -u nullglob
        return 0
      fi
    else
      if BW_SESSION="$session" bw status 2>/dev/null \
        | grep -Eq '"status"[[:space:]]*:[[:space:]]*"unlocked"'; then
        shopt -u nullglob
        return 0
      fi
      for profile_dir in "$HOME"/.bw-profiles/*; do
        [ -d "$profile_dir" ] || continue
        if BITWARDENCLI_APPDATA_DIR="$profile_dir" BW_SESSION="$session" bw status 2>/dev/null \
          | grep -Eq '"status"[[:space:]]*:[[:space:]]*"unlocked"'; then
          shopt -u nullglob
          return 0
        fi
      done
    fi
  done
  shopt -u nullglob
  bw status 2>/dev/null | grep -Eq '"status"[[:space:]]*:[[:space:]]*"unlocked"'
}
verify_op() {
  local session shorthand
  if [ -s "$HOME/.op_session" ]; then
    session="$(<"$HOME/.op_session")"
    if [ -r "$HOME/.config/op/config" ] && command -v jq >/dev/null 2>&1; then
      while IFS= read -r shorthand; do
        [ -n "$shorthand" ] || continue
        if env "OP_SESSION_${shorthand}=$session" op whoami >/dev/null 2>&1; then
          return 0
        fi
      done < <(jq -r '.accounts[]?.shorthand // empty' "$HOME/.config/op/config" 2>/dev/null)
    fi
  fi
  # The desktop keyring can already hold a valid session even without a file.
  op whoami >/dev/null 2>&1
}
# Duas armadilhas aqui. `claude auth status` sai com zero mesmo deslogado, então
# o que vale é o "loggedIn": true da saída, não o código de retorno. E esta
# máquina nunca usa o ~/.claude padrão: cada sessão roda sob um perfil, e é lá
# que o tarball entrega as credenciais. Basta um perfil autenticado.
claude_logged_in() {
  claude auth status 2>/dev/null | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'
}

verify_claude() {
  local profile
  claude_logged_in && return 0
  for profile in "$HOME"/.claude-profiles/*/; do
    [ -f "$profile/.credentials.json" ] || continue
    if CLAUDE_CONFIG_DIR="${profile%/}" claude_logged_in; then
      say "Claude autenticado no perfil $(basename "${profile%/}")."
      return 0
    fi
  done
  return 1
}
verify_codex() { codex login status >/dev/null 2>&1; }

ensure_chezmoi() {
  if command -v chezmoi >/dev/null 2>&1; then return 0; fi
  command -v curl >/dev/null 2>&1 || die "curl ausente; não consigo instalar o binário do chezmoi para a restauração segura."
  say "Instalando somente o binário do chezmoi antes das credenciais."
  mkdir -p "$HOME/.local/bin"
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" >/dev/null
  command -v chezmoi >/dev/null 2>&1 || die "chezmoi não ficou disponível."
}

guard_herdr() {
  systemctl --user stop herdr.service >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$HERDR_GUARD")"
  if [ -e "$HERDR_GUARD" ] || [ -L "$HERDR_GUARD" ]; then
    [ -L "$HERDR_GUARD" ] && [ "$(readlink "$HERDR_GUARD")" = /dev/null ] \
      || die "$HERDR_GUARD já existe e não é a trava esperada; não vou sobrescrever."
  else
    ln -s /dev/null "$HERDR_GUARD"
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if systemctl --user is-active herdr.service >/dev/null 2>&1; then
    die "herdr.service continua ativo; recusando avançar sem proteger session.json."
  fi
  say "herdr.service está parado e mascarado persistentemente até session.json ser conferido."
}

step_credentials() {
  local key has_private=false
  ensure_chezmoi
  EZOMAR_BACKUP_ONLY='.ssh .gnupg .config/op' bash "$SCRIPT_DIR/restore-ai.sh" "$AI_BACKUP"
  for key in "$HOME/.ssh"/*; do
    [ -f "$key" ] || continue
    if grep -IqE '^-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----$' "$key" 2>/dev/null; then
      has_private=true
      break
    fi
  done
  if [ "$has_private" = false ] \
     && ! find "$HOME/.gnupg/private-keys-v1.d" -maxdepth 1 -type f -name '*.key' -size +0c -print -quit 2>/dev/null | grep -q .; then
    die "a passagem de credenciais terminou sem chave privada SSH ou GnuPG."
  fi
}

step_install_bootstrap() {
  # Only the base and the vault client can run before the vault and chezmoi.
  EZOMAR_INSTALL_ONLY='00-packages.sh 10-bitwarden-cli.sh' bash "$REPO_DIR/install.sh"
}

step_bw_login() {
  wait_for_human "bw unlock" "Em outro terminal, rode 'bw login' se preciso e depois 'bws personal' ou 'bw unlock'." verify_bw
}

step_login_tools() {
  # Applying chezmoi provides the ops shell helper; module 58 provides codex.
  EZOMAR_INSTALL_ONLY='35-shell.sh 58-npm-ai-clis.sh' bash "$REPO_DIR/install.sh"
}

step_op_login() {
  wait_for_human "ops" "Em outro terminal, rode 'ops' e conclua o login do 1Password." verify_op
}

# Claude e Codex ficam DEPOIS do restore de propósito. As credenciais das cinco
# contas viajam no tarball, então quando o restore passa estes dois verificam
# sozinhos e nenhum navegador é aberto. Perguntar antes do restore obrigava um
# /login à mão para uma conta que já estava a caminho, e ainda gravava por cima
# do que o tarball traria em seguida.
step_agent_logins() {
  wait_for_human "claude login" "Em outro terminal, rode 'claude' e conclua /login no navegador." verify_claude
  wait_for_human "codex login" "Em outro terminal, rode 'codex login' e conclua o navegador." verify_codex
}

# Medido no ensaio em VM: sem a identidade age, o `chezmoi apply` aborta no
# primeiro arquivo criptografado, e aborta ANTES de criar os symlinks
# ~/.claude-profiles/*/projects. As 11 mil conversas continuam no disco sob
# ~/.claude/projects, os perfis e as credenciais voltam, e a máquina parece
# restaurada -- mas cada pane retomado abre um perfil cujo store está vazio, e
# `claude --resume` não acha transcript nenhum. Ninguém adiante percebe, então a
# checagem tem que ser aqui.
assert_chezmoi_converged() {
  local pending profile link broken=0 ok=0
  if ! pending="$(chezmoi status 2>&1)"; then
    die "o chezmoi não consegue avaliar o estado (${pending%%$'\n'*})."
  fi
  [ -z "$pending" ] || say "Aviso: o chezmoi ainda lista $(printf '%s\n' "$pending" | wc -l) caminho(s) por aplicar."

  # Aqui só se cobra que o link exista e aponte para o lugar certo. Ele fica
  # pendurado de propósito: ~/.claude/projects só chega no restore completo,
  # que roda depois deste passo. Quem cobra que ele resolva é
  # assert_profile_stores, logo antes do herdr subir.
  for profile in "$HOME"/.claude-profiles/*/; do
    [ -d "$profile" ] || continue
    link="$profile/projects"
    if [ -L "$link" ] || [ -d "$link" ]; then
      ok=$((ok + 1))
    else
      broken=$((broken + 1))
      # --force porque o chezmoi pergunta antes de reescrever um caminho que
      # mudou desde a última vez que ele o escreveu, e a pergunta morre sem TTY.
      say "Perfil sem store de conversas: ${profile%/}"
      say "  reparo: chezmoi apply --force ${profile}projects"
    fi
  done

  [ "$broken" -eq 0 ] \
    || die "$broken perfil(is) sem ~/.claude-profiles/<perfil>/projects; os panes retomariam vazios."
  [ "$ok" -gt 0 ] || die "nenhum perfil do Claude foi restaurado pelo chezmoi."
  say "Os $ok perfis têm o link para o store de conversas."
}

# O link do chezmoi pode estar certo e ainda assim não levar a lugar nenhum, se
# o restore não trouxe ~/.claude/projects. Como cada pane retomado abre
# `claude --resume <uuid>` sob o seu perfil, um link pendurado aqui significa a
# frota inteira voltando sem conversa. Por isso esta cobrança fica colada no
# início do herdr, quando o restore já passou.
assert_profile_stores() {
  local profile link dangling=0 ok=0
  for profile in "$HOME"/.claude-profiles/*/; do
    [ -d "$profile" ] || continue
    link="$profile/projects"
    [ -L "$link" ] || [ -d "$link" ] || continue
    if [ -d "$link" ]; then
      ok=$((ok + 1))
    else
      dangling=$((dangling + 1))
      say "Store de conversas não resolve: ${profile%/}/projects -> $(readlink "$link")"
    fi
  done
  [ "$dangling" -eq 0 ] \
    || die "$dangling perfil(is) com o store pendurado; os panes retomariam sem conversa."
  say "Os $ok perfis resolvem o store de conversas."
}

step_chezmoi() {
  bash "$REPO_DIR/install/apps/20-age-key.sh"
  [ -s "$HOME/.config/age/keys.txt" ] || die "a identidade age não foi restaurada pelo cofre."
  bash "$REPO_DIR/install/apps/30-chezmoi.sh"
  [ -d "$(chezmoi source-path)/.git" ] || die "o source do chezmoi não foi clonado."
  assert_chezmoi_converged
}

step_remaining_install() {
  EZOMAR_INSTALL_SKIP='00-packages.sh 10-bitwarden-cli.sh 20-age-key.sh 30-chezmoi.sh 35-shell.sh 58-npm-ai-clis.sh 90-verify.sh' \
    bash "$REPO_DIR/install.sh"
}

step_full_restore() {
  EZOMAR_DEFER_HERDR_SESSION=true bash "$SCRIPT_DIR/restore-ai.sh" "$AI_BACKUP" --force
}

# Falha de clone é fatal por padrão: quase sempre significa chave SSH ainda não
# configurada, e seguir em frente deixaria panes apontando para diretórios que
# não existem. Mas há um caso legítimo de seguir mesmo assim, o remote que
# morreu: aí não existe clone possível, o preformat já avisou antes do format, e
# a decisão de perder aquela história é do humano, não do script.
step_restore_repos() {
  if bash "$SCRIPT_DIR/restore-repos.sh"; then
    return 0
  fi
  [ "${EZOMAR_ALLOW_REPO_FAILURES:-}" = true ] \
    || die "reclone falhou. Revise a lista acima; EZOMAR_ALLOW_REPO_FAILURES=true segue assumindo a perda."
  say "Seguindo com repos faltando, por EZOMAR_ALLOW_REPO_FAILURES."
}
step_restore_wip() { bash "$SCRIPT_DIR/restore-wip.sh" "$WIP_BACKUP"; }
step_profiles() { bash "$REPO_DIR/install/apps/66-claude-profile-restore.sh"; }

step_session() {
  EZOMAR_BACKUP_ONLY='.config/herdr' bash "$SCRIPT_DIR/restore-ai.sh" "$AI_BACKUP" --force
  session="$HOME/.config/herdr/session.json"
  [ -s "$session" ] || die "session.json não apareceu; herdr continuará bloqueado."
  jq -e '.version == 3 and (.workspaces | length > 0)' "$session" >/dev/null \
    || die "session.json não contém uma frota v3 não vazia."
}

# Medido no ensaio em VM, e é a razão de esta checagem existir: quando o herdr
# sobe e o cwd de um pane não existe, ele não apenas cai no $HOME naquele boot,
# ele REESCREVE o session.json com o fallback. No ensaio os 99 panes de agente
# colapsaram dos seus repos (30 em dd-intelligence, 14 em atta, ...) para um
# único /home/opik, e o vínculo entre pane e repo sumiu de vez: os transcripts
# continuam no disco sob o slug do caminho antigo, e nada mais aponta para eles.
# Logo, um restore-repos incompleto não pode chegar a este passo.
assert_pane_cwds() {
  local session="$HOME/.config/herdr/session.json"
  local total missing cwd
  command -v jq >/dev/null 2>&1 || { say "jq ausente; não dá para conferir os cwd." >&2; return 0; }

  mapfile -t ALL_CWDS < <(jq -r '[.. | objects | select(has("cwd") and has("agent_session")) | .cwd] | .[]' "$session" 2>/dev/null)
  total=${#ALL_CWDS[@]}
  [ "$total" -gt 0 ] || { say "Nenhum pane com sessão de agente no índice."; return 0; }

  missing=0
  declare -A MISSING_COUNT=()
  for cwd in "${ALL_CWDS[@]}"; do
    [ -n "$cwd" ] || continue
    if [ ! -d "$cwd" ]; then
      missing=$((missing + 1))
      MISSING_COUNT["$cwd"]=$(( ${MISSING_COUNT["$cwd"]:-0} + 1 ))
    fi
  done

  if [ "$missing" -eq 0 ]; then
    say "Todos os $total cwd de pane existem."
    return 0
  fi

  say "$missing de $total panes apontam para diretórios que não existem:" >&2
  for cwd in "${!MISSING_COUNT[@]}"; do
    say "  ${MISSING_COUNT[$cwd]} pane(s) em $cwd" >&2
  done
  say "Subir o herdr agora grava esses fallbacks por cima do índice, e o vínculo" >&2
  say "entre pane e repo some para sempre. Termine o restore-repos antes." >&2
  [ "${EZOMAR_ALLOW_MISSING_CWDS:-}" = "true" ] \
    || die "recusando iniciar o herdr com cwd faltando (EZOMAR_ALLOW_MISSING_CWDS=true força)."
  say "EZOMAR_ALLOW_MISSING_CWDS=true: seguindo mesmo assim, por sua conta." >&2
}

step_start_herdr() {
  [ -s "$HOME/.config/herdr/session.json" ] || die "recusando iniciar herdr.service sem session.json."
  assert_profile_stores
  assert_pane_cwds
  if [ -L "$HERDR_GUARD" ] && [ "$(readlink "$HERDR_GUARD")" = /dev/null ]; then
    rm -- "$HERDR_GUARD"
  else
    die "a trava persistente do herdr sumiu ou mudou; não vou iniciar sem revisão."
  fi
  systemctl --user unmask --runtime herdr.service >/dev/null 2>&1 || true
  if ! systemctl --user daemon-reload \
     || ! systemctl --user enable --now herdr.service; then
    guard_herdr
    die "herdr.service não pôde ser habilitado; a trava persistente foi recolocada."
  fi
  for _ in $(seq 1 30); do
    if systemctl --user is-active herdr.service >/dev/null 2>&1 \
       && herdr session list 2>/dev/null | awk '$1 == "default" && $2 == "running" { found=1 } END { exit !found }'; then
      return 0
    fi
    sleep 1
  done
  guard_herdr
  die "herdr.service não permaneceu ativo com a sessão default rodando."
}

if ! done_before start-herdr; then guard_herdr; fi
run_step credentials "restaurar .ssh/.gnupg" step_credentials
run_step install-bootstrap "instalar base e cliente Bitwarden" step_install_bootstrap
run_step login-bw "concluir e verificar o login Bitwarden" step_bw_login
run_step chezmoi "restaurar age e aplicar chezmoi" step_chezmoi
run_step login-tools "instalar shell e Codex para os logins" step_login_tools
run_step login-op "concluir e verificar o login do 1Password" step_op_login
run_step install-rest "concluir os módulos idempotentes" step_remaining_install
run_step restore-ai "restaurar todo o estado, adiando session.json" step_full_restore
run_step login-agents "conferir Claude e Codex (o restore costuma bastar)" step_agent_logins
run_step restore-repos "reclonar repos nos caminhos absolutos" step_restore_repos
run_step restore-wip "reaplicar commits, stash, patches e não rastreados" step_restore_wip
run_step profiles "reconstruir sessionId → perfil com o módulo 66" step_profiles
run_step session "colocar e validar session.json" step_session
run_step start-herdr "iniciar herdr somente depois do índice" step_start_herdr

say "Restauração concluída. O checkpoint idempotente ficou em $STATE."
