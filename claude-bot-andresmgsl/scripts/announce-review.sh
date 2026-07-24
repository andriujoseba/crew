# NOTE (crew copy): idempotent 🔎 review announce, deduped per (PR, head); fires on demand from review sessions.
#!/usr/bin/env bash
# announce-review.sh <owner/repo> <pr-number> <head-sha>
#
# The 🔎 announce is idempotent per (PR, head) — the same dedup discipline
# verdicts already have, applied to the announce (operator protocol
# 2026-07-23: grok and kimi each double-posted the identical 🔎 on
# ceremony#32 when two candidate passes hit one PR in one tick; verdicts
# stayed single only because submit-verdict.sh gates them). Checks my own
# existing comments live, posts only if this exact (PR, head) was never
# announced; an existing double is left alone — never a third, and never a
# comment about the double.
set -euo pipefail

ME="claude-bot-andresmgsl"

REPO="${1:?usage: announce-review.sh <owner/repo> <pr-number> <head-sha>}"
NUM="${2:?pr number required}"
HEAD_SHA="${3:?head sha required}"

n=$(gh api "repos/$REPO/issues/$NUM/comments" --paginate \
  --jq '[.[] | select(.user.login == "'"$ME"'")
             | select(.body | contains("🔎 reviewing head '"$HEAD_SHA"'"))] | length')

if [ "$n" -gt 0 ]; then
  echo "announce-review: already announced (${n}x) for $REPO#$NUM at ${HEAD_SHA:0:12} — not posting again."
  exit 0
fi

gh api "repos/$REPO/issues/$NUM/comments" \
  -f body="🔎 reviewing head $HEAD_SHA" >/dev/null
echo "announce-review: posted for $REPO#$NUM at ${HEAD_SHA:0:12}."
