# How obsidian-chronicle compares

A few Claude Code tools turn finished sessions into notes or a journal — but
they each cover only *part* of what chronicle does. Here's the map.

## At a glance

<sub>✅ yes · 🟡 partial · — no / not its focus</sub>

| Capability | **chronicle** | daily-patterns-pack | remember.md | dev-journal |
|---|:--:|:--:|:--:|:--:|
| Installable Claude Code plugin (marketplace) | ✅ | — | ✅ | ✅ |
| Automatic — nothing to run | ✅ | — | 🟡 | — |
| AI-written session summary | ✅ | ✅ | ✅ | 🟡 |
| Into Obsidian Daily Notes | ✅ | ✅ | 🟡 | — |
| Resume-aware (folds into the same note) | ✅ | — | 🟡 | — |

Only chronicle is ✅ across the board: a marketplace plugin that writes AI summaries into your Obsidian Daily Notes **automatically** and **dedups resumed sessions**.

## The tools

| Tool | What it is | In one line |
|---|---|---|
| **obsidian-chronicle** (this) | Claude Code plugin | Auto AI summaries → Obsidian notes + Daily Notes, resume-aware |
| [daily-patterns-pack](https://github.com/aplaceforallmystuff/daily-patterns-pack) | skills + agent, copied into `~/.claude` | `/log-to-daily` appends an AI session log to today's daily note (manual) |
| [remember.md](https://github.com/remember-md/remember) | Claude Code plugin | Captures session knowledge into an Obsidian-compatible Markdown vault (incl. `Journal/` daily notes); nudge/manual |
| [dev-journal](https://github.com/juliuszfedyk/dev-journal) | Claude Code plugin | Manual `/journal` decision entries in `docs/journal/` (not Obsidian) |

## TL;DR

> [!IMPORTANT]
> chronicle's niche is being **fully automatic and resume-aware**: a Claude Code hook writes the summary into your Obsidian Daily Notes with nothing to remember, and a resumed session folds back into its original note instead of creating a duplicate.

Writing AI summaries into Obsidian isn't unique — [daily-patterns-pack](https://github.com/aplaceforallmystuff/daily-patterns-pack) and [remember.md](https://github.com/remember-md/remember) do it too — but they need a manual command or a nudge, daily-patterns-pack isn't a marketplace plugin, and none fold a resumed session back into its note. chronicle's whole point is that it's hands-off: install it and the notes just appear.

---

<sub>Researched 2026-06-07. Sources:
[daily-patterns-pack](https://github.com/aplaceforallmystuff/daily-patterns-pack) ·
[remember.md](https://github.com/remember-md/remember) ·
[dev-journal](https://github.com/juliuszfedyk/dev-journal) ·
[Hooks reference](https://code.claude.com/docs/en/hooks)</sub>
