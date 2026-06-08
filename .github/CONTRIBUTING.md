# Contributing to obsidian-chronicle

Thanks for your interest — bug reports, ideas, and PRs are all welcome. This is a small, dependency-light project (pure **bash + `jq`**, no build step), so contributing is quick once you know the few hard rules below.

> New here? [`CLAUDE.md`](../CLAUDE.md) is the deep architecture guide. This file is the short "how to contribute" version.

## Ways to contribute

- **🐛 Report a bug** — open an issue (template below). The single most useful thing you can attach is the relevant slice of `process.log`.
- **💡 Suggest a feature** — open an issue describing the problem you're hitting first, then the proposed solution.
- **🔧 Send a PR** — fixes, docs, new behavior. For anything non-trivial, open an issue first so we can agree on the approach before you write code.
- **🌐 Translations** — the README has an English and a Japanese version (`docs/README.ja.md`); other languages are welcome.

## Project layout

```
.claude-plugin/{plugin,marketplace}.json   manifests
commands/{setup,done}.md                    slash commands
hooks/session-summary.sh                    the writer (the engine, ~660 lines)
hooks/resolve-config.sh                     config resolver (single source of truth for paths)
hooks/done-runner.sh                        backs /done (locates the transcript)
tests/test-resolve-config.sh                unit tests for the resolver
docs/                                        README.ja.md, COMPARISON.md, assets/
```

## Development setup

No build, no install step, no dependencies beyond `jq`, `bash` 3.2+, and the `claude` CLI.

```bash
git clone https://github.com/takashito/claude-obsidian-chronicle
cd claude-obsidian-chronicle
```

### Testing your change

There is no app to run — you exercise the hooks directly and watch the log.

```bash
# 1) Run the resolver unit tests (sandboxed HOME/XDG, stubbed `obsidian` CLI — no network, no real vault)
bash tests/test-resolve-config.sh

# 2) Fire the hook with a synthetic payload (point transcript_path at a real .jsonl)
echo '{"session_id":"test","transcript_path":"/path/to/real.jsonl","cwd":"/tmp","reason":"clear"}' \
  | hooks/session-summary.sh

# 3) Simulate /done (auto-finds the current session's transcript)
hooks/done-runner.sh

# The single source of truth for what happened — hooks swallow all stdout/stderr:
tail -f ~/.local/state/obsidian-chronicle/process.log
```

> [!TIP]
> When testing the writer, point `vaultPath` at a **throwaway vault** (a temp dir via a project-scoped `.claude/obsidian-chronicle.json`) so you never write test notes into a real vault.

The summarization prompts are inlined in `session-summary.sh` (search for `You are summarizing` and `You are extending`). Edit, save, re-fire — config is re-resolved on every fire, so changes take effect immediately.

## Hard constraints (please don't break these)

These are non-negotiable because they keep the plugin safe to run unattended for months:

1. **Bash 3.2 (macOS system default).** No associative arrays, no Bash-4-only syntax. Use `printf -v` and `${!var}` indirect references — follow the existing patterns. Do JSON work with `jq`, not shell string parsing.
2. **Never write a garbage note.** On *any* failure (empty/oversized conversation, a `claude -p` error string, a missing marker, no resolvable vault) the pipeline must **skip — log + `exit 0`** rather than write. Preserve this fail-safe posture.
3. **Hooks must exit fast and never block the user.** Real work runs in the detached background subshell (`( … ) & disown` with `trap '' HUP`). Don't move work out of it onto the hook's critical path.
4. **Quote every path.** Vault paths routinely contain spaces, `@`, and live on cloud storage. Always quote; glob directly rather than parsing `ls`; never trust file mtime for "most recent" (cloud sync rewrites it).
5. **No `eval`, no `source` of config.** Read config values with `jq -r` only — values must never be executed.
6. **Keep the recursion guard first.** `claude -p` spawns its own session (which fires `SessionEnd`); `CLAUDE_OBSIDIAN_CHRONICLE_RUNNING` must stay the first thing checked in `session-summary.sh`.

## Code style

- Match the surrounding code — comment density, naming, and idioms. The hooks favor clear comments explaining *why* a non-obvious mechanism exists; keep that.
- Keep changes focused and minimal. Avoid unrelated refactors in the same PR.
- Shell: keep it POSIX-ish / Bash 3.2-safe; prefer small, single-purpose functions like the existing ones.

## Pull request process

1. Fork and create a branch: `git checkout -b fix/short-description`.
2. Make your change; **run `bash tests/test-resolve-config.sh`** and manually fire the relevant hook (see above).
3. Write a clear commit message — imperative mood, explain the *why* (e.g. `fix(done-runner): resolve transcript when CLAUDE_SESSION_ID is unset`).
4. Open the PR with: what changed, why, and how you tested it. Link the related issue.
5. **CI must pass** (`.github/workflows/ci.yml`). Maintainer review follows.

By contributing, you agree your contributions are licensed under the project's [MIT License](../LICENSE).

## Reporting bugs — what to include

- What you did and what you expected vs. what happened.
- The relevant lines from `~/.local/state/obsidian-chronicle/process.log` (a `start:` line plus its result line).
- OS, `bash --version`, `jq --version`, and your Claude Code version.
- Your config (redact `vaultPath` if it's sensitive) and whether it's user-level or per-project.

## Security

If you find a security issue (e.g. a path-handling or injection problem), please **don't** open a public issue — email the maintainer via the address on the [GitHub profile](https://github.com/takashito) instead.

## Code of Conduct

Be respectful, constructive, and collaborative. We follow the spirit of the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
