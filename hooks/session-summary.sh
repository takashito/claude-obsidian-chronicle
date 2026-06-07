#!/bin/bash
# SessionEnd / PreCompact / UserPromptSubmit(/done) hook for obsidian-chronicle.
# Writes an Obsidian-format summary note and appends a Daily Note entry.
# Async + detached so /clear, /new, and quit return instantly.
# Dedupes by session_id (frontmatter): resumed sessions append an addendum.

# ---------------------------------------------------------------------------
# Recursion guard (MUST be first).
# `claude -p` (called below to generate the summary) starts its own Claude Code
# session, which itself fires SessionEnd on exit. Without this guard, every
# summary attempt would spawn another summary attempt, eventually overflowing
# the model's context window and writing junk notes like "Prompt is too long".
# We export the marker so the spawned `claude -p` child inherits it and its
# own SessionEnd hook short-circuits here.
# ---------------------------------------------------------------------------
if [ -n "$CLAUDE_OBSIDIAN_CHRONICLE_RUNNING" ]; then
  exit 0
fi
export CLAUDE_OBSIDIAN_CHRONICLE_RUNNING=1

INPUT=$(cat)

(
  # Survive the parent (Claude Code) being killed or quit mid-summary.
  # `claude -p` can take 20–30 s; if the user runs `/exit` right after `/done`,
  # the parent process group goes away. Without this trap the subshell would
  # receive SIGHUP and die mid-write, leaving a half-baked note or none at all.
  # We deliberately do NOT ignore INT/TERM — if the user really wants to kill
  # a runaway summarizer, those still work.
  trap '' HUP

  # ---------- Hook payload ----------
  TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
  SESSION_ID=$(printf '%s'    "$INPUT" | jq -r '.session_id     // empty')
  CWD=$(printf '%s'           "$INPUT" | jq -r '.cwd            // empty')
  REASON=$(printf '%s'        "$INPUT" | jq -r '.reason         // "unknown"')
  # REASON_OVERRIDE (control var) always comes from the caller's env.
  [ -n "${REASON_OVERRIDE:-}" ] && REASON="$REASON_OVERRIDE"

  # ---------- Config resolution ----------
  # All settings come from JSON via the shared resolver (resolve-config.sh):
  #   built-in defaults <- user JSON <- project JSON, with vaultPath resolved
  #   from files -> `obsidian vault` CLI -> none. Paths come back absolute and
  #   tilde-expanded. Fields are read with `jq -r` (no eval).
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CONFIG="$("$SCRIPT_DIR/resolve-config.sh" "$CWD")"

  CONFIG_SOURCE=$(printf '%s'   "$CONFIG" | jq -r '.source')
  VAULT=$(printf '%s'           "$CONFIG" | jq -r '.sessionsDir')
  DAILY_DIR=$(printf '%s'       "$CONFIG" | jq -r '.dailyDir')
  LOG=$(printf '%s'             "$CONFIG" | jq -r '.log')
  SUMMARY_MODEL=$(printf '%s'   "$CONFIG" | jq -r '.model')
  CONVO_MIN_BYTES=$(printf '%s' "$CONFIG" | jq -r '.minBytes')
  CONVO_MAX_BYTES=$(printf '%s' "$CONFIG" | jq -r '.maxBytes')

  # The log lives outside the vault (default: under the XDG state dir); make sure
  # its parent exists before the first write below.
  mkdir -p "$(dirname "$LOG")" 2>/dev/null

  ts() { date '+%Y-%m-%d %H:%M:%S'; }

  # No resolvable vault → never guess a location; log and bail (fail-safe).
  if [ "$CONFIG_SOURCE" = "none" ] || [ -z "$VAULT" ]; then
    echo "$(ts) skip: no vault configured (source=none, $SESSION_ID, reason=$REASON). Run /obsidian-chronicle:setup" >> "$LOG"
    exit 0
  fi

  [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && {
    echo "$(ts) skip: no transcript ($SESSION_ID, reason=$REASON)" >> "$LOG"
    exit 0
  }

  # Per-session lock — atomic mkdir guarantees only one writer per session_id
  # even when PreCompact + /done + SessionEnd race within milliseconds.
  # Stale-lock sweep (>5 min) handles the rare case of a previous run that
  # was SIGKILL'd before trap could clean up.
  # Lock lives next to the log (XDG state dir), already created above — no
  # dependency on ~/.claude existing.
  RUNTIME_DIR="$(dirname "$LOG")"
  LOCK="$RUNTIME_DIR/session-summary.${SESSION_ID}.lock"
  find "$RUNTIME_DIR" -maxdepth 1 -type d -name "session-summary.${SESSION_ID}.lock" -mmin +5 -exec rmdir {} \; 2>/dev/null
  if ! mkdir "$LOCK" 2>/dev/null; then
    echo "$(ts) skip: in-progress lock held ($SESSION_ID, reason=$REASON)" >> "$LOG"
    exit 0
  fi
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

  # ---------- Conversation extraction ----------
  # Pull ONLY the user/assistant prose out of the JSONL and render it as plain
  # text. Drops attachments, queue-operation, file-history-snapshot, last-prompt,
  # and all the JSON scaffolding. The summarizer sees a clean USER↔ASSISTANT
  # narrative without (often huge) tool I/O payloads, slash-command bookkeeping,
  # or Skill content dumps.
  #
  # Filter strategy (low → high specificity):
  # 1. `.isMeta == true` — Claude Code's own flag for system-injected turns.
  #    Verified to mark Skill body loads (kepano-style and built-in alike),
  #    image-paste descriptors, and headless `<local-command-caveat>` first
  #    turns. Does NOT mark slash-command invocations (those are intentional
  #    user input) — those need the string filter below.
  # 2. Drop turns with no real prose — pure tool roundtrips add no signal.
  # 3. Drop obsidian-chronicle's own slash-command invocations + ack.
  # 4. Emit prose followed by any tool markers, compressed.
  extract_conversation() {
    jq -r '
      select(.type == "user" or .type == "assistant")
      | select(.isMeta != true)
      | .message as $m
      | ($m.role // .type) as $role
      | (
          if ($m.content | type) == "string" then $m.content
          else
            [ ($m.content // [])[] | select(.type == "text") | (.text // "") ]
            | join("\n")
          end
        ) as $real_text
      | (
          if ($m.content | type) == "string" then ""
          else
            [ ($m.content // [])[] |
              if .type == "tool_use" then "[tool_use: " + (.name // "?") + "]"
              elif .type == "tool_result" then "[tool_result]"
              else empty end
            ] | join("\n")
          end
        ) as $tool_text
      | select(($real_text | gsub("[[:space:]]+"; "")) != "")
      # Slash-command invocations are real user input (isMeta=false), but they
      # carry our own command body + are followed by the ack — both are noise.
      | select(($real_text | test("<command-name>/obsidian-chronicle:")) | not)
      | select((($role == "assistant") and ($real_text | test("^✓ Summary queued in background"))) | not)
      | (if $tool_text == "" then $real_text else $real_text + "\n" + $tool_text end) as $text
      | "### " + ($role | ascii_upcase) + "\n" + $text + "\n"
    ' "$1" 2>/dev/null
  }

  # CONVO extraction + size guards are deferred until after prior-summary
  # detection (below), so a resumed session can slice the transcript to only the
  # new (post-anchor) events before we measure / summarize it.

  fm_field() {
    local key="$1" file="$2"
    awk -v key="$key" '
      /^---$/{n++; if(n==2) exit; next}
      n==1 {
        if(match($0, "^"key":[[:space:]]*")) {
          val=substr($0, RLENGTH+1)
          sub(/[[:space:]]+$/, "", val)
          gsub(/^"|"$/, "", val)
          print val
          exit
        }
      }' "$file"
  }

  # Upsert a frontmatter scalar: replace `key:` if present inside the frontmatter
  # block, otherwise insert it just before the closing `---`. Used to advance
  # `transcript_anchor` on each resume. Body is left untouched.
  set_fm_field() {
    local key="$1" val="$2" file="$3" tmp="$3.tmp.$$"
    awk -v key="$key" -v val="$val" '
      BEGIN { n=0; done=0 }
      /^---$/ {
        n++
        if (n==2 && !done) { print key ": " val; done=1 }
        print; next
      }
      n==1 && index($0, key ":")==1 {
        if (!done) { print key ": " val; done=1 }
        next
      }
      { print }
    ' "$file" > "$tmp" 2>/dev/null && mv "$tmp" "$file"
  }

  # Extract the content between `@@MARKER@@` and the next KNOWN-marker line.
  # The LLM emits a flat list of named sections; the script reassembles the
  # final Markdown. We close the section only on a marker name we actually
  # use — so an LLM that echoes a literal `@@FOO@@` inside BODY doesn't
  # silently truncate the body.
  extract_marker() {
    local body="$1" marker="$2"
    printf '%s\n' "$body" | awk -v start="@@${marker}@@" '
      BEGIN { in_section = 0 }
      $0 == start { in_section = 1; next }
      in_section && /^@@(TITLE|DESCRIPTION|CLASSIFICATION|KEYWORDS|BODY|DAILY_UPDATE|END)@@[[:space:]]*$/ { exit }
      in_section { print }
    '
  }

  # Trim leading/trailing blank lines + surrounding whitespace.
  trim_block() {
    printf '%s' "$1" | awk '
      { lines[NR] = $0 }
      END {
        first = 1; last = NR
        while (first <= last && lines[first] ~ /^[[:space:]]*$/) first++
        while (last  >= first && lines[last]  ~ /^[[:space:]]*$/) last--
        for (i = first; i <= last; i++) print lines[i]
      }
    '
  }

  EXISTING_FILE=""
  if [ -n "$SESSION_ID" ]; then
    EXISTING_FILE=$(find "$VAULT" -maxdepth 1 -type f -name '*.md' \
      -exec grep -l "^session_id: ${SESSION_ID}\$" {} \; 2>/dev/null | head -1)
  fi

  # ---------- Position-based resume slicing ----------
  # Each summary stores `transcript_anchor` = the uuid of the LAST prose event it
  # covered. On resume we slice the transcript to events AFTER that anchor, so
  # the summarizer only ever sees genuinely new work — never a re-summary of the
  # whole conversation. The transcript is an append-only JSONL log, so "lines
  # after the anchor line" is exactly the new segment, independent of the
  # (non-monotonic, multi-event-type) per-line timestamps — which is why we
  # anchor on uuid rather than a line number or timestamp.
  #
  # Graceful degradation: if the anchor is missing (note predates this feature)
  # or no longer present in the transcript (compaction rewrote/forked it), we
  # fall back to extracting the FULL transcript. The resume prompt still asks the
  # LLM to diff against the prior summary, so behavior matches the pre-slice code.
  NEW_ANCHOR=$(jq -r 'select((.type=="user" or .type=="assistant") and .uuid) | .uuid' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1)

  SLICED=0
  if [ -n "$EXISTING_FILE" ]; then
    PREV_ANCHOR=$(fm_field transcript_anchor "$EXISTING_FILE")
    if [ -n "$PREV_ANCHOR" ]; then
      ANCHOR_LINE=$(grep -n "\"uuid\":\"${PREV_ANCHOR}\"" "$TRANSCRIPT_PATH" 2>/dev/null | head -1 | cut -d: -f1)
      if [ -n "$ANCHOR_LINE" ]; then
        CONVO=$(extract_conversation <(tail -n +"$((ANCHOR_LINE + 1))" "$TRANSCRIPT_PATH"))
        SLICED=1
      fi
    fi
  fi
  if [ "$SLICED" -ne 1 ]; then
    CONVO=$(extract_conversation "$TRANSCRIPT_PATH")
  fi
  CONVO_BYTES=$(printf '%s' "$CONVO" | wc -c | tr -d ' ')

  if [ "${CONVO_BYTES:-0}" -lt "$CONVO_MIN_BYTES" ]; then
    if [ "$SLICED" -eq 1 ]; then
      echo "$(ts) skip: no new work since anchor (${CONVO_BYTES}B, resumed, $SESSION_ID)" >> "$LOG"
    else
      echo "$(ts) skip: empty/trivial conversation (${CONVO_BYTES}B < ${CONVO_MIN_BYTES}B, $SESSION_ID)" >> "$LOG"
    fi
    exit 0
  fi
  if [ "${CONVO_BYTES:-0}" -gt "$CONVO_MAX_BYTES" ]; then
    echo "$(ts) skip: conversation too large (${CONVO_BYTES}B > ${CONVO_MAX_BYTES}B, $SESSION_ID)" >> "$LOG"
    exit 0
  fi

  mkdir -p "$VAULT" "$DAILY_DIR"
  TODAY=$(date +%Y-%m-%d)
  NOW=$(date '+%Y-%m-%d %H:%M')
  DAILY_FILE="$DAILY_DIR/${TODAY}.md"

  if [ -n "$EXISTING_FILE" ]; then
    # ---------- RESUME path: append addendum ----------
    PREV_SUMMARY=$(cat "$EXISTING_FILE")
    EXISTING_TITLE=$(grep -m1 '^# ' "$EXISTING_FILE" | sed 's/^# //;s/[[:space:]]*$//')
    EXISTING_LINK=$(basename "$EXISTING_FILE" .md)
    CLASSIFICATION=$(fm_field classification "$EXISTING_FILE")

    PROMPT='You are extending a previously-summarized Claude Code session that the user resumed.
The conversation transcript is on stdin. The prior summary note is at the bottom of this prompt.

OUTPUT FORMAT — each section starts with `@@MARKER@@` on its own line.

@@DAILY_UPDATE@@
{ONE sentence in Japanese (40-80 文字) summarizing what was done in THIS resume segment. Preserve English technical terms. No quotes, no newlines, no wikilinks.}

@@BODY@@
### 🔧 新しい変更

- {Japanese bullets describing NEW decisions / discoveries / fixes since the prior summary. English technical terms preserved.}
- {…}

### 📝 Files Changed (this segment)

- `path/to/file.ext` — {Japanese description of what changed}

(OMIT this entire "### 📝 Files Changed (this segment)" section if nothing was edited)

> [!success] 結果(this segment)
> {2-3 sentences in Japanese describing what was completed in this segment, what works. Technical terms in English.}

> [!todo] Next Steps
> - [ ] {Actionable follow-up in Japanese}

(OMIT this entire "> [!todo] Next Steps" callout if there are no real follow-ups. NEVER write a placeholder line such as `None` / `なし` / `特になし`.)

@@END@@

LANGUAGE RULES:
- 本文は日本語、ただし file/function/tool names は ENGLISH のまま
- 動詞は混在 OK: 「fix した」「refactor した」
- Section headings は 上記テンプレートのまま

CRITICAL OUTPUT RULES:
- The VERY FIRST characters of your output MUST be `@@DAILY_UPDATE@@` followed by a newline. No preamble. No "Here is the addendum:". No code fence. No greetings.
- DO NOT echo or quote messages verbatim from the conversation. Synthesize new prose.
- DO NOT output lines that begin with `✓`, `>`, or `<command-name>` — these are conversation artifacts, not summary content.
- Be specific — name actual files, functions, decisions; avoid generic phrasing.
- Do NOT repeat content from the prior summary; only cover what is new in this segment.
- Total length under 350 words.
- If nothing substantive happened since the prior summary, respond with EXACTLY the single line `SKIP` and nothing else.

---PRIOR SUMMARY NOTE---
'"$PREV_SUMMARY"'
---END PRIOR SUMMARY---'

    # Haiku occasionally ignores the marker format and responds conversationally
    # (e.g. "了解です。…") or emits a bare markdown table. One retry with a
    # reinforced instruction recovers nearly all of these without producing
    # garbage notes. The reinforcement is appended, not replacing the prompt,
    # so the original format spec stays in view.
    ADDENDUM_RETRY_NOTE='

RETRY NOTE: Your previous attempt did NOT start with `@@DAILY_UPDATE@@` on line 1. Do not acknowledge this. Do not apologize. Do not respond conversationally. Re-emit the addendum now, beginning the VERY FIRST byte of your output with the literal characters `@@DAILY_UPDATE@@` followed by a newline. Every required marker must appear on its own line.'

    attempt=1
    while [ "$attempt" -le 2 ]; do
      if [ "$attempt" -eq 1 ]; then
        _prompt="$PROMPT"
      else
        _prompt="${PROMPT}${ADDENDUM_RETRY_NOTE}"
      fi
      ADDENDUM_RAW=$(printf '%s' "$CONVO" | claude -p "$_prompt" --model "$SUMMARY_MODEL" --output-format text 2>>"$LOG")
      ADDENDUM_EXIT=$?
      if [ "$ADDENDUM_EXIT" -ne 0 ]; then
        echo "$(ts) fail: claude -p exit=$ADDENDUM_EXIT (addendum, $SESSION_ID, attempt=$attempt)" >> "$LOG"
        exit 0
      fi
      if [ -z "$ADDENDUM_RAW" ]; then
        echo "$(ts) fail: empty claude -p output (addendum, $SESSION_ID, attempt=$attempt)" >> "$LOG"
        exit 0
      fi
      case "$ADDENDUM_RAW" in
        "Prompt is too long"*|"Error:"*|"Usage:"*|"Invalid API key"*|"Network error"*)
          echo "$(ts) fail: addendum rejected — claude -p error: ${ADDENDUM_RAW:0:80} ($SESSION_ID)" >> "$LOG"
          exit 0
          ;;
      esac
      case "$(printf '%s' "$ADDENDUM_RAW" | awk 'NF{print; exit}')" in
        SKIP|"SKIP."|"SKIP — "*|"SKIP - "*)
          echo "$(ts) skip: claude -p returned SKIP — no new work since prior summary ($SESSION_ID)" >> "$LOG"
          exit 0
          ;;
      esac

      DAILY_UPDATE=$(trim_block "$(extract_marker "$ADDENDUM_RAW" DAILY_UPDATE)" | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')
      BODY=$(trim_block "$(extract_marker "$ADDENDUM_RAW" BODY)")

      if [ -n "$DAILY_UPDATE" ] && [ -n "$BODY" ]; then
        break
      fi
      if [ "$attempt" -eq 2 ]; then
        echo "$(ts) fail: addendum missing DAILY_UPDATE or BODY marker after retry (raw head: ${ADDENDUM_RAW:0:60}) ($SESSION_ID)" >> "$LOG"
        exit 0
      fi
      echo "$(ts) retry: addendum missing markers, retrying once (raw head: ${ADDENDUM_RAW:0:60}) ($SESSION_ID)" >> "$LOG"
      attempt=$((attempt+1))
    done

    # Assemble the addendum: HR + HTML-comment marker + Resumed H2 + abstract
    # callout (re-using the DAILY_UPDATE one-liner) + LLM-written body.
    {
      printf '\n---\n\n'
      printf '<!-- daily_update: %s -->\n\n' "$DAILY_UPDATE"
      printf '## 🔁 Resumed %s\n\n' "$NOW"
      printf '> [!abstract] このセグメントの概要\n> %s\n\n' "$DAILY_UPDATE"
      printf '%s\n' "$BODY"
    } >> "$EXISTING_FILE"

    if [ ! -f "$DAILY_FILE" ]; then
      printf '# %s\n' "$TODAY" > "$DAILY_FILE"
    fi
    case "$CLASSIFICATION" in
      task)
        ENTRY=$(printf '\n> [!quote]+ 🔁 %s (resumed)\n> [[%s]]\n>\n> %s\n' "$EXISTING_TITLE" "$EXISTING_LINK" "$DAILY_UPDATE")
        ;;
      research)
        ENTRY=$(printf '\n> [!quote]+ 🔁 %s (resumed)\n> [[%s]]\n>\n> %s\n>\n> #research\n' "$EXISTING_TITLE" "$EXISTING_LINK" "$DAILY_UPDATE")
        ;;
      *)
        ENTRY=$(printf '\n> [!quote]+ 🔁 %s (resumed)\n> [[%s]]\n>\n> %s\n' "$EXISTING_TITLE" "$EXISTING_LINK" "$DAILY_UPDATE")
        ;;
    esac
    printf '%s\n' "$ENTRY" >> "$DAILY_FILE"
    # Advance the high-water mark so the NEXT resume slices from here.
    [ -n "$NEW_ANCHOR" ] && set_fm_field transcript_anchor "$NEW_ANCHOR" "$EXISTING_FILE"
    echo "$(ts) appended $EXISTING_FILE [class=$CLASSIFICATION, resumed, sliced=$SLICED] → $DAILY_FILE" >> "$LOG"
    exit 0
  fi

  # ---------- NEW path: full summary ----------
  # The LLM fills named sections delimited by `@@MARKER@@`. The script
  # reassembles the final Obsidian-flavored Markdown (frontmatter, H1,
  # abstract callout, then the LLM-written body).
  PROMPT='You are summarizing a finished Claude Code coding session for storage as an Obsidian note.
The conversation transcript is on stdin.

OUTPUT FORMAT — each section starts with `@@MARKER@@` on its own line. The automation parses these by exact text match.

@@TITLE@@
{日本語で簡潔な見出し（15-30 文字程度、体言止め）。何を達成・調査したかを表す。このタイトルはそのままファイル名になるので、次の文字は絶対に使わない: / \ : * ? " < > | # ^ [ ]。File / function / tool names などの English technical terms はそのまま含めてよい（例: 「session-summary.sh の復元」）。引用符・markdown 記法は不可。}

@@DESCRIPTION@@
{ONE sentence in Japanese (40-80 文字). Preserve English technical terms verbatim. No quotes, no newlines, no wikilinks.}

@@CLASSIFICATION@@
{exactly one lowercase word: task OR research OR other}
- task = something concrete was built, fixed, shipped, or refactored
- research = investigation, learning, exploration (no shippable artifact)
- other = troubleshooting that did not converge, planning, mixed

@@KEYWORDS@@
{comma-separated lowercase ENGLISH terms (5-10) when classification is `research`; may be empty otherwise}

@@BODY@@
## 🎯 ゴール

{1-2 sentence(s) in Japanese describing the user'"'"'s objective. Preserve English technical terms. Use `inline code` for files/functions/variables. Use [[wikilinks]] for concepts that would have their own vault note.}

## 💡 主要な判断

- {Decision 1 in Japanese with English technical terms. Include the *why*, not just the *what*.}
- {Decision 2}
- {Decision 3 — 3-6 bullets total}

## 📝 変更ファイル

| File | 変更内容 |
|---|---|
| `relative/path.ext` | {Japanese description of what changed} |
| `another/file.ext` | {…} |

(OMIT this entire "## 📝 変更ファイル" heading AND table if no files were edited)

## 🔍 Findings

{INCLUDE this section ONLY when classification is `research`. 3-6 bullets of what was learned, with specific file paths / function names / numbers. Japanese with English technical terms. OMIT this whole section otherwise.}

> [!success] 結果
> {2-3 sentences in Japanese describing what was completed, what works, what was verified. English technical terms preserved.}

> [!todo] Next Steps
> - [ ] {Actionable follow-up in Japanese with English technical terms}
> - [ ] {Another actionable follow-up if any}

(OMIT this entire "> [!todo] Next Steps" callout if the session finished cleanly with no real follow-ups. NEVER write a placeholder line such as `None` / `なし` / `特になし`.)

---

#claude-session {add 3-6 additional #topic tags in lowercase English, e.g. #refactor #bug-fix #hooks #infra}

@@END@@

LANGUAGE RULES:
- 本文は日本語で書く (Goal, 主要な判断, 結果, Next Steps の中身)
- 以下は ENGLISH のまま保持する (DO NOT translate):
  * File / directory names: `session-summary.sh`, `.env`, `hooks/`
  * Code identifiers: `extract_marker`, `SESSION_ID`, `claude -p`, `printf -v`
  * Tools / libraries / products: jq, awk, bash, Slack, Obsidian, Claude Code, MCP, Bedrock
  * Technical concepts without a clean Japanese rendering: hook, dispatcher, transcript, telemetry, marker, payload, callout, frontmatter, wikilink, embed, schema, prompt, plugin, repository
- 動詞は混在 OK: 「build した」「refactor した」「test を pass した」のように使う
- TITLE は日本語で書く（File / function / tool names などの technical terms は English のまま埋め込んでよい）
- KEYWORDS は ENGLISH only
- Section headings (## 🎯 ゴール etc.) は 上記テンプレートのまま — 翻訳・変更しない

CRITICAL OUTPUT RULES:
- The VERY FIRST characters of your output MUST be `@@TITLE@@` followed by a newline. No preamble. No "Here is the summary:". No "これで完了です". No code fence wrapper.
- Emit every marker exactly as shown above, on its own line, in this order, exactly once.
- DO NOT echo or quote messages verbatim from the conversation. Synthesize new prose.
- DO NOT output lines that begin with `✓`, `>` (outside the callouts shown above), or `<command-name>` — these are conversation artifacts, not summary content.
- Be specific — name actual files, functions, decisions; avoid generic phrasing.
- Total length under 700 words.
- If the conversation has no real user work (e.g. it is mostly plugin echoes or an empty session), respond with EXACTLY the single line `SKIP` and nothing else. The pipeline will drop the note rather than write garbage.'

  # Haiku occasionally ignores the marker format — sometimes it responds
  # conversationally to the last user turn ("了解です。…"), sometimes it
  # emits a bare markdown table. One retry with a reinforced instruction
  # recovers nearly all of these. The reinforcement is appended so the
  # original format spec stays in view.
  SUMMARY_RETRY_NOTE='

RETRY NOTE: Your previous attempt did NOT start with `@@TITLE@@` on line 1. Do not acknowledge this. Do not apologize. Do not respond conversationally to the conversation transcript. Re-emit the summary now, beginning the VERY FIRST byte of your output with the literal characters `@@TITLE@@` followed by a newline. Every required marker (@@TITLE@@, @@DESCRIPTION@@, @@CLASSIFICATION@@, @@KEYWORDS@@, @@BODY@@, @@END@@) must appear on its own line exactly once, in that order.'

  attempt=1
  while [ "$attempt" -le 2 ]; do
    if [ "$attempt" -eq 1 ]; then
      _prompt="$PROMPT"
    else
      _prompt="${PROMPT}${SUMMARY_RETRY_NOTE}"
    fi
    SUMMARY_RAW=$(printf '%s' "$CONVO" | claude -p "$_prompt" --model "$SUMMARY_MODEL" --output-format text 2>>"$LOG")
    SUMMARY_EXIT=$?
    if [ "$SUMMARY_EXIT" -ne 0 ]; then
      echo "$(ts) fail: claude -p exit=$SUMMARY_EXIT (summary, $SESSION_ID, attempt=$attempt)" >> "$LOG"
      exit 0
    fi
    if [ -z "$SUMMARY_RAW" ]; then
      echo "$(ts) fail: empty claude -p output (summary, $SESSION_ID, attempt=$attempt)" >> "$LOG"
      exit 0
    fi
    # Known claude -p error tells
    case "$SUMMARY_RAW" in
      "Prompt is too long"*|"Error:"*|"Usage:"*|"Invalid API key"*|"Network error"*)
        echo "$(ts) fail: summary rejected — claude -p error: ${SUMMARY_RAW:0:80} ($SESSION_ID)" >> "$LOG"
        exit 0
        ;;
    esac
    # Explicit SKIP escape hatch from the prompt
    case "$(printf '%s' "$SUMMARY_RAW" | awk 'NF{print; exit}')" in
      SKIP|"SKIP."|"SKIP — "*|"SKIP - "*)
        echo "$(ts) skip: claude -p returned SKIP — no real session work ($SESSION_ID)" >> "$LOG"
        exit 0
        ;;
    esac

    # Parse the marker sections.
    TITLE=$(trim_block "$(extract_marker "$SUMMARY_RAW" TITLE)" | head -1)
    DESCRIPTION=$(trim_block "$(extract_marker "$SUMMARY_RAW" DESCRIPTION)" | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')
    CLASSIFICATION=$(trim_block "$(extract_marker "$SUMMARY_RAW" CLASSIFICATION)" | head -1 | tr '[:upper:]' '[:lower:]' | tr -d -c 'a-z')
    KEYWORDS=$(trim_block "$(extract_marker "$SUMMARY_RAW" KEYWORDS)" | head -1 | sed 's/^ *//;s/ *$//')
    BODY=$(trim_block "$(extract_marker "$SUMMARY_RAW" BODY)")

    if [ -n "$TITLE" ] && [ -n "$BODY" ]; then
      break
    fi
    if [ "$attempt" -eq 2 ]; then
      echo "$(ts) fail: summary missing TITLE or BODY marker after retry (raw head: ${SUMMARY_RAW:0:60}) ($SESSION_ID)" >> "$LOG"
      exit 0
    fi
    echo "$(ts) retry: summary missing markers, retrying once (raw head: ${SUMMARY_RAW:0:60}) ($SESSION_ID)" >> "$LOG"
    attempt=$((attempt+1))
  done

  # Snap classification to a known value
  case "$CLASSIFICATION" in
    task|research|other) ;;
    *) CLASSIFICATION="other" ;;
  esac

  [ -z "$DESCRIPTION" ] && DESCRIPTION="$TITLE"

  # Strip filesystem-unsafe chars AND Obsidian wikilink-breakers (# ^ [ ]), since
  # TITLE now becomes both the file name and the [[wikilink]] target in Daily Notes.
  TITLE_SAFE=$(printf '%s' "$TITLE" | tr -d '/<>:"\\|?*#^[]' | sed 's/  */ /g;s/^ //;s/ $//')
  if [ -z "$TITLE_SAFE" ]; then
    echo "$(ts) fail: title sanitization produced empty string from [$TITLE] ($SESSION_ID)" >> "$LOG"
    exit 0
  fi

  FILE="$VAULT/${TITLE_SAFE}.md"
  LINK_NAME="$TITLE_SAFE"
  n=2
  while [ -e "$FILE" ]; do
    LINK_NAME="${TITLE_SAFE} ${n}"
    FILE="$VAULT/${LINK_NAME}.md"
    n=$((n+1))
  done

  # Build the final note: script-controlled frontmatter + H1 + abstract callout
  # (driven by DESCRIPTION) + LLM-written body. The script owns the structural
  # scaffolding; the LLM only fills semantic content.
  #
  # YAML safety: any value that contains `: `, leading `#`, `&`, `*`, `!`, etc.
  # is invalid as an unquoted scalar. We quote strings whose LLM-controlled
  # content is unbounded (title, description, keywords) and any path-shaped
  # value that could contain a colon (cwd, transcript_path) — done by wrapping
  # in double quotes and escaping internal `\` and `"`.
  yaml_q() {
    local v="$1"
    v="${v//\\/\\\\}"  # backslash first
    v="${v//\"/\\\"}"  # then double-quote
    printf '"%s"' "$v"
  }
  {
    printf '%s\n' "---"
    printf 'title: %s\n'           "$(yaml_q "$TITLE")"
    printf 'description: %s\n'     "$(yaml_q "$DESCRIPTION")"
    printf 'classification: %s\n'  "$CLASSIFICATION"
    printf 'keywords: %s\n'        "$(yaml_q "$KEYWORDS")"
    printf 'session_id: %s\n'      "$SESSION_ID"
    printf 'transcript_anchor: %s\n' "$NEW_ANCHOR"
    printf 'transcript_path: %s\n' "$(yaml_q "$TRANSCRIPT_PATH")"
    printf 'cwd: %s\n'             "$(yaml_q "$CWD")"
    printf 'end_reason: %s\n'      "$REASON"
    printf 'tags: [claude-session]\n'
    printf '%s\n\n' "---"
    printf '# %s\n\n' "$TITLE"
    printf '> [!abstract] 概要\n> %s\n\n' "$DESCRIPTION"
    printf '%s\n' "$BODY"
  } > "$FILE"

  if [ ! -f "$DAILY_FILE" ]; then
    printf '# %s\n' "$TODAY" > "$DAILY_FILE"
  fi
  case "$CLASSIFICATION" in
    task)
      ENTRY=$(printf '\n> [!success]+ ✅ %s\n> [[%s]]\n>\n> %s\n' "$TITLE" "$LINK_NAME" "$DESCRIPTION")
      ;;
    research)
      if [ -n "$KEYWORDS" ]; then
        ENTRY=$(printf '\n> [!info]+ 🔍 %s\n> [[%s]]\n>\n> %s\n>\n> **Keywords:** %s\n' "$TITLE" "$LINK_NAME" "$DESCRIPTION" "$KEYWORDS")
      else
        ENTRY=$(printf '\n> [!info]+ 🔍 %s\n> [[%s]]\n>\n> %s\n' "$TITLE" "$LINK_NAME" "$DESCRIPTION")
      fi
      ;;
    *)
      ENTRY=$(printf '\n> [!note]+ 📝 %s\n> [[%s]]\n>\n> %s\n' "$TITLE" "$LINK_NAME" "$DESCRIPTION")
      ;;
  esac
  printf '%s\n' "$ENTRY" >> "$DAILY_FILE"
  echo "$(ts) wrote $FILE [class=$CLASSIFICATION, new] → $DAILY_FILE" >> "$LOG"
) >/dev/null 2>&1 < /dev/null &

disown 2>/dev/null
exit 0
