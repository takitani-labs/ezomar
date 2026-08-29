#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWITCH="$ROOT/install/templates/herdr-profile-switch/herdr-switch-agent-profile"
SESSION_MAP="$ROOT/install/templates/claude-profile-restore/claude-session-profile"
TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"
export CODEX_PROFILES_ROOT="$HOME/.codex-profiles"
export CLAUDE_PROFILES_ROOT="$HOME/.claude-profiles"
export HERDR_ACTIVE_PANE_ID="w1:p1"
export HERDR_SWITCH_PROFILE="exato"
export HERDR_TEST_LOG="$TMP/herdr.log"
mkdir -p "$HOME/bin" "$CODEX_PROFILES_ROOT/personal/sessions/2026/08/28" \
  "$CODEX_PROFILES_ROOT/exato"
printf '{}\n' > "$CODEX_PROFILES_ROOT/personal/auth.json"
printf '{}\n' > "$CODEX_PROFILES_ROOT/exato/auth.json"
session_id="01a00000-0000-7000-8000-000000000001"
source_rollout="$CODEX_PROFILES_ROOT/personal/sessions/2026/08/28/rollout-2026-08-28T00-00-00-$session_id.jsonl"
printf '{"type":"session_meta"}\n' > "$source_rollout"
ln -s "$CODEX_PROFILES_ROOT/personal" "$HOME/.codex"
target_rollout="$CODEX_PROFILES_ROOT/exato/sessions/2026/08/28/$(basename "$source_rollout")"
mkdir -p "$(dirname "$target_rollout")"
printf 'stale target\n' > "$target_rollout"
touch -d '2000-01-01 00:00:00 UTC' "$target_rollout"

cat > "$HOME/bin/herdr-compat-test" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_TEST_LOG"
case "$1 $2" in
  "pane get")
    printf '{"result":{"pane":{"agent":"%s","agent_status":"%s","agent_session":{"value":"%s"}}}}\n' \
      "${HERDR_TEST_AGENT:-codex}" "${HERDR_TEST_STATE:-idle}" \
      "${HERDR_TEST_SESSION:-01a00000-0000-7000-8000-000000000001}"
    ;;
  "pane process-info")
    if grep -q '^pane send-text ' "$HERDR_TEST_LOG"; then
      printf '%s\n' '{"result":{"process_info":{"foreground_processes":[]}}}'
    else
      printf '%s\n' '{"result":{"process_info":{"foreground_processes":[]}}}'
    fi
    ;;
esac
SH
cat > "$HOME/bin/herdr-new-incompatible" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$HOME/bin/herdr-compat-test" "$HOME/bin/herdr-new-incompatible"
export HERDR_BIN_PATH="$HOME/bin/herdr-new-incompatible"
export HERDR_COMPAT_BIN="$HOME/bin/herdr-compat-test"
export PATH="$HOME/bin:$PATH"

"$SWITCH"

[ "$source_rollout" -ef "$target_rollout" ]
grep -Fq "pane send-text $HERDR_ACTIVE_PANE_ID /quit" "$HERDR_TEST_LOG"
grep -Fq "pane send-keys $HERDR_ACTIVE_PANE_ID enter" "$HERDR_TEST_LOG"
grep -Fq "pane run $HERDR_ACTIVE_PANE_ID env CODEX_HOME=$CODEX_PROFILES_ROOT/exato codex resume $session_id" "$HERDR_TEST_LOG"
backup_dir="$CODEX_PROFILES_ROOT/exato/cache/herdr-session-handoff-backups"
[ "$(find "$backup_dir" -type f -name "$session_id-*.jsonl" | wc -l)" -eq 1 ]
grep -Fq 'stale target' "$backup_dir"/*.jsonl

# An active response is a hard stop: no /quit and no second writer.
: > "$HERDR_TEST_LOG"
export HERDR_TEST_STATE=working
if "$SWITCH" >/dev/null 2>&1; then
  echo "working agent was switched unexpectedly" >&2
  exit 1
fi
if grep -q '^pane send-text ' "$HERDR_TEST_LOG"; then
  echo "working agent received /quit unexpectedly" >&2
  exit 1
fi

# Claude shares transcripts, records an explicit profile override and resumes
# through the helper so provider secrets never appear in the pane command.
unset HERDR_TEST_STATE
export HERDR_TEST_AGENT=claude
claude_session="cb83035b-f9c5-413e-b058-af7567f596b4"
export HERDR_TEST_SESSION="$claude_session"
export HERDR_SWITCH_PROFILE=proton-max
mkdir -p "$CLAUDE_PROFILES_ROOT/team" "$CLAUDE_PROFILES_ROOT/proton-max" \
  "$HOME/.claude/projects/project-one"
printf '{}\n' > "$CLAUDE_PROFILES_ROOT/team/settings.json"
printf '{"env":{"TEST_PROFILE_SECRET":"kept-off-terminal"}}\n' \
  > "$CLAUDE_PROFILES_ROOT/proton-max/settings.json"
ln -s "$HOME/.claude/projects" "$CLAUDE_PROFILES_ROOT/team/projects"
ln -s "$HOME/.claude/projects" "$CLAUDE_PROFILES_ROOT/proton-max/projects"
printf '{}\n' > "$HOME/.claude/projects/project-one/$claude_session.jsonl"
cat > "$HOME/bin/claude-session-profile" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'session-map %s\n' "$*" >> "$HERDR_TEST_LOG"
if [ "${1:-}" != "set" ]; then printf 'team'; fi
SH
cat > "$HOME/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'claude-exec profile=%s secret=%s args=%s\n' \
  "${CLAUDE_CONFIG_DIR:-}" "${TEST_PROFILE_SECRET:-}" "$*" >> "$HERDR_TEST_LOG"
SH
chmod +x "$HOME/bin/claude-session-profile" "$HOME/bin/claude"

: > "$HERDR_TEST_LOG"
"$SWITCH"
grep -Fq "pane send-text $HERDR_ACTIVE_PANE_ID /exit" "$HERDR_TEST_LOG"
grep -Fq "session-map set $claude_session proton-max" "$HERDR_TEST_LOG"
grep -Fq "pane run $HERDR_ACTIVE_PANE_ID $SWITCH --resume-claude proton-max $claude_session" "$HERDR_TEST_LOG"
if grep -Fq 'kept-off-terminal' "$HERDR_TEST_LOG"; then
  echo "Claude provider secret leaked into pane command" >&2
  exit 1
fi

"$SWITCH" --resume-claude proton-max "$claude_session"
grep -Fq "claude-exec profile=$CLAUDE_PROFILES_ROOT/proton-max secret=kept-off-terminal args=--resume $claude_session" \
  "$HERDR_TEST_LOG"

# The real mapper prefers an intentional switch over the derived birth map.
export CLAUDE_SESSION_PROFILE_CACHE="$TMP/claude-cache.tsv"
export CLAUDE_SESSION_PROFILE_OVERRIDES="$TMP/claude-overrides.tsv"
printf '%s\t%s\n' "$claude_session" team > "$CLAUDE_SESSION_PROFILE_CACHE"
"$SESSION_MAP" set "$claude_session" proton-max
[ "$("$SESSION_MAP" "$claude_session")" = "proton-max" ]

echo "herdr profile switch: ok"
