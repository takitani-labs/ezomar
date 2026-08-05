#!/usr/bin/env bash
set -euo pipefail

# Verify the result instead of trusting that the modules above printed "ok".
#
# The failure this guards against is the one that actually happened while this
# machine was set up by hand: every step reported success, and the breakage only
# surfaced later, one command at a time, because nothing checked the end state.

export PATH="$HOME/.local/bin:$PATH"

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }

echo "[ezomar][verify] Ferramentas"
for t in zsh node atuin bw chezmoi claude git; do
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

echo
if [ "$FAIL" -eq 0 ]; then
  echo "[ezomar][verify] Tudo certo."
else
  echo "[ezomar][verify] Há pendências acima."
fi

echo
echo "[ezomar] Falta fazer à mão (exigem browser):"
echo "  claude            login do Claude Code"
echo "  ops               1Password"
echo "  bws personal      Bitwarden"
echo "  chezmoi apply     depois do 1Password, para rodar os run_once_after_*"

exit "$FAIL"
