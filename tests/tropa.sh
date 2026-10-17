#!/usr/bin/env bash
set -euo pipefail

# Ensaia o tropa inteiro contra um herdr falso, sem abrir agente de verdade:
# workspace e abas, a conta certa em cada aba (CODEX_HOME, KIMI_CODE_HOME), o
# override de confiança do Codex, o arquivo de confiança do Kimi, o passo
# headless do Muse dentro de um painel, a revisão que acusa quem mexe na
# worktree e a desmobilização que só apaga o que já entrou no master. Também
# cobre a guarda (wrappers que recusam push, commit e `dotnet test` sem filtro),
# o passo travado que volta com `unblock`, vagas e conta ocupada, o runner que
# some e o passo headless que estoura o tempo.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT/install/templates/tropa"
TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

fail() { echo "FALHOU: $*" >&2; exit 1; }

export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config"
export TROPA_ROSTER="$TPL/roster.json" TROPA_MEMES="$TPL/memes.json"
export TROPA_USAGE_DIR="$TMP/usage" TROPA_POLL_SECONDS=1 TROPA_EXIT_GRACE=0 TROPA_KEY_DELAY=0
export TROPA_NO_BOARD=1 HERDR_ENV=1
export HERDR_LOG="$TMP/herdr.log" FAKE_DIR="$TMP/fake"
mkdir -p "$HOME/.local/bin" "$FAKE_DIR" "$TROPA_USAGE_DIR" "$TMP/bin"
TROPA="$TPL/tropa"
# dotnet falso atrás da guarda: o que passar pelo wrapper chega aqui
printf '#!/usr/bin/env bash\necho fake-dotnet "$@"\n' >"$TMP/bin/dotnet"
chmod +x "$TMP/bin/dotnet"
export PATH="$TMP/bin:$PATH"

# --- herdr falso: registra a chamada e devolve o JSON nos caminhos que o tropa lê
cat >"$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_LOG"
n=$(( $(cat "$FAKE_DIR/n" 2>/dev/null || echo 1) + 1 )); echo "$n" >"$FAKE_DIR/n"
# Erros vão para o stderr com saída 1, como no herdr 0.8.2.
herr() { printf '{"error":{"code":"%s","message":"%s"},"id":"cli"}\n' "$1" "$2" >&2; exit 1; }
f="${FAKE_FOCUS:-wD}"
case "$1 $2" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"wD","focused":%s},{"workspace_id":"wT","focused":%s},{"workspace_id":"wX","focused":false}]}}\n' \
      "$([ "$f" = wD ] && echo true || echo false)" "$([ "$f" = wT ] && echo true || echo false)" ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wT"},"tab":{"tab_id":"wT:t1"},"root_pane":{"pane_id":"wT:p1"}}}' ;;
  "tab create") echo "{\"result\":{\"tab\":{\"tab_id\":\"wT:t$n\"},\"root_pane\":{\"pane_id\":\"wT:p$n\"}}}" ;;
  "agent start")
    if [ -n "${FAKE_FAIL_START:-}" ]; then herr agent_not_ready "agent $3 blocked during startup"; fi
    echo "{\"result\":{\"agent\":{\"name\":\"$3\",\"agent_status\":\"idle\"}}}" ;;
  "agent prompt")
    if [ -n "${FAKE_FAIL_PROMPT:-}" ]; then herr agent_prompt_stalled "no change in 5s"; fi
    echo "{\"result\":{\"agent\":{\"name\":\"$3\",\"agent_status\":\"working\",\"agent_session\":{\"value\":\"sess-$n\"}}}}" ;;
  "agent get")
    if [ "$3" = ghost ]; then herr agent_not_found "agent target ghost not found"; fi
    echo "{\"result\":{\"agent\":{\"name\":\"$3\",\"agent_status\":\"${FAKE_AGENT_STATUS:-done}\"}}}" ;;
  "agent read") echo "tela de $3" ;;
  "pane get") echo '{"result":{"pane":{"pane_id":"x"}}}' ;;
  "pane run")
    shift 3
    # o placar roda para sempre; o passo do painel pode ser segurado
    case "$*" in *" board "*) ;; *) [ -n "${FAKE_PANE_NORUN:-}" ] || bash -c "$*" >/dev/null 2>&1 ;; esac
    echo ;;
  "notification show") echo '{"result":{"shown":false,"reason":"disabled"}}' ;;
  *) echo '{"result":{"type":"ok"}}' ;;
