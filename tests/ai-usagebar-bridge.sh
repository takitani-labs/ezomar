#!/usr/bin/env bash
set -euo pipefail

# A ponte do ai-usagebar com um binário falso: nenhuma chave, nenhuma rede, e
# HOME/XDG apontando para uma pasta descartável, para que o ensaio nunca
# publique nada no painel de verdade.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT/install/templates/agent-usage-accounts/ezomar-agent-usage-ai-usagebar"
TMP="$(mktemp -d)"
cleanup() {
  chmod -R u+rw -- "$TMP" 2>/dev/null || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT

# Um EZOMAR_AI_USAGEBAR_* herdado do shell de quem roda o teste mudaria o
# cenário sem aviso. As chaves de verdade do shell também saem: o binário é
# falso e não precisa delas, e o cenário 4 só controla o que ele mesmo exporta.
unset EZOMAR_AI_USAGEBAR_CONFIG EZOMAR_AI_USAGEBAR_FROM_FILE \
  EZOMAR_AI_USAGEBAR_ACCOUNTS_DIR
while IFS= read -r name; do
  case "$name" in
    *_API_KEY|ANTHROPIC_ADMIN_KEY|XAI_MANAGEMENT_KEY|GITHUB_COPILOT_TOKEN|GH_TOKEN|GITHUB_TOKEN)
      unset "$name"
      ;;
  esac
done < <(compgen -e)
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_CACHE_HOME="$TMP/cache"
export XDG_STATE_HOME="$TMP/state"
export EZOMAR_AI_USAGEBAR_BIN="$TMP/bin/ai-usagebar"
export FAKE_USAGEBAR_LOG="$TMP/ai-usagebar.log"
export FAKE_USAGEBAR_ENV_LOG="$TMP/ai-usagebar-env.log"
export FAKE_USAGEBAR_PAYLOADS="$TMP/payloads"
USAGE_DIR="$XDG_STATE_HOME/omarchy/agents/usage"
ACCOUNTS_DIR="$XDG_CONFIG_HOME/ai-usagebar/accounts"
ACCOUNTS_STATE="$XDG_STATE_HOME/ezomar/ai-usagebar-accounts.tsv"
DEFAULT_CONFIG="$XDG_CONFIG_HOME/ai-usagebar/config.toml"
mkdir -p "$XDG_CONFIG_HOME/ai-usagebar" "$HOME" "$TMP/bin" "$FAKE_USAGEBAR_PAYLOADS"
: >"$DEFAULT_CONFIG"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Registra config, XDG_CACHE_HOME e argumentos de cada chamada e responde com
# payloads/<nome da config>.json, ou payloads/default.json sem --config. Sem
# payload, sai com erro, como um backend quebrado. Uma config que só desliga
# vendors imita o `usage` do ai-usagebar 1.26.0: "no vendors enabled" e saída 1.
# O log de ambiente guarda só NOMES de variáveis de credencial, nunca valores.
cat >"$EZOMAR_AI_USAGEBAR_BIN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
config=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\t%s\t%s\n' "${config:-<default>}" "${XDG_CACHE_HOME:-<unset>}" "$args" \
  >>"$FAKE_USAGEBAR_LOG"
keys="$(compgen -e \
  | grep -E '_API_KEY$|^(ANTHROPIC_ADMIN_KEY|XAI_MANAGEMENT_KEY|GITHUB_COPILOT_TOKEN|GH_TOKEN|GITHUB_TOKEN)$' \
  | LC_ALL=C sort | paste -sd, || true)"
printf '%s\t%s\tHOME=%s\tCANARY=%s\n' "${config:-<default>}" "${keys:-<none>}" \
  "$HOME" "${EZOMAR_TEST_CANARY:-<unset>}" >>"$FAKE_USAGEBAR_ENV_LOG"
if [ -n "$config" ] && grep -q '^enabled = false' "$config" \
  && ! grep -q '^enabled = true' "$config"; then
  echo "ai-usagebar usage: no vendors enabled in $config" >&2
  exit 1
