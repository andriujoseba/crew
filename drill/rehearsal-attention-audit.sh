#!/usr/bin/env bash
# Sourceable helpers for the triage-role attention-AUDIT leg (#441). The live
# leg runs only from rehearsal.sh's authenticated triage block; every predicate
# stays here so CI can mutate its inputs — the invocation's report, the alert
# capture, the board reads — without a drill host.
#
# What this covers that nothing in drill/ read before (#441). #303 shipped
# `duty_attention_audit`, the triage-only hygiene slot's board audit, and no
# leg reads any of its three behaviours:
#
#   1. it reports BOTH malformed shapes — `attention` on a pull request, and
#      `attention` on an unassigned issue — through report_suppressed;
#   2. it never REPAIRS: the flags stay up, the issue stays unassigned, and no
#      comment is posted. The module's own comment forbids repair, and an audit
#      that quietly started moving labels would be the worse thing;
#   3. it alerts on TRANSITION only — 🚨 when the malformed set becomes
#      non-empty, ✅ when it clears, silence in between (#59).
#
# The audit exists because of a real incident: a ruling's `attention` went on a
# pull request instead of on the assigned claim it belonged to, and the wake's
# `filter=assigned` query could never return it. Both fixtures below are
# invisible to that query for exactly the same reason, which is precisely why
# they are the fixtures: neither can wake a session, so the leg cannot be green
# by accident on a board the wake was quietly clearing behind it.
#
# Why the leg calls duty_attention_audit directly (§1). The slot is hourly and
# self-scheduling; waiting for HYGIENE_INTERVAL would spend an hour of wall
# clock to re-prove scheduling, which is not this leg's subject. The behaviour
# is. So the leg sources common.sh, load_conf, sources the module and calls the
# function — the shape rehearsal-hygiene.sh already uses for _wt_release.
#
# Why the report is read off the invocation's own stdout rather than out of
# ~/duty/duty.log. They are the same bytes: log() prints to stdout and duty.sh
# is what redirects a tick into duty.log. Reading the shared file instead would
# have to diff it across a window a cron tick can write into, so a concurrent
# tick's lines would arrive inside this leg's "delta" — a report assertion that
# can pass on somebody else's report. The invocation's stdout cannot.

if ! declare -F rehearsal_verdict_record >/dev/null 2>&1; then
  # shellcheck source=drill/rehearsal-verdict.sh
  . "$(dirname "${BASH_SOURCE[0]}")/rehearsal-verdict.sh"
fi

REHEARSAL_ATTENTION_AUDIT_REPO=""
REHEARSAL_ATTENTION_AUDIT_PR=""
REHEARSAL_ATTENTION_AUDIT_ISSUE=""
REHEARSAL_ATTENTION_AUDIT_BRANCH=""

rehearsal_attention_audit_verdict() {
  rehearsal_verdict_record "${REHEARSAL_ATTENTION_AUDIT_STATUS:-}" "$@"
}