esac
SH
chmod +x "$TMP/bin/herdr"
export TROPA_HERDR_BIN="$TMP/bin/herdr"

# --- Muse falso: escreve o relatório que o prompt pede e mexe na worktree. Na
# execução do CS-027 testa a guarda por dentro, como um agente faria.
cat >"$HOME/.local/bin/muse" <<'SH'
#!/usr/bin/env bash
prompt="${*: -1}"
if [ -n "${FAKE_MUSE_SLEEP:-}" ]; then sleep "$FAKE_MUSE_SLEEP"; fi
if [ -n "${FAKE_MUSE_SILENT:-}" ]; then echo "{\"kind\":\"turn_input_user\",\"prompt\":\"$prompt\"}"; exit 0; fi
if [[ "$prompt" == *"implementer for task CS-027"* ]]; then
  {
    git push origin HEAD >/dev/null 2>&1; echo "push=$?"
    git -C "$PWD" commit --allow-empty -m x >/dev/null 2>&1; echo "commit=$?"
    git status --porcelain >/dev/null 2>&1; echo "status=$?"
    dotnet test Foo.csproj >/dev/null 2>&1; echo "test=$?"
    dotnet test Foo.csproj --filter "TestCategory!=Integration&FullyQualifiedName~X" >/dev/null 2>&1; echo "testf=$?"
    dotnet run --project Intelligence.Service.SelfHost >/dev/null 2>&1; echo "run=$?"
    dotnet build Intelligence.DataSources >/dev/null 2>&1; echo "build=$?"
    psql -c 'select 1' >/dev/null 2>&1; echo "psql=$?"
    echo "pgpass=$PGPASSFILE"
  } >"$FAKE_DIR/guard-probe.txt"
fi
out="$(grep -oE '/[^ ]*-report\.md' <<<"$prompt" | head -1)"
if [ -n "$out" ]; then echo "relatorio do muse falso" >"$out"; fi
if [ "$prompt" != "Reply with exactly: OK" ]; then echo mudanca >"$PWD/muse-change.txt"; fi
echo "{\"kind\":\"turn_input_user\",\"prompt\":\"$prompt\"}"
echo '{"type":"final","text":"OK"}'
SH
chmod +x "$HOME/.local/bin/muse"

# --- contas: muse e kimi logados, codex-exato logado com cota alta, glm sem login
mkdir -p "$HOME/.config/muse" "$HOME/.kimi-code" "$HOME/.codex-profiles/exato" "$HOME/.codex-profiles/personal"
: >"$HOME/.config/muse/auth.json"
: >"$HOME/.kimi-code/credentials"
: >"$HOME/.codex-profiles/exato/auth.json"
: >"$HOME/.codex-profiles/personal/auth.json"
echo '{"limits":[{"label":"Weekly","percent":0.95}]}' >"$TROPA_USAGE_DIR/codex.json"
echo '{"limits":[{"label":"Weekly","percent":0.10}]}' >"$TROPA_USAGE_DIR/codex-exato.json"

roster="$("$TROPA" roster --json)"
[ "$(jq -r '.[] | select(.dino == "muse") | .state' <<<"$roster")" = ok ] || fail "muse logado não ficou ok"
[ "$(jq -r '.[] | select(.dino == "glm-zai") | .state' <<<"$roster")" = sem-login ] || fail "glm sem login não foi detectado"
[ "$(jq -r '.[] | select(.dino == "codex-personal") | .state' <<<"$roster")" = sem-cota ] || fail "cota de 95% não tirou o codex-personal"
[ "$(jq -r '.[] | select(.dino == "codex-exato") | .state' <<<"$roster")" = ok ] || fail "codex-exato com 10% devia estar ok"
"$TROPA" roster >/dev/null || fail "roster em tabela quebrou"

