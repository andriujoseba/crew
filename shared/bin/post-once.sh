#!/usr/bin/env bash
# post-once.sh — idempotent exact-body comment on an issue or PR. The ONLY
# sanctioned path for board marker comments (the 🔎 announce, and anything
# else that must appear at most once).
#
#   post-once.sh <owner/repo> <number> <exact-body>
#
# Exit 0 = the comment is present (posted now, or already there); 1 = hard
# failure after one identical retry.
#
# Dedup is an EXACT body match against my own comments via the issue-
# comments endpoint (never search, never substring: grok's contains() match
# would let a short SHA false-match a different announce). Same trust rules
# as submit-verdict.sh: the endpoint decides, the CLI's exit status doesn't;
# an existing double is left alone — never a third, and no comment about it.
# (Incident: ceremony#32, grok + kimi double-announce.)
set -euo pipefail

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
LOG="$DUTY_DIR/duty.log"
glog() { printf '%s post-once: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG" >&2; }

if [ $# -ne 3 ]; then
  glog "usage: post-once.sh <owner/repo> <number> <exact-body>"
  exit 1
fi
REPO="$1" NUM="$2" BODY="$3"
[ -n "$BODY" ] || { glog "refusing an empty body"; exit 1; }

ME="$(gh api user --jq .login)"

mine_matching() {
  PO_ME="$ME" PO_BODY="$BODY" gh api "repos/$REPO/issues/$NUM/comments" --paginate \
    --jq '[.[] | select(.user.login == env.PO_ME) | select(.body == env.PO_BODY)] | length'
}

attempt=0
while :; do
  attempt=$((attempt + 1))

  count="$(mine_matching)" \
    || { glog "pre-check failed for $REPO#$NUM; not posting (fail closed)"; exit 1; }
  if [ "$count" -gt 0 ]; then
    [ "$count" -gt 1 ] && glog "PROTOCOL NOTE: $count identical comments already on $REPO#$NUM — leaving them; never a third"
    glog "already present on $REPO#$NUM"
    exit 0
  fi

  rc=0
  gh api "repos/$REPO/issues/$NUM/comments" -X POST -f body="$BODY" >/dev/null 2>&1 || rc=$?

  count="$(mine_matching || echo 0)"
  if [ "$count" -gt 0 ]; then
    [ "$rc" -ne 0 ] && glog "post rc=$rc but the endpoint shows the comment landed — success, not retrying"
    glog "verified on $REPO#$NUM"
    exit 0
  fi

  if [ "$attempt" -ge 2 ]; then
    glog "HARD FAIL: comment on $REPO#$NUM did not land after $attempt attempts (last rc=$rc) — NOT posting again"
    exit 1
  fi
  glog "attempt $attempt did not land (rc=$rc); retrying once with the identical body"
done
