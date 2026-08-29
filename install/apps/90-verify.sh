#!/usr/bin/env bash
set -euo pipefail

# Verify the result instead of trusting that the modules above printed "ok".
#
# The failure this guards against is the one that actually happened while this
# machine was set up by hand: every step reported success, and the breakage only
# surfaced later, one command at a time, because nothing checked the end state.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/config.sh
. "$SCRIPT_DIR/../lib/config.sh"

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin:$PATH"

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
skip() { printf '  \033[33m-\033[0m %s\n' "$1"; }

echo "[ezomar][verify] Ferramentas"
for t in zsh node atuin bw chezmoi claude git mosh jq uv; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || bad "$t ausente"
done

echo "[ezomar][verify] Shell"
[ "$(getent passwd "$USER" | cut -d: -f7)" = "$(command -v zsh)" ] \
  && ok "shell de login é zsh" || bad "shell de login não é zsh"
[ -s "$HOME/.config/antigen/antigen.zsh" ] \
  && ok "antigen presente" || bad "antigen ausente (.zshrc vai falhar no source)"

echo "[ezomar][verify] Dotfiles"
[ -s "$HOME/.config/age/keys.txt" ] && ok "chave age" || bad "chave age ausente"
# Decryption is the real test: an encrypted file that still looks encrypted
# means the identity is wrong, which chezmoi reports as success.
if grep -q "^Host " "$HOME/.ssh/config" 2>/dev/null; then
  ok "arquivos encriptados decriptaram (.ssh/config legível)"
else
  bad ".ssh/config ausente ou não decriptado"
fi
for f in writing-style.md english-coaching.md context-hygiene.md; do
  [ -f "$HOME/.claude/$f" ] && ok "$f" || bad "$f ausente (CLAUDE.md faz @-include dele)"
done

echo "[ezomar][verify] Claude"
N=$(ls -1 "$HOME/.claude/skills" 2>/dev/null | wc -l)
[ "$N" -gt 0 ] && ok "$N skills" || bad "nenhuma skill"
P=$(ls -1 "$HOME/.claude-profiles" 2>/dev/null | wc -l)
[ "$P" -gt 0 ] && ok "$P perfis" || bad "nenhum perfil"
[ -L "$HOME/.claude-profiles/team/skills" ] \
  && ok "symlinks de perfil intactos" || bad "symlinks de perfil quebrados"
# Every profile must share one projects/ dir, or a session cannot be resumed
# from another profile. The symlink comes from the dotfiles; check it landed.
BROKEN=0
for d in "$HOME"/.claude-profiles/*/; do
  [ -d "$d" ] || continue
  [ -L "$d/projects" ] || BROKEN=$((BROKEN + 1))
done
[ "$BROKEN" -eq 0 ] && ok "projects/ compartilhado em todos os perfis" \
  || bad "$BROKEN perfil(is) sem symlink projects/ -> ~/.claude/projects (dotfiles)"

echo "[ezomar][verify] Agentes"
for t in herdr codex gemini grok ai-usagebar pw-keepalive cli-proxy-api pidbox; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || bad "$t ausente"
done
[ -x "$HOME/.local/bin/herdr-switch-agent-profile" ] \
  && ok "seletor de profile Codex/Claude do herdr" \
  || bad "herdr-switch-agent-profile ausente"
grep -q '^# >>> herdr agent profile switch (ezdora/ezomar) >>>$' \
  "$HOME/.config/herdr/config.toml" 2>/dev/null \
  && ok "atalho Ctrl+B, A do herdr" || bad "keybinding de troca de profile ausente"
if systemctl --user cat herdr.service >/dev/null 2>&1; then
  systemctl --user is-enabled herdr.service >/dev/null 2>&1 \
    && ok "herdr.service habilitado" || bad "herdr.service existe mas não está habilitado"
else
  bad "herdr.service ausente (vem do repo de dotfiles)"
fi
if [ -n "${EZOMAR_TOOLS_REPO:-}" ]; then
  DIR="$(ezomar_tools_dir)"
  [ -d "$DIR/.git" ] && ok "repo de ferramentas em $DIR" || bad "repo de ferramentas não clonado em $DIR"
  [ -L "$HOME/.local/bin/mrig" ] && ok "mrig" || bad "mrig não linkado"
  systemctl --user is-enabled claude-auth-preflight.service >/dev/null 2>&1 \
    && ok "claude-auth-preflight.service habilitado" || bad "claude-auth-preflight.service não habilitado"
else
  skip "EZOMAR_TOOLS_REPO não definido: mrig e preflight não conferidos"
fi

echo "[ezomar][verify] Resiliência"
# O teto de inodes do /tmp é o limite que ninguém olha até ele parar a máquina:
# num tmpfs cheio de arquivo pequeno o espaço sobra e o inode acaba, e aí nada
# consegue criar arquivo, nem o mount.cifs de um NAS. Medido aqui em 2026-08-29.
if IT="$(df -i /tmp 2>/dev/null | awk 'NR==2{print $2}')" && [ -n "$IT" ]; then
  IP="$(df -i /tmp 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  if [ "$IT" -gt 1048576 ]; then
    ok "teto de inodes do /tmp: $IT (uso ${IP}%)"
  elif [ "${IP:-0}" -ge 60 ]; then
    bad "/tmp em ${IP}% dos inodes, com teto padrão de $IT (rode install/apps/84-tmp-inodes.sh)"
  else
    ok "inodes do /tmp em ${IP}% (teto padrão $IT)"
  fi
fi
[ "$(cat /proc/sys/kernel/sysrq)" = "1" ] && ok "kernel.sysrq=1" || bad "kernel.sysrq=$(cat /proc/sys/kernel/sysrq) (Alt+SysRq+F indisponível)"
[ -f "$HOME/.config/systemd/user/session.slice.d/ezomar-oom-guard.conf" ] \
  && ok "session.slice MemoryMin" || bad "drop-in do session.slice ausente"
if systemctl --user cat herdr.service >/dev/null 2>&1; then
  [ -f "$HOME/.config/systemd/user/herdr.service.d/ezomar-oom-guard.conf" ] \
    && ok "herdr.service MemoryMax" || bad "drop-in de memória do herdr ausente"
fi
if [ -e /dev/watchdog ]; then
  RT="$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null || echo 0)"
  [ -n "$RT" ] && [ "$RT" != "0" ] && ok "watchdog de hardware armado ($RT)" || bad "watchdog de hardware desarmado"
else
  skip "sem /dev/watchdog nesta máquina"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "[ezomar][verify] Tudo certo."
else
  echo "[ezomar][verify] Há pendências acima."
fi

echo
echo "[ezomar] Falta fazer à mão (exigem browser):"
echo "  claude            login do Claude Code (um por perfil; claude-login.sh guia)"
echo "  ops               1Password"
echo "  bws personal      Bitwarden"
echo "  codex login       uma vez por CODEX_HOME; gemini e grok login no primeiro uso"
echo "  chezmoi apply     depois do 1Password, para rodar os run_once_after_*"

exit "$FAIL"