# --- smoke headless no muse falso; o prompt ecoado sozinho não conta como OK
"$TROPA" smoke muse | jq -e '.ok == true and .guard == true' >/dev/null || fail "smoke do muse falso"
set +e
FAKE_MUSE_SILENT=1 "$TROPA" smoke muse >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 1 ] || fail "smoke passou só com o prompt ecoado no log"

# --- guarda: wrappers escritos e na frente de um bash -l
gd="$("$TROPA" guard --check "$TMP")"
jq -e '.enabled == true and (.wrappers | index("git") != null) and (.wrappers | index("mise") != null)' >/dev/null <<<"$gd" \
  || fail "guarda sem os wrappers: $gd"
jq -e '.check.bash_login.git.guarded == true and .check.bash_login.dotnet.guarded == true' >/dev/null <<<"$gd" \
  || fail "guarda não ficou na frente no bash -l: $gd"

# --- repositório de teste
git init -q -b master "$TMP/repos/proj"
P="$TMP/repos/proj"
echo base >"$P/base.txt"
git -C "$P" add base.txt && git -C "$P" commit -q -m base
printf 'Goal: test\n' >"$TMP/spec.md"

# --- up
"$TROPA" up t1 --repo "$P" >/dev/null
grep -q "workspace create --cwd $P --label .* --no-focus" "$HERDR_LOG" || fail "workspace create sem --no-focus"
S="$XDG_STATE_HOME/tropa/t1/state.json"
[ "$(jq -r '.workspace.focused_before' "$S")" = wD ] || fail "não guardou o workspace em foco"
[ "$(jq -r '.main' "$S")" = master ] || fail "branch principal errada"
"$TROPA" up t1 --repo "$P" | jq -e '.resumed == true' >/dev/null || fail "up repetido não retomou"

# --- deploy codex-exato (TUI pelo herdr)
out="$("$TROPA" deploy t1 ds-077 --dino codex-exato --spec "$TMP/spec.md" --title DS-077)"
WT1="$TMP/repos/.tropa-worktrees/proj-ds-077"
[ -d "$WT1" ] || fail "worktree não criada em $WT1"
[ "$(git -C "$WT1" rev-parse --abbrev-ref HEAD)" = tropa/ds-077 ] || fail "branch errada"
grep -F "tab create --workspace wT --cwd $WT1 --label" "$HERDR_LOG" | grep -qF -- "--env CODEX_HOME=$HOME/.codex-profiles/exato" \
  || fail "aba do codex-exato sem CODEX_HOME da conta"
start="$(grep '^agent start rex-t1-0-e1 ' "$HERDR_LOG")" || fail "agent start com nome errado"
grep -qF -- "--kind codex" <<<"$start" || fail "kind errado"
grep -qF -- "model_reasoning_effort=high" <<<"$start" || fail "esforço de execução não é high"
grep -qF -- "projects={\"$WT1\"={trust_level=\"trusted\"}}" <<<"$start" || fail "override de confiança do codex ausente"
grep -q '^agent prompt rex-t1-0-e1 You are the implementer for task DS-077' "$HERDR_LOG" || fail "prompt de execução não enviado"
[ "$(jq -r '.status' <<<"$out")" = running ] || fail "deploy não ficou running"
grep -qE 'label [^-]*DS-077 \[Tiranossauro\]' "$HERDR_LOG" || fail "rótulo de meme não tem o ID e o dinossauro"
gl="$(grep -n "^pane run [^ ]* export PATH=$XDG_STATE_HOME/tropa/_guard/bin:" "$HERDR_LOG" | head -1 | cut -d: -f1)"
sl="$(grep -n '^agent start rex-t1-0-e1 ' "$HERDR_LOG" | cut -d: -f1)"
[ -n "$gl" ] && [ "$gl" -lt "$sl" ] || fail "a guarda não foi exportada no painel antes do agent start"
grep -q 'PGPASSFILE=/dev/null' "$HERDR_LOG" || fail "export da guarda sem PGPASSFILE"
[ -s "$(dirname "$(jq -r '.expect' <<<"$out")")/exec1-prompt.txt" ] || fail "prompt da execução não foi guardado"

