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

## Módulos

Rodam em ordem de nome, e a numeração importa.

| Módulo | O que faz |
|---|---|
| `00-packages.sh` | o delta de pacotes via pacman |
| `05-shell.sh` | `chsh` para zsh, e registra em `/etc/shells` |
| `10-bitwarden-cli.sh` | binário oficial do `bw` em `~/.local/bin`, sem root |
| `20-age-key.sh` | restaura a identidade age do Bitwarden |
| `30-chezmoi.sh` | instala o chezmoi e aplica os dotfiles |
| `40-claude-plugins.sh` | marketplaces e os 10 plugins do Claude Code |
| `50-personal.sh` | roda seus módulos privados, se houver |
| `56-herdr.sh` | instala o herdr pelo instalador oficial e habilita o unit, se os dotfiles o trouxeram |
| `58-npm-ai-clis.sh` | `codex`, `gemini` e `grok` via npm, em `~/.npm-global` |
| `60-cliproxyapi.sh` | instala a API local para as subscriptions de IA, sua config secreta e unit de usuário |
| `61-ai-usagebar.sh` | medidor de uso das subscriptions (upstream do Akita) e seu plugin do Omarchy |
| `62-cliproxyapi-exato.sh` | cria a segunda instância do CLIProxyAPI para a conta Codex de trabalho |
| `64-codex-profiles.sh` | separa as contas do Codex CLI por `CODEX_HOME` e compartilha a configuração |
| `66-claude-profile-restore.sh` | instala o mapa de sessão para o herdr restaurar cada pane no perfil Claude correto |
| `68-pidbox.sh` | instala o guard de namespace de PID contra `kill(-1)` de suítes de teste |
| `70-collie.sh` | instala opcionalmente o plugin Collie, sem publicar o bridge |
| `72-tools-repo.sh` | clona seu repo privado de ferramentas, se `EZOMAR_TOOLS_REPO` estiver definido |
| `74-meeting-rig.sh` | linka o `mrig` desse repo e roda o setup dele (venv + modelo) |
| `76-claude-auth-preflight.sh` | instala o unit que avisa de perfis deslogados antes do herdr subir |
| `78-pw-keepalive.sh` | daemon que mantém as sessões do 1Password e Bitwarden vivas |
| `80-oom-guard.sh` | sysrq, piso de memória do desktop e teto de memória da frota do herdr |
| `82-watchdog.sh` | arma o watchdog de hardware em 60s, se a placa tiver um |
| `90-verify.sh` | confere o estado final e lista o que falta |

**A ordem entre 20 e 30 é obrigatória.** Sem a chave age, o chezmoi aplica os
400 arquivos e reporta sucesso, mas tudo que é encriptado fica ilegível. É uma
máquina quebrada que se parece com uma máquina pronta.

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

## Resiliência: o que entrou e o que ficou de fora

A máquina primária congelou em 2026-07-30 (36 sessões do Claude mais Chrome,
zram 100% cheio por 16 horas, load 283, e nem o OOM killer do kernel nem o
systemd-oomd dispararam) e trava por completo a cada poucas semanas, sem panic
e sem log. A carga de trabalho vai junto para o Omarchy; a proteção também.

O `80-oom-guard.sh` porta três camadas: `kernel.sysrq=1` (a saída manual,
Alt+SysRq+F, que o Arch deixa desligada), um piso de memória para o
`session.slice` (o compositor continua respondendo sob pressão) e um teto para
o `herdr.service`, que dá à frota seu próprio domínio de OOM: no limite o kernel
mata o pane mais gordo dentro do cgroup, o herdr o retoma pelo uuid, e o resto
da máquina nem percebe. O teto importa mais no Omarchy do que no Fedora: o oomd
dele mata cgroups inteiros no `app.slice`, e a frota é um cgroup só. Por isso o
drop-in também pede `ManagedOOMPreference=avoid`.

Ficou de fora, de propósito: o earlyoom (o Omarchy escolheu o oomd por PSI e
rejeita o earlyoom nos próprios comentários; com a frota contida, o motivo dele
existir desaparece, e os dois juntos produzem kills duplicados), o swapfile em
btrfs (o zram do Omarchy já ocupa toda a RAM, e `omarchy-hibernation-setup`
cria o tier em disco se quiser) e o resto do sysctl (o Omarchy já traz igual).

O `82-watchdog.sh` arma o watchdog de hardware em 60s. A placa é a mesma
depois do format; o kernel morrendo sem ninguém por perto virava uma máquina
parada até alguém segurar o botão. Sem `/dev/watchdog`, o módulo pula.

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

**A barra de uso do KDE.** A máquina primária mostrava o consumo das
subscriptions num plasmoide alimentado por um fork do ai-usagebar. O fork não
tinha nenhum commit próprio, então no Omarchy entra o upstream do Akita direto
(`61-ai-usagebar.sh`), com o plugin nativo dele como interface.

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

## Antes de formatar a máquina velha

O `install.sh` responde se a máquina nova ficou pronta. O `preformat.sh` responde
a pergunta anterior, na máquina que vai ser apagada: tudo que a nova vai precisar
está capturado? Ele deriva a lista do estado vivo (skills, perfis do Claude,
units systemd de usuário, configs com chave) e pergunta ao chezmoi o que está no
source; depois confere que os repos envolvidos (dotfiles, ezomar e o de
ferramentas) estão commitados e no remoto, porque um source perfeito que só
existe no disco prestes a ser apagado não vale nada.

```bash
bash preformat.sh          # relatório, só leitura
bash preformat.sh --fix    # chezmoi add/re-add do que dá, commit e push do source, e reconfere
```

Termina com "OK, pode formatar" ou com a lista de pendências. O `--fix` nunca
toca `~/.claude/settings.json` (o Claude Code reescreve esse arquivo com estado
de plugin) nem adiciona os drop-ins do oom-guard (o módulo 80 escreve os dele).
O que ninguém versiona de propósito (transcrições do mrig, `~/.claude.json`,
sessões do herdr) ele só lista, para você copiar se importar.

## Contexto

Escrito em 2026-08 para uma máquina de reserva que espelha um desktop primário.
Desde então a régua mudou: o próprio desktop primário vai ser formatado com
Omarchy, e o que antes podia ficar só no post-install do Fedora (meeting-rig,
oom-guard, watchdog, preflight de login, keepalive dos cofres) passou a ter
módulo aqui, porque nada mais o reporia. O procedimento completo de bootstrap
fica documentado no seu repo de dotfiles.
