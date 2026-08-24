#!/usr/bin/env bash
# shared/test/triage.sh — standalone triage subject suite.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"
# shellcheck source=shared/lib/duty-builder.sh
source "$SHARED/lib/duty-builder.sh"
# shellcheck source=drill/rehearsal-fixtures.sh
source "$ROOT/drill/rehearsal-fixtures.sh"
# shellcheck source=drill/rehearsal-hygiene.sh
source "$ROOT/drill/rehearsal-hygiene.sh"
# shellcheck source=drill/rehearsal-resume.sh
source "$ROOT/drill/rehearsal-resume.sh"
# shellcheck source=drill/rehearsal-attention.sh
source "$ROOT/drill/rehearsal-attention.sh"
# shellcheck source=drill/rehearsal-attention-audit.sh
source "$ROOT/drill/rehearsal-attention-audit.sh"
# shellcheck source=drill/rehearsal-boot.sh
source "$ROOT/drill/rehearsal-boot.sh"
# shellcheck source=drill/rehearsal-breaker.sh
source "$ROOT/drill/rehearsal-breaker.sh"

# --- rehearsal triage fixtures: installed queue labels and cleanup (#417) --
QUEUE_LABEL_SIX_HOME="$TMP/queue-label-six-home"
QUEUE_LABEL_FIVE_HOME="$TMP/queue-label-five-home"
ANSWER_MARK_HOME="$TMP/answer-mark-home"
mkdir -p \
  "$QUEUE_LABEL_SIX_HOME/duty/conf" \
  "$QUEUE_LABEL_FIVE_HOME/duty/conf" \
  "$ANSWER_MARK_HOME/duty/conf"
printf '%s\n' \
  'LABEL_READY=ready' \
  'LABEL_CLAIMED=claimed' \
  'LABEL_BLOCKED=blocked' \
  'LABEL_POST_MERGE=post-merge' \
  'LABEL_EPIC=epic' \
  'LABEL_NEEDS_TRIAGE=needs-triage' \
  >"$QUEUE_LABEL_SIX_HOME/duty/conf/fleet.defaults.conf"
printf '%s\n' \
  'LABEL_READY=ready' \
  'LABEL_CLAIMED=claimed' \
  'LABEL_BLOCKED=blocked' \
  'LABEL_EPIC=epic' \
  'LABEL_NEEDS_TRIAGE=needs-triage' \
  >"$QUEUE_LABEL_FIVE_HOME/duty/conf/fleet.defaults.conf"
printf '%s\n' 'MARK_ANSWERED="fixture answered at head"' \
  >"$ANSWER_MARK_HOME/duty/conf/fleet.defaults.conf"

bx() { HOME="$QUEUE_LABEL_FIXTURE_HOME" bash -c "$1"; }
ok() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; }

QUEUE_LABEL_FIXTURE_HOME="$QUEUE_LABEL_SIX_HOME"
if queue_label_six_out="$(rehearsal_load_installed_queue_labels 2>&1)"; then
  queue_label_six_rc=0
else
  queue_label_six_rc=$?
fi
t rehearsal-queue-label-six-rc 0 "$queue_label_six_rc"
t rehearsal-queue-label-six-records-ok 1 \
  "$(grep -cFx 'ok   triage: installed queue-label set resolves six names' \
    <<<"$queue_label_six_out")"

QUEUE_LABEL_FIXTURE_HOME="$QUEUE_LABEL_FIVE_HOME"
if queue_label_five_out="$(rehearsal_load_installed_queue_labels 2>&1)"; then
  queue_label_five_rc=0
else
  queue_label_five_rc=$?
fi
t rehearsal-queue-label-five-rc 1 "$queue_label_five_rc"
t rehearsal-queue-label-five-records-fail 1 \
  "$(grep -cFx 'FAIL triage: installed queue-label set resolves six names' \
    <<<"$queue_label_five_out")"
t rehearsal-queue-label-five-names-values 'blocked claimed epic needs-triage ready' \
  "$(sed -n 's/^  //p' <<<"$queue_label_five_out" | paste -sd' ' -)"
QUEUE_LABEL_FIXTURE_HOME="$ANSWER_MARK_HOME"
if rehearsal_load_installed_answer_mark >/dev/null; then
  answer_mark_rc=0
else
  answer_mark_rc=$?
fi
t rehearsal-answer-mark-load-rc 0 "$answer_mark_rc"
t rehearsal-answer-mark-loads-installed-value 'fixture answered at head' \
  "$REHEARSAL_MARK_ANSWERED"
REHEARSAL_MARK_ANSWERED=stale-value
QUEUE_LABEL_FIXTURE_HOME="$QUEUE_LABEL_SIX_HOME"
if rehearsal_load_installed_answer_mark >/dev/null; then
  answer_mark_missing_rc=0
else
  answer_mark_missing_rc=$?
fi
t rehearsal-answer-mark-missing-rc 1 "$answer_mark_missing_rc"
t rehearsal-answer-mark-missing-clears-output '' "$REHEARSAL_MARK_ANSWERED"
unset -f bx ok fail

REHEARSAL_ISSUE_GH_CALLS="$TMP/rehearsal-issue-gh-calls"
gh() { printf '%s\n' "$*" >>"$REHEARSAL_ISSUE_GH_CALLS"; }
if rehearsal_close_issue_fixtures owner/sandbox '41 42' >/dev/null; then
  issue_cleanup_rc=0
else
  issue_cleanup_rc=$?
fi
t rehearsal-issue-teardown-success-rc 0 "$issue_cleanup_rc"
t rehearsal-issue-teardown-success-attempts-both 2 \
  "$(wc -l <"$REHEARSAL_ISSUE_GH_CALLS")"

: >"$REHEARSAL_ISSUE_GH_CALLS"
gh() {
  printf '%s\n' "$*" >>"$REHEARSAL_ISSUE_GH_CALLS"
  [[ "$*" != *repos/owner/sandbox/issues/41* ]]
}
if rehearsal_close_issue_fixtures owner/sandbox '41 42' >/dev/null 2>&1; then
  issue_cleanup_rc=0
else
  issue_cleanup_rc=$?
fi
t rehearsal-issue-teardown-partial-failure-rc 1 "$issue_cleanup_rc"
t rehearsal-issue-teardown-partial-failure-attempts-both 2 \
  "$(wc -l <"$REHEARSAL_ISSUE_GH_CALLS")"
t rehearsal-issue-teardown-partial-failure-attempts-first 1 \
  "$(grep -cF 'repos/owner/sandbox/issues/41' "$REHEARSAL_ISSUE_GH_CALLS")"
t rehearsal-issue-teardown-partial-failure-attempts-second 1 \
  "$(grep -cF 'repos/owner/sandbox/issues/42' "$REHEARSAL_ISSUE_GH_CALLS")"
unset -f gh

EMPTY_BUILDER_PRS='[]'
STALE_BUILDER_PRS='[{"number":6,"body":"Closes #5"}]'
RIGHT_BUILDER_PRS='[{"number":6,"body":"Closes #5"},{"number":12,"body":"Closes #179"}]'
PREFIX_BUILDER_PRS='[{"number":13,"body":"Closes #1790"}]'
DUPLICATE_BUILDER_PRS='[{"number":12,"body":"Closes #179"},{"number":14,"body":"Fixes #179"}]'

t rehearsal-builder-stale-pr-occupies-slot 6 \
  "$(rehearsal_builder_slot_prs_from_json "$STALE_BUILDER_PRS")"
if empty_builder_out="$(rehearsal_builder_pr_for_issue_from_json 179 "$EMPTY_BUILDER_PRS")"; then
  empty_builder_rc=0
else
  empty_builder_rc=$?
fi
t rehearsal-builder-empty-response-refused '' "$empty_builder_out"
t rehearsal-builder-empty-response-lookup-fails 1 "$empty_builder_rc"
if stale_builder_out="$(rehearsal_builder_pr_for_issue_from_json 179 "$STALE_BUILDER_PRS")"; then
  stale_builder_rc=0
else
  stale_builder_rc=$?
fi
t rehearsal-builder-stale-pr-cannot-satisfy-this-run '' "$stale_builder_out"
t rehearsal-builder-stale-pr-lookup-fails 1 "$stale_builder_rc"
t rehearsal-builder-run-specific-pr-resolves 12 \
  "$(rehearsal_builder_pr_for_issue_from_json 179 "$RIGHT_BUILDER_PRS")"
if prefix_builder_out="$(rehearsal_builder_pr_for_issue_from_json 179 "$PREFIX_BUILDER_PRS")"; then
  prefix_builder_rc=0
else
  prefix_builder_rc=$?
fi
t rehearsal-builder-wrong-issue-prefix-refused '' "$prefix_builder_out"
t rehearsal-builder-wrong-issue-prefix-lookup-fails 1 "$prefix_builder_rc"
if duplicate_builder_out="$(rehearsal_builder_pr_for_issue_from_json 179 "$DUPLICATE_BUILDER_PRS")"; then
  duplicate_builder_rc=0
else
  duplicate_builder_rc=$?
fi
t rehearsal-builder-duplicate-current-prs-refused '' "$duplicate_builder_out"
t rehearsal-builder-duplicate-current-prs-lookup-fails 1 "$duplicate_builder_rc"

BUILDER_HEAD="$(printf 'b%.0s' {1..40})"
BUILDER_OTHER_HEAD="$(printf 'c%.0s' {1..40})"
BUILDER_MARK='📣 round answered at head'
BUILDER_ROUND_STARTED_AT='2026-08-08T12:01:00Z'
BUILDER_PANEL_CONTENT="$(rehearsal_builder_fixture_panel_content builder host-reviewer)"
t rehearsal-builder-fixture-panel-is-author-specific \
  'panel[builder]=host-reviewer' "$BUILDER_PANEL_CONTENT"

if rehearsal_builder_is_draft_from_json '{"draft":true}'; then builder_draft_result=draft; else builder_draft_result=ready; fi
t rehearsal-builder-draft-object-read draft "$builder_draft_result"
if rehearsal_builder_is_draft_from_json '{"draft":false}'; then builder_draft_result=DRAFT; else builder_draft_result=refused; fi
t rehearsal-builder-ready-object-refused refused "$builder_draft_result"

BUILDER_COMMENTS='[
  {"user":{"login":"builder"},"body":"📣 round answered at head '"$BUILDER_HEAD"'","created_at":"2026-08-08T12:02:00Z"},
  {"user":{"login":"somebody-else"},"body":"📣 round answered at head '"$BUILDER_OTHER_HEAD"'","created_at":"2026-08-08T12:02:00Z"}
]'
if rehearsal_builder_has_answer_signal_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" "$BUILDER_COMMENTS"; then builder_signal_result=found; else builder_signal_result=missing; fi
t rehearsal-builder-current-head-signal-found found "$builder_signal_result"
if rehearsal_builder_has_answer_signal_from_json \
    "$BUILDER_MARK" builder "$BUILDER_OTHER_HEAD" "$BUILDER_ROUND_STARTED_AT" "$BUILDER_COMMENTS"; then builder_signal_result=WRONG; else builder_signal_result=refused; fi
t rehearsal-builder-other-author-signal-refused refused "$builder_signal_result"
BUILDER_TRAILING_SIGNALS="$(jq -cn \
  --arg head "$BUILDER_HEAD" --arg mark "$BUILDER_MARK" '[
    {user:{login:"builder"},body:($mark + " " + $head + " — all points answered"),created_at:"2026-08-08T12:02:00Z"},
    {user:{login:"builder"},body:($mark + " " + $head + "\n"),created_at:"2026-08-08T12:02:00Z"}
  ]')"
if rehearsal_builder_has_answer_signal_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" "$BUILDER_TRAILING_SIGNALS"; then
  builder_signal_result=found
else
  builder_signal_result=missing
fi
t rehearsal-builder-engine-compatible-trailing-signal-found found \
  "$builder_signal_result"

if rehearsal_builder_head_is_from_json \
    "$BUILDER_HEAD" '{"head":{"sha":"'"$BUILDER_HEAD"'"}}'; then
  builder_head_result=stable
else
  builder_head_result=moved
fi
t rehearsal-builder-fixture-head-stability-read stable "$builder_head_result"

BUILDER_PENDING_STATUS='{"statuses":[
  {"context":"drill/builder-head-settle","state":"success","created_at":"2026-08-08T12:00:00Z"},
  {"context":"drill/builder-head-settle","state":"pending","created_at":"2026-08-08T12:01:00Z"},
  {"context":"other","state":"failure","created_at":"2026-08-08T12:02:00Z"}
]}'
t rehearsal-builder-latest-check-state-is-pending pending \
  "$(rehearsal_builder_check_state_from_json \
    drill/builder-head-settle "$BUILDER_PENDING_STATUS")"