# --- wait sem relatório: código 3
set +e
"$TROPA" wait t1 ds-077 --timeout 1000 >/dev/null; rc=$?
set -e
[ "$rc" = 3 ] || fail "wait sem relatório devolveu $rc, esperado 3"

# --- wait com relatório: código 0
report="$(jq -r '.expect' <<<"$out")"
echo "relatorio" >"$report"
"$TROPA" wait t1 ds-077 --timeout 1000 | jq -e '.status == "finished"' >/dev/null || fail "wait com relatório não terminou"

# --- deploy kimi-exato: arquivo de confiança gravado antes de abrir
"$TROPA" deploy t1 pl-061 --dino kimi-exato --spec "$TMP/spec.md" --title PLT-061 >/dev/null
WT2="$TMP/repos/.tropa-worktrees/proj-pl-061"
hash="$(printf '%s' "$WT2" | sha256sum | cut -c1-12)"
trust="$HOME/.kimi-code/workspace-trust/wd_proj-pl-061_$hash"
[ -f "$trust" ] || fail "kimi sem arquivo de confiança ($trust)"
[ "$(jq -r '.root' "$trust")" = "$WT2" ] || fail "confiança do kimi aponta para outro lugar"
grep -F "tab create --workspace wT --cwd $WT2" "$HERDR_LOG" | grep -qF -- "--env KIMI_MODEL_THINKING_EFFORT=high" \
  || fail "esforço do kimi não foi pela env"

# --- autorrevisão do codex: sessão nova, esforço máximo, aba própria
rv="$("$TROPA" review t1 ds-077)"
[ "$(jq -r '.step' <<<"$rv")" = review1 ] || fail "passo de revisão errado"
grep '^agent start rex-t1-0-r1 ' "$HERDR_LOG" | grep -qF -- "model_reasoning_effort=max" || fail "revisão não subiu no max (ultra delega a subagentes)"
[ "$(jq -r '.tasks["ds-077"].phase' "$S")" = review1 ] || fail "revisão não marcou a fase"
echo "NO FINDINGS" >"$(jq -r '.expect' <<<"$rv")"
"$TROPA" wait t1 ds-077 --timeout 1000 --close | jq -e '.status == "finished" and .tainted == false' >/dev/null \
  || fail "revisão limpa não terminou"
grep -q "^tab close $(jq -r '.tab' <<<"$rv")$" "$HERDR_LOG" || fail "--close não fechou a aba da revisão"
grep -q '^agent send-keys rex-t1-0-r1 ctrl+c' "$HERDR_LOG" || fail "revisor não recebeu ctrl+c antes de fechar"

# --- revisão cruzada que mexe na worktree: código 6
xr="$("$TROPA" review t1 ds-077 --dino codex-personal)"
[ "$(jq -r '.step' <<<"$xr")" = cross1 ] || fail "revisão por outro dinossauro não virou cross"
echo "achado" >"$(jq -r '.expect' <<<"$xr")"
echo sujou >"$WT1/sujeira.txt"
set +e
"$TROPA" wait t1 ds-077 --timeout 1000 >/dev/null; rc=$?
set -e
[ "$rc" = 6 ] || fail "revisor que mexeu na worktree devolveu $rc, esperado 6"
rm -f "$WT1/sujeira.txt"

# --- correção vai para a mesma sessão do executor
printf '1. major a.cs:1 x\n' >"$TMP/fixes.md"
fx="$("$TROPA" fix t1 ds-077 --file "$TMP/fixes.md")"
jq -e '.same_session == true and .agent == "rex-t1-0-e1"' >/dev/null <<<"$fx" || fail "correção não voltou ao executor"

