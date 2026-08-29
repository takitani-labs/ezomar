# Ezomar (Ez Omarchy)

Post-install para **Omarchy** (Arch + Hyprland), no mesmo formato do
ezdora (repositório privado do autor): módulos independentes, um por
arquivo, idempotentes.

## Como usar

```bash
# Uma linha
bash <(curl -fsSL https://raw.githubusercontent.com/takitani-labs/ezomar/master/bootstrap.sh)

# Ou clonado
git clone https://github.com/takitani-labs/ezomar.git
cd ezomar && bash install.sh
```

## Por que ele é tão menor que o ezdora

O ezdora tem 99 módulos porque precisa construir o ambiente inteiro em cima de
um Fedora KDE pelado. O Omarchy já é um post-install opinado e entrega `claude`,
`gh`, `op`, `mise`, `git`, `docker` e `python` de fábrica.

Medido numa instalação limpa do Omarchy 3.8.4, faltavam seis coisas. É essa a
lista aqui, e cada item entrou porque **algo quebrou**, não por precaução:

| Item | O que quebrava sem ele |
|---|---|
| `zsh` | shell de login continuava bash, então o `.zshrc` de 591 linhas nunca carregava e `bws`, `ops` e `bw-exec` não existiam |
| `nodejs` | os hooks em `settings.local.json` chamam `node .../hook.mjs` e são protegidos por `[ ! -f ]`, então falhavam em silêncio |
| `atuin` | histórico de shell; o `.zshrc` degradava com aviso |
| `bw` | é de onde vem a chave age, sem ela nada do repo decripta |
| chave age | `.bashrc`, `.zshrc.local`, `.ssh/config` e os quatro perfis do Claude com token de API |
| antigen | `.zshrc` fazia `source` dele e morria com "command not found" |

Os dois últimos foram resolvidos no próprio repo de dotfiles (a chave vem do
cofre, o antigen virou external do chezmoi). Os outros quatro estão aqui.

Remedido numa VM com Omarchy **4.0.1** zerado, porque a base andou: agora ele já
traz `claude`, `herdr`, `codex`, `gemini`, `grok`, `node`, `npm`, `jq`, `rsync` e
`yay` de fábrica. Continuam faltando `zsh`, `mosh`, `atuin` e `bun`, e é por isso
que os módulos 56 e 58 hoje quase sempre só confirmam o que já existe. Eles ficam
porque o repo também roda em Arch puro, onde nada disso vem junto.

Um dos itens saiu da lista por ser **ativamente ruim**. O `nodejs` estava aqui
desde a medição no 3.8.4, quando ele não vinha. No 4.0.1 o Omarchy administra o
node pelo **mise**, e instalar a versão do pacman por cima faz `/usr/bin/node`
sombrear o shim do mise: medido na VM, `node` resolvia para o mise antes do
`00-packages` e para o `/usr/bin` depois. Hoje as duas versões coincidem, e no dia
em que divergirem o sintoma aparece longe da causa. Saíram junto `jq`, `libpulse`
e `libnotify`, que o Omarchy já traz, e `uv`, `espeak-ng` e `zenity` viraram
condicionais: só entram quando `EZOMAR_TOOLS_REPO` está definido, porque existem
apenas para o meeting-rig.

Duas coisas mudaram no 4.0.1 e custaram um módulo cada:

- **A instalação é offline.** Ela consome os pacotes do próprio ISO e nunca baixa
  os bancos dos repositórios, então numa máquina recém-instalada
  `/var/lib/pacman/sync` só tem `offline.db` e qualquer `pacman -S` morre com
  "target not found". O `00-packages.sh` sincroniza antes.