t rehearsal-builder-missing-check-context-is-empty '' \
  "$(rehearsal_builder_check_state_from_json missing "$BUILDER_PENDING_STATUS")"

BUILDER_REQUESTED='{"users":[{"login":"host-reviewer"}],"teams":[]}'
BUILDER_UNREQUESTED='{"users":[],"teams":[]}'
if rehearsal_builder_requested_from_json host-reviewer "$BUILDER_REQUESTED"; then builder_request_result=requested; else builder_request_result=missing; fi
t rehearsal-builder-settled-head-request-found requested "$builder_request_result"
if rehearsal_builder_requested_from_json host-reviewer "$BUILDER_UNREQUESTED"; then builder_request_result=EARLY; else builder_request_result=withheld; fi
t rehearsal-builder-pending-head-request-withheld withheld "$builder_request_result"

gh() {
  case "$*" in
    *pulls/9/requested_reviewers*) return 1 ;;
    *) return 2 ;;
  esac
}
if rehearsal_builder_not_requested owner/sandbox 9 host-reviewer; then
  builder_request_result=FAIL_OPEN
else
  builder_request_result=refused
fi
t rehearsal-builder-request-fetch-error-fails-closed refused \
  "$builder_request_result"
unset -f gh

t rehearsal-builder-signal-window-waits-before-signal waiting \
  "$(rehearsal_builder_signal_window_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" drill/builder-head-settle \
    '[]' "$BUILDER_PENDING_STATUS")"
t rehearsal-builder-signal-window-caught-at-pending caught \
  "$(rehearsal_builder_signal_window_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" drill/builder-head-settle \
    "$BUILDER_COMMENTS" "$BUILDER_PENDING_STATUS")"
t rehearsal-builder-stale-same-head-signal-waits waiting \
  "$(rehearsal_builder_signal_window_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" '2026-08-08T12:03:00Z' drill/builder-head-settle \
    "$BUILDER_COMMENTS" "$BUILDER_PENDING_STATUS")"
BUILDER_SETTLED_STATUS='{"statuses":[
  {"context":"drill/builder-head-settle","state":"success","created_at":"2026-08-08T12:03:00Z"}
]}'
t rehearsal-builder-immediate-check-conclusion-is-named-skip-state closed:success \
  "$(rehearsal_builder_signal_window_from_json \
    "$BUILDER_MARK" builder "$BUILDER_HEAD" "$BUILDER_ROUND_STARTED_AT" drill/builder-head-settle \
    "$BUILDER_COMMENTS" "$BUILDER_SETTLED_STATUS")"
gh() {
  case "$*" in
    *issues/9/comments*) printf '%s\n' "$BUILDER_COMMENTS" ;;
    *commits/"$BUILDER_HEAD"/status*) printf '%s\n' "$BUILDER_SETTLED_STATUS" ;;
    *) return 2 ;;
  esac
}
BUILDER_WINDOW_SKIP_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  skip() { printf 'skip %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  rehearsal_wait_builder_signal_window \
    1 owner/sandbox 9 "$BUILDER_MARK" builder "$BUILDER_HEAD" \
    "$BUILDER_ROUND_STARTED_AT" drill/builder-head-settle
})"
t rehearsal-builder-immediate-check-conclusion-names-window 1 \
  "$(grep -cFx \
    'skip builder: pending-check signal window closed before it could be observed (check success); round answer signal was present' \
    <<<"$BUILDER_WINDOW_SKIP_OUT")"
unset -f gh

for builder_prereq_case in mark boundary; do
  builder_prereq_mark="$BUILDER_MARK"
  builder_prereq_after="$BUILDER_ROUND_STARTED_AT"
  builder_prereq_reason='changes-requested review boundary unresolved'
  if [ "$builder_prereq_case" = mark ]; then
    builder_prereq_mark=''
    builder_prereq_reason='installed answer mark unresolved'
  else
    builder_prereq_after=''
  fi
  gh() { printf 'unexpected gh call\n'; return 1; }
  BUILDER_PREREQ_OUT="$({
    ok() { printf 'ok   %s\n' "$1"; }
    skip() { printf 'skip %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    rehearsal_wait_builder_signal_window_with_prereqs \
      1 owner/sandbox 9 "$builder_prereq_mark" builder "$BUILDER_HEAD" \
      "$builder_prereq_after" drill/builder-head-settle
  })"
  t "rehearsal-builder-$builder_prereq_case-prereq-skips-window" 1 \
    "$(grep -cFx \
      "skip builder: round answer signal window unavailable ($builder_prereq_reason)" \
      <<<"$BUILDER_PREREQ_OUT")"
  t "rehearsal-builder-$builder_prereq_case-prereq-cannot-pass-window" 0 \
    "$(grep -c '^ok   builder: round answer' <<<"$BUILDER_PREREQ_OUT")"
  t "rehearsal-builder-$builder_prereq_case-prereq-does-not-query" 0 \
    "$(grep -cFx 'unexpected gh call' <<<"$BUILDER_PREREQ_OUT")"
  unset -f gh
done

# Mutation required by #418: stage the disabled draft-return path as the PR
# object the sourceable assertion reads. It must name the live leg assertion,
# never silently pass a ready PR as if conversion happened.
BUILDER_DRAFT_MUTATION_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
  check "builder: changes-requested round returns PR to draft" \
    rehearsal_builder_is_draft_from_json '{"draft":false}'
})"
t rehearsal-builder-disabled-draft-return-reds 1 \
  "$(grep -cFx 'FAIL builder: changes-requested round returns PR to draft' \
    <<<"$BUILDER_DRAFT_MUTATION_OUT")"

# A premature request at the unsettled head must red the same assertion the
# live leg runs after the builder tick has completed.
# shellcheck disable=SC2317  # gh is invoked indirectly through the sourced helper
gh() {
  case "$*" in
    *pulls/9/requested_reviewers*) printf '%s\n' "$BUILDER_REQUESTED" ;;
    *) return 2 ;;
  esac
}
BUILDER_REQUEST_MUTATION_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
  check "builder: panel request withheld while head check is pending" \
    rehearsal_builder_not_requested owner/sandbox 9 host-reviewer
})"
t rehearsal-builder-premature-request-reds 1 \
  "$(grep -cFx \
    'FAIL builder: panel request withheld while head check is pending' \
    <<<"$BUILDER_REQUEST_MUTATION_OUT")"
unset -f gh

# A failed drill-owned success status must red at setup rather than waiting on
# the downstream request assertion for a transition that never happened.
# shellcheck disable=SC2317  # gh is invoked indirectly through the sourced helper
gh() { return 1; }
BUILDER_SETTLE_MUTATION_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
  check "builder: settled head status established" \
    rehearsal_set_builder_head_status owner/sandbox "$BUILDER_HEAD" \
    drill/builder-head-settle success 'drill releases the settled-head panel request'
})"
t rehearsal-builder-settle-write-failure-reds-at-setup 1 \
  "$(grep -cFx 'FAIL builder: settled head status established' \
    <<<"$BUILDER_SETTLE_MUTATION_OUT")"
unset -f gh

# Pin the live sequence too: host verdict, pending status, concurrent draft
# observation, signal-at-pending assertion, withheld request, success, request.
BUILDER_LIVE_BLOCK="$(sed -n '/builder_head=.*pulls.*head.sha/,/panel request issued after head settles/p' \
  "$ROOT/drill/rehearsal.sh")"
while IFS='|' read -r builder_live_case builder_live_token; do
  if grep -Fq "$builder_live_token" <<<"$BUILDER_LIVE_BLOCK"; then
    t "rehearsal-builder-live-fix-round-$builder_live_case" wired wired
  else
    t "rehearsal-builder-live-fix-round-$builder_live_case" wired MISSING
  fi
done <<'EOF'
1|event=REQUEST_CHANGES
2|host changes-requested review submitted
3|state=pending
4|pending head status established
5|builder_tick_pid=$!
6|changes-requested round returns PR to draft
7|rehearsal_wait_builder_signal_window_with_prereqs
8|builder_round_started_at
9|panel request withheld while head check is pending
10|rehearsal_set_builder_head_status
11|settled head status established
12|panel request issued after head settles
EOF
# shellcheck disable=SC2016  # match the literal background-pid wait in the drill
case "$BUILDER_LIVE_BLOCK" in
  *'wait "$builder_tick_pid"'*'panel request withheld while head check is pending'*'rehearsal_set_builder_head_status'*)
    builder_gate_order=ordered ;;
  *) builder_gate_order=WRONG ;;
esac
t rehearsal-builder-pending-gate-probed-after-tick ordered \
  "$builder_gate_order"

OCCUPIED_BUILDER_OUT="$({
  fail() { printf 'FAIL %s\n' "$1"; }
  skip() { printf 'skip %s\n' "$1"; }
  rehearsal_report_occupied_builder_slot builder
})"
t rehearsal-builder-occupied-slot-fails-opened-pr 1 \
  "$(grep -cFx 'FAIL builder: opened a PR for the ready issue' <<<"$OCCUPIED_BUILDER_OUT")"
t rehearsal-builder-occupied-slot-fails-run-specific-authorship 1 \
  "$(grep -cFx "FAIL builder: PR authored by builder for this run's fixture issue" \
    <<<"$OCCUPIED_BUILDER_OUT")"
t rehearsal-builder-occupied-slot-skips-unreachable-checks \
  'builder fixture is unassigned (ready+assigned is not pickable)|builder: PR branch is build/*|builder: issue moved off ready (claimed)|builder: no duplicate PR on re-tick|builder: fixture panel names the host reviewer|builder: initial PR is ready for its fixture panel|builder: host reviewer requested for initial round|builder: installed round-answer mark resolves|builder: host changes-requested review submitted|builder: pending head status established|builder: changes-requested round returns PR to draft|builder: round answer is signalled while head check is pending|builder: fix round kept the fixture head stable|builder: panel request withheld while head check is pending|builder: settled head status established|builder: panel request issued after head settles' \
  "$(sed -n 's/^skip //p' <<<"$OCCUPIED_BUILDER_OUT" | paste -sd'|' -)"

MISSING_BUILDER_PR_OUT="$({
  skip() { printf 'skip %s\n' "$1"; }
  rehearsal_report_missing_builder_pr
})"
t rehearsal-builder-missing-pr-skips-unreachable-checks \
  'builder: initial PR is ready for its fixture panel|builder: host reviewer requested for initial round|builder: installed round-answer mark resolves|builder: host changes-requested review submitted|builder: pending head status established|builder: changes-requested round returns PR to draft|builder: round answer is signalled while head check is pending|builder: fix round kept the fixture head stable|builder: panel request withheld while head check is pending|builder: settled head status established|builder: panel request issued after head settles' \
  "$(sed -n 's/^skip //p' <<<"$MISSING_BUILDER_PR_OUT" | paste -sd'|' -)"

REHEARSAL_GH_CALLS="$TMP/rehearsal-gh-calls"
gh() {
  case "$1 $2" in
    "api repos/owner/sandbox/pulls?state=open&per_page=100")
      jq '[.[] | .user = {login:"builder"}]' <<<"$RIGHT_BUILDER_PRS" ;;
    "api -X") printf '%s\n' "$*" >>"$REHEARSAL_GH_CALLS" ;;
    *) return 2 ;;
  esac
}
rehearsal_close_builder_fixture_prs owner/sandbox builder >/dev/null
t rehearsal-builder-teardown-closes-all-fixture-prs 2 \
  "$(wc -l <"$REHEARSAL_GH_CALLS")"
t rehearsal-builder-teardown-closes-first 1 \
  "$(grep -cF 'repos/owner/sandbox/pulls/6' "$REHEARSAL_GH_CALLS")"
t rehearsal-builder-teardown-closes-current 1 \
  "$(grep -cF 'repos/owner/sandbox/pulls/12' "$REHEARSAL_GH_CALLS")"
unset -f gh


