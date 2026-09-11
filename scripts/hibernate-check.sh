#!/usr/bin/env bash
set -uo pipefail

# Diz se dá para hibernar AGORA, e o que derrubar se não der.
#
#   hibernate-check.sh           relatório
#   hibernate-check.sh --gate    só o veredito (sai 1 se não recomendar)
#   hibernate-check.sh --do      checa e, se passar, hiberna
#
# O `omarchy hibernation available` responde outra pergunta: se a MÁQUINA
# suporta hibernar. Compara o swap em disco com /sys/power/image_size e pronto.
# Isso não muda ao longo do dia. A pergunta que importa numa máquina com muitos
# agentes abertos é a outra: com o que está carregado neste momento, isso vai
# terminar ou vai ficar dez minutos na tela preta?
#
# O que precisa ser salvo na imagem:
#
#   AnonPages   memória anônima dos processos, o grosso
#   Shmem       tmpfs, e aqui /tmp é tmpfs: arquivo grande em /tmp é RAM
#   zram        páginas já trocadas, que moram na RAM comprimidas e também
#               precisam ir para o disco
#
# O zram é o detalhe que surpreende. No Omarchy ele tem o tamanho da RAM inteira
# e prioridade acima do swapfile de propósito: swap do dia a dia é ele, e o
# swapfile em disco fica reservado para a imagem. O efeito colateral é que
# quanto mais a máquina tiver trocado para o zram, mais trabalho a hibernação
# tem, porque para escrever a imagem o kernel precisa de memória livre e a
# memória está justamente ocupada pelo zram.

say() { printf '%s\n' "$*"; }
human() { awk -v b="$1" 'BEGIN{printf "%.1f GB", b/1073741824}'; }

MODE="${1:-report}"
case "$MODE" in
  --gate) MODE=gate ;;
  --do) MODE=do ;;
  report | "") MODE=report ;;
  -h | --help) sed -n '3,8p' "$0" | sed 's/^# \?//'; exit 0 ;;
  *) say "uso: $(basename "$0") [--gate|--do]" >&2; exit 2 ;;
esac

# --- o que tem de caber -------------------------------------------------------
anon=$(awk '/^AnonPages:/{print $2*1024}' /proc/meminfo)
shmem=$(awk '/^Shmem:/{print $2*1024}' /proc/meminfo)
# orig_data_size: quanto o zram guarda DESCOMPRIMIDO, que é o que volta para a
# RAM. O tamanho comprimido engana para menos.
zram_orig=0
[ -r /sys/block/zram0/mm_stat ] && zram_orig=$(awk '{print $1}' /sys/block/zram0/mm_stat 2>/dev/null || echo 0)
need=$(( anon + shmem + zram_orig ))

# --- o que existe para receber ------------------------------------------------
# zram fora da conta: é RAM, não recebe imagem de hibernação. O próprio
# omarchy-hibernation-available exclui do mesmo jeito.
disk_swap=$(awk '!/Filename|zram/ {sum += $3} END {print (sum+0)*1024}' /proc/swaps)
image_target=$(cat /sys/power/image_size 2>/dev/null || echo 0)
mem_free=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo)

# --- veredito -----------------------------------------------------------------
# Duas perguntas diferentes, e as duas precisam de sim.
fits=true
[ "$need" -gt "$disk_swap" ] && fits=false

# Acima do alvo do kernel a hibernação não falha, mas ela passa a ter de encolher
# a memória antes de escrever, e é aí que a tela fica preta por muito tempo.
over_target=false
[ "$image_target" -gt 0 ] && [ "$need" -gt "$image_target" ] && over_target=true

# Para drenar o zram de volta o kernel precisa de RAM livre. Sem folga, essa é a
# parte que trava sem mensagem nenhuma.
zram_risk=false
[ "$zram_orig" -gt 0 ] && [ "$zram_orig" -gt "$mem_free" ] && zram_risk=true

verdict=ok
$over_target && verdict=lento
$zram_risk && verdict=risco
$fits || verdict=nao

if [ "$MODE" != gate ]; then
  say "  precisa salvar:  $(human "$need")"
  say "    processos:     $(human "$anon")"
  say "    tmpfs (/tmp):  $(human "$shmem")"
  say "    zram:          $(human "$zram_orig")"
  say "  cabe no swap:    $(human "$disk_swap") em disco"
  say "  alvo do kernel:  $(human "$image_target")"
  say "  RAM livre:       $(human "$mem_free")"
  say ""
  case "$verdict" in
    ok)    say "  OK. Deve hibernar rápido." ;;
    lento) say "  VAI DEMORAR. Passa do alvo do kernel, então ele encolhe a memória"
           say "  antes de escrever, e a tela fica preta nesse tempo sem dar sinal." ;;
    risco) say "  ARRISCADO. O zram guarda mais do que cabe na RAM livre, e drenar"
           say "  ele é justamente a parte que trava sem mensagem." ;;
    nao)   say "  NÃO CABE. A imagem é maior que o swap em disco." ;;
  esac
  if [ "$verdict" != ok ]; then
    say ""
    say "  Maiores consumidores de memória:"
    ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -6 \
      | awk '{printf "    %-24s %.1f GB\n", $2, $1/1048576}'
    say ""
    say "  Fechar agente e navegador é o que mais rende. /tmp também: ele é tmpfs,"
    say "  então arquivo grande ali é RAM que vai para a imagem."
  fi
fi

case "$MODE" in
  report) [ "$verdict" = nao ] && exit 1 || exit 0 ;;
  gate)   [ "$verdict" = ok ] && exit 0 || exit 1 ;;
  do)
    if [ "$verdict" = nao ] || [ "$verdict" = risco ]; then
      command -v notify-send >/dev/null 2>&1 && notify-send -u critical -a "Hibernar" \
        "Não vou hibernar agora" "$(human "$need") para salvar. Rode hibernate-check para ver o que fechar." || true
      say "  Não hibernei. Rode sem --do para ver o detalhe." >&2
      exit 1
    fi
    say "  Hibernando…"
    systemctl hibernate
    ;;
esac
