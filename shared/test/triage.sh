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


suite_finish
