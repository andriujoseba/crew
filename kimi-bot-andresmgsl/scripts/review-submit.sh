# review-submit.sh — one-shot verdict gate: re-checks the reviews endpoint before/after submit. Fires once per verdict, called by the reviewer agent.

#!/usr/bin/env bash
# review-submit.sh — one-shot verdict gate for the duty reviewer.
#
# Usage: review-submit.sh OWNER/REPO PR_NUMBER approve|request-changes BODY_FILE
#
# Compose the verdict body ONCE into BODY_FILE, then submit ONLY through this
# script. It re-checks the pulls/N/reviews endpoint immediately before and
# after the submit (that endpoint does not lag; the search index does).
#   ALREADY-COVERED / LANDED  -> you are done. Never submit again for this head.
#   NOT-LANDED (exit 1)       -> retry ONCE with the identical BODY_FILE.
set -euo pipefail

R="$1"; N="$2"; EVENT="$3"; BODY="$4"

case "$EVENT" in
    approve)         flag=--approve ;;
    request-changes) flag=--request-changes ;;
    *) echo "verdict must be approve or request-changes (a comment is a non-verdict)" >&2; exit 2 ;;
esac

[ -s "$BODY" ] || { echo "body file missing or empty — a verdict needs its reasons" >&2; exit 2; }

me=$(gh api user --jq .login)
head=$(gh api "repos/$R/pulls/$N" --jq .head.sha)

covered() {
    ME="$me" HEAD="$head" gh api "repos/$R/pulls/$N/reviews" --paginate \
        --jq '[.[] | select(.user.login == env.ME and .commit_id == env.HEAD)] | length'
}

# Step 2: re-run the own-review check immediately before submitting.
n=$(covered) || n=""
[[ "$n" =~ ^[0-9]+$ ]] || { echo "ERROR: pre-check query failed — aborting WITHOUT submitting" >&2; exit 2; }
if [ "$n" -gt 0 ]; then
    echo "ALREADY-COVERED: $me already has a review at head $head on $R#$N — do NOT submit again."
    exit 0
fi

# Step 3: submit once.
gh pr review "$N" --repo "$R" "$flag" --body-file "$BODY" || true

# Step 4: verify with the same endpoint — it reflects the review immediately.
n=$(covered) || n=""
if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ]; then
    echo "LANDED: verdict recorded at head $head on $R#$N. Stop — never resubmit to make sure."
    exit 0
fi

echo "NOT-LANDED: nothing recorded at head $head on $R#$N. Retry once with the identical body file; never regenerate it."
exit 1
