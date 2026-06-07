# How obsidian-chronicle compares

A few Claude Code plugins touch session logging, journaling, or Obsidian — but
they mostly solve *different* problems. Here's the map.

## At a glance

| Capability | **chronicle** | session-logger | timelog | dev-journal | claude-sessions | obsidian-claude-code |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| Runs automatically (hooks) | ✅ | ✅ | ✅ | — | — | — |
| AI-written prose summary | ✅ | — | — | 🟡 | — | — |
| Writes into Obsidian Daily Notes | ✅ | — | — | — | — | — |
| Resume-aware (no duplicate notes) | ✅ | — | — | — | — | — |
| Semantic frontmatter (task/research) | ✅ | — | — | — | — | — |
| Per-tool audit trail | — | ✅ | — | — | — | — |
| Time / billing metrics | — | — | ✅ | — | — | — |
| Visual timeline in Obsidian | — | — | — | — | ✅ | — |
| Chat inside Obsidian | — | — | — | — | — | ✅ |

<sub>✅ built-in · 🟡 manual · — not what it's for</sub>

## The plugins

| Plugin | In one line |
|---|---|
| **obsidian-chronicle** (this) | Auto AI summaries → Obsidian notes + Daily Notes, resume-aware |
| [claude-session-logger](https://github.com/DazzleML/claude-session-logger) | Real-time per-tool audit log to `~/.claude/sesslogs/` |
| [claude-code-timelog](https://github.com/RemoteCTO/claude-code-timelog) | Time tracking for billing / invoicing |
| [dev-journal](https://github.com/juliuszfedyk/dev-journal) | Manual `/journal` decision entries committed to your repo |
| [claude-sessions](https://github.com/gapmiss/claude-sessions) | Obsidian plugin that renders `.jsonl` as visual timelines |
| [obsidian-claude-code](https://github.com/Roasbeef/obsidian-claude-code) | Claude as a chat sidebar inside Obsidian |

## TL;DR

chronicle is the only one that turns finished sessions into **AI-written Obsidian
notes wired into your Daily Notes**, and the only one that folds a resumed session
back into its original note instead of duplicating it.

It's not a logger or a time tracker, and doesn't try to be. A power user runs
three side by side: **chronicle** for journaling, **timelog** for invoicing,
**session-logger** for incident replay.

## Roadmap

Nice-to-haves that would close the gaps above:

- Frontmatter metrics — `duration_minutes`, `prompt_count`, `model_used`
- Optional parallel JSONL event log — covers the crash-before-`SessionEnd` case
- Per-classification prompt/model overrides — detailed for `task`, terse for chat
- Inactivity auto-checkpoint — hands-off fix for "the VS Code session never ends"

---

<sub>Research: 2026-05-29. Sources:
[session-logger](https://github.com/DazzleML/claude-session-logger) ·
[timelog](https://github.com/RemoteCTO/claude-code-timelog) ·
[dev-journal](https://github.com/juliuszfedyk/dev-journal) ·
[claude-sessions](https://github.com/gapmiss/claude-sessions) ·
[obsidian-claude-code](https://github.com/Roasbeef/obsidian-claude-code) ·
[Hooks reference](https://code.claude.com/docs/en/hooks)</sub>
