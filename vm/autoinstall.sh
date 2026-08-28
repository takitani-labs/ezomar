#!/usr/bin/env bash
set -euo pipefail

# Gera o drive de autoinstall do Omarchy, para a VM instalar sozinha.
#
# O instalador procura no boot um drive rotulado `cidata` (o rótulo do NoCloud
# do cloud-init) e, se achar os arquivos que o assistente gráfico produziria,
# pula o assistente inteiro e instala sem uma tecla sequer. Isso é o que torna o
# ensaio repetível: resetar e reinstalar vira um comando, em vez de vinte
# minutos de setas e Enter.
#
# Verificado dentro do próprio ISO 4.0.1, não em documentação:
#   /usr/local/bin/omarchy-cidata-load   procura o rótulo e copia para /root
#   /root/configurator                   é quem escreve esses arquivos no modo
#                                        interativo, e é de onde veio o formato
#
# O par obrigatório é user_configuration.json + user_credentials.json. O
# authorized_keys é opcional para o instalador e essencial aqui: com ele o
# próprio instalador habilita o sshd, libera a porta 22 no ufw e instala a
# chave, então a VM já nasce alcançável pelo vm-test.sh. Sem ele, o Omarchy
# instala com sshd desabilitado e ufw negando tudo.
#
#   bash vm/autoinstall.sh                    # perguntas mínimas, resto padrão
#   EZOMAR_VM_PASSWORD=secreta bash vm/autoinstall.sh
#
# Botões: EZOMAR_VM_USER (opik), EZOMAR_VM_HOSTNAME (omarchy-vm),
#         EZOMAR_VM_TZ (America/Sao_Paulo), EZOMAR_VM_KB (us),
#         EZOMAR_VM_DISK_DEV (/dev/sda), EZOMAR_VM_ENCRYPT (false),
#         EZOMAR_VM_SSH_KEY (~/.ssh/id_ed25519.pub), EZOMAR_VM_FULLNAME,
#         EZOMAR_VM_EMAIL

VM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMG="$VM_DIR/cidata.img"

say() { echo "[ezomar][autoinstall] $*"; }
die() { echo "[ezomar][autoinstall] $*" >&2; exit 1; }

for t in mkfs.vfat mcopy openssl jq; do
  command -v "$t" >/dev/null 2>&1 || die "$t não encontrado (mtools, dosfstools, openssl, jq)."
done

USER_NAME="${EZOMAR_VM_USER:-opik}"
HOSTNAME_="${EZOMAR_VM_HOSTNAME:-omarchy-vm}"
TZ_="${EZOMAR_VM_TZ:-America/Sao_Paulo}"
KB="${EZOMAR_VM_KB:-us}"
DISK_DEV="${EZOMAR_VM_DISK_DEV:-/dev/sda}"
ENCRYPT="${EZOMAR_VM_ENCRYPT:-false}"
FULLNAME="${EZOMAR_VM_FULLNAME:-}"
EMAIL="${EZOMAR_VM_EMAIL:-}"
KEY="${EZOMAR_VM_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"

# O nome de usuário não é cosmético: os dotfiles, os perfis do Claude e os
# caminhos deste repo assumem o home da máquina real. Um usuário diferente
# invalida metade do ensaio.
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "usuário inválido: $USER_NAME"
[ -f "$KEY" ] || die "chave pública não encontrada: $KEY (defina EZOMAR_VM_SSH_KEY)"

PASSWORD="${EZOMAR_VM_PASSWORD:-}"
if [ -z "$PASSWORD" ]; then
  [ -t 0 ] || die "sem terminal para perguntar a senha. Use EZOMAR_VM_PASSWORD."
  read -r -s -p "[ezomar][autoinstall] Senha do usuário $USER_NAME (também vira a de root): " PASSWORD; echo
  [ -n "$PASSWORD" ] || die "senha vazia."
fi

# Tamanho real do disco. O layout é calculado em bytes e precisa bater com o
# device de verdade, senão a última partição não fecha.
DISK_BYTES=""
NAME="${EZOMAR_VM_NAME:-ezomar-vm}"
if docker inspect -f '{{.State.Running}}' "$NAME" >/dev/null 2>&1; then
  DISK_BYTES="$(docker exec "$NAME" stat -c%s /storage/data.img 2>/dev/null || true)"
fi
if [ -z "$DISK_BYTES" ]; then
  SIZE_NUM="${EZOMAR_VM_DISK:-64G}"; SIZE_NUM="${SIZE_NUM%[Gg]}"
  [[ "$SIZE_NUM" =~ ^[0-9]+$ ]] || die "EZOMAR_VM_DISK inesperado: ${EZOMAR_VM_DISK:-} (use algo como 64G)."
  DISK_BYTES=$(( SIZE_NUM * 1024 * 1024 * 1024 ))
  say "Container não está de pé; assumindo disco de ${SIZE_NUM}G."
fi

# Mesma aritmética do configurator (linhas 1094-1106): ESP de 2 GiB começando em
# 1 MiB, o resto em btrfs, 1 MiB reservado no fim para o GPT de backup.
MIB=1048576
DISK_MIB=$(( DISK_BYTES / MIB * MIB ))
BOOT_START=$MIB
BOOT_SIZE=$(( 2 * 1024 * MIB ))
MAIN_START=$(( BOOT_SIZE + BOOT_START ))
MAIN_SIZE=$(( DISK_MIB - MAIN_START - MIB ))
[ "$MAIN_SIZE" -gt 0 ] || die "disco pequeno demais: $DISK_BYTES bytes."

