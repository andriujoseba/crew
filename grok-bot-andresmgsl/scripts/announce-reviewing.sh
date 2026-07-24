#!/usr/bin/env bash
# CREW: one-shot 🔎 reviewing-head announce — called by a duty session (not cron); posts once per (PR, head).
# ONE-SHOT reviewing-head announce — the only path a duty session may use to
# post the 🔎 marker. Idempotent at (PR, head): check comments, post once,
# never double-post the same (PR, head) pair.
#
# Usage:
#   announce-reviewing.sh <owner/repo> <pr-number> <head-sha>
#
# Exit codes:
#   0  — announce present for this head (posted now, or already present → no-op)
#   1  — hard failure (bad args, API error)
set -euo pipefail

export PATH="/usr/local/bin:/home/grok/.grok/bin:/usr/bin:/bin${PATH:+:$PATH}"

ME="${DUTY_ME:-grok-bot-andresmgsl}"
DUTY_DIR="${HOME}/duty"
LOG="${DUTY_DIR}/duty.log"

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { echo "$(ts) announce-reviewing: $*" | tee -a "${LOG}" >&2; }

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <owner/repo> <pr-number> <head-sha>" >&2
  exit 1
fi

REPO="$1"
NUM="$2"
HEAD="$3"

if [[ -z "${HEAD}" || "${HEAD}" == "null" ]]; then
  log "${REPO}#${NUM}: empty head sha"
  exit 1
fi

# Exact body the family posts (full sha, not abbreviated).
BODY="🔎 reviewing head ${HEAD}"

# True if ME already posted this exact body on the PR issue thread.
# Issues comments endpoint is durable (not search); matches the verdict path.
count_my_announce_at_head() {
  gh api --paginate "repos/${REPO}/issues/${NUM}/comments" \
    --jq "[.[] | select(.user.login == \"${ME}\") | select(.body == \"${BODY}\")] | length"
}

pre="$(count_my_announce_at_head)"
if [[ "${pre}" -gt 0 ]]; then
  if [[ "${pre}" -gt 1 ]]; then
    log "${REPO}#${NUM}: PROTOCOL NOTE — already ${pre} ME announces at head ${HEAD:0:12}; refusing further post"
  else
    log "${REPO}#${NUM}: already announced head ${HEAD:0:12} — refuse second announce"
  fi
  exit 0
fi

set +e
post_out="$(gh api "repos/${REPO}/issues/${NUM}/comments" -f body="${BODY}" 2>&1)"
post_rc=$?
set -e
if [[ ${post_rc} -ne 0 ]]; then
  log "${REPO}#${NUM}: gh comment exited ${post_rc}: ${post_out}"
fi

post="$(count_my_announce_at_head)"
if [[ "${post}" -gt 0 ]]; then
  if [[ ${post_rc} -ne 0 ]]; then
    log "${REPO}#${NUM}: post rc=${post_rc} but comments show announce at ${HEAD:0:12} — treating as success"
  else
    log "${REPO}#${NUM}: announced head ${HEAD:0:12}"
  fi
  if [[ "${post}" -gt 1 ]]; then
    log "${REPO}#${NUM}: PROTOCOL VIOLATION — ${post} ME announces at ${HEAD:0:12}; not posting about it"
  fi
  exit 0
fi

# Genuine miss — one identical retry, never regenerate.
if [[ ${post_rc} -ne 0 ]]; then
  log "${REPO}#${NUM}: nothing at head after failed post — one identical retry"
  set +e
  retry_out="$(gh api "repos/${REPO}/issues/${NUM}/comments" -f body="${BODY}" 2>&1)"
  retry_rc=$?
  set -e
  if [[ ${retry_rc} -ne 0 ]]; then
    log "${REPO}#${NUM}: retry gh exited ${retry_rc}: ${retry_out}"
  fi
  post="$(count_my_announce_at_head)"
  if [[ "${post}" -gt 0 ]]; then
    log "${REPO}#${NUM}: announced on retry at head ${HEAD:0:12}"
    exit 0
  fi
  log "${REPO}#${NUM}: HARD FAIL — no announce at head ${HEAD:0:12} after post+retry"
  exit 1
fi

log "${REPO}#${NUM}: gh rc=0 but comments have no ME announce@${HEAD:0:12} — not re-posting"
exit 1
