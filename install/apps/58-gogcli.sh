#!/usr/bin/env bash
set -euo pipefail

# gog — Google Workspace pelo terminal (openclaw/gogcli).
#
# Existe para os agentes alcançarem Gmail, Calendar e Drive de QUALQUER perfil e
# qualquer terminal. Os conectores oficiais do claude.ai também fazem isso, mas a
# autorização deles mora na conta claude.ai em que o perfil está logado: com onze
# perfis, cada um logado numa conta diferente, a autorização não viaja junto e é
# preciso repetir o OAuth em cada um. O gog usa credencial própria, no disco, e
# por isso vale em tudo de uma vez — inclusive fora do Claude.
#
# Também resolve o caso de duas contas Google, que o conector não faz dentro de
# uma sessão: o gog guarda contas nomeadas e escolhe por flag.
#
# A saída é JSON e TSV, que é o que torna isto utilizável por agente. Uma CLI de
# e-mail que só desenha tabela bonita no terminal não serve para ser parseada.
#
# Avaliado em 25/09/2026 contra os critérios da casa para dependência de terceiro:
#   8.447 stars · último push no mesmo dia · 30 contribuidores · 2 issues abertas
#   MIT · Go · v0.41.0 de 22/09
#
# Instalado pelo tarball do release, e não pelo script do site. `curl | bash` de
# um domínio entrega ao autor do dia a capacidade de rodar qualquer coisa nesta
# máquina, e aqui não há motivo para isso: o binário é publicado em release do
# GitHub, e baixar o release é igualmente simples e verificável.
#
# A AUTENTICAÇÃO NÃO É FEITA AQUI: abre navegador e exige uma pessoa.

REPO="openclaw/gogcli"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/gog"

say() { echo "[ezomar][gog] $*"; }

arch="$(uname -m)"
case "$arch" in
  x86_64) asset_arch="amd64" ;;
  aarch64 | arm64) asset_arch="arm64" ;;
  *) say "Arquitetura $arch não publicada pelo projeto; pulando." >&2; exit 0 ;;
esac

latest="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
  | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1 || true)"
if [ -z "$latest" ]; then
  say "Não consegui consultar o último release; pulando." >&2
  exit 0
fi

current=""
[ -x "$BIN" ] && current="v$("$BIN" --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

if [ "$current" = "$latest" ]; then
  say "Já na versão $latest."
else
  url="https://github.com/$REPO/releases/download/$latest/gogcli_${latest#v}_linux_${asset_arch}.tar.gz"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" EXIT
  if ! curl -fsSL "$url" -o "$tmp/gog.tar.gz"; then
    say "Download falhou: $url" >&2
    exit 1
  fi
  tar -xzf "$tmp/gog.tar.gz" -C "$tmp"
  found="$(find "$tmp" -type f -name gog -perm -u+x | head -1)"
  [ -n "$found" ] || { say "O tarball não trouxe o binário esperado." >&2; exit 1; }
  install -D -m 0755 "$found" "$BIN"
  say "Instalado ${current:+(era $current) }$latest em $BIN."
fi

# Contas autorizadas, que é a diferença entre o binário existir e servir.
if accounts="$("$BIN" auth list 2>/dev/null)" && [ -n "$accounts" ]; then
  say "Contas autorizadas:"
  printf '%s\n' "$accounts" | sed 's/^/    /'
else
  say "Nenhuma conta autorizada ainda. Para ligar a primeira:"
  say "  gog auth login"
  say "Para a segunda conta, o gog guarda contas nomeadas; veja: gog auth --help"
fi
