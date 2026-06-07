<div align="center">

# 📓 obsidian-chronicle

**Auto-write structured Obsidian notes from every Claude Code session.**

[Quickstart](#-quickstart) · [How it works](#-how-it-works) · [Reliability](#-reliability) · [Configuration](#-configuration) · [Comparison](COMPARISON.md)

![bash](https://img.shields.io/badge/bash-3.2%2B-89e051) ![claude--code](https://img.shields.io/badge/claude--code-%E2%89%A52.1-d97757) ![license](https://img.shields.io/badge/license-MIT-blue) ![status](https://img.shields.io/badge/status-stable-success)

</div>

---

## What it does

You end a Claude Code session — `/clear`, `/new`, `/obsidian-chronicle:done`, quit, or auto-compact. Seconds later, a structured Markdown note appears in your Obsidian vault, and today's Daily Note grows by one line. No clicks. No manual journaling.

```markdown
─── <Vault>/02_Sessions/Wire SessionEnd hook to Obsidian.md ───

---
title: Wire SessionEnd hook to Obsidian
description: Built a SessionEnd hook that writes Obsidian summaries and Daily Note entries.
classification: task
keywords: claude-code, hooks, obsidian, automation
session_id: 65a0ebe9-92e4-4c96-aa73-8b5109b2cb2f
transcript_path: ~/.claude/projects/-Users-you-dev-foo/65a0ebe9-...jsonl
cwd: /Users/you/dev/foo
end_reason: clear
tags: [claude-session]
---

# Wire SessionEnd hook to Obsidian

## Goal
Auto-generate journal-style summaries when each Claude Code session ends.

## Key Decisions
- Use SessionEnd over Stop (Stop fires every turn)
- Pipe transcript JSONL to `claude -p` after extracting only user/assistant text
- ...

## Files Changed
- `hooks/session-summary.sh` — main writer
- `.claude-plugin/plugin.json` — register the hook

## Outcome
Hook fires reliably; verified with synthetic payload and live sessions.
```

```markdown
─── <Vault>/02_Sessions/Daily Notes/2026-05-29.md (appended) ───

## ✅ Wire SessionEnd hook to Obsidian — [[Wire SessionEnd hook to Obsidian]]

Built a SessionEnd hook that writes Obsidian summaries and Daily Note entries.
```

Research sessions get `🔍 + **Keywords:** + #research` for searchability. Resumed sessions append an `## Resumed YYYY-MM-DD HH:MM` block to the same note instead of creating a duplicate.

---

## Features

|   |   |
|---|---|
| 🎯  **Triggered by hooks, not memory** | Deterministic. Fires on `SessionEnd`, `PreCompact`, or the `/obsidian-chronicle:done` slash command. |
| 🧹  **Conversation-only extraction** | Strips JSONL scaffolding via `jq`. 1 MB transcripts → ~140 KB. Tool I/O is reduced to one-line markers. |
| 🔁  **Resume-aware dedup** | Same `session_id` → addendum, never a duplicate note. |
| 🎚️  **Manual checkpoint mid-session** | `/obsidian-chronicle:done` queues a summary in the background — one Bash call + one-line confirmation, then nothing more. |
| 🪪  **Frontmatter properties** | `title`, `description`, `classification`, `keywords`, `session_id`, `transcript_path`, `cwd`. Queryable in Obsidian Bases. |
| 🛡️  **Hardened** | Recursion guard, SIGHUP survival, summary validation. Won't write garbage notes even if `claude -p` errors. |

---

## 🚀 Quickstart

**Requirements:** Claude Code ≥ 2.1, `jq`, `bash` 3.2+, an Obsidian vault. macOS / Linux.

### 1. Get the plugin

```bash
git clone https://github.com/<you>/claude-obsidian-chronicle ~/dev/claude-obsidian-chronicle
```

### 2. Register it in `~/.claude/settings.json`

```jsonc
{
  // Merge with what you already have:
  "extraKnownMarketplaces": {
    "obsidian-chronicle": {
      "source": {
        "source": "directory",
        "path": "/Users/YOU/dev/claude-obsidian-chronicle"
      }
    }
  },
  "enabledPlugins": {
    "obsidian-chronicle@obsidian-chronicle": true
  }
}
```

### 3. Restart Claude Code and configure

```
claude
> /obsidian-chronicle:setup
```

The setup command asks where your vault is and writes a `.env` file. **That's it.**

Every session you end (`/clear`, `/new`, `/obsidian-chronicle:done`, quit) now auto-writes a summary into `<vault>/02_Sessions/` and appends a line to today's Daily Note.

---

## 🪝 Triggers

| Trigger | Fires when | Use it for |
|---|---|---|
| `/clear` · `/new` | You explicitly start over | Day-to-day default. `/new` is an alias for `/clear`. |
| `/obsidian-chronicle:done` | Mid-session, anywhere | Checkpoint without ending. One Bash call + `✓ Summary queued.` line, then silence. |
| Auto-compact | Context near limit | Nothing to do — it just happens. |
| Quit / exit | CLI closes normally | Captures the last work before you leave. |

| Does **not** trigger |
|---|
| `kill -9` on the CLI process — no hook can run. |
| Closing the VS Code chat panel without `/clear` — the session stays alive. Use `/obsidian-chronicle:done`. |
| Idle disconnect — Claude Code keeps the session resumable; no hook fires. |

> **GUI front-ends (Claudian, etc.)** embed the real `claude` CLI, so their
> conversation transcripts land in the standard `~/.claude/projects/…` location —
> `.claudian/sessions/` holds only lightweight metadata, not the conversation.
> `SessionEnd` works unchanged (Claude Code passes the exact `transcript_path`).
> For `/obsidian-chronicle:done`, `done-runner.sh` resolves the transcript in this
> order: (1) `CLAUDE_SESSION_ID` if exported; (2) for Claudian, the most-recently-
> active conversation in `<vault>/.claudian/sessions/*.meta.json` → its `sessionId`;
> (3) the newest transcript in the project dir. The cwd→dir mapping uses Claude
> Code's exact encoding (`[^a-zA-Z0-9]` → `-`), so vaults on paths with `@`, spaces,
> or other special characters resolve correctly.
>
> *Caveat:* with `CLAUDE_SESSION_ID` absent, step 2 picks the conversation with the
> latest `lastResponseAt`. If you keep **multiple Claudian conversations open in one
> vault**, `/done` summarizes whichever responded most recently — usually, but not
> guaranteed to be, the one you're looking at. `SessionEnd` has no such ambiguity.

---

## ⚙️ How it works

Three hooks → one script → one note + one Daily Note line.

```
   /clear   /new   exit       /obsidian-chronicle:done       context-near-limit
        \      |      /                  |                           |
         \     |     /                   |                           |
       ╔══════════════╗         ╔════════════════════╗     ╔════════════════╗
       ║  SessionEnd  ║         ║   slash command    ║     ║   PreCompact   ║
       ╚══════╤═══════╝         ╚═════════╤══════════╝     ╚════════╤═══════╝
              │                           │                          │
              │              ┌────────────▼────────────┐             │
              │              │   commands/done.md      │             │
              │              │   → done-runner.sh      │             │
              │              │   finds session JSONL   │             │
              │              └────────────┬────────────┘             │
              │                           │                          │
              └───────────────────────────┼──────────────────────────┘
                                          ▼
                          ╔═══════════════════════╗
                          ║  session-summary.sh   ║   the one writer
                          ╚═══════════╤═══════════╝
                                      │
                ┌─────────────────────┼─────────────────────┐
                ▼                     ▼                     ▼
        load 3-tier .env      extract conversation     dedup by session_id
        (plugin→project       jq strips JSONL          search frontmatter
         →shell env)          ~14% of raw size         in vault
                                      │
                                      ▼
                                  claude -p
                              (model = haiku)
                                      │
                          ┌───────────┴───────────┐
                          ▼                       ▼
                   <Title>.md              Daily Notes/
                   structured summary      YYYY-MM-DD.md
                   with frontmatter        ✅ task · 🔍 research
```

### The conversation extraction step

The summarizer never sees raw JSONL. `extract_conversation()` keeps only what matters:

```jq
select(.type == "user" or .type == "assistant")
| .message as $m
| ($m.content | if type == "string" then .
   else [.[] | if .type == "text"        then .text
              elif .type == "tool_use"   then "[tool_use: " + .name + "]"
              elif .type == "tool_result" then "[tool_result]"
              else empty end] | join("\n") end)
| "### " + ($m.role | ascii_upcase) + "\n" + . + "\n"
```

|   | Before | After |
|---|---:|---:|
| Avg transcript size | 1,190 KB | **167 KB** |
| Dropped: `queue-operation`, `attachment`, `last-prompt`, `file-history-snapshot` |  |  |
| Tool I/O collapsed to `[tool_use: Bash]` / `[tool_result]` markers |  |  |

This is what makes the plugin **never** hit Haiku's context window in practice, even after 100+ turn sessions.

---

## 🛡️ Reliability

The wall between "this plugin sometimes silently breaks" and "this plugin is something you can leave running for months":

| Safeguard | Threat it defends against |
|---|---|
| **Recursion guard** (`CLAUDE_OBSIDIAN_CHRONICLE_RUNNING=1` exported to children) | `claude -p` spawns its own Claude session → SessionEnd → recursion → context overflow. Guard short-circuits the inner hook. |
| **Headless detection** (cwd in `~/.claude/*` or first user message contains `<local-command-caveat>`) | Belt-and-suspenders fallback for the recursion guard if env vars are stripped. |
| **`trap '' HUP` inside the worker subshell** | User quits Claude Code while `claude -p` is mid-summary → parent dies → SIGHUP cascades. We ignore it; summary completes. |
| **Per-session lock** (`~/.claude/session-summary.<id>.lock`, 5-min stale) | PreCompact + manual `/done` + SessionEnd racing for the same `session_id`. |
| **Conversation size gate** (200 B – 200 KB after extraction) | Empty "open window then close" sessions → no note. Pathologically huge transcripts → skip rather than write garbage. |
| **Output validation** (exit code, frontmatter delimiter, H1 presence, known error strings) | `claude -p` returns `"Prompt is too long"` or `"Error: ..."` → we detect and skip. **No more `Untitled session.md`.** |
| **`printf -v` for `.env` values** | Project `.env` containing `OBSIDIAN_SESSIONS_DIR="$(rm -rf /)"` is treated as a literal string. |
| **Only `OBSIDIAN_*` keys parsed** | A shared repo `.env` with `DB_PASSWORD` is safely ignored — never exported, never logged. |

---

## 🔧 Configuration

### Interactive

```
/obsidian-chronicle:setup
```

Asks where to save the `.env` (plugin-wide or this project only) and walks through the settings.

### Manual

```bash
cp ~/dev/claude-obsidian-chronicle/.env.example ~/dev/claude-obsidian-chronicle/.env
$EDITOR ~/dev/claude-obsidian-chronicle/.env
```

### Precedence

```
                       lowest                                          highest
   built-in defaults  →  <plugin-root>/.env  →  $CWD/.env  →  shell env vars
```

Tilde (`~/foo`) and `$HOME/foo` both work.

### Keys

| Variable | Default | Purpose |
|---|---|---|
| `OBSIDIAN_SESSIONS_DIR` | `~/obsidian/02_Sessions` | Where session notes go |
| `OBSIDIAN_DAILY_DIR` | `<sessions-dir>/Daily Notes` | Where Daily Notes live |
| `OBSIDIAN_CHRONICLE_MODEL` | `haiku` | Model passed to `claude -p` (`haiku` · `sonnet` · `opus`) |
| `OBSIDIAN_CHRONICLE_LOG` | `~/.claude/session-summary.log` | Append-only hook activity log |
| `OBSIDIAN_CHRONICLE_MIN_BYTES` | `200` | Skip if extracted conversation is smaller |
| `OBSIDIAN_CHRONICLE_MAX_BYTES` | `200000` | Skip if extracted conversation is larger |

---

## 🩺 Troubleshooting

The single source of truth is the hook log:

```bash
tail -f ~/.claude/session-summary.log
```

| Log line | Meaning | Action |
|---|---|---|
| `wrote <path> [class=task, new]` | ✓ Healthy. New summary written. | — |
| `appended <path> [class=task, resumed]` | ✓ Healthy. Addendum added to existing note. | — |
| `skip: empty/trivial conversation (<200B)` | Session had no real content. | Expected after opening a window and closing without working. |
| `skip: in-progress lock held` | Another hook for this session is already summarizing. | Wait or `rm ~/.claude/session-summary.<id>.lock`. |
| `skip: headless cwd` / `skip: headless session marker` | The recursion / headless guards caught an internal `claude -p` session. | Expected. Means safeguards are working. |
| `skip: no transcript` | Hook input had no `transcript_path`. | Should not happen with normal Claude Code; check the hook payload. |
| `fail: claude -p exit=N (summary, ...)` | `claude -p` returned non-zero. | Check `claude` binary in PATH, model name in `.env`, network. |
| `fail: summary missing frontmatter (head: ...)` | `claude -p` returned something that isn't a summary. | Often a transient model glitch. Will work next time. |
| `fail: summary rejected — looks like a claude -p error: Prompt is too long...` | Extraction didn't shrink it enough, or model errored. | Raise `OBSIDIAN_CHRONICLE_MAX_BYTES`, or try `OBSIDIAN_CHRONICLE_MODEL=sonnet`. |

The plugin auto-loads `.env` on every hook fire, so config changes take effect immediately — no Claude restart needed.

---

## 🗑️ Uninstall

```bash
# 1. Edit ~/.claude/settings.json — delete the obsidian-chronicle entries
#    from `enabledPlugins` and `extraKnownMarketplaces`.

# 2. Remove the plugin directory
rm -rf ~/dev/claude-obsidian-chronicle

# 3. Optional: clear runtime files
rm -f ~/.claude/session-summary.log ~/.claude/session-summary.*.lock
```

Your existing summary notes stay where they are.

---

## 🧪 Development

### Layout

```
claude-obsidian-chronicle/
├── .claude-plugin/
│   ├── plugin.json          # hook registrations (SessionEnd, PreCompact)
│   └── marketplace.json     # single-plugin marketplace
├── commands/
│   ├── setup.md             # /obsidian-chronicle:setup
│   └── done.md              # /obsidian-chronicle:done
├── hooks/
│   ├── session-summary.sh   # ~350 lines — the one writer
│   └── done-runner.sh       # ~40 lines — backs /done
├── .env.example
├── .gitignore               # .env, *.log, *.lock
├── COMPARISON.md            # field survey + roadmap
└── README.md
```

### Run a hook manually

Hooks read JSON from stdin. Pipe a synthetic payload to test in isolation:

```bash
# Simulate SessionEnd
echo '{"session_id":"test","transcript_path":"/path/to/real.jsonl","cwd":"/tmp","reason":"clear"}' \
  | ~/dev/claude-obsidian-chronicle/hooks/session-summary.sh

# Simulate /obsidian-chronicle:done (auto-finds the current session's transcript)
~/dev/claude-obsidian-chronicle/hooks/done-runner.sh
```

Both detach and return instantly. Watch progress with `tail -f ~/.claude/session-summary.log`.

### Tune the summarization prompt

It's inlined in [`hooks/session-summary.sh`](hooks/session-summary.sh). Search for:
- `PROMPT='You are summarizing` — new-session path
- `PROMPT='You are extending` — resume path

Edit, save, fire a hook. No build step.

### Bash compatibility

Targeted at macOS bash 3.2 (system default). No associative arrays. Uses `printf -v` and `${!var}` indirect references.

---

## 📊 How this compares to other plugins

The full field survey lives in [COMPARISON.md](COMPARISON.md). Short version:

| Plugin | Surface |
|---|---|
| `claude-session-logger` | Per-tool audit trail. No summarization. |
| `claude-code-timelog` | Billing / time tracking. No prose summary. |
| `dev-journal` | Manual decision journaling via slash command. |
| `obsidian-claude-code` | Claude-as-sidebar inside Obsidian. Not a logger. |
| **`obsidian-chronicle`** | **Auto AI-written summaries → Obsidian Daily Notes with resume dedup.** |

The niche is the combination — nobody else does *automatic + Obsidian-flavored + resume-aware*.

---

## 📜 License

MIT. See [LICENSE](LICENSE) if present, otherwise assume MIT.
