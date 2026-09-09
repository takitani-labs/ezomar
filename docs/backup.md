# Backup do home

Dois repositórios borg, o mesmo conteúdo nos dois:

| Destino | Caminho | Para quê |
|---|---|---|
| Hetzner storage box | `ssh://u548875@u548875.your-storagebox.de:23/./backups/takidesk-home` | offsite |
| NAS ZEUS | `/mnt/zeus-backup/backups/borg/takidesk-home` | restauração rápida |

O Hetzner roda **borg do lado servidor** (a box lista `borg` entre os backends
suportados no `help` do shell dela), então só os chunks novos atravessam a rede.

Rodam por `ezomar-borgmatic.timer`, todo dia às 3h com uma hora de folga
aleatória, `Persistent=true` para o dia em que a máquina passou a noite
desligada.

## A senha

A passphrase está no 1Password, vault Private, item **Borg takidesk-home**. O
`encryption_passcommand` do borgmatic chama `~/.local/bin/borg-passphrase`, que
lê o item em tempo de execução usando a sessão em `~/.op_session`.

O export da chave repokey está no item **Borg takidesk-home key export**, para o
caso de o blob dentro do repositório corromper. Ele sozinho não abre nada: só
serve junto com a passphrase.

Perder a passphrase é perder os dois backups. O borg não tem recuperação.

## O mount do ZEUS precisa de root, uma vez

O mount gvfs de `~/mnt/zeus` não serve para repositório borg: é FUSE sobre SMB,
lento para muitos arquivos pequenos, e o lock do borg em filesystem de rede via
FUSE não é confiável. O repositório fica sobre um mount cifs de kernel.

```bash
secret-tool lookup server 192.168.1.3 protocol smb user admin service zeus-mount \
  | sudo bash install/templates/borg-backup/setup-zeus-cifs.sh
```

A senha vai por stdin de propósito: não passa por argumento (que aparece na
lista de processos) nem por arquivo escrito antes. O script grava
`/etc/samba/credentials/zeus` com 0600 e põe a linha no `/etc/fstab` com
`nofail` e `x-systemd.automount`, para o NAS desligado não segurar o boot.

Depois, uma vez, criar o repositório:

```bash
BORG_PASSPHRASE="$(borg-passphrase)" \
  borg init --encryption=repokey-blake2 /mnt/zeus-backup/backups/borg/takidesk-home
```

## O que fica de fora

Medido em 2026-09-09, depois da limpeza dos worktrees do mantis (265 para 5, que
sozinha tirou 241 GB do home): **90,1 GB e 840.881 arquivos entram**, 137 GB ficam
de fora.

Ficam de fora os `.venv`, `node_modules`, `__pycache__`, os caches de linguagem
(`.rustup`, `.cargo/registry`, `.nuget/packages`, `.npm`, `go/pkg`), o `~/.cache`
e a lixeira. Os `target/` do cargo saem por `exclude_caches`, porque o próprio
cargo escreve `CACHEDIR.TAG` lá dentro: são 55 GB, a maior linha da lista.

Saída de build do .NET sai por `**/bin/Debug`, `**/bin/Release`, `**/obj/Debug` e
`**/obj/Release`. É o segmento `Debug`/`Release` que torna isso seguro: exclui
sem tocar num `bin/` qualquer que guarde script de verdade.

`~/.local/share/mise` e `~/.local/share/NuGet` saem porque são runtime e pacote
baixado (7,4 GB). O `~/.local/share/opencode` FICA: os 9,8 GB de `opencode.db`
são o histórico das sessões, o equivalente ao que `.claude-profiles` guarda.

`work/repos/references` sai inteiro. São clones de repositório dos outros, e na
medição 38 dos 42 estavam idênticos ao remoto: o que se perde é um `git clone`,
e o que se ganha são 20 GB e 206 mil arquivos em toda execução. **O que essa
exclusão não cobre é alteração local.** Na hora de excluir, quatro tinham
trabalho só ali (`react-doctor`, `ServiceStack` e `tweakcc` sujos, `omarchy` com
um commit não enviado). Trabalho local em `references` só sobrevive se for
commitado e enviado.

`~/mnt` fica de fora porque é onde moram os mounts: sem essa linha o backup
tentaria engolir os 27 TB do NAS e o espelho do kage, passando por si mesmo no
caminho. `one_file_system: true` é a segunda barreira para a mesma coisa.

`dist`, `build` e os `bin/` genéricos **não** estão excluídos, de propósito: esses
nomes, sozinhos, aparecem em repositório onde guardam conteúdo real, e o dia da
restauração é o pior lugar para descobrir a exclusão errada. Só a saída do .NET
sai, e sai pelo caminho `Debug`/`Release`, não pelo nome da pasta.

Para não gravar um diretório específico, largue um arquivo `.nobackup` dentro
dele.

## Uso

```bash
systemctl --user start ezomar-borgmatic.service   # roda agora
journalctl --user -u ezomar-borgmatic -f          # acompanha
borgmatic list                                    # arquivos existentes
borgmatic info                                    # tamanho, dedup
borgmatic --repository zeus create                # só um dos destinos
```

Restaurar um arquivo:

```bash
borgmatic list --archive latest --find 'nome-do-arquivo'
borgmatic extract --archive latest --path home/opik/caminho/do/arquivo
```

Retenção: 7 diários, 4 semanais, 6 mensais. Verificação do repositório de duas
em duas semanas, dos arquivos de quatro em quatro.
