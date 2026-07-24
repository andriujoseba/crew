# NOTE (crew copy): one-shot verdict gate — every review verdict is submitted through this, never gh pr review; fires on demand from review sessions.
#!/usr/bin/env bash
# submit-verdict.sh <owner/repo> <pr-number> <head-sha> <approve|request-changes> <body-file>
#
# Verdict submission is a ONE-SHOT operation (operator protocol,
# 2026-07-22: three double-submits — PR #26 codex, #29 grok, #39 grok —
# each one tick, one 🔎 claim, two submits; the tick-top dedup runs before
# the session and cannot see a second submit inside it). This wrapper is
# the mechanical gate the session routes EVERY verdict through:
#
#   2. immediately before submitting, re-run the own-review check against
#      GET /repos/{owner}/{repo}/pulls/{N}/reviews — live, never cached;
#   3. submit once, review pinned to the head SHA it was composed for;
#   4. verify with the SAME endpoint. That endpoint reflects the review
#      immediately (it is the *search* index that lags — incident #3's
#      lesson). If it shows the review, the submit succeeded, whatever the
#      submit's own output looked like.
#   5. review present → exit 0, never submit again "to make sure": a
#      duplicate verdict is a protocol violation; a missed one is
#      recoverable on the next tick.
#   6. nothing landed → ONE retry with the identical body, then the same
#      verify; still nothing → exit 1 loudly.
#
# Composing once (step 1) cannot live here — the prompt owns it: write the
# body to a file, call this once, stop.
set -euo pipefail

ME="claude-bot-andresmgsl"

REPO="${1:?usage: submit-verdict.sh <owner/repo> <pr> <head-sha> <approve|request-changes> <body-file>}"
NUM="${2:?pr number required}"
HEAD_SHA="${3:?head sha required}"
VERDICT="${4:?approve|request-changes required}"
BODY_FILE="${5:?body file required}"

case "$VERDICT" in
  approve) EVENT="APPROVE" ;;
  request-changes) EVENT="REQUEST_CHANGES" ;;
  *) echo "submit-verdict: verdict must be approve or request-changes, got '$VERDICT'" >&2; exit 2 ;;
esac
[ -s "$BODY_FILE" ] || { echo "submit-verdict: body file '$BODY_FILE' is empty or missing" >&2; exit 2; }

# The one authoritative question, asked live each time: do I already have a
# non-pending review at this head? (pulls/N/reviews, never search.)
mine_at_head() {
  gh api "repos/$REPO/pulls/$NUM/reviews" --paginate \
    --jq '[.[] | select(.user.login == "'"$ME"'")
               | select(.state != "PENDING")
               | select(.commit_id == "'"$HEAD_SHA"'")] | length'
}

submit() {
  # REST with an explicit commit_id: the verdict lands pinned to the head
  # it was composed for, even if the branch moved mid-session.
  gh api "repos/$REPO/pulls/$NUM/reviews" -X POST \
    -f commit_id="$HEAD_SHA" -f event="$EVENT" -F body="@$BODY_FILE"
}

# Step 2 — live pre-submit check.
if [ "$(mine_at_head)" -gt 0 ]; then
  echo "submit-verdict: my verdict already exists on $REPO#$NUM at ${HEAD_SHA:0:12} — one-shot rule, doing nothing."
  exit 0
fi

# Step 3 — submit once. The output is NOT trusted either way; step 4 is.
submit_out="$(submit 2>&1)" && submit_rc=0 || submit_rc=$?
[ "$submit_rc" -eq 0 ] || echo "submit-verdict: submit exited $submit_rc (output may be ambiguous; the verify decides): $submit_out" >&2

# Step 4/5 — verify with the same endpoint; present means done, full stop.
if [ "$(mine_at_head)" -gt 0 ]; then
  echo "submit-verdict: verified — verdict is on $REPO#$NUM at ${HEAD_SHA:0:12}."
  exit 0
fi

# Step 6 — nothing landed: one retry, identical body, then the same verify.
echo "submit-verdict: verify found nothing after submit; retrying once with the identical body." >&2
submit_out="$(submit 2>&1)" && submit_rc=0 || submit_rc=$?
[ "$submit_rc" -eq 0 ] || echo "submit-verdict: retry exited $submit_rc: $submit_out" >&2
if [ "$(mine_at_head)" -gt 0 ]; then
  echo "submit-verdict: verified on retry — verdict is on $REPO#$NUM at ${HEAD_SHA:0:12}."
  exit 0
fi
echo "submit-verdict: FAILED — two submits, verify still shows no review by $ME at ${HEAD_SHA:0:12} on $REPO#$NUM. Not submitting again; a missed verdict is recoverable next tick." >&2
exit 1