# --- muse: headless dentro de um painel, sem tipo de agente no herdr
mu="$("$TROPA" deploy t1 cs-027 --dino muse --spec "$TMP/spec.md" --title CS-027)"
[ "$(jq -r '.mode' <<<"$mu")" = pane ] || fail "muse devia rodar em painel"
"$TROPA" wait t1 cs-027 --timeout 5000 | jq -e '.status == "finished" and .rc == "0"' >/dev/null || fail "passo do muse não terminou"
[ -f "$TMP/repos/.tropa-worktrees/proj-cs-027/muse-change.txt" ] || fail "muse não rodou dentro da worktree"
probe="$(cat "$FAKE_DIR/guard-probe.txt")"
for want in push=126 commit=126 status=0 test=126 testf=0 run=126 build=0 psql=126 pgpass=/dev/null; do
  grep -qx "$want" <<<"$probe" || fail "guarda: esperado $want, veio: $(tr '\n' ' ' <<<"$probe")"
done

# --- grok: travado na abertura, confiança gravada, unblock manda o prompt guardado
set +e
gk="$(FAKE_FAIL_START=1 "$TROPA" deploy t1 ops-051 --dino grok --spec "$TMP/spec.md" --title OPS-051 2>"$TMP/gk.err")"; rc=$?
set -e
[ "$rc" = 4 ] || fail "abertura travada devolveu $rc, esperado 4"
grep -q 'agent_not_ready' "$TMP/gk.err" || fail "erro do herdr (stderr) não chegou à mensagem: $(cat "$TMP/gk.err")"
jq -e '.prompt_sent == false and .error == "agent_not_ready"' >/dev/null <<<"$gk" || fail "passo travado sem prompt_sent=false: $gk"
grep -c "^\[folders.\"$P\"\]" "$HOME/.grok/trusted_folders.toml" | grep -qx 1 || fail "grok sem confiança na raiz do repo"
set +e
wj="$(FAKE_AGENT_STATUS=idle "$TROPA" wait t1 ops-051 --timeout 1000)"; rc=$?
set -e
{ [ "$rc" = 4 ] && jq -e '.prompt_pending == true' >/dev/null <<<"$wj"; } || fail "wait de passo sem prompt devolveu $rc: $wj"
gka="$(jq -r '.agent' <<<"$gk")"
grep -q "^agent prompt $gka " "$HERDR_LOG" && fail "prompt saiu antes do unblock"
FAKE_AGENT_STATUS=idle "$TROPA" unblock t1 ops-051 | jq -e '.resent == true and .status == "running"' >/dev/null || fail "unblock não reenviou"
grep -q "^agent prompt $gka You are the implementer for task OPS-051" "$HERDR_LOG" || fail "unblock não mandou o prompt guardado"
echo ok >"$(jq -r '.expect' <<<"$gk")"
"$TROPA" wait t1 ops-051 --timeout 1000 | jq -e '.status == "finished"' >/dev/null || fail "lane destravada não terminou"
"$TROPA" deploy t1 ops-052 --dino grok --spec "$TMP/spec.md" >/dev/null
[ "$(grep -c '^\[folders' "$HOME/.grok/trusted_folders.toml")" = 1 ] || fail "confiança do grok duplicada"
"$TROPA" recall t1 ops-052 >/dev/null

# --- narração e status
line="$("$TROPA" say t1 merged ds-077)"
grep -qE 'DS-077|Tiranossauro' <<<"$line" || fail "fala de merge sem tarefa nem dinossauro: $line"
[ "$("$TROPA" say t1 merged ds-077)" != "$line" ] || fail "say repetiu a mesma fala"
"$TROPA" status t1 --json | jq -e 'length == 5 and (.[0].account == "codex-exato")' >/dev/null || fail "status não lista as 5 tarefas com conta"
"$TROPA" notify t1 "teste" >/dev/null
grep -q '^workspace report-metadata wT --source tropa --token status=teste' "$HERDR_LOG" || fail "notify não marcou o workspace"

