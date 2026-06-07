#!/bin/bash
# Shared config resolver for obsidian-chronicle.
#
# Usage: resolve-config.sh [cwd]
# Prints the resolved configuration as a JSON object on stdout, with every path
# made absolute and tilde-expanded. Consumers (session-summary.sh, the
# obsidian-vault agent, setup) read individual keys with `jq -r` — no eval.
#
# Resolution model:
#   - Non-vault keys (sessionsDir, dailyDir, model, log, minBytes, maxBytes):
#       built-in defaults  <-  user JSON  <-  project JSON     (key-wise merge)
#   - vaultPath (NO built-in runtime default):
#       project JSON  ->  user JSON  ->  `obsidian vault` CLI  ->  unresolved
#   - relative sessionsDir/dailyDir are joined to the resolved vaultPath;
#     a value starting with `/` or `~` is treated as absolute.
#
# Config file locations:
#   - project: nearest .claude/obsidian-chronicle.json found by walking UP from
#              cwd, stopping before $HOME and at the filesystem root.
#   - user:    ${XDG_STATE_HOME:-$HOME/.local/state}/obsidian-chronicle/obsidian-chronicle.json
#
# Output JSON includes a "source" field: project | user | cli-fallback | none.
# "none" means no vaultPath could be resolved — callers must skip rather than
# write to a guessed location.

set -u

CWD="${1:-$PWD}"

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
USER_CONFIG="$STATE_HOME/obsidian-chronicle/obsidian-chronicle.json"

expand_tilde() {
  case "$1" in
    "~")    printf '%s\n' "$HOME" ;;
    "~/"*)  printf '%s\n' "$HOME/${1#\~/}" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

# Join a (possibly relative) sub-path onto the vault root. Absolute (`/…`) and
# tilde (`~…`) values are taken verbatim.
join_path() {
  local base="$1" p="$2"
  case "$p" in
    "/"*)  printf '%s\n' "$p" ;;
    "~"*)  expand_tilde "$p" ;;
    *)     printf '%s\n' "$base/$p" ;;
  esac
}

# Run a command with a wall-clock timeout so the optional `obsidian vault` probe
# can never hang a hook. Uses perl's alarm (present on macOS/Linux); degrades to
# a direct call if perl is unavailable.
run_with_timeout() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift; alarm $s; exec @ARGV' "$secs" "$@"
  else
    "$@"
  fi
}

# Read a JSON file, emitting `{}` for missing/unreadable/invalid files so the
# merge below never breaks on a half-synced or hand-corrupted config.
read_json() {
  local f="$1"
  [ -f "$f" ] || { printf '{}'; return 0; }
  jq -c '.' "$f" 2>/dev/null || printf '{}'
}

# Walk UP from cwd looking for .claude/obsidian-chronicle.json. $HOME itself is
# NOT a project location (that scope belongs to the user-level config), and the
# search never climbs above it. Prints the file path if found.
find_project_config() {
  local dir
  dir="$(cd "$1" 2>/dev/null && pwd)" || return 0
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ "$dir" = "$HOME" ] && break
    if [ -f "$dir/.claude/obsidian-chronicle.json" ]; then
      printf '%s\n' "$dir/.claude/obsidian-chronicle.json"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 0
}

USER_JSON="$(read_json "$USER_CONFIG")"
PROJ_FILE="$(find_project_config "$CWD")"
PROJ_JSON='{}'
[ -n "$PROJ_FILE" ] && PROJ_JSON="$(read_json "$PROJ_FILE")"

# Built-in defaults for the non-vault keys only. vaultPath is intentionally
# absent here so it is resolved exclusively from files / CLI / (else) none.
DEFAULTS='{"sessionsDir":"Sessions","model":"sonnet","language":"English","minBytes":200,"maxBytes":1000000}'

MERGED="$(jq -nc \
  --argjson d "$DEFAULTS" \
  --argjson u "$USER_JSON" \
  --argjson p "$PROJ_JSON" \
  '$d * $u * $p')"

# --- vaultPath + source ---
proj_vault="$(printf '%s' "$PROJ_JSON" | jq -r '.vaultPath // empty')"
user_vault="$(printf '%s' "$USER_JSON" | jq -r '.vaultPath // empty')"

VAULT=""
SOURCE="none"
if [ -n "$proj_vault" ]; then
  VAULT="$proj_vault"; SOURCE="project"
elif [ -n "$user_vault" ]; then
  VAULT="$user_vault"; SOURCE="user"
elif command -v obsidian >/dev/null 2>&1; then
  cli_vault="$(run_with_timeout 5 obsidian vault 2>/dev/null | awk -F'\t' '$1=="path"{print $2}')"
  if [ -n "$cli_vault" ]; then
    VAULT="$cli_vault"; SOURCE="cli-fallback"
  fi
fi
[ -n "$VAULT" ] && VAULT="$(expand_tilde "$VAULT")"

# --- session / daily dirs (resolved against the vault) ---
raw_sessions="$(printf '%s' "$MERGED" | jq -r '.sessionsDir // "Sessions"')"
raw_daily="$(printf '%s' "$MERGED" | jq -r '.dailyDir // empty')"

SESSIONS=""
DAILY=""
if [ -n "$VAULT" ]; then
  SESSIONS="$(join_path "$VAULT" "$raw_sessions")"
  if [ -n "$raw_daily" ]; then
    DAILY="$(join_path "$VAULT" "$raw_daily")"
  else
    DAILY="$SESSIONS/Daily Notes"
  fi
fi
# When VAULT is unresolved (source=none), relative dirs cannot be resolved, so
# SESSIONS/DAILY stay empty; callers skip on source=none anyway.

# --- log (always resolvable; lives outside the vault) ---
raw_log="$(printf '%s' "$MERGED" | jq -r '.log // empty')"
if [ -n "$raw_log" ]; then
  LOG="$(expand_tilde "$raw_log")"
else
  LOG="$STATE_HOME/obsidian-chronicle/process.log"
fi

MODEL="$(printf '%s' "$MERGED" | jq -r '.model // "sonnet"')"
LANGUAGE="$(printf '%s' "$MERGED" | jq -r '.language // "English"')"
MINB="$(printf '%s' "$MERGED" | jq -r '(.minBytes // 200) | (tonumber? // 200) | floor')"
MAXB="$(printf '%s' "$MERGED" | jq -r '(.maxBytes // 1000000) | (tonumber? // 1000000) | floor')"

jq -nc \
  --arg vault "$VAULT" \
  --arg sessions "$SESSIONS" \
  --arg daily "$DAILY" \
  --arg model "$MODEL" \
  --arg language "$LANGUAGE" \
  --arg log "$LOG" \
  --argjson minBytes "$MINB" \
  --argjson maxBytes "$MAXB" \
  --arg source "$SOURCE" \
  '{vaultPath:$vault, sessionsDir:$sessions, dailyDir:$daily, model:$model, language:$language, log:$log, minBytes:$minBytes, maxBytes:$maxBytes, source:$source}'