# graded NAME PREDICATE... — run the predicate, print what it read indented
# under a failure, and grade the row. §7: a red names what it read — the report
# line, the label set, the alert count — never a transcript.
#
# Deliberately this leg's own copy rather than rehearsal-attention.sh's. That
# file is a BUILDER-block leg and is sourced only there; sharing one grader
# would mean pulling a builder leg into the triage block for a six-line
# function, and the source line is the thing a reader would then have to
# discount.
rehearsal_attention_audit_graded() {
  local name="$1"; shift
  local read_back rc=0
  read_back="$("$@")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$name"
    return 0
  fi
  if [ -n "$read_back" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && echo "  read: $line"
    done <<<"$read_back"
  fi
  fail "$name"
  return 1
}

# --- pure predicates: the report (§3) --------------------------------------
#
# Each prints WHAT IT READ on stdout and returns non-zero when the fact does
# not hold, so the live row quotes the offender.

# report_suppressed renders its items as "<repo>#<num>(<CLASS>)", so the two
# needles are built from the round's own variables and the classifier's own two
# branch names. A report naming one of the two is a red: the classifier has two
# branches, and a leg that reads one proves half of it.
rehearsal_attention_audit_report_names_both() {
  local repo="$1" pr="$2" issue="$3" out="$4" line missing=""
  line="$(grep -F 'attention: malformed flag(s)' <<<"$out" | tail -1)"
  if [ -z "$line" ]; then
    printf 'no "attention: malformed flag(s)" report in the invocation output\n'
    return 1
  fi
  grep -Fq -- "$repo#$pr(PR)" <<<"$line" || missing="$repo#$pr(PR)"
  grep -Fq -- "$repo#$issue(UNASSIGNED)" <<<"$line" \
    || missing="${missing:+$missing }$repo#$issue(UNASSIGNED)"
  printf '%s\n' "$line"
  [ -z "$missing" ] || { printf 'not named: %s\n' "$missing"; return 1; }
  return 0
}

# The clean-board call must produce no report at all — not an empty one. A
# report line on an empty malformed set is report_suppressed writing state for
# nothing, and it would make the transition counts below read a previous set
# this leg never established.
rehearsal_attention_audit_no_report() {
  local out="$1" line
  line="$(grep -F 'attention: malformed flag(s)' <<<"$out" | tail -1)"
  [ -z "$line" ] || { printf '%s\n' "$line"; return 1; }
  printf 'no malformed report, as expected on a clean board\n'
  return 0
}

# --- pure predicates: the transition counts (§5) ---------------------------

# COUNTS, not presence. "🚨 appeared" is true of a board that alerted on every
# call, which is the #59 defect the suppression exists to prevent; only the
# count can tell the two apart.
rehearsal_attention_audit_alert_count() {
  local mark="$1" alerts="$2"
  # grep -c counts LINES, and returns 1 on no match — the count is still 0 and
  # that is the answer, not an error.
  grep -cF -- "$mark" <<<"$alerts" || true
}

rehearsal_attention_audit_alert_count_is() {
  local want="$1" mark="$2" alerts="$3" got
  got="$(rehearsal_attention_audit_alert_count "$mark" "$alerts")" || return 2
  printf '%s %s alert(s), wanted %s\n' "${got:-0}" "$mark" "$want"
  [ "${got:-0}" -eq "$want" ]
}

# The 🚨 renders its items as "<repo>#<num>[<CLASS>]" — square brackets, where
# the report line above uses parentheses. Two renderings of one set, and the
# leg reads each in its own shape rather than assuming they agree.
rehearsal_attention_audit_alert_names_both() {
  local mark="$1" repo="$2" pr="$3" issue="$4" alerts="$5" line missing=""
  line="$(grep -F -- "$mark" <<<"$alerts" | tail -1)"
  if [ -z "$line" ]; then
    printf 'no %s alert to read\n' "$mark"
    return 1
  fi
  grep -Fq -- "$repo#$pr[PR]" <<<"$line" || missing="$repo#$pr[PR]"
  grep -Fq -- "$repo#$issue[UNASSIGNED]" <<<"$line" \
    || missing="${missing:+$missing }$repo#$issue[UNASSIGNED]"
  printf '%s\n' "$line"
  [ -z "$missing" ] || { printf 'not named: %s\n' "$missing"; return 1; }
  return 0
}

# --- pure predicates: non-repair (§4) --------------------------------------
#
# The load-bearing half. Without these the leg would pass an audit that had
# started repairing the board, which is exactly what the module's own comment
# forbids — and a repaired board reports its malformed set correctly on the way
# past, so §3 alone cannot see it.

rehearsal_attention_audit_labels_from_json() {
  jq -r '[.labels[].name] | sort | join(" ")' <<<"$1"
}

rehearsal_attention_audit_flags_intact() {
  local mark="$1" pr_json="$2" issue_json="$3" pr_labels issue_labels
  pr_labels="$(rehearsal_attention_audit_labels_from_json "$pr_json")" || return 2
  issue_labels="$(rehearsal_attention_audit_labels_from_json "$issue_json")" || return 2
  printf 'pull request: %s\n' "${pr_labels:-<no labels>}"
  printf 'unassigned issue: %s\n' "${issue_labels:-<no labels>}"
  grep -qw -- "$mark" <<<"$pr_labels" && grep -qw -- "$mark" <<<"$issue_labels"
}

rehearsal_attention_audit_still_unassigned() {
  local issue_json="$1" assignees
  assignees="$(jq -r '[.assignees[].login] | sort | join(" ")' <<<"$issue_json")" || return 2
  printf '%s\n' "${assignees:-<unassigned>}"
  [ -z "$assignees" ]
}

# The identity comes from the round's own variable, never a name typed here.
# Counted over the whole life of both fixtures rather than a window: the
# fixtures are minted by this leg moments earlier, so every comment on them is
# inside the window anyway, and a window bound would only add a clock to
# disagree with.
rehearsal_attention_audit_comment_count() {
  local identity="$1" comments_json="$2"
  jq -r --arg identity "$identity" \
    '[ .[] | select(.user.login == $identity) ] | length' <<<"$comments_json"
}

rehearsal_attention_audit_no_identity_comment() {
  local identity="$1" pr_comments="$2" issue_comments="$3" on_pr on_issue
  on_pr="$(rehearsal_attention_audit_comment_count "$identity" "$pr_comments")" || return 2
  on_issue="$(rehearsal_attention_audit_comment_count "$identity" "$issue_comments")" || return 2
  printf '%s comment(s) on the pull request, %s on the unassigned issue\n' \
    "${on_pr:-0}" "${on_issue:-0}"
  [ "${on_pr:-0}" -eq 0 ] && [ "${on_issue:-0}" -eq 0 ]
}

# --- pure predicates: the cleanup and the deferral --------------------------

# The round PROVES the cleanup rather than asserting it in a comment: both
# fixtures re-read off the board after the leg's own cleanup ran.
rehearsal_attention_audit_fixtures_removed() {
  local mark="$1" pr_json="$2" issue_json="$3" pr_state issue_state
  local pr_labels issue_labels bad=""
  pr_state="$(jq -r '.state // "?"' <<<"$pr_json")" || return 2
  issue_state="$(jq -r '.state // "?"' <<<"$issue_json")" || return 2
  pr_labels="$(rehearsal_attention_audit_labels_from_json "$pr_json")" || return 2
  issue_labels="$(rehearsal_attention_audit_labels_from_json "$issue_json")" || return 2
  printf 'pull request: %s [%s]\n' "$pr_state" "${pr_labels:-<no labels>}"
  printf 'unassigned issue: %s [%s]\n' "$issue_state" "${issue_labels:-<no labels>}"
  [ "$pr_state" = closed ] || bad="pull request still $pr_state"
  [ "$issue_state" = closed ] || bad="${bad:+$bad; }unassigned issue still $issue_state"
  grep -qw -- "$mark" <<<"$pr_labels" && bad="${bad:+$bad; }pull request still flagged"
  grep -qw -- "$mark" <<<"$issue_labels" && bad="${bad:+$bad; }unassigned issue still flagged"
  [ -z "$bad" ] || { printf '%s\n' "$bad"; return 1; }
  return 0
}

# The hourly slot's own clock, restored. The leg defers the slot for its
# duration (see rehearsal_attention_audit_defer_hygiene) and must hand the box
# back the clock it found, or it has changed the scheduling it declared out of
# its own subject.
rehearsal_attention_audit_hygiene_clock_restored() {
  local before="$1" after="$2"
  printf 'hygiene clock before=%s after=%s\n' \
    "${before:-<unset>}" "${after:-<unset>}"
  [ "${before:-<unset>}" = "${after:-<unset>}" ]
}

# --- box and board reads ---------------------------------------------------

# THE COLLISION THIS DEFERS, stated because it is the leg's one real race.
# duty.sh's hygiene slot calls duty_attention_audit itself, and that call
# shares ONE state file with this leg's: $DUTY_DIR/.attention-malformed. A
# cron tick landing between call 2 and call 3 would write the malformed set
# first, and this leg's own 🚨 would then be correctly suppressed — a red on a
# working engine, in the row whose whole subject is suppression.
#
# So the leg stamps the slot's clock forward for its own duration and restores
# it afterwards. That is scheduling, which §1 puts outside this leg's subject
# in both directions: the leg does not wait for the interval, and it does not
# leave the interval moved. Nothing on the box is edited — .hygiene-last is
# runtime state duty.sh writes on every hygiene run — and the restore is proved
# by re-reading it, not asserted.
rehearsal_attention_audit_hygiene_clock() {
  # shellcheck disable=SC2016  # HOME belongs to the box
  bx 'cat "$HOME/duty/.hygiene-last" 2>/dev/null || true' | tr -d '\r\n'
}

rehearsal_attention_audit_defer_hygiene() {
  # shellcheck disable=SC2016  # HOME and date resolve in the box
  bx 'date +%s > "$HOME/duty/.hygiene-last"' >/dev/null 2>&1
}

rehearsal_attention_audit_restore_hygiene() {
  local before="$1"
  if [ -z "$before" ]; then
    # shellcheck disable=SC2016  # HOME belongs to the box
    bx 'rm -f "$HOME/duty/.hygiene-last"' >/dev/null 2>&1
    return 0
  fi
  bx "printf '%s\n' '$before' > \"\$HOME/duty/.hygiene-last\"" >/dev/null 2>&1
}

# The suppression state the transition rows read. Removed before call 1 so the
# clean-board row is an assertion about a clean BOARD and not about whatever a
# previous run happened to leave here — a stale non-empty state file would make
# call 1 emit ✅ and the row would red on a correct engine.
rehearsal_attention_audit_clear_state() {
  # shellcheck disable=SC2016  # HOME belongs to the box
  bx 'rm -f "$HOME/duty/.attention-malformed"' >/dev/null 2>&1
}

# The audit's OWN read, asked through the box: the endpoint is repo-scoped but
# the token is not, and the host's token answers a different question about a
# different user. Prints the numbers carrying the flag, one per line.
rehearsal_attention_audit_flagged_numbers() {
  local repo="$1"
  bx "set -uo pipefail
    DUTY_DIR=\"\$HOME/duty\"
    source \"\$DUTY_DIR/lib/common.sh\"
    load_conf
    gh api \"/repos/$repo/issues?state=open&labels=\$LABEL_ATTENTION&per_page=100\" \
      --jq '.[] | \"\(.number)\"' 2>/dev/null
  " 2>/dev/null | tr -d '\r'
}

rehearsal_attention_audit_board_clean() {
  local repo="$1" rows
  rows="$(rehearsal_attention_audit_flagged_numbers "$repo")" || return 1
  [ -z "${rows//[[:space:]]/}" ]
}

rehearsal_attention_audit_both_visible() {
  local repo="$1" pr="$2" issue="$3" rows
  rows="$(rehearsal_attention_audit_flagged_numbers "$repo")" || return 1
  grep -qx -- "$pr" <<<"$rows" && grep -qx -- "$issue" <<<"$rows"
}

# The direct invocation of §1. `alert` is overridden AFTER the module is
# sourced, in the process that calls it: the real alert needs operator
# credentials a drill box need not carry, and the counts are the assertion, so
# they have to be captured rather than fired into a channel nobody reads.
# Nothing on the box is edited — the override lives in this one shell and dies
# with it.
#
# One backslash on the override's `$*`, not two: bx is a single shell layer
# (box exec … bash -lc "$1"), so the box's bash is the CONSUMER of this text and
# `\$` here is what survives to become the `"$*"` it parses.
rehearsal_attention_audit_invoke() {
  local capture="$1"
  bx "set -uo pipefail
    DUTY_DIR=\"\$HOME/duty\"
    source \"\$DUTY_DIR/lib/common.sh\"
    load_conf
    source \"\$DUTY_DIR/lib/duty-attention.sh\"
    alert() { printf '%s\n' \"\$*\" >>'$capture'; }
    duty_attention_audit
  " 2>&1
}

rehearsal_attention_audit_read_capture() {
  local capture="$1"
  bx "cat '$capture' 2>/dev/null || true"
}

# --- fixtures ---------------------------------------------------------------

# The registry the EXIT trap reads (rehearsal.sh). Split out from the filer so
# the cleanup path can be exercised without an API call.
rehearsal_attention_audit_register() {
  case "$1" in
    repo)   REHEARSAL_ATTENTION_AUDIT_REPO="$2" ;;
    branch) REHEARSAL_ATTENTION_AUDIT_BRANCH="$2" ;;
    pr)     REHEARSAL_ATTENTION_AUDIT_PR="$2" ;;
    issue)  REHEARSAL_ATTENTION_AUDIT_ISSUE="$2" ;;
  esac
}

