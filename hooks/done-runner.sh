#!/bin/bash
# Backing script for the /obsidian-chronicle:done slash command.
# Locates the current Claude Code session's transcript, builds a hook-style
# JSON payload, and pipes it to session-summary.sh (which runs the summary
# generation in a detached background subshell).

set -e

CWD="${1:-$PWD}"

# Map a real cwd to Claude Code's project transcript directory.
# Claude Code encodes the cwd with `path.replace(/[^a-zA-Z0-9]/g, "-")` (verified
# against the v2.1.x binary): EVERY non-alphanumeric char — `/`, `.`, `@`, space,
# `_`, etc. — becomes `-`, with no collapsing of runs (`~/.claude` → `-Users-…--claude`).
# Paths >200 chars are truncated + suffixed with a hash; that rare case is covered
# by the CLAUDE_SESSION_ID search fallback below rather than reimplemented here.
# This also covers GUI front-ends like Claudian, which embed the real `claude` CLI
# and therefore write transcripts to the standard ~/.claude/projects location.
PROJ_DIR="$HOME/.claude/projects/$(printf '%s' "$CWD" | sed 's|[^a-zA-Z0-9]|-|g')"

TRANSCRIPT=""
# Prefer the active session's id if Claude Code exposes it (works across parallel
# sessions in the same cwd, and survives a cwd→dir mismatch from truncation/NFC).
if [ -n "$CLAUDE_SESSION_ID" ] && [ -f "$PROJ_DIR/${CLAUDE_SESSION_ID}.jsonl" ]; then
  TRANSCRIPT="$PROJ_DIR/${CLAUDE_SESSION_ID}.jsonl"
elif [ -n "$CLAUDE_SESSION_ID" ]; then
  # Computed dir missing or didn't hold this session — search every project dir.
  TRANSCRIPT=$(ls "$HOME/.claude/projects/"*/"${CLAUDE_SESSION_ID}.jsonl" 2>/dev/null | head -1)
fi

# GUI front-ends like Claudian embed the `claude` CLI but do NOT export
# CLAUDE_SESSION_ID, so the heuristic above can't see the active session. They do
# record each conversation's real sessionId in <vault>/.claudian/sessions/*.meta.json.
# Map the most-recently-updated Claudian conversation back to its standard-location
# transcript — this scopes resolution to Claudian sessions (ignoring unrelated CLI
# sessions in the same project dir) and is robust to the >200-char dir-name edge case.
if [ -z "$TRANSCRIPT" ] && [ -d "$CWD/.claudian/sessions" ]; then
  # Pick the most-recently-active conversation by Claudian's own timestamp
  # (lastResponseAt) rather than file mtime — the vault often lives on cloud
  # storage where mtime reflects sync time, not activity. Glob directly instead
  # of parsing `ls`: the vault path contains spaces/`@`, which some `ls` builds
  # shell-quote, corrupting the path.
  _best_ts=0
  for _meta in "$CWD/.claudian/sessions/"*.meta.json; do
    [ -f "$_meta" ] || continue
    # `|| _sid=` keeps set -e from aborting on a half-synced / malformed meta.
    _sid=$(jq -r '.sessionId // empty' "$_meta" 2>/dev/null) || _sid=""
    [ -n "$_sid" ] || continue
    _ts=$(jq -r '(.lastResponseAt // .updatedAt // .createdAt // 0) | floor' "$_meta" 2>/dev/null) || _ts=0
    case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
    [ "$_ts" -gt "$_best_ts" ] || continue
    for _cand in "$HOME/.claude/projects/"*/"${_sid}.jsonl"; do
      if [ -f "$_cand" ]; then _best_ts="$_ts"; TRANSCRIPT="$_cand"; break; fi
    done
  done
fi

# Last resort (no session id, not a Claudian vault): most-recently-modified
# transcript in the computed project dir.
if [ -z "$TRANSCRIPT" ] && [ -d "$PROJ_DIR" ]; then
  TRANSCRIPT=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
fi

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "obsidian-chronicle: no .jsonl transcript found for cwd=$CWD" >&2
  echo "  looked in: $PROJ_DIR" >&2
  [ -n "$CLAUDE_SESSION_ID" ] && echo "  and searched all project dirs for ${CLAUDE_SESSION_ID}.jsonl" >&2
  exit 1
fi

SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)
HERE="$(cd "$(dirname "$0")" && pwd)"

jq -nc \
  --arg sid  "$SESSION_ID" \
  --arg path "$TRANSCRIPT" \
  --arg cwd  "$CWD" \
  '{session_id: $sid, transcript_path: $path, cwd: $cwd, reason: "manual_done"}' \
  | REASON_OVERRIDE=manual_done "$HERE/session-summary.sh"

echo "✓ Summary queued in background (session: ${SESSION_ID:0:8}…)"
