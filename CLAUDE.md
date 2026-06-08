# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`obsidian-chronicle` is a **Claude Code plugin** (not an application) — pure bash + markdown, no build step, no dependencies beyond `jq`, `bash` 3.2+, and the `claude` CLI. It has two pillars:

1. **Automatic session recording** — hooks fire when a session ends and write a structured Obsidian note + a Daily Note line, summarized by `claude -p`.
2. **The `obsidian-vault` agent** — the unified handler the main session delegates *all* Obsidian vault work to (create/edit/search/organize notes, canvases, bases) so vault semantics are handled correctly instead of via generic file tools.

## Architecture: three triggers → one writer

```
SessionEnd ─┐
PreCompact ─┤→ hooks/session-summary.sh  (the ONE writer; ~660 lines)
/done ──────┘   via commands/done.md → hooks/done-runner.sh
```

- **`hooks/session-summary.sh`** is the entire engine. Everything else feeds it a hook-style JSON payload on stdin (`{session_id, transcript_path, cwd, reason}`). All the real logic — config loading, conversation extraction, dedup, `claude -p` invocation, note assembly — lives here.
- **`hooks/done-runner.sh`** backs `/done`. Its only job is to *locate the current session's transcript* (a surprisingly involved task — see below) and synthesize the payload, then pipe it to `session-summary.sh`.
- **`hooks/resolve-config.sh`** is the shared config resolver — the single source of truth for *where notes go*. It reads the JSON config (user-level + project), merges, resolves paths, and prints resolved JSON. `session-summary.sh`, the `obsidian-vault` agent, and `setup.md` all call it.
- **`commands/done.md`** / **`commands/setup.md`** are the two slash commands. `setup.md` generates an `obsidian-chronicle.json`.
- **`agents/obsidian-vault.md`** is independent of the recording pipeline — it's the interactive vault specialist agent.
- Hooks are registered in **`.claude-plugin/plugin.json`** (`SessionEnd`, `PreCompact`). `PreCompact` passes `REASON_OVERRIDE=precompact`.

### Key mechanisms in session-summary.sh

- **Recursion guard (must stay first):** `claude -p` spawns its own Claude session → fires SessionEnd → would recurse infinitely. `CLAUDE_OBSIDIAN_CHRONICLE_RUNNING=1` is exported so the child hook short-circuits. Never move this below the early logic.
- **Detached worker subshell with `trap '' HUP`:** the whole job runs in `( ... ) & disown` so `/clear`/`/exit` return instantly, and survives SIGHUP when the parent dies mid-summary.
- **Config resolution** (in `resolve-config.sh`): JSON files merged low→high: built-in defaults → user-level (`${XDG_STATE_HOME:-~/.local/state}/obsidian-chronicle/obsidian-chronicle.json`) → project (`.claude/obsidian-chronicle.json`, found by walking up from cwd, never above `$HOME`). `vaultPath` is special — resolved from project → user → `obsidian vault` CLI → else `source: none` (and the hook skips, never guessing). Values read with `jq -r` (never `eval`/`source`). Relative `sessionsDir`/`dailyDir` are joined to the resolved `vaultPath`.
- **Conversation extraction** (`extract_conversation`): a `jq` filter keeps only user/assistant prose, drops `isMeta` turns and this plugin's own slash-command noise, and collapses tool I/O to `[tool_use: X]` / `[tool_result]` markers. Shrinks ~1 MB transcripts to ~14%.
- **Resume dedup + slicing:** notes carry `session_id` and `transcript_anchor` (uuid of the last covered prose event) in frontmatter. A resumed session is found by grepping the vault for its `session_id`; the transcript is then sliced to events *after* the anchor and an addendum is appended instead of writing a duplicate. Anchor missing/compacted → graceful fallback to full transcript.
- **Marker-based LLM output:** the prompt makes `claude -p` emit flat `@@TITLE@@` / `@@BODY@@` / etc. sections; the script (`extract_marker`) reassembles the final note. The script owns frontmatter/H1/callout scaffolding — the LLM only fills semantic content. There's a one-shot retry if the first byte isn't the expected marker, and an explicit `SKIP` escape hatch for empty sessions.
- **Per-session lock:** `~/.claude/session-summary.<id>.lock` via atomic `mkdir` (5-min stale sweep) prevents PreCompact + `/done` + SessionEnd racing for one `session_id`.

### Transcript resolution in done-runner.sh

`/done` has no hook payload, so it must find the transcript itself. Resolution order: (1) `$CLAUDE_SESSION_ID` → `<proj-dir>/<id>.jsonl`; (2) Claudian GUI: newest `<vault>/.claudian/sessions/*.meta.json` by `lastResponseAt` → its `sessionId`; (3) newest `*.jsonl` in the computed project dir. The cwd→dir mapping reproduces Claude Code's exact encoding: `path.replace(/[^a-zA-Z0-9]/g, "-")` (every non-alphanumeric char → `-`, no run-collapsing).

## Development

No build, no test suite. You test by firing the hook with a synthetic payload and watching the log.

```bash
# Simulate SessionEnd (point transcript_path at a real .jsonl)
echo '{"session_id":"test","transcript_path":"/path/to/real.jsonl","cwd":"/tmp","reason":"clear"}' \
  | hooks/session-summary.sh

# Simulate /done (auto-finds the current session's transcript)
hooks/done-runner.sh

# The single source of truth for what happened — hooks swallow all stdout/stderr:
tail -f ~/.local/state/obsidian-chronicle/process.log
```

The summarization prompts are inlined in `session-summary.sh` — search for `PROMPT='You are summarizing` (new-session path) and `PROMPT='You are extending` (resume path). Edit, save, re-fire; no build step. The JSON config is re-resolved on every fire, so config changes take effect immediately.

The resolver has unit tests: `bash tests/test-resolve-config.sh` (sandboxed HOME/XDG, stubbed `obsidian` CLI — no network, no real vault).

## Hard constraints

- **Bash 3.2 (macOS system default).** No associative arrays. Use `printf -v` and `${!var}` indirect references — see existing patterns. JSON work is done with `jq` rather than shell parsing.
- **Vault paths often contain spaces, `@`, and live on cloud storage** (e.g. Google Drive). Always quote paths; never rely on file mtime for "most recent" (cloud sync rewrites it — use Obsidian/payload timestamps instead). Glob directly rather than parsing `ls`.
- **Never write garbage notes.** The pipeline must skip (log + exit 0) rather than write on any failure: empty/oversized conversation, `claude -p` error strings, missing markers. Preserve this fail-safe posture when editing.
- **Hooks must exit fast and never block the user.** Real work goes in the detached subshell.

## The obsidian-vault agent

`agents/obsidian-vault.md` resolves the vault at the start of every task via `resolve-config.sh "$PWD" | jq -r .vaultPath` (no hardcoded path), then defers to `$VAULT/.obsidian/vault-rules.md` (the *vault's* own rules doc) as the source of truth for folder structure, placement rules, and naming conventions — it reads it first on every vault task. The agent itself stays generic; per-vault conventions live in `vault-rules.md`, not in the agent definition. It routes file operations to the kepano **`obsidian:`** skills (`obsidian-markdown`, `json-canvas`, `obsidian-bases`, `obsidian-cli`, `defuddle`) rather than generic file tools, and renames/moves notes **through the `obsidian` CLI** (never `mv`) to preserve wikilinks. It does *not* reimplement session logging — that's owned by this plugin's hooks/`/done`.