# --- rehearsal attention-AUDIT leg: the hygiene slot's board audit (#441) ---
# Every input here is the value the live row reads — the invocation's own
# report text, the alert capture, board JSON, the script sent through a stubbed
# bx() — so each mutation is the decision boundary itself and needs no drill
# host. The one mutation that does is named in the PR body with its reason.
AUD_REPO=owner/sandbox
AUD_PR=91
AUD_ISSUE=92
AUD_IDENTITY=drill-identity
AUD_MARK=attention
# report_suppressed's rendering, verbatim: "<repo>#<num>(<CLASS>)".
AUD_REPORT_BOTH="2026-08-09T12:00:00Z WARN: attention: malformed flag(s): 2 item(s) on pull requests or unassigned issues; audit only, not repaired — $AUD_REPO#$AUD_PR(PR) $AUD_REPO#$AUD_ISSUE(UNASSIGNED) "
AUD_REPORT_PR_ONLY="2026-08-09T12:00:00Z WARN: attention: malformed flag(s): 1 item(s) on pull requests or unassigned issues; audit only, not repaired — $AUD_REPO#$AUD_PR(PR) "
AUD_REPORT_ISSUE_ONLY="2026-08-09T12:00:00Z WARN: attention: malformed flag(s): 1 item(s) on pull requests or unassigned issues; audit only, not repaired — $AUD_REPO#$AUD_ISSUE(UNASSIGNED) "
# The alert's rendering is the OTHER one: square brackets, not parentheses.
AUD_ALERT_BOTH="🚨 host: malformed attention flag(s) — $AUD_REPO#${AUD_PR}[PR] $AUD_REPO#${AUD_ISSUE}[UNASSIGNED] — move each flag to the assigned issue that owns the claim"
AUD_ALERT_PR_ONLY="🚨 host: malformed attention flag(s) — $AUD_REPO#${AUD_PR}[PR] — move each flag to the assigned issue that owns the claim"
AUD_ALERT_CLEAR="✅ host: malformed attention flags cleared"

aud_row() {  # aud_row <row name> <predicate...> — the live grading, captured
  (
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    rehearsal_attention_audit_graded "$@"
  )
}

# §3 the report names BOTH shapes. The classifier has two branches; a leg that
# reads one proves half of it, and the half it drops is the one #303 was minted
# for — a ruling's flag on a PR.
if rehearsal_attention_audit_report_names_both \
    "$AUD_REPO" "$AUD_PR" "$AUD_ISSUE" "$AUD_REPORT_BOTH" >/dev/null; then
  r1=named
else
  r1=WRONG
fi
t attention-audit-report-naming-both-holds named "$r1"
AUD_OUT="$(aud_row 'attention-audit: report names both malformed shapes' \
  rehearsal_attention_audit_report_names_both \
  "$AUD_REPO" "$AUD_PR" "$AUD_ISSUE" "$AUD_REPORT_PR_ONLY")"
t attention-audit-report-naming-only-the-pr-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: report names both malformed shapes' <<<"$AUD_OUT")"
t attention-audit-report-pr-only-red-names-what-is-missing 1 \
  "$(grep -cF "not named: $AUD_REPO#$AUD_ISSUE(UNASSIGNED)" <<<"$AUD_OUT")"
AUD_OUT="$(aud_row 'attention-audit: report names both malformed shapes' \
  rehearsal_attention_audit_report_names_both \
  "$AUD_REPO" "$AUD_PR" "$AUD_ISSUE" "$AUD_REPORT_ISSUE_ONLY")"
t attention-audit-report-naming-only-the-issue-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: report names both malformed shapes' <<<"$AUD_OUT")"
t attention-audit-report-issue-only-red-names-what-is-missing 1 \
  "$(grep -cF "not named: $AUD_REPO#$AUD_PR(PR)" <<<"$AUD_OUT")"
# §7: the red quotes the report LINE it read, not a transcript.
t attention-audit-report-red-quotes-the-line-it-read 1 \
  "$(grep -cF "read: $AUD_REPORT_ISSUE_ONLY" <<<"$AUD_OUT")"
AUD_OUT="$(aud_row 'attention-audit: report names both malformed shapes' \
  rehearsal_attention_audit_report_names_both \
  "$AUD_REPO" "$AUD_PR" "$AUD_ISSUE" '2026-08-09T12:00:00Z hygiene sweep starting')"
t attention-audit-missing-report-reds 1 \
  "$(grep -cF 'read: no "attention: malformed flag(s)" report in the invocation output' \
    <<<"$AUD_OUT")"
# A report naming two OTHER objects is not this leg's report. Without the
# round's own numbers in the needles the row would pass on any malformed board
# at all — including one a previous run left behind.
AUD_OUT="$(aud_row 'attention-audit: report names both malformed shapes' \
  rehearsal_attention_audit_report_names_both "$AUD_REPO" "$AUD_PR" "$AUD_ISSUE" \
  "2026-08-09T12:00:00Z WARN: attention: malformed flag(s): 2 item(s) on pull requests or unassigned issues; audit only, not repaired — $AUD_REPO#7(PR) $AUD_REPO#8(UNASSIGNED) ")"
t attention-audit-report-of-other-objects-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: report names both malformed shapes' <<<"$AUD_OUT")"

# The clean-board call writes NO report. An empty one would be
# report_suppressed writing state for nothing, and the transition rows below
# read that state as their `previous`.
if rehearsal_attention_audit_no_report \
    '2026-08-09T12:00:00Z hygiene sweep starting' >/dev/null; then
  r1=silent
else
  r1=WRONG
fi
t attention-audit-clean-board-silence-holds silent "$r1"
AUD_OUT="$(aud_row 'attention-audit: clean board writes no malformed report' \
  rehearsal_attention_audit_no_report "$AUD_REPORT_BOTH")"
t attention-audit-report-on-a-clean-board-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: clean board writes no malformed report' <<<"$AUD_OUT")"

# §5 the transitions, by COUNT. "🚨 appeared" is also true of a board that
# alerted on every call — the #59 defect the suppression exists to prevent —
# so only the count can tell the two apart.
t attention-audit-alert-count-of-none 0 \
  "$(rehearsal_attention_audit_alert_count '🚨' '')"
t attention-audit-alert-count-of-one 1 \
  "$(rehearsal_attention_audit_alert_count '🚨' "$AUD_ALERT_BOTH")"
t attention-audit-alert-count-of-two 2 \
  "$(rehearsal_attention_audit_alert_count '🚨' "$AUD_ALERT_BOTH
$AUD_ALERT_BOTH")"
# A ✅ in the capture is not a 🚨: the two marks are counted apart, or the
# clear would satisfy the row that says the transition fired.
t attention-audit-clear-does-not-count-as-a-raise 0 \
  "$(rehearsal_attention_audit_alert_count '🚨' "$AUD_ALERT_CLEAR")"
AUD_OUT="$(aud_row 'attention-audit: the transition alerts exactly once' \
  rehearsal_attention_audit_alert_count_is 1 '🚨' "$AUD_ALERT_BOTH
$AUD_ALERT_BOTH")"
t attention-audit-two-alerts-on-the-transition-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: the transition alerts exactly once' <<<"$AUD_OUT")"
t attention-audit-transition-red-quotes-the-count 1 \
  "$(grep -cF 'read: 2 🚨 alert(s), wanted 1' <<<"$AUD_OUT")"
# The must-fail the whole suppression exists for: a SECOND 🚨 while the board
# has not changed.
AUD_OUT="$(aud_row 'attention-audit: an unchanged board adds no further alert' \
  rehearsal_attention_audit_alert_count_is 0 '🚨' "$AUD_ALERT_BOTH")"
t attention-audit-second-alert-on-an-unchanged-board-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: an unchanged board adds no further alert' <<<"$AUD_OUT")"
t attention-audit-unchanged-red-quotes-the-count 1 \
  "$(grep -cF 'read: 1 🚨 alert(s), wanted 0' <<<"$AUD_OUT")"
# ...and its twin: a MISSING ✅ on the clear.
AUD_OUT="$(aud_row 'attention-audit: clearing the set alerts exactly once' \
  rehearsal_attention_audit_alert_count_is 1 '✅' '')"
t attention-audit-missing-clear-alert-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: clearing the set alerts exactly once' <<<"$AUD_OUT")"
t attention-audit-missing-clear-red-quotes-the-count 1 \
  "$(grep -cF 'read: 0 ✅ alert(s), wanted 1' <<<"$AUD_OUT")"
# A silent clean board is the count the first call wants.
AUD_OUT="$(aud_row 'attention-audit: clean board raises no alert' \
  rehearsal_attention_audit_alert_count_is 0 '🚨' '')"
t attention-audit-silent-clean-board-passes 1 \
  "$(grep -cFx 'ok   attention-audit: clean board raises no alert' <<<"$AUD_OUT")"

# The 🚨 names both shapes too, in its own rendering. Two renderings of one
# set, each read in its own shape rather than assumed to agree with the other.
if rehearsal_attention_audit_alert_names_both \
    '🚨' "$AUD_REPO" "$AUD_PR" "$AUD_ISSUE" "$AUD_ALERT_BOTH" >/dev/null; then
  r1=named
else
  r1=WRONG
fi
t attention-audit-alert-naming-both-holds named "$r1"
AUD_OUT="$(aud_row 'attention-audit: the alert names both malformed shapes' \
  rehearsal_attention_audit_alert_names_both \
  '🚨' "$AUD_REPO" "$AUD_PR" "$AUD_ISSUE" "$AUD_ALERT_PR_ONLY")"
t attention-audit-alert-naming-only-the-pr-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: the alert names both malformed shapes' <<<"$AUD_OUT")"
t attention-audit-alert-pr-only-red-names-what-is-missing 1 \
  "$(grep -cF "not named: $AUD_REPO#${AUD_ISSUE}[UNASSIGNED]" <<<"$AUD_OUT")"
# The report's parenthesised rendering must not satisfy the alert row: they are
# different renderings, and a row that accepted either would pass on a board
# where only one of the two ever fired.
AUD_OUT="$(aud_row 'attention-audit: the alert names both malformed shapes' \
  rehearsal_attention_audit_alert_names_both \
  '🚨' "$AUD_REPO" "$AUD_PR" "$AUD_ISSUE" "🚨 host: $AUD_REPO#$AUD_PR(PR) $AUD_REPO#$AUD_ISSUE(UNASSIGNED)")"
t attention-audit-report-rendering-does-not-satisfy-the-alert-row 1 \
  "$(grep -cFx 'FAIL attention-audit: the alert names both malformed shapes' <<<"$AUD_OUT")"

# §4 NON-REPAIR — the load-bearing half. A repaired board still reports its
# malformed set correctly on the way past, so §3 alone cannot see it.
AUD_PR_FLAGGED='{"state":"open","labels":[{"name":"attention"}],"assignees":[]}'
AUD_ISSUE_FLAGGED='{"state":"open","labels":[{"name":"attention"},{"name":"blocked"}],"assignees":[]}'
AUD_ISSUE_REPAIRED='{"state":"open","labels":[{"name":"blocked"}],"assignees":[]}'
AUD_ISSUE_ASSIGNED='{"state":"open","labels":[{"name":"attention"},{"name":"blocked"}],"assignees":[{"login":"drill-identity"}]}'
if rehearsal_attention_audit_flags_intact "$AUD_MARK" \
    "$AUD_PR_FLAGGED" "$AUD_ISSUE_FLAGGED" >/dev/null; then
  r1=intact
else
  r1=WRONG
fi
t attention-audit-flags-intact-holds intact "$r1"
AUD_OUT="$(aud_row 'attention-audit: both flags still set' \
  rehearsal_attention_audit_flags_intact "$AUD_MARK" \
  "$AUD_PR_FLAGGED" "$AUD_ISSUE_REPAIRED")"
t attention-audit-a-cleared-flag-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: both flags still set' <<<"$AUD_OUT")"
t attention-audit-cleared-flag-red-quotes-both-label-sets 2 \
  "$(grep -cE 'read: (pull request|unassigned issue): ' <<<"$AUD_OUT")"
AUD_OUT="$(aud_row 'attention-audit: both flags still set' \
  rehearsal_attention_audit_flags_intact "$AUD_MARK" \
  '{"state":"open","labels":[],"assignees":[]}' "$AUD_ISSUE_FLAGGED")"
t attention-audit-a-cleared-pr-flag-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: both flags still set' <<<"$AUD_OUT")"
# A look-alike label is not the flag. `grep -w attention` matches
# `attention-needed` — `-` is not a word character — so the membership test is
# jq's, and this is the row that says so.
AUD_OUT="$(aud_row 'attention-audit: both flags still set' \
  rehearsal_attention_audit_flags_intact "$AUD_MARK" \
  '{"state":"open","labels":[{"name":"attention-needed"}],"assignees":[]}' \
  "$AUD_ISSUE_FLAGGED")"
