#!/usr/bin/env bash
# CREW: one-shot PR verdict submitter — called by a duty session (not cron); posts approve/request-changes once per (PR, head).
# ONE-SHOT verdict submitter — the only path a duty session may use to post
# a PR review. Submitting a verdict is idempotent at this head: compose once,
# pre-check, submit once, verify; never double-post.
#
# Usage:
#   submit-verdict.sh <owner/repo> <pr-number> <approve|request-changes> <body-file>
#
# Exit codes:
#   0  — review present at head (submitted now, or already present → no-op)
#   1  — hard failure (bad args, API error, submit failed and nothing landed)
#   2  — refused: a review from ME already exists at this head (no submit)
set -euo pipefail

export PATH="/usr/local/bin:/home/grok/.grok/bin:/usr/bin:/bin${PATH:+:$PATH}"

ME="${DUTY_ME:-grok-bot-andresmgsl}"
DUTY_DIR="${HOME}/duty"
LOG="${DUTY_DIR}/duty.log"

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { echo "$(ts) submit-verdict: $*" | tee -a "${LOG}" >&2; }

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <owner/repo> <pr-number> <approve|request-changes> <body-file>" >&2
  exit 1
fi

REPO="$1"
NUM="$2"
EVENT="$3"
BODY_FILE="$4"

# gh 2.46 (Debian) uses -a/--approve and -r/--request-changes; newer gh
# also accepts --event APPROVE|REQUEST_CHANGES. Prefer the flag form so both
# work.
case "${EVENT}" in
  approve) GH_REVIEW_FLAG="--approve" ;;
  request-changes) GH_REVIEW_FLAG="--request-changes" ;;
  *)
    echo "event must be approve or request-changes (got: ${EVENT})" >&2
    exit 1
    ;;
esac

if [[ ! -f "${BODY_FILE}" ]]; then
  echo "body file not found: ${BODY_FILE}" >&2
  exit 1
fi

# Live head OID via pulls API (not search index).
head_oid="$(gh api "repos/${REPO}/pulls/${NUM}" --jq '.head.sha')"
if [[ -z "${head_oid}" || "${head_oid}" == "null" ]]; then
  log "${REPO}#${NUM}: failed to read head.sha"
  exit 1
fi

# Reviews via GET /repos/{owner}/{repo}/pulls/{N}/reviews — does NOT lag.
# True if ME already has an APPROVED or CHANGES_REQUESTED review at this head.
# (COMMENTED is not a verdict per REVIEWER.md.)
has_my_review_at_head() {
  local n
  n="$(gh api "repos/${REPO}/pulls/${NUM}/reviews" --paginate \
    --jq "[.[] | select(.user.login == \"${ME}\") | select(.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\") | select(.commit_id == \"${head_oid}\")] | length")"
  [[ "${n}" -gt 0 ]]
}

# Count of ME verdicts at this head (for double-post detection in logs).
count_my_reviews_at_head() {
  gh api "repos/${REPO}/pulls/${NUM}/reviews" --paginate \
    --jq "[.[] | select(.user.login == \"${ME}\") | select(.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\") | select(.commit_id == \"${head_oid}\")] | length"
}

# --- step 2: re-check immediately before submit (never trust earlier cache) ---
pre_count="$(count_my_reviews_at_head)"
if [[ "${pre_count}" -gt 0 ]]; then
  if [[ "${pre_count}" -gt 1 ]]; then
    log "${REPO}#${NUM}: PROTOCOL NOTE — already ${pre_count} ME verdicts at head ${head_oid:0:12} (prior double-post); refusing further submit"
  else
    log "${REPO}#${NUM}: already have review at head ${head_oid:0:12} — refuse second submit"
  fi
  exit 2
fi

# --- step 3: submit once ---
# Body is taken as-is (caller composed once; we never regenerate).
set +e
submit_out="$(gh pr review "${NUM}" --repo "${REPO}" "${GH_REVIEW_FLAG}" --body-file "${BODY_FILE}" 2>&1)"
submit_rc=$?
set -e
if [[ ${submit_rc} -ne 0 ]]; then
  log "${REPO}#${NUM}: gh pr review exited ${submit_rc}: ${submit_out}"
fi

# --- step 4: verify via same pulls/N/reviews endpoint (trust it, not gh output) ---
post_count="$(count_my_reviews_at_head)"
if [[ "${post_count}" -gt 0 ]]; then
  if [[ ${submit_rc} -ne 0 ]]; then
    log "${REPO}#${NUM}: submit rc=${submit_rc} but reviews endpoint shows our review at ${head_oid:0:12} — treating as success (do not retry)"
  else
    log "${REPO}#${NUM}: verdict landed at head ${head_oid:0:12} (${EVENT})"
  fi
  # step 5: if present, STOP — never submit again to "make sure"
  if [[ "${post_count}" -gt 1 ]]; then
    log "${REPO}#${NUM}: PROTOCOL VIOLATION — ${post_count} ME verdicts at ${head_oid:0:12} after one submit path; not posting about it"
  fi
  exit 0
fi

# --- step 6: genuine failure — nothing landed; retry ONCE with identical body ---
if [[ ${submit_rc} -ne 0 ]]; then
  log "${REPO}#${NUM}: nothing at head after failed submit — one identical retry"
  set +e
  retry_out="$(gh pr review "${NUM}" --repo "${REPO}" "${GH_REVIEW_FLAG}" --body-file "${BODY_FILE}" 2>&1)"
  retry_rc=$?
  set -e
  if [[ ${retry_rc} -ne 0 ]]; then
    log "${REPO}#${NUM}: retry gh exited ${retry_rc}: ${retry_out}"
  fi
  post_count="$(count_my_reviews_at_head)"
  if [[ "${post_count}" -gt 0 ]]; then
    log "${REPO}#${NUM}: verdict landed on retry at head ${head_oid:0:12} (${EVENT})"
    exit 0
  fi
  log "${REPO}#${NUM}: HARD FAIL — no review at head ${head_oid:0:12} after submit+retry"
  exit 1
fi

# submit claimed success but reviews endpoint empty — do not fire again
log "${REPO}#${NUM}: gh rc=0 but reviews endpoint has no ME@${head_oid:0:12} — not re-submitting"
exit 1
