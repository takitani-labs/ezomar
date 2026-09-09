#!/usr/bin/env bash
set -euo pipefail

# Substitui o Panel.qml do plugin de agentes do Omarchy pela nossa versão.
#
# O plugin de fábrica mostra uma aba por conta: com nove assinaturas isso vira
# um carrossel onde a pergunta real ("qual eu uso agora?") não tem resposta sem
# abrir uma por uma. A nossa versão empilha todas numa tabela ordenada.
#
# A ordenação é a razão de existir do patch. Ela separa duas janelas que os
# provedores expõem juntas: a de 5 horas é um FREIO, volta sozinha várias vezes
# por dia e nada se perde quando vira; a semanal é o ORÇAMENTO, vira uma vez, na
# data, e o que não foi usado até lá não volta. O orçamento manda na ordem, o
# freio decide quem pode entrar na disputa agora.
#
# O arquivo vive em ~/.config/omarchy/plugins, que é um clone do plugin e não
# um repositório nosso: sem este passo, a próxima formatação leva o patch junto.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/../templates/agents-panel/Panel.qml"
DEST="$HOME/.config/omarchy/plugins/opik.agents/Panel.qml"

say() { echo "[ezomar][agents-panel] $*"; }

[ -f "$TPL" ] || { say "Template ausente: $TPL" >&2; exit 1; }

if [ ! -d "$(dirname "$DEST")" ]; then
  say "Plugin opik.agents não está instalado; nada a fazer."
  exit 0
fi

if cmp -s "$TPL" "$DEST"; then
  say "Painel já está na nossa versão."
  exit 0
fi

# Guarda o de fábrica uma vez só: numa segunda execução o .orig já seria o nosso.
if [ -f "$DEST" ] && [ ! -f "$DEST.orig" ]; then
  cp "$DEST" "$DEST.orig"
  say "Original guardado em $DEST.orig"
fi

install -m 0644 "$TPL" "$DEST"
say "Painel instalado. Recarregue o shell para ver: omarchy-restart-shell"