t attention-audit-a-look-alike-label-is-not-the-flag 1 \
  "$(grep -cFx 'FAIL attention-audit: both flags still set' <<<"$AUD_OUT")"

if rehearsal_attention_audit_still_unassigned "$AUD_ISSUE_FLAGGED" >/dev/null; then
  r1=unassigned
else
  r1=WRONG
fi
t attention-audit-still-unassigned-holds unassigned "$r1"
AUD_OUT="$(aud_row 'attention-audit: the unassigned issue is still unassigned' \
  rehearsal_attention_audit_still_unassigned "$AUD_ISSUE_ASSIGNED")"
t attention-audit-an-assigned-fixture-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: the unassigned issue is still unassigned' <<<"$AUD_OUT")"
t attention-audit-assigned-red-quotes-the-assignee 1 \
  "$(grep -cF "read: $AUD_IDENTITY" <<<"$AUD_OUT")"

AUD_NO_COMMENTS='[]'
AUD_OTHERS_COMMENT='[{"user":{"login":"someone-else"}}]'
AUD_IDENTITY_COMMENT='[{"user":{"login":"drill-identity"}}]'
if rehearsal_attention_audit_no_identity_comment "$AUD_IDENTITY" \
    "$AUD_NO_COMMENTS" "$AUD_NO_COMMENTS" >/dev/null; then
  r1=silent
else
  r1=WRONG
fi
t attention-audit-no-comment-holds silent "$r1"
# Somebody else's comment is not the audit's: the identity comes from the
# round's own variable, and the row must not red on a board a human touched.
if rehearsal_attention_audit_no_identity_comment "$AUD_IDENTITY" \
    "$AUD_OTHERS_COMMENT" "$AUD_OTHERS_COMMENT" >/dev/null; then
  r1=silent
else
  r1=WRONG
fi
t attention-audit-another-actors-comment-is-not-the-audits silent "$r1"
AUD_OUT="$(aud_row 'attention-audit: no comment by the identity on either fixture' \
  rehearsal_attention_audit_no_identity_comment "$AUD_IDENTITY" \
  "$AUD_IDENTITY_COMMENT" "$AUD_NO_COMMENTS")"
t attention-audit-a-comment-on-the-pr-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: no comment by the identity on either fixture' <<<"$AUD_OUT")"
t attention-audit-comment-red-quotes-both-counts 1 \
  "$(grep -cF 'read: 1 comment(s) on the pull request, 0 on the unassigned issue' <<<"$AUD_OUT")"
AUD_OUT="$(aud_row 'attention-audit: no comment by the identity on either fixture' \
  rehearsal_attention_audit_no_identity_comment "$AUD_IDENTITY" \
  "$AUD_NO_COMMENTS" "$AUD_IDENTITY_COMMENT")"
t attention-audit-a-comment-on-the-issue-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: no comment by the identity on either fixture' <<<"$AUD_OUT")"

# The cleanup, PROVED off the board rather than asserted in a comment.
AUD_GONE='{"state":"closed","labels":[],"assignees":[]}'
if rehearsal_attention_audit_fixtures_removed "$AUD_MARK" "$AUD_GONE" "$AUD_GONE" >/dev/null; then
  r1=removed
else
  r1=WRONG
fi
t attention-audit-fixtures-removed-holds removed "$r1"
AUD_OUT="$(aud_row 'attention-audit: both fixtures removed from the board' \
  rehearsal_attention_audit_fixtures_removed "$AUD_MARK" "$AUD_GONE" "$AUD_ISSUE_FLAGGED")"
t attention-audit-a-surviving-fixture-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: both fixtures removed from the board' <<<"$AUD_OUT")"
t attention-audit-surviving-fixture-red-names-both-faults 1 \
  "$(grep -cF 'read: unassigned issue still open; unassigned issue still flagged' <<<"$AUD_OUT")"
# Closed but still flagged is still a survival: the flag is what the audit
# reads, and a closed object carrying it is a fixture left in the board's way.
AUD_OUT="$(aud_row 'attention-audit: both fixtures removed from the board' \
  rehearsal_attention_audit_fixtures_removed "$AUD_MARK" \
  '{"state":"closed","labels":[{"name":"attention"}],"assignees":[]}' "$AUD_GONE")"
t attention-audit-closed-but-flagged-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: both fixtures removed from the board' <<<"$AUD_OUT")"

# §7 in the rc=2 branch: an UNREADABLE read is the case where naming what was
# read matters most, and a predicate that returned 2 with no stdout printed a
# bare red there — a row whose read is the suspect, saying nothing about it.
AUD_JUNK='{"labels":[' # a truncated response, the realistic shape of the fault
AUD_OUT="$(aud_row 'attention-audit: both flags still set' \
  rehearsal_attention_audit_flags_intact "$AUD_MARK" "$AUD_JUNK" "$AUD_ISSUE_FLAGGED")"
t attention-audit-unreadable-pr-json-reds 1 \
  "$(grep -cFx 'FAIL attention-audit: both flags still set' <<<"$AUD_OUT")"
t attention-audit-unreadable-pr-json-red-names-what-it-had 1 \
  "$(grep -cF 'read: unreadable pull request JSON: {"labels":[' <<<"$AUD_OUT")"
AUD_OUT="$(aud_row 'attention-audit: both flags still set' \
  rehearsal_attention_audit_flags_intact "$AUD_MARK" "$AUD_PR_FLAGGED" "$AUD_JUNK")"
t attention-audit-unreadable-issue-json-red-names-which-read-failed 1 \
  "$(grep -cF 'read: unreadable unassigned issue JSON: {"labels":[' <<<"$AUD_OUT")"
AUD_OUT="$(aud_row 'attention-audit: the unassigned issue is still unassigned' \
  rehearsal_attention_audit_still_unassigned "$AUD_JUNK")"
t attention-audit-unreadable-assignee-read-names-what-it-had 1 \
  "$(grep -cF 'read: unreadable unassigned issue JSON: {"labels":[' <<<"$AUD_OUT")"
AUD_OUT="$(aud_row 'attention-audit: no comment by the identity on either fixture' \
  rehearsal_attention_audit_no_identity_comment "$AUD_IDENTITY" '[{' '[]')"
t attention-audit-unreadable-comments-red-names-what-it-had 1 \
  "$(grep -cF 'read: unreadable pull request comments: [{' <<<"$AUD_OUT")"
AUD_OUT="$(aud_row 'attention-audit: both fixtures removed from the board' \
  rehearsal_attention_audit_fixtures_removed "$AUD_MARK" "$AUD_JUNK" "$AUD_GONE")"
t attention-audit-unreadable-re-read-red-names-what-it-had 1 \
  "$(grep -cF 'read: unreadable pull request JSON: {"labels":[' <<<"$AUD_OUT")"
# The flattening is what keeps the line a name and not a payload: an API
# response arrives pretty-printed, and one `read:` line per JSON line would
# bury the row it belongs to.
AUD_OUT="$(rehearsal_attention_audit_unreadable 'pull request JSON' \
  "$(printf '{\n  "labels": [\n')")"
t attention-audit-unreadable-flattens-onto-one-line 1 \
  "$(wc -l <<<"$AUD_OUT" | tr -d ' ')"
# jq's own parse error goes to a terminal where nothing correlates it with a
# row; the `read:` line above is the report the row carries.
AUD_OUT="$(rehearsal_attention_audit_labels_from_json "$AUD_JUNK" 2>&1 >/dev/null)"
t attention-audit-unreadable-read-is-quiet-on-stderr '' "$AUD_OUT"

# The cleanup CALLS, staged under a stubbed gh(): both flags dropped, both
# objects closed, the fixture branch deleted. This is the EXIT-trap path, which
# no drill host is needed to exercise.
AUD_CALLS="$TMP/attention-audit-cleanup-calls"
: >"$AUD_CALLS"
(
  gh() { printf '%s\n' "$*" >>"$AUD_CALLS"; }
  REHEARSAL_ATTENTION_AUDIT_REPO="$AUD_REPO"
  REHEARSAL_ATTENTION_AUDIT_PR="$AUD_PR"
  REHEARSAL_ATTENTION_AUDIT_ISSUE="$AUD_ISSUE"
  REHEARSAL_ATTENTION_AUDIT_BRANCH=drill-attention-audit-120000
  rehearsal_attention_audit_cleanup
)
t attention-audit-cleanup-drops-both-flags 2 \
  "$(grep -cE "api -X DELETE repos/$AUD_REPO/issues/(91|92)/labels/attention" \
    "$AUD_CALLS" | tr -d ' ')"
t attention-audit-cleanup-closes-both-objects 2 \
  "$(grep -cE "api -X PATCH repos/$AUD_REPO/issues/(91|92) -f state=closed" \
    "$AUD_CALLS" | tr -d ' ')"
t attention-audit-cleanup-deletes-the-fixture-branch 1 \
  "$(grep -cF "api -X DELETE repos/$AUD_REPO/git/refs/heads/drill-attention-audit-120000" \
    "$AUD_CALLS" | tr -d ' ')"
# Nothing registered, nothing called: the trap fires on every round, including
# the ones that never reached the leg.
: >"$AUD_CALLS"
(
  gh() { printf '%s\n' "$*" >>"$AUD_CALLS"; }
  # shellcheck disable=SC2030  # the empty registry is this subshell's fixture
  REHEARSAL_ATTENTION_AUDIT_REPO=""
  rehearsal_attention_audit_cleanup
)
t attention-audit-cleanup-without-a-registry-calls-nothing 0 \
  "$(wc -l <"$AUD_CALLS" | tr -d ' ')"
# The filer registers each object THE MOMENT it exists. A creation that fails
# after the issue is filed must still leave that issue in the trap's registry,
# or the round leaks a flagged issue onto the sandbox.
(
  # shellcheck disable=SC2317  # invoked indirectly, by the filer under test
  gh() {
    case "$*" in
      *"repos/$AUD_REPO/issues -f title"*) printf '%s\n' "$AUD_ISSUE" ;;
      *) return 1 ;;
    esac
  }
  # shellcheck disable=SC2030  # the registry is read inside this subshell
  REHEARSAL_ATTENTION_AUDIT_ISSUE=""
  rehearsal_attention_audit_file_fixtures "$AUD_REPO" 120000 >/dev/null 2>&1
  # shellcheck disable=SC2031  # ...and printed from it, before it is lost
  printf '%s %s\n' "$REHEARSAL_ATTENTION_AUDIT_REPO" \
    "$REHEARSAL_ATTENTION_AUDIT_ISSUE" >"$TMP/attention-audit-partial"
)
t attention-audit-partial-filing-still-registers-the-issue "$AUD_REPO $AUD_ISSUE" \
  "$(cat "$TMP/attention-audit-partial")"

# The invocation SCRIPT, read off the text the leg actually sends through bx().
# §1: the module is sourced and the function called directly, after load_conf,
# and nothing under the installed conf or lib is written — the leg observes the
# hourly slot's behaviour without becoming a second writer of its scheduling.
AUD_SCRIPT="$(
  bx() { printf '%s' "$1"; }
  rehearsal_attention_audit_invoke /tmp/attention-audit-capture
)"
t attention-audit-invocation-calls-the-module-directly 1 \
  "$(grep -cx ' *duty_attention_audit' <<<"$AUD_SCRIPT" | tr -d ' ')"
t attention-audit-invocation-follows-load-conf 1 \
  "$(awk '/load_conf/ { seen = 1 } seen && /duty-attention\.sh/ { print; exit }' \
    <<<"$AUD_SCRIPT" | wc -l | tr -d ' ')"
t attention-audit-invocation-writes-no-installed-file 0 \
  "$(grep -cE '(>>?|tee |sed -i|cp ).*duty/(conf|lib)' <<<"$AUD_SCRIPT" | tr -d ' ')"
# It does NOT tick: a tick would run the wake, the sweep and whatever else the
# role carries, and the rows below would then be reading somebody else's work.
t attention-audit-invocation-does-not-tick 0 \
  "$(grep -cF 'tick.sh' <<<"$AUD_SCRIPT" | tr -d ' ')"
# The alert override EXECUTED, not a prebuilt string handed to the predicate.
# One escaping level too deep captures the literal $* and no alert can ever
# match, so every transition row would red against a correct engine.
AUD_CAPTURE="$TMP/attention-audit-alert-capture"
: >"$AUD_CAPTURE"
AUD_ALERT_DEF="$(
  bx() { printf '%s' "$1"; }
  rehearsal_attention_audit_invoke "$AUD_CAPTURE"
)"
AUD_ALERT_DEF="$(grep -F 'alert()' <<<"$AUD_ALERT_DEF")"
bash -c "$AUD_ALERT_DEF; alert '$AUD_ALERT_BOTH'"
t attention-audit-generated-alert-expands-its-arguments 0 \
  "$(grep -cFx '$*' "$AUD_CAPTURE" | tr -d ' ')"
