#!/usr/bin/env bash
set -euo pipefail

# Keep ai-usagebar only as a collector backend for providers Omarchy does not
# support. Its bar widget was removed because it duplicated Omarchy's native
# agents panel; installing the binary alone lets module 65 fill those gaps in
# the one panel without adding another widget or shell plugin.

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

say() { echo "[ezomar][ai-usagebar] $*"; }

install_bin() {
  local helper

  if command -v omarchy >/dev/null 2>&1 \
    && omarchy pkg aur add ai-usagebar-bin; then
    return 0
  fi
  for helper in yay paru; do
    if command -v "$helper" >/dev/null 2>&1 \
      && "$helper" -S --needed --noconfirm ai-usagebar-bin; then
      return 0
    fi
  done
  if command -v cargo >/dev/null 2>&1 && cargo install ai-usagebar; then
    return 0
  fi
  return 1
}

# Liga o SuperGrok, que nasce desligado.
#
# Por que isto vive aqui e não no config.toml versionado: aquele arquivo guarda
# chaves de API e este repositório é público, então ele não pode ser versionado.
# Este bloco, em compensação, não tem segredo nenhum, e sem ele uma máquina
# recém-formatada volta com o Grok faltando em silêncio.
#
# O vendor certo é "supergrok", não "grok". O "grok" usa XAI_API_KEY e reporta
# crédito de API avulso; a assinatura só aparece pelo "supergrok", que lê o
# faturamento pelo CLI oficial via ACP (x.ai/billing). Confundir os dois é o que
# fazia parecer que o Grok não reportava uso nenhum.
#
# O caminho do binário é absoluto de propósito: o grok vive num diretório do
# mise e só está no PATH do shell interativo, enquanto o coletor roda por timer
# do systemd, que não herda nada disso. O "latest" é symlink mantido pelo mise,
# então isto sobrevive a upgrade de versão.
enable_supergrok() {
  local config="$HOME/.config/ai-usagebar/config.toml"
  local bin=""
  local candidate

  [ -f "$config" ] || { say "Sem config.toml do ai-usagebar; pulando SuperGrok."; return 0; }
  if grep -q '^\[supergrok\]' "$config"; then
    say "SuperGrok já configurado."
    return 0
  fi

  for candidate in \
    "$HOME/.local/share/mise/installs/npm-xai-official-grok/latest/node_modules/.bin/grok" \
    "$(command -v grok 2>/dev/null || true)"
  do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { bin="$candidate"; break; }
  done

  if [ -z "$bin" ]; then
    say "CLI do grok não encontrado; SuperGrok fica de fora (rode 'grok login' e reexecute)."
    return 0
  fi

  {
    printf '\n[supergrok]\nenabled = true\ngrok_binary = "%s"\n' "$bin"
  } >> "$config"
  chmod 600 "$config"
  say "SuperGrok ligado apontando para $bin."
}

if command -v ai-usagebar >/dev/null 2>&1; then
  say "Já instalado: $(ai-usagebar --version 2>/dev/null | head -1)"
else
  say "Instalando o backend de coleta (AUR ai-usagebar-bin, ou cargo)..."
  if ! install_bin; then
    say "Não consegui instalar. Opções manuais:" >&2
    echo "  omarchy pkg aur add ai-usagebar-bin   |   yay -S ai-usagebar-bin   |   cargo install ai-usagebar" >&2
    exit 1
  fi
  say "Backend instalado; o painel nativo será atualizado pelo módulo 65."
fi

# Depois da instalação, e em toda execução: o binário estar em disco e o vendor
# estar ligado são fatos separados.
enable_supergrok
