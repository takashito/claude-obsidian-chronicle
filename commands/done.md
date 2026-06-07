---
description: Queue an obsidian-chronicle session summary in the background
allowed-tools: Bash
---

Execute the bash command below. After it returns, respond with EXACTLY one line containing only the command's stdout output — no preamble, no explanation, no additional markdown formatting, no surrounding code fence.

```bash
PLUGIN="${CLAUDE_PLUGIN_ROOT:-$(jq -r '.extraKnownMarketplaces["obsidian-chronicle"].source.path // empty' "$HOME/.claude/settings.json" 2>/dev/null)}"
if [ -z "$PLUGIN" ] || [ ! -x "$PLUGIN/hooks/done-runner.sh" ]; then
  echo "✗ obsidian-chronicle plugin not found; check ~/.claude/settings.json"
  exit 1
fi
"$PLUGIN/hooks/done-runner.sh"
```
