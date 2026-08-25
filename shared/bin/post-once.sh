#!/usr/bin/env bash
# post-once.sh — idempotent exact-body comment on an issue or PR. The ONLY
# sanctioned path for board marker comments (the 🔎 announce, and anything
# else that must appear at most once).
#
#   post-once.sh <owner/repo> <number> <exact-body> [<marker-line>]
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
#
# WITH A MARKER, dedup is an exact WHOLE-LINE match on that marker instead —
# still never a substring, so ceremony#32's finding stands: a line compare
# cannot false-match the way contains() could, because the delimiters are the
# line ends and a caller cannot widen them. This exists for a body whose
# identity is narrower than its text: the builder's decline comment is keyed on
# the issue and the reason, but must also carry the one fact that decided it,
# and that sentence is written by a model — two boxes reaching the SAME
# conclusion phrase it differently, so an exact-body match would post both and
# a changed conclusion has to still post (crew#462). The marker must itself be
# a line of the body, checked here rather than trusted: a key that is not in
# what gets posted can never match the comment it just wrote, which is a
# double-post on every single call and the exact failure this script exists to
# prevent. Fail closed on that, as on a failed pre-check.
set -euo pipefail

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
LOG="$DUTY_DIR/duty.log"
# stderr always; the duty log only when writable (see submit-verdict.sh).
glog() {
  printf '%s post-once: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
  printf '%s post-once: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG" 2>/dev/null || true
}

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  glog "usage: post-once.sh <owner/repo> <number> <exact-body> [<marker-line>]"
  exit 1
fi
REPO="$1" NUM="$2" BODY="$3" MARKER="${4:-}"
[ -n "$BODY" ] || { glog "refusing an empty body"; exit 1; }
if [ -n "$MARKER" ]; then
  case "$MARKER" in
    *$'\n'*) glog "refusing a multi-line marker; the key is one whole line"; exit 1 ;;
  esac
  # A here-string, never `printf … | grep -q`: under this file's pipefail an
  # early-exiting grep SIGPIPEs its writer and the pipeline's status is the
  # writer's (#449, and the guard that reds the shape on sight).
  grep -qxF -- "$MARKER" <<<"$BODY" \
    || { glog "refusing: the marker is not a line of the body (it could never match)"; exit 1; }
fi

ME="$(gh api user --jq .login)"

# Pagination slurped outside gh: `--paginate --jq length` counts PER PAGE
# and lies past 100 comments (see submit-verdict.sh).
mine_matching() {
  gh api "repos/$REPO/issues/$NUM/comments" --paginate \
    | jq -s --arg me "$ME" --arg body "$BODY" --arg marker "$MARKER" \
      '[add[] | select(.user.login == $me)
        | select(if $marker == ""
                 then .body == $body
                 else (.body | split("\n") | map(sub("\r$"; "")) | index($marker) != null)
                 end)] | length'
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