- **`pacman -Syu` direto é bloqueado** por um hook de pré-transação ("Woah
  partner..."), porque os upgrades passam por `omarchy update`, que cuida de
  snapshot, keyring e migrações. Instalar sem `-u` é a convenção da casa: o
  próprio `omarchy pkg add` é um `pacman -S --needed`. Em Arch puro o módulo usa
  `-Syu`, que lá é o certo.

## Módulos

Rodam em ordem de nome, e a numeração importa.

| Módulo | O que faz |
|---|---|
| `00-packages.sh` | o delta de pacotes via pacman |
| `10-bitwarden-cli.sh` | binário oficial do `bw` em `~/.local/bin`, sem root |
| `20-age-key.sh` | restaura a identidade age do Bitwarden |
| `30-chezmoi.sh` | instala o chezmoi e aplica os dotfiles |
| `35-shell.sh` | `chsh` para zsh, depois do chezmoi ter entregue o `.zshrc` |
| `40-claude-plugins.sh` | marketplaces e os 10 plugins do Claude Code |
| `50-personal.sh` | roda seus módulos privados, se houver |
| `56-herdr.sh` | instala o herdr pelo instalador oficial e habilita o unit, se os dotfiles o trouxeram |
| `58-npm-ai-clis.sh` | `codex`, `gemini` e `grok` via npm, em `~/.npm-global` |
| `60-cliproxyapi.sh` | instala a API local para as subscriptions de IA, sua config secreta e unit de usuário |
| `61-ai-usagebar.sh` | instala só o binário ai-usagebar, usado como backend de quotas pelo painel nativo |
| `62-cliproxyapi-exato.sh` | cria a segunda instância do CLIProxyAPI para a conta Codex de trabalho |
| `64-codex-profiles.sh` | separa as contas do Codex CLI por `CODEX_HOME` e compartilha a configuração |
| `65-agent-usage-accounts.sh` | abre uma aba por conta Claude/Codex no painel nativo de agentes do Omarchy |
| `66-claude-profile-restore.sh` | instala o mapa de sessão para o herdr restaurar cada pane no perfil Claude correto |
| `67-herdr-integrations.sh` | instala os hooks oficiais de session id em todos os profiles Claude e no Codex |
| `68-pidbox.sh` | opt-in: guard de namespace de PID contra `kill(-1)` de suítes de teste |
| `69-herdr-profile-switch.sh` | instala `Ctrl+B, A` para trocar a conta do Codex ou Claude sem perder a sessão |
| `70-collie.sh` | instala opcionalmente o plugin Collie, sem publicar o bridge |
| `72-tools-repo.sh` | clona seu repo privado de ferramentas, se `EZOMAR_TOOLS_REPO` estiver definido |
| `74-meeting-rig.sh` | linka o `mrig` desse repo e roda o setup dele (venv + modelo) |
| `76-claude-auth-preflight.sh` | instala o unit que avisa de perfis deslogados antes do herdr subir |
| `78-pw-keepalive.sh` | daemon que mantém as sessões do 1Password e Bitwarden vivas |
| `80-oom-guard.sh` | sysrq e reserva de root; os limites de cgroup são opt-in |
| `82-watchdog.sh` | opt-in: arma o watchdog de hardware em 60s |
| `90-verify.sh` | confere o estado final e lista o que falta |

**A ordem entre 20, 30 e 35 é obrigatória.** Sem a chave age, o chezmoi aplica os
400 arquivos e reporta sucesso, mas tudo que é encriptado fica ilegível. É uma
máquina quebrada que se parece com uma máquina pronta.

O 35 vem depois do 30 pelo mesmo motivo. Trocar o shell de login antes de os
dotfiles existirem deixa um zsh sem nenhum arquivo de inicialização, e o próximo
login cai no assistente `zsh-newuser-install`. Medido numa VM sem cofre. O `chsh`
só vale no login seguinte de qualquer jeito, então adiantá-lo não comprava nada.

### Troca de subscription dentro do Herdr

Com um Codex ou Claude parado no prompt, `Ctrl+B, A` abre os profiles daquele
agente, encerra o processo atual e retoma o mesmo session id na conta escolhida.
O Codex entrega só o rollout atual ao outro `CODEX_HOME`; o Claude reaproveita o
`projects/` compartilhado e grava a escolha em
`~/.claude/session-profile-overrides.tsv`, para os restores seguintes manterem
o novo `CLAUDE_CONFIG_DIR`. Variáveis privadas de providers Claude são aplicadas
sem aparecer no comando ou no scrollback do pane.

O backup do ezomar já inclui `.claude` e `.codex-profiles`, portanto leva tanto
as conversas quanto os overrides intencionais para a máquina formatada.

### Por que a camada de agentes também mora aqui

Os módulos de 56 a 82 seguem o mesmo princípio de só adicionar o que já
quebrou, não o que talvez quebre. O chezmoi restaura os perfis e snippets, mas
deliberadamente não consegue entregar units systemd de usuário, binários e
configs com segredos. Sem esse complemento, as APIs locais não sobem, as contas
do Codex se misturam, panes restaurados perdem o perfil e testes com `kill(-1)`
podem derrubar a sessão; o Collie continua um opt-in sem início automático.

A numeração também é uma dependência: todos rodam **depois de
`30-chezmoi.sh`**, pois operam sobre `~/.claude-profiles`, `~/.config/zsh` e
`~/.local/bin` restaurados por ele. Por isso ficam depois de `50-personal.sh` e
antes de `90-verify.sh`.

## Configuração, e o que fica fora daqui

Nada pessoal está hard-coded neste repo. Dois valores são necessários, e a
ordem em que são precisos é o que define onde eles moram:

| Variável | O que é |
|---|---|
| `EZOMAR_DOTFILES_REPO` | seu repositório chezmoi |
| `EZOMAR_AGE_ITEM` | item no cofre com a identidade age que decripta ele |

Esses dois são precisos **antes** do chezmoi rodar, então não podem vir do repo
privado de dotfiles: é justamente ele que eles destravam. Na primeira execução o
ezomar pergunta e salva em `~/.config/ezomar/config.sh` (0600). Depois disso,
não pergunta mais. Também aceita por ambiente:

```bash
export EZOMAR_DOTFILES_REPO="git@github.com:usuario/dotfiles.git"
export EZOMAR_AGE_ITEM="Nome do item no seu cofre"
```

Um terceiro valor é opcional. Algumas ferramentas são pessoais demais para este
repo e vivas demais para uma cópia vendorizada (uma cópia é uma segunda fonte de
verdade, e envelhece em silêncio). Os módulos 72 a 76 instalam direto de um clone
do seu repo de ferramentas, e pulam se ele não estiver definido:

| Variável | O que é |
|---|---|
| `EZOMAR_TOOLS_REPO` | repo git com `tools/meeting-rig/` e `scripts/claude-auth-preflight.sh` |
| `EZOMAR_TOOLS_DIR` | onde clonar; padrão `~/work/repos/<org>/<repo>`, derivado da URL |

O caminho padrão não é cosmético: o `.zshrc` dos dotfiles e o unit do preflight
apontam para os scripts por esse caminho, então mantê-lo faz tudo funcionar sem
editar nada.

Botões de ajuste, todos com padrão razoável: `EZOMAR_HERDR_CHANNEL` (`preview`),
`EZOMAR_HERDR_MEMORY_HIGH` e `EZOMAR_HERDR_MEMORY_MAX` (dimensionados pela RAM;
128G dá 64G/72G), `EZOMAR_WATCHDOG_SEC` (60), `EZOMAR_SKIP_MRIG_SETUP` (`true`
só linka, sem baixar o modelo).

Todo o resto que for seu é preciso **depois** do chezmoi, então pode viajar
junto com os dotfiles. Ponha em `~/.config/ezomar/apps/*.sh` no seu repo
privado, e o módulo `50-personal.sh` executa em ordem de nome. Antes do chezmoi
rodar o diretório não existe e o módulo não faz nada, o que é o comportamento
correto numa máquina zerada.

## Resiliência: o que entrou, e por que quase tudo é opt-in

A máquina antiga congelou em 2026-07-30 (36 sessões do Claude mais Chrome, zram
100% cheio por 16 horas, load 283, e nem o OOM killer do kernel nem o
systemd-oomd dispararam) e travava por completo a cada poucas semanas, sem panic
e sem log. Três módulos nasceram disso.

Só um pedaço deles roda por padrão, e a divisão é entre **capacidade** e
**seguro**. O `80-oom-guard.sh` sempre instala duas linhas de sysctl,
`kernel.sysrq=1` e `vm.admin_reserve_kbytes`: isso não previne nada, é a
habilidade de agir depois que já deu errado. Sem o sysrq, um espiral de reclaim
só termina no botão de força; com ele, termina em `Alt+SysRq+F`. Não muda o
comportamento da máquina enquanto nada acontece.

O resto espera acontecer, que é a regra da casa: **só entra o que já quebrou
aqui**. Os incidentes foram no Fedora com KDE, com metade do zram que o Omarchy
usa, e podem não se repetir.

```bash
EZOMAR_OOM_CGROUPS=true      bash install/apps/80-oom-guard.sh   # piso do desktop + teto da frota
EZOMAR_INSTALL_WATCHDOG=true bash install/apps/82-watchdog.sh    # reboot automático em travamento
EZOMAR_INSTALL_PIDBOX=true   bash install/apps/68-pidbox.sh      # conter kill(-1) de teste
```

O teto da frota tem um motivo a mais para esperar: os valores 64G/72G foram
medidos num cgroup que vivia em 69,6G **no Fedora**. Chutar isso numa máquina com
outro perfil de memória é pior do que não ter teto. Meça antes, sob carga:

```bash
systemctl --user show herdr.service -p MemoryCurrent --value
```

Ficou de fora de vez: o earlyoom (o Omarchy escolheu o oomd por PSI e o rejeita
nos próprios comentários) e o swapfile em btrfs (o zram do Omarchy já ocupa a RAM
inteira).

## O que ele não faz

**Login de browser.** `claude`, `ops` e `bws` precisam de você. O `90-verify.sh`
lista isso no fim.

**A primeira chave SSH.** O repo de dotfiles é privado e as chaves estão dentro
dele, o que é circular. A primeira tem que vir da máquina primária:

```bash
scp ~/.ssh/id_rsa ~/.ssh/id_rsa.pub <máquina-nova>:.ssh/
```

**Os `run_once_after_*` do chezmoi.** São pulados de propósito com
`--exclude=scripts`: três dependem do 1Password logado e dois chamam
`sudo pacman`, então travam esperando um TTY que não existe numa execução
automatizada. Depois de logar nos cofres, rode `chezmoi apply` uma vez.

**Configuração do Claude.** Skills, perfis, `CLAUDE.md` e hooks vêm do chezmoi.
Só os plugins são reinstalados aqui, porque carregam binário e não fazem sentido
versionados.

**Units systemd de usuário.** `herdr.service` e seus drop-ins, e qualquer outro
unit seu, vêm do repo de dotfiles. O ezomar habilita o que encontra e escreve só
os próprios drop-ins (`*/ezomar-oom-guard.conf`). O mesmo vale para
`~/.config/ai-usagebar/config.toml`, que carrega chaves de API, e para o symlink
`projects/` de cada perfil do Claude: o `90-verify.sh` reclama se faltarem.

**Uma segunda barra de uso.** A máquina primária mostrava o consumo das
subscriptions num plasmoide alimentado por um fork do ai-usagebar. O fork não
tinha nenhum commit próprio, e o widget duplicava o painel nativo
`omarchy.agents`, então nenhum plugin, plasmoide ou módulo de barra é instalado.
O binário ai-usagebar sobrevive apenas como backend: no mesmo timer de 15 minutos
do módulo 65, uma ponte transforma Z.AI, Kimi, Grok, OpenRouter, DeepSeek e
qualquer outro provider configurado em abas nativas. Anthropic e OpenAI são
ignorados nessa ponte porque os coletores do próprio Omarchy já entregam limites
mais autoritativos por conta.

Uma peculiaridade do nativo que confunde: o widget se esconde da barra enquanto
nenhuma conta tiver dados. Além de prompts, sessões e dias ativos,
`providerHasData()` também aceita `limits[]` não vazio ou saldo; por isso uma
subscription que só expõe quota aparece normalmente. Para testar a ponte sem
chaves reais, rode
`ezomar-agent-usage-ai-usagebar --from-file /caminho/payload.json` ou defina
`EZOMAR_AI_USAGEBAR_FROM_FILE` com o mesmo caminho. `XDG_STATE_HOME` pode apontar
para um diretório temporário durante o ensaio.

## Aresta conhecida: `.claude/settings.json`

Esse arquivo é versionado no chezmoi, mas o Claude Code reescreve ele ao
instalar ou habilitar plugin. Os dois disputam o mesmo arquivo, e ele não
converge entre máquinas: cada instalação registra os marketplaces de um jeito.

Por isso o módulo 30 usa `--force`. Sem ele o chezmoi para nesse arquivo
esperando um prompt que uma execução automatizada não responde, e **todo arquivo
gerenciado depois dele é pulado em silêncio**, com a execução ainda reportando
sucesso.

**Não rode `chezmoi apply --force` na mão.** Medido: sobrescrever esse arquivo
com a versão do repo desabilita os plugins que só o alvo tinha habilitados
(`✔ enabled` vira `✘ disabled`), e `claude plugin list` continua dizendo
"installed", então nada parece errado.

O `--force` só é seguro dentro do pipeline, porque o módulo 40 roda logo depois
e reabilita tudo incondicionalmente. Se for aplicar à mão, rode o módulo 40 em
seguida.

A correção de verdade seria no repo de dotfiles: separar a configuração durável
(hooks, statusline) do estado local de plugins, e versionar só a primeira.

## Ensaio numa VM, antes de tocar na máquina real

Testar este repo direto na máquina que ele vai reconstruir é o único jeito
garantido de descobrir tarde demais que um módulo quebra. O `vm/` sobe um
Omarchy de verdade numa VM e roda o repo dentro dela.

O motor é o [qemux/qemu](https://github.com/qemus/qemu): QEMU com KVM dentro de
um container, UEFI, e a tela servida no browser. Não é preciso libvirt nem
cliente de VNC no host.

```bash
bash vm/autoinstall.sh      # gera o drive de instalação desatendida
bash vm/up.sh               # sobe a VM com o ISO mais recente do ~/Downloads
                            # tela em http://localhost:8007
bash vm/prepare-guest.sh    # sudo sem senha e rsync, depois que instalar
./vm-test.sh                # roda os módulos lá dentro, e resume o que passou
```

A instalação é desatendida porque o instalador do Omarchy aceita um drive
rotulado `cidata` (o rótulo do NoCloud do cloud-init) com os mesmos arquivos que
o assistente gráfico produziria, e nesse caso pula o assistente. O
`vm/autoinstall.sh` gera esse drive. Isso é o que faz o ensaio ser repetível:
`bash vm/reset.sh --up` reinstala do zero sem uma tecla.

Vale pôr sua chave pública nele, o que o script faz por padrão: com um
`authorized_keys` no drive, o próprio instalador habilita o sshd, libera a porta
no ufw e instala a chave. Sem isso o Omarchy instala com sshd desligado e ufw
negando tudo, e o ensaio começa digitando comandos na GUI da VM.

| Script | O que faz |
|---|---|
| `vm/up.sh` | sobe a VM, conferindo KVM, ISO e portas antes |
| `vm/autoinstall.sh` | gera o drive `cidata` (usuário, senha, disco, chave) |
| `vm/prepare-guest.sh` | libera sudo sem senha na VM e garante o rsync |
| `vm/console.sh` | print da tela e envio de teclas pelo monitor do QEMU |
| `vm/reset.sh` | apaga disco e NVRAM de dentro do container, sem sudo no host |

O `vm/up.sh` liga a aceleração de GPU quando o host tem `/dev/dri`, mas há uma
ressalva medida nesta máquina: o `qemux/qemu` **desabilita a aceleração quando o
host tem CPU AMD** (`isAmdCpu` no `/run/display.sh` dele), então num Ryzen a
variável não tem efeito e o guest renderiza por software. O sintoma não é só
lentidão: o Hyprland por llvmpipe deixa regiões sem repintar e, pelo VNC, isso
vira retângulos pretos. A saída é no guest, e vale só para a VM:

```lua
-- em ~/.config/hypr/looknfeel.lua, dentro da VM
hl.config({ debug = { damage_tracking = 0 } })
```

Isso redesenha o quadro inteiro sempre. Custa CPU e não faz sentido numa máquina
com GPU de verdade, que é o caso da máquina real.

O `vm-test.sh` leva a árvore de trabalho por rsync, não um clone do GitHub, então
o que é testado é o que está no disco agora, mudanças não commitadas incluídas.

Nem todo módulo roda numa VM zerada, e o script não finge que sim: 19 rodam,
4 dependem do cofre ou do repo privado de dotfiles (`20-age-key`, `30-chezmoi`,
`62-cliproxyapi-exato` e `90-verify`) e ficam de fora do conjunto padrão.
`./vm-test.sh --list` diz o porquê de cada um; `--vault` roda só esses, depois de
você logar no cofre dentro da VM.

## Antes de formatar a máquina velha

O `install.sh` responde se a máquina nova ficou pronta. O `preformat.sh` responde
a pergunta anterior, na máquina que vai ser apagada, e tem duas metades.

A primeira é o que **bloqueia**: o source do chezmoi está completo (skills,
perfis, units, configs com chave), os repos deste plano estão commitados e no
remoto, **todos** os repos sob `~/work/repos` e `~/Devel` estão limpos e
enviados, e existe um backup do estado de IA mais novo que o que ele carrega. A
varredura de repos é o coração: medida nesta máquina, 680 repos em 3 a 4
segundos, e ela achou 57 com alteração não commitada, 42 com commit que não está
em remote nenhum e 4 sem remote nenhum. Sem essa seção, formatar perderia
exatamente esses.

A segunda metade é **medição**, e nunca deixa o veredito vermelho: diretórios de
projeto sem git nenhum dentro, o que foi feito à mão em `~/.local/bin`, volumes
do Docker (é onde moram os bancos) e os maiores diretórios do `$HOME`.

```bash
bash preformat.sh          # relatório, só leitura
bash preformat.sh --fix    # chezmoi add/re-add, commit e push do source, e reconfere
```

O `--fix` só mexe no chezmoi. Ele não commita o seu trabalho, não faz push dele e
não roda o backup: essas decisões são suas.

## O que o chezmoi não carrega, e o `backup/` carrega

Os dotfiles guardam a configuração durável. Duas coisas ficam de fora de
propósito, e o `backup/` existe para elas:

- **As conversas do Claude Code** (`~/.claude/projects`), que são dezenas de
  gigabytes reescritos a cada minuto e transformariam cada commit dos dotfiles em
  ruído.
- **Toda credencial da máquina**, de `~/.claude.json` (a lista de servidores MCP
  e seus tokens, que uma auditoria encontrou sem nenhuma origem de restauração)
  até `~/.ssh`, `~/.gnupg`, `~/.aws` e os tokens do CLIProxyAPI.

```bash
bash backup/backup-ai.sh          # gera ~/backups/ezomar-ai-<data>.tar.zst + sha256
bash backup/restore-ai.sh <tar>   # na máquina nova, depois do install.sh
bash backup/restore-repos.sh      # reclona os repos nos mesmos caminhos
```

O tarball **não é encriptado** e carrega chave privada: ele viaja por ssh ou
tailscale para uma máquina sua, e para lugar nenhum além disso.

Duas decisões que valem entender. O backup pergunta ao **chezmoi**, na hora de
rodar, o que já é gerenciado, e exclui isso do tarball; assim `~/.claude` entra
sem as skills e sem o `settings.json`, sem que ninguém precise manter uma segunda
lista que envelhece calada. E o restore move de lado **apenas os caminhos exatos**
que vai restaurar, nunca as raízes que os contêm: mover `~/.config` para extrair
`.config/opencode` apagaria em silêncio o `hypr/`, o `waybar/` e todo o resto que
o Omarchy acabou de escrever.

Reclonar nos mesmos caminhos não é preciosismo. O Claude Code indexa conversa
pelo caminho absoluto do diretório, então um repo que volta uma pasta ao lado
perde o histórico inteiro, sem erro nenhum. Quando o caminho mudar mesmo assim,
`backup/rebind.sh` religa as conversas, o banco do zoxide e o trust do mise.

## Contexto

Escrito em 2026-08 para uma máquina de reserva que espelha um desktop primário.
Desde então a régua mudou: o próprio desktop primário vai ser formatado com
Omarchy, e o que antes podia ficar só no post-install do Fedora (meeting-rig,
oom-guard, watchdog, preflight de login, keepalive dos cofres) passou a ter
módulo aqui, porque nada mais o reporia. O procedimento completo de bootstrap
fica documentado no seu repo de dotfiles.