# --- merge da ds-077 e desmobilização
echo fix >"$WT1/fix.txt"  # o que o dinossauro teria feito
git -C "$WT1" add fix.txt && git -C "$WT1" commit -q -m "fix ds-077"
ch="$("$TROPA" changes t1 ds-077 --scope "fix.txt docs/*")"
jq -e '.empty == false and (.commits | length) == 1 and (.files | index("fix.txt") != null) and .out_of_scope == []' >/dev/null <<<"$ch" \
  || fail "changes não viu o commit da lane: $ch"
"$TROPA" changes t1 ds-077 --scope "docs/*" | jq -e '.out_of_scope == ["fix.txt"]' >/dev/null || fail "changes não acusou arquivo fora do escopo"
git -C "$P" merge -q --ff-only tropa/ds-077
"$TROPA" mark t1 ds-077 "merged $(git -C "$P" rev-parse --short HEAD)"
down="$("$TROPA" down t1)"
[ ! -e "$WT1" ] || fail "worktree mergeada não foi removida"
git -C "$P" rev-parse --verify -q refs/heads/tropa/ds-077 >/dev/null && fail "branch mergeada não foi apagada"
[ -d "$TMP/repos/.tropa-worktrees/proj-cs-027" ] || fail "apagou a worktree com trabalho não mergeado"
jq -e '.kept | map(.task) | index("cs-027") != null' >/dev/null <<<"$down" || fail "down não listou a worktree mantida"
grep -q '^workspace close wT$' "$HERDR_LOG" || fail "workspace da run não foi fechado"
grep -q '^workspace focus' "$HERDR_LOG" && fail "down mexeu no foco com o Andre em outro workspace"
[ "$(jq -r '.closed' "$S")" = true ] || fail "run não ficou encerrada"

# --- placar com os caminhos efetivos, e o foco que volta só quando a tropa tinha o foco
TROPA_NO_BOARD=0 "$TROPA" up t3 --repo "$P" >/dev/null
grep -q "^pane run wT:p1 env TROPA_STATE_ROOT=$XDG_STATE_HOME/tropa .*TROPA_ROSTER=$TROPA_ROSTER .* board t3$" "$HERDR_LOG" \
  || fail "placar sem TROPA_STATE_ROOT/TROPA_ROSTER na linha de comando"
FAKE_FOCUS=wT "$TROPA" down t3 | jq -e '.refocused == true' >/dev/null || fail "down não devolveu o foco"
grep -q '^workspace focus wD$' "$HERDR_LOG" || fail "foco não voltou para o workspace original"

# --- vagas, conta ocupada e modelo da tarefa na autorrevisão
"$TROPA" up t4 --repo "$P" --max 2 >/dev/null
"$TROPA" deploy t4 a1 --dino codex-exato --spec "$TMP/spec.md" --model gpt-6-luna >/dev/null
set +e
"$TROPA" deploy t4 a2 --dino codex-exato --spec "$TMP/spec.md" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 8 ] || fail "segunda sessão na mesma conta devolveu $rc, esperado 8"
[ ! -e "$TMP/repos/.tropa-worktrees/proj-a2" ] || fail "recusa por conta deixou worktree para trás"
"$TROPA" deploy t4 a2 --dino codex-personal --spec "$TMP/spec.md" >/dev/null
set +e
"$TROPA" deploy t4 a3 --dino kimi-exato --spec "$TMP/spec.md" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 7 ] || fail "deploy além do max devolveu $rc, esperado 7"
"$TROPA" slots t4 | jq -e '.used == 2 and .free == 0' >/dev/null || fail "slots não contou 2 de 2"
"$TROPA" runs | jq -e 'map(.run) | index("t4") != null and index("t1") == null' >/dev/null || fail "runs não lista só as abertas"
echo ok >"$(jq -r '.tasks.a1.step.expect' "$XDG_STATE_HOME/tropa/t4/state.json")"
"$TROPA" wait t4 a1 --timeout 1000 >/dev/null
"$TROPA" review t4 a1 >/dev/null
grep '^agent start rex-t4-0-r1 ' "$HERDR_LOG" | grep -qF -- "-m gpt-6-luna" || fail "autorrevisão não usou o modelo da execução"
"$TROPA" down t4 >/dev/null

# --- modo headless (sem herdr): o passo roda e devolve o resultado do wait
HERDR_ENV=0 "$TROPA" up t2 --repo "$P" >/dev/null
hl="$(HERDR_ENV=0 "$TROPA" deploy t2 cs-028 --dino muse --spec "$TMP/spec.md")"
jq -e '.status == "finished"' >/dev/null <<<"$hl" || fail "deploy headless não devolveu o wait: $hl"
grep -q "^timeout --kill-after=60 5400 " "$XDG_STATE_HOME/tropa/t2/cs-028/exec1.sh" || fail "runner sem timeout"
set +e
to="$(HERDR_ENV=0 FAKE_MUSE_SLEEP=5 TROPA_STEP_TIMEOUT=1 "$TROPA" deploy t2 cs-029 --dino muse --spec "$TMP/spec.md")"; rc=$?
set -e
{ [ "$rc" = 5 ] && jq -e '.status == "timed-out"' >/dev/null <<<"$to"; } || fail "passo headless travado devolveu $rc: $to"

# --- runner que nunca começou (ou sumiu): código 2, sem esperar o prazo inteiro
"$TROPA" up t5 --repo "$P" >/dev/null
FAKE_PANE_NORUN=1 "$TROPA" deploy t5 cs-030 --dino muse --spec "$TMP/spec.md" >/dev/null
set +e
rg="$(TROPA_START_GRACE=0 "$TROPA" wait t5 cs-030 --timeout 60000)"; rc=$?
set -e
{ [ "$rc" = 2 ] && jq -e '.status == "runner-gone"' >/dev/null <<<"$rg"; } || fail "runner ausente devolveu $rc: $rg"
true &
dead=$!
wait "$dead"
"$TROPA" recall t5 cs-030 >/dev/null
FAKE_PANE_NORUN=1 "$TROPA" deploy t5 cs-030 --dino muse --spec "$TMP/spec.md" >/dev/null
echo "$dead" >"$(jq -r '.tasks["cs-030"].step.pid_file' "$XDG_STATE_HOME/tropa/t5/state.json")"
set +e
"$TROPA" wait t5 cs-030 --timeout 60000 >/dev/null; rc=$?
set -e
[ "$rc" = 2 ] || fail "runner morto devolveu $rc, esperado 2"
"$TROPA" down t5 >/dev/null

while read -r _ _ name; do
  [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || fail "nome de agente inválido para o herdr: $name"
done < <(grep -oE '^agent start [^ ]+' "$HERDR_LOG")

# --- módulo de instalação: idempotente e sem pisar na edição do roster
(
  export HOME="$TMP/home2" XDG_CONFIG_HOME="$TMP/home2/.config" XDG_STATE_HOME="$TMP/home2/.local/state"
  mkdir -p "$HOME"
  bash "$ROOT/install/apps/71-tropa.sh" >/dev/null
  [ -x "$HOME/.local/bin/tropa" ] || fail "módulo não instalou o binário"
  cmp -s "$TPL/roster.json" "$XDG_CONFIG_HOME/tropa/roster.json" || fail "roster não foi copiado"
  bash "$ROOT/install/apps/71-tropa.sh" >/dev/null
  [ ! -e "$XDG_CONFIG_HOME/tropa/roster.json.new" ] || fail "segunda instalação criou .new sem motivo"
  jq '.dinos.grok.enabled = false' "$XDG_CONFIG_HOME/tropa/roster.json" >"$TMP/r.json"
  mv "$TMP/r.json" "$XDG_CONFIG_HOME/tropa/roster.json"
  bash "$ROOT/install/apps/71-tropa.sh" >/dev/null
  [ "$(jq -r '.dinos.grok.enabled' "$XDG_CONFIG_HOME/tropa/roster.json")" = false ] || fail "módulo pisou na edição do roster"
  cmp -s "$TPL/roster.json" "$XDG_CONFIG_HOME/tropa/roster.json.new" && fail "roster editado e template iguais não deviam gerar .new"
  true
)

bash -n "$TROPA"
echo "tropa: ok"
