#!/usr/bin/env bash
set -euo pipefail

# Roda na máquina VELHA. Gera um tar.zst com paths relativos a $HOME,
# restaurável pelo restore-ai.sh na máquina nova.
#
#   bash backup/backup-ai.sh [dir-destino]      (padrão: ~/backups)
#
# Why a tarball at all, when a chezmoi repo already rebuilds the machine:
# chezmoi carries the durable configuration (skills, profile settings, hooks,
# CLAUDE.md) and deliberately refuses two kinds of thing. The first is the
# Claude Code conversations under ~/.claude/projects, 589 repo slugs and tens of
# gigabytes rewritten every minute, which would turn every commit of the
# dotfiles repo into noise. The second is every credential on the machine, from
# ~/.claude.json (the MCP server list and its tokens) down to ~/.ssh. This
# tarball is exactly that gap. An audit before the format found that nothing at
# all restored ~/.claude.json, which is why it is the first entry below.
#
# The tarball is NOT encrypted. It carries private keys and OAuth tokens, so it
# travels over tailscale/ssh to a machine you own, and nowhere else.
#
# Knobs:
#   EZOMAR_BACKUP_ONLY   lista de caminhos relativos a $HOME, separados por
#                        espaço, que SUBSTITUI a lista padrão. Serve para
#                        ensaiar o par backup/restore sem embarcar credencial
#                        nenhuma, e para tirar um tarball só de credenciais
#                        (sem as conversas, que são o grosso do tamanho).
#   EZOMAR_SKIP_OPENCODE_DB  true (padrão) pula opencode.db, opencode.db-wal e
#                        afins; false leva o banco vivo inteiro.

DEST_DIR="${1:-$HOME/backups}"
STAMP="$(date +%Y%m%d-%H%M)"
OUT="$DEST_DIR/ezomar-ai-$STAMP.tar.zst"

# Lista dos caminhos arquivados, gravada como PRIMEIRO membro do tarball.
# The restore side reads it back instead of keeping its own copy of this list:
# two lists that have to agree is the drift this repo keeps paying for, and it
# is also what makes EZOMAR_BACKUP_ONLY work on the restore side for free.
PATHS_MEMBER=".ezomar-backup-paths"
MANIFEST_REL=".ezomar-repos-manifest.tsv"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

say() { echo "[ezomar][backup-ai] $*"; }
die() { echo "[ezomar][backup-ai] $*" >&2; exit 1; }

command -v zstd >/dev/null 2>&1 || die "zstd não instalado (pacman -S zstd)."

# O que entra. Só o que existir de fato entra no tarball.
INCLUDE=(
  # --- Claude Code: as conversas e as credenciais, não a configuração -------
  .claude                     # projects/ (as conversas), history, file-history
  .claude-profiles            # por perfil: .credentials.json, .claude.json, projects@
  .claude.json                # servidores MCP e tokens; nada mais restaura isto

  # --- os outros CLIs de agente: OAuth, config e sessões -------------------
  .codex-profiles             # um CODEX_HOME por conta (módulo 64): auth.json + config.toml
  .codex                      # o symlink que aponta para a conta ativa
  .kimi-code
  .kimi                       # home anterior à migração; ainda guarda credentials
  .gemini
  .grok
  .config/opencode
  .local/share/opencode       # auth.json e opencode.db (as conversas)

  # --- the fleet must exist before its service is allowed to start ----------
  .config/herdr               # session.json is the only durable fleet index
                              # (inclui session-snapshots/, as cópias horárias)
  .local/state/ezomar         # uuids colhidos do scrollback: o único lugar onde
                              # sobrevive o vínculo pane -> conversa de um agente
                              # que morreu antes de o índice ser copiado
  .local/state/herdr          # small state; caches are harmless to regenerate
  .config/systemd/user        # herdr.service and its login-selecting drop-in

  # --- as APIs locais das subscriptions ------------------------------------
  .cli-proxy-api              # config.yaml (api-key local) + tokens OAuth
  .cli-proxy-api-exato        # segunda instância, conta Codex de trabalho (módulo 62)
  .config/ai-usagebar         # config.toml carrega chaves de API

  # --- credenciais da máquina: pequenas, e clássicas de se perder no format --
  .ssh
  .gnupg
  .aws
  .kube
  .config/gh
  .pgpass
  .npmrc
  .docker/config.json
  .bw-profiles                # os três perfis do bw (persona, personal, work)
  .config/op                  # inscrição do 1Password: sem ela, entrar exige a
                              # Secret Key do Emergency Kit. São 4 KB, e o
                              # tarball já carrega chave SSH privada e GnuPG.

  # --- estado que ninguém mais reporia --------------------------------------
  .config/meeting-rig         # contexto pessoal do mrig
  "$MANIFEST_REL"             # manifesto dos repos, gerado abaixo
)