fi
name=default
if [ -n "$config" ]; then
  name="$(basename -- "$config" .toml)"
fi
payload="$FAKE_USAGEBAR_PAYLOADS/$name.json"
if [ ! -f "$payload" ]; then
  echo "fake ai-usagebar: sem payload para $name" >&2
  exit 3
fi
cat -- "$payload"
SH
chmod +x "$EZOMAR_AI_USAGEBAR_BIN"

# anthropic@work e openai@personal são contas nomeadas, que o ai-usagebar 1.26.0
# publica com o rótulo no id. anthropic_api é outro vendor (gasto da API) e não
# pode cair no mesmo filtro.
cat >"$FAKE_USAGEBAR_PAYLOADS/default.json" <<'JSON'
{
  "schema_version": 1,
  "entries": [
    {"id": "anthropic", "display_name": "Claude", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": [{"label": "Session", "percent": 10, "reset_at": "2026-09-30T15:00:00Z"}]},
    {"id": "anthropic@work", "display_name": "Claude · work", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": [{"label": "Session", "percent": 11, "reset_at": null}]},
    {"id": "openai", "display_name": "Codex", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": [{"label": "5h", "percent": 20, "reset_at": null}]},
    {"id": "OpenAI@personal", "display_name": "Codex · personal", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": [{"label": "5h", "percent": 21, "reset_at": null}]},
    {"id": "anthropic_api", "display_name": "Anthropic API", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": [{"label": "Spend", "percent": 40, "reset_at": null}]},
    {"id": "kimi", "display_name": "Kimi", "plan": "Moderato", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": [{"label": "Weekly", "percent": 30, "reset_at": "2026-10-05T00:00:00Z"},
                 {"label": "5h", "percent": 4, "reset_at": "2026-09-30T16:00:00Z"}]},
    {"id": "zai", "display_name": "Z.AI", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": [{"label": "Tokens", "percent": 55, "reset_at": null}]},
    {"id": "custom:localprobe", "display_name": "Local Probe", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": [{"label": "Requests", "percent": 150, "reset_at": null}]},
    {"id": "deepseek", "display_name": "DeepSeek", "error": "HTTP 401", "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": []},
    {"id": "openrouter", "display_name": "OpenRouter", "error": null, "fetched_at": "2026-09-30T12:00:00Z",
     "metrics": []},
    {"display_name": "sem id", "metrics": [{"label": "x", "percent": 1}]},
    42
  ]
}
JSON

cat >"$FAKE_USAGEBAR_PAYLOADS/personal.json" <<'JSON'
{
  "schema_version": 1,
  "entries": [
    {"id": "anthropic", "display_name": "Claude", "error": null, "fetched_at": "2026-09-30T12:05:00Z",
     "metrics": [{"label": "Session", "percent": 90, "reset_at": null}]},
    {"id": "anthropic@work", "display_name": "Claude · work", "error": null, "fetched_at": "2026-09-30T12:05:00Z",
     "metrics": [{"label": "Session", "percent": 91, "reset_at": null}]},
    {"id": "openai", "display_name": "Codex", "error": null, "fetched_at": "2026-09-30T12:05:00Z",
     "metrics": [{"label": "5h", "percent": 80, "reset_at": null}]},
    {"id": "kimi", "display_name": "Kimi", "plan": "Allegretto", "error": null, "fetched_at": "2026-09-30T12:05:00Z",
     "metrics": [{"label": "Weekly", "percent": 12, "reset_at": "2026-10-06T00:00:00Z"}]},
    {"id": "moonshot", "error": null, "fetched_at": "2026-09-30T12:05:00Z",
     "metrics": [{"label": "Balance", "percent": 50, "reset_at": null}]}
  ]
}
JSON

printf '%s\n' 'isto não é JSON {' >"$FAKE_USAGEBAR_PAYLOADS/garbled.json"

# Roda a ponte e guarda código de saída, stdout e stderr sem derrubar o teste.
run_bridge() {
  local name="$1"
  shift
  : >"$FAKE_USAGEBAR_LOG"
  : >"$FAKE_USAGEBAR_ENV_LOG"
  if bash "$BRIDGE" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"; then
    rc=0
  else
    rc=$?
  fi
}

published() {
  if [ -d "$USAGE_DIR" ]; then
    (cd -- "$USAGE_DIR" && find . -maxdepth 1 -type f -name '*.json' -printf '%f\n' | LC_ALL=C sort)
  fi
}

field() { jq -r "$2" "$USAGE_DIR/ezomar-ai-usagebar-$1.json"; }

add_account() {
  mkdir -p "$ACCOUNTS_DIR"
  printf '[kimi]\nenabled = true\n' >"$ACCOUNTS_DIR/$1.toml"
}

pause_account() {
  printf '[kimi]\nenabled = false\n[zai]\nenabled = false\n' >"$ACCOUNTS_DIR/$1.toml"
}

reset_state() { rm -rf -- "$XDG_STATE_HOME" "$ACCOUNTS_DIR"; }

state() {
  if [ -f "$ACCOUNTS_STATE" ]; then
    cat -- "$ACCOUNTS_STATE"
  fi
}

# Nenhum arquivo de anthropic/openai, nem das contas nomeadas deles. O
# anthropic-api é o gasto da API e fica de fora da checagem.
no_native_vendors() {
  if published | grep -Fxv 'ezomar-ai-usagebar-anthropic-api.json' | grep -Eq 'anthropic|openai'; then
    fail "anthropic/openai should be skipped: $(published | tr '\n' ' ')"
  fi
}

default_files='ezomar-ai-usagebar-anthropic-api.json
ezomar-ai-usagebar-custom-localprobe.json
ezomar-ai-usagebar-kimi.json
ezomar-ai-usagebar-zai.json'

personal_files='ezomar-ai-usagebar-kimi-personal.json
ezomar-ai-usagebar-moonshot-personal.json'

with_default() { printf '%s\n%s\n' "$default_files" "$1" | LC_ALL=C sort; }

# 1. Só a config padrão: os mesmos arquivos de antes, com uma única chamada sem
#    --config e sem mexer no XDG_CACHE_HOME. anthropic@rótulo e openai@rótulo
#    ficam de fora como anthropic e openai.
reset_state
run_bridge default
[ "$rc" -eq 0 ] || fail "default-only run exited $rc: $(cat "$TMP/default.err")"
[ "$(published)" = "$default_files" ] || fail "default-only files: $(published)"
no_native_vendors
[ "$(field kimi '.id')" = kimi ] || fail 'default kimi id'
[ "$(field kimi '.name')" = Kimi ] || fail 'default kimi name'
[ "$(field kimi '.tierLabel')" = Moderato ] || fail 'default kimi tier'
[ "$(field kimi '[.limits[].percent] | map(tostring) | join(",")')" = '0.3,0.04' ] \
  || fail 'default kimi percent scale'
[ "$(field custom-localprobe '.limits[0].percent')" = 1 ] || fail 'percent clamp'
[ "$(field custom-localprobe '.id')" = 'custom:localprobe' ] || fail 'custom id'
[ "$(field anthropic-api '.id')" = anthropic_api ] || fail 'anthropic_api should still publish'
grep -Fxq '[ezomar][agent-usage] Kimi atualizado via ai-usagebar.' "$TMP/default.out" \
  || fail 'default stdout'
grep -Fxq '[ezomar][agent-usage] deepseek: HTTP 401; mantendo o último registro válido.' \
  "$TMP/default.err" || fail 'provider error message'
[ "$(wc -l <"$FAKE_USAGEBAR_LOG")" -eq 1 ] || fail 'default-only should call the backend once'
[ "$(cat "$FAKE_USAGEBAR_LOG")" = "<default>	$XDG_CACHE_HOME	usage --json" ] \
  || fail "default invocation: $(cat "$FAKE_USAGEBAR_LOG")"
[ ! -e "$XDG_STATE_HOME/ezomar" ] || fail 'default-only run created the accounts state'

# O modo --from-file com o mesmo payload publica exatamente os mesmos bytes.
mv -- "$USAGE_DIR" "$TMP/live-usage"
run_bridge from-file --from-file "$FAKE_USAGEBAR_PAYLOADS/default.json"
[ "$rc" -eq 0 ] || fail "--from-file exited $rc"
diff -r -- "$TMP/live-usage" "$USAGE_DIR" >/dev/null || fail '--from-file differs from the live run'
[ ! -s "$FAKE_USAGEBAR_LOG" ] || fail '--from-file called the backend'

# 2. --from-file não roda as contas extras: o ensaio sem chaves continua sem chaves.
reset_state
add_account personal
run_bridge from-file-accounts --from-file "$FAKE_USAGEBAR_PAYLOADS/default.json"
[ "$rc" -eq 0 ] || fail "--from-file with accounts exited $rc"
[ "$(published)" = "$default_files" ] || fail "--from-file published extra accounts: $(published)"
[ ! -s "$FAKE_USAGEBAR_LOG" ] || fail '--from-file with accounts called the backend'

# 3. accounts/personal.toml vira um segundo registro kimi, com config e cache
#    próprios, e anthropic/openai da conta extra continuam de fora.
reset_state
add_account personal
run_bridge personal
[ "$rc" -eq 0 ] || fail "personal run exited $rc: $(cat "$TMP/personal.err")"
[ "$(published)" = "$(with_default "$personal_files")" ] || fail "personal files: $(published)"
[ "$(field kimi-personal '.id')" = kimi-personal ] || fail 'personal kimi id'
[ "$(field kimi-personal '.name')" = 'Kimi · personal' ] || fail 'personal kimi display name'
[ "$(field kimi-personal '.limits[0].percent')" = 0.12 ] || fail 'personal kimi percent'
[ "$(field kimi-personal '.tierLabel')" = Allegretto ] || fail 'personal kimi tier'
[ "$(field moonshot-personal '.name')" = 'moonshot · personal' ] || fail 'name falls back to id'
# O registro da conta padrão não foi tocado pela conta extra.
if [ "$(field kimi '.id')" != kimi ] || [ "$(field kimi '.limits[0].percent')" != 0.3 ]; then
  fail 'default kimi was overwritten by the extra account'
fi
grep -Fxq '[ezomar][agent-usage] Kimi · personal atualizado via ai-usagebar.' "$TMP/personal.out" \
  || fail 'personal stdout'
no_native_vendors
[ "$(wc -l <"$FAKE_USAGEBAR_LOG")" -eq 2 ] || fail 'expected default + one extra call'
[ "$(sed -n 2p "$FAKE_USAGEBAR_LOG")" \
  = "$ACCOUNTS_DIR/personal.toml	$XDG_CACHE_HOME/ai-usagebar-accounts/personal	--config $ACCOUNTS_DIR/personal.toml usage --json" ] \
  || fail "extra invocation: $(sed -n 2p "$FAKE_USAGEBAR_LOG")"
[ "$(sed -n 1p "$FAKE_USAGEBAR_LOG" | cut -f2)" != "$(sed -n 2p "$FAKE_USAGEBAR_LOG" | cut -f2)" ] \
  || fail 'extra account shares the default cache'
[ "$(state)" = "ezomar-ai-usagebar-kimi-personal.json	personal
ezomar-ai-usagebar-moonshot-personal.json	personal" ] || fail "accounts state: $(state)"

# 4. Contas extras quebradas (backend com erro, JSON inválido) não impedem a
#    padrão nem as outras extras; o serviço ainda sinaliza a falha no fim.
reset_state
add_account broken
add_account garbled
add_account personal
run_bridge failing
[ "$rc" -eq 1 ] || fail "failing extras should exit 1, got $rc"
[ -f "$USAGE_DIR/ezomar-ai-usagebar-kimi.json" ] || fail 'failing extra blocked the default record'
[ -f "$USAGE_DIR/ezomar-ai-usagebar-kimi-personal.json" ] || fail 'failing extra blocked another extra'
if published | grep -Eq 'broken|garbled'; then
  fail 'failing extras published something'
fi
grep -Fq 'O backend ai-usagebar (conta broken) falhou' "$TMP/failing.err" || fail 'broken message'
grep -Fq 'fake ai-usagebar: sem payload para broken' "$TMP/failing.err" \
  || fail 'the backend stderr of a failing extra was swallowed'
grep -Fq 'O backend ai-usagebar (conta garbled) retornou JSON inválido' "$TMP/failing.err" \
  || fail 'garbled message'
[ "$(wc -l <"$FAKE_USAGEBAR_LOG")" -eq 4 ] || fail 'every account should have been tried'

# 5. O contrário também vale: a padrão quebrada não segura a conta extra, e a
#    mensagem dela é a mesma de antes.
reset_state
add_account personal
mv -- "$FAKE_USAGEBAR_PAYLOADS/default.json" "$TMP/default.json.off"
run_bridge default-broken
mv -- "$TMP/default.json.off" "$FAKE_USAGEBAR_PAYLOADS/default.json"
[ "$rc" -eq 1 ] || fail "broken default should exit 1, got $rc"
grep -Fxq '[ezomar][agent-usage] O backend ai-usagebar falhou; mantendo os últimos registros válidos.' \
  "$TMP/default-broken.err" || fail 'default failure message changed'
[ "$(published)" = "$personal_files" ] || fail "broken default files: $(published)"

# 6. Sem binário ou sem config nenhuma, o serviço fica quieto e sai 0. Uma conta
#    extra basta para rodar sem a config padrão.
reset_state
add_account personal
EZOMAR_AI_USAGEBAR_BIN="$TMP/missing-ai-usagebar" run_bridge no-binary
[ "$rc" -eq 0 ] || fail "missing binary exited $rc"
if [ -s "$TMP/no-binary.out" ] || [ -s "$TMP/no-binary.err" ]; then
  fail 'missing binary was not quiet'
fi
[ ! -e "$USAGE_DIR" ] || fail 'missing binary created the state dir'

reset_state
mv -- "$DEFAULT_CONFIG" "$TMP/config.toml.off"
run_bridge no-config
[ "$rc" -eq 0 ] || fail "missing config exited $rc"
if [ -s "$TMP/no-config.out" ] || [ -s "$TMP/no-config.err" ]; then
  fail 'missing config was not quiet'
fi
[ ! -s "$FAKE_USAGEBAR_LOG" ] || fail 'missing config called the backend'

add_account personal
run_bridge accounts-only
[ "$rc" -eq 0 ] || fail "accounts-only exited $rc"
[ "$(published)" = "$personal_files" ] || fail "accounts-only files: $(published)"
if [ "$(wc -l <"$FAKE_USAGEBAR_LOG")" -ne 1 ] || ! grep -q "^$ACCOUNTS_DIR/personal.toml	" "$FAKE_USAGEBAR_LOG"; then
  fail 'accounts-only should call only the extra config'
fi

# Sem config padrão, apagar a última conta extra ainda tira a aba dela: o estado
# faz a ponte rodar uma última vez. Na seguinte, sem estado, volta a ficar quieta.
rm -f -- "$ACCOUNTS_DIR/personal.toml"
run_bridge accounts-only-deleted
[ "$rc" -eq 0 ] || fail "last extra deleted exited $rc: $(cat "$TMP/accounts-only-deleted.err")"
[ -z "$(published)" ] || fail "last extra deleted left: $(published)"
[ ! -e "$ACCOUNTS_STATE" ] || fail 'empty accounts state was kept'
[ ! -s "$FAKE_USAGEBAR_LOG" ] || fail 'pruning without configs called the backend'
run_bridge accounts-only-quiet
if [ "$rc" -ne 0 ] || [ -s "$TMP/accounts-only-quiet.out" ] || [ -s "$TMP/accounts-only-quiet.err" ]; then
  fail 'no config and no state should be quiet again'
fi
mv -- "$TMP/config.toml.off" "$DEFAULT_CONFIG"

# 7. A config padrão segue XDG_CONFIG_HOME, como o próprio ai-usagebar. Uma
#    config só em ~/.config, com XDG_CONFIG_HOME apontando para outro lugar, é
#    um arquivo que o binário não leria, então o serviço fica quieto.
reset_state
mkdir -p "$HOME/.config/ai-usagebar"
mv -- "$DEFAULT_CONFIG" "$HOME/.config/ai-usagebar/config.toml"
run_bridge home-config-only
mv -- "$HOME/.config/ai-usagebar/config.toml" "$DEFAULT_CONFIG"
[ "$rc" -eq 0 ] || fail "config outside XDG_CONFIG_HOME exited $rc"
[ ! -s "$FAKE_USAGEBAR_LOG" ] || fail 'config outside XDG_CONFIG_HOME called the backend'

# EZOMAR_AI_USAGEBAR_CONFIG explícita vai junto como --config, e o registro
# continua sendo da conta padrão, sem sufixo nem cache próprio.
reset_state
mkdir -p "$TMP/explicit"
: >"$TMP/explicit/default.toml"
EZOMAR_AI_USAGEBAR_CONFIG="$TMP/explicit/default.toml" run_bridge explicit-config
[ "$rc" -eq 0 ] || fail "explicit config exited $rc: $(cat "$TMP/explicit-config.err")"
[ "$(cat "$FAKE_USAGEBAR_LOG")" \
  = "$TMP/explicit/default.toml	$XDG_CACHE_HOME	--config $TMP/explicit/default.toml usage --json" ] \
  || fail "explicit config invocation: $(cat "$FAKE_USAGEBAR_LOG")"
[ "$(published)" = "$default_files" ] || fail "explicit config files: $(published)"

# 8. Poda. Renomear a conta troca as abas: as da conta antiga somem e as da
#    nova aparecem, e as da padrão ficam.
reset_state
add_account personal
run_bridge prune-setup
[ "$rc" -eq 0 ] || fail "prune setup exited $rc"
mv -- "$ACCOUNTS_DIR/personal.toml" "$ACCOUNTS_DIR/work.toml"
cp -- "$FAKE_USAGEBAR_PAYLOADS/personal.json" "$FAKE_USAGEBAR_PAYLOADS/work.json"
run_bridge prune-rename
[ "$rc" -eq 0 ] || fail "rename exited $rc: $(cat "$TMP/prune-rename.err")"
[ "$(published)" = "$(with_default 'ezomar-ai-usagebar-kimi-work.json
ezomar-ai-usagebar-moonshot-work.json')" ] || fail "rename files: $(published)"
[ "$(state)" = "ezomar-ai-usagebar-kimi-work.json	work
ezomar-ai-usagebar-moonshot-work.json	work" ] || fail "rename state: $(state)"
grep -Fxq '[ezomar][agent-usage] Conta personal removida ou pausada; ezomar-ai-usagebar-kimi-personal.json apagado.' \
  "$TMP/prune-rename.out" || fail 'rename prune message'

# Uma conta que existe e só falhou nesta rodada mantém as abas, como a padrão.
mv -- "$FAKE_USAGEBAR_PAYLOADS/work.json" "$TMP/work.json.off"
run_bridge prune-transient
[ "$rc" -eq 1 ] || fail "transient extra failure should exit 1, got $rc"
[ -f "$USAGE_DIR/ezomar-ai-usagebar-kimi-work.json" ] || fail 'transient failure pruned the extra account'
grep -Fq 'ezomar-ai-usagebar-kimi-work.json	work' "$ACCOUNTS_STATE" \
  || fail 'transient failure dropped the account from the state'
mv -- "$TMP/work.json.off" "$FAKE_USAGEBAR_PAYLOADS/work.json"

# Apagar a conta tira as abas dela e o estado, e nada da padrão.
rm -f -- "$ACCOUNTS_DIR/work.toml"
run_bridge prune-delete
[ "$rc" -eq 0 ] || fail "delete exited $rc"
[ "$(published)" = "$default_files" ] || fail "delete files: $(published)"
[ ! -e "$ACCOUNTS_STATE" ] || fail "delete kept the state: $(state)"

# Um estado estragado não apaga registro da padrão nem arquivo fora da pasta.
mkdir -p "$XDG_STATE_HOME/ezomar"
: >"$XDG_STATE_HOME/omarchy/agents/outside.json"
printf 'ezomar-ai-usagebar-kimi.json\tghost\n../outside.json\tghost\nezomar-ai-usagebar-zai.json\t\n' \
  >"$ACCOUNTS_STATE"
run_bridge prune-tampered
[ "$rc" -eq 0 ] || fail "tampered state exited $rc"
[ "$(published)" = "$default_files" ] || fail "tampered state files: $(published)"
[ -f "$XDG_STATE_HOME/omarchy/agents/outside.json" ] || fail 'tampered state deleted a file outside'
[ ! -e "$ACCOUNTS_STATE" ] || fail "tampered state was kept: $(state)"

# O ensaio com --from-file não poda; a rodada ao vivo seguinte, sim.
reset_state
add_account personal
run_bridge prune-from-file-setup
rm -f -- "$ACCOUNTS_DIR/personal.toml"
run_bridge prune-from-file --from-file "$FAKE_USAGEBAR_PAYLOADS/default.json"
[ "$rc" -eq 0 ] || fail "--from-file after delete exited $rc"
[ "$(published)" = "$(with_default "$personal_files")" ] || fail "--from-file pruned: $(published)"
[ -s "$ACCOUNTS_STATE" ] || fail '--from-file rewrote the accounts state'
run_bridge prune-after-from-file
[ "$(published)" = "$default_files" ] || fail "live run after --from-file did not prune: $(published)"

# 9. Conta pausada: enabled = false em tudo faz o ai-usagebar sair 1 com "no
#    vendors enabled". A ponte pula a conta em silêncio, sai 0 e tira a aba.
reset_state
add_account personal
run_bridge pause-setup
pause_account personal
run_bridge paused
[ "$rc" -eq 0 ] || fail "paused account exited $rc: $(cat "$TMP/paused.err")"
# O stderr só tem o que a conta padrão já dizia (o 401 do deepseek).
if grep -Eq 'personal|no vendors' "$TMP/paused.err"; then
  fail "paused account was not quiet: $(cat "$TMP/paused.err")"
fi
[ "$(published)" = "$default_files" ] || fail "paused account kept its tab: $(published)"
[ "$(wc -l <"$FAKE_USAGEBAR_LOG")" -eq 2 ] || fail 'paused account was not even tried'
run_bridge paused-again
if [ "$rc" -ne 0 ] || grep -Eq 'personal|no vendors' "$TMP/paused-again.err"; then
  fail 'paused account failed on the next tick'
fi
# Religar devolve a aba na rodada seguinte.
add_account personal
run_bridge unpaused
[ "$(published)" = "$(with_default "$personal_files")" ] || fail "unpaused files: $(published)"

# Renomear para .toml.off também pausa: a conta nem roda e a aba sai.
mv -- "$ACCOUNTS_DIR/personal.toml" "$ACCOUNTS_DIR/personal.toml.off"
run_bridge paused-off
[ "$rc" -eq 0 ] || fail ".toml.off exited $rc"
[ "$(published)" = "$default_files" ] || fail ".toml.off kept its tab: $(published)"
[ "$(wc -l <"$FAKE_USAGEBAR_LOG")" -eq 1 ] || fail '.toml.off account was still called'

# 10. A conta extra não herda credencial do ambiente, e o resto do ambiente
#     chega igual. A padrão continua recebendo tudo, como antes.
reset_state
add_account personal
KIMI_API_KEY=fake-default-kimi MOONSHOT_API_KEY=fake-moonshot ZAI_API_KEY=fake-zai \
  ANTHROPIC_ADMIN_KEY=fake-admin GH_TOKEN=fake-gh EZOMAR_TEST_CANARY=kept \
  run_bridge env-scrub
[ "$rc" -eq 0 ] || fail "env scrub exited $rc: $(cat "$TMP/env-scrub.err")"
[ "$(sed -n 1p "$FAKE_USAGEBAR_ENV_LOG")" \
  = "<default>	ANTHROPIC_ADMIN_KEY,GH_TOKEN,KIMI_API_KEY,MOONSHOT_API_KEY,ZAI_API_KEY	HOME=$HOME	CANARY=kept" ] \
  || fail "default env: $(sed -n 1p "$FAKE_USAGEBAR_ENV_LOG")"
[ "$(sed -n 2p "$FAKE_USAGEBAR_ENV_LOG")" \
  = "$ACCOUNTS_DIR/personal.toml	<none>	HOME=$HOME	CANARY=kept" ] \
  || fail "extra env: $(sed -n 2p "$FAKE_USAGEBAR_ENV_LOG")"
[ "$(published)" = "$(with_default "$personal_files")" ] || fail "env scrub files: $(published)"

# 11. --from-file copia o arquivo, como antes das contas extras: um payload
#     ilegível falha com a mensagem do cp, não com "o backend falhou", e "-" é
#     um arquivo chamado "-", nunca a entrada padrão.
reset_state
cp -- "$FAKE_USAGEBAR_PAYLOADS/default.json" "$TMP/unreadable.json"
chmod 000 "$TMP/unreadable.json"
if [ -r "$TMP/unreadable.json" ]; then
  echo 'SKIP unreadable --from-file: this user can read a mode-000 file' >&2
else
  run_bridge unreadable --from-file "$TMP/unreadable.json"
  [ "$rc" -eq 1 ] || fail "unreadable --from-file exited $rc"
  grep -q '^cp: ' "$TMP/unreadable.err" || fail "unreadable --from-file message: $(cat "$TMP/unreadable.err")"
  if grep -Fq 'backend' "$TMP/unreadable.err"; then
    fail 'unreadable --from-file blamed the backend'
  fi
  [ -z "$(published)" ] || fail 'unreadable --from-file published something'
fi

mkdir -p "$TMP/cwd-no-dash" "$TMP/cwd-dash"
cd -- "$TMP/cwd-no-dash"
run_bridge dash-stdin --from-file - <"$FAKE_USAGEBAR_PAYLOADS/default.json"
cd -- "$ROOT"
[ "$rc" -eq 1 ] || fail "--from-file - read stdin (exit $rc)"
grep -Fxq '[ezomar][agent-usage] Payload de teste ausente: -' "$TMP/dash-stdin.err" \
  || fail "--from-file - message: $(cat "$TMP/dash-stdin.err")"
[ -z "$(published)" ] || fail '--from-file - published stdin'

cp -- "$FAKE_USAGEBAR_PAYLOADS/default.json" "$TMP/cwd-dash/-"
cd -- "$TMP/cwd-dash"
run_bridge dash-file --from-file - <"$FAKE_USAGEBAR_PAYLOADS/garbled.json"
cd -- "$ROOT"
[ "$rc" -eq 0 ] || fail "--from-file with a file named - exited $rc: $(cat "$TMP/dash-file.err")"
[ "$(published)" = "$default_files" ] || fail "--from-file - files: $(published)"

printf '%s\n' \
  'BRIDGE default-only publishes the same records, live and --from-file' \
  'BRIDGE accounts/personal.toml adds kimi-personal with its own --config and cache' \
  'BRIDGE failing sources do not block the others; anthropic/openai and @labels stay skipped' \
  'BRIDGE default config follows XDG_CONFIG_HOME; EZOMAR_AI_USAGEBAR_CONFIG goes as --config' \
  'BRIDGE renamed, deleted and paused accounts lose their tabs; transient failures keep them' \
  'BRIDGE extra accounts run without *_API_KEY credentials from the environment' \
  'BRIDGE --from-file copies the file: cp errors, "-" is a file' \
  'ai-usagebar bridge: ok'
