#!/usr/bin/env bash
set -euo pipefail

# Tira o /tmp da RAM e põe no NVMe.
#
# Medido aqui em 17/09/2026, com a máquina em uso normal:
#
#   /tmp        62 GB de tmpfs, 50 GB ocupados
#   dentro dele 34 GB de scratchpad de agente e ~15 GB de cache de build
#   zram        55,7 GB guardados, ocupando 23,6 GB de RAM depois de comprimir
#   NVMe        7,2 GB/s escrita, 11,0 GB/s leitura (medido com O_DIRECT)
#
# O argumento não é "disco é rápido o bastante", é que o conteúdo do /tmp aqui
# não é temporário de verdade: é subproduto de agente, e boa parte dele são
# CACHES de compilação (go, uv, nuget, dotnet). Cache em /tmp é contradição: o
# /tmp é limpo no boot, então o cache nunca é reaproveitado entre reinícios E
# ainda custa RAM. É o pior dos dois mundos.
#
# Com o /tmp em disco some também o teto de 1 milhão de inodes do tmpfs, que já
# derrubou coisa aqui antes, e a imagem de hibernação encolhe pelo mesmo tanto,
# porque tmpfs entra inteiro nela.
#
# Sobre velocidade: a diferença bruta para a RAM é de uma ordem de grandeza, mas
# arquivo recém-escrito é lido de volta do page cache, não do disco. Com 123 GB
# de memória, quase nada do que um agente escreve em /tmp chega a tocar o NVMe.
#
# Precisa de root e de um reboot. Por isso o módulo não faz sozinho: ele diz o
# que fazer e confirma o estado.

say() { echo "[ezomar][tmp] $*"; }

if ! mountpoint -q /tmp; then
  say "/tmp já está em disco (não é ponto de montagem separado). Nada a fazer."
  exit 0
fi

fstype="$(findmnt -no FSTYPE /tmp 2>/dev/null || echo '?')"
if [ "$fstype" != tmpfs ]; then
  say "/tmp está montado como '$fstype', não tmpfs. Nada a fazer."
  exit 0
fi

used="$(df -h /tmp | awk 'NR==2{print $3" de "$2" ("$5")"}')"
say "/tmp hoje: tmpfs em RAM, $used"

# Não existe `systemctl is-masked`. Quem responde "masked" é o is-enabled, e ele
# sai com status 1 nesse caso, então o comando não pode ficar sob `set -e` cru.
if [ "$(systemctl is-enabled tmp.mount 2>/dev/null || true)" = masked ]; then
  say "tmp.mount já está mascarado; falta só reiniciar para valer."
  exit 0
fi

say "Para mover o /tmp para o disco, rode e reinicie:"
say "  sudo systemctl mask tmp.mount"
say ""
say "Para voltar atrás depois, se quiser: sudo systemctl unmask tmp.mount"