if rehearsal_attention_audit_alert_count_is 1 '🚨' "$(cat "$AUD_CAPTURE")" >/dev/null; then
  r1=counted
else
  r1=WRONG
fi
t attention-audit-generated-alert-capture-feeds-the-row counted "$r1"

# The hourly slot's clock: deferred for the leg's duration, handed back after.
# duty.sh's own hygiene slot calls duty_attention_audit and shares ONE state
# file with this leg, so a cron tick landing between two calls would write the
# malformed set first and the leg's 🚨 would be correctly suppressed — a red on
# a working engine, in the row whose whole subject is suppression.
AUD_SCRIPT="$(
  bx() { printf '%s' "$1"; }
  rehearsal_attention_audit_defer_hygiene
)"
# shellcheck disable=SC2016  # the needle is box-side source text, not an expansion
t attention-audit-deferral-stamps-the-hygiene-clock 1 \
  "$(grep -cF 'date +%s > "$HOME/duty/.hygiene-last"' <<<"$AUD_SCRIPT" | tr -d ' ')"
AUD_SCRIPT="$(
  bx() { printf '%s' "$1"; }
  rehearsal_attention_audit_restore_hygiene 1754740000
)"
t attention-audit-restore-writes-back-the-value-it-found 1 \
  "$(grep -cF "printf '%s\\n' '1754740000'" <<<"$AUD_SCRIPT" | tr -d ' ')"
# A box that had no clock file must be handed back no clock file, not a zero.
AUD_SCRIPT="$(
  bx() { printf '%s' "$1"; }
  rehearsal_attention_audit_restore_hygiene ''
)"
# shellcheck disable=SC2016  # the needle is box-side source text, not an expansion
t attention-audit-restore-of-an-absent-clock-removes-it 1 \
  "$(grep -cF 'rm -f "$HOME/duty/.hygiene-last"' <<<"$AUD_SCRIPT" | tr -d ' ')"
if rehearsal_attention_audit_hygiene_clock_restored 1754740000 1754740000 >/dev/null; then
  r1=restored
else
  r1=WRONG
fi
t attention-audit-clock-restored-holds restored "$r1"
AUD_OUT="$(aud_row "attention-audit: the hourly slot's clock is handed back" \
  rehearsal_attention_audit_hygiene_clock_restored 1754740000 1754743600)"
t attention-audit-a-moved-clock-reds 1 \
  "$(grep -cFx "FAIL attention-audit: the hourly slot's clock is handed back" <<<"$AUD_OUT")"
t attention-audit-moved-clock-red-quotes-both-readings 1 \
  "$(grep -cF 'read: hygiene clock before=1754740000 after=1754743600' <<<"$AUD_OUT")"

# --- the clock's FAILURE path: an interrupted round hands it back too -------
#
# The leg's own returns are not the only way out. rehearsal.sh runs under a
# trap and its INT/TERM path exits through cleanup_all, which reaches this
# leg only via rehearsal_attention_audit_cleanup — so a round killed between
# the deferral and the leg's restore would otherwise leave the retained triage
# box carrying a clock stamped into this round, postponing its next hourly
# hygiene slot by up to one HYGIENE_INTERVAL. Every case below drives the REAL
# cleanup, with bx() recording the box-side script it is handed.
AUD_CLOCK_CALLS="$TMP/attention-audit-clock-calls"
: >"$AUD_CLOCK_CALLS"
(
  bx() { printf '%s\n' "$1" >>"$AUD_CLOCK_CALLS"; }
  # EMPTY registry, deliberately: the clock is armed before the board is read
  # and long before any fixture exists, so this is the state the interrupt
  # window actually opens in — and a restore placed behind the cleanup's
  # empty-registry return would answer 0 here and hand the clock back never.
  # shellcheck disable=SC2030  # the empty registry is this subshell's fixture
  REHEARSAL_ATTENTION_AUDIT_REPO=""
  rehearsal_attention_audit_arm_clock 1754740000
  rehearsal_attention_audit_defer_hygiene >/dev/null
  rehearsal_attention_audit_cleanup
)
t attention-audit-an-interrupt-after-the-deferral-restores-the-clock 1 \
  "$(grep -cF "printf '%s\\n' '1754740000'" "$AUD_CLOCK_CALLS" | tr -d ' ')"
# ...and the box that had NO clock is handed back no clock, on this path too:
# writing an empty file where there was none is its own mutation of the slot.
: >"$AUD_CLOCK_CALLS"
(
  bx() { printf '%s\n' "$1" >>"$AUD_CLOCK_CALLS"; }
  # shellcheck disable=SC2030  # the empty registry is this subshell's fixture
  REHEARSAL_ATTENTION_AUDIT_REPO=""
  rehearsal_attention_audit_arm_clock ''
  rehearsal_attention_audit_defer_hygiene >/dev/null
  rehearsal_attention_audit_cleanup
)
# shellcheck disable=SC2016  # the needle is box-side source text, not an expansion
t attention-audit-an-interrupt-restores-an-absent-clock-by-removing-it 1 \
  "$(grep -cF 'rm -f "$HOME/duty/.hygiene-last"' "$AUD_CLOCK_CALLS" | tr -d ' ')"
# Idempotent, because BOTH doors are used on a normal round: the leg restores
# on its way out and the trap fires afterwards. A second write would land on a
# clock the box may legitimately have re-stamped in between, which is the
# defect this fix exists to remove, arriving from the other side.
: >"$AUD_CLOCK_CALLS"
(
  bx() { printf '%s\n' "$1" >>"$AUD_CLOCK_CALLS"; }
  # shellcheck disable=SC2030  # the empty registry is this subshell's fixture
  REHEARSAL_ATTENTION_AUDIT_REPO=""
  rehearsal_attention_audit_arm_clock 1754740000
  rehearsal_attention_audit_restore_clock
  rehearsal_attention_audit_cleanup
  rehearsal_attention_audit_cleanup
)
t attention-audit-the-clock-is-handed-back-once-however-many-unwinds 1 \
  "$(grep -cF "printf '%s\\n' '1754740000'" "$AUD_CLOCK_CALLS" | tr -d ' ')"
# A round that never reached the leg must not write a clock at all. The trap
# fires on EVERY round, including the builder's and the reviewer's, and an
# unconditional restore would stamp `.hygiene-last` on a box this leg never
# touched — a scheduling mutation invented by the cleanup itself.
: >"$AUD_CLOCK_CALLS"
(
  bx() { printf '%s\n' "$1" >>"$AUD_CLOCK_CALLS"; }
  # shellcheck disable=SC2030  # the empty registry is this subshell's fixture
  REHEARSAL_ATTENTION_AUDIT_REPO=""
  REHEARSAL_ATTENTION_AUDIT_CLOCK_ARMED=0
  rehearsal_attention_audit_cleanup
)
t attention-audit-an-unarmed-cleanup-touches-no-clock 0 \
  "$(wc -l <"$AUD_CLOCK_CALLS" | tr -d ' ')"
# A restore that FAILED stays armed, so the trap's call is a retry and not a
# no-op. Disarming on the attempt rather than on the result would hand the box
# back a moved clock and say nothing about it.
: >"$AUD_CLOCK_CALLS"
(
  # shellcheck disable=SC2317  # invoked indirectly, by the restore under test
  bx() { printf '%s\n' "$1" >>"$AUD_CLOCK_CALLS"; return 1; }
  # shellcheck disable=SC2030  # the empty registry is this subshell's fixture
  REHEARSAL_ATTENTION_AUDIT_REPO=""
  rehearsal_attention_audit_arm_clock 1754740000
  rehearsal_attention_audit_restore_clock >/dev/null 2>&1 || true
  rehearsal_attention_audit_cleanup
)
t attention-audit-a-failed-restore-is-retried-by-the-trap 2 \
  "$(grep -cF "printf '%s\\n' '1754740000'" "$AUD_CLOCK_CALLS" | tr -d ' ')"
# The arming precedes the WRITE it unwinds, in the leg's own source order. An
# arm placed after the deferral leaves a window whose whole width is the write
# the unwind exists for.
# shellcheck disable=SC2016  # match the literal call site in the leg's source
AUD_ARM_LINE="$(grep -nF 'rehearsal_attention_audit_arm_clock "$clock_before"' \
  "$ROOT/drill/rehearsal-attention-audit.sh" | head -1 | cut -d: -f1)"
AUD_DEFER_CALL_LINE="$(grep -nF 'rehearsal_attention_audit_defer_hygiene >/dev/null' \
  "$ROOT/drill/rehearsal-attention-audit.sh" | head -1 | cut -d: -f1)"
if [ -n "$AUD_ARM_LINE" ] && [ -n "$AUD_DEFER_CALL_LINE" ] \
    && [ "$AUD_ARM_LINE" -lt "$AUD_DEFER_CALL_LINE" ]; then
  r1=armed-first
else
  r1=WRONG
fi
t attention-audit-the-clock-is-armed-before-it-is-deferred armed-first "$r1"
# ...and the unwind sits ahead of the cleanup's empty-registry return, which is
# the state the interrupt window opens in.
AUD_CLEANUP_SRC="$TMP/attention-audit-cleanup-src"
awk '/^rehearsal_attention_audit_cleanup\(\) \{$/,/^\}$/' \
  "$ROOT/drill/rehearsal-attention-audit.sh" >"$AUD_CLEANUP_SRC"
AUD_RESTORE_LINE="$(grep -nF 'rehearsal_attention_audit_restore_clock' \
  "$AUD_CLEANUP_SRC" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # match the literal guard text, not an expansion
AUD_GUARD_LINE="$(grep -nF '[ -n "$repo" ] || return 0' \
  "$AUD_CLEANUP_SRC" | head -1 | cut -d: -f1)"
if [ -n "$AUD_RESTORE_LINE" ] && [ -n "$AUD_GUARD_LINE" ] \
    && [ "$AUD_RESTORE_LINE" -lt "$AUD_GUARD_LINE" ]; then
  r1=ahead
else
  r1=WRONG
fi
t attention-audit-the-unwind-precedes-the-empty-registry-return ahead "$r1"

# The state file the transition rows read is cleared before call 1, or a stale
# non-empty set makes call 1 emit ✅ and the clean-board row reds on a correct
# engine.
AUD_SCRIPT="$(
  bx() { printf '%s' "$1"; }
  rehearsal_attention_audit_clear_state
)"
# shellcheck disable=SC2016  # the needle is box-side source text, not an expansion
t attention-audit-state-cleared-before-the-first-call 1 \
  "$(grep -cF 'rm -f "$HOME/duty/.attention-malformed"' <<<"$AUD_SCRIPT" | tr -d ' ')"

