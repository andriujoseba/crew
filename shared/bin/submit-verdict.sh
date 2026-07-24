#!/usr/bin/env bash
# submit-verdict.sh — the ONLY sanctioned path to a PR review verdict.
#
#   submit-verdict.sh <owner/repo> <pr-number> <head-sha> <approve|request-changes> <body-file> [--supersede-own]
#
# Idempotent per (identity, PR, head): live pre-check → pinned submit →
# verify → at most ONE retry with the identical body. Exit codes:
#   0  verdict present at that head (submitted now, or already there)
#   1  hard failure (nothing landed after the retry; do NOT resubmit)
#   2  refused — the PR head moved away from <head-sha>; a real review of
#      the new head is owed, not this body
#
# --supersede-own (engine-only; sessions never pass it): submit even though
# a verdict of mine already sits at this head — the re-request auto-approve
# must REPLACE a stale verdict at an unchanged head, which the normal
# already-present check would refuse. Success is then verified as the
# verdict COUNT at head increasing, and idempotency across ticks comes from
# the caller's request-newer-than-my-latest-review condition.
#
# Why each piece exists (all incident-bought, 2026-07-22..24):
#  - The gate sits IMMEDIATELY around the mutation: session-start dedup
#    checks provably failed to stop a second submit later in the same
#    session (codex, PR #26/#29/#39 double-verdicts).
#  - The pre/post check reads pulls/<N>/reviews — it reflects immediately;
#    the SEARCH index lags and must never be consulted.
#  - The submit is pinned with commit_id=<head-sha> via REST: a push between
#    read and submit otherwise attaches the verdict to a tree it never
#    reviewed (kimi, ceremony#94 / incubator#41). The head-moved pre-check
#    plus the pin closes that race from both sides. REST also sidesteps
#    gh-CLI flag drift (Debian's gh 2.46 lacks `--event`; grok's one HARD
#    FAIL in 43h was exactly that).
#  - The CLI's exit status is untrusted in BOTH directions: verified-landed
#    with rc!=0 is success (stop); rc==0 with nothing landed is NOT a
#    license to blind-resubmit.
#  - COMMENTED never counts: a comment is a non-verdict (REVIEWER.md).
#  - The retry reuses the byte-identical body — never regenerated, so a slow
#    first submit can never be joined by a differently-worded twin.
set -euo pipefail

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
LOG="$DUTY_DIR/duty.log"
# stderr always; the duty log only when writable — a hand-run from an odd
# HOME must never turn a landed verdict into a nonzero exit over logging.
glog() {
  printf '%s submit-verdict: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
  printf '%s submit-verdict: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG" 2>/dev/null || true
}

if [ $# -lt 5 ] || [ $# -gt 6 ]; then
  glog "usage: submit-verdict.sh <owner/repo> <pr-number> <head-sha> <approve|request-changes> <body-file> [--supersede-own]"
  exit 1
fi
REPO="$1" NUM="$2" HEAD_SHA="$3" VERDICT="$4" BODY_FILE="$5"
SUPERSEDE=0
[ "${6:-}" = "--supersede-own" ] && SUPERSEDE=1

case "$VERDICT" in
  approve)          EVENT="APPROVE" ;;
  request-changes)  EVENT="REQUEST_CHANGES" ;;
  *) glog "refusing event '$VERDICT': a comment is a non-verdict (REVIEWER.md); only approve|request-changes"; exit 1 ;;
esac
case "$HEAD_SHA" in
  *[!0-9a-f]*) glog "head-sha '$HEAD_SHA' is not a full 40-hex oid"; exit 1 ;;
esac
if [ "${#HEAD_SHA}" -ne 40 ]; then
  glog "head-sha '$HEAD_SHA' is not a full 40-hex oid (short SHAs never match commit_id and burn the retry)"
  exit 1
fi
[ -s "$BODY_FILE" ] || { glog "body file '$BODY_FILE' missing or empty"; exit 1; }

# Freeze the body: the retry must be byte-identical even if the caller's
# file changes underneath us.
FROZEN="$(mktemp)"
trap 'rm -f "$FROZEN"' EXIT
cp "$BODY_FILE" "$FROZEN"

ME="$(gh api user --jq .login)"

# My opinionated reviews at exactly this head. Never the search index.
# Pagination is slurped OUTSIDE gh: `--paginate --jq length` emits one
# count PER PAGE, and a multiline count made both dedup gates read
# "absent" past 100 reviews — the double-submit class this gate prevents.
mine_at_head() {
  gh api "repos/$REPO/pulls/$NUM/reviews" --paginate \
    | jq -s --arg me "$ME" --arg head "$HEAD_SHA" \
      '[add[] | select(.user.login == $me)
              | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
              | select(.commit_id == $head)] | length'
}

attempt=0
while :; do
  attempt=$((attempt + 1))

  live_head="$(gh api "repos/$REPO/pulls/$NUM" --jq .head.sha)" \
    || { glog "cannot read live head for $REPO#$NUM; not submitting"; exit 1; }
  if [ "$live_head" != "$HEAD_SHA" ]; then
    glog "refused: $REPO#$NUM moved from $HEAD_SHA to $live_head — review the new head instead"
    exit 2
  fi

  count="$(mine_at_head)" \
    || { glog "pre-check failed for $REPO#$NUM; not submitting (fail closed)"; exit 1; }
  pre_count="$count"
  if [ "$count" -gt 0 ] && [ "$SUPERSEDE" -eq 0 ]; then
    [ "$count" -gt 1 ] && glog "PROTOCOL NOTE: $count of my verdicts already at head ${HEAD_SHA:0:12} — leaving them; never post a third"
    glog "already present: my verdict at head ${HEAD_SHA:0:12} on $REPO#$NUM"
    exit 0
  fi

  # Pinned REST submit. Its outcome is advisory; the endpoint decides.
  rc=0
  gh api "repos/$REPO/pulls/$NUM/reviews" -X POST \
    -f commit_id="$HEAD_SHA" -f event="$EVENT" -F body="@$FROZEN" >/dev/null 2>&1 || rc=$?

  count="$(mine_at_head || echo "$pre_count")"
  if [ "$count" -gt "$pre_count" ] || { [ "$SUPERSEDE" -eq 0 ] && [ "$count" -gt 0 ]; }; then
    [ "$rc" -ne 0 ] && glog "submit rc=$rc but the endpoint shows the verdict landed — success, not retrying"
    [ "$SUPERSEDE" -eq 0 ] && [ "$count" -gt 1 ] && glog "PROTOCOL VIOLATION: $count verdicts at head ${HEAD_SHA:0:12} — a concurrent submit slipped past; leaving them"
    glog "verified: $VERDICT landed on $REPO#$NUM at head ${HEAD_SHA:0:12}"
    exit 0
  fi

  if [ "$attempt" -ge 2 ]; then
    glog "HARD FAIL: verdict on $REPO#$NUM did not land after $attempt attempts (last rc=$rc) — NOT submitting again; next tick re-detects"
    exit 1
  fi
  glog "attempt $attempt did not land (rc=$rc); retrying once with the identical body"
done