# Fora daqui de propósito:
#   ~/.zshrc, ~/.tmux.conf, ~/.gitconfig, ~/.config/ezomar/config.sh  o chezmoi
#     carrega os quatro. Uma segunda cópia aqui é uma segunda fonte de verdade,
#     que envelhece calada e um dia é restaurada por cima da boa.
#   ~/.config/age/keys.txt   o módulo 20 tira do Bitwarden. Guardar a chave que
#     decripta os dotfiles num tarball em claro anularia a encriptação deles.
#   ~/.op_session, ~/.bw_session*   tokens de sessão, renovados pelo
#     pw-keepalive; na máquina nova nascem mortos.
#   ~/.local/state/meeting-rig   transcrições, que são saída e não configuração.

if [ -n "${EZOMAR_BACKUP_ONLY:-}" ]; then
  read -r -a INCLUDE <<<"$EZOMAR_BACKUP_ONLY"
  say "EZOMAR_BACKUP_ONLY ativo: a lista padrão foi substituída por ${#INCLUDE[@]} caminho(s)."
fi

# Lixo: o que o próprio CLI recria, ou o que o ezomar reinstala.
EXCLUDE_PATTERNS=(
  # Os plugins do Claude Code voltam pelo módulo 40 e carregam binário.
  '.claude/plugins'
  '.claude-profiles/*/plugins'
  # Estado de runtime, recriado no primeiro uso.
  '*/shell-snapshots'
  '*/shell_snapshots'
  '*/statsig'
  '*/telemetry'
  '*/paste-cache'
  '*/session-env'
  '.claude/local'
  '.claude/cache'
  '.claude/backups'
  '.claude/backup-rename-*'
  '.kimi-code/cache'
  '.kimi-code/search-index'
  '.grok/marketplace-cache'
  '.gemini/tmp'
  # Binários que o CLI rebaixa sozinho na primeira execução.
  '.kimi-code/bin'
  '.grok/bin'
  '.grok/bundled'
  '.grok/vendor'
  '.gemini/antigravity-browser-profile'
  # Logs.
  '*/logs'
  '*/log'
  '*.log'
  '.codex-profiles/*/logs_*.sqlite*'
  # 6,2G de transcrição do grok que ninguém relê; o auth.json é o que importa.
  '.grok/sessions'
  '.local/share/opencode/snapshot'
  # herdr installs its plugins again and recreates runtime/cache state. Keeping
  # the 323 MB tree would also preserve an orphaned 311 MB clone forever.
  '.config/herdr/plugins'
  '.config/herdr/*.log'
  '.config/herdr/*.sock'
  '.config/herdr/config.toml.bak'
  '.config/herdr/session.json.pre-crash-*'
  '*/node_modules'
  '*.sock'
)