# --- the leg's own bookkeeping: a red row must reach the verdict ------------
#
# rehearsal-all.sh reads this leg's summary row off its return code. A red row
# that cannot reach that return code prints `ok attention-audit` into the round
# summary and into drills/<version>.md for a round that asserted nothing — the
# #423 defect, relocated into this leg's bookkeeping.
#
# Staged as the leg actually runs, with the filer, the invoker, the board reads
# and bx() stubbed; each mutation is one realistic blip, not a broken engine.
aud_leg() {  # rows on stdout, the leg's rc as the exit status
  (
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    skip() { printf 'skip %s\n' "$1"; }
    # rehearsal.sh's wait_for, minus the sleeping.
    wait_for() {
      local name="$2"; shift 2
      if "$@" >/dev/null 2>&1; then ok "$name"; return 0; fi
      fail "$name (timeout)"; return 1
    }
    bx() { printf '/home/drill\n'; }
    rehearsal_attention_audit_board_clean() { return "${AUD_BOARD_DIRTY:-0}"; }
    rehearsal_attention_audit_flagged_numbers() { printf '%s\n' "${AUD_FLAGGED:-}"; }
    # shellcheck disable=SC2317  # invoked indirectly, by the leg under test
    rehearsal_attention_audit_both_visible() { return 0; }
    # shellcheck disable=SC2317  # invoked indirectly, by the leg under test
    rehearsal_attention_audit_neither_visible() { return 0; }
    rehearsal_attention_audit_defer_hygiene() { return 0; }
    rehearsal_attention_audit_restore_hygiene() { return 0; }
    rehearsal_attention_audit_clear_state() { return 0; }
    rehearsal_attention_audit_clear_flags() { return 0; }
    # The stubbed cleanup leaves a MARKER rather than doing nothing: the board
    # is read once before it (the non-repair rows) and once after it (the
    # removal row), and a stub that answered both reads identically would make
    # one of the two rows unfalsifiable.
    rehearsal_attention_audit_cleanup() { printf 'done' >"$TMP/aud-cleaned"; }
    rehearsal_attention_audit_hygiene_clock() { printf '1754740000\n'; }
    rehearsal_attention_audit_file_fixtures() {
      REHEARSAL_ATTENTION_AUDIT_REPO="$AUD_REPO"
      REHEARSAL_ATTENTION_AUDIT_PR="$AUD_PR"
      REHEARSAL_ATTENTION_AUDIT_ISSUE="$AUD_ISSUE"
      return "${AUD_FILE_RC:-0}"
    }
    # One call per invocation, counted in a FILE: the calls happen inside
    # command substitutions and a shell variable would go with the subshell.
    rehearsal_attention_audit_invoke() {
      local n
      n=$(( $(cat "$TMP/aud-calls") + 1 ))
      printf '%s' "$n" >"$TMP/aud-calls"
      case "$n" in
        2) printf '%s\n' "${AUD_OUT_2:-$AUD_REPORT_BOTH}" ;;
        3) printf '%s\n' "${AUD_OUT_3:-2026-08-09T12:00:00Z attention audit}" ;;
        4) printf '%s\n' "${AUD_OUT_4:-2026-08-09T12:00:00Z attention audit}" ;;
        *) printf '2026-08-09T12:00:00Z attention audit\n' ;;
      esac
    }
    rehearsal_attention_audit_read_capture() {
      local n
      n="$(cat "$TMP/aud-calls")"
      case "$n" in
        2) printf '%s\n' "${AUD_CAP_2:-$AUD_ALERT_BOTH}" ;;
        3) printf '%s\n' "${AUD_CAP_3:-}" ;;
        # `-`, not `:-`: the missing-✅ mutation IS the empty capture, and a
        # colon default would silently hand it the passing one instead.
        4) printf '%s\n' "${AUD_CAP_4-$AUD_ALERT_CLEAR}" ;;
        *) printf '%s\n' "${AUD_CAP_1:-}" ;;
      esac
    }
    gh() {
      local cleaned=0
      [ -f "$TMP/aud-cleaned" ] && cleaned=1
      case "$*" in
        *"/comments"*) printf '%s\n' "${AUD_COMMENTS:-[]}" ;;
        *"issues/$AUD_PR")
          if [ "$cleaned" -eq 1 ]; then
            printf '%s\n' "${AUD_PR_AFTER:-$AUD_GONE}"
          else
            printf '%s\n' "${AUD_PR_READ:-$AUD_PR_FLAGGED}"
          fi ;;
        *"issues/$AUD_ISSUE")
          if [ "$cleaned" -eq 1 ]; then
            printf '%s\n' "${AUD_ISSUE_AFTER:-$AUD_GONE}"
          else
            printf '%s\n' "${AUD_ISSUE_READ:-$AUD_ISSUE_FLAGGED}"
          fi ;;
        *) printf '%s\n' '{}' ;;
      esac
    }
    jq() { command jq "$@"; }
    rehearsal_attention_audit_drill "$AUD_REPO" "$AUD_IDENTITY"
  )
}
aud_run() {  # aud_run — reset the call counter and the cleanup marker
  printf '0' >"$TMP/aud-calls"
  rm -f "$TMP/aud-cleaned"
  aud_leg
}

# The control: every stub green, and the leg is an all-ok round.
if AUD_OUT="$(aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-control-is-green 0 "$aud_rc"
t attention-audit-leg-control-has-no-red-row 0 \
  "$(grep -c '^FAIL ' <<<"$AUD_OUT")"
# Every §3/§4/§5 row present, and each its OWN summary row so
# drills/<version>.md records them separately.
t attention-audit-leg-control-row-count 18 \
  "$(grep -c '^ok   attention-audit: ' <<<"$AUD_OUT")"

# The three acceptance mutations, run against the LEG rather than a predicate:
# each must reach the leg's return code, not just print a red row.
if AUD_OUT="$(AUD_OUT_2="$AUD_REPORT_PR_ONLY" aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-report-naming-only-the-pr-reds-the-leg 1 "$aud_rc"
t attention-audit-leg-report-mutation-names-its-row 1 \
  "$(grep -cFx 'FAIL attention-audit: report names both malformed shapes' <<<"$AUD_OUT")"
if AUD_OUT="$(AUD_ISSUE_READ="$AUD_ISSUE_REPAIRED" aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-a-repaired-flag-reds-the-leg 1 "$aud_rc"
t attention-audit-leg-repair-mutation-names-its-row 1 \
  "$(grep -cFx 'FAIL attention-audit: both flags still set' <<<"$AUD_OUT")"
if AUD_OUT="$(AUD_CAP_3="$AUD_ALERT_BOTH" aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-a-second-alert-reds-the-leg 1 "$aud_rc"
t attention-audit-leg-second-alert-mutation-names-its-row 1 \
  "$(grep -cFx 'FAIL attention-audit: an unchanged board adds no further alert' <<<"$AUD_OUT")"
# ...and the rest of the test plan's must-fail list.
if AUD_OUT="$(AUD_ISSUE_READ="$AUD_ISSUE_ASSIGNED" aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-an-assigned-fixture-reds-the-leg 1 "$aud_rc"
if AUD_OUT="$(AUD_COMMENTS="$AUD_IDENTITY_COMMENT" aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-a-comment-reds-the-leg 1 "$aud_rc"
if AUD_OUT="$(AUD_CAP_4='' aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-a-missing-clear-alert-reds-the-leg 1 "$aud_rc"
if AUD_OUT="$(AUD_CAP_1="$AUD_ALERT_BOTH" aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-an-alert-on-a-clean-board-reds-the-leg 1 "$aud_rc"
# #59's other half, the one that lands in duty.log: a standing malformed set
# re-reported every hour is the loud-and-expensive bug the suppression replaced,
# and the alert rows cannot see it — the two suppressions are separate.
if AUD_OUT="$(AUD_OUT_3="$AUD_REPORT_BOTH" aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-a-repeated-report-reds-the-leg 1 "$aud_rc"
t attention-audit-leg-repeated-report-names-its-row 1 \
  "$(grep -cFx 'FAIL attention-audit: an unchanged board writes no further report' <<<"$AUD_OUT")"
if AUD_OUT="$(AUD_OUT_4="$AUD_REPORT_BOTH" aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-a-report-on-the-clear-reds-the-leg 1 "$aud_rc"
t attention-audit-leg-report-on-the-clear-names-its-row 1 \
  "$(grep -cFx 'FAIL attention-audit: the cleared board writes no report' <<<"$AUD_OUT")"

# A fixture that survives the cleanup reds the leg, which is the row that makes
# the cleanup a proof rather than a claim.
if AUD_OUT="$(AUD_PR_AFTER="$AUD_PR_FLAGGED" AUD_ISSUE_AFTER="$AUD_ISSUE_FLAGGED" aud_run)"; then
  aud_rc=0
else
  aud_rc=$?
fi
t attention-audit-leg-a-surviving-fixture-reds-the-leg 1 "$aud_rc"
t attention-audit-leg-surviving-fixture-names-its-row 1 \
  "$(grep -cFx 'FAIL attention-audit: both fixtures removed from the board' <<<"$AUD_OUT")"

# A sandbox that already carries a flagged object is a refused round, not a
# green one: "silent on a clean board" would otherwise be a statement about a
# board that was never clean.
if AUD_OUT="$(AUD_BOARD_DIRTY=1 AUD_FLAGGED=7 aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-a-dirty-sandbox-refuses 1 "$aud_rc"
t attention-audit-leg-dirty-sandbox-names-what-it-read 1 \
  "$(grep -cF 'read: 7' <<<"$AUD_OUT")"
# ...and it hands the clock back on the way out, exactly as the green path does.
if AUD_OUT="$(AUD_FILE_RC=1 aud_run)"; then aud_rc=0; else aud_rc=$?; fi
t attention-audit-leg-an-unfiled-fixture-refuses 1 "$aud_rc"

# The verdict lines the aggregate row is folded from.
AUD_VERDICTS="$TMP/attention-audit-leg-verdicts"
: >"$AUD_VERDICTS"
REHEARSAL_ATTENTION_AUDIT_STATUS="$AUD_VERDICTS" aud_run >/dev/null
t attention-audit-green-leg-records-an-ok-verdict 1 \
  "$(grep -c ' ok ' "$AUD_VERDICTS" | tr -d ' ')"
: >"$AUD_VERDICTS"
REHEARSAL_ATTENTION_AUDIT_STATUS="$AUD_VERDICTS" AUD_CAP_3="$AUD_ALERT_BOTH" \
  aud_run >/dev/null
t attention-audit-red-leg-records-a-fail-verdict 1 \
  "$(grep -c ' fail ' "$AUD_VERDICTS" | tr -d ' ')"
# The opt-out is a skip with a reason, never a silent pass.
: >"$AUD_VERDICTS"
(
  # shellcheck disable=SC2030  # the fixture role is intentionally local
  ROLE=triage
  REHEARSAL_ATTENTION_AUDIT_STATUS="$AUD_VERDICTS"
  REHEARSAL_ATTENTION_AUDIT_DRILL=0
  skip() { :; }
  rehearsal_attention_audit_drill "$AUD_REPO" "$AUD_IDENTITY" >/dev/null
)
t attention-audit-verdict-opt-out-is-a-skip "triage skip --no-attention-audit-drill" \
  "$(cat "$AUD_VERDICTS")"

# No agent or box name in the leg: the identity and the sandbox reach every
# assertion from the round's own variables.
t attention-audit-leg-names-no-agent-or-box 0 \
  "$(grep -ciE 'claude|codex|grok|kimi|crew-drill' \
    "$ROOT/drill/rehearsal-attention-audit.sh" | tr -d ' ')"

# Wiring: sourced and called in the TRIAGE block — the hygiene slot is
# triage-only — and after the existing triage assertions, which are unchanged.
# shellcheck disable=SC2016  # match literal triage-block source text
attention_audit_triage_block="$(sed -n '/if \[ "$ROLE" = "triage" \]/,/^[[:space:]]*elif /p' \
    "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # match literal triage-block source text
if grep -Fq '. "$ROOT/drill/rehearsal-attention-audit.sh"' <<<"$attention_audit_triage_block"; then
  r1=wired
else
  r1=MISSING
fi
t attention-audit-helper-sourced-in-triage-block wired "$r1"
AUD_PM_LINE="$(grep -nF 'triage: post-merge-only tick launched no session' \
  "$ROOT/drill/rehearsal.sh" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # match the literal call site in rehearsal.sh
AUD_LEG_LINE="$(grep -nF 'rehearsal_attention_audit_drill "$SANDBOX"' \
  "$ROOT/drill/rehearsal.sh" | head -1 | cut -d: -f1)"
if [ -n "$AUD_PM_LINE" ] && [ -n "$AUD_LEG_LINE" ] && [ "$AUD_PM_LINE" -lt "$AUD_LEG_LINE" ]; then
  r1=after
else
  r1=WRONG
fi
t attention-audit-leg-follows-the-existing-triage-rows after "$r1"
# The EXIT trap reaches this leg's registry too, or a red round leaks a flagged
# pull request and a flagged unassigned issue onto the sandbox.
t attention-audit-cleanup-armed-in-the-exit-trap 1 \
  "$(grep -cF 'rehearsal_attention_audit_cleanup || true' "$ROOT/drill/rehearsal.sh" | tr -d ' ')"
if grep -Fq -- '--no-attention-audit-drill' "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'attention-audit  (both shapes reported, not repaired, alerts on transition)' \
      "$ROOT/drill/rehearsal-all.sh"; then
  r1=wired
else
  r1=MISSING
fi
t attention-audit-all-opt-out-and-summary-wired wired "$r1"
# The aggregate row is gated on the TRIAGE role, not the builder's: this leg
# runs in the only role block whose duty carries the hourly slot.
t attention-audit-aggregate-row-gates-on-the-triage-role 1 \
  "$(grep -cF 'INCOMPLETE attention-audit  (triage role omitted)' \
    "$ROOT/drill/rehearsal-all.sh" | tr -d ' ')"

