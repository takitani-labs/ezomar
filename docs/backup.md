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

Medido neste home em 2026-09-09: de 440 GB, uns 130 GB são coisa que o gerenciador
refaz sozinho. `.venv` sozinho tinha 52 GB.

Ficam de fora os `.venv`, `node_modules`, `__pycache__`, os caches de linguagem
(`.rustup`, `.cargo/registry`, `.nuget/packages`, `.npm`, `go/pkg`), o `~/.cache`
e a lixeira. Os `target/` do cargo saem por `exclude_caches`, porque o próprio
cargo escreve `CACHEDIR.TAG` lá dentro.

`~/mnt` fica de fora porque é onde moram os mounts: sem essa linha o backup
tentaria engolir os 27 TB do NAS e o espelho do kage, passando por si mesmo no
caminho. `one_file_system: true` é a segunda barreira para a mesma coisa.

`dist`, `build`, `bin` e `obj` **não** estão excluídos, de propósito: os nomes
são genéricos demais e em vários repositórios aqui guardam conteúdo real. Juntos
dão uns 8 GB, e não vale descobrir a exclusão errada no dia da restauração.

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