# The 10 GB SQLite database is live while the fleet runs, so copying it by
# default costs time and can capture a WAL-dependent point-in-time image. The
# auth/config beside it still travels; set this false only when those OpenCode
# conversations are worth the large final tarball and its consistency risk.
if [ "${EZOMAR_SKIP_OPENCODE_DB:-true}" = "true" ]; then
  EXCLUDE_PATTERNS+=('.local/share/opencode/opencode.db*')
  say "opencode.db* será pulado (EZOMAR_SKIP_OPENCODE_DB=false para incluir o banco vivo)."
fi

# Snapshot dos repos, só quando o manifesto vai de fato neste tarball.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for p in "${INCLUDE[@]}"; do
  if [ "$p" = "$MANIFEST_REL" ] && [ -f "$SCRIPT_DIR/repos-manifest.sh" ]; then
    # The manifest belongs in the archive, not as new state under $HOME on the
    # disk about to be wiped. Staging preserves its relative restore path.
    bash "$SCRIPT_DIR/repos-manifest.sh" "$TMP_DIR/$MANIFEST_REL"
    break
  fi
done

# Filtra o que existe (-L pega symlink quebrado, que ainda assim vale arquivar:
# ~/.codex é um symlink para dentro de ~/.codex-profiles).
EXISTING=()
ABSENT=()
for p in "${INCLUDE[@]}"; do
  if [ "$p" = "$MANIFEST_REL" ] && [ -s "$TMP_DIR/$MANIFEST_REL" ]; then
    EXISTING+=("$p")
  elif [ -e "$HOME/$p" ] || [ -L "$HOME/$p" ]; then
    EXISTING+=("$p")
  else
    ABSENT+=("$p")
  fi
