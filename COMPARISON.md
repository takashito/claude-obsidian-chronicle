# obsidian-chronicle vs. the field

Research date: 2026-05-29. Where this plugin fits relative to other Claude Code plugins doing session logging, journaling, or Obsidian integration.

## Comparable plugins found

| Plugin | What it does | Hooks used | Output | Distinctive |
|---|---|---|---|---|
| **[claude-session-logger](https://github.com/DazzleML/claude-session-logger)** | Real-time monitoring, auto-naming, tool tracking, command history. Logs to `~/.claude/sesslogs/`. | `SessionStart`, `PostToolUse` | `.log` files + JSONL transcript symlinks | Granular per-tool logging; no summarization |
| **[claude-code-timelog](https://github.com/RemoteCTO/claude-code-timelog)** | Automatic time tracking for billing/invoicing. Extracts project/ticket metadata. | `SessionStart`, `UserPromptSubmit`, `SessionEnd` | JSONL (one file/day) | Time + billable metrics, not summaries |
| **[dev-journal](https://github.com/juliuszfedyk/dev-journal)** | Project-local decision journaling via `/journal` command. Integrates into CLAUDE.md. | none (skill-based) | `docs/journal/YYYY-MM-DD--NNN-short-description.md` | Manual entry; architectural focus |
| **[Claude Sessions (Obsidian plugin)](https://github.com/gapmiss/claude-sessions)** | Reads `.jsonl` session files, renders as interactive timelines in Obsidian. | none (reads existing files) | Visual timeline + optional Markdown export | Viewer, not logger |
| **[obsidian-claude-code](https://github.com/Roasbeef/obsidian-claude-code)** | Embeds Claude as a sidebar assistant in Obsidian via the Agent SDK. | none (Agent SDK) | In-vault conversation state | Real-time chat, not journaling |

**Gap in the ecosystem:** none of these combine hook-triggered automatic summarization with Obsidian-specific formatting (daily notes, wikilinks, dedup by session_id). That's the gap `obsidian-chronicle` fills.

## What obsidian-chronicle does better

1. **Automatic structured summarization at session boundaries.** SessionEnd + PreCompact + `/done` → LLM-written summary with frontmatter and standard sections. Competitors capture raw logs (`claude-session-logger`) or require manual entry (`dev-journal`).
2. **Daily Note integration.** Appends `## ✅ <Title> — [[wikilink]]` (task), `## 🔍 ... **Keywords:** #research` (research), or plain (other) to `Daily Notes/YYYY-MM-DD.md`. No other plugin does this.
3. **Resume-aware dedup by `session_id`.** Resumed sessions get an `## Resumed YYYY-MM-DD HH:MM` addendum block on the existing note, not a duplicate.
4. **`/done` as a hidden checkpoint.** UserPromptSubmit interceptor fires the summary in background and blocks the prompt from reaching the model — no visible turn, no context pollution.
5. **Semantic classification in frontmatter.** `classification: task | research | other` enables Obsidian queries / Bases views.
6. **Safe JSON config.** User-level → project precedence (merged key-by-key); parsed with `jq` and read with `jq -r`, never `eval`/`source`, so values can't execute. `vaultPath` resolves from config → `obsidian vault` CLI → else skip (never guesses a path).

## What's missing or worth improving

1. **No real-time event log.** A session that crashes mid-work leaves nothing — `claude-session-logger` covers this via `PostToolUse`. Adding an optional JSONL audit trail (cheap, runs alongside summarization) would close this gap.
2. **No metrics in frontmatter.** `claude-code-timelog` captures duration, prompt count, model used. Adding `duration_minutes`, `prompt_count`, `model_used` to the frontmatter would make notes more queryable in Obsidian Bases.
3. **No tool-call audit trail.** Outcomes are summarized in prose; which tools ran in what order is lost. A condensed `tool_calls:` frontmatter array would help debugging.
4. **No per-classification summarization knobs.** Currently one model + one prompt for every session. Could let `task` use a more detailed prompt and `other` use a terse one. Same with model choice per classification.
5. **VS Code "session never ends" — only partial fix.** `/done` is manual. An inactivity-triggered auto-checkpoint (e.g., a periodic launchd timer that scans transcripts modified > N min ago without a summary) would make this hands-off.
6. **No back-link to the raw transcript.** The full JSONL transcript still exists at `~/.claude/projects/...` but the summary note doesn't reference it. Adding a `transcript_path:` frontmatter field would let users jump from summary → raw if they want detail.
7. **No cost / token estimate.** `claude-code-timelog` infers tokens. A rough estimate in the summary would help users decide whether to upgrade the summarization model.

## Patterns worth borrowing

- **JSONL as durable intermediate format** (from `claude-session-logger`, `claude-code-timelog`). Cheap to write, easy to grep/query later.
- **One file per day for events** (timelog pattern). Pairs well with the per-session Markdown summary.
- **`PostToolUse` for audit granularity** (logger pattern). Optional add-on hook.

## Verdict

`obsidian-chronicle` fills a real, unoccupied niche: the only plugin doing automatic AI-written summaries → Obsidian Daily Notes with resume awareness. It is **not** a replacement for `claude-session-logger` (granular audit) or `claude-code-timelog` (billing). A power user would run all three: chronicle for daily summaries, timelog for invoicing, logger for incident replay.

Highest-leverage next improvements, in order:

1. Add `duration_minutes`, `prompt_count`, `model_used`, `transcript_path` to frontmatter — low effort, high search/filter value.
2. Optional parallel JSONL event log — closes the "crash before SessionEnd" gap.
3. Per-classification prompt + model overrides — better summaries for tasks without paying Sonnet/Opus for chat.
4. Inactivity-triggered launchd timer — finally solves the VS Code "session never closes" problem hands-off.

## Sources

- [claude-session-logger](https://github.com/DazzleML/claude-session-logger)
- [claude-code-timelog](https://github.com/RemoteCTO/claude-code-timelog)
- [dev-journal](https://github.com/juliuszfedyk/dev-journal)
- [Claude Sessions (Obsidian plugin)](https://github.com/gapmiss/claude-sessions)
- [obsidian-claude-code](https://github.com/Roasbeef/obsidian-claude-code)
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide)
- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
