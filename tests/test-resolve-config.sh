#!/bin/bash
# Tests for hooks/resolve-config.sh.
# Runs the resolver inside a throwaway sandbox HOME/XDG_STATE_HOME with a stubbed
# `obsidian` binary, then asserts individual fields of the resolved JSON.
#
# Usage: tests/test-resolve-config.sh   (exits non-zero on first failure)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$SCRIPT_DIR/../hooks/resolve-config.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

FAKE_HOME="$SANDBOX/home"
STATE="$SANDBOX/state"
STUB_BIN="$SANDBOX/bin"
mkdir -p "$FAKE_HOME" "$STATE" "$STUB_BIN"

# Stub `obsidian`: prints a TSV vault block only when STUB_VAULT_PATH is set.
cat > "$STUB_BIN/obsidian" <<'EOF'
#!/bin/bash
if [ "$1" = "vault" ] && [ -n "${STUB_VAULT_PATH:-}" ]; then
  printf 'name\tobsidian\npath\t%s\nfiles\t1\nfolders\t1\nsize\t1\n' "$STUB_VAULT_PATH"
fi
EOF
chmod +x "$STUB_BIN/obsidian"

PASS=0
FAIL=0

# run <cwd> -> sets global OUT to the resolver's JSON output
run() {
  OUT="$(HOME="$FAKE_HOME" \
        XDG_STATE_HOME="$STATE" \
        PATH="$STUB_BIN:$PATH" \
        bash "$RESOLVER" "$1")"
}

field() { printf '%s' "$OUT" | jq -r "$1"; }

assert_field() {
  local label="$1" expr="$2" want="$3" got
  got="$(field "$expr")"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL: %s\n      %s\n      want: [%s]\n      got:  [%s]\n' "$label" "$expr" "$want" "$got"
  fi
}

reset_configs() {
  rm -rf "${FAKE_HOME:?}/.claude" "${STATE:?}/obsidian-chronicle"
  rm -rf "$SANDBOX/proj"
  unset STUB_VAULT_PATH
}

write_user_config() {
  mkdir -p "$STATE/obsidian-chronicle"
  printf '%s' "$1" > "$STATE/obsidian-chronicle/obsidian-chronicle.json"
}

write_project_config() {
  # $1 = project dir (relative to sandbox), $2 = json
  mkdir -p "$SANDBOX/$1/.claude"
  printf '%s' "$2" > "$SANDBOX/$1/.claude/obsidian-chronicle.json"
}

# --- 1. project only ---
reset_configs
write_project_config "proj" '{"vaultPath":"/p/vault"}'
run "$SANDBOX/proj"
assert_field "project: source" '.source' 'project'
assert_field "project: vaultPath" '.vaultPath' '/p/vault'
assert_field "project: sessionsDir default" '.sessionsDir' '/p/vault/Sessions'
assert_field "project: dailyDir default" '.dailyDir' '/p/vault/Sessions/Daily Notes'
assert_field "project: model default" '.model' 'sonnet'
assert_field "project: language default" '.language' 'English'

# --- 2. user only ---
reset_configs
write_user_config '{"vaultPath":"/u/vault","model":"sonnet"}'
run "$SANDBOX/proj"   # proj has no config now
assert_field "user: source" '.source' 'user'
assert_field "user: vaultPath" '.vaultPath' '/u/vault'
assert_field "user: model" '.model' 'sonnet'
assert_field "user: sessionsDir" '.sessionsDir' '/u/vault/Sessions'

# --- 3. merge: user base, project overrides key-wise; vault from user ---
reset_configs
write_user_config '{"vaultPath":"/u/vault","model":"sonnet","minBytes":100}'
write_project_config "proj" '{"sessionsDir":"Notes","model":"opus"}'
run "$SANDBOX/proj"
assert_field "merge: source (vault from user)" '.source' 'user'
assert_field "merge: vaultPath" '.vaultPath' '/u/vault'
assert_field "merge: sessionsDir from project" '.sessionsDir' '/u/vault/Notes'
assert_field "merge: dailyDir tracks sessionsDir" '.dailyDir' '/u/vault/Notes/Daily Notes'
assert_field "merge: model overridden by project" '.model' 'opus'
assert_field "merge: minBytes from user" '.minBytes' '100'
assert_field "merge: maxBytes default" '.maxBytes' '1000000'

# --- 4. none: no files, stub returns nothing ---
reset_configs
run "$SANDBOX/proj"
assert_field "none: source" '.source' 'none'
assert_field "none: vaultPath empty" '.vaultPath' ''
assert_field "none: sessionsDir empty" '.sessionsDir' ''
assert_field "none: dailyDir empty" '.dailyDir' ''
assert_field "none: log resolved" '.log' "$STATE/obsidian-chronicle/process.log"
assert_field "none: model default" '.model' 'sonnet'

# --- 5. cli-fallback: no files, stub returns a path ---
reset_configs
export STUB_VAULT_PATH="/cli/vault"
run "$SANDBOX/proj"
assert_field "cli: source" '.source' 'cli-fallback'
assert_field "cli: vaultPath" '.vaultPath' '/cli/vault'
assert_field "cli: sessionsDir" '.sessionsDir' '/cli/vault/Sessions'
unset STUB_VAULT_PATH

# --- 6. relative vs absolute path forms ---
reset_configs
write_project_config "proj" '{"vaultPath":"~/vault","sessionsDir":"/abs/sessions","dailyDir":"~/daily"}'
run "$SANDBOX/proj"
assert_field "paths: vaultPath tilde" '.vaultPath' "$FAKE_HOME/vault"
assert_field "paths: sessionsDir absolute" '.sessionsDir' '/abs/sessions'
assert_field "paths: dailyDir tilde" '.dailyDir' "$FAKE_HOME/daily"

# --- 7. dailyDir default derives from sessionsDir ---
reset_configs
write_project_config "proj" '{"vaultPath":"/v","sessionsDir":"S"}'
run "$SANDBOX/proj"
assert_field "dailyDefault: dailyDir" '.dailyDir' '/v/S/Daily Notes'

# --- 8. upward search finds parent project config from a subdir ---
reset_configs
write_project_config "proj" '{"vaultPath":"/up/vault"}'
mkdir -p "$SANDBOX/proj/sub/deep"
run "$SANDBOX/proj/sub/deep"
assert_field "upward: source" '.source' 'project'
assert_field "upward: vaultPath" '.vaultPath' '/up/vault'

# --- 9b. language: user sets it, project overrides key-wise ---
reset_configs
write_user_config '{"vaultPath":"/u/vault","language":"Japanese"}'
run "$SANDBOX/proj"
assert_field "language: from user" '.language' 'Japanese'
reset_configs
write_user_config '{"vaultPath":"/u/vault","language":"Japanese"}'
write_project_config "proj" '{"language":"Français"}'
run "$SANDBOX/proj"
assert_field "language: project overrides user" '.language' 'Français'

# --- 9. search never treats $HOME as a project location ---
reset_configs
mkdir -p "$FAKE_HOME/.claude"
printf '%s' '{"vaultPath":"/should/not/be/used"}' > "$FAKE_HOME/.claude/obsidian-chronicle.json"
mkdir -p "$FAKE_HOME/work"
run "$FAKE_HOME/work"
assert_field "home-excluded: not picked as project" '.source' 'none'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