done
[ ${#EXISTING[@]} -gt 0 ] || die "nenhum dos caminhos pedidos existe em \$HOME."

# --- a sobreposição com o chezmoi ------------------------------------------------
#
# ~/.claude e ~/.claude-profiles são PARCIALMENTE gerenciados: settings.json,
# CLAUDE.md, hooks/ e as 291 skills são do chezmoi; projects/, .credentials.json
# e .claude.json não são de ninguém além deste tarball.
#
# Resolving that by hardcoding "chezmoi owns these subpaths" would create the
# exact failure this repo keeps finding: a second list, which goes stale the day
# a new skill or profile lands, and whose staleness is invisible. So ask chezmoi
# at backup time and turn every managed path under an included root into a tar
# --exclude. The tarball ends up holding precisely the complement, for every
# root, not just those two: ~/.ssh goes in whole except ~/.ssh/config.
#
# One consequence is worth naming: ~/.claude/settings.json is managed, so it
# never enters the tarball. That is the file the README warns about (Claude Code
# rewrites it with plugin state, and it does not converge between machines); a
# copy of it riding in here would land on the new machine and fight módulo 40
# for the same file.
declare -A MANAGED_SET=()
if command -v chezmoi >/dev/null 2>&1; then
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    MANAGED_SET["${m#"$HOME"/}"]=1
  # Directory ancestors are structural output, not ownership of their whole
  # subtree. In particular, excluding a managed profile directory would also
  # drop its unmanaged .credentials.json. Files and symlinks are the leaves.
  done < <(chezmoi managed --include=files,symlinks --path-style absolute 2>/dev/null || true)
fi
if [ ${#MANAGED_SET[@]} -eq 0 ]; then
  say "Aviso: chezmoi não respondeu; o tarball vai duplicar o que os dotfiles já carregam." >&2
fi

MANAGED_EXCLUDES=()
KEEP=()
for r in "${EXISTING[@]}"; do
  # Um caminho da lista que é ele próprio um arquivo gerenciado não tem por que
  # estar aqui: quem restaura ele é o chezmoi.
  if [ -n "${MANAGED_SET[$r]:-}" ] && [ ! -d "$HOME/$r" ]; then
    say "$r está no chezmoi (dotfiles); fora do tarball."
    continue
  fi
  KEEP+=("$r")
done
EXISTING=("${KEEP[@]}")

for m in "${!MANAGED_SET[@]}"; do
  root=""
  for r in "${EXISTING[@]}"; do
    case "$m" in "$r"/*) root="$r"; break ;; esac
  done
  [ -n "$root" ] || continue
  # Só o caminho gerenciado mais alto: excluir `.claude/skills` já leva os 291
  # arquivos dentro dele, e uma lista de 291 --exclude não ajuda ninguém.
  parent="${m%/*}"; skip=0
  while [ "$parent" != "$root" ] && [ "$parent" != "$m" ]; do
    if [ -n "${MANAGED_SET[$parent]:-}" ]; then skip=1; break; fi
    next="${parent%/*}"
    [ "$next" = "$parent" ] && break
    parent="$next"
  done
  [ "$skip" -eq 0 ] && MANAGED_EXCLUDES+=("$m")
done

TAR_ARGS=()
for x in "${EXCLUDE_PATTERNS[@]}"; do TAR_ARGS+=(--exclude="$x"); done
if [ ${#MANAGED_EXCLUDES[@]} -gt 0 ]; then
  while IFS= read -r x; do TAR_ARGS+=(--exclude="$x"); done < <(printf '%s\n' "${MANAGED_EXCLUDES[@]}" | sort)
fi

say "Incluindo (${#EXISTING[@]}): ${EXISTING[*]}"
[ ${#ABSENT[@]} -gt 0 ] && say "Não existem nesta máquina: ${ABSENT[*]}"
say "Excluído por já estar no chezmoi: ${#MANAGED_EXCLUDES[@]} caminho(s)"

# O manifesto do que entrou vai como primeiro membro, no diretório temporário,
# para não deixar rastro em $HOME. O restore lê ele com --occurrence=1 e para
# de ler o stream aí, sem descompactar dezenas de gigas para descobrir a lista.
printf '%s\n' "${EXISTING[@]}" >"$TMP_DIR/$PATHS_MEMBER"

HOME_EXISTING=()
for p in "${EXISTING[@]}"; do
  [ "$p" = "$MANIFEST_REL" ] || HOME_EXISTING+=("$p")
done
STAGED_MEMBERS=("$PATHS_MEMBER")
[ -s "$TMP_DIR/$MANIFEST_REL" ] && STAGED_MEMBERS+=("$MANIFEST_REL")

mkdir -p "$DEST_DIR"
say "Gerando $OUT ..."

# tar sai com 1 quando um arquivo muda enquanto é lido, o que é garantido aqui:
# a sessão do Claude que roda o backup está escrevendo em ~/.claude/projects.
# Sob pipefail isso abortaria e deixaria um tarball pela metade, então o status
# é lido à mão: 1 é aviso, acima disso é falha de verdade.
set +e
tar --ignore-failed-read "${TAR_ARGS[@]}" -cf - \
  -C "$TMP_DIR" "${STAGED_MEMBERS[@]}" \
  -C "$HOME" "${HOME_EXISTING[@]}" \
  | zstd -T0 -8 -q -o "$OUT"
STATUS=("${PIPESTATUS[@]}")
set -e

[ "${STATUS[1]}" -eq 0 ] || die "zstd falhou (status ${STATUS[1]}); $OUT está incompleto."
case "${STATUS[0]}" in
  0) ;;
  1) say "Aviso: arquivos mudaram durante a leitura (esperado com sessões abertas)." ;;
  *) die "tar falhou (status ${STATUS[0]}); $OUT está incompleto." ;;
esac

# O checksum guarda o nome curto, senão `sha256sum -c` só funciona a partir do
# diretório em que o backup foi gerado.
BASE="$(basename "$OUT")"
(cd "$DEST_DIR" && sha256sum "$BASE" >"$BASE.sha256")

say "OK: $OUT ($(du -h "$OUT" | cut -f1))"
say "Checksum: $OUT.sha256"
say "Copiar para fora da máquina antes de formatar, por exemplo:"
say "  rsync -P $OUT $OUT.sha256 <host>:~/"
