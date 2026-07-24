#!/usr/bin/env bash
# Verdict helper: called once per reviewed head to submit and verify an idempotent approval or change request.
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 OWNER/REPO PR HEAD_SHA APPROVE|REQUEST_CHANGES BODY_FILE" >&2
  exit 2
fi

repo="$1"
pr="$2"
head_sha="$3"
event="$4"
body_file="$5"
log_file="$HOME/duty/duty.log"

case "$event" in
  APPROVE) review_flag=--approve ;;
  REQUEST_CHANGES) review_flag=--request-changes ;;
  *) echo "verdict must be APPROVE or REQUEST_CHANGES" >&2; exit 2 ;;
esac
[[ -s "$body_file" ]] || { echo "verdict body file is empty or missing" >&2; exit 2; }

# Freeze the composition once. Any verified retry uses these exact bytes.
frozen_body="$(mktemp)"
trap 'rm -f "$frozen_body"' EXIT
cp "$body_file" "$frozen_body"
viewer="$(gh api user --jq .login)"

review_present() {
  gh api --paginate "repos/$repo/pulls/$pr/reviews?per_page=100" \
    --jq ".[] | select(.user.login == \"$viewer\" and .commit_id == \"$head_sha\") | .id" \
    | grep -q .
}

for attempt in 1 2; do
  current_head="$(gh api "repos/$repo/pulls/$pr" --jq .head.sha)"
  [[ "$current_head" == "$head_sha" ]] || {
    echo "review gate: PR $repo#$pr moved from $head_sha to $current_head; not submitting" >&2
    exit 1
  }

  # Fresh own-review check immediately before every possible submit.
  if review_present; then
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') REVIEW submit skipped for $repo#$pr: $viewer already reviewed head $head_sha" >>"$log_file"
    exit 0
  fi

  submit_status=0
  gh pr review "$pr" --repo "$repo" "$review_flag" --body-file "$frozen_body" || submit_status=$?

  # The REST reviews endpoint is authoritative and immediately consistent.
  if review_present; then
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') REVIEW submit verified for $repo#$pr head $head_sha" >>"$log_file"
    exit 0
  fi

  if (( attempt == 1 )); then
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') REVIEW submit unverified for $repo#$pr head $head_sha (status $submit_status); retrying identical body once" >>"$log_file"
  fi
done

echo "review submission failed and no verdict appeared for $repo#$pr head $head_sha" >&2
exit 1
