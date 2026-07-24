#!/usr/bin/env bash
# Review helper: called once at review pickup to post or deduplicate the exact PR/head announcement.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 OWNER/REPO PR HEAD_SHA" >&2
  exit 2
fi

repo="$1"
pr="$2"
head_sha="$3"
body="🔎 reviewing head $head_sha"
viewer="$(gh api user --jq .login)"
log_file="$HOME/duty/duty.log"

announcement_present() {
  gh api --paginate "repos/$repo/issues/$pr/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$viewer\" and .body == \"$body\") | .id" \
    | grep -q .
}

if announcement_present; then
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') REVIEW announce skipped for $repo#$pr head $head_sha" >>"$log_file"
  exit 0
fi

gh pr comment "$pr" --repo "$repo" --body "$body" >/dev/null

if ! announcement_present; then
  echo "review announcement was not visible for $repo#$pr head $head_sha" >&2
  exit 1
fi
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') REVIEW announce verified for $repo#$pr head $head_sha" >>"$log_file"
