#!/usr/bin/env bash
set -euo pipefail

# Sobe o teto de inodes do /tmp.
#
# O /tmp é um tmpfs e o systemd o monta com `nr_inodes=1m`: um teto FIXO de
# 1.048.576 arquivos, que não acompanha a RAM. Medido nesta máquina em
# 2026-08-29, com 123G de RAM: o /tmp tinha 21G livres de 62G e mesmo assim
# nada mais conseguia criar arquivo, porque os inodes tinham acabado. O
# sintoma não se parece com disco cheio, se parece com o sistema quebrando:
# o mount.cifs do NAS parou de montar e até um `echo` para um arquivo falhava
# com ENOSPC.
#
# A causa é como a máquina é usada: uma única sessão de agente tinha 246.972
# arquivos e 10G ali dentro, entre eles um venv Python inteiro. Frota de
# agentes cria árvore de arquivo em cima de árvore de arquivo, e em tmpfs cada
# um desses 10G também é RAM.
#
# Isto aqui é a rede de segurança, não a correção da causa: o teto sobe, o
# 90-verify passa a reclamar quando o consumo se aproxima dele, e o que
# resolve de verdade é não construir venv nem clonar repo dentro do scratchpad.
#
# O teto não reserva nada: é limite, não alocação. Custa zero até os arquivos
# existirem, e continua protegendo contra um processo em looping criando
# arquivos vazios, que é o motivo de o limite existir.
#
# O Omarchy tem exatamente o mesmo padrão (conferido numa VM 4.0.1), então isto
# vale nas duas máquinas.
#
# Há uma segunda estratégia, mais radical e às vezes mais certa, atrás de
# EZOMAR_TMP_ON_DISK=true: mascarar o tmp.mount e deixar o /tmp no disco.
# Faz sentido porque a raiz do scratchpad do Claude Code NÃO é configurável
# (não há TMPDIR, chave de settings.json nem flag; verificado na documentação
# oficial em 2026-08-29), então não dá para mandar os artefatos pesados para
# outro lugar. Com o /tmp em btrfs o inode passa a ser alocado dinamicamente,
# some o teto, e um venv de 10G deixa de ocupar RAM. O preço é a velocidade do
# tmpfs, que num NVMe é pequeno perto de perder 10G de memória.
#
# Botões: EZOMAR_TMP_INODES (padrão 4m), EZOMAR_TMP_ON_DISK (padrão false)

WANT="${EZOMAR_TMP_INODES:-4m}"
ON_DISK="${EZOMAR_TMP_ON_DISK:-false}"
DROPIN_DIR="/etc/systemd/system/tmp.mount.d"
DROPIN="$DROPIN_DIR/99-ezomar-inodes.conf"

say() { echo "[ezomar][tmp-inodes] $*"; }

if [ "$ON_DISK" = "true" ]; then
  # Mascarar é o jeito suportado de dizer "não monte tmpfs aqui": o /tmp passa
  # a ser um diretório comum do sistema de arquivos raiz. Vale no próximo boot,
  # de propósito: remontar por baixo de processos que têm arquivo aberto em
  # /tmp seria trocar um problema por outro.
  if systemctl is-enabled tmp.mount 2>/dev/null | grep -q masked; then
    say "tmp.mount já está mascarado; o /tmp é do disco."
  else
    sudo systemctl mask tmp.mount
    say "tmp.mount mascarado. O /tmp passa a ser do disco no próximo boot."
    say "Para reverter: sudo systemctl unmask tmp.mount"
  fi
  say "Conteúdo atual do /tmp continua em RAM até reiniciar."
  exit 0
fi

if ! systemctl cat tmp.mount >/dev/null 2>&1; then
  say "Esta máquina não usa tmp.mount (o /tmp não é tmpfs do systemd). Pulando."
  exit 0
fi

# A opção vem do unit do fornecedor e é reescrita inteira: num .mount o
# `Options=` substitui, não acrescenta, então perder o resto da linha aqui
# significaria montar o /tmp sem `mode=1777` e quebrar a máquina.
VENDOR="$(systemctl cat tmp.mount 2>/dev/null | grep -m1 '^Options=' | cut -d= -f2-)"
if [ -z "$VENDOR" ]; then
  say "Não achei a linha Options= do tmp.mount; não vou adivinhar." >&2
  exit 1
fi

if printf '%s' "$VENDOR" | grep -q 'nr_inodes='; then
  NEW="$(printf '%s' "$VENDOR" | sed "s/nr_inodes=[^,]*/nr_inodes=$WANT/")"
else
  NEW="$VENDOR,nr_inodes=$WANT"
fi

# `df --output` não existe em todo df; a coluna 2 do -i é o total em qualquer um.
CURRENT_MAX="$(df -i /tmp 2>/dev/null | awk 'NR==2{print $2}' || true)"
say "Teto atual: ${CURRENT_MAX:-?} inodes. Alvo: $WANT."

if [ -f "$DROPIN" ] && grep -qF "nr_inodes=$WANT" "$DROPIN"; then
  say "Drop-in já pede $WANT."
else
  sudo install -d -m 0755 "$DROPIN_DIR"
  printf '# Escrito pelo ezomar: install/apps/84-tmp-inodes.sh\n[Mount]\nOptions=%s\n' "$NEW" \
    | sudo tee "$DROPIN" >/dev/null
  sudo systemctl daemon-reload
  say "Drop-in instalado em $DROPIN."
fi

# Remontar aplica agora, sem reboot e sem perder o conteúdo do /tmp. O tmpfs
# aceita aumentar nr_inodes em remount; diminuir abaixo do que já está em uso é
# que seria recusado.
if sudo mount -o "remount,nr_inodes=$WANT" /tmp 2>/dev/null; then
  say "Remontado agora: $(df -i /tmp | awk 'NR==2{print $2}') inodes."
else
  say "Não consegui remontar; vale no próximo boot." >&2
fi

USED_PCT="$(df -i /tmp 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || true)"
say "Uso atual: ${USED_PCT:-?}% dos inodes."