HASH="$(openssl passwd -6 "$PASSWORD")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '%s\n' "$FULLNAME"  > "$WORK/user_full_name.txt"
printf '%s\n' "$EMAIL"     > "$WORK/user_email_address.txt"
printf '%s\n' "$ENCRYPT"   > "$WORK/user_encrypt_installation.txt"
cp "$KEY" "$WORK/authorized_keys"

# Sem encriptação, a senha em claro não vai para lugar nenhum: só o hash. Com
# encriptação o instalador precisa dela para a LUKS, e aí não tem escapatória.
ENC_LINE=""
[ "$ENCRYPT" = "true" ] && ENC_LINE="    \"encryption_password\": $(printf '%s' "$PASSWORD" | jq -Rsa .),"

cat > "$WORK/user_credentials.json" <<JSON
{
$ENC_LINE
    "root_enc_password": $(printf '%s' "$HASH" | jq -Rsa .),
    "users": [
        {
            "enc_password": $(printf '%s' "$HASH" | jq -Rsa .),
            "groups": [],
            "sudo": true,
            "username": $(printf '%s' "$USER_NAME" | jq -Rsa .)
        }
    ]
}
JSON

cat > "$WORK/user_configuration.json" <<JSON
{
    "app_config": null,
    "archinstall-language": "English",
    "auth_config": {},
    "audio_config": { "audio": "pipewire" },
    "bootloader_config": { "bootloader": "Limine", "uki": false, "removable": false },
    "custom_commands": [],
    "omarchy_install": {
        "mode": "full_disk",
        "defer_provisioning": false,
        "target_mount": "/mnt",
        "boot": {
            "esp_mount": "/boot",
            "esp_path": "/EFI/limine",
            "efi_binary": "limine_x64.efi",
            "enable_fallback": true
        },
        "storage": { "kernel": "linux" }
    },
    "disk_config": {
        "config_type": "default_layout",
        "device_modifications": [
            {
                "device": "$DISK_DEV",
                "partitions": [
                    {
                        "btrfs": [],
                        "dev_path": null,
                        "flags": [ "boot", "esp" ],
                        "fs_type": "fat32",
                        "mount_options": [],
                        "mountpoint": "/boot",
                        "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $BOOT_SIZE },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $BOOT_START },
                        "status": "create",
                        "type": "primary"
                    },
                    {
                        "btrfs": [
                            { "mountpoint": "/", "name": "@" },
                            { "mountpoint": "/home", "name": "@home" },
                            { "mountpoint": "/var/log", "name": "@log" },
                            { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" }
                        ],
                        "dev_path": null,
                        "flags": [],
                        "fs_type": "btrfs",
                        "mount_options": [ "compress=zstd" ],
                        "mountpoint": null,
                        "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $MAIN_SIZE },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $MAIN_START },
                        "status": "create",
                        "type": "primary"
                    }
                ],
                "wipe": true
            }
        ]
    },
    "hostname": "$HOSTNAME_",
    "kernels": [ "linux" ],
    "network_config": { "type": "iso" },
    "ntp": true,
    "parallel_downloads": 8,
    "script": null,
    "services": [],
    "swap": true,
    "timezone": "$TZ_",
    "locale_config": {
        "kb_layout": "$KB",
        "sys_enc": "UTF-8",
        "sys_lang": "en_US.UTF-8"
    },
    "mirror_config": {
        "custom_repositories": [],
        "custom_servers": [
            {"url": "https://mirror.omarchy.org/\$repo/os/\$arch"},
            {"url": "https://mirror.rackspace.com/archlinux/\$repo/os/\$arch"},
            {"url": "https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"}
        ],
        "mirror_regions": {},
        "optional_repositories": []
    },
    "packages": [ "base-devel", "git", "omarchy-keyring", "omarchy-settings", "omarchy" ],
    "profile_config": { "gfx_driver": null, "greeter": null, "profile": {} },
    "version": "3.0.9"
}
JSON

# JSON quebrado só apareceria vinte minutos depois, no meio da instalação.
for f in user_configuration.json user_credentials.json; do
  jq -e . "$WORK/$f" >/dev/null || die "JSON inválido gerado em $f (isto é um bug deste script)."
done

# FAT16 com rótulo CIDATA. mkfs.vfat e mcopy operam sobre um arquivo comum, sem
# montar nada, então nada aqui precisa de root.
# 16 MiB porque FAT16 tem piso: mkfs.vfat recusa -F 16 num arquivo de 4 MiB.
rm -f "$IMG"
truncate -s 16M "$IMG"
mkfs.vfat -F 16 -n CIDATA "$IMG" >/dev/null
mcopy -i "$IMG" "$WORK"/user_configuration.json "$WORK"/user_credentials.json \
                "$WORK"/user_full_name.txt "$WORK"/user_email_address.txt \
                "$WORK"/user_encrypt_installation.txt "$WORK"/authorized_keys ::
chmod 0600 "$IMG"

say "Gerado: $IMG"
say "  usuário $USER_NAME  hostname $HOSTNAME_  fuso $TZ_  teclado $KB"
say "  disco $DISK_DEV ($((DISK_BYTES / 1024 / 1024 / 1024))G), encriptação $ENCRYPT"
say "  chave  $KEY"
mdir -i "$IMG" :: | sed 's/^/    /'
say ""
say "O arquivo carrega hash de senha e sua chave pública: está no .gitignore."
say "Para instalar do zero, sem tocar em nada:"
say "  bash vm/reset.sh --up"