# The numbers come back in GLOBALS, not on stdout, and callers must not wrap
# this in a command substitution: bash runs one in a subshell, so a registry
# written there dies with it and the EXIT trap inherits an empty list. That
# would leave a flagged pull request and a flagged unassigned issue standing on
# the sandbox — the very board state this leg exists to call malformed.
#
# Each object is registered THE MOMENT it exists, before the next call that can
# fail. A filer that registered at the end would leak every object it had
# already created when the last one failed.
rehearsal_attention_audit_file_fixtures() {
  local repo="$1" stamp="$2" main_sha branch pr issue
  REHEARSAL_ATTENTION_AUDIT_PR=""
  REHEARSAL_ATTENTION_AUDIT_ISSUE=""
  REHEARSAL_ATTENTION_AUDIT_BRANCH=""
  rehearsal_attention_audit_register repo "$repo"

  # The unassigned issue carries a queue label as well as the flag. Not
  # decoration: an open issue with no queue label is a `queue-unlabeled` stray
  # by the board invariant, and the triage sweep would have a standing reason
  # to session it — which is a comment on the fixture, and §4's absence rows
  # would then red on the sweep's work rather than on the audit's. `blocked` is
  # the one queue label that composes with `attention` and asks nothing of
  # anybody.
  issue="$(gh api "repos/$repo/issues" \
    -f title="drill: attention audit unassigned $stamp" \
    -f body="Drill fixture: this issue carries \`attention\` with no assignee, so the board audit can classify it UNASSIGNED. It is deliberately invisible to the assigned-demand wake. No action is required of a reader." \
    -f "labels[]=attention" -f "labels[]=blocked" --jq .number)" || return 1
  [ -n "$issue" ] || return 1
  rehearsal_attention_audit_register issue "$issue"

  main_sha="$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)" || return 1
  branch="drill-attention-audit-$stamp"
  gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$main_sha" \
    >/dev/null || return 1
  rehearsal_attention_audit_register branch "$branch"
  gh api -X PUT "repos/$repo/contents/drill-attention-audit.txt" \
    -f message="drill: attention audit fixture" -f branch="$branch" \
    -f content="$(printf 'drill %s\n' "$stamp" | base64 -w0)" >/dev/null || return 1
  pr="$(gh api "repos/$repo/pulls" -f title="drill: attention audit $stamp" \
    -f head="$branch" -f base=main \
    -f body="Drill fixture: this pull request carries \`attention\`, which belongs on the assigned issue that owns the claim. No action is required of a reader." \
    --jq .number)" || return 1
  [ -n "$pr" ] || return 1
  rehearsal_attention_audit_register pr "$pr"
  gh api "repos/$repo/issues/$pr/labels" -f "labels[]=attention" >/dev/null || return 1
  return 0
}

rehearsal_attention_audit_clear_flags() {
  local repo="${REHEARSAL_ATTENTION_AUDIT_REPO:-}" num
  [ -n "$repo" ] || return 0
  for num in "${REHEARSAL_ATTENTION_AUDIT_PR:-}" "${REHEARSAL_ATTENTION_AUDIT_ISSUE:-}"; do
    [ -n "$num" ] || continue
    gh api -X DELETE "repos/$repo/issues/$num/labels/attention" >/dev/null 2>&1 || true
  done
  return 0
}

rehearsal_attention_audit_neither_visible() {
  local repo="$1" pr="$2" issue="$3" rows
  rows="$(rehearsal_attention_audit_flagged_numbers "$repo")" || return 1
  ! grep -qx -- "$pr" <<<"$rows" && ! grep -qx -- "$issue" <<<"$rows"
}

# Every exit path, including a red: called from the leg on its way out AND from
# rehearsal.sh's EXIT trap. Idempotent — the second call finds the objects
# already closed and the ref already gone, and says nothing about it.
rehearsal_attention_audit_cleanup() {
  local repo="${REHEARSAL_ATTENTION_AUDIT_REPO:-}" num
  [ -n "$repo" ] || return 0
  rehearsal_attention_audit_clear_flags
  for num in "${REHEARSAL_ATTENTION_AUDIT_PR:-}" "${REHEARSAL_ATTENTION_AUDIT_ISSUE:-}"; do
    [ -n "$num" ] || continue
    gh api -X PATCH "repos/$repo/issues/$num" -f state=closed >/dev/null 2>&1 || true
  done
  if [ -n "${REHEARSAL_ATTENTION_AUDIT_BRANCH:-}" ]; then
    gh api -X DELETE \
      "repos/$repo/git/refs/heads/${REHEARSAL_ATTENTION_AUDIT_BRANCH}" \
      >/dev/null 2>&1 || true
  fi
  return 0
}

# --- the leg ---------------------------------------------------------------

# rehearsal_attention_audit_drill REPO IDENTITY — the triage-role leg (#441).
rehearsal_attention_audit_drill() {
  local repo="$1" identity="$2" box_home capture stamp pr issue
  local clean_out flagged_out unchanged_out cleared_out
  local alerts_clean alerts_flagged alerts_unchanged alerts_cleared
  local pr_json issue_json pr_comments issue_comments
  local clock_before clock_after
  # Declared HERE, above the leg's first `fail`. Below it this is a
  # re-initialisation: a row reds, the leg still returns 0, and rehearsal-all.sh
  # prints `ok attention-audit` for a round that asserted nothing.
  local audit_ok=0

  if [ "${REHEARSAL_ATTENTION_AUDIT_DRILL:-1}" -eq 0 ]; then
    skip "attention-audit: malformed-flag report, non-repair and alert transitions (--no-attention-audit-drill)"
    rehearsal_attention_audit_verdict skip "--no-attention-audit-drill"
    return 0
  fi
  # shellcheck disable=SC2016  # HOME belongs to the box
  if ! box_home="$(bx 'printf %s "$HOME"')" || [ -z "$box_home" ]; then
    fail "attention-audit: box home resolves"
    rehearsal_attention_audit_verdict fail "box home does not resolve"
    return 1
  fi
  capture="$box_home/duty/.rehearsal-attention-audit-alerts"
  bx "rm -f '$capture'.[1-4]" >/dev/null 2>&1 || true

  clock_before="$(rehearsal_attention_audit_hygiene_clock)"
  rehearsal_attention_audit_defer_hygiene || true
  rehearsal_attention_audit_clear_state || true

  # Call 1's precondition, asserted rather than assumed: a sandbox already
  # carrying a flag would make "silent on a clean board" a statement about a
  # board that was never clean.
  if rehearsal_attention_audit_board_clean "$repo"; then
    ok "attention-audit: sandbox starts with no flagged object"
  else
    echo "  read: $(rehearsal_attention_audit_flagged_numbers "$repo" | tr '\n' ' ')"
    fail "attention-audit: sandbox starts with no flagged object"
    rehearsal_attention_audit_restore_hygiene "$clock_before" || true
    rehearsal_attention_audit_verdict fail "the sandbox already carried a flagged object"
    return 1
  fi

  # -- call 1: a clean board is silent (§5) --
  clean_out="$(rehearsal_attention_audit_invoke "$capture.1")" || true
  alerts_clean="$(rehearsal_attention_audit_read_capture "$capture.1")" || alerts_clean=""
  rehearsal_attention_audit_graded "attention-audit: clean board writes no malformed report" \
    rehearsal_attention_audit_no_report "$clean_out" || audit_ok=1
  rehearsal_attention_audit_graded "attention-audit: clean board raises no alert" \
    rehearsal_attention_audit_alert_count_is 0 "🚨" "$alerts_clean" || audit_ok=1

  # -- the two fixtures (§2) --
  stamp="$(date -u +%H%M%S)"
  # NOT a command substitution: the registry the EXIT trap reads is written by
  # this call, and a subshell would discard it.
  if rehearsal_attention_audit_file_fixtures "$repo" "$stamp"; then
    ok "attention-audit: flagged pull request and unassigned issue filed"
  else
    fail "attention-audit: flagged pull request and unassigned issue filed"
    rehearsal_attention_audit_cleanup || true
    rehearsal_attention_audit_restore_hygiene "$clock_before" || true
    rehearsal_attention_audit_verdict fail "the fixtures could not be filed"
    return 1
  fi
  pr="$REHEARSAL_ATTENTION_AUDIT_PR"
  issue="$REHEARSAL_ATTENTION_AUDIT_ISSUE"

  if ! wait_for 300 "attention-audit: both fixtures visible to the audit's read" \
      rehearsal_attention_audit_both_visible "$repo" "$pr" "$issue"; then
    audit_ok=1
  fi

  # -- call 2: the set becomes non-empty (§3, §5) --
  flagged_out="$(rehearsal_attention_audit_invoke "$capture.2")" || true
  alerts_flagged="$(rehearsal_attention_audit_read_capture "$capture.2")" || alerts_flagged=""
  rehearsal_attention_audit_graded "attention-audit: report names both malformed shapes" \
    rehearsal_attention_audit_report_names_both "$repo" "$pr" "$issue" "$flagged_out" \
    || audit_ok=1
  rehearsal_attention_audit_graded "attention-audit: the transition alerts exactly once" \
    rehearsal_attention_audit_alert_count_is 1 "🚨" "$alerts_flagged" || audit_ok=1
  rehearsal_attention_audit_graded "attention-audit: the alert names both malformed shapes" \
    rehearsal_attention_audit_alert_names_both "🚨" "$repo" "$pr" "$issue" "$alerts_flagged" \
    || audit_ok=1

  # -- call 3: the board is unchanged (§5) --
  unchanged_out="$(rehearsal_attention_audit_invoke "$capture.3")" || true
  alerts_unchanged="$(rehearsal_attention_audit_read_capture "$capture.3")" || alerts_unchanged=""
  rehearsal_attention_audit_graded "attention-audit: an unchanged board adds no further alert" \
    rehearsal_attention_audit_alert_count_is 0 "🚨" "$alerts_unchanged" || audit_ok=1

  # -- non-repair (§4), read after the audit has seen the board twice --
  pr_json="$(gh api "repos/$repo/issues/$pr")" || pr_json='{}'
  issue_json="$(gh api "repos/$repo/issues/$issue")" || issue_json='{}'
  pr_comments="$(gh api "repos/$repo/issues/$pr/comments?per_page=100" --paginate \
    | jq -s 'add // []')" || pr_comments='[]'
  issue_comments="$(gh api "repos/$repo/issues/$issue/comments?per_page=100" --paginate \
    | jq -s 'add // []')" || issue_comments='[]'
  rehearsal_attention_audit_graded "attention-audit: both flags still set" \
    rehearsal_attention_audit_flags_intact attention "$pr_json" "$issue_json" || audit_ok=1
  rehearsal_attention_audit_graded "attention-audit: the unassigned issue is still unassigned" \
    rehearsal_attention_audit_still_unassigned "$issue_json" || audit_ok=1
  rehearsal_attention_audit_graded "attention-audit: no comment by the identity on either fixture" \
    rehearsal_attention_audit_no_identity_comment "$identity" "$pr_comments" "$issue_comments" \
    || audit_ok=1

  # -- call 4: the set clears (§5) --
  rehearsal_attention_audit_clear_flags
  if ! wait_for 300 "attention-audit: neither fixture is flagged any more" \
      rehearsal_attention_audit_neither_visible "$repo" "$pr" "$issue"; then
    audit_ok=1
  fi
  cleared_out="$(rehearsal_attention_audit_invoke "$capture.4")" || true
  alerts_cleared="$(rehearsal_attention_audit_read_capture "$capture.4")" || alerts_cleared=""
  rehearsal_attention_audit_graded "attention-audit: clearing the set alerts exactly once" \
    rehearsal_attention_audit_alert_count_is 1 "✅" "$alerts_cleared" || audit_ok=1

  # -- cleanup, proved off the board rather than asserted --
  bx "rm -f '$capture'.[1-4]" >/dev/null 2>&1 || true
  rehearsal_attention_audit_cleanup || true
  pr_json="$(gh api "repos/$repo/issues/$pr")" || pr_json='{}'
  issue_json="$(gh api "repos/$repo/issues/$issue")" || issue_json='{}'
  rehearsal_attention_audit_graded "attention-audit: both fixtures removed from the board" \
    rehearsal_attention_audit_fixtures_removed attention "$pr_json" "$issue_json" || audit_ok=1

  rehearsal_attention_audit_restore_hygiene "$clock_before" || true
  clock_after="$(rehearsal_attention_audit_hygiene_clock)"
  rehearsal_attention_audit_graded "attention-audit: the hourly slot's clock is handed back" \
    rehearsal_attention_audit_hygiene_clock_restored "$clock_before" "$clock_after" \
    || audit_ok=1

  if [ "$audit_ok" -eq 0 ]; then
    rehearsal_attention_audit_verdict ok "both malformed shapes reported, not repaired, alerts on transition only"
    return 0
  fi
  rehearsal_attention_audit_verdict fail "report, non-repair or transition assertions red — see the run's rows"
  return 1
}
