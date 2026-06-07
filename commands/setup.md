---
description: Configure obsidian-chronicle by generating an obsidian-chronicle.json (user-level or per-project)
allowed-tools: Read, Write, Bash, AskUserQuestion
---

The user wants to configure the `obsidian-chronicle` plugin. Your job: generate an `obsidian-chronicle.json` file in either the **user-level state dir** (the machine-wide default) or the **current project** (applies only when Claude Code runs under that project tree).

Config is JSON only. The shared resolver `hooks/resolve-config.sh` reads these files; understand its model before writing:

- **Locations (project overrides user, key-by-key):**
  - user-level: `${XDG_STATE_HOME:-$HOME/.local/state}/obsidian-chronicle/obsidian-chronicle.json`
  - project: nearest `.claude/obsidian-chronicle.json` found walking up from cwd (not `$HOME` itself)
- **Merge:** built-in defaults ← user JSON ← project JSON.
- **`vaultPath`:** resolved from project → user → `obsidian vault` CLI → else nothing is written (the hook skips). No silent `~/obsidian` fallback.
- **Relative `sessionsDir`/`dailyDir`** are resolved against `vaultPath`; a value starting with `/` or `~` is absolute.

# Steps (follow in order, do not skip)

## 1. Resolve the plugin root and the two candidate destinations

```bash
PLUGIN="${CLAUDE_PLUGIN_ROOT:-$(jq -r '.extraKnownMarketplaces["obsidian-chronicle"].source.path // empty' "$HOME/.claude/settings.json" 2>/dev/null)}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
USER_DEST="$STATE_HOME/obsidian-chronicle/obsidian-chronicle.json"
PROJECT_DEST="$(pwd)/.claude/obsidian-chronicle.json"
echo "plugin=$PLUGIN"; echo "user=$USER_DEST"; echo "project=$PROJECT_DEST"
```

If `$PLUGIN` is empty, abort: tell the user to install/register the plugin first.

## 2. Detect a default vault path

```bash
command -v obsidian >/dev/null 2>&1 && obsidian vault 2>/dev/null | awk -F'\t' '$1=="path"{print $2}'
```

Whatever this prints is the **recommended `vaultPath`**. If it prints nothing (no `obsidian` CLI, or Obsidian not running), fall back to suggesting `~/obsidian` and tell the user to confirm/edit it.

## 3. Ask where to save

Use AskUserQuestion (single-select):

- **User-level** (`<USER_DEST>`) — machine-wide default. Recommended. Used for "one vault per computer".
- **This project** (`<PROJECT_DEST>`) — applies only under this project tree. Overrides the user-level file key-by-key. Used for a project-local vault / project wiki.

## 4. Check for an existing config at the chosen location

If the chosen file already exists:
- Read it and show its current JSON.
- Use AskUserQuestion: **Update** / **Cancel**.
- On update, you will merge: keep keys the user doesn't change.

## 5. Gather settings via AskUserQuestion (4 settings — one batched call)

For each, default = existing value at the chosen file → built-in default. Ask the `sessionsDir` default first so you can present `<sessionsDir>/Daily Notes` as the recommended `dailyDir`.

1. **Vault path** (`vaultPath`) — Header: `Vault`. Options: the detected path from step 2 (recommended), `~/obsidian`. (Other = type a path.)
2. **Sessions dir** (`sessionsDir`) — Header: `Sessions`. Relative to the vault. Options: `Sessions` (recommended), `02_Sessions`. (Other = type a path.)
3. **Daily Notes dir** (`dailyDir`) — Header: `Daily Notes`. Relative to the vault (where the per-day Daily Note lines are appended). Options: `<sessionsDir>/Daily Notes` (recommended — the built-in default, nested under the chosen Sessions dir), `Daily Notes` (at the vault root). (Other = type a path.)
4. **Language** (`language`) — Header: `Language`. The language notes are written in (summary, title, section headings). Options: `English` (recommended / built-in default), `Japanese`. (Other = type a language name verbatim, e.g. `Français`.) Passed verbatim into the summarization prompt.

`model` and `log` are NOT asked — they fall back to built-in defaults (`sonnet`, and `~/.local/state/obsidian-chronicle/process.log`). To override either, edit the JSON afterward (mention this).

If the user picks "Other", take their string verbatim. Do NOT expand `~` (the resolver handles tildes).

## 6. Write the file

Create the parent directory, then write JSON with `jq` so quoting/escaping is correct.

**New file:**
```bash
mkdir -p "$(dirname "$DEST")"
jq -n \
  --arg vaultPath   "$VAULTPATH" \
  --arg sessionsDir "$SESSIONSDIR" \
  --arg dailyDir    "$DAILYDIR" \
  --arg language    "$LANGUAGE" \
  '{vaultPath:$vaultPath, sessionsDir:$sessionsDir, dailyDir:$dailyDir, language:$language}' \
  > "$DEST"
```

(Include `model` or `log` only if the user explicitly asked to set a custom one.)

**Updating an existing file** — merge so unspecified keys survive:
```bash
TMP="$(mktemp)"
jq --arg vaultPath "$VAULTPATH" --arg sessionsDir "$SESSIONSDIR" --arg dailyDir "$DAILYDIR" --arg language "$LANGUAGE" \
   '. * {vaultPath:$vaultPath, sessionsDir:$sessionsDir, dailyDir:$dailyDir, language:$language}' "$DEST" > "$TMP" && mv "$TMP" "$DEST"
```

## 7. Confirm

```bash
echo "✓ wrote $DEST"
"$PLUGIN/hooks/resolve-config.sh" "$(pwd)"
```

Show the user:
- `✓ wrote <DEST>`.
- The resolver's output (the **resolved absolute** `sessionsDir`, `dailyDir`, `log`, and `source`) so they can confirm notes will land where they expect.
- If `source` is `none`, warn that no vault was resolved — they must set `vaultPath`.
- Precedence note: project overrides user-level key-by-key; takes effect on the next hook fire (SessionEnd, PreCompact, or `/done`) — no restart needed.

# Rules

- Be terse. No long explanations of what the plugin does.
- Only write the chosen JSON file. Don't touch any other file.
- Use answers verbatim; don't expand `~`.
