#!/bin/bash
# SessionStart hook for obsidian-chronicle.
#
# Runs once at every session start (source: startup | resume | clear | compact).
# Resolves the obsidian-chronicle config a SINGLE time and does two things with
# the one result:
#
#   1. Caches it to disk, keyed by cwd, so the obsidian-vault agent can read the
#      already-resolved config without re-running resolve-config.sh. (Subagents
#      do NOT receive SessionStart context — Claude Code injects it into the main
#      session only — so the cache file is how the resolved config reaches them.)
#   2. Injects the resolved paths + the delegation rule into the MAIN session's
#      context via hookSpecificOutput.additionalContext, so the main session
#      knows the vault paths and that ALL vault work (read/search included) is
#      delegated to the obsidian-vault agent.
#
# Fail-safe posture: this hook must NEVER block or slow session start. Any
# failure (no jq, no config, resolver error) exits 0 silently with no injection.

set -u

# --- recursion guard (mirror session-summary.sh) -----------------------------
# session-summary.sh spawns `claude -p`, which starts a child session and fires
# SessionStart again. The child is a throwaway summarizer; skip all work there.
[ "${CLAUDE_OBSIDIAN_CHRONICLE_RUNNING:-}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE_DIR="$STATE_HOME/obsidian-chronicle/config-cache"

payload="$(cat)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

cfg="$("$PLUGIN_ROOT/hooks/resolve-config.sh" "$cwd" 2>/dev/null || true)"
[ -z "$cfg" ] && exit 0

src="$(printf '%s' "$cfg" | jq -r '.source // "none"' 2>/dev/null)"

# Cache path, keyed by cwd. Key encoding matches done-runner.sh's cwd->dir
# scheme: every non-alphanumeric char becomes '-'. The obsidian-vault agent
# recomputes the same key from $PWD (subagents inherit cwd).
key="$(printf '%s' "$cwd" | tr -c 'a-zA-Z0-9' '-')"
CACHE_FILE="$CACHE_DIR/$key.json"

# No vault configured -> inject nothing, and clear any stale cache for this cwd
# (e.g. a vault that was configured earlier and has since been removed) so the
# agent never reads a dangling path. Then stay completely silent.
if [ "$src" = "none" ]; then
  rm -f "$CACHE_FILE" 2>/dev/null || true
  exit 0
fi

# --- cache the resolved config (keyed by cwd) --------------------------------
if mkdir -p "$CACHE_DIR" 2>/dev/null; then
  printf '%s' "$cfg" > "$CACHE_FILE" 2>/dev/null || true
fi

# --- inject context into the main session ------------------------------------
vault="$(printf '%s' "$cfg" | jq -r '.vaultPath')"
sessions="$(printf '%s' "$cfg" | jq -r '.sessionsDir')"
daily="$(printf '%s' "$cfg" | jq -r '.dailyDir')"

# Unquoted heredoc so $vars expand; backticks are escaped to stay literal.
CTX="$(cat <<EOF
# Obsidian vault (obsidian-chronicle)

An Obsidian vault is configured for this session. Its config has already been
resolved for you — use these paths directly and do NOT re-run resolve-config.sh
during this session unless the config may have changed:

- vaultPath:   $vault
- sessionsDir: $sessions
- dailyDir:    $daily

## Delegation rule (applies to the main session)
Delegate ALL Obsidian vault operations to the \`obsidian-vault\` agent (Agent
tool, subagent_type "obsidian-chronicle:obsidian-vault") — this includes **read and search**, not
just writes. Do NOT run Bash/Read/Grep/Glob/Write/Edit directly against
$vault from the main session. The agent owns vault semantics (wikilinks,
frontmatter, daily notes, canvases, bases) and reads the same resolved config
from its on-disk cache. Session recording (notes + Daily Note lines) is separate
and owned by the SessionEnd/PreCompact hooks and /done — do not reimplement it.
EOF
)"

jq -n --arg ctx "$CTX" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}' \
  2>/dev/null || true

exit 0