# --- rehearsal boot-check verdict: what the gate SAID, not that it ran (#427) ---
# The drill's assertion was `test -s ~/duty/boot-check.log`, which passes on a
# FAILED probe line and on a log full of WARN. Every mutation below is staged
# against the input the assertion actually reads — a fixture boot-check.log
# under a stubbed bx() — so the decision boundary runs here without a drill
# host, a box or a credential.
BOOT_LOG=""
boot_run() {  # boot_run <agent> <boot-check.log text>
  BOOT_LOG="$2"
  (
    bx() { printf '%s\n' "$BOOT_LOG"; }
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    rehearsal_boot_load
    rehearsal_boot_probe_ok "$1"
    rehearsal_boot_warn_free "$1"
  ) 2>&1
}

BOOT_OK_LOG="== boot check 2026-08-09T10:00:00+00:00 ==
github.com
  - Logged in to github.com account drill-bot (oauth_token)
/dev/root  49G  8.5G  38G  19% /
cli probe: ok"
BOOT_WARN_LINE='2026-08-09T10:00:00Z WARN: boot gate: auth probe failed — duty continues degraded'

# A logged-in box's boot block: both assertions green, and both rows named.
boot_out="$(boot_run kimi "$BOOT_OK_LOG")"
t rehearsal-boot-ok-verdict-passes 1 \
  "$(grep -cFx 'ok   boot check: cli probe verdict is ok for kimi' <<<"$boot_out")"
t rehearsal-boot-warn-free-passes 1 \
  "$(grep -cFx 'ok   boot check: no WARN for kimi' <<<"$boot_out")"

# Must fail: a `cli probe` verdict other than `ok` reds, naming the verdict
# and quoting the line — the two things `boot check ran` could never say.
boot_out="$(boot_run kimi "${BOOT_OK_LOG/cli probe: ok/cli probe: FAILED}")"
t rehearsal-boot-failed-verdict-mutation-reds 1 \
  "$(grep -cFx 'FAIL boot check: cli probe verdict is ok for kimi' <<<"$boot_out")"
t rehearsal-boot-failed-verdict-quotes-the-line 1 \
  "$(grep -cFx '  read: cli probe: FAILED' <<<"$boot_out")"
t rehearsal-boot-failed-verdict-names-the-verdict 1 \
  "$(grep -cFx "  verdict 'FAILED' for kimi, expected 'ok'" <<<"$boot_out")"
t rehearsal-boot-failed-verdict-leaves-warn-free-green 1 \
  "$(grep -cFx 'ok   boot check: no WARN for kimi' <<<"$boot_out")"

# Must fail: a WARN in the boot check reds, quoted — and the agent is the one
# the assertion was given, which is why this case is drilled under a second
# name. Neither assertion is spelled for an agent.
boot_out="$(boot_run grok "$BOOT_OK_LOG
$BOOT_WARN_LINE")"
t rehearsal-boot-warn-mutation-reds 1 \
  "$(grep -cFx 'FAIL boot check: no WARN for grok' <<<"$boot_out")"
t rehearsal-boot-warn-mutation-quotes-the-line 1 \
  "$(grep -cFx "    $BOOT_WARN_LINE" <<<"$boot_out")"
t rehearsal-boot-warn-mutation-names-the-agent 1 \
  "$(grep -cFx '  read: 1 WARN line(s) in the last boot block for grok, first:' <<<"$boot_out")"
t rehearsal-boot-warn-mutation-leaves-probe-green 1 \
  "$(grep -cFx 'ok   boot check: cli probe verdict is ok for grok' <<<"$boot_out")"

# The log is APPENDED to, one block per boot. A box drilled creds-free, logged
# in and re-drilled carries the pre-auth block forever: a whole-file read
# would answer for a boot other than the one under test, in both directions.
boot_out="$(boot_run kimi "== boot check 2026-08-09T09:00:00+00:00 ==
$BOOT_WARN_LINE
cli probe: FAILED
$BOOT_OK_LOG")"
t rehearsal-boot-stale-preauth-block-does-not-red 2 \
  "$(grep -c '^ok   boot check' <<<"$boot_out")"
boot_out="$(boot_run kimi "$BOOT_OK_LOG
== boot check 2026-08-09T11:00:00+00:00 ==
cli probe: FAILED")"
t rehearsal-boot-stale-ok-block-does-not-vouch 1 \
  "$(grep -cFx 'FAIL boot check: cli probe verdict is ok for kimi' <<<"$boot_out")"

# A block with no probe line at all reds naming that, rather than passing on
# the absence of a verdict it never read.
boot_out="$(boot_run codex "== boot check 2026-08-09T10:00:00+00:00 ==
/dev/root  49G  8.5G  38G  19% /")"
t rehearsal-boot-missing-probe-line-reds 1 \
  "$(grep -cFx 'FAIL boot check: cli probe verdict is ok for codex' <<<"$boot_out")"
t rehearsal-boot-missing-probe-line-says-what-it-read 1 \
  "$(grep -cFx "  read: no 'cli probe:' line in the last boot block for codex" <<<"$boot_out")"

# A box that stopped answering leaves the block empty. BOTH rows red on that —
# an unreadable log is not a verdict, and it is not a clean boot either: the
# WARN-free row greening here would score the box's silence as proof, which is
# the `test -s` mistake this whole block exists to undo. Both name the read
# rather than the log's shape, so the operator chases the box and not a boot
# log that was fine. `boot check ran` cannot cover this: it is a separate box
# request, and a box can stop answering between the two.
boot_out="$(
  (
    bx() { return 1; }
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    rehearsal_boot_load
    rehearsal_boot_probe_ok claude
    rehearsal_boot_warn_free claude
  ) 2>&1
)"
t rehearsal-boot-unreadable-log-reds 1 \
  "$(grep -cFx 'FAIL boot check: cli probe verdict is ok for claude' <<<"$boot_out")"
t rehearsal-boot-unreadable-log-reds-the-warn-free-row 1 \
  "$(grep -cFx 'FAIL boot check: no WARN for claude' <<<"$boot_out")"
t rehearsal-boot-unreadable-log-greens-neither-row 0 \
  "$(grep -c '^ok   boot check' <<<"$boot_out")"
t rehearsal-boot-unreadable-log-names-the-read-on-both-rows 2 \
  "$(grep -cFx '  read: nothing — ~/duty/boot-check.log did not come back from the box for claude' <<<"$boot_out")"

# A read that SUCCEEDED and came back empty is a different fact from a box that
# never answered, and the WARN-free row may not green on it either: `grep`
# finding no WARN in an empty block certifies a boot it never saw.
boot_out="$(boot_run claude "")"
t rehearsal-boot-empty-block-reds-the-warn-free-row 1 \
  "$(grep -cFx 'FAIL boot check: no WARN for claude' <<<"$boot_out")"
t rehearsal-boot-empty-block-says-what-it-read 1 \
  "$(grep -cFx '  read: an empty last boot block for claude — no WARN in nothing is not a clean boot' <<<"$boot_out")"

