<div align="center">

# 📓 obsidian-chronicle

**Every Claude Code session, auto-written as a structured Obsidian note + a Daily Note line.**

📖 English · [日本語](docs/README.ja.md)

![bash](https://img.shields.io/badge/bash-3.2%2B-89e051)
![claude--code](https://img.shields.io/badge/claude--code-%E2%89%A52.1-d97757)
[![CI](https://github.com/takashito/claude-obsidian-chronicle/actions/workflows/ci.yml/badge.svg)](https://github.com/takashito/claude-obsidian-chronicle/actions/workflows/ci.yml)
![license](https://img.shields.io/badge/license-MIT-blue)

<br>

<img src="docs/assets/demo-en.gif" alt="obsidian-chronicle demo: ending a Claude Code session writes a structured Obsidian note and a Daily Note line; resuming appends to the same note, no duplicate" width="840">

</div>

---

End a Claude Code session — `/clear`, `/new`, quit, auto-compact, or `/obsidian-chronicle:done` — and a summary note lands in your vault, with one more line in today's Daily Note. It's summarized in the background (typically ~10–30 s, depending on session length and model), so your CLI is free immediately. No clicks, no manual journaling.

- 🎯 **Hook-triggered, not vibes** — fires on `SessionEnd`, `PreCompact`, and `/done`. Deterministic.
- 🔁 **Resume-aware** — resuming a session appends to the same note (matched by `session_id`), never a dup.
- 🗂️ **Two vault modes** — one user-level vault shared across your machine, or a per-project vault (e.g. a project wiki).
- 🛡️ **Hardened** — recursion guard, survives quit mid-write, skips rather than writing garbage.

## 🚀 Install

obsidian-chronicle is a **Claude Code plugin** — install it from inside Claude Code by running these slash commands:

```
/plugin marketplace add takashito/claude-obsidian-chronicle
/plugin install obsidian-chronicle@obsidian-chronicle
/obsidian-chronicle:setup
```

`setup` auto-detects your vault (via the `obsidian` CLI if you have it), asks user-level vs per-project, and writes the config. That's it.

**Requirements:** Claude Code ≥ 2.1, `jq`, bash 3.2+, an Obsidian vault. **macOS / Linux are supported; Windows is experimental — see below.** The [`obsidian` CLI](https://github.com/yakitrak/obsidian-cli) is optional (vault auto-detect).

<details><summary>🪟 Windows (experimental, best-effort)</summary>

The hooks are bash scripts. Claude Code runs hook commands through **Git Bash** on Windows, so they *can* run there — but this is **not a fully tested platform**. To try it:

- **Install [Git for Windows](https://git-scm.com/download/win)** — it provides `bash` plus the `sed`/`awk`/`grep`/`find` coreutils the scripts need. If `bash.exe` isn't on `PATH`, point Claude Code at it: `setx CLAUDE_CODE_GIT_BASH_PATH "C:\Program Files\Git\bin\bash.exe"`. (Or use **WSL**, which behaves like Linux.)
- **Install `jq`** and make sure it's on `PATH` (Git Bash does not bundle it).
- **Line endings matter.** The repo ships a `.gitattributes` that forces `*.sh` to LF, so a normal checkout is fine. If you hand-edit a hook, keep it LF — a CRLF shebang becomes `bash\r` and the hook silently dies.

> [!WARNING]
> **Untested on Windows:** the summarizer runs in a detached background subshell (`( … ) & disown` + `trap '' HUP`) so it survives you quitting mid-session. That fork/signal behavior is verified on macOS/Linux only; under MSYS/Git Bash the background write may not survive the parent exiting. The hook will *fire*, but whether the note always lands is unverified. Reports/PRs welcome.

</details>

**Update:** `/plugin marketplace update obsidian-chronicle` then `/plugin update obsidian-chronicle@obsidian-chronicle`.

<details><summary>Local / dev install</summary>

```bash
git clone https://github.com/takashito/claude-obsidian-chronicle ~/dev/claude-obsidian-chronicle
```
```jsonc
// ~/.claude/settings.json — merge with what you have
{
  "extraKnownMarketplaces": {
    "obsidian-chronicle": { "source": { "source": "directory", "path": "/Users/YOU/dev/claude-obsidian-chronicle" } }
  },
  "enabledPlugins": { "obsidian-chronicle@obsidian-chronicle": true }
}
```
</details>

## 🪝 Triggers

| Trigger | When |
|---|---|
| `/clear`, `/new`, quit | you end or restart a session |
| auto-compact | context fills up |
| `/obsidian-chronicle:done` | manual mid-session checkpoint (queues in background, one-line ack) |

> [!WARNING]
> Won't fire on `kill -9`, on closing the VS Code panel without `/clear` (use `/done`), or on idle disconnect.

> [!NOTE]
> GUI front-ends (Claudian, etc.) work fine — transcripts still land in `~/.claude/projects/…` and `SessionEnd` gets the exact path. For `/done`, `done-runner.sh` finds the session via `CLAUDE_SESSION_ID` → Claudian metadata → newest transcript.

## ⚙️ How it works

```mermaid
flowchart LR
    A[SessionEnd]:::trig --> S
    B[PreCompact]:::trig --> S
    C["/done"]:::trig --> S
    S["session-summary.sh<br/>(detached subshell)"] --> E["jq extract<br/>~1MB → ~14%"]
    E --> D{"dedup by<br/>session_id"}
    D -->|new| W["claude -p · sonnet"]
    D -->|resumed| W
    W --> N["summary note"]
    W --> L["Daily Note line"]
    classDef trig fill:#d97757,color:#fff,stroke:none;
```

`session-summary.sh` runs the whole thing in a detached background subshell, so your CLI returns instantly:

1. **Resolve config** (`resolve-config.sh`) — vault path, model, dirs.
2. **Extract** — `jq` strips the JSONL to user/assistant prose; tool I/O collapses to `[tool_use: Bash]` markers (~1 MB → ~14%), so it never blows Haiku's context.
3. **Dedup** by `session_id` — fresh note, or an addendum if the session was resumed.
4. **Summarize** with `claude -p`, write the note, append the Daily Note.

## 🔧 Configuration

The quickest way is to run **`/obsidian-chronicle:setup`** inside Claude Code — it auto-detects your vault and writes this file for you. To edit it by hand:

One JSON file. You can place it at either of two levels — copy [`obsidian-chronicle.example.json`](obsidian-chronicle.example.json) as a starting point:

| Scope | Path | Applies to |
|---|---|---|
| **user** | `${XDG_STATE_HOME:-~/.local/state}/obsidian-chronicle/obsidian-chronicle.json` | every project on your machine |
| **project** | `<repo>/.claude/obsidian-chronicle.json` (searched upward from cwd) | just that one repo |

**How settings combine:** built-in defaults are the base, your **user** file overrides those, and a **project** file overrides both — i.e. `defaults → user → project`, last one wins. (You only need to set the keys you want to change.)

**How `vaultPath` is found:** the **project** file is checked first, then the **user** file, then the `obsidian vault` CLI (if installed). If none of those provide a vault, the hook just **skips and writes nothing** — it never guesses a path like `~/obsidian`.

| Key | Default | Notes |
|---|---|---|
| `vaultPath` | _(detected)_ | vault root; absolute or `~` |
| `sessionsDir` | `Sessions` | relative → under the vault |
| `dailyDir` | `<sessionsDir>/Daily Notes` | |
| `model` | `sonnet` | `haiku` · `sonnet` · `opus` |
| `language` | `English` | output language for summary / title / headings; any language name, passed verbatim to the prompt |
| `log` | `~/.local/state/obsidian-chronicle/process.log` | activity log |
| `minBytes` / `maxBytes` | `200` / `1000000` | skip if the extracted convo is smaller / larger |

See what resolves: `hooks/resolve-config.sh "$PWD"`. Config is re-read on every fire — no restart needed.

> [!NOTE]
> **Output language.** Notes are written in **English** by default. Set the `language` config key (e.g. `"language": "Japanese"`) — or pick it during `/obsidian-chronicle:setup` — to fully localize each note: the title (and filename), description, section headings, and callout text are all written in that language. The value is any language name, passed verbatim into the summarization prompt, so anything the model knows works (`"Français"`, `"한국어"`, …). File / function / tool names and code identifiers always stay in English; the note scaffolding is language-agnostic, so switching languages needs no code edits.

## 📊 Comparison

How it compares to other Claude Code journaling tools → **[COMPARISON.md](docs/COMPARISON.md)**. Short version: a few tools write AI summaries into Obsidian too, but chronicle is the hands-off one — a marketplace plugin that's *hook-triggered (nothing to run) and resume-aware*.

## 🛡️ Reliability

Built to run for months without writing junk:

- **Recursion guard** — `claude -p` spawns its own session; a flag stops the inner `SessionEnd` from recursing.
- **Survives quit** — `trap '' HUP` lets the summary finish even if you exit mid-write.
- **Per-session lock** — `PreCompact` + `/done` + `SessionEnd` can't double-write the same session.
- **Skips, never guesses** — empty/oversized convo, `claude -p` errors, or no vault → log + exit, no garbage note.
- **No `eval`** — config is read with `jq -r`; values never execute.

## 🩺 Troubleshooting

```bash
tail -f ~/.local/state/obsidian-chronicle/process.log
```

Every fire logs a `start:` line and a result:

| Line | What it means |
|---|---|
| `start: session=… reason=… source=…` | a fire began |
| `wrote <path> [class=task, new]` | ✓ note written |
| `appended <path> [… resumed]` | ✓ addendum added to an existing note |
| `skip: no vault configured` | run `/obsidian-chronicle:setup`, or set `vaultPath` |
| `skip: empty/trivial conversation` | nothing to summarize (expected) |
| `skip: in-progress lock held` | another fire for this session is already running |
| `fail: claude -p exit=N` | check `claude` in PATH / the `model` value / network |
| `fail: … Prompt is too long` | set `model` to `opus` (1M context), or lower `maxBytes` to skip oversized conversations |

## ❓ FAQ

### How do I automatically save Claude Code sessions to Obsidian?
Install obsidian-chronicle and run `/obsidian-chronicle:setup`. From then on, ending a session (`/clear`, quit, auto-compact, or `/done`) writes a structured note to your vault and a linked line to today's Daily Note — no manual step.

### Does it create a new note every time I resume a session?
No. Resumed sessions are matched by `session_id` and **appended to the same note**, so one task stays one note (no duplicates).

### Is this an Obsidian plugin?
No — it's a *Claude Code* plugin that writes Markdown into your Obsidian vault. You install it via Claude Code's `/plugin`, not Obsidian's community-plugin browser.

### Can it write notes in a language other than English?
Yes. Set the `language` config key (e.g. `"language": "Japanese"`) and the whole note — title, headings, callouts — is written in that language. File/function names stay in English.

### Does it need a daemon, Python, or a build step?
No. Pure bash + jq. macOS/Linux are supported; Windows is experimental.

## 🗑️ Uninstall

```
/plugin uninstall obsidian-chronicle@obsidian-chronicle
/plugin marketplace remove obsidian-chronicle
rm -rf ~/.local/state/obsidian-chronicle   # optional: logs + config
```

Your notes stay where they are.

## 🤝 Contributing

Bug reports, ideas, and PRs welcome — see **[CONTRIBUTING.md](.github/CONTRIBUTING.md)** for the dev/test workflow and the hard constraints (bash 3.2, fail-safe, no `eval`).

## 📜 License

MIT — see [LICENSE](LICENSE).
