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
| `90-verify.sh` | confere o estado final e lista o que falta |

**A ordem entre 20 e 30 é obrigatória.** Sem a chave age, o chezmoi aplica os
400 arquivos e reporta sucesso, mas tudo que é encriptado fica ilegível. É uma
máquina quebrada que se parece com uma máquina pronta.

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

Todo o resto que for seu é preciso **depois** do chezmoi, então pode viajar
junto com os dotfiles. Ponha em `~/.config/ezomar/apps/*.sh` no seu repo
privado, e o módulo `50-personal.sh` executa em ordem de nome. Antes do chezmoi
rodar o diretório não existe e o módulo não faz nada, o que é o comportamento
correto numa máquina zerada.

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

## Contexto

Escrito para uma máquina de reserva que espelha um desktop primário. O
procedimento completo de bootstrap fica documentado no seu repo de dotfiles.