# No agent name appears in the assertions: the agent is the argument, and the
# call site passes $AGENT.
boot_names=0
for boot_profile in "$SHARED"/conf/agents/*.conf; do
  if grep -Fqi "$(basename "$boot_profile" .conf)" "$ROOT/drill/rehearsal-boot.sh"; then
    boot_names=$((boot_names + 1))
  fi
done
t rehearsal-boot-no-agent-name-in-the-assertions 0 "$boot_names"

# `boot check ran` survives and still fires first, so an empty log keeps
# reading the way it does today.
boot_ran_line="$(grep -n 'check "boot check ran"' "$ROOT/drill/rehearsal.sh" \
  | head -1 | cut -d: -f1)"
boot_load_line="$(grep -n 'rehearsal_boot_load' "$ROOT/drill/rehearsal.sh" \
  | head -1 | cut -d: -f1)"
if [ -n "$boot_ran_line" ] && [ -n "$boot_load_line" ] \
    && [ "$boot_ran_line" -lt "$boot_load_line" ]; then
  r1=first
else
  r1=MISORDERED
fi
t rehearsal-boot-ran-still-fires-first first "$r1"

# shellcheck disable=SC2016  # match the literal source line and the $AGENT rows
if grep -Fq '. "$ROOT/drill/rehearsal-boot.sh"' "$ROOT/drill/rehearsal.sh" \
    && grep -Fq 'rehearsal_boot_probe_ok "$AGENT"' "$ROOT/drill/rehearsal.sh" \
    && grep -Fq 'rehearsal_boot_warn_free "$AGENT"' "$ROOT/drill/rehearsal.sh"; then
  r1=wired
else
  r1=MISSING
fi
t rehearsal-boot-helper-sourced-and-called-with-the-drilled-agent wired "$r1"

# The pre-auth arm records both as skips with their reasons, never as passes —
# and each reason must be TRUE of the file its assertion reads. Pin the reasons
# and not the prefix: `(box is not gh-authenticated` is shared by every wording
# a row could carry, including the one triage struck at `09:2xZ`, so a case
# grepping only that far passes on a false explanation as readily as on the
# right one. Distinctive substring per row, so a reword stays free and a
# reason swap does not.
# shellcheck disable=SC2016  # match the literal $AGENT skip rows
boot_skip_probe='skip "boot check: cli probe verdict is ok for $AGENT (box is not gh-authenticated'
# shellcheck disable=SC2016
boot_skip_warn='skip "boot check: no WARN for $AGENT (box is not gh-authenticated'
if ! grep -Fq "$boot_skip_probe" "$ROOT/drill/rehearsal.sh"; then
  r1=PROBE-ROW-MISSING
elif ! grep -Fq "$boot_skip_warn" "$ROOT/drill/rehearsal.sh"; then
  r1=WARN-ROW-MISSING
else
  boot_probe_row="$(grep -F "$boot_skip_probe" "$ROOT/drill/rehearsal.sh")"
  boot_warn_row="$(grep -F "$boot_skip_warn" "$ROOT/drill/rehearsal.sh")"
  if ! grep -Fq 'correct pre-auth verdict' <<<"$boot_probe_row"; then
  r1=PROBE-REASON-UNPINNED
  elif ! grep -Fq 'declined to vouch' <<<"$boot_warn_row"; then
  r1=WARN-REASON-UNPINNED
  else
  r1=skipped
  fi
fi
t rehearsal-boot-preauth-arm-skips-both-with-reasons skipped "$r1"

# And the mechanism triage measured away: the WARN-free row's reason was `the
# expected login WARN is asserted below` until `09:2xZ` proved that WARN is
# written to ~/duty/duty.log — the file `pre-auth: login WARN logged` reads —
# and never to the ~/duty/boot-check.log this row reads. Two different files,
# so the contradiction the old reason cited was never possible. Neither skip
# reason may name a file its assertion does not read; the rest of this block
# keeps saying `login WARN` legitimately, so the scan is the skip rows only.
boot_skip_rows="$(grep -F 'skip "boot check: ' "$ROOT/drill/rehearsal.sh")"
if grep -Eq 'login WARN|duty\.log' <<<"$boot_skip_rows"; then
  r1=REASON-CITES-A-FILE-IT-DOES-NOT-READ
else
  r1=own-file
fi
t rehearsal-boot-preauth-skip-reasons-name-only-the-file-they-read own-file "$r1"

# The gate itself. The case above greps only that the two skip rows EXIST, so
# it survives an `if true` — the skips live on in an `else` nothing reaches —
# and the `08:3xZ` gate would regress silently into the shape that reds every
# creds-free round. Pin the arm instead: scan up from each call to the nearest
# `if` and require it to be the gate, with nothing closing that arm in
# between. The `in between` half matters because the isolation gate above is
# spelled identically, so a deleted gate would otherwise re-anchor onto it and
# pass.
boot_arm=ok
# shellcheck disable=SC2016  # match the literal gate line, unexpanded
boot_gate='if [ "$GH_AUTHED" -eq 1 ]; then'
for boot_call in rehearsal_boot_load rehearsal_boot_probe_ok rehearsal_boot_warn_free; do
  boot_call_line="$(grep -n "^[[:space:]]*$boot_call\\b" "$ROOT/drill/rehearsal.sh" \
    | head -1 | cut -d: -f1)"
  if [ -z "$boot_call_line" ]; then boot_arm="$boot_call:UNCALLED"; break; fi
  boot_if_line="$(head -n "$boot_call_line" "$ROOT/drill/rehearsal.sh" \
    | grep -n '^[[:space:]]*if ' | tail -1 | cut -d: -f1)"
  if [ -z "$boot_if_line" ]; then boot_arm="$boot_call:UNGATED"; break; fi
  if [ "$(sed -n "${boot_if_line}p" "$ROOT/drill/rehearsal.sh")" != "$boot_gate" ]; then
    boot_arm="$boot_call:WRONG-GATE"; break
  fi
  boot_closers="$(sed -n "$((boot_if_line + 1)),$((boot_call_line - 1))p" \
    "$ROOT/drill/rehearsal.sh" | grep -cE '^[[:space:]]*(fi|else)[[:space:]]*$')"
  if [ "$boot_closers" -ne 0 ]; then boot_arm="$boot_call:OUTSIDE-THE-ARM"; break; fi
done
t rehearsal-boot-calls-sit-inside-the-gh-authed-arm ok "$boot_arm"

# #422: the real-host hygiene leg reads remote trees, the durable PR comment,
# and duty.log ordering. Keep those reads as sourceable predicates so their
# must-fail mutations run here without a host, a remote or a drill box.
HYG_TREE=$'README.md\nhygiene-fixture.txt\nhygiene-root-untracked.txt\nhygiene-untracked/nested.txt'
if rehearsal_hygiene_tip_has_all_dirt "$HYG_TREE"; then r1=complete; else r1=MISSING; fi
t rehearsal-hygiene-tip-has-all-dirt complete "$r1"
if rehearsal_hygiene_tip_has_all_dirt "${HYG_TREE%$'\n'*}"; then r1=FALSE_PASS; else r1=red; fi
t rehearsal-hygiene-missing-nested-file-reds red "$r1"
HYG_CONTENTS=$'working fixture-1\nroot fixture-1\nnested fixture-1'
if rehearsal_hygiene_tip_has_expected_contents "$HYG_CONTENTS" fixture-1; then
  r1=complete
else
  r1=MISSING
fi
t rehearsal-hygiene-tip-has-all-dirty-bytes complete "$r1"
if rehearsal_hygiene_tip_has_expected_contents \
    "${HYG_CONTENTS/root fixture-1/wrong bytes}" fixture-1; then
  r1=FALSE_PASS
else
  r1=red
fi
t rehearsal-hygiene-wrong-tip-bytes-red red "$r1"

HYG_RECORD=$'🗃️ Uncommitted work preserved before this branch\x27s worktree was removed\n`build/hygiene-builder`\x27s worktree was dirty. The work is on the `origin` remote as `wip/build/hygiene-builder`, holding 1 modified, 2 untracked file(s).\nPart of that work was **staged and differed from the working tree**, so the index has its own snapshot one commit below the tip — reach it with `git checkout FETCH_HEAD^`.'
if rehearsal_hygiene_record_names_payload "$HYG_RECORD" origin \
    wip/build/hygiene-builder; then r1=complete; else r1=MISSING; fi
t rehearsal-hygiene-record-names-payload complete "$r1"
if rehearsal_hygiene_record_names_payload \
    "${HYG_RECORD/1 modified, 2 untracked/1 modified, 1 untracked}" \
    origin wip/build/hygiene-builder; then r1=FALSE_PASS; else r1=red; fi
t rehearsal-hygiene-miscounted-record-reds red "$r1"

HYG_ORDER=$'engine: branch done\ndrill hygiene: preservation push landed\ndrill hygiene: forced removal invoked\nengine: branch removed'
if rehearsal_hygiene_push_precedes_removal "$HYG_ORDER"; then r1=ordered; else r1=WRONG; fi
t rehearsal-hygiene-push-precedes-removal ordered "$r1"
HYG_REVERSED=$'engine: branch done\ndrill hygiene: forced removal invoked\ndrill hygiene: preservation push landed\nengine: branch removed'
if rehearsal_hygiene_push_precedes_removal "$HYG_REVERSED"; then r1=FALSE_PASS; else r1=red; fi
t rehearsal-hygiene-removal-before-push-reds red "$r1"

HYG_SNAPSHOT=$' MM README.md\n?? hygiene-root-untracked.txt\n?? hygiene-untracked/nested.txt\nbytes for all three paths\nstaged bytes'
if rehearsal_hygiene_refusal_is_intact "$HYG_SNAPSHOT" "$HYG_SNAPSHOT" \
    'WARN: preservation failed; keeping worktree' ''; then r1=intact; else r1=LOST; fi
t rehearsal-hygiene-refusal-keeps-bytes-and-reports-once intact "$r1"
if rehearsal_hygiene_refusal_is_intact "$HYG_SNAPSHOT" \
    "${HYG_SNAPSHOT/hygiene-untracked\/nested.txt/REMOVED}" \
    'WARN: preservation failed; keeping worktree' ''; then r1=FALSE_PASS; else r1=red; fi
t rehearsal-hygiene-failed-push-removal-reds red "$r1"
if rehearsal_hygiene_refusal_is_intact "$HYG_SNAPSHOT" "$HYG_SNAPSHOT" \
    'WARN: preservation failed; keeping worktree' \
    'WARN: preservation failed again'; then r1=FALSE_PASS; else r1=red; fi
t rehearsal-hygiene-repeated-report-reds red "$r1"
if rehearsal_hygiene_box_path_is_resolved \
    /home/box-user/duty/.rehearsal-hygiene-refusal-ledger; then
  r1=resolved
else
  r1=WRONG
fi
t rehearsal-hygiene-ledger-is-absolute-box-path resolved "$r1"
# shellcheck disable=SC2016  # deliberate pre-fix mutation
if rehearsal_hygiene_box_path_is_resolved \
    '$HOME/duty/.rehearsal-hygiene-refusal-ledger'; then
  r1=FALSE_PASS
else
  r1=red
fi
t rehearsal-hygiene-unexpanded-ledger-path-reds red "$r1"

HYG_RESET_COMMAND=""
bx() { HYG_RESET_COMMAND="$1"; }
if rehearsal_hygiene_reset_refusal_ledger \
    /home/box-user/duty/.rehearsal-hygiene-refusal-ledger \
    && [ "$HYG_RESET_COMMAND" = \
      "rm -f '/home/box-user/duty/.rehearsal-hygiene-refusal-ledger'" ]; then
  r1=fresh
else
  r1=STALE
fi
t rehearsal-hygiene-refusal-ledger-reset-at-run-boundary fresh "$r1"

bx() {
  case "$1" in
    *"'fork' HEAD"*) return 0 ;;
    *) return 1 ;;
  esac
}
if rehearsal_hygiene_remote_is_reachable /home/box/duty/work/owner__repo fork; then
  r1=reachable
else
  r1=WRONG
fi
t rehearsal-hygiene-selected-remote-reachable reachable "$r1"
if rehearsal_hygiene_remote_is_reachable /home/box/duty/work/owner__repo origin; then
  r1=FALSE_PASS
else
  r1=red
fi
t rehearsal-hygiene-unreachable-selected-remote-reds red "$r1"

if rehearsal_hygiene_resources_are_absent '' '' 0 0; then r1=clean; else r1=WRONG; fi
t rehearsal-hygiene-two-remote-teardown-clean clean "$r1"
if rehearsal_hygiene_resources_are_absent '' \
    $'deadbeef\trefs/heads/build/hygiene-builder' 0 0; then
  r1=FALSE_PASS
else
  r1=red
fi
t rehearsal-hygiene-origin-fixture-branch-left-behind-reds red "$r1"

t rehearsal-hygiene-summary-skipped-phase-incomplete \
  "INCOMPLETE hygiene  (phase 2 skipped)" \
  "$(rehearsal_hygiene_summary 1 ' builder' 2)"
t rehearsal-hygiene-summary-failure-stays-failure \
  "FAIL       hygiene" "$(rehearsal_hygiene_summary 1 ' builder' 1)"
t rehearsal-hygiene-mixed-fail-then-skip-stays-failure 1 \
    "$(rehearsal_hygiene_combine_result \
      "$(rehearsal_hygiene_combine_result 2 1)" 2)"
t rehearsal-hygiene-mixed-fail-then-pass-stays-failure 1 \
  "$(rehearsal_hygiene_combine_result \
    "$(rehearsal_hygiene_combine_result 2 1)" 0)"
t rehearsal-hygiene-mixed-skip-then-pass-is-ok 0 \
    "$(rehearsal_hygiene_combine_result \
      "$(rehearsal_hygiene_combine_result 2 2)" 0)"
t rehearsal-hygiene-failure-reds-green-round 1 \
  "$(rehearsal_hygiene_round_result 0 1)"
t rehearsal-hygiene-pass-does-not-clear-incomplete-round 2 \
  "$(rehearsal_hygiene_round_result 2 0)"
t rehearsal-hygiene-phase1-failure-does-not-red-green-leg \
  "ok         hygiene  (preservation + refusal)" \
  "$(rehearsal_hygiene_summary 1 '' 0)"
HYG_RESULT_FILE="$TMP/rehearsal-hygiene-result"
REHEARSAL_HYGIENE_RESULT_FILE="$HYG_RESULT_FILE" rehearsal_hygiene_record_result 1
t rehearsal-hygiene-role-result-is-explicit 1 "$(cat "$HYG_RESULT_FILE")"

HYG_COMBINE_MUTATED="$TMP/rehearsal-hygiene-without-failure-precedence.sh"
# shellcheck disable=SC2016  # deliberate literal mutation of the precedence clause
sed 's/\[ "$current" -eq 1 \] || //' \
  "$ROOT/drill/rehearsal-hygiene.sh" >"$HYG_COMBINE_MUTATED"
if bash -c '. "$1"; [ "$(rehearsal_hygiene_combine_result 1 0)" -eq 1 ]' \
    _ "$HYG_COMBINE_MUTATED"; then
  r1=FALSE_PASS
else
  r1=red
fi
t rehearsal-hygiene-removed-failure-precedence-reds red "$r1"

HYG_ROUND_MUTATED="$TMP/rehearsal-hygiene-without-round-failure.sh"
# shellcheck disable=SC2016  # deliberate literal mutation of the failure fold
sed 's/if \[ "$hygiene_result" -eq 1 \]; then/if false; then/' \
  "$ROOT/drill/rehearsal-hygiene.sh" >"$HYG_ROUND_MUTATED"
if bash -c '. "$1"; [ "$(rehearsal_hygiene_round_result 0 1)" -eq 1 ]' \
    _ "$HYG_ROUND_MUTATED"; then
  r1=FALSE_PASS
else
  r1=red
fi
t rehearsal-hygiene-removed-round-failure-fold-reds red "$r1"

hygiene_wiring=missing
# shellcheck disable=SC2016  # these are literal wiring strings, not expansions
if grep -Fq -- '--no-hygiene-drill' "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq '. "$HERE/rehearsal-hygiene.sh"' \
      "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'hygiene  (preservation + refusal)' \
      "$ROOT/drill/rehearsal-hygiene.sh" \
    && grep -Fq '"$bad_pr" "$refusal_ledger" "$ME2"' \
      "$ROOT/drill/rehearsal-hygiene.sh" \
    && grep -Fq 'rehearsal_hygiene_reset_refusal_ledger "$refusal_ledger"' \
      "$ROOT/drill/rehearsal-hygiene.sh" \
    && grep -Fq 'REHEARSAL_HYGIENE_RESULT_FILE="$role_hygiene_file"' \
      "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'overall="$(rehearsal_hygiene_round_result "$overall" "$hygiene_result")"' \
      "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'ROLE_HYGIENE_FILES+=("$role_hygiene_file")' \
      "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'trap cleanup_role_hygiene_files EXIT' \
      "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'rehearsal_hygiene_drill "$SANDBOX" "$ROLE"' "$ROOT/drill/rehearsal.sh"; then
  hygiene_wiring=wired
fi
t rehearsal-hygiene-opt-out-summary-and-live-leg-wired wired "$hygiene_wiring"
HYG_ALL_MUTATED="$TMP/rehearsal-all-without-hygiene-source.sh"
# shellcheck disable=SC2016  # deliberate literal source-line mutation
sed '/\. "$HERE\/rehearsal-hygiene.sh"/d' \
  "$ROOT/drill/rehearsal-all.sh" >"$HYG_ALL_MUTATED"
# shellcheck disable=SC2016  # the removed source line is deliberately literal
if grep -Fq '. "$HERE/rehearsal-hygiene.sh"' "$HYG_ALL_MUTATED"; then
  r1=FALSE_PASS
else
  r1=red
fi
t rehearsal-hygiene-missing-helper-source-reds red "$r1"

suite_finish
