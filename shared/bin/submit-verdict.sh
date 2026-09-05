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

# Freeze the body on crew's duty volume: the retry must be byte-identical even
# if the caller's file changes underneath us, and a full /tmp must not spend a
# completed review. The write itself is the writability check (not [ -w ],
# which cannot detect ENOSPC).
FROZEN_DIR="$DUTY_DIR/.submit-verdict"
FROZEN=""
frozen_filesystem() {
  df -P "$FROZEN_DIR" 2>/dev/null | tail -n 1 || printf 'unavailable'
}
freeze_failed() {
  glog "cannot freeze caller body '$BODY_FILE' in store '$FROZEN_DIR' (filesystem: $(frozen_filesystem)); not contacting GitHub"
  exit 1
}
cleanup_frozen() {  # <exit-status>
  local rc="$1"
  trap - EXIT INT TERM HUP
  [ -z "$FROZEN" ] || rm -f -- "$FROZEN"
  exit "$rc"
}
trap 'cleanup_frozen $?' EXIT
trap 'cleanup_frozen 130' INT
trap 'cleanup_frozen 143' TERM
trap 'cleanup_frozen 129' HUP

mkdir -p "$FROZEN_DIR" || freeze_failed
if ! FROZEN="$(mktemp "$FROZEN_DIR/verdict.XXXXXX")"; then
  freeze_failed
fi
cp "$BODY_FILE" "$FROZEN" || freeze_failed

ME="$(gh api user --jq .login)"

# (me, PR, head, round) coverage (#114). A verdict of mine may already sit at
# this head, yet a review_requested for me that is NEWER than my latest review
# at this head opens a FRESH round — the considered verdict of that round is
# admissible, and refusing it as already-present silently drops it. A bare
# re-post with no intervening re-request stays refused. Pure so the transition
# is fixture-pinned; --supersede-own keeps its own (auto-approve) meaning and
# never reaches this gate.
round_decision() {  # <my-latest-review-at-head-at> <latest-req-for-me-at>
  local mine_at="$1" req_at="$2"
  if [ "$req_at" != "-" ] && { [ "$mine_at" = "-" ] || [[ "$req_at" > "$mine_at" ]]; }; then
    echo new-round
  else
    echo covered
  fi
}

# The two timestamps round_decision needs, from object endpoints only (never
# the lagging search index): my latest APPROVED/CHANGES_REQUESTED review AT
# this head, and my most recent review-request. Prints "<mine_at> <req_at>",
# each "-" when absent. Empty output (non-zero) means the lookup failed.
round_timestamps() {
  local owner="${REPO%%/*}" name="${REPO##*/}"
  # shellcheck disable=SC2016  # single-quoted GraphQL/jq programs with $vars are intended
  SV_ME="$ME" SV_HEAD="$HEAD_SHA" gh api graphql \
    -f query='query($owner:String!,$name:String!,$num:Int!,$me:String!){
      repository(owner:$owner,name:$name){ pullRequest(number:$num){
        reviews(author:$me,last:20,states:[APPROVED,CHANGES_REQUESTED]){nodes{commit{oid} submittedAt}}
        timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT],last:20){
          nodes{... on ReviewRequestedEvent{createdAt requestedReviewer{... on User{login}}}}}
      } } }' \
    -f owner="$owner" -f name="$name" -F num="$NUM" -f me="$ME" \
    --jq '.data.repository.pullRequest as $pr
      | ([$pr.reviews.nodes[] | select(.commit.oid == env.SV_HEAD) | .submittedAt] | max // "-") as $mine
      | ([$pr.timelineItems.nodes[] | select((.requestedReviewer.login // "") == env.SV_ME) | .createdAt] | max // "-") as $req
      | "\($mine) \($req)"'
}

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
NEW_ROUND=0
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
    # A verdict already sits at this head. Admit it only if a re-request opened
    # a new round (#114); otherwise it is a bare double-post and stays refused.
    round_ts="$(round_timestamps 2>/dev/null || true)"
    if [ -z "$round_ts" ]; then
      glog "cannot determine round state for $REPO#$NUM (graphql lookup failed) — not submitting (fail closed); next tick re-detects"
      exit 1
    fi
    read -r mine_at req_at <<<"$round_ts"
    if [ "$(round_decision "$mine_at" "$req_at")" = "new-round" ]; then
      NEW_ROUND=1
      glog "new round: a re-request for me is newer than my latest review at head ${HEAD_SHA:0:12} on $REPO#$NUM — admitting this considered verdict (#114)"
    else
      [ "$count" -gt 1 ] && glog "PROTOCOL NOTE: $count of my verdicts already at head ${HEAD_SHA:0:12} — leaving them; never post a third"
      glog "already present: my verdict at head ${HEAD_SHA:0:12} on $REPO#$NUM"
      exit 0
    fi
  fi

  # Pinned REST submit. Its outcome is advisory; the endpoint decides.
  rc=0
  gh api "repos/$REPO/pulls/$NUM/reviews" -X POST \
    -f commit_id="$HEAD_SHA" -f event="$EVENT" -F body="@$FROZEN" >/dev/null 2>&1 || rc=$?

  count="$(mine_at_head || echo "$pre_count")"
  # Landed iff my verdict count at this head strictly increased. Before #114 the
  # SUPERSEDE=0 path only ran with pre_count==0, so an "|| count>0" shortcut was
  # equivalent; a new-round submit now runs with pre_count>0, where only a
  # strict increase proves THIS verdict landed rather than the pre-existing one.
  if [ "$count" -gt "$pre_count" ]; then
    [ "$rc" -ne 0 ] && glog "submit rc=$rc but the endpoint shows the verdict landed — success, not retrying"
    [ "$SUPERSEDE" -eq 0 ] && [ "$NEW_ROUND" -eq 0 ] && [ "$count" -gt 1 ] && glog "PROTOCOL VIOLATION: $count verdicts at head ${HEAD_SHA:0:12} — a concurrent submit slipped past; leaving them"
    glog "verified: $VERDICT landed on $REPO#$NUM at head ${HEAD_SHA:0:12}"
    exit 0
  fi

  if [ "$attempt" -ge 2 ]; then
    glog "HARD FAIL: verdict on $REPO#$NUM did not land after $attempt attempts (last rc=$rc); caller body remains at '$BODY_FILE' — NOT submitting again; next tick re-detects"
    exit 1
  fi
  glog "attempt $attempt did not land (rc=$rc); retrying once with the identical body"
done
