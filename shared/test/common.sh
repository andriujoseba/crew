#!/usr/bin/env bash
# shared/test/common.sh — standalone common subject suite.
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

# --- read_repo_list: comments (incl. inline), blanks, whitespace, missing
# trailing newline
printf '# a comment\nheavy-duty/ceremony\n\n  heavy-duty/rig  # inline note\n# tail\nheavy-duty/incubator' >"$TMP/repos.txt"
t repo-list "heavy-duty/ceremony
heavy-duty/rig
heavy-duty/incubator" "$(read_repo_list "$TMP/repos.txt")"
t repo-list-missing "" "$(read_repo_list "$TMP/nope.txt")"

# --- render_prompt: multiple slots, repeated slots, untouched unknowns
mkdir -p "$TMP/prompts"
printf 'You are {{ME}} in {{REPO}}; {{ME}} again; {{UNSET}} stays.' >"$TMP/prompts/x.txt"
t render "You are bot in o/r; bot again; {{UNSET}} stays." \
  "$(render_prompt x.txt ME=bot REPO=o/r)"

# --- has_role
# shellcheck disable=SC2034  # consumed by has_role inside sourced common.sh
BOT_ROLES="builder reviewer"
has_role builder && r1=yes || r1=no
has_role triage && r2=yes || r2=no
t has-role-yes yes "$r1"
t has-role-no no "$r2"

# --- leg-neutral drill verdict helpers (#435) -----------------------------
VERDICT_STATUS_FILE="$TMP/drill-verdicts"
: >"$VERDICT_STATUS_FILE"
(
  # shellcheck disable=SC2030  # the fixture identity is intentionally local
  ROLE=builder
  rehearsal_verdict_record "$VERDICT_STATUS_FILE" skip "fixture unavailable"
  rehearsal_verdict_record "$VERDICT_STATUS_FILE" fail "later failure"
)
t drill-verdict-record-appends "$(printf 'builder skip fixture unavailable\nbuilder fail later failure')" \
  "$(cat "$VERDICT_STATUS_FILE")"
t drill-verdict-worst-is-leg-neutral "fail later failure" \
  "$(rehearsal_worst_verdict "$(cat "$VERDICT_STATUS_FILE")")"
t drill-verdict-unreadable-token-grades-fail "fail unreadable" \
  "$(rehearsal_worst_verdict 'builder sideways unreadable')"
if rehearsal_worst_verdict '' >/dev/null 2>&1; then r1=verdict; else r1=none; fi
t drill-verdict-empty-has-no-answer none "$r1"

# The two early successful returns are omissions, not passes. The unavailable
# fixture is the reported mutation: role rc 0 must still aggregate INCOMPLETE.
REHEARSAL_RESUME_STATUS="$TMP/resume-leg-verdicts"
: >"$REHEARSAL_RESUME_STATUS"
(
  # shellcheck disable=SC2030  # the fixture identity is intentionally local
  ROLE=builder
  REHEARSAL_RESUME_DRILL=1
  skip() { :; }
  rehearsal_resume_drill owner/repo "" >/dev/null
)
t resume-verdict-unavailable-fixture-is-a-skip \
  "builder skip builder fixture PR unavailable" \
  "$(cat "$REHEARSAL_RESUME_STATUS")"
: >"$REHEARSAL_RESUME_STATUS"
(
  # shellcheck disable=SC2030  # the fixture identity is intentionally local
  ROLE=builder
  REHEARSAL_RESUME_DRILL=0
  skip() { :; }
  rehearsal_resume_drill owner/repo 1 >/dev/null
)
t resume-verdict-opt-out-is-a-skip "builder skip --no-resume-drill" \
  "$(cat "$REHEARSAL_RESUME_STATUS")"
unset REHEARSAL_RESUME_STATUS

# --- rehearsal resume leg: next-tick wake and bounded zero action (#419) ---
RESUME_HEAD="$(printf 'd%.0s' {1..40})"
RESUME_REPO=owner/sandbox
RESUME_PR=19
RESUME_COMMENT=9919

bx() { printf '7\n'; }
ok() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; }
resume_threshold_log="$TMP/rehearsal-resume-threshold.log"
if rehearsal_resume_load_installed_threshold >"$resume_threshold_log" 2>&1; then
  resume_threshold_rc=0
else
  resume_threshold_rc=$?
fi
resume_threshold_out="$(cat "$resume_threshold_log")"
t rehearsal-resume-threshold-load-rc 0 "$resume_threshold_rc"
t rehearsal-resume-threshold-comes-from-installed-engine 7 "$REHEARSAL_RESUME_THRESHOLD"
t rehearsal-resume-threshold-load-records-ok 1 \
  "$(grep -cFx 'ok   resume: installed zero-action threshold resolves' \
    <<<"$resume_threshold_out")"
bx() { printf 'not-a-threshold\n'; }
if rehearsal_resume_load_installed_threshold >/dev/null 2>&1; then
  resume_threshold_rc=0
else
  resume_threshold_rc=$?
fi
t rehearsal-resume-invalid-threshold-refused 1 "$resume_threshold_rc"
unset -f bx ok fail

RESUME_PENDING_LOG="2026-08-08T12:00:00Z $RESUME_REPO: no resume duty"
if rehearsal_resume_pending_tick_from_log \
    "$RESUME_REPO" "$RESUME_PR" "$RESUME_PENDING_LOG"; then
  resume_predicate=unresumed
else
  resume_predicate=WRONG
fi
t rehearsal-resume-pending-head-unresumed unresumed "$resume_predicate"
if rehearsal_resume_pending_tick_from_log "$RESUME_REPO" "$RESUME_PR" \
    "$RESUME_PENDING_LOG
2026-08-08T12:00:01Z SESSION START kind=resume key=$RESUME_REPO"; then
  resume_predicate=WRONG
else
  resume_predicate=refused
fi
t rehearsal-resume-pending-session-mutation-reds refused "$resume_predicate"

RESUME_WAKE_LOG="2026-08-08T12:05:00Z WARN: $RESUME_REPO#$RESUME_PR: green head owed a signal — nothing left to wait for (#384)
2026-08-08T12:05:00Z $RESUME_REPO#$RESUME_PR: green head owed a signal — resuming this tick instead of the twelfth, dispatch 1 of 7 at $RESUME_HEAD (#384)
2026-08-08T12:05:01Z SESSION START kind=resume key=$RESUME_REPO timeout=3600s"
if rehearsal_resume_wake_tick_from_log \
    "$RESUME_REPO" "$RESUME_PR" "$RESUME_HEAD" "$RESUME_WAKE_LOG"; then
  resume_predicate=woke
else
  resume_predicate=WRONG
fi
t rehearsal-resume-green-next-tick-wakes woke "$resume_predicate"

# Required pre-#384 mutation: remove the check-conclusion wake term from the
# exact duty.log input the sourceable assertion reads. It must red the live
# assertion by name; no real host is needed to stage this decision boundary.
RESUME_WAKE_MUTATION_OUT="$({
  ok() { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
  check "resume: first tick after green resumes the parked PR" \
    rehearsal_resume_wake_tick_from_log "$RESUME_REPO" "$RESUME_PR" \
      "$RESUME_HEAD" "2026-08-08T12:05:00Z $RESUME_REPO: no resume duty"
})"
t rehearsal-resume-pre-384-fingerprint-mutation-reds 1 \
  "$(grep -cFx 'FAIL resume: first tick after green resumes the parked PR' \
    <<<"$RESUME_WAKE_MUTATION_OUT")"

RESUME_NEAR_LOG="2026-08-08T12:10:00Z WARN: $RESUME_REPO#$RESUME_PR: comment $RESUME_COMMENT opens with an unrendered marker slot and names head $RESUME_HEAD — not a signal (#133), but the round was answered there
2026-08-08T12:10:00Z $RESUME_REPO#$RESUME_PR: near-miss resume dispatch 1 of 7 at $RESUME_HEAD
2026-08-08T12:10:01Z SESSION START kind=resume key=$RESUME_REPO timeout=3600s"
if rehearsal_resume_near_miss_tick_from_log "$RESUME_REPO" "$RESUME_PR" \
    "$RESUME_HEAD" "$RESUME_COMMENT" "$RESUME_NEAR_LOG"; then
  resume_predicate=woke
else
  resume_predicate=WRONG
fi
t rehearsal-resume-near-miss-names-comment-and-wakes woke "$resume_predicate"
if rehearsal_resume_near_miss_tick_from_log "$RESUME_REPO" "$RESUME_PR" \
    "$RESUME_HEAD" "$RESUME_COMMENT" \
    "${RESUME_NEAR_LOG/comment $RESUME_COMMENT/comment unknown}"; then
  resume_predicate=WRONG
else
  resume_predicate=refused
fi
t rehearsal-resume-near-miss-unnamed-comment-mutation-reds refused "$resume_predicate"

RESUME_STOP_LOG="2026-08-08T12:15:00Z no resume duty: $RESUME_REPO#$RESUME_PR near-miss lane suppressed at $RESUME_HEAD after 7 zero-action dispatches — only a push clears it (#314)"
if rehearsal_resume_suppressed_tick_from_log "$RESUME_REPO" "$RESUME_PR" \
    "$RESUME_HEAD" 7 "$RESUME_STOP_LOG"; then
  resume_predicate=stopped
else
  resume_predicate=WRONG
fi
t rehearsal-resume-zero-action-threshold-stops stopped "$resume_predicate"
if rehearsal_resume_suppressed_tick_from_log "$RESUME_REPO" "$RESUME_PR" \
    "$RESUME_HEAD" 7 "$RESUME_STOP_LOG
2026-08-08T12:15:01Z SESSION START kind=resume key=$RESUME_REPO"; then
  resume_predicate=WRONG
else
  resume_predicate=refused
fi
t rehearsal-resume-post-suppression-session-mutation-reds refused "$resume_predicate"

t rehearsal-resume-threshold-not-retyped-in-drill 0 \
  "$(grep -R -E 'breaker=[0-9]+' "$ROOT/drill" | wc -l | tr -d ' ')"
# shellcheck disable=SC2016  # match literal builder-block source text
resume_builder_block="$(sed -n '/elif \[ "$ROLE" = "builder" \]/,/^[[:space:]]*else$/p' \
    "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # match literal builder-block source text
if grep -Fq '. "$ROOT/drill/rehearsal-resume.sh"' <<<"$resume_builder_block"; then
  resume_wiring=wired
else
  resume_wiring=MISSING
fi
t rehearsal-resume-helper-sourced-in-builder-block wired "$resume_wiring"
if grep -Fq -- '--no-resume-drill' "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'resume  (wake + zero-action stop)' "$ROOT/drill/rehearsal-all.sh"; then
  resume_wiring=wired
else
  resume_wiring=MISSING
fi
t rehearsal-resume-all-opt-out-and-summary-wired wired "$resume_wiring"

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

# --- rehearsal notify leg: the watch-set union, both halves (#423) ---------
# shellcheck source=drill/rehearsal-notify.sh
source "$ROOT/drill/rehearsal-notify.sh"

NOTIFY_WORK=owner/crew-drill-reviewer
NOTIFY_EXTRA=owner/crew-drill-reviewer-notify
NOTIFY_WORK_PR=31
NOTIFY_EXTRA_PR=7
NOTIFY_WORK_LINE="2026-08-08T12:00:01Z $NOTIFY_WORK#$NOTIFY_WORK_PR: notified needs-human at abc1234 (msg 5501)"
NOTIFY_EXTRA_LINE="2026-08-08T12:00:02Z $NOTIFY_EXTRA#$NOTIFY_EXTRA_PR: notified needs-human at def5678 (msg 5502)"
NOTIFY_RUN_LOG="2026-08-08T12:00:00Z notify run start
$NOTIFY_WORK_LINE
$NOTIFY_EXTRA_LINE
2026-08-08T12:00:03Z sweep done — 2 repos, 2 flagged, 2 pending
2026-08-08T12:00:03Z notify run end"

notify_union() {
  rehearsal_notify_union_from_log \
    "$NOTIFY_WORK" "$NOTIFY_WORK_PR" "$NOTIFY_EXTRA" "$NOTIFY_EXTRA_PR" "$1"
}

notify_out="$(notify_union "$NOTIFY_RUN_LOG" 2>&1)"
notify_rc=$?
t notify-union-both-halves-on-one-run-rc 0 "$notify_rc"
t notify-union-both-halves-say-nothing "" "$notify_out"

# THE required mutation: the pre-#316 shadowing behaviour, staged against the
# input the assertion reads. notify-repos.txt used to REPLACE repos.txt, so
# the half that disappears is the work registry's — and a leg asserting only
# the notify half would pass the bug unchanged.
NOTIFY_SHADOW_LOG="${NOTIFY_RUN_LOG/"$NOTIFY_WORK_LINE"$'\n'/}"
notify_out="$(notify_union "$NOTIFY_SHADOW_LOG" 2>&1)"
notify_rc=$?
t notify-union-pre-316-shadow-mutation-reds 5 "$notify_rc"
case "$notify_out" in
  *"$NOTIFY_WORK#$NOTIFY_WORK_PR (repos.txt half)"*) r1=named ;;
  *) r1=missing ;;
esac
t notify-union-shadow-failure-names-the-missing-repo named "$r1"

NOTIFY_EXTRA_DROPPED_LOG="${NOTIFY_RUN_LOG/"$NOTIFY_EXTRA_LINE"$'\n'/}"
notify_out="$(notify_union "$NOTIFY_EXTRA_DROPPED_LOG" 2>&1)"
notify_rc=$?
t notify-union-notify-half-dropped-reds 6 "$notify_rc"
case "$notify_out" in
  *"$NOTIFY_EXTRA#$NOTIFY_EXTRA_PR (notify-repos.txt half)"*) r1=named ;;
  *) r1=missing ;;
esac
t notify-union-notify-half-failure-names-the-missing-repo named "$r1"

notify_rc=0
notify_union "2026-08-08T12:00:00Z notify run start
2026-08-08T12:00:03Z sweep done — 2 repos, 0 flagged, 0 pending
2026-08-08T12:00:03Z notify run end" >/dev/null 2>&1 || notify_rc=$?
t notify-union-neither-half-reds 7 "$notify_rc"

# "On the same tick" is the assertion, not "eventually both". Two runs a tick
# apart satisfy every per-repo grep and are exactly what a shadowing notifier
# alternating its watch set would produce.
NOTIFY_TWO_RUN_LOG="2026-08-08T12:00:00Z notify run start
$NOTIFY_WORK_LINE
2026-08-08T12:00:03Z sweep done — 1 repos, 1 flagged, 1 pending
2026-08-08T12:00:03Z notify run end
2026-08-08T12:05:00Z notify run start
$NOTIFY_EXTRA_LINE
2026-08-08T12:05:03Z sweep done — 1 repos, 1 flagged, 2 pending
2026-08-08T12:05:03Z notify run end"
notify_out="$(notify_union "$NOTIFY_TWO_RUN_LOG" 2>&1)"
notify_rc=$?
t notify-union-split-across-two-ticks-reds 5 "$notify_rc"

# A send that failed still writes the sweep's line, with no message id. The
# criterion is that the notification REACHED the operator.
notify_rc=0
notify_union "${NOTIFY_RUN_LOG/(msg 5501)/(msg none)}" >/dev/null 2>&1 || notify_rc=$?
t notify-union-unsent-message-is-not-a-delivery 5 "$notify_rc"

notify_rc=0
notify_union "2026-08-08T12:00:00Z notify run start
$NOTIFY_WORK_LINE
$NOTIFY_EXTRA_LINE" >/dev/null 2>&1 || notify_rc=$?
t notify-union-unterminated-run-is-no-run 7 "$notify_rc"

t notify-last-run-is-the-last-complete-one "$NOTIFY_EXTRA_LINE" \
  "$(rehearsal_notify_last_run_from_log "$NOTIFY_TWO_RUN_LOG" | sed -n '2p')"

# Containment, read off the notifier's own count of what it swept: a fleet
# repository surviving in notify-repos.txt shows up here and nowhere else.
if rehearsal_notify_watch_set_is_from_log 2 "$NOTIFY_RUN_LOG"; then r1=contained; else r1=WRONG; fi
t notify-watch-set-is-the-two-sandboxes contained "$r1"
if rehearsal_notify_watch_set_is_from_log 2 \
    "${NOTIFY_RUN_LOG/sweep done — 2 repos,/sweep done — 7 repos,}"; then
  r1=WRONG
else
  r1=refused
fi
t notify-watch-set-fleet-leak-mutation-reds refused "$r1"

# The interlock, re-asserted: the union widens the watch set and never the
# work set.
if rehearsal_notify_work_registry_intact "$NOTIFY_WORK" "$NOTIFY_WORK" "$NOTIFY_WORK"; then
  r1=intact
else
  r1=WRONG
fi
t notify-work-registry-intact intact "$r1"
notify_rc=0
rehearsal_notify_work_registry_intact "$NOTIFY_WORK" "$NOTIFY_WORK" \
  "$NOTIFY_WORK
heavy-duty/crew" >/dev/null 2>&1 || notify_rc=$?
t notify-work-registry-moved-reds 5 "$notify_rc"
notify_rc=0
rehearsal_notify_work_registry_intact "$NOTIFY_WORK" \
  "$NOTIFY_WORK
heavy-duty/crew" "$NOTIFY_WORK
heavy-duty/crew" >/dev/null 2>&1 || notify_rc=$?
t notify-work-registry-already-wide-reds 6 "$notify_rc"

# The interlock's rule applied to the second file.
NOTIFY_PRE_DRILL="heavy-duty/crew
heavy-duty/ceremony"
if rehearsal_notify_candidate_is_safe "$NOTIFY_EXTRA" "$NOTIFY_WORK" "$NOTIFY_PRE_DRILL"; then
  r1=safe
else
  r1=WRONG
fi
t notify-candidate-minted-sandbox-is-safe safe "$r1"
notify_rc=0
rehearsal_notify_candidate_is_safe not-a-slug "$NOTIFY_WORK" "$NOTIFY_PRE_DRILL" >/dev/null 2>&1 || notify_rc=$?
t notify-candidate-malformed-refused 5 "$notify_rc"
notify_rc=0
rehearsal_notify_candidate_is_safe "$NOTIFY_WORK" "$NOTIFY_WORK" "$NOTIFY_PRE_DRILL" >/dev/null 2>&1 || notify_rc=$?
t notify-candidate-work-sandbox-refused 6 "$notify_rc"
notify_out="$(rehearsal_notify_candidate_is_safe heavy-duty/ceremony "$NOTIFY_WORK" "$NOTIFY_PRE_DRILL" 2>&1)"
notify_rc=$?
t notify-candidate-pre-drill-registry-refused 7 "$notify_rc"
case "$notify_out" in
  *"heavy-duty/ceremony is named in this host's pre-drill registry"*) r1=named ;;
  *) r1=missing ;;
esac
t notify-candidate-refusal-names-the-repo named "$r1"

# --- the operator-channel preflight, against a stubbed Telegram -----------
#
# The preflight has two halves and they fail apart. `getMe` answers "is this
# token a bot"; what the leg needs is that the bot can reach the chat the
# engine actually sends to (`CHAT="$(cat "$HOME/.tg_chat_id")"`,
# shared/bin/notify.sh:64). Probing only the first meant a valid token on a
# missing, wrong, or inaccessible chat returned `ok`, staged both fixtures,
# and had its `(msg none)` deliveries graded as a LEG FAILURE — where #423
# says an unreachable operator channel is a named skip and nothing else
# (codex-bot, round 4).
#
# Driven by EXECUTING the box-side script under a fake HOME with `curl`
# shimmed, not by grepping its text: the question is which requests it makes
# and what it concludes from each answer. Still no network — the shim is on
# PATH ahead of the real binary and every reply is local.
NOTIFY_CHAN_HOME="$TMP/notify-channel-home"
NOTIFY_CHAN_SHIM="$TMP/notify-channel-shim"
NOTIFY_CHAN_CURL="$TMP/notify-channel-curl-calls"
mkdir -p "$NOTIFY_CHAN_HOME" "$NOTIFY_CHAN_SHIM"
cat >"$NOTIFY_CHAN_SHIM/curl" <<'NOTIFY_CURL_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NOTIFY_CHAN_CURL"
url=""
for arg in "$@"; do case "$arg" in https://*) url="$arg" ;; esac; done
case "$url" in
  *getMe*)   state="$NOTIFY_CHAN_GETME" ;;
  *getChat*) state="$NOTIFY_CHAN_GETCHAT" ;;
  *)         state=ok ;;
esac
case "$state" in
  transport) exit 7 ;;
  refused)   printf '{"ok":false,"description":"stub refusal"}\n' ;;
  *)         printf '{"ok":true,"result":{"id":-100200}}\n' ;;
esac
NOTIFY_CURL_STUB
chmod +x "$NOTIFY_CHAN_SHIM/curl"
export NOTIFY_CHAN_CURL
NOTIFY_CHAN_ID='-1002003004'
notify_channel_probe() {  # $1 token bytes|missing, $2 chat bytes|missing, $3 getMe, $4 getChat
  if [ "$1" = missing ]; then rm -f "$NOTIFY_CHAN_HOME/.tg_bot_token"
  else printf '%s' "$1" >"$NOTIFY_CHAN_HOME/.tg_bot_token"; fi
  if [ "$2" = missing ]; then rm -f "$NOTIFY_CHAN_HOME/.tg_chat_id"
  else printf '%s' "$2" >"$NOTIFY_CHAN_HOME/.tg_chat_id"; fi
  : >"$NOTIFY_CHAN_CURL"
  (
    export NOTIFY_CHAN_GETME="${3:-ok}" NOTIFY_CHAN_GETCHAT="${4:-ok}"
    bx() { HOME="$NOTIFY_CHAN_HOME" PATH="$NOTIFY_CHAN_SHIM:$PATH" bash -c "$1"; }
    rehearsal_notify_channel_status
  )
}

notify_chan="$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" ok ok)"
t notify-channel-token-and-chat-both-good ok "$notify_chan"
t notify-channel-probes-the-configured-chat 1 \
  "$(grep -cF "chat_id=$NOTIFY_CHAN_ID" "$NOTIFY_CHAN_CURL")"
t notify-channel-chat-probe-is-a-read 0 \
  "$(grep -cF sendMessage "$NOTIFY_CHAN_CURL")"

# The case the whole point turns on: the token is unimpeachable and the chat
# is not. `getMe` alone cannot tell this from a healthy channel.
notify_chan="$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" ok refused)"
t notify-channel-valid-token-unreachable-chat-is-not-ok chat-unreachable "$notify_chan"
t notify-channel-valid-token-unreachable-chat-asked-both 2 \
  "$(grep -c . "$NOTIFY_CHAN_CURL")"

# …and its converse, so the two reasons keep distinct subjects: a refused
# token is `rejected`, and the chat is never probed with a token already known
# to be bad.
notify_chan="$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" refused ok)"
t notify-channel-refused-token-is-rejected rejected "$notify_chan"
t notify-channel-refused-token-never-probes-the-chat 0 \
  "$(grep -cF getChat "$NOTIFY_CHAN_CURL")"

t notify-channel-transport-failure-is-unreachable unreachable \
  "$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" transport ok)"
t notify-channel-chat-transport-failure-is-unreachable unreachable \
  "$(notify_channel_probe tok-abc "$NOTIFY_CHAN_ID" ok transport)"
t notify-channel-missing-token-is-no-credentials no-credentials \
  "$(notify_channel_probe missing "$NOTIFY_CHAN_ID" ok ok)"
t notify-channel-missing-chat-id-is-no-credentials no-credentials \
  "$(notify_channel_probe tok-abc missing ok ok)"

# A readable file holding nothing is not a credential: carried into the
# request it would have asked Telegram about the empty chat id and read the
# refusal as `chat-unreachable`, which names the wrong fault.
notify_chan="$(notify_channel_probe tok-abc "" ok ok)"
t notify-channel-empty-chat-id-is-no-credentials no-credentials "$notify_chan"
t notify-channel-empty-chat-id-asks-nothing 0 "$(grep -c . "$NOTIFY_CHAN_CURL")"
notify_chan="$(notify_channel_probe "" "$NOTIFY_CHAN_ID" ok ok)"
t notify-channel-empty-token-is-no-credentials no-credentials "$notify_chan"
t notify-channel-empty-token-asks-nothing 0 "$(grep -c . "$NOTIFY_CHAN_CURL")"
unset -f notify_channel_probe

# The new reason travels the same road as the old ones: a skip naming it, no
# ok row anywhere in the leg, and no tick.
notify_out="$(
  bx() { printf 'chat-unreachable\n'; }
  ok()   { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  skip() { printf 'skip %s\n' "$1"; }
  rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer 2>&1
  printf 'rc=%s\n' "$?"
)"
t notify-unreachable-chat-rc "rc=0" "$(tail -n 1 <<<"$notify_out")"
t notify-unreachable-chat-skips-with-its-reason 1 \
  "$(grep -cF 'skip notify: union over repos.txt and notify-repos.txt (operator channel unreachable on this host: chat-unreachable)' <<<"$notify_out")"
t notify-unreachable-chat-is-never-a-pass 0 "$(grep -c '^ok   ' <<<"$notify_out")"

# Must fail (recorded, not hidden): an unreachable channel is a visible skip
# naming the reason, and never an ok.
notify_out="$(
  bx() { printf 'no-credentials\n'; }
  ok()   { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  skip() { printf 'skip %s\n' "$1"; }
  rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer 2>&1
  printf 'rc=%s\n' "$?"
)"
t notify-unreachable-channel-rc "rc=0" "$(tail -n 1 <<<"$notify_out")"
t notify-unreachable-channel-skips-with-its-reason 1 \
  "$(grep -cF 'skip notify: union over repos.txt and notify-repos.txt (operator channel unreachable on this host: no-credentials)' <<<"$notify_out")"
t notify-unreachable-channel-is-never-a-pass 0 "$(grep -c '^ok   ' <<<"$notify_out")"

notify_out="$(
  bx() { printf 'ok\n'; }
  skip() { printf 'skip %s\n' "$1"; }
  REHEARSAL_NOTIFY_DRILL=0 rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer 2>&1
)"
t notify-opt-out-skips-the-leg 1 \
  "$(grep -cF 'skip notify: union over repos.txt and notify-repos.txt (--no-notify-drill)' <<<"$notify_out")"

# Restore is by pre-drill STATE, not by rewriting a default: a file the leg
# created is removed, one it replaced is moved back.
: >"$NOTIFY_BX_CALLS"
REHEARSAL_NOTIFY_BACKUP="$NOTIFY_BACKUP_PATH"
REHEARSAL_NOTIFY_ABSENT=1
bx() { printf '%s\n' "$1" >>"$NOTIFY_BX_CALLS"; }
rehearsal_notify_restore_registry
t notify-restore-removes-a-file-the-leg-created 1 \
  "$(grep -cF 'rm -f ~/duty/notify-repos.txt' "$NOTIFY_BX_CALLS")"
t notify-restore-clears-its-backup-handle "" "$REHEARSAL_NOTIFY_BACKUP"
: >"$NOTIFY_BX_CALLS"
REHEARSAL_NOTIFY_BACKUP="$NOTIFY_BACKUP_PATH"
REHEARSAL_NOTIFY_ABSENT=0
rehearsal_notify_restore_registry
t notify-restore-moves-the-pre-drill-file-back 1 \
  "$(grep -cF 'mv ~/duty/notify-repos.txt.pre-drill-99 ~/duty/notify-repos.txt' "$NOTIFY_BX_CALLS")"
: >"$NOTIFY_BX_CALLS"
REHEARSAL_NOTIFY_BACKUP=""
rehearsal_notify_restore_registry
t notify-restore-is-a-noop-when-the-leg-never-wrote 0 \
  "$(wc -l <"$NOTIFY_BX_CALLS" | tr -d ' ')"

# A handoff fixture is recorded by the CALLER, because the stager is read
# through a command substitution and a subshell's list would be lost exactly
# where a killed run needs it. Left open, these occupy the builder slot on a
# host whose gh identity is also the box's.
REHEARSAL_NOTIFY_FIXTURES=""
rehearsal_notify_record_fixture "$NOTIFY_WORK" "$NOTIFY_WORK_PR"
rehearsal_notify_record_fixture "$NOTIFY_EXTRA" "$NOTIFY_EXTRA_PR"
: >"$NOTIFY_BX_CALLS"
gh() { case "$1 $2" in "api -X") printf '%s\n' "$*" >>"$NOTIFY_BX_CALLS" ;; *) return 2 ;; esac; }
rehearsal_notify_close_fixtures
t notify-fixture-teardown-closes-both 2 "$(wc -l <"$NOTIFY_BX_CALLS" | tr -d ' ')"
t notify-fixture-teardown-closes-the-work-half 1 \
  "$(grep -cF "repos/$NOTIFY_WORK/pulls/$NOTIFY_WORK_PR" "$NOTIFY_BX_CALLS")"
t notify-fixture-teardown-closes-the-notify-half 1 \
  "$(grep -cF "repos/$NOTIFY_EXTRA/pulls/$NOTIFY_EXTRA_PR" "$NOTIFY_BX_CALLS")"
t notify-fixture-teardown-clears-the-list "" "$REHEARSAL_NOTIFY_FIXTURES"
: >"$NOTIFY_BX_CALLS"
rehearsal_notify_close_fixtures
t notify-fixture-teardown-is-idempotent 0 "$(wc -l <"$NOTIFY_BX_CALLS" | tr -d ' ')"
unset -f gh

# --- a fixture that exists survives whatever failed after it ---------------
#
# Two ways the round-4 review found an open handoff PR escaping the list that
# exists to close it (codex-bot):
#
#   1. the stager printed its number only after the label steps, so a label
#      application that failed returned empty — the caller recorded nothing
#      and the PR created a moment earlier was open with nobody holding it;
#   2. close_fixtures cleared the WHOLE list even when a PATCH failed, so the
#      EXIT pass inherited an empty list and retried nothing.
#
# Both are driven here with a gh stub that fails exactly one step.
NOTIFY_GH_CALLS="$TMP/notify-gh-calls"
NOTIFY_GH_PR_SEQ="$TMP/notify-gh-pr-seq"
NOTIFY_GH_FAIL_AT=""
NOTIFY_GH_CLOSE_FAIL=""
printf '0\n' >"$NOTIFY_GH_PR_SEQ"
notify_gh_stub() {
  local n
  printf '%s\n' "$*" >>"$NOTIFY_GH_CALLS"
  case "$*" in
    "repo view "*|"repo create "*) return 0 ;;
    *" -X PATCH "*)
      if [ -n "$NOTIFY_GH_CLOSE_FAIL" ]; then
        case "$*" in *"$NOTIFY_GH_CLOSE_FAIL"*) return 1 ;; esac
      fi
      return 0 ;;
    *git/ref/heads/main*) printf 'deadbeefdeadbeefdeadbeef\n'; return 0 ;;
    # Matched before the repository-level label creation below, whose pattern
    # is a prefix of this one.
    *issues/*/labels*)
      [ "$NOTIFY_GH_FAIL_AT" = label ] && return 1
      return 0 ;;
    *"/pulls -f title="*)
      n="$(( $(cat "$NOTIFY_GH_PR_SEQ") + 1 ))"
      printf '%s\n' "$n" >"$NOTIFY_GH_PR_SEQ"
      [ "$NOTIFY_GH_FAIL_AT" = create ] && return 1
      printf '%s\n' "$n"
      return 0 ;;
    *) return 0 ;;
  esac
}

# The stager itself: a number the caller can act on, and a status that still
# says the fixture is not usable as a notifiable event.
(
  NOTIFY_GH_FAIL_AT=label
  : >"$NOTIFY_GH_CALLS"
  printf '0\n' >"$NOTIFY_GH_PR_SEQ"
  gh() { notify_gh_stub "$@"; }
  notify_staged="$(rehearsal_notify_stage_handoff_pr owner/sandbox slug state:needs-human)"
  printf 'rc=%s pr=[%s]\n' "$?" "$notify_staged"
) >"$TMP/notify-stage-label-failure" 2>&1
t notify-stage-label-failure-still-yields-the-number 'rc=1 pr=[1]' \
  "$(cat "$TMP/notify-stage-label-failure")"
(
  NOTIFY_GH_FAIL_AT=create
  : >"$NOTIFY_GH_CALLS"
  printf '0\n' >"$NOTIFY_GH_PR_SEQ"
  gh() { notify_gh_stub "$@"; }
  notify_staged="$(rehearsal_notify_stage_handoff_pr owner/sandbox slug state:needs-human)"
  printf 'rc=%s pr=[%s]\n' "$?" "$notify_staged"
) >"$TMP/notify-stage-create-failure" 2>&1
t notify-stage-create-failure-has-nothing-to-track 'rc=1 pr=[]' \
  "$(cat "$TMP/notify-stage-create-failure")"

# The leg around it: a labelling failure grades the staging red AND closes the
# PR it created. Under the round-4 code the PATCH below never happened.
notify_stage_run() {  # $1 the gh step that fails, $2 the close that fails
  NOTIFY_SECOND_READ=same
  NOTIFY_PRE_STATE=present
  NOTIFY_PRE_TEXT=""
  NOTIFY_WORK_BACKUP_STATE=present
  NOTIFY_WORK_BACKUP_TEXT="$NOTIFY_PRE_DRILL"
  NOTIFY_POST_STATE=present
  NOTIFY_POST_TEXT=""
  : >"$NOTIFY_BX_CALLS"
  : >"$NOTIFY_GH_CALLS"
  printf '0\n' >"$NOTIFY_READS"
  printf '0\n' >"$NOTIFY_NOTIFY_READS"
  printf '0\n' >"$NOTIFY_GH_PR_SEQ"
  REHEARSAL_NOTIFY_BACKUP=""
  REHEARSAL_NOTIFY_ABSENT=0
  REHEARSAL_NOTIFY_FIXTURES=""
  (
    REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
    NOTIFY_GH_FAIL_AT="${1:-}"
    NOTIFY_GH_CLOSE_FAIL="${2:-}"
    bx() { notify_stub_bx "$1"; }
    gh() { notify_gh_stub "$@"; }
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    skip() { printf 'skip %s\n' "$1"; }
    rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer >/dev/null 2>&1
    printf 'fixture-rows=%s\n' "$(grep -c . <<<"$REHEARSAL_NOTIFY_FIXTURES")"
    printf 'fixtures=[%s]\n' \
      "$(grep . <<<"$REHEARSAL_NOTIFY_FIXTURES" | paste -sd';' -)"
  )
}

notify_out="$(notify_stage_run label)"
t notify-fixture-unlabelled-pr-is-closed-by-the-leg 1 \
  "$(grep -cF "api -X PATCH repos/$NOTIFY_WORK/pulls/1 -f state=closed" "$NOTIFY_GH_CALLS")"
t notify-fixture-unlabelled-pr-in-the-notify-half-is-closed-too 1 \
  "$(grep -cF "api -X PATCH repos/$NOTIFY_EXTRA/pulls/2 -f state=closed" "$NOTIFY_GH_CALLS")"
t notify-fixture-unlabelled-pr-leaves-nothing-open 'fixture-rows=0' \
  "$(grep -F 'fixture-rows=' <<<"$notify_out")"

# A PR that was never created is not tracked and not closed: the list holds
# objects that exist, and nothing else.
notify_out="$(notify_stage_run create)"
t notify-fixture-uncreated-pr-is-never-closed 0 \
  "$(grep -cF 'api -X PATCH' "$NOTIFY_GH_CALLS")"
t notify-fixture-uncreated-pr-is-not-tracked 'fixture-rows=0' \
  "$(grep -F 'fixture-rows=' <<<"$notify_out")"

# A close that failed leaves its row behind for the EXIT pass, which is the
# only thing that can still retry it.
notify_out="$(notify_stage_run "" "pulls/2")"
t notify-fixture-failed-close-survives-the-leg 'fixture-rows=1' \
  "$(grep -F 'fixture-rows=' <<<"$notify_out")"
t notify-fixture-failed-close-survives-by-name "fixtures=[$NOTIFY_EXTRA 2]" \
  "$(grep -F 'fixtures=' <<<"$notify_out")"

# …and the retry itself, at the level of the closer: the row that failed is
# re-attempted and the rows that closed are not re-closed.
REHEARSAL_NOTIFY_FIXTURES=""
rehearsal_notify_record_fixture "$NOTIFY_WORK" "$NOTIFY_WORK_PR"
rehearsal_notify_record_fixture "$NOTIFY_EXTRA" "$NOTIFY_EXTRA_PR"
: >"$NOTIFY_GH_CALLS"
NOTIFY_GH_CLOSE_FAIL="pulls/$NOTIFY_EXTRA_PR"
gh() { notify_gh_stub "$@"; }
rehearsal_notify_close_fixtures 2>/dev/null
notify_close_rc=$?
t notify-fixture-failed-close-is-reported 1 "$notify_close_rc"
t notify-fixture-failed-close-stays-on-the-list "$NOTIFY_EXTRA $NOTIFY_EXTRA_PR" \
  "$(grep . <<<"$REHEARSAL_NOTIFY_FIXTURES")"
: >"$NOTIFY_GH_CALLS"
NOTIFY_GH_CLOSE_FAIL=""
rehearsal_notify_close_fixtures 2>/dev/null
t notify-fixture-failed-close-is-retried 1 \
  "$(grep -cF "repos/$NOTIFY_EXTRA/pulls/$NOTIFY_EXTRA_PR" "$NOTIFY_GH_CALLS")"
t notify-fixture-retry-does-not-reclose-the-closed-half 0 \
  "$(grep -cF "repos/$NOTIFY_WORK/pulls/$NOTIFY_WORK_PR" "$NOTIFY_GH_CALLS")"
t notify-fixture-retry-empties-the-list "" "$REHEARSAL_NOTIFY_FIXTURES"
unset -f gh notify_stage_run

# Both registries in ONE step: rehearsal_cleanup restores the notify half too,
# so an abnormal exit cannot leave a box watching a torn-down sandbox.
: >"$NOTIFY_BX_CALLS"
(
  # shellcheck source=drill/rehearsal-safety.sh
  source "$ROOT/drill/rehearsal-safety.sh"
  BOX_NAME=crew-drill-reviewer
  REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
  REHEARSAL_NOTIFY_BACKUP="$NOTIFY_BACKUP_PATH"
  REHEARSAL_NOTIFY_ABSENT=0
  bx() { printf '%s\n' "$1" >>"$NOTIFY_BX_CALLS"; }
  rehearsal_cleanup 0
) >/dev/null 2>&1
t notify-cleanup-restores-the-notify-registry 1 \
  "$(grep -cF 'mv ~/duty/notify-repos.txt.pre-drill-99 ~/duty/notify-repos.txt' "$NOTIFY_BX_CALLS")"
t notify-cleanup-still-restores-the-work-registry 1 \
  "$(grep -cF 'mv ~/duty/repos.txt.pre-drill-99 ~/duty/repos.txt' "$NOTIFY_BX_CALLS")"
# The leg writes its OWN verdict where the round summary reads it — the first
# review round found the summary reading the ROLE's exit code, which is 0 both
# for a union asserted and for a channel-unreachable skip (#423).
NOTIFY_STATUS_FILE="$TMP/notify-verdicts"
REHEARSAL_NOTIFY_STATUS="$NOTIFY_STATUS_FILE"
notify_leg_verdicts() {  # $1 how the post-write repos.txt read answers
  NOTIFY_SECOND_READ="$1"
  NOTIFY_PRE_STATE="${2:-present}"
  NOTIFY_PRE_TEXT="${3:-}"
  NOTIFY_WORK_BACKUP_STATE="${4:-present}"
  NOTIFY_WORK_BACKUP_TEXT="$NOTIFY_PRE_DRILL"
  NOTIFY_POST_STATE=present
  NOTIFY_POST_TEXT=""
  : >"$NOTIFY_BX_CALLS"
  : >"$NOTIFY_STATUS_FILE"
  printf '0\n' >"$NOTIFY_READS"
  printf '0\n' >"$NOTIFY_NOTIFY_READS"
  REHEARSAL_NOTIFY_BACKUP=""
  REHEARSAL_NOTIFY_ABSENT=0
  REHEARSAL_NOTIFY_CAPTURED=0
  (
    ROLE=reviewer
    REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
    bx() { notify_stub_bx "$1"; }
    gh() { case "$1 $2" in "repo view") return 0 ;; *) return 2 ;; esac; }
    ok() { :; }; fail() { :; }; skip() { :; }
    rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer >/dev/null 2>&1
  )
  cat "$NOTIFY_STATUS_FILE"
}
notify_out="$(notify_leg_verdicts widened)"
t notify-verdict-widened-registry-is-a-fail 1 \
  "$(grep -cF 'reviewer fail repos.txt widened while the union was being staged' <<<"$notify_out")"
t notify-verdict-widened-registry-records-no-pass 0 "$(grep -c ' ok ' <<<"$notify_out")"
notify_out="$(notify_leg_verdicts same)"
t notify-verdict-unstageable-fixture-is-a-fail 1 \
  "$(grep -cF "reviewer fail the repos.txt half's handoff fixture could not be staged" <<<"$notify_out")"
t notify-verdict-unstageable-fixture-records-no-pass 0 "$(grep -c ' ok ' <<<"$notify_out")"
# A box that will not say what its notify-repos.txt held is a fail, not a
# silent empty capture that teardown then vouches for.
notify_out="$(notify_leg_verdicts same unanswerable)"
t notify-verdict-unreadable-pre-drill-registry-is-a-fail 1 \
  "$(grep -cF 'reviewer fail the pre-drill notify-repos.txt could not be read' <<<"$notify_out")"
t notify-verdict-unreadable-pre-drill-registry-records-no-pass 0 "$(grep -c ' ok ' <<<"$notify_out")"
# ...and so is a box that will not say what the interlock put aside: the guard
# on the notify half cannot run, so the leg stops and the round says why rather
# than reporting a leg that simply passed.
notify_out="$(notify_leg_verdicts same present '' unanswerable)"
t notify-verdict-unvouched-work-backup-is-a-fail 1 \
  "$(grep -cF "reviewer fail the host's pre-drill work registry could not be read; the notify half was never written" <<<"$notify_out")"
t notify-verdict-unvouched-work-backup-records-no-pass 0 "$(grep -c ' ok ' <<<"$notify_out")"

unset -f bx notify_stub_bx notify_run_leg notify_union notify_leg_verdicts

# --- wiring: where the leg runs, and what clears up after it --------------
# shellcheck disable=SC2016  # match the literal source line in rehearsal.sh
if grep -Fq '. "$ROOT/drill/rehearsal-notify.sh"' "$ROOT/drill/rehearsal.sh"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-helper-sourced-in-rehearsal wired "$notify_wiring"
# Positional, because "after the safety interlock and before the role blocks"
# is the criterion: the call has to sit between the interlock's last ok and
# the first thing phase 2 does with a tick.
# shellcheck disable=SC2016  # match the literal call in rehearsal.sh
notify_interlock_block="$(sed -n '/ok "safety interlock: no attention demand parked outside the sandbox"/,/-- attention wake --/p' \
    "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # match the literal call in rehearsal.sh
if grep -Fq 'rehearsal_notify_drill "$SANDBOX"' <<<"$notify_interlock_block"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-leg-called-after-the-interlock wired "$notify_wiring"
# shellcheck disable=SC2016  # match the literal call site in rehearsal.sh
notify_call_block="$(sed -n '/rehearsal_notify_drill "\$SANDBOX"/,/^  fi$/p' "$ROOT/drill/rehearsal.sh")"
if grep -Fq 'exit 1' <<<"$notify_call_block"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-abort-return-stops-the-round wired "$notify_wiring"
if grep -Fq -- '--no-notify-drill' "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'notify  (repos.txt + notify-repos.txt union)' "$ROOT/drill/rehearsal-all.sh"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-all-opt-out-and-summary-wired wired "$notify_wiring"
# shellcheck disable=SC2016  # match teardown.sh's literal role-expansion text
if grep -Fq 'crew-drill-%s-notify' "$ROOT/drill/teardown.sh" \
    && grep -Fq 'crew-drill-$role-notify' "$ROOT/drill/teardown.sh"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-second-sandbox-torn-down wired "$notify_wiring"
# shellcheck disable=SC2016  # match the literal guard in rehearsal.sh
if grep -Fq 'rehearsal_notify_close_fixtures' "$ROOT/drill/rehearsal.sh"; then
  notify_wiring=wired
else
  notify_wiring=MISSING
fi
t notify-fixtures-closed-on-every-exit-path wired "$notify_wiring"
# The handoff label is the engine's, never retyped in the drill.
t notify-handoff-label-not-retyped-in-drill 0 \
  "$(grep -R -F 'state:needs-human' "$ROOT/drill" | wc -l | tr -d ' ')"

# --- the leg's own verdict, and the round summary that reads it (#423) -----
#
# The first review round found that rehearsal-all.sh read the leg's outcome
# off rehearsal.sh's exit code, which is 0 for a union asserted AND for a
# channel-unreachable skip — so a round that asserted nothing reported
# `ok notify`, and a role that failed elsewhere reported `FAIL notify`. The
# leg now writes its own verdict; these drive both halves.
: >"$NOTIFY_STATUS_FILE"

# The pure fold, first: worst wins across the roles that wrote a line.
t notify-verdict-fold-ok "ok both halves on one tick" \
  "$(rehearsal_notify_worst_verdict 'reviewer ok both halves on one tick')"
t notify-verdict-fold-skip-outranks-ok "skip operator channel unreachable: no-credentials" \
  "$(rehearsal_notify_worst_verdict 'triage ok both halves on one tick
reviewer skip operator channel unreachable: no-credentials')"
t notify-verdict-fold-fail-outranks-skip "fail the union was not delivered on one tick" \
  "$(rehearsal_notify_worst_verdict 'triage skip operator channel unreachable: no-credentials
reviewer fail the union was not delivered on one tick')"
t notify-verdict-fold-fail-outranks-a-later-ok "fail the union was not delivered on one tick" \
  "$(rehearsal_notify_worst_verdict 'triage fail the union was not delivered on one tick
reviewer ok both halves on one tick')"
# No line at all is not a verdict: the summary must not be able to read one.
if rehearsal_notify_worst_verdict '' >/dev/null 2>&1; then fold_out='a verdict'; else fold_out=none; fi
t notify-verdict-fold-empty-is-no-verdict none "$fold_out"
# A token the summary cannot classify grades as fail, never as a pass.
t notify-verdict-fold-unreadable-token-is-a-fail "fail wat" \
  "$(rehearsal_notify_worst_verdict 'reviewer sideways wat')"

# The two the round summary turns on: an unreachable channel, and the opt-out.
: >"$NOTIFY_STATUS_FILE"
(
  ROLE=reviewer
  bx() { printf 'no-credentials\n'; }
  ok() { :; }; fail() { :; }; skip() { :; }
  rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer >/dev/null 2>&1
)
t notify-verdict-unreachable-channel-is-a-skip-naming-it \
  "reviewer skip operator channel unreachable: no-credentials" \
  "$(cat "$NOTIFY_STATUS_FILE")"
: >"$NOTIFY_STATUS_FILE"
(
  REHEARSAL_NOTIFY_DRILL=0
  ROLE=reviewer
  bx() { :; }
  ok() { :; }; fail() { :; }; skip() { :; }
  rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer >/dev/null 2>&1
)
t notify-verdict-opt-out-is-an-announced-skip "reviewer skip --no-notify-drill" \
  "$(cat "$NOTIFY_STATUS_FILE")"

# The aggregation, executable: a real rehearsal-all.sh with stubbed siblings.
AGG="$TMP/notify-agg"
mkdir -p "$AGG"
cp "$ROOT/drill/rehearsal-all.sh" "$ROOT/drill/rehearsal-notify.sh" \
  "$ROOT/drill/rehearsal-verdict.sh" \
  "$ROOT/drill/rehearsal-hygiene.sh" "$ROOT/drill/rehearsal-breaker.sh" "$AGG/"
cat >"$AGG/rehearsal.sh" <<'AGGSH'
#!/usr/bin/env bash
# Stub role drill: writes the verdict the case asked for — the way the leg
# does, into REHEARSAL_NOTIFY_STATUS — and exits with the case's rc. The two
# are independent on purpose: that independence is what is under test.
role=""
while [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2 ;; *) shift ;; esac; done
v="$(cat "$AGG_DIR/$role.verdict" 2>/dev/null || true)"
[ -z "$v" ] || printf '%s %s\n' "$role" "$v" >>"$REHEARSAL_NOTIFY_STATUS"
v="$(cat "$AGG_DIR/$role.resume" 2>/dev/null || true)"
[ -z "$v" ] || printf '%s %s\n' "$role" "$v" >>"$REHEARSAL_RESUME_STATUS"
exit "$(cat "$AGG_DIR/$role.rc" 2>/dev/null || echo 0)"
AGGSH
printf '#!/usr/bin/env bash\nexit 0\n' >"$AGG/teardown.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$AGG/rehearsal-app.sh"
chmod +x "$AGG/rehearsal.sh" "$AGG/teardown.sh" "$AGG/rehearsal-app.sh"
agg_case() {  # $1 role, $2 notify verdict, $3 rc, $4 resume verdict
  printf '%s' "$2" >"$AGG/$1.verdict"
  printf '%s\n' "$3" >"$AGG/$1.rc"
  printf '%s' "${4:-}" >"$AGG/$1.resume"
}
agg_run() {  # $1 roles, then extra flags
  local roles="$1"; shift
  # Every sibling leg the notify fold is not under test with is switched off,
  # --no-hygiene-drill (#422), --no-breaker-drill (#424),
  # --no-attention-drill (#440) and --no-attention-audit-drill (#441)
  # included: these
  # cases assert what the NOTIFY
  # verdict does to `overall`, and a neighbour's row moving it would red them
  # for a reason that is not theirs. The composition of the two folds gets its
  # own case below, with the hygiene leg deliberately left on.
  AGG_DIR="$AGG" bash "$AGG/rehearsal-all.sh" --roles "$roles" \
    --no-app --no-config-drill --no-install-drill --no-resume-drill \
    --no-attention-drill --no-attention-audit-drill \
    --no-hygiene-drill --no-breaker-drill ${1+"$@"} 2>&1
}

# The breaker has its own enabled/incomplete partition: an enabled leg that no
# role reached is INCOMPLETE and cannot leave a green exit status, while the
# operator's explicit opt-out remains an announced green skip.
agg_breaker_run() {
  AGG_DIR="$AGG" bash "$AGG/rehearsal-all.sh" --roles '' \
    --no-app --no-config-drill --no-install-drill --no-resume-drill \
    --no-attention-drill --no-attention-audit-drill \
    --no-hygiene-drill --no-notify-drill ${1+"$@"} 2>&1
}
if agg_out="$(agg_breaker_run)"; then agg_rc=0; else agg_rc=$?; fi
t breaker-agg-enabled-no-role-is-incomplete 1 \
  "$(grep -cF 'INCOMPLETE breaker  (no role reached a box)' <<<"$agg_out")"
t breaker-agg-enabled-no-role-rc 2 "$agg_rc"
if agg_out="$(agg_breaker_run --no-breaker-drill)"; then agg_rc=0; else agg_rc=$?; fi
t breaker-agg-opt-out-is-an-announced-skip 1 \
  "$(grep -cF 'skip       breaker  (--no-breaker-drill)' <<<"$agg_out")"
t breaker-agg-opt-out-rc 0 "$agg_rc"

# The criterion: an unreachable operator channel produces a skip naming it and
# NEVER a pass — in the round summary too, which is where a round's verdict is
# actually read. The role exits 0, exactly as it did when this reported `ok`.
agg_case reviewer 'skip operator channel unreachable: no-credentials' 0
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-unreachable-channel-emits-no-ok-row 0 \
  "$(grep -c 'ok         notify' <<<"$agg_out")"
t notify-agg-unreachable-channel-names-the-reason 1 \
  "$(grep -cF 'INCOMPLETE notify  (leg skipped: operator channel unreachable: no-credentials — union UNPROVEN)' <<<"$agg_out")"
t notify-agg-unreachable-channel-is-not-a-green-round 2 "$agg_rc"

# The union actually asserted is the one thing that prints `ok notify`.
agg_case reviewer 'ok both halves on one tick' 0
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-asserted-union-is-a-pass 1 \
  "$(grep -cF 'ok         notify  (repos.txt + notify-repos.txt union)' <<<"$agg_out")"
t notify-agg-asserted-union-rc 0 "$agg_rc"

# The inverse conflation: a role that failed for its own reasons must not be
# able to red the notify row, and must not hide the leg's own pass.
agg_case triage '' 1
agg_case reviewer 'ok both halves on one tick' 0
if agg_out="$(agg_run "triage reviewer")"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-unrelated-role-failure-is-not-a-notify-fail 0 \
  "$(grep -c 'FAIL       notify' <<<"$agg_out")"
t notify-agg-unrelated-role-failure-keeps-the-leg-pass 1 \
  "$(grep -c 'ok         notify' <<<"$agg_out")"
t notify-agg-unrelated-role-failure-still-reds-its-role 1 \
  "$(grep -c 'FAIL       triage' <<<"$agg_out")"
t notify-agg-unrelated-role-failure-rc 1 "$agg_rc"

# And the other direction: the leg's own failure reds the round even where
# every role exited 0 — under the old wiring this printed `ok notify`.
agg_case triage '' 0
agg_case reviewer 'fail the union was not delivered on one tick (rc 5)' 0
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-leg-failure-reds-the-round 1 \
  "$(grep -cF 'FAIL       notify  (the union was not delivered on one tick (rc 5))' <<<"$agg_out")"
t notify-agg-leg-failure-rc 1 "$agg_rc"

# No verdict at all is phase 2 never reaching the leg: INCOMPLETE, never ok.
agg_case reviewer '' 0
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-no-verdict-is-incomplete 1 \
  "$(grep -cF 'INCOMPLETE notify  (phase 2 never reached the leg — union UNPROVEN)' <<<"$agg_out")"
t notify-agg-no-verdict-emits-no-ok-row 0 "$(grep -c 'ok         notify' <<<"$agg_out")"
t notify-agg-no-verdict-rc 2 "$agg_rc"
agg_case reviewer '' 1
if agg_out="$(agg_run reviewer)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-no-box-reached-says-so 1 \
  "$(grep -cF 'INCOMPLETE notify  (no role reached a box — union UNPROVEN)' <<<"$agg_out")"

# The announced omission stays a skip and keeps the round green: an operator
# who says their host has no channel gets a clean round; nobody else does.
agg_case reviewer '' 0
if agg_out="$(agg_run reviewer --no-notify-drill)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-opt-out-is-an-announced-skip 1 \
  "$(grep -cF 'skip       notify  (--no-notify-drill)' <<<"$agg_out")"
t notify-agg-opt-out-rc 0 "$agg_rc"

# ...but the flag switches off the notify VERDICT, not the round. With the
# leg's verdict as its only escalation route, a teardown that left the wrong
# bytes disappeared under --no-notify-drill; the role's own rc has to carry
# it, which is what cleanup_all's `exit "$rc"` restores.
agg_case reviewer '' 1
if agg_out="$(agg_run reviewer --no-notify-drill)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-opt-out-still-reds-a-failed-role 1 "$(grep -c '^## *FAIL *reviewer' <<<"$agg_out")"
t notify-agg-opt-out-failed-role-rc 1 "$agg_rc"

# The resume fold uses the same executable aggregator, with the other legs
# opted out so every mutation below grades the resume row alone.
resume_agg_run() {  # $1 roles, then extra flags
  local roles="$1"; shift
  AGG_DIR="$AGG" bash "$AGG/rehearsal-all.sh" --roles "$roles" \
    --no-app --no-config-drill --no-install-drill --no-hygiene-drill \
    --no-attention-drill --no-attention-audit-drill \
    --no-breaker-drill --no-notify-drill ${1+"$@"} 2>&1
}

# Reported defect: the builder leg skipped while the role exited 0. The row
# must name the omission and the round must be incomplete, never `ok resume`.
agg_case builder '' 0 'skip builder fixture PR unavailable'
if agg_out="$(resume_agg_run builder)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-unavailable-fixture-emits-no-ok-row 0 \
  "$(grep -c 'ok         resume' <<<"$agg_out")"
t resume-agg-unavailable-fixture-names-row 1 \
  "$(grep -cF 'INCOMPLETE resume  (leg skipped: builder fixture PR unavailable)' <<<"$agg_out")"
t resume-agg-unavailable-fixture-rc 2 "$agg_rc"

# The inverse: an unrelated builder assertion can red its role without
# rewriting a successful resume verdict as `FAIL resume`.
agg_case builder '' 1 'ok wake + zero-action stop'
if agg_out="$(resume_agg_run builder)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-unrelated-builder-failure-emits-no-resume-fail 0 \
  "$(grep -c 'FAIL       resume' <<<"$agg_out")"
t resume-agg-unrelated-builder-failure-keeps-resume-ok 1 \
  "$(grep -cF 'ok         resume  (wake + zero-action stop)' <<<"$agg_out")"
t resume-agg-unrelated-builder-failure-still-reds-round 1 "$agg_rc"

# Missing, malformed, and omitted verdicts cover the remaining enabled rows.
agg_case builder '' 0
if agg_out="$(resume_agg_run builder)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-no-verdict-is-incomplete 1 \
  "$(grep -cF 'INCOMPLETE resume  (builder phase 2 never reached the leg)' <<<"$agg_out")"
t resume-agg-no-verdict-rc 2 "$agg_rc"
agg_case builder '' 0 'sideways unreadable'
if agg_out="$(resume_agg_run builder)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-unreadable-token-is-fail 1 \
  "$(grep -cF 'FAIL       resume  (unreadable)' <<<"$agg_out")"
t resume-agg-unreadable-token-rc 1 "$agg_rc"
agg_case triage '' 0
if agg_out="$(resume_agg_run triage)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-builder-omitted-is-incomplete 1 \
  "$(grep -cF 'INCOMPLETE resume  (builder role omitted)' <<<"$agg_out")"
t resume-agg-builder-omitted-rc 2 "$agg_rc"
agg_case builder '' 0
if agg_out="$(resume_agg_run builder --no-resume-drill)"; then agg_rc=0; else agg_rc=$?; fi
t resume-agg-opt-out-is-the-only-skip-row 1 \
  "$(grep -cF 'skip       resume  (--no-resume-drill)' <<<"$agg_out")"
t resume-agg-opt-out-rc 0 "$agg_rc"

# --- the two legs' folds compose, they do not overwrite each other (#422) --
#
# #422's hygiene leg and this one both fold a verdict into the same `overall`,
# in that order. Both are worst-wins, so neither may talk the other's failure
# back down to a pass — an `ok notify` beside a red hygiene round must still
# exit 1, and a red notify leg beside a hygiene round that says nothing must
# still exit 1. `agg_run` above switches the sibling off precisely so this is
# the one place the interaction is asserted rather than assumed.
agg_hygiene_run() {  # $1 roles, $2 the hygiene result the role box records
  local roles="$1" hyg="$2"
  AGG_DIR="$AGG" AGG_HYGIENE="$hyg" bash "$AGG/rehearsal-all.sh" --roles "$roles" \
    --no-app --no-config-drill --no-install-drill --no-resume-drill \
    --no-attention-drill --no-attention-audit-drill --no-breaker-drill 2>&1
}
# The stub writes the hygiene result the way the live leg does — into the file
# rehearsal-all.sh hands it, per role — on top of the notify verdict it already
# writes. The two channels stay independent, which is the property under test.
cat >"$AGG/rehearsal.sh" <<'AGGSH'
#!/usr/bin/env bash
role=""
while [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2 ;; *) shift ;; esac; done
v="$(cat "$AGG_DIR/$role.verdict" 2>/dev/null || true)"
[ -z "$v" ] || printf '%s %s\n' "$role" "$v" >>"$REHEARSAL_NOTIFY_STATUS"
[ -z "${AGG_HYGIENE:-}" ] || printf '%s\n' "$AGG_HYGIENE" >"$REHEARSAL_HYGIENE_RESULT_FILE"
exit "$(cat "$AGG_DIR/$role.rc" 2>/dev/null || echo 0)"
AGGSH
chmod +x "$AGG/rehearsal.sh"

agg_case reviewer 'ok both halves on one tick' 0
if agg_out="$(agg_hygiene_run reviewer 1)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-hygiene-failure-does-not-clear-the-round 1 "$agg_rc"
t notify-agg-hygiene-failure-keeps-the-notify-pass 1 \
  "$(grep -c 'ok         notify' <<<"$agg_out")"

agg_case reviewer 'fail the notify-repos.txt half never arrived' 0
if agg_out="$(agg_hygiene_run reviewer 0)"; then agg_rc=0; else agg_rc=$?; fi
t notify-agg-hygiene-pass-does-not-clear-the-notify-failure 1 "$agg_rc"
t notify-agg-hygiene-pass-keeps-the-notify-fail-row 1 \
  "$(grep -c 'FAIL       notify' <<<"$agg_out")"

# Both legs mint a temp file per round and bash keeps exactly ONE EXIT handler,
# so a second `trap … EXIT` here would silently replace the first and leak the
# losing leg's file every round. One handler; it removes both.
t notify-all-installs-one-exit-trap 1 \
  "$(grep -c '^trap .* EXIT$' "$ROOT/drill/rehearsal-all.sh")"
# shellcheck disable=SC2016  # the handler line is deliberately literal
if grep -Fq 'rm -f -- "$NOTIFY_STATUS"' "$ROOT/drill/rehearsal-all.sh"; then
  r1=removed
else
  r1=LEAKED
fi
t notify-status-file-removed-by-the-one-exit-handler removed "$r1"
AGG_TRAP_MUTATED="$TMP/rehearsal-all-two-traps.sh"
# shellcheck disable=SC2016  # deliberate literal mutation of the handler body
sed '/rm -f -- "\$NOTIFY_STATUS"/d' "$ROOT/drill/rehearsal-all.sh" >"$AGG_TRAP_MUTATED"
# shellcheck disable=SC2016  # the removed line is deliberately literal
if grep -Fq 'rm -f -- "$NOTIFY_STATUS"' "$AGG_TRAP_MUTATED"; then
  r1=FALSE_PASS
else
  r1=red
fi
t notify-status-left-unremoved-reds red "$r1"

# Restore the plain stub for anything downstream that drives it.
cat >"$AGG/rehearsal.sh" <<'AGGSH'
#!/usr/bin/env bash
role=""
while [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2 ;; *) shift ;; esac; done
v="$(cat "$AGG_DIR/$role.verdict" 2>/dev/null || true)"
[ -z "$v" ] || printf '%s %s\n' "$role" "$v" >>"$REHEARSAL_NOTIFY_STATUS"
exit "$(cat "$AGG_DIR/$role.rc" 2>/dev/null || echo 0)"
AGGSH
chmod +x "$AGG/rehearsal.sh"

# --- teardown compares BOTH registries against their pre-drill bytes ------
#
# A restore that exits 0 having moved the wrong bytes leaves the box working
# or watching a set nobody chose, while the round reports a clean teardown.
# So the comparison is after both restores, and it controls the verdict.
# Driven in its own process rather than a (..) group: rehearsal_cleanup reads
# BOX_NAME and REPOS_BACKUP from the round's scope, and a fixture that shadows
# them in a subshell makes every one of those reads a subshell read.
CLEANUP_DRIVER="$TMP/notify-cleanup-driver.sh"
#
# The stub answers as a box does, in three states and not two: `present` with
# the contents, `absent`, or nothing at all because the box has gone away. The
# last one is what round 2 was about — it used to read as "there was no
# backup", and the comparison then returned success having compared nothing.
cat >"$CLEANUP_DRIVER" <<'CLEANSH'
#!/usr/bin/env bash
set -uo pipefail
. "$ROOT/drill/rehearsal-notify.sh"
. "$ROOT/drill/rehearsal-safety.sh"
BOX_NAME=fixture
REPOS_BACKUP='~/duty/repos.txt.pre-drill-99'
# Whether this round's `cp` actually ran. The handle above is set BEFORE that
# copy in rehearsal_begin_isolation, so it is not the same fact and the case
# chooses it separately.
REHEARSAL_BACKUP_TAKEN="$CLEAN_BACKUP_TAKEN"
REHEARSAL_NOTIFY_BACKUP="$CLEAN_NOTIFY_BACKUP"
# After the sources: sourcing rehearsal-notify.sh resets these to their
# start-of-round defaults, which is the state the case is choosing.
REHEARSAL_NOTIFY_CAPTURED="$CLEAN_CAPTURED"
REHEARSAL_NOTIFY_ABSENT="$CLEAN_ABSENT"
REHEARSAL_NOTIFY_PRE_TEXT="$CLEAN_NOTIFY_PRE"
rehearsal_disarm_cron() { return 0; }
snap_reply() {  # $1 present|absent|unanswerable, $2 the contents
  case "$1" in
    present) printf 'present\n'; [ -n "$2" ] && printf '%s\n' "$2"; return 0 ;;
    absent)  printf 'absent\n'; return 0 ;;
    *)       return 255 ;;
  esac
}
bx() {
  case "$1" in
    # The restores, matched before the probes: their command names the same
    # paths, and what a case is choosing there is whether the mv/rm worked.
    *"mv ~/duty/repos.txt.pre-drill"*)        return "$CLEAN_REPOS_RESTORE_RC" ;;
    *"mv ~/duty/notify-repos.txt.pre-drill"*) return "$CLEAN_NOTIFY_RESTORE_RC" ;;
    *"rm -f ~/duty/notify-repos.txt"*)        return "$CLEAN_NOTIFY_RESTORE_RC" ;;
    *"-e ~/duty/repos.txt.pre-drill"*) snap_reply "$CLEAN_BACKUP_STATE" "$CLEAN_REPOS_PRE" ;;
    *"-e ~/duty/notify-repos.txt"*)    snap_reply "$CLEAN_NOTIFY_STATE" "$CLEAN_NOTIFY_AFTER" ;;
    *"-e ~/duty/repos.txt"*)           snap_reply "$CLEAN_REPOS_STATE" "$CLEAN_REPOS_AFTER" ;;
    *) return 0 ;;
  esac
}
rehearsal_cleanup "$1"
printf 'rc=%s\n' "$?"
CLEANSH
export ROOT CLEAN_BACKUP_STATE CLEAN_REPOS_PRE CLEAN_REPOS_STATE CLEAN_REPOS_AFTER
export CLEAN_NOTIFY_STATE CLEAN_NOTIFY_AFTER CLEAN_CAPTURED CLEAN_ABSENT CLEAN_NOTIFY_PRE
export CLEAN_REPOS_RESTORE_RC CLEAN_NOTIFY_RESTORE_RC CLEAN_NOTIFY_BACKUP
export REHEARSAL_NOTIFY_STATUS CLEAN_BACKUP_TAKEN
CLEANUP_VERDICTS="$TMP/notify-cleanup-verdicts"
cleanup_run() {  # $1 rc handed in
  REHEARSAL_NOTIFY_STATUS="$CLEANUP_VERDICTS"
  : >"$CLEANUP_VERDICTS"
  bash "$CLEANUP_DRIVER" "$1" 2>&1
}
CLEAN_BACKUP_STATE=present
CLEAN_BACKUP_TAKEN=1
CLEAN_REPOS_PRE='owner/one
owner/two'
CLEAN_REPOS_STATE=present
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"
CLEAN_REPOS_RESTORE_RC=0
CLEAN_NOTIFY_STATE=present
CLEAN_NOTIFY_AFTER='owner/watched'
CLEAN_NOTIFY_RESTORE_RC=0
CLEAN_NOTIFY_BACKUP=''
CLEAN_CAPTURED=1
CLEAN_ABSENT=0
CLEAN_NOTIFY_PRE='owner/watched'
clean_out="$(cleanup_run 0)"
t notify-cleanup-matching-registries-pass "rc=0" "$(tail -n 1 <<<"$clean_out")"
# Only ever worsens: an rc it was handed survives a clean comparison.
t notify-cleanup-passes-the-handed-rc-through "rc=2" "$(tail -n 1 <<<"$(cleanup_run 2)")"

# Must fail: the work registry restored with the wrong bytes.
CLEAN_REPOS_AFTER='owner/one'
clean_out="$(cleanup_run 0)"
t notify-cleanup-wrong-work-registry-bytes-red "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-wrong-work-registry-names-the-file 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/repos.txt differs from its pre-drill contents' <<<"$clean_out")"
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"

# Must fail: the notify registry restored with the wrong bytes.
CLEAN_NOTIFY_AFTER='heavy-duty/ceremony'
clean_out="$(cleanup_run 0)"
t notify-cleanup-wrong-notify-registry-bytes-red "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-wrong-notify-registry-names-the-file 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt differs from its pre-drill contents' <<<"$clean_out")"
CLEAN_NOTIFY_AFTER='owner/watched'

# Absent before the drill means absent after it — both ways round.
CLEAN_ABSENT=1
CLEAN_NOTIFY_STATE=absent
t notify-cleanup-absent-before-and-gone-after-passes "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_NOTIFY_STATE=present
clean_out="$(cleanup_run 0)"
t notify-cleanup-file-left-behind-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-file-left-behind-says-there-was-none 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt is still in place; the box had none before the drill' <<<"$clean_out")"
CLEAN_ABSENT=0

# A leg that never captured has nothing to vouch for: the notify half is not
# asserted, and the work half still is.
CLEAN_CAPTURED=0
CLEAN_NOTIFY_AFTER='heavy-duty/ceremony'
t notify-cleanup-uncaptured-leg-asserts-nothing "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_REPOS_AFTER='owner/one'
t notify-cleanup-uncaptured-leg-still-checks-the-work-registry "rc=1" \
  "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"
# Nothing backed up is nothing to vouch for either — but only when the box
# SAID so, AND this round never made a copy. See the unanswerable-probe cases
# below for the first difference and the deleted-backup case for the second.
CLEAN_BACKUP_STATE=absent
CLEAN_BACKUP_TAKEN=0
CLEAN_REPOS_AFTER='whatever the box has'
t notify-cleanup-backup-never-taken-asserts-nothing "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"

# Must fail: the copy WAS made — so ~/duty/repos.txt was truncated and the only
# pre-drill bytes on the box were in that backup — and the box now says the
# backup is not there. This is a positively MEASURED loss, and it used to take
# the same branch as "there was nothing to back up": rc 0, comparing nothing,
# with the box left holding whatever the drill wrote (#423, round 3).
CLEAN_BACKUP_TAKEN=1
clean_out="$(cleanup_run 0)"
t notify-cleanup-deleted-backup-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-deleted-backup-says-so 1 \
  "$(grep -cF 'TEARDOWN: the pre-drill repos.txt backup this round made is gone' <<<"$clean_out")"
t notify-cleanup-deleted-backup-verdict-names-the-state 1 \
  "$(grep -cF 'fail teardown could not find the pre-drill repos.txt backup this round made' "$CLEANUP_VERDICTS")"
# ...and it is not confused with the box that would not answer at all, which
# has its own reason string.
t notify-cleanup-deleted-backup-is-not-the-unanswerable-reason 0 \
  "$(grep -cF 'the box did not say whether the pre-drill repos.txt backup was there' <<<"$clean_out")"
CLEAN_BACKUP_STATE=present
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"
CLEAN_CAPTURED=1
CLEAN_NOTIFY_AFTER='owner/watched'

# --- the box that stops answering, and the restore that does not run ------
#
# Every case below passed before round 2: each one ends in a `cat … || true`
# or a `test -f` whose failure was indistinguishable from an absent file, so
# teardown vouched for a registry nobody had looked at.

# Must fail: the backup probe is unanswerable. "The box did not say" is not
# "there was no backup", and the second reading is the one that returns 0.
CLEAN_BACKUP_STATE=unanswerable
clean_out="$(cleanup_run 0)"
t notify-cleanup-unanswerable-backup-probe-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-unanswerable-backup-probe-says-so 1 \
  "$(grep -cF 'TEARDOWN: the box did not say whether the pre-drill repos.txt backup was there' <<<"$clean_out")"
t notify-cleanup-unanswerable-backup-probe-verdict-names-the-state 1 \
  "$(grep -cF 'fail teardown could not read the pre-drill repos.txt backup' "$CLEANUP_VERDICTS")"
CLEAN_BACKUP_STATE=present

# Must fail: the restore itself did not run. It used to print a warning and
# leave the comparison to a probe that had already decided there was nothing
# to compare.
CLEAN_REPOS_RESTORE_RC=255
clean_out="$(cleanup_run 0)"
t notify-cleanup-failed-work-restore-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-failed-work-restore-names-the-file 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/repos.txt could not be restored' <<<"$clean_out")"
t notify-cleanup-failed-work-restore-verdict-says-restore 1 \
  "$(grep -cF 'fail teardown could not restore repos.txt' "$CLEANUP_VERDICTS")"
CLEAN_REPOS_RESTORE_RC=0

# Must fail: the read-back after the restore is unanswerable. The pre-drill
# bytes here are EMPTY, which is the exact shape the old `cat … || true` let
# through — an unreadable file came back as "" and compared equal.
CLEAN_REPOS_PRE=''
CLEAN_REPOS_STATE=unanswerable
clean_out="$(cleanup_run 0)"
t notify-cleanup-unreadable-work-registry-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-unreadable-work-registry-is-not-empty-bytes 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/repos.txt could not be read back after the restore' <<<"$clean_out")"
# ...and a box that really did have an empty repos.txt still passes.
CLEAN_REPOS_STATE=present
CLEAN_REPOS_AFTER=''
t notify-cleanup-empty-work-registry-restored-passes "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"
# ...while one the restore left missing entirely does not.
CLEAN_REPOS_STATE=absent
clean_out="$(cleanup_run 0)"
t notify-cleanup-missing-work-registry-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-missing-work-registry-says-so 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/repos.txt is not there after the restore' <<<"$clean_out")"
CLEAN_REPOS_STATE=present
CLEAN_REPOS_PRE='owner/one
owner/two'
CLEAN_REPOS_AFTER="$CLEAN_REPOS_PRE"

# The same three, on the notify half. A backup path is set so the restore is
# actually attempted — that is the call whose failure is under test.
# shellcheck disable=SC2088  # a box-side path: the tilde expands in the box
CLEAN_NOTIFY_BACKUP='~/duty/notify-repos.txt.pre-drill-99'
CLEAN_NOTIFY_RESTORE_RC=255
clean_out="$(cleanup_run 0)"
t notify-cleanup-failed-notify-restore-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-failed-notify-restore-names-the-file 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt could not be restored' <<<"$clean_out")"
t notify-cleanup-failed-notify-restore-verdict-says-restore 1 \
  "$(grep -cF 'fail teardown could not restore notify-repos.txt' "$CLEANUP_VERDICTS")"
CLEAN_NOTIFY_RESTORE_RC=0
CLEAN_NOTIFY_BACKUP=''

CLEAN_NOTIFY_PRE=''
CLEAN_NOTIFY_STATE=unanswerable
clean_out="$(cleanup_run 0)"
t notify-cleanup-unreadable-notify-registry-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-unreadable-notify-registry-is-not-empty-bytes 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt could not be read back after the restore' <<<"$clean_out")"
CLEAN_NOTIFY_STATE=present
CLEAN_NOTIFY_AFTER=''
t notify-cleanup-empty-notify-registry-restored-passes "rc=0" "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_NOTIFY_STATE=absent
clean_out="$(cleanup_run 0)"
t notify-cleanup-missing-notify-registry-reds "rc=1" "$(tail -n 1 <<<"$clean_out")"
t notify-cleanup-missing-notify-registry-says-so 1 \
  "$(grep -cF 'TEARDOWN: ~/duty/notify-repos.txt is not there after the restore' <<<"$clean_out")"
# An unanswerable read is not the absence the ABSENT branch asserts either:
# the box that shipped no notify-repos.txt must still be READ to say so.
CLEAN_ABSENT=1
CLEAN_NOTIFY_STATE=unanswerable
t notify-cleanup-unanswerable-read-is-not-the-absence-asserted "rc=1" \
  "$(tail -n 1 <<<"$(cleanup_run 0)")"
CLEAN_ABSENT=0
CLEAN_NOTIFY_STATE=present
CLEAN_NOTIFY_PRE='owner/watched'
CLEAN_NOTIFY_AFTER='owner/watched'

# --- the verdict has to reach the EXIT trap's exit status -----------------
#
# It did not. drill/rehearsal.sh runs under `set -uo pipefail` with no -e, and
# a `return` from an EXIT-trap function does not change the shell's exit
# status — so the comparison above was computed, printed, and discarded, and a
# standalone `--role X` round exited 0 on a registry left holding the wrong
# bytes. This case used to grep for the wiring line, which is exactly why it
# passed while the property did not hold; it now runs rehearsal.sh's REAL
# cleanup_all, extracted from the file, and reads the status.
CLEANUP_ALL_SRC="$TMP/notify-cleanup-all.sh"
awk '/^cleanup_all\(\) \{$/,/^\}$/' "$ROOT/drill/rehearsal.sh" >"$CLEANUP_ALL_SRC"
t notify-cleanup-all-extracted-from-the-real-file 1 \
  "$(grep -c '^cleanup_all() {$' "$CLEANUP_ALL_SRC")"
CLEANUP_ALL_DRIVER="$TMP/notify-cleanup-all-driver.sh"
cat >"$CLEANUP_ALL_DRIVER" <<'EXITSH'
#!/usr/bin/env bash
set -uo pipefail
CLEANUP_RETURNS="$1"   # what the case makes the teardown comparison say
BOX_TOUCHED=1
BOX_NAME=""
ACQUIRE_TMP=""
REHEARSAL_NOTIFY_FIXTURES=""
BUILDER_CLEANUP_REPO=""; BUILDER_CLEANUP_AUTHOR=""
TRIAGE_CLEANUP_REPO=""; TRIAGE_CLEANUP_ISSUES=""
bx() { return 0; }
rehearsal_cleanup() { return "$CLEANUP_RETURNS"; }
. "$CLEANUP_ALL_SRC"
trap cleanup_all EXIT
exit 0
EXITSH
export CLEANUP_ALL_SRC
bash "$CLEANUP_ALL_DRIVER" 1 >/dev/null 2>&1
t notify-cleanup-verdict-reaches-the-exit-status 1 "$?"
bash "$CLEANUP_ALL_DRIVER" 0 >/dev/null 2>&1
t notify-cleanup-clean-teardown-keeps-the-exit-status 0 "$?"

# --- rehearsal reviewer announce ordering (#192) --------------------------
# shellcheck source=drill/review-order.sh
source "$ROOT/drill/review-order.sh"
REVIEW_HEAD="$(printf 'a%.0s' {1..40})"
REVIEW_BEFORE_COMMENTS='[{"user":{"login":"reviewer"},"body":"🔎 reviewing head '"$REVIEW_HEAD"'","created_at":"2026-07-30T10:00:00Z","guest_clock":"2099-01-01T00:00:00Z"}]'
REVIEW_AFTER_COMMENTS='[{"user":{"login":"reviewer"},"body":"🔎 reviewing head '"$REVIEW_HEAD"'","created_at":"2026-07-30T10:06:00Z","guest_clock":"2000-01-01T00:00:00Z"}]'
REVIEW_VERDICTS='[{"user":{"login":"reviewer"},"commit_id":"'"$REVIEW_HEAD"'","state":"APPROVED","submitted_at":"2026-07-30T10:05:00Z"}]'

if rehearsal_review_announce_precedes_verdict_from_json \
    reviewer "$REVIEW_HEAD" "$REVIEW_BEFORE_COMMENTS" "$REVIEW_VERDICTS"; then
  review_order_rc=0
else
  review_order_rc=$?
fi
t rehearsal-review-announce-before-verdict-rc 0 "$review_order_rc"

if review_order_out="$(rehearsal_review_announce_precedes_verdict_from_json \
    reviewer "$REVIEW_HEAD" "$REVIEW_AFTER_COMMENTS" "$REVIEW_VERDICTS" 2>&1)"; then
  review_order_rc=0
else
  review_order_rc=$?
fi
t rehearsal-review-announce-after-verdict-rc 5 "$review_order_rc"
case "$review_order_out" in
  *"review ordering: announce must precede verdict"*) r1=named ;;
  *) r1=missing ;;
esac
t rehearsal-review-announce-after-verdict-names-ordering named "$r1"
# The mutation leaves the two existing predicates satisfied: the announce is
# still present at this head and still appears exactly once.
t rehearsal-review-after-verdict-presence-still-passes 1 \
  "$(jq -r --arg h "$REVIEW_HEAD" '[.[] | select(.body == ("🔎 reviewing head " + $h))] | length' \
    <<<"$REVIEW_AFTER_COMMENTS")"
t rehearsal-review-after-verdict-dedup-still-passes 1 \
  "$(jq -r '[.[] | select(.body | startswith("🔎 reviewing head"))] | length' \
    <<<"$REVIEW_AFTER_COMMENTS")"

# --- install.sh: crontab preflight and convergence (#25) ----------------
# A curated PATH makes "crontab absent" deterministic even on a workstation
# that happens to have cron installed. Everything install.sh legitimately
# needs is linked in; gh and git are fixture shims.
ISHIM="$TMP/install-bin"
IHOME="$TMP/install-home"
IDUTY="$IHOME/duty"
CRON_STATE="$TMP/crontab"
mkdir -p "$ISHIM" "$IHOME"
# find/sort/tail/xargs joined the list with #159's engine manifest: the curated
# PATH is the box's whole world here, and a tool missing from it degrades the
# install to `unverified` instead of failing, which would hide the very thing
# these fixtures assert.
for cmd in awk bash basename cat chmod cp date dirname env find grep head mkdir mktemp mv readlink rm sed sha256sum sort tail tr wc xargs; do
  ln -s "$(command -v "$cmd")" "$ISHIM/$cmd"
done
# If install.sh ever infers from hostname again, make the regression reproduce
# the dangerous case deterministically rather than depend on this test host.
printf '#!/usr/bin/env bash\nprintf "claude-builder\\n"\n' >"$ISHIM/hostname"
chmod +x "$ISHIM/hostname"
ln -s "$(command -v jq)" "$ISHIM/jq"
printf '#!/usr/bin/env bash\nexit 1\n' >"$ISHIM/gh"
# shellcheck disable=SC2016  # expanded when the fixture shim runs
printf '#!/usr/bin/env bash\n[ "${FIXTURE_GITLESS:-0}" != 1 ] || exit 1\nprintf "fixture-sha\\n"\n' >"$ISHIM/git"
chmod +x "$ISHIM/gh" "$ISHIM/git"

install_fixture() {
  env HOME="$IHOME" DUTY_DIR="$IDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" --agent claude --role reviewer "$@"
}

if install_out="$(install_fixture 2>&1)"; then r1=0; else r1=$?; fi
t install-no-cron-no-arm-rc 0 "$r1"
case "$install_out" in *"REPLACE the crontab"*) r1=manual ;; *) r1=missing ;; esac
t install-no-cron-no-arm-instructions manual "$r1"
case "$install_out" in *"command not found"*) r1=leaked ;; *) r1=clean ;; esac
t install-no-cron-no-arm-clean clean "$r1"
t install-version-with-provenance \
  "crew@$(head -1 "$ROOT/VERSION") (fixture-sha)" "$(head -1 "$IDUTY/VERSION")"

# The installed package shape has no .git. Run that actual shape, rather than
# trusting the Git shim used by the rest of the installer fixtures.
GITLESS_ROOT="$TMP/gitless-crew"
GITLESS_HOME="$TMP/gitless-home"
mkdir -p "$GITLESS_ROOT" "$GITLESS_HOME"
cp -R "$SHARED" "$GITLESS_ROOT/shared"
cp -R "$ROOT/examples" "$GITLESS_ROOT/examples"
cp "$ROOT/VERSION" "$GITLESS_ROOT/VERSION"
if FIXTURE_GITLESS=1 HOME="$GITLESS_HOME" DUTY_DIR="$GITLESS_HOME/duty" \
  PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
  /bin/bash "$GITLESS_ROOT/shared/install.sh" --agent claude --role reviewer \
  >"$TMP/gitless-install.out" 2>&1; then r1=0; else r1=$?; fi
t install-gitless-rc 0 "$r1"
t install-gitless-stamps-version \
  "crew@$(head -1 "$ROOT/VERSION")" "$(head -1 "$GITLESS_HOME/duty/VERSION")"
case "$(head -1 "$GITLESS_HOME/duty/VERSION")" in
  *unknown*) r1=unknown ;;
  *) r1=versioned ;;
esac
t install-gitless-never-unknown versioned "$r1"

printf '15 3 * * * unrelated-job\n' >"$CRON_STATE"
before_cron="$(cat "$CRON_STATE")"
if install_out="$(install_fixture --arm-cron 2>&1)"; then r1=0; else r1=$?; fi
t install-no-cron-arm-rc 1 "$r1"
case "$install_out" in
  *"engine installed, but cron is not armed"*"administrator"*"sudo apt-get install cron"*"install.sh --arm-cron"*) r1=actionable ;;
  *) r1=missing ;;
esac
t install-no-cron-arm-message actionable "$r1"
case "$install_out" in *"command not found"*) r1=leaked ;; *) r1=clean ;; esac
t install-no-cron-arm-attributed clean "$r1"
t install-no-cron-arm-untouched "$before_cron" "$(cat "$CRON_STATE")"
[ -f "$IDUTY/VERSION" ] && r1=installed || r1=missing
t install-no-cron-arm-files-remain installed "$r1"

# shellcheck disable=SC2016  # fixture script expands these at execution time
printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -l) [ ! -f "$CRON_STATE" ] || cat "$CRON_STATE" ;;\n  -) tmp="$CRON_STATE.new"; cat >"$tmp"; mv "$tmp" "$CRON_STATE" ;;\n  *) tmp="$CRON_STATE.new"; cat "$1" >"$tmp"; mv "$tmp" "$CRON_STATE" ;;\nesac\n' >"$ISHIM/crontab"
chmod +x "$ISHIM/crontab"
if install_out="$(install_fixture --arm-cron 2>&1)"; then r1=0; else r1=$?; fi
t install-with-cron-arm-rc 0 "$r1"
case "$install_out" in *"crontab armed"*) r1=armed ;; *) r1=missing ;; esac
t install-with-cron-arm-output armed "$r1"
t install-with-cron-preserves-existing 1 "$(grep -cF 'unrelated-job' "$CRON_STATE")"
t install-with-cron-one-tick 1 "$(grep -cF "$IDUTY/bin/tick.sh" "$CRON_STATE")"
install_fixture --arm-cron >/dev/null 2>&1
t install-with-cron-rerun-one-tick 1 "$(grep -cF "$IDUTY/bin/tick.sh" "$CRON_STATE")"

# --- crew upgrade --all is roster-scoped, not host-wide (#37) ------------
# `--all` used to mean box_names(): every box on the host, each installed
# with --arm-cron. That reached off-roster boxes -- a drill box between runs
# carries a real identity and a production registry and is deliberately
# disarmed -- and armed them by routine maintenance.
UROSTER="$TMP/upgrade-roster"
printf '# comment\nclaude-triage    claude  triage\nclaude-builder   claude  builder\n\n' >"$UROSTER"
roster_names_fixture() { grep -vE '^[[:space:]]*(#|$)' "$UROSTER" | awk '{print $1}'; }
host_boxes_fixture() { printf 'claude-triage\ncrew-drill-reviewer\nclaude-builder\nsome-other-box\n'; }
t upgrade-roster-names "claude-triage
claude-builder" "$(roster_names_fixture)"
t upgrade-targets-are-roster-and-host "claude-builder
claude-triage" \
  "$(comm -12 <(roster_names_fixture | sort) <(host_boxes_fixture | sort))"
t upgrade-skips-off-roster "crew-drill-reviewer
some-other-box" \
  "$(comm -23 <(host_boxes_fixture | sort) <(roster_names_fixture | sort))"
# The drill box is the case that matters: present on the host, absent from
# the roster, and therefore never touched by --all.
case "$(comm -12 <(roster_names_fixture | sort) <(host_boxes_fixture | sort))" in
  *crew-drill*) r1=reached ;; *) r1=untouched ;;
esac
t upgrade-never-reaches-drill-box untouched "$r1"

# --- duty.sh lock sentinel: 199 AND the message --------------------------
# A bare non-zero `flock` under `set -euo pipefail` exited duty.sh AT the
# flock line, so the 199 branch never ran and a contended manual invocation
# printed nothing at all. Both halves are asserted: the exit code alone was
# always correct, which is why this survived unnoticed — only the drill's
# "lock contention -> 199 + message" check saw the silence.
LHOME="$TMP/lock-home"
mkdir -p "$LHOME"
env HOME="$LHOME" DUTY_DIR="$LHOME/duty" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
  /bin/bash "$SHARED/install.sh" --agent claude --role reviewer >/dev/null 2>&1
flock -n "$LHOME/duty/.duty.lock" -c 'sleep 3' >/dev/null 2>&1 &
lock_bg=$!
sleep 1
if lock_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" /bin/bash "$LHOME/duty/bin/duty.sh" 2>&1)"; then
  lock_rc=0
else
  lock_rc=$?
fi
wait "$lock_bg" 2>/dev/null || true
t duty-lock-sentinel-rc 199 "$lock_rc"
case "$lock_out" in *"already holds"*) r1=message ;; *) r1=silent ;; esac
t duty-lock-sentinel-message message "$r1"

# --- count predicates must fail CLOSED on empty and on error output ------
# `grep -qv '^0$'` reads as "the count is not zero", but -v selects lines
# that do NOT match, so it returns 0 for EMPTY input and for gh's error JSON
# — the check went green when the API call failed. Same defect class as the
# null check in #29: a predicate whose failure mode looks like success.
for _in in '' '0' '{"message":"Not Found","status":"404"}'; do
if grep -qE '^[1-9][0-9]*$' <<<"$_in"; then r1=passed; else r1=refused; fi
  t "count-predicate-refuses-${_in:-empty}" refused "$r1"
done
if grep -qE '^[1-9][0-9]*$' <<<'3'; then r1=passed; else r1=refused; fi
t count-predicate-accepts-real-count passed "$r1"
# The shape it replaced, pinned so nobody reintroduces it. Uses gh's error
# JSON, not empty input: -v on an empty stream is shell/grep dependent, but
# ANY non-"0" line — which is what a failed gh call prints to stdout — makes
# the old predicate return 0. That is the realistic failure and it is
# deterministic everywhere.
if grep -qv '^0$' <<<'{"message":"Not Found","status":"404"}'; then r1=fail-open; else r1=fail-closed; fi
t count-predicate-old-shape-was-fail-open fail-open "$r1"

# --- notify.sh lock sentinel: same set -e trap as duty.sh (#30) ----------
# duty.sh was fixed for this; notify.sh has the identical preamble and was
# missed. Asserted the same way: the exit code alone was always right, so
# only the message distinguishes fixed from broken.
flock -n "$LHOME/duty/.notify.lock" -c 'sleep 3' >/dev/null 2>&1 &
nlock_bg=$!
sleep 1
if nlock_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" /bin/bash "$LHOME/duty/bin/notify.sh" 2>&1)"; then
  nlock_rc=0
else
  nlock_rc=$?
fi
wait "$nlock_bg" 2>/dev/null || true
t notify-lock-sentinel-rc 199 "$nlock_rc"
case "$nlock_out" in *"already holds"*) r1=message ;; *) r1=silent ;; esac
t notify-lock-sentinel-message message "$r1"

# --- attention label predicate: never let a null reach the shell ---------
# `gh api --jq` prints NOTHING for a null result (real jq prints "null"), so
# `index("attention") | grep -q null` matched in NEITHER state: present
# emitted "0", absent emitted "". The predicate must emit a token both ways.
t label-predicate-gone    true  "$(printf '{"labels":[]}\n' | jq -r '[.labels[].name] | index("attention") == null')"
t label-predicate-present false "$(printf '{"labels":[{"name":"attention"}]}\n' | jq -r '[.labels[].name] | index("attention") == null')"

# --- rehearsal safety: isolate, fail closed, restore, disarm (#26) -------
RHOME="$TMP/rehearsal-home"
RDUTY="$RHOME/duty"
RCRON="$TMP/rehearsal-crontab"
mkdir -p "$RDUTY"
printf 'heavy-duty/ceremony\nheavy-duty/incubator\nheavy-duty/rig\n' >"$RDUTY/repos.txt"
printf '*/5 * * * * %s/bin/tick.sh\n17 2 * * * unrelated-job\n' "$RDUTY" >"$RCRON"
# shellcheck disable=SC2034  # consumed by sourced rehearsal safety functions
BOX_NAME=fixture
# shellcheck disable=SC2034  # consumed by sourced rehearsal safety functions
REPOS_BACKUP=""
BX_FAIL_WRITE=0
bx() {
  case "$1" in
    "printf "*" > ~/duty/repos.txt") [ "$BX_FAIL_WRITE" -eq 0 ] || return 1 ;;
  esac
  HOME="$RHOME" PATH="$ISHIM" CRON_STATE="$RCRON" bash -c "$1"
}
# shellcheck source=drill/rehearsal-safety.sh
source "$ROOT/drill/rehearsal-safety.sh"

rehearsal_begin_isolation && r1=isolated || r1=failed
t rehearsal-isolates-before-tick isolated "$r1"
t rehearsal-isolation-empty 0 "$(wc -l <"$RDUTY/repos.txt")"
t rehearsal-isolation-records-the-copy 1 "$REHEARSAL_BACKUP_TAKEN"

# Must fail: the copy did not happen. The flag teardown reads is the COPY, not
# the handle — the handle is assigned first, so a round whose `cp` failed
# carries one too, and reading it as "a backup exists" is what let a deleted
# backup pass as "nothing to vouch for". Nothing may truncate the registry on
# this path either.
ISO_CALLS="$TMP/rehearsal-isolation-calls"
: >"$ISO_CALLS"
(
  bx() {
    printf '%s\n' "$1" >>"$ISO_CALLS"
    case "$1" in *"cp ~/duty/repos.txt"*) return 1 ;; esac
  }
  rehearsal_begin_isolation
  printf 'rc=%s taken=%s\n' "$?" "$REHEARSAL_BACKUP_TAKEN"
) >"$TMP/rehearsal-isolation-failed-copy"
t rehearsal-isolation-failed-copy-refuses 'rc=1 taken=0' \
  "$(cat "$TMP/rehearsal-isolation-failed-copy")"
t rehearsal-isolation-failed-copy-truncates-nothing 0 \
  "$(grep -cF ': > ~/duty/repos.txt' "$ISO_CALLS")"
# ...and on the path that does work, the copy is the FIRST thing the box is
# asked to do, so the flag is set before anything can overwrite what it names.
: >"$ISO_CALLS"
(
  bx() { printf '%s\n' "$1" >>"$ISO_CALLS"; }
  rehearsal_begin_isolation
) >/dev/null 2>&1
t rehearsal-isolation-copies-first 'cp' "$(head -1 "$ISO_CALLS" | cut -c1-2)"
t rehearsal-isolation-truncates-after 1 \
  "$(grep -cF ': > ~/duty/repos.txt' "$ISO_CALLS")"
rehearsal_narrow_to_sandbox owner/sandbox && r1=narrowed || r1=failed
t rehearsal-narrow-success narrowed "$r1"
t rehearsal-narrow-exact owner/sandbox "$(cat "$RDUTY/repos.txt")"
BX_FAIL_WRITE=1
rehearsal_narrow_to_sandbox owner/other && r1=continued || r1=refused
t rehearsal-narrow-fails-closed refused "$r1"
BX_FAIL_WRITE=0
rehearsal_cleanup 0
t rehearsal-restores-registry "heavy-duty/ceremony
heavy-duty/incubator
heavy-duty/rig" "$(cat "$RDUTY/repos.txt")"
t rehearsal-disarms-tick 0 "$(grep -cF "$RDUTY/bin/tick.sh" "$RCRON")"
t rehearsal-preserves-unrelated-cron 1 "$(grep -cF unrelated-job "$RCRON")"


# --- #347: the header names the version of the crew SERVING the page -----
SURF_V="floor: the API names the serving host"
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-truthful-header ok "$(surf_says "$r1" "$SURF_V")"
r1="$(surf app_surface_version "$SURF/fleet-wrong-version.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-staged-wrong-version FAIL "$(surf_says "$r1" "$SURF_V")"
# The server dropped what the launcher passed and served its placeholder.
r1="$(surf app_surface_version "$SURF/fleet-no-version.json" "crew 0.1.2 (/opt/crew)" 0.1.2)"
t app-surface-347-placeholder-served FAIL "$(surf_says "$r1" "$SURF_V")"
# The launcher and the page agree on a version this tree is not: the half that
# stops the assertion being a fixture comparing itself to itself.
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" 0.1.1)"
t app-surface-347-stale-release-named FAIL "$(surf_says "$r1" "$SURF_V")"
r1="$(surf app_surface_version "$SURF/fleet.json" "crew 0.1.2 (/opt/crew)" '')"
t app-surface-347-no-version-file FAIL "$(surf_says "$r1" "$SURF_V")"

# --- #190: the verdict on the tile is the BOX's own word -----------------
SURF_I="floor: every hired box's integrity verdict"
SURF_IV="floor: every integrity verdict is one of the three words"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-truthful-verdicts ok "$(surf_says "$r1" "$SURF_I")"
t app-surface-190-truthful-vocabulary ok "$(surf_says "$r1" "$SURF_IV")"
# The label names how many boxes were compared, and it must be all three that
# answered — not the one the loop happened to reach.
t app-surface-190-compares-every-box ok "$(surf_says "$r1" "verdict is the box's own answer (3 boxes)")"
# The reader that shells into a box drains the loop's stdin. Reading the roster
# on fd 3 is what keeps that from truncating the loop to its first member — a
# real host defect, found by running the leg, invisible to a stub reader that
# does not touch stdin.
r1="$(SURF_GREEDY_READER=1 surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-greedy-reader-visits-every-box ok "$(surf_says "$r1" "verdict is the box's own answer (3 boxes)")"
# The floor prints `current` for a box whose own manifest says `modified` —
# exactly the reassurance #190 exists to stop the page inventing.
r1="$(surf app_surface_integrity "$SURF/fleet-integrity-lie.json")"
t app-surface-190-staged-floor-lie FAIL "$(surf_says "$r1" "$SURF_I")"
SURF_INTEG="$SURF/integrity-fourth-word"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
t app-surface-190-fourth-word-red FAIL "$(surf_says "$r1" "$SURF_IV")"
SURF_INTEG="$SURF/integrity-silent"
r1="$(surf app_surface_integrity "$SURF/fleet.json")"
# No box answered the second reader, so there is nothing to compare — and the
# precondition is NAMED rather than passing quietly.
t app-surface-190-unanswerable-skips skip "$(surf_says "$r1" "$SURF_I")"
t app-surface-190-names-the-silent-box skip "$(surf_says "$r1" "integrity: crew-a")"
SURF_INTEG="$SURF/integrity"

# --- #204: not deployed is COUNTED and not DRAWN -------------------------
SURF_ND="floor: a roster box that is not deployed is counted"
SURF_NC="floor: the not-deployed boxes are counted but not drawn"
r1="$(surf app_surface_not_deployed "$SURF/fleet.json" 4)"
t app-surface-204-truthful-repair-verb ok "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-truthful-counts ok "$(surf_says "$r1" "$SURF_NC")"
r1="$(surf app_surface_not_deployed "$SURF/fleet-no-repair-verb.json" 4)"
t app-surface-204-staged-silent-note FAIL "$(surf_says "$r1" "$SURF_ND")"
# The filter applied one layer too high: the box is gone from the payload, so
# the fleet silently shrinks instead of keeping its declared size. Reds at the
# completeness gate now, which owns this direction and names the missing box —
# so the arithmetic assertion downstream is never reached and is `absent`.
r1="$(surf app_surface_not_deployed "$SURF/fleet-drops-a-box.json" 4)"
t app-surface-204-staged-shrunk-fleet FAIL "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-shrunk-fleet-names-the-box FAIL "$(surf_says "$r1" "never reported: crew-d")"
t app-surface-204-shrunk-fleet-stops-at-the-gate absent "$(surf_says "$r1" "$SURF_NC")"
# The same drop, of the box that is the fleet's ONLY measured absence. This is
# the direction the mutation above cannot reach: with `crew-c` gone no unit
# carries `hired=no`, so the empty-set branch used to conclude "every one of
# the 4 roster boxes is deployed" over a three-unit payload — #204's own
# regression reported as a fleet that does not exercise it. It must FAIL, not
# skip (codex-bot at 4bde9ce; triage's Must-fail in #420's test plan).
r1="$(surf app_surface_not_deployed "$SURF/fleet-drops-the-undeployed-box.json" 4)"
t app-surface-204-drops-the-undeployed-box FAIL "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-drops-the-undeployed-box-named FAIL "$(surf_says "$r1" "never reported: crew-c")"
r1="$(surf app_surface_not_deployed "$SURF/fleet-inventory-unreadable.json" 4)"
t app-surface-204-unmeasured-absence-skips skip "$(surf_says "$r1" "$SURF_ND")"
# ...and it keeps that precedence when the failed inventory ALSO cost the
# payload a unit: an unmeasured fleet is not the dropped-box regression, so it
# must still skip by its own reason rather than red at the gate.
r1="$(surf app_surface_not_deployed "$SURF/fleet-inventory-unreadable-and-short.json" 4)"
t app-surface-204-unreadable-outranks-the-gate skip "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-unreadable-names-its-reason skip "$(surf_says "$r1" "the box inventory did not answer for: crew-b")"
# The gate must not red a correct fleet: a complete payload with no measured
# absence still skips, with the one reason that is now true of it.
r1="$(surf app_surface_not_deployed "$SURF/fleet-all-deployed.json" 4)"
t app-surface-204-no-such-box-skips skip "$(surf_says "$r1" "$SURF_ND")"
t app-surface-204-complete-fleet-skip-reason skip "$(surf_says "$r1" "every one of the 4 roster boxes is deployed")"

# --- #218: `crew up --dry-run` names every box and touches nothing -------
printf 'crew-a: WOULD hire (currently: 2026-08-01T00:00Z)\ncrew-b: WOULD hire (currently: 2026-08-01T00:00Z)\ncrew-c: WOULD create (grok/triage)\ncrew-c: WOULD hire (new box — engine crew@0.1.2, cron armed)\ncrew-d: WOULD start\ncrew-d: WOULD SKIP — not converged; crew hire crew-d would refuse\n\nup --dry-run: 1 would be created, 1 started, 3 hired\n' \
  >"$SURF/up-dry.txt"
grep -v '^crew-d: ' "$SURF/up-dry.txt" >"$SURF/up-dry-silent.txt"
grep -v '^up --dry-run: ' "$SURF/up-dry.txt" >"$SURF/up-dry-no-summary.txt"
printf 'roster deadbeef\nboxes crew-a:running,crew-b:running,crew-d:stopped\ncron crew-a c0ffee\ncron crew-b c0ffee\ncron crew-d c0ffee\n' \
  >"$SURF/before.fp"
cp "$SURF/before.fp" "$SURF/after.fp"
# The one thing --dry-run promises never to do: a box that did not exist before
# the command exists after it.
sed 's/^boxes .*/boxes crew-a:running,crew-b:running,crew-c:running,crew-d:stopped/' \
  "$SURF/before.fp" >"$SURF/after-created.fp"
sed 's/^boxes .*/boxes UNREADABLE/' "$SURF/before.fp" >"$SURF/before-unreadable.fp"
# A component that did not answer, marked as such rather than hashed. Both of
# these used to be INVISIBLE: a failed `box_read` was piped straight into
# sha256sum, so two failed reads produced the same hash of the empty string and
# compared equal — "unchanged" over a crontab nobody read.
sed 's/^cron crew-d .*/cron crew-d UNREADABLE/' "$SURF/before.fp" \
  >"$SURF/before-cron-unreadable.fp"
awk '{ $NF = "UNREADABLE"; print }' "$SURF/before.fp" \
  >"$SURF/before-all-unreadable.fp"
# ...and the box that answered and genuinely has no crontab. Its read succeeded,
# so it is a measured fact and must still compare: the fix must not turn every
# un-armed box into an unreadable one.
EMPTY_SHA='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
sed "s/^cron crew-d .*/cron crew-d $EMPTY_SHA/" "$SURF/before.fp" \
  >"$SURF/before-cron-empty.fp"
# One side read it, the other did not: there is no comparison to make, and the
# side that answered is not evidence about the side that did not.
sed 's/^cron crew-d .*/cron crew-d UNREADABLE/' "$SURF/before.fp" \
  >"$SURF/after-cron-unreadable.fp"
# A component that was there before and is gone after is movement, not silence.
grep -v '^cron crew-d ' "$SURF/before.fp" >"$SURF/after-box-gone.fp"

SURF_D0="crew up --dry-run exits 0"
SURF_DN="crew up --dry-run names a planned action"
SURF_DS="crew up --dry-run summarises"
SURF_DC="crew up --dry-run changed nothing"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-truthful-rc ok "$(surf_says "$r1" "$SURF_D0")"
t app-surface-218-truthful-per-box ok "$(surf_says "$r1" "$SURF_DN")"
t app-surface-218-truthful-summary ok "$(surf_says "$r1" "$SURF_DS")"
t app-surface-218-truthful-unchanged ok "$(surf_says "$r1" "$SURF_DC")"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-created.fp" 0)"
t app-surface-218-staged-created-a-box FAIL "$(surf_says "$r1" "$SURF_DC")"
r1="$(surf app_surface_dry_run "$SURF/up-dry-silent.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-staged-unnamed-box FAIL "$(surf_says "$r1" "$SURF_DN")"
r1="$(surf app_surface_dry_run "$SURF/up-dry-no-summary.txt" "$SURF/before.fp" "$SURF/after.fp" 0)"
t app-surface-218-staged-no-summary FAIL "$(surf_says "$r1" "$SURF_DS")"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after.fp" 1)"
t app-surface-218-nonzero-rc-red FAIL "$(surf_says "$r1" "$SURF_D0")"
# Half the fingerprint was never taken, so "unchanged" is split rather than
# claimed over a comparison that compared less than it says. Both fingerprints
# are the SAME FILE here, which is the point: identical failures are identical,
# and `diff` called that agreement.
SURF_DP="crew up --dry-run moved none of the"
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-unreadable.fp" "$SURF/before-unreadable.fp" 0)"
t app-surface-218-unreadable-inventory-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-unreadable-inventory-still-compares ok "$(surf_says "$r1" "$SURF_DP")"
# The crontab half of the same defect, and the one with no marker at all before
# this: an unreachable box and a timed-out box both hashed to the empty string.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-cron-unreadable.fp" "$SURF/before-cron-unreadable.fp" 0)"
t app-surface-218-unreadable-crontab-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-unreadable-crontab-still-compares ok "$(surf_says "$r1" "$SURF_DP")"
# Nothing answered on either side. There is no partial claim left to make, so
# the partial `ok` must not be printed either.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-all-unreadable.fp" "$SURF/before-all-unreadable.fp" 0)"
t app-surface-218-nothing-readable-skips skip "$(surf_says "$r1" "$SURF_DC")"
t app-surface-218-nothing-readable-claims-nothing absent "$(surf_says "$r1" "$SURF_DP")"
# One side answered and the other did not: still no comparison, and the side
# that answered is not evidence about the side that did not.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-cron-unreadable.fp" 0)"
t app-surface-218-one-sided-read-skips skip "$(surf_says "$r1" "$SURF_DC")"
# ...but a box that ANSWERED and has no crontab is a measured fact, and must
# still compare. The repair must not turn every un-armed box into an unread one.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before-cron-empty.fp" "$SURF/before-cron-empty.fp" 0)"
t app-surface-218-empty-crontab-still-compares ok "$(surf_says "$r1" "$SURF_DC")"
# A component present before and absent after is movement, not silence — the
# shape a dry run that deleted something would leave.
r1="$(surf app_surface_dry_run "$SURF/up-dry.txt" "$SURF/before.fp" "$SURF/after-box-gone.fp" 0)"
t app-surface-218-component-vanished FAIL "$(surf_says "$r1" "$SURF_DC")"

# --- #308: an unanswered probe is unknown, never never-hired -------------
t app-surface-308-picks-the-silent-box crew-d \
  "$(surf app_surface_silent_box "$SURF/fleet.json")"
t app-surface-308-no-silent-box-to-ask '' \
  "$(surf app_surface_silent_box "$SURF/fleet-all-answered.json")"
printf 'box: crew-d\nengine: unknown — the box did not answer\n' >"$SURF/status-unknown.txt"
printf 'box: crew-d\nengine: not hired (no engine)\n'            >"$SURF/status-never-hired.txt"
printf 'box: crew-d\n'                                          >"$SURF/status-no-engine-line.txt"
SURF_S="an unanswered probe reads unknown"
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-unknown.txt" 0)"
t app-surface-308-truthful-unknown ok "$(surf_says "$r1" "$SURF_S")"
# The wrong repair: the operator is sent to `crew hire` for a box that is
# hired and not talking.
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-never-hired.txt" 0)"
t app-surface-308-staged-never-hired FAIL "$(surf_says "$r1" "$SURF_S")"
r1="$(surf app_surface_status_unknown crew-d "$SURF/status-no-engine-line.txt" 2)"
t app-surface-308-no-engine-line-red FAIL "$(surf_says "$r1" "$SURF_S")"

# --- #345: `no build duty` names a cause and a count ---------------------
{ printf 'crew-a 12:00 heavy-duty/crew: no build duty (board empty)\n'
  printf 'crew-b 12:00 heavy-duty/crew: no build duty (slot held by #402; board holds 3 ready)\n'
  printf 'crew-d 12:00 heavy-duty/crew: no build duty (2 ready, 1 round(s) held by seen-ledger)\n'
} >"$SURF/nbd.txt"
printf 'crew-a 12:00 heavy-duty/crew: no build duty\n' >"$SURF/nbd-bare.txt"
: >"$SURF/nbd-empty.txt"
SURF_N="duty.log: every no build duty line names a cause"
r1="$(surf app_surface_no_build_duty "$SURF/nbd.txt")"
t app-surface-345-truthful-causes ok "$(surf_says "$r1" "$SURF_N")"
# The bare line #345 replaced: indistinguishable from the burial bug.
r1="$(surf app_surface_no_build_duty "$SURF/nbd-bare.txt")"
t app-surface-345-staged-bare-line FAIL "$(surf_says "$r1" "$SURF_N")"
r1="$(surf app_surface_no_build_duty "$SURF/nbd-empty.txt")"
t app-surface-345-nothing-logged-skips skip "$(surf_says "$r1" "no build duty names a cause")"

# --- the page halves: the walk's own named lines ------------------------
{ printf '  ok   floor: the canvas header paints the serving host version\n'
  printf '  ok   render: the engine tile carries its integrity verdict\n'
} >"$SURF/walk.out"
printf '  FAIL floor: the canvas header paints the serving host version\n' >"$SURF/walk-failed.out"
: >"$SURF/walk-never-reached.out"
SURF_W="page: the header renders"
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk.out")"
t app-surface-walk-line-present ok "$(surf_says "$r1" "$SURF_W")"
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk-failed.out")"
t app-surface-walk-line-failed FAIL "$(surf_says "$r1" "$SURF_W")"
# A walk that exits 0 having never reached the check proves nothing about it.
r1="$(surf app_surface_walk_asserted "page: the header renders it" \
        "floor: the canvas header paints the serving host version" "$SURF/walk-never-reached.out")"
t app-surface-walk-never-reached FAIL "$(surf_says "$r1" "$SURF_W")"

# --- #312: disarmed is a decision, silent is an alarm --------------------
surf_page() {  # surf_page '<python mutating q>' → the page reader's payload
  python3 - "$1" <<'PY'
import json, sys
# `empty` is what drill/rehearsal-page-read.js reads off #emptyfloor: whether
# the panel is in the DOM at all, whether syncEmptyFloor has it shown, and its
# text. On a fleet with consoles drawn it is present and not shown, which is
# the shape the truthful fixture below carries.
q = {"live": True, "tiles": "4units3hired",
     "disarmed": ["crew-b"], "silent": ["crew-d"],
     "empty": {"present": True, "shown": False, "text": ""}}
exec(sys.argv[1])
print(json.dumps(q))
PY
}
# The empty floor as the page actually paints it (app.js:1681-1686), and the
# tile row that goes with a fleet where nothing is deployed: `hidden` is 4, so
# the hired tile renders, reading 0.
EMPTY_TEXT='NO BOX IS HIRED YET The fleet roster declares 4 boxes, and none of them is running an engine. A console appears here as its box is hired. crew hire <box>'
surf_page 'pass'                                     >"$SURF/page.json"
surf_page 'q["disarmed"], q["silent"] = [], ["crew-b"]' >"$SURF/page-alarms-a-decision.json"
surf_page 'q["silent"] = ["crew-b"]'                 >"$SURF/page-both-groups.json"
surf_page 'q["disarmed"] = ["crew-z"]'               >"$SURF/page-unknown-box.json"
surf_page 'q["disarmed"], q["silent"] = [], []'      >"$SURF/page-no-members.json"
surf_page 'q["live"] = False'                        >"$SURF/page-demo.json"
surf_page 'q["tiles"] = "3units3hired"'              >"$SURF/page-shrunk.json"
surf_page 'q["tiles"] = "4units"'                    >"$SURF/page-no-hired-tile.json"
surf_page 'q["tiles"] = "4units4hired"'              >"$SURF/page-furniture.json"
# The two dropped-member stages: a page that lists nobody wrongly, by listing
# nobody at all. Before both directions were asserted these PASSED.
surf_page 'q["silent"] = []'                         >"$SURF/page-drops-silent.json"
surf_page 'q["disarmed"] = []'                       >"$SURF/page-drops-disarmed.json"
# The page agreeing with a payload that calls crew-b silent, so the only thing
# left to disagree is `crew status`.
surf_page 'q["disarmed"], q["silent"] = [], ["crew-b", "crew-d"]' \
                                                     >"$SURF/page-b-silent.json"
# Two boxes the operator deliberately stopped, correctly grouped: the fleet the
# blind-set arity defect reds falsely when both are also logged out.
surf_page 'q["disarmed"], q["silent"] = ["crew-b", "crew-d"], []' \
                                                     >"$SURF/page-two-disarmed.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True, 'text': '''$EMPTY_TEXT'''}" \
                                                     >"$SURF/page-empty.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': False, 'shown': False, 'text': ''}" \
                                                     >"$SURF/page-empty-no-panel.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': False, 'text': '''$EMPTY_TEXT'''}" \
                                                     >"$SURF/page-empty-hidden.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True,
              'text': 'NO BOX IS HIRED YET The fleet roster declares 4 boxes.'}" \
                                                     >"$SURF/page-empty-no-verb.json"
surf_page "q['tiles'], q['disarmed'], q['silent'] = '4units0hired', [], []
q['empty'] = {'present': True, 'shown': True,
              'text': 'THE FLEET ROSTER IS EMPTY No box is declared. crew new <box>'}" \
                                                     >"$SURF/page-empty-wrong-verb.json"
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  disarmed\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status.txt"
# The same fleet, logged out. cli/crew:2123 gives a missing credential the note
# column outright, so the disarmed word never reaches it — the normal starting
# state on a drill host, and it must not read as a disagreement.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status-logged-out.txt"
# TWO boxes logged out, which is the arity that matters: the blind set was
# accumulated as a display string (`crew-b, crew-d`) and then tested token-wise,
# so every member but the last kept a comma and read as NOT blind — a false
# FAIL on a correct page, invisible with the one-box fixture above (codex-bot,
# claude-bot, #428). Creds-free is the normal starting state on a drill host and
# two quiet boxes is an ordinary fleet, so this is the shape that reds #400's
# round against a page that is right.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   convergence unknown\n'
} >"$SURF/status-both-blind.txt"
# ...and the same, with both blind boxes DISARMED rather than one of each, so
# the members that must not red are the ones the disarmed direction iterates.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  ⚠ log in: box shell crew-b\n'
  printf 'crew-d  kimi    builder   ⚠ log in: box shell crew-d\n'
} >"$SURF/status-two-disarmed-blind.txt"
# ...and the same fleet where the CLI simply does not agree: crew-b is armed
# and ticking as far as `crew status` can tell.
{ printf 'crew-a  claude  builder   armed\n'
  printf 'crew-b  codex   reviewer  2026-08-08T11:04Z reviewed #428\n'
  printf 'crew-d  kimi    builder   silent — no tick in 3 ticks\n'
} >"$SURF/status-b-armed.txt"

SURF_F="page: the state filter separates disarmed from silent"
SURF_T="page: the unit tile counts the declared roster"
SURF_E="page: an all-undeployed floor names the repair verb"
SURF_FC="page: the state filter agrees with crew status for every box"
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-truthful-split ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-204-page-truthful-tiles ok "$(surf_says "$r1" "$SURF_T")"
# Nothing was blind to `crew status`, so the reader's own caveat is not raised.
t app-surface-312-nothing-unclassifiable absent "$(surf_says "$r1" "$SURF_FC")"
# The load-bearing direction, and the whole of #312: a box the operator
# deliberately stopped counted in the alarm group.
r1="$(surf app_surface_page_groups "$SURF/page-alarms-a-decision.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-staged-decision-as-alarm FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-both-groups.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-both-groups-at-once FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-unknown-box.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-grouped-box-cli-never-saw FAIL "$(surf_says "$r1" "$SURF_F")"
# The other direction, which is the correction: a page that drops a genuinely
# silent box — or a genuinely disarmed one — has no member to be wrong about,
# and passed until the groups were compared as sets.
r1="$(surf app_surface_page_groups "$SURF/page-drops-silent.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-page-drops-a-silent-box FAIL "$(surf_says "$r1" "$SURF_F")"
r1="$(surf app_surface_page_groups "$SURF/page-drops-disarmed.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-page-drops-a-disarmed-box FAIL "$(surf_says "$r1" "$SURF_F")"
# The two readers disagreeing, each way round. The payload calls crew-b
# disarmed and the CLI shows it ticking...
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-b-armed.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-cli-does-not-confirm-disarmed FAIL "$(surf_says "$r1" "$SURF_F")"
# ...and the CLI calls crew-b deliberately stopped while the payload has it in
# the alarm group, which is #312's original defect read from the other reader.
r1="$(surf app_surface_page_groups "$SURF/page-b-silent.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet-b-not-disarmed.json")"
t app-surface-312-cli-says-stopped-payload-does-not FAIL "$(surf_says "$r1" "$SURF_F")"
# A logged-out box: `crew status` cannot answer for it, so it is named in its
# own skip and the page-side verdict still stands. Counting it as a
# disagreement would red a correct page on every creds-free host.
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-logged-out.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-credential-note-does-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-credential-note-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# TWO blind boxes, one from each group — the cheaper reproduction, since the
# blind set is filled from the disarmed boxes before the silent ones, so the
# disarmed member is the one that carried the comma.
r1="$(surf app_surface_page_groups "$SURF/page.json" "$SURF/status-both-blind.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-two-blind-boxes-do-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-two-blind-boxes-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# ...and both of them DISARMED, which is the case put directly to the loop that
# tests blind membership. A correct page must skip here and not FAIL.
r1="$(surf app_surface_page_groups "$SURF/page-two-disarmed.json" "$SURF/status-two-disarmed-blind.txt" 4 crew-c 3 "$SURF/fleet-two-disarmed.json")"
t app-surface-312-two-blind-disarmed-do-not-red ok "$(surf_says "$r1" "$SURF_F")"
t app-surface-312-two-blind-disarmed-named-as-skip skip "$(surf_says "$r1" "$SURF_FC")"
# The set is machine-readable and the message is a copy of it: both boxes are
# named, comma-joined, and neither naming nor membership depends on the other.
t app-surface-312-blind-skip-names-both skip "$(surf_says "$r1" "armed-ness would be in: crew-b, crew-d")"
r1="$(surf app_surface_page_groups "$SURF/page-no-members.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet-none-quiet.json")"
t app-surface-312-no-member-to-classify skip "$(surf_says "$r1" "$SURF_F")"
# The demo payload is not this host, so neither group may be read off it.
r1="$(surf app_surface_page_groups "$SURF/page-demo.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-312-demo-payload-skips skip "$(surf_says "$r1" "$SURF_F")"
t app-surface-204-demo-payload-skips skip "$(surf_says "$r1" "$SURF_T")"
t app-surface-204-demo-payload-skips-empty-floor skip "$(surf_says "$r1" "$SURF_E")"
r1="$(surf app_surface_page_groups "$SURF/page-shrunk.json" "$SURF/status.txt" 4 crew-c 3 "$SURF/fleet.json")"
t app-surface-204-staged-shrunk-tile FAIL "$(surf_says "$r1" "$SURF_T")"
# Fully deployed: the count half still holds, and the hired tile is furniture.
r1="$(surf app_surface_page_groups "$SURF/page-no-hired-tile.json" "$SURF/status.txt" 4 '' 4 "$SURF/fleet.json")"
t app-surface-204-page-fully-deployed ok "$(surf_says "$r1" "$SURF_T")"
r1="$(surf app_surface_page_groups "$SURF/page-furniture.json" "$SURF/status.txt" 4 '' 4 "$SURF/fleet.json")"
t app-surface-204-page-permanent-hired-tile FAIL "$(surf_says "$r1" "$SURF_T")"
# A floor with a console drawn is not the empty-floor state, and the drill will
# not un-hire a box to reach it: skipped by name, never quietly passed.
t app-surface-204-empty-floor-skips-when-drawn skip "$(surf_says "$r1" "$SURF_E")"

# --- #204's other half: the floor with nothing on it ---------------------
# Four declared boxes, none deployed. The issue asks for this floor to name
# `crew hire` in as many words, and nothing here read it before.
SURF_ALLND="crew-a crew-b crew-c crew-d"
r1="$(surf app_surface_page_groups "$SURF/page-empty.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-names-crew-hire ok "$(surf_says "$r1" "$SURF_E")"
# The count half still holds on that floor: 4 declared, 0 with a console.
t app-surface-204-empty-floor-tiles ok "$(surf_says "$r1" "$SURF_T")"
# A blank stage with no words on it is the state #204 named as the defect.
r1="$(surf app_surface_page_groups "$SURF/page-empty-no-panel.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-no-panel FAIL "$(surf_says "$r1" "$SURF_E")"
# In the DOM but never shown is the same blank stage to an operator.
r1="$(surf app_surface_page_groups "$SURF/page-empty-hidden.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-hidden FAIL "$(surf_says "$r1" "$SURF_E")"
# It says how many boxes are declared and stops — the count without the next
# step, which is the half the issue calls a requirement on the fix.
r1="$(surf app_surface_page_groups "$SURF/page-empty-no-verb.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-no-repair-verb FAIL "$(surf_says "$r1" "$SURF_E")"
# `crew new` is the wrong verb for a roster that DOES declare boxes: they exist
# to be hired, and telling the operator to create more is the wrong repair.
r1="$(surf app_surface_page_groups "$SURF/page-empty-wrong-verb.json" "$SURF/status.txt" 4 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-floor-wrong-verb FAIL "$(surf_says "$r1" "$SURF_E")"
# ...and it is the RIGHT verb when the roster declares nothing at all, which is
# the other branch syncEmptyFloor renders.
r1="$(surf app_surface_page_groups "$SURF/page-empty-wrong-verb.json" "$SURF/status.txt" 0 "$SURF_ALLND" 0 "$SURF/fleet-all-undeployed.json")"
t app-surface-204-empty-roster-names-crew-new ok "$(surf_says "$r1" "$SURF_E")"

# --- rehearsal phase 0: acquisition failures abort before checks (#27) --
P0SHIM="$TMP/phase0-bin"
P0HOME="$TMP/phase0-home"
P0LOG="$TMP/phase0-box.log"
mkdir -p "$P0SHIM" "$P0HOME"
# shellcheck disable=SC2016  # fixture expands state at execution time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$P0LOG"\ncase "$1" in\n  list) printf "[]\\n" ;;\n  new|exec) exit 0 ;;\n  *) exit 2 ;;\nesac\n' >"$P0SHIM/box"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0SHIM/gh"
chmod +x "$P0SHIM/box" "$P0SHIM/gh"
: >"$P0LOG"

if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --remote "$TMP/no-such-remote" \
    --ref nosuchbranch --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t rehearsal-bad-ref-rc 1 "$r1"
case "$p0out" in *"remote '$TMP/no-such-remote'"*"ref 'nosuchbranch'"*"aborted before checks"*) r1=attributed ;; *) r1=missing ;; esac
t rehearsal-bad-ref-attributed attributed "$r1"
t rehearsal-bad-ref-no-tick 0 "$(grep -cF 'exec crew-drill -- bash -lc ~/duty/bin/tick.sh' "$P0LOG" || true)"
case "$p0out" in *"fixture tests green"*|*"FAIL install"*) r1=cascaded ;; *) r1=stopped ;; esac
t rehearsal-bad-ref-no-cascade stopped "$r1"

# --tree is a promise that SOURCE_SHA identifies the tree the operator means
# to drill, including the committed ref phase 1 installs (#183). Refuse every
# dirty shape before the first box operation and show the paths and reason.
P0TREE="$TMP/phase0-tree"
mkdir -p "$P0TREE/shared/test" "$P0TREE/cli"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0TREE/shared/install.sh"
printf '#!/usr/bin/env bash\nprintf "failed 0\\n"\n' >"$P0TREE/shared/test/run.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0TREE/cli/crew"
printf '0.0.0-test\n' >"$P0TREE/VERSION"
chmod +x "$P0TREE/shared/install.sh" "$P0TREE/shared/test/run.sh" "$P0TREE/cli/crew"
git -C "$P0TREE" init -q
git -C "$P0TREE" add .
git -C "$P0TREE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture

: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
case "$p0out" in *"has uncommitted changes"*) r2=refused ;; *) r2=passed-guard ;; esac
t rehearsal-clean-tree-passes-guard passed-guard "$r2"
if grep -Eq '^(list|new) ' "$P0LOG"; then r2=reached-box; else r2=stopped-early; fi
t rehearsal-clean-tree-reaches-box reached-box "$r2"

printf '# dirty shared\n' >>"$P0TREE/shared/install.sh"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-shared-rc 1 "$r1"
case "$p0out" in
  *"shared/install.sh"*"SOURCE_SHA must name the tree"*"phase 1 installs"*"crew hire --ref"*) r2=attributed ;;
  *) r2=missing ;;
esac
t rehearsal-dirty-shared-attributed attributed "$r2"
t rehearsal-dirty-shared-before-box 0 "$(wc -l <"$P0LOG")"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal-all.sh" --roles reviewer --tree "$P0TREE" \
    --quick --no-app --no-config-drill --no-install-drill 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-all-passes-dirty-refusal-rc 1 "$r1"
case "$p0out" in *"has uncommitted changes"*"FAIL       reviewer"*) r2=passed ;; *) r2=swallowed ;; esac
t rehearsal-all-passes-dirty-refusal passed "$r2"

git -C "$P0TREE" restore shared/install.sh
printf '# dirty cli\n' >>"$P0TREE/cli/crew"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-cli-rc 1 "$r1"
case "$p0out" in *"cli/crew"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-cli-names-path named "$r2"
t rehearsal-dirty-cli-before-box 0 "$(wc -l <"$P0LOG")"

git -C "$P0TREE" restore cli/crew
printf '0.0.1-staged\n' >"$P0TREE/VERSION"
git -C "$P0TREE" add VERSION
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-staged-rc 1 "$r1"
case "$p0out" in *"VERSION"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-staged-names-path named "$r2"
t rehearsal-dirty-staged-before-box 0 "$(wc -l <"$P0LOG")"

git -C "$P0TREE" restore --staged --worktree VERSION
printf 'untracked\n' >"$P0TREE/NEW-FILE"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-dirty-untracked-rc 1 "$r1"
case "$p0out" in *"NEW-FILE"*) r2=named ;; *) r2=missing ;; esac
t rehearsal-dirty-untracked-names-path named "$r2"
t rehearsal-dirty-untracked-before-box 0 "$(wc -l <"$P0LOG")"
rm -f "$P0TREE/NEW-FILE"

P0NONGIT="$TMP/phase0-not-git"
mkdir -p "$P0NONGIT/shared/test"
printf 'fixture\n' >"$P0NONGIT/shared/install.sh"
printf 'fixture\n' >"$P0NONGIT/shared/test/run.sh"
printf 'fixture\n' >"$P0NONGIT/VERSION"
: >"$P0LOG"
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0NONGIT" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-non-git-tree-rc 1 "$r1"
case "$p0out" in *"must be a git checkout with a clean working tree"*) r2=owned ;; *) r2=raw ;; esac
t rehearsal-non-git-tree-owned-error owned "$r2"
t rehearsal-non-git-tree-before-box 0 "$(wc -l <"$P0LOG")"

# A missing host git gets its own preflight reason, before the source guard or
# any box operation can turn it into a misleading checkout error.
P0NOGITSHIM="$TMP/phase0-no-git-bin"
mkdir -p "$P0NOGITSHIM"
ln -s "$(command -v dirname)" "$P0NOGITSHIM/dirname"
ln -s "$P0SHIM/box" "$P0NOGITSHIM/box"
ln -s "$P0SHIM/gh" "$P0NOGITSHIM/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0NOGITSHIM/jq"
chmod +x "$P0NOGITSHIM/jq"
: >"$P0LOG"
if p0out="$(PATH="$P0NOGITSHIM" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  /usr/bin/bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-missing-git-rc 1 "$r1"
case "$p0out" in *"git not found on the host"*) r2=owned ;; *) r2=misattributed ;; esac
t rehearsal-missing-git-owned-error owned "$r2"
t rehearsal-missing-git-before-box 0 "$(wc -l <"$P0LOG")"

# Remote/ref acquisition already uses git clone, but must not inherit the
# --tree-only clean-status probe.
P0GSHIM="$TMP/phase0-git-bin"
P0GITLOG="$TMP/phase0-git.log"
REAL_GIT="$(command -v git)"
mkdir -p "$P0GSHIM"
# shellcheck disable=SC2016  # expanded by the shim at execution time
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$P0GITLOG"\ncase " $* " in\n  *" status "*)\n    if [ "${P0GIT_FAIL_STATUS:-0}" -eq 1 ]; then echo "fixture status failure" >&2; exit 42; fi\n    if [ "${P0GIT_WARN_STATUS:-0}" -eq 1 ]; then echo "fixture status warning" >&2; fi ;;\nesac\nexec "$REAL_GIT" "$@"\n' >"$P0GSHIM/git"
chmod +x "$P0GSHIM/git"

# A warning from a successful status is not a dirty path and must not make a
# clean checkout refuse. A failed status retains its stderr in crew's error.
: >"$P0GITLOG"
: >"$P0LOG"
if p0out="$(PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" P0GIT_WARN_STATUS=1 \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
case "$p0out" in *"has uncommitted changes"*) r2=refused ;; *) r2=passed-guard ;; esac
t rehearsal-status-warning-is-not-dirty passed-guard "$r2"
if grep -Eq '^(list|new) ' "$P0LOG"; then r2=reached-box; else r2=stopped-early; fi
t rehearsal-status-warning-reaches-box reached-box "$r2"

: >"$P0GITLOG"
: >"$P0LOG"
if p0out="$(PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" P0GIT_FAIL_STATUS=1 \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0TREE" --quick 2>&1)"; then r1=0; else r1=$?; fi
t rehearsal-status-failure-rc 1 "$r1"
case "$p0out" in *"could not inspect"*"fixture status failure"*) r2=owned ;; *) r2=missing ;; esac
t rehearsal-status-failure-owned-error owned "$r2"
t rehearsal-status-failure-before-box 0 "$(wc -l <"$P0LOG")"

P0REMOTE="$TMP/phase0-remote.git"
P0REF="$(git -C "$P0TREE" branch --show-current)"
git clone -q --bare "$P0TREE" "$P0REMOTE"
: >"$P0GITLOG"
: >"$P0LOG"
PATH="$P0GSHIM:$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  P0GITLOG="$P0GITLOG" REAL_GIT="$REAL_GIT" \
  bash "$ROOT/drill/rehearsal.sh" --remote "$P0REMOTE" \
    --ref "$P0REF" --quick >/dev/null 2>&1 || true
if grep -Eq '(^|[[:space:]])status([[:space:]]|$)' "$P0GITLOG"; then r2=probed; else r2=untouched; fi
t rehearsal-remote-skips-clean-tree-probe untouched "$r2"

BADTREE="$TMP/bad-tree"
mkdir -p "$BADTREE"
git -C "$BADTREE" init -q
printf 'not the engine\n' >"$BADTREE/README.md"
git -C "$BADTREE" add README.md
git -C "$BADTREE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
if p0out="$(PATH="$P0SHIM:$PATH" P0LOG="$P0LOG" P0HOME="$P0HOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$BADTREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t rehearsal-invalid-tree-rc 1 "$r1"
case "$p0out" in *"shared/install.sh"*"missing"*"aborted before checks"*) r1=attributed ;; *) r1=missing ;; esac
t rehearsal-invalid-tree-attributed attributed "$r1"

# The suite/reference extraction, archive selection and phase-0 verifier are
# one contract: each can drift independently, and empty inputs never cover it.
P0COVER_SUITE="$TMP/phase0-cover-suite.sh"
P0COVER_REHEARSAL="$TMP/phase0-cover-rehearsal.sh"
cp "$HERE/common.sh" "$P0COVER_SUITE"
cp "$ROOT/drill/rehearsal.sh" "$P0COVER_REHEARSAL"
# shellcheck disable=SC2016  # write a literal synthetic suite dependency
printf '%s%s\n' '$ROOT' '/postmortems' >>"$P0COVER_SUITE"
t phase0-new-suite-root-needs-verification missing:postmortems \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/common.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # write a literal brace-form suite dependency
printf '%s%s\n' '${ROOT}' '/postmortems/report.md' >>"$P0COVER_SUITE"
t phase0-braced-suite-root-needs-verification missing:postmortems \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/common.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # write a dependency beneath the excluded subtree
printf '%s%s\n' '$ROOT' '/fleet-floor/dev/assets.json' >>"$P0COVER_SUITE"
t phase0-excluded-suite-path-refused excluded:fleet-floor/dev \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/common.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # replace the block with the literal legacy command
sed -i '/BEGIN phase-0 archive selection/,/END phase-0 archive selection/c\
# BEGIN phase-0 archive selection\
tar czf "$ENGINE_ARCHIVE" -C "$SOURCE_TREE" shared VERSION\
# END phase-0 archive selection' "$P0COVER_REHEARSAL"
t phase0-legacy-archive-selection-refused archive:archive-selection-mismatch \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
: >"$P0COVER_SUITE"
t phase0-empty-suite-root-list-refused empty-suite-roots \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
: >"$P0COVER_REHEARSAL"
t phase0-empty-verified-root-list-refused empty-verified-roots \
  "$(phase0_coverage_result "$HERE/common.sh" "$P0COVER_REHEARSAL")"

# Exercise the in-box verifier, not just its static root list. The fixture is
# a valid clean git tree with one required root deliberately absent; phase 0
# must attribute that truncation before it can run the staged suite.
P0VERIFYTREE="$TMP/phase0-verify-tree"
P0VERIFYHOME="$TMP/phase0-verify-home"
P0VERIFYSHIM="$TMP/phase0-verify-bin"
mkdir -p "$P0VERIFYTREE"/{.ceremony,.github,cli,drill,fleet-floor,shared/test} \
  "$P0VERIFYHOME" "$P0VERIFYSHIM"
printf 'fixture\n' >"$P0VERIFYTREE/.ceremony/marker"
printf 'fixture\n' >"$P0VERIFYTREE/.github/marker"
printf '#!/usr/bin/env bash\nexit 1\n' >"$P0VERIFYTREE/cli/crew"
printf 'fixture\n' >"$P0VERIFYTREE/drill/marker"
printf 'fixture\n' >"$P0VERIFYTREE/fleet-floor/marker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0VERIFYTREE/install.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$P0VERIFYTREE/shared/install.sh"
printf '#!/usr/bin/env bash\nprintf "failed 0\\n"\n' >"$P0VERIFYTREE/shared/test/run.sh"
printf '0.0.0-test\n' >"$P0VERIFYTREE/VERSION"
chmod +x "$P0VERIFYTREE/cli/crew" "$P0VERIFYTREE/install.sh" \
  "$P0VERIFYTREE/shared/install.sh" "$P0VERIFYTREE/shared/test/run.sh"
git -C "$P0VERIFYTREE" init -q
git -C "$P0VERIFYTREE" add .
git -C "$P0VERIFYTREE" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm fixture
# shellcheck disable=SC2016  # the shim receives and executes rehearsal's script argument
printf '%s\n' '#!/usr/bin/env bash
case "$1" in
  list) printf "[]\n" ;;
  new) exit 0 ;;
  exec)
    shift 5
    HOME="$P0VERIFYHOME" bash -lc "$1" ;;
  *) exit 2 ;;
esac' >"$P0VERIFYSHIM/box"
chmod +x "$P0VERIFYSHIM/box"
if p0out="$(PATH="$P0VERIFYSHIM:$P0SHIM:$PATH" P0VERIFYHOME="$P0VERIFYHOME" \
  bash "$ROOT/drill/rehearsal.sh" --tree "$P0VERIFYTREE" --quick 2>&1)"; then
  r1=0
else
  r1=$?
fi
t phase0-truncated-tree-rc 1 "$r1"
case "$p0out" in *"transferred engine failed verification"*) r1=attributed ;; *) r1=missing ;; esac
t phase0-truncated-tree-attributed attributed "$r1"
case "$p0out" in *"fixture tests green"*) r1=ran-suite ;; *) r1=stopped-before-suite ;; esac
t phase0-truncated-tree-stops-before-suite stopped-before-suite "$r1"

# --- install-drill step 9: engine/cron/tick survival, both paths (#341) --
# The tick leg used to demand an unchanged, NON-EMPTY last duty.log line. A box
# hired seconds earlier has no duty.log at all — it is written at the first
# cron boundary — so on the drill's own standalone path the assertion failed by
# construction. Observed on crew-drill-011, 2026-08-03: the drill read an empty
# tail and redded, and the box's first tick fired 14s later, AFTER the console
# removal.
#
# These fixtures drive the predicate itself, not a host: a fake box home, the
# crontab shim above, and a clock the wait spends instead of the suite's wall
# time. As with the rehearsal-safety block above, the caller's bx() is what
# makes that possible; each block defines its own and nothing after either one
# calls it.
SHOME="$TMP/survival-home"
SDUTY="$SHOME/duty"
SCRON="$TMP/survival-crontab"
SURVIVAL_CLOCK=0
SURVIVAL_TICK_AT=""
SURVIVAL_RESTAMP_AT=""
SURVIVAL_DISARM_AT=""

# survival_reset <engine> <armed|disarmed> [last duty.log line]
# The third argument is the whole difference between the two paths: a borrowed
# box arrives with tick history, a freshly hired one does not.
survival_reset() {
  rm -rf "$SHOME"; mkdir -p "$SDUTY/bin"
  printf '%s\n' "$1" >"$SDUTY/VERSION"
  : >"$SCRON"
  if [ "$2" = armed ]; then
    printf '*/5 * * * * %s/bin/tick.sh\n17 2 * * * unrelated-job\n' "$SDUTY" >"$SCRON"
  fi
  [ -z "${3:-}" ] || printf '%s\n' "$3" >"$SDUTY/duty.log"
  SURVIVAL_CLOCK=0
  SURVIVAL_TICK_AT=""
  SURVIVAL_RESTAMP_AT=""
  SURVIVAL_DISARM_AT=""
}

bx() { HOME="$SHOME" PATH="$ISHIM" CRON_STATE="$SCRON" bash -c "$1"; }
# shellcheck source=drill/install-survival.sh
source "$ROOT/drill/install-survival.sh"
# The two seams, taken over: the clock only moves when the predicate sleeps, so
# the real 300+90s budget is exercised in no wall time at all — and the tick
# lands when the fixture's boundary strikes, the way a surviving engine's does.
# The two *_AT breakages are how a box is made to lose engine or cron INSIDE the
# wait window, which is the only place the second engine/cron read can see them.
install_survival_now() { printf '%s\n' "$SURVIVAL_CLOCK"; }
install_survival_sleep() {
  SURVIVAL_CLOCK=$((SURVIVAL_CLOCK + $1))
  if [ -n "$SURVIVAL_TICK_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_TICK_AT" ]; then
    printf 'tick %s duty run end\n' "$SURVIVAL_TICK_AT" >>"$SDUTY/duty.log"
  fi
  if [ -n "$SURVIVAL_RESTAMP_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_RESTAMP_AT" ]; then
    printf 'crew@9.9.9-someone-elses\n' >"$SDUTY/VERSION"
  fi
  if [ -n "$SURVIVAL_DISARM_AT" ] && [ "$SURVIVAL_CLOCK" -ge "$SURVIVAL_DISARM_AT" ]; then
    : >"$SCRON"
  fi
}
# Which surfaces the detail blames, as a list — the D2 assertion in one line.
survival_surfaces() {
  printf '%s' "$INSTALL_SURVIVAL_DETAIL" | tr ';' '\n' |
    sed 's/^ *//;s/:.*//' | tr '\n' ',' | sed 's/,$//'
}

# The budget is the box's own schedule, not a constant this file guesses at.
t survival-budget-reads-the-cron-period 150 "$(install_survival_budget '*/1 * * * * /h/duty/bin/tick.sh')"
t survival-budget-default-when-unparsable 390 "$(install_survival_budget '17 2 * * * /h/duty/bin/tick.sh')"
t survival-budget-default-when-cron-empty 390 "$(install_survival_budget '')"

# --- the fresh-box path: no duty.log before the removal
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
t survival-fresh-box-takes-the-wait-path fresh "$INSTALL_SURVIVAL_PATH"
t survival-fresh-box-label-describes-arrival "the box arrived with no duty.log" "$INSTALL_SURVIVAL_PATH_LABEL"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-passes-on-the-observed-tick survived "$r1"
t survival-fresh-box-reports-the-new-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"
[ "$SURVIVAL_CLOCK" -le 390 ] && r1=bounded || r1=OVERRAN
t survival-fresh-wait-stops-at-one-boundary-plus-grace bounded "$r1"

# The mutation #192's precedent requires: step 9's leg as it read before this
# fix — one read, no wait — against the same fixture that just passed.
SURVIVAL_WAIT="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_wait_for_tick() {
  INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"; [ -n "$INSTALL_SURVIVAL_TICK" ]
}
install_survival_check && r1=survived || r1=red
t survival-deleting-the-wait-reds-the-fresh-box red "$r1"
t survival-deleting-the-wait-still-names-tick tick "$(survival_surfaces)"
eval "$SURVIVAL_WAIT"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-restoring-the-wait-passes-the-same-fixture survived "$r1"

# A fresh box whose engine never ticks again is the failure this path exists to
# catch, and it must be reported as the tick — not as the removal transcript.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-fresh-box-with-no-tick-reds red "$r1"
t survival-fresh-box-with-no-tick-names-tick tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in *"duty.log"*"390s"*) r1=says-what-it-read ;; *) r1=OPAQUE ;; esac
t survival-fresh-box-with-no-tick-says-what-it-read says-what-it-read "$r1"
t survival-fresh-box-with-no-tick-waited-the-budget 390 "$SURVIVAL_CLOCK"

# --- a tick that lands DURING the uninstall proves nothing
# The wait measures against the log as the COMPLETED removal left it, not the
# empty read taken before it. A boundary striking while `crew uninstall` runs
# writes a line the console was still installed for; accepting it would pass
# step 9 at zero elapsed time on a box whose engine never ticked again.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
t survival-uninstall-tick-still-takes-the-wait-path fresh "$INSTALL_SURVIVAL_PATH"
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-tick-during-uninstall-alone-reds red "$r1"
t survival-tick-during-uninstall-names-tick tick "$(survival_surfaces)"
t survival-tick-during-uninstall-waits-the-budget 390 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"tick during uninstall"*"already there"*) r1=says-the-stale-line ;; *) r1=OPAQUE ;;
esac
t survival-tick-during-uninstall-says-the-stale-line says-the-stale-line "$r1"

# …and that same box passes the moment the engine ticks after the removal.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-tick-during-uninstall-then-a-real-tick-passes survived "$r1"
t survival-tick-during-uninstall-reports-the-later-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"

# The mutation the case exists for: the baseline-blind wait — first non-empty
# line wins — takes the during-uninstall line as its evidence and concludes in
# no time at all, which is the false pass this fixture must catch.
SURVIVAL_WAIT_PRE="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_wait_for_tick() {
  local budget="$1" deadline
  deadline=$(( $(install_survival_now) + budget ))
  while :; do
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    [ -z "$INSTALL_SURVIVAL_TICK" ] || return 0
    [ "$(install_survival_now)" -lt "$deadline" ] || return 1
    install_survival_sleep "$INSTALL_SURVIVAL_POLL"
  done
}
install_survival_check && r1=survived || r1=red
t survival-baseline-blind-wait-false-passes-the-uninstall-tick survived "$r1"
t survival-baseline-blind-wait-spends-nothing 0 "$SURVIVAL_CLOCK"
eval "$SURVIVAL_WAIT_PRE"
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
printf 'tick during uninstall duty run end\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-restoring-the-baseline-reds-the-same-fixture red "$r1"

# --- the wait window is not a blind spot
# Up to a whole cron period passes inside the wait, so engine and cron are read
# again on the other side of it: a box that loses either one in there did not
# outlive its console, and the detail names the read that saw it go.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
SURVIVAL_RESTAMP_AT=305
install_survival_check && r1=survived || r1=red
t survival-engine-restamped-inside-the-wait-reds red "$r1"
t survival-engine-restamped-inside-the-wait-names-engine engine "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"after the 390s tick wait"*) r1=says-which-read ;; *) r1=OPAQUE ;;
esac
t survival-engine-restamped-inside-the-wait-says-which-read says-which-read "$r1"

survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
SURVIVAL_DISARM_AT=305
install_survival_check && r1=survived || r1=red
t survival-cron-disarmed-inside-the-wait-reds red "$r1"
t survival-cron-disarmed-inside-the-wait-names-cron cron "$(survival_surfaces)"

# A surface that missed before the wait is reported once, at the read that saw
# it — the second pass must not double it into the detail.
survival_reset '' armed ''
install_survival_before
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-engine-gone-reds red "$r1"
t survival-fresh-box-engine-gone-reported-once engine "$(survival_surfaces)"

# --- the borrowed-box context: history, with the same post-removal wait
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
t survival-borrowed-box-records-history-context history "$INSTALL_SURVIVAL_PATH"
t survival-borrowed-box-label-describes-arrival "the box arrived with tick history" "$INSTALL_SURVIVAL_PATH_LABEL"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-newer-post-removal-line-passes survived "$r1"
t survival-borrowed-box-reports-the-new-tick "tick 305 duty run end" "$INSTALL_SURVIVAL_TICK"
[ "$SURVIVAL_CLOCK" -le 390 ] && r1=bounded || r1=OVERRAN
t survival-borrowed-wait-stops-at-one-boundary-plus-grace bounded "$r1"

# A borrowed box whose engine dies with its console spends the full budget and
# reds. This explicitly inverts the old borrowed-box pass on an unchanged log.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-unchanged-log-now-reds red "$r1"
t survival-borrowed-box-unchanged-log-names-tick tick "$(survival_surfaces)"
t survival-borrowed-box-unchanged-log-waits-the-budget 390 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"2026-08-03T15:14:01Z duty run end"*"box arrived with"*) r1=names-arrival-tick ;; *) r1=OPAQUE ;;
esac
t survival-borrowed-box-failure-retains-pre-removal-tick names-arrival-tick "$r1"

survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
rm -f "$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-borrowed-box-emptied-log-still-reds red "$r1"

# A tick written during uninstall is the post-removal baseline, not survival
# evidence. The borrowed context must exclude it exactly as the fresh one does.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-borrowed-tick-during-uninstall-alone-reds red "$r1"
t survival-borrowed-tick-during-uninstall-names-tick tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"2026-08-03T15:14:01Z duty run end"*"2026-08-03T15:19:01Z tick during uninstall"*) r1=says-both-lines ;; *) r1=OPAQUE ;;
esac
t survival-borrowed-tick-during-uninstall-says-both-lines says-both-lines "$r1"

# …and that same borrowed box passes once a later boundary proves survival.
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-borrowed-tick-during-uninstall-then-real-tick-passes survived "$r1"

# Restore the old byte-identical borrowed-path comparison. It reds the healthy
# fixture above as soon as it sees the uninstall-boundary line and never waits
# for the later proof. This is the reported flake's negative mutation.
SURVIVAL_WAIT_HISTORY="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
SURVIVAL_TICK_AT=305
install_survival_wait_for_tick() {
  INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
  [ -n "$INSTALL_SURVIVAL_TICK" ] && [ "$INSTALL_SURVIVAL_TICK" = "$INSTALL_SURVIVAL_TICK_PRE" ]
}
install_survival_check && r1=survived || r1=red
t survival-restoring-borrowed-byte-identical-compare-reds red "$r1"
eval "$SURVIVAL_WAIT_HISTORY"

# Pointing the wait at TICK_PRE instead of the post-removal read accepts the
# during-uninstall line at zero elapsed time. The correct baseline reds it.
SURVIVAL_WAIT_POST="$(declare -f install_survival_wait_for_tick)"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_wait_for_tick() {
  local budget="$1" deadline
  deadline=$(( $(install_survival_now) + budget ))
  while :; do
    INSTALL_SURVIVAL_TICK="$(install_survival_read_tick)"
    if [ -n "$INSTALL_SURVIVAL_TICK" ] && [ "$INSTALL_SURVIVAL_TICK" != "$INSTALL_SURVIVAL_TICK_PRE" ]; then
      return 0
    fi
    [ "$(install_survival_now)" -lt "$deadline" ] || return 1
    install_survival_sleep "$INSTALL_SURVIVAL_POLL"
  done
}
install_survival_check && r1=survived || r1=red
t survival-borrowed-pre-removal-baseline-false-passes survived "$r1"
t survival-borrowed-pre-removal-baseline-spends-nothing 0 "$SURVIVAL_CLOCK"
eval "$SURVIVAL_WAIT_POST"
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf '2026-08-03T15:19:01Z tick during uninstall\n' >>"$SDUTY/duty.log"
install_survival_check && r1=survived || r1=red
t survival-restoring-borrowed-post-removal-baseline-reds red "$r1"

# --- the real survival failures, on the surfaces they happened to
survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
: >"$SCRON"
install_survival_check && r1=survived || r1=red
t survival-cron-removed-by-hand-reds red "$r1"
t survival-cron-removed-by-hand-names-cron-first cron,tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in *"tick.sh"*) r1=says-what-it-read ;; *) r1=OPAQUE ;; esac
t survival-cron-removed-says-what-it-read says-what-it-read "$r1"
t survival-borrowed-box-cron-removed-does-not-wait 0 "$SURVIVAL_CLOCK"
case "$INSTALL_SURVIVAL_DETAIL" in *"tick: not waited for"*) r1=says-no-wait ;; *) r1=OPAQUE ;; esac
t survival-borrowed-box-cron-removed-says-no-wait says-no-wait "$r1"
case "$INSTALL_SURVIVAL_DETAIL" in *"2026-08-03T15:14:01Z duty run end"*) r1=names-arrival-tick ;; *) r1=OPAQUE ;; esac
t survival-borrowed-box-cron-removed-retains-pre-removal-tick names-arrival-tick "$r1"

# The same removal on a fresh box: no boundary can strike, so the wait is not
# entered at all and the report says so rather than blaming the tick alone.
survival_reset 'crew@0.0.0-drill-b' armed ''
install_survival_before
: >"$SCRON"
SURVIVAL_TICK_AT=305
install_survival_check && r1=survived || r1=red
t survival-fresh-box-cron-removed-reds red "$r1"
t survival-fresh-box-cron-removed-names-cron-first cron,tick "$(survival_surfaces)"
t survival-fresh-box-cron-removed-does-not-wait 0 "$SURVIVAL_CLOCK"

survival_reset 'crew@0.0.0-drill-b' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
printf 'crew@9.9.9-someone-elses\n' >"$SDUTY/VERSION"
install_survival_check && r1=survived || r1=red
t survival-engine-restamped-reds red "$r1"
t survival-engine-restamped-names-engine-first engine,tick "$(survival_surfaces)"
case "$INSTALL_SURVIVAL_DETAIL" in
  *"crew@9.9.9-someone-elses"*"crew@0.0.0-drill-b"*) r1=says-both ;; *) r1=OPAQUE ;;
esac
t survival-engine-restamped-says-read-and-expected says-both "$r1"

survival_reset '' armed '2026-08-03T15:14:01Z duty run end'
install_survival_before
install_survival_check && r1=survived || r1=red
t survival-engine-gone-reds red "$r1"
t survival-engine-gone-names-engine-first engine,tick "$(survival_surfaces)"

# The driver reads the predicate from here and reports the surfaces, so the
# transcript that misled #341 cannot come back as the evidence.
if grep -qF 'install_survival_before' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'install_survival_check' "$ROOT/drill/install-drill.sh"; then r1=wired; else r1=MISSING; fi
t survival-driver-uses-the-shared-predicate wired "$r1"
# shellcheck disable=SC2016  # the driver's literal line is the pattern
if grep -qF '($INSTALL_SURVIVAL_PATH_LABEL)' "$ROOT/drill/install-drill.sh"; then r1=context; else r1=LOST; fi
t survival-driver-pass-line-keeps-arrival-context context "$r1"
# shellcheck disable=SC2016  # the driver's literal line is the pattern
if grep -qF 'fail "step 9: positive engine/cron/tick survival observation" "$INSTALL_SURVIVAL_DETAIL"' \
     "$ROOT/drill/install-drill.sh"; then r1=surfaces; else r1=TRANSCRIPT; fi
t survival-driver-fails-with-the-surfaces surfaces "$r1"
if grep -qE 'tick_(pre_remove|after)' "$ROOT/drill/install-drill.sh"; then r1=INLINE; else r1=extracted; fi
t survival-driver-keeps-no-inline-copy extracted "$r1"

# --- drill/install-payload.sh: #365's payload rule, per channel (#421) ----
# Same shape as the survival block above: the predicate is driven against
# fixtures rather than a host — a stub installer, stub guards, and installed
# trees built by hand. No bx() is needed at all here, because the thing under
# assertion is an ordinary directory: install-drill.sh's installs are
# host-side, into its own scratch CREW_HOME.
#
# One convention departs from the rest of this file: every hyphenated verdict
# word assigned below is QUOTED. shellcheck reads `r2=a-b` as arithmetic
# (SC2100) once it has seen `a` as a variable name, and under -x it keeps the
# names of every file this one sources — so whether a bare word here parses
# depends on a declaration in some other file. `roots-still-green` was armed by
# this block's own `local roots`; `first-upgrade-artifact` was armed from
# outside the branch entirely, when #432 landed a `first=` in
# drill/rehearsal-resume.sh, which line 324 sources. ci-shell runs shellcheck
# unfiltered, so an info-level finding is a red build. Quoting says "literal"
# and cannot be armed by a name this file never mentions.
PHOME="$TMP/payload"

# payload_src <declared roots, space separated> <bound in guard A> <bound in B>
# A stub source tree: the installer's list and the two offline guards that
# spell the size bound, in the shape install-payload.sh reads them.
payload_src() {
  local roots p; read -ra roots <<<"$1"
  rm -rf "$PHOME/src"; mkdir -p "$PHOME/src/shared/test"
  { printf 'PAYLOAD_EXCLUDED_PATHS=(\n'
    for p in "${roots[@]}"; do [ -z "$p" ] || printf '  %s  # a reason\n' "$p"; done
    printf ')\n'
  } >"$PHOME/src/install.sh"
  # shellcheck disable=SC2016  # `$kb` is the guard's literal text
  [ "$2" = - ] || printf 'if [ "$kb" -lt %s ]; then\n' "$2" >"$PHOME/src/shared/test/install-lifecycle.sh"
  [ "$2" = - ] && : >"$PHOME/src/shared/test/install-lifecycle.sh"
  # shellcheck disable=SC2016  # same
  [ "$3" = - ] || printf 'if [ "$kb" -lt %s ]; then\n' "$3" >"$PHOME/src/shared/test/artifact.sh"
  [ "$3" = - ] && : >"$PHOME/src/shared/test/artifact.sh"
  return 0
}

# payload_tree <name> <root to plant, or -> <filler KiB> → echoes the path
payload_tree() {
  local dir="$PHOME/trees/$1"
  rm -rf "$dir"; mkdir -p "$dir/cli"
  [ "$2" = - ] || mkdir -p "$dir/$2"
  head -c "$(( $3 * 1024 ))" /dev/zero >"$dir/filler"
  printf '%s\n' "$dir"
}

# The predicate's own report, captured. A subshell supplies the pass()/fail()
# the caller owes it, so neither name escapes into the suite around it.
payload_run() {  # <source tree> <installed tree>
  ( pass() { printf 'PASS %s\n' "$1"; }
    fail() { printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
    # shellcheck source=drill/install-payload.sh
    . "$ROOT/drill/install-payload.sh"
    install_payload_assert payload "$1" "$2" )
}
payload_verdict() { case "$1" in *FAIL*) printf 'red\n' ;; *) printf 'green\n' ;; esac; }

CLEAN_ROOTS='.git drill shared/test fleet-floor/dev fleet-floor/test'

# A tree that ships none of them, well under the bound.
#
# The expectation for the reported size is `du -skL`'s own reading of this
# tree, never a hard-coded window: du charges directory inodes per filesystem,
# so the two directories below cost 0 blocks on the tmpfs a box's $TMP usually
# is and 4 KiB each on a runner's ext4 — 64 KiB here and 72 KiB there, for the
# same fixture. A band is green on one and red on the other for a reason that
# is not the predicate's. Equality against du is also the stronger assertion:
# it pins the line to the measurement rather than to a range a constant could
# sit in, and payload-two-trees-report-different-sizes below closes the last
# way a constant could still satisfy it.
payload_src "$CLEAN_ROOTS" 3072 3072
payload_dir="$(payload_tree clean - 64)"
payload_kb="$(du -skL "$payload_dir" | cut -f1)"
r1="$(payload_run "$PHOME/src" "$payload_dir")"
t payload-clean-tree-passes green "$(payload_verdict "$r1")"
case "$r1" in *"is $payload_kb KiB, within the 3072 KiB bound"*) r2=measured ;; *) r2="$r1" ;; esac
t payload-pass-line-carries-the-measured-size measured "$r2"
case "$r1" in *"none of the installer's 5 excluded roots"*) r2=counted ;; *) r2="$r1" ;; esac
t payload-pass-line-counts-the-roots-it-walked counted "$r2"

# MUST FAIL: a tree carrying fleet-floor/dev reds, NAMING that path — and it is
# not a size finding, so the size assertion beside it still passes. A leg that
# only redded on the bound would report "over budget" and leave the operator to
# work out which root came back.
r1="$(payload_run "$PHOME/src" "$(payload_tree fat-dev fleet-floor/dev 64)")"
t payload-dev-root-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: fleet-floor/dev"*) r2=named ;; *) r2="$r1" ;; esac
t payload-dev-root-names-the-path named "$r2"
case "$r1" in *"PASS payload: installed tree is"*) r2='size-still-green' ;; *) r2="$r1" ;; esac
t payload-dev-root-is-not-a-size-finding size-still-green "$r2"

# MUST FAIL: under the bound and still carrying a test root. This is the case a
# size-only check passes.
r1="$(payload_run "$PHOME/src" "$(payload_tree small-test shared/test 64)")"
t payload-test-root-under-budget-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: shared/test"*) r2=named ;; *) r2="$r1" ;; esac
t payload-test-root-under-budget-names-the-path named "$r2"

# …and the mirror: no excluded root anywhere, and fat. The bound is the only
# thing that catches the next big directory nobody thought to exclude.
payload_fat_dir="$(payload_tree fat-clean - 4096)"
payload_fat_kb="$(du -skL "$payload_fat_dir" | cut -f1)"
r1="$(payload_run "$PHOME/src" "$payload_fat_dir")"
t payload-over-bound-reds red "$(payload_verdict "$r1")"
case "$r1" in *"within the 3072 KiB bound — measured $payload_fat_kb KiB"*) r2='says-both' ;; *) r2="$r1" ;; esac
t payload-over-bound-names-bound-and-measurement says-both "$r2"
# Two trees, two different readings: whatever the filesystem charges for the
# directories, a 4096 KiB tree cannot measure the same as a 64 KiB one. This is
# what stops a predicate that printed a constant from satisfying both cases
# above, which is the force the removed band was carrying.
if [ "$payload_fat_kb" -gt "$payload_kb" ]; then r2=differ; else r2="$payload_kb vs $payload_fat_kb"; fi
t payload-two-trees-report-different-sizes differ "$r2"

# MUST FAIL: a DANGLING SYMLINK at an excluded root (#431 round 2, codex). One
# planted link used to produce two PASS lines on the tree that most needs a
# finding: `-e` is false for it, so the root walk did not see it, and `du -skL`
# then could not walk the tree — exiting non-zero and printing a partial total
# of 0, which is under any bound. Both halves are asserted here, because either
# one alone still lets a fat `fleet-floor/dev` arrive behind a broken link.
payload_dangling_dir="$(payload_tree dangling-root - 64)"
mkdir -p "$payload_dangling_dir/fleet-floor"
ln -s missing-target "$payload_dangling_dir/fleet-floor/dev"
r1="$(payload_run "$PHOME/src" "$payload_dangling_dir")"
t payload-dangling-excluded-root-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: fleet-floor/dev"*) r2=named ;; *) r2="$r1" ;; esac
t payload-dangling-excluded-root-names-the-path named "$r2"
# The exact false green, pinned out by its own text: a failed measurement must
# never be reported as a small tree.
case "$r1" in
  *"is 0 KiB, within"*) r2='FALSE-GREEN' ;;
  *"size measured"*)    r2='measurement-red' ;;
  *)                    r2="$r1" ;;
esac
t payload-dangling-root-is-not-a-zero-kib-pass measurement-red "$r2"

# MUST FAIL: the measurement guard STANDS ALONE. A dangling symlink at a path
# that is not an excluded root leaves the root walk correctly green, so the
# only thing that can red this tree is du's own status — which is the proof
# that the size assertion is not being carried by the root finding beside it.
payload_unmeasurable_dir="$(payload_tree unmeasurable - 64)"
ln -s missing-target "$payload_unmeasurable_dir/cli/orphan"
r1="$(payload_run "$PHOME/src" "$payload_unmeasurable_dir")"
t payload-unmeasurable-tree-reds red "$(payload_verdict "$r1")"
case "$r1" in *"PASS payload: installed tree carries none"*) r2='roots-still-green' ;; *) r2="$r1" ;; esac
t payload-unmeasurable-tree-is-not-a-root-finding roots-still-green "$r2"
# and it reports du's own status and words, not a bound verdict: "could not
# measure" and "too big" are different facts for whoever reads the drill record.
case "$r1" in *"size measured — du -skL exited 1"*) r2='says-du' ;; *) r2="$r1" ;; esac
t payload-unmeasurable-tree-carries-dus-own-status says-du "$r2"
case "$r1" in *"within the 3072 KiB bound"*) r2='BOUND-VERDICT' ;; *) r2='not-a-bound-verdict' ;; esac
t payload-unmeasurable-tree-is-not-a-bound-finding not-a-bound-verdict "$r2"

# MUST FAIL: a fat artifact tree reds where the checkout tree is clean. The
# channels are asserted separately for exactly this reason — one verdict per
# installed tree, never one inferred from another.
r1="$(payload_run "$PHOME/src" "$(payload_tree channel-checkout - 64)")"
r2="$(payload_run "$PHOME/src" "$(payload_tree channel-artifact fleet-floor/dev 4096)")"
t payload-per-channel-verdicts-are-independent "green red" \
  "$(payload_verdict "$r1") $(payload_verdict "$r2")"

# THE MUTATION THAT DELETES ITS OWN CHECK. Reverting #365 takes fleet-floor/dev
# out of PAYLOAD_EXCLUDED_PATHS, so a walk over only what the installer still
# names would go green on the very regression this leg exists for. The sentinel
# is unioned in, so the tree is still walked against it — and the installer
# having dropped it is a separate finding, not a silence.
payload_src '.git drill shared/test fleet-floor/test' 3072 3072
r1="$(payload_run "$PHOME/src" "$(payload_tree reverted fleet-floor/dev 4096)")"
t payload-reverted-exclusion-still-reds red "$(payload_verdict "$r1")"
case "$r1" in *"still shipped: fleet-floor/dev"*) r2=named ;; *) r2="$r1" ;; esac
t payload-reverted-exclusion-still-names-the-root named "$r2"
# shellcheck source=drill/install-payload.sh
. "$ROOT/drill/install-payload.sh"
install_payload_installer_names_sentinel "$PHOME/src" && r1=named || r1=dropped
t payload-reverted-exclusion-reported-against-the-source dropped "$r1"
payload_src "$CLEAN_ROOTS" 3072 3072
install_payload_installer_names_sentinel "$PHOME/src" && r1=named || r1=dropped
t payload-declared-sentinel-is-reported-named named "$r1"

# The bound is READ, and reading it doubles as a drift check between the two
# guards that both spell it: disagreement is a defect this drill will not pick
# a winner for.
t payload-bound-read-from-the-guards 3072 "$(install_payload_budget_kb "$PHOME/src")"
payload_src "$CLEAN_ROOTS" 3072 4096
r1="$(payload_run "$PHOME/src" "$(payload_tree disagree - 64)")"
t payload-guards-disagreeing-on-the-bound-reds red "$(payload_verdict "$r1")"
case "$r1" in *"disagree on the size bound"*) r2='says-so' ;; *) r2="$r1" ;; esac
t payload-guards-disagreeing-says-so says-so "$r2"
payload_src "$CLEAN_ROOTS" - -
r1="$(payload_run "$PHOME/src" "$(payload_tree nobound - 64)")"
t payload-no-bound-in-the-guards-reds red "$(payload_verdict "$r1")"
case "$r1" in *"no installed-tree size bound"*) r2='says-so' ;; *) r2="$r1" ;; esac
t payload-no-bound-says-so says-so "$r2"
payload_src "$CLEAN_ROOTS" 3072 3072
rm -f "$PHOME/src/shared/test/artifact.sh"
r1="$(payload_run "$PHOME/src" "$(payload_tree noguard - 64)")"
case "$r1" in *"artifact.sh is missing"*) r2='names-the-guard' ;; *) r2="$r1" ;; esac
t payload-missing-guard-names-it names-the-guard "$r2"

# An installer whose list stopped parsing is a red, never an empty walk.
payload_src '' 3072 3072
r1="$(payload_run "$PHOME/src" "$(payload_tree noparse - 64)")"
t payload-unparsable-exclusion-list-reds red "$(payload_verdict "$r1")"
case "$r1" in *"did not parse"*) r2='says-so' ;; *) r2="$r1" ;; esac
t payload-unparsable-exclusion-list-says-so says-so "$r2"
# …and a tree that is not there is its own finding, reached only once the two
# reads above have succeeded — which is why the source is restored first.
payload_src "$CLEAN_ROOTS" 3072 3072
r1="$(payload_run "$PHOME/src" "$PHOME/trees/does-not-exist")"
case "$r1" in *"nothing at"*) r2='says-so' ;; *) r2="$r1" ;; esac
t payload-absent-installed-tree-says-so says-so "$r2"

# The rule the shipped tree actually carries, read through the same predicate
# the drill uses — so a guard reworded past the read reds here and not on a
# release night.
PAYLOAD_SHIPPED_BOUND="$(install_payload_budget_kb "$ROOT")"
case "$PAYLOAD_SHIPPED_BOUND" in [1-9]*) r1=numeric ;; *) r1="$PAYLOAD_SHIPPED_BOUND" ;; esac
t payload-shipped-bound-is-readable numeric "$r1"
payload_excluded_roots="$(install_payload_excluded_roots "$ROOT")"
grep -qx 'shared/test' <<<"$payload_excluded_roots" && r1=walked || r1=MISSING
t payload-shipped-list-names-the-test-root walked "$r1"
install_payload_installer_names_sentinel "$ROOT" && r1=named || r1=dropped
t payload-shipped-installer-excludes-the-sentinel named "$r1"

# CRITERION: no size constant is spelled in drill/. Asserted against the bound
# as read, so it keeps holding after the number moves.
if grep -rqF "$PAYLOAD_SHIPPED_BOUND" "$ROOT/drill/"; then r1=SPELLED; else r1='read-not-typed'; fi
t payload-drill-spells-no-size-constant read-not-typed "$r1"

# The driver reads the predicate from here, at all three installed trees.
# shellcheck disable=SC2016  # the driver's literal lines are the patterns
if grep -qF '. "$ROOT/drill/install-payload.sh"' "$ROOT/drill/install-drill.sh"; then
  r1=sourced; else r1=MISSING; fi
t payload-driver-sources-the-shared-predicate sourced "$r1"
r1="$(grep -c 'install_payload_assert ' "$ROOT/drill/install-drill.sh")"
t payload-driver-asserts-three-installed-trees 3 "$r1"
# shellcheck disable=SC2016  # same
if grep -qF 'versions/$VA' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'CREW_HOME/current' "$ROOT/drill/install-drill.sh" &&
   grep -qF 'ARTIFACT_HOME/share/current' "$ROOT/drill/install-drill.sh"; then
  r1='first-upgrade-artifact'; else r1=INCOMPLETE; fi
t payload-driver-covers-first-upgrade-and-artifact first-upgrade-artifact "$r1"

# --- validate_sha
validate_sha "0123456789abcdef0123456789abcdef01234567" && r1=ok || r1=bad
validate_sha "0123456" && r2=ok || r2=bad
validate_sha "g123456789abcdef0123456789abcdef01234567" && r3=ok || r3=bad
t sha-full ok "$r1"
t sha-short bad "$r2"
t sha-nonhex bad "$r3"

# --- blockers.jq: corpus-shaped fixtures --------------------------------
BJQ="$SHARED/lib/jq/blockers.jq"
S='{"5":"CLOSED","6":"MERGED","10":"CLOSED","7":"OPEN"}'

# The canonical body shape from the triage contract, all blockers landed —
# including one inside the clause's parentheses; "Blocks #13" is the inverse
# relation and must not parse.
b1='[{"number":21,"body":"Part of #1. Blocked by #5, #6 (and #10 for the bootstrap). Blocks #13 (needs a tag)."}]'
t blockers-landed "21" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b1")"

# One blocker still open → stays blocked.
b2='[{"number":22,"body":"Blocked by #5 and #7."}]'
t blockers-open "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b2")"

# Unknown number → fail-safe: counts as still-open.
b3='[{"number":23,"body":"Blocked by #999."}]'
t blockers-unknown "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b3")"

# Cross-repo blocker must NOT resolve against the local number map — triage
# flips those by hand (TRIAGE.md). #5 is CLOSED locally, but this "#5" is
# other-org/other-repo#5.
b4='[{"number":24,"body":"Blocked by other-org/other-repo#5."}]'
t blockers-crossrepo "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b4")"

# Lowercase clause, sentence-final stop honored: #7 after the period is not
# part of the clause.
b5='[{"number":25,"body":"blocked by #5. Also mentions #7 later."}]'
t blockers-lowercase "25" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b5")"

# No clause at all → no lead.
b6='[{"number":26,"body":"Depends on vibes."},{"number":27,"body":null}]'
t blockers-none "" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b6")"

# Two issues, one unblockable → only that one reported.
b7='[{"number":28,"body":"Blocked by #5."},{"number":29,"body":"Blocked by #7."}]'
t blockers-mixed "28" "$(jq -r --argjson S "$S" -f "$BJQ" <<<"$b7")"

# --- converged.jq: handoff predicate ------------------------------------
CJQ="$SHARED/lib/jq/converged.jq"
PANEL='["rev-a","rev-b"]'
mk_pr() {  # head mergeable labels requests reviews
  jq -n --arg head "$1" --arg m "$2" --argjson labels "$3" --argjson reqs "$4" --argjson revs "$5" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head, mergeable:$m,
      labels:{nodes:($labels|map({name:.}))},
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$revs}}}}}'
}
H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CJ_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REVS_OK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
REVS_STALE='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$CJ_OLD'"}}]'
# The maintainer (#452). Off-panel by construction — that is the whole reason
# the human's verdict needed its own term here — and the ONE off-panel identity
# this predicate reads.
CJ_HUMAN="danmt"
# The clock D1's ordering is read against, #286's rule applied to the human's
# verdict: CJ_T_BLOCK is when the block landed, CJ_T_SIG_NEW a signal that
# ANSWERS it, CJ_T_SIG_OLD one that merely PREDATES it.
CJ_T_SIG_OLD="2026-08-11T09:00:00Z"
CJ_T_BLOCK="2026-08-11T10:00:00Z"
CJ_T_SIG_NEW="2026-08-11T11:00:00Z"
# No signal posted — the shape answered-head.jq returns when the session has
# never declared a round answered on this PR, and the default here because most
# of these fixtures are indifferent to it.
CJ_NO_SIG='{"sha":"","createdAt":""}'
cj() {  # cj [signal-json] [panel-json] [human]
  jq -r --argjson panel "${2:-$PANEL}" --arg needs_human state:needs-human \
    --arg human "${3-$CJ_HUMAN}" --argjson signal "${1:-$CJ_NO_SIG}" -f "$CJQ"
}

t converged-true true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_OK" | cj)"
t converged-outstanding-req false \
  "$(mk_pr "$H" MERGEABLE '[]' '["rev-b"]' "$REVS_OK" | cj)"
t converged-offpanel-req-ignored true \
  "$(mk_pr "$H" MERGEABLE '[]' '["danmt"]' "$REVS_OK" | cj)"
t converged-stale-approval false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_STALE" | cj)"
t converged-already-handed false \
  "$(mk_pr "$H" MERGEABLE '["state:needs-human"]' '[]' "$REVS_OK" | cj)"
t converged-unknown-mergeable defer-unknown \
  "$(mk_pr "$H" UNKNOWN '[]' '[]' "$REVS_OK" | cj)"
t converged-conflicting false \
  "$(mk_pr "$H" CONFLICTING '[]' '[]' "$REVS_OK" | cj)"
# An empty panel must never converge vacuously (bare panel= line).
t converged-empty-panel false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' '[]' | cj '' '[]')"

# --- #452: the HUMAN's own verdict disqualifies convergence -------------------
# BUILDER.md's Handoff ends "address what comes back and re-hand-off the same
# way", and this predicate is what made that impossible: every wake is scoped to
# $panel and the maintainer is off-panel, so a human CHANGES_REQUESTED left this
# true — the panel still approved the head, and a review does not move
# mergeable. The reconciler took state:needs-human off, the next tick refired
# the handoff, re-requested the human and re-set the label, and the reconciler's
# human-request clause made it stick. The PR bounced back at the human carrying
# a fresh nag and the change request never reached the builder.
CJ_BLOCK_AT_HEAD='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"'$CJ_HUMAN'"},"state":"CHANGES_REQUESTED","submittedAt":"'$CJ_T_BLOCK'","commit":{"oid":"'$H'"}}]'
CJ_BLOCK_SUPERSEDED='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"'$CJ_HUMAN'"},"state":"CHANGES_REQUESTED","submittedAt":"'$CJ_T_BLOCK'","commit":{"oid":"'$CJ_OLD'"}}]'
CJ_HUMAN_APPROVED='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"'$CJ_HUMAN'"},"state":"APPROVED","submittedAt":"'$CJ_T_BLOCK'","commit":{"oid":"'$H'"}}]'
cj_sig() { jq -cn --arg sha "$1" --arg at "$2" '{sha:$sha,createdAt:$at}'; }

# The headline: a standing human block at the head, never answered.
t converged-human-block-at-head false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj)"
# D1's SPEND, and the reason the disqualifier is not simply permanent: an answer
# with argument moves no head, so request-panel.jq finds nobody to re-request —
# the panel already approves this tree — and only the handoff can put the PR back
# in front of the human. A signal at this head, posted after the block, converges.
t converged-human-block-answered true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj "$(cj_sig "$H" "$CJ_T_SIG_NEW")")"
# MUST-FAIL, the #286 ordering: a signal that PREDATES the block did not answer
# it. Reading the sha alone — the licence before #286 gave it a createdAt — would
# let one signal posted before the human ever reviewed cancel every later block.
t converged-human-block-stale-signal false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj "$(cj_sig "$H" "$CJ_T_SIG_OLD")")"
# An equal-second tie holds, exactly as it does in request-panel.jq: fail-closed
# costs one tick and the next signal clears it.
t converged-human-block-tied-signal false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj "$(cj_sig "$H" "$CJ_T_BLOCK")")"
# A signal for some OTHER head is not a signal at this one, however new it is.
t converged-human-block-signal-other-head false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj "$(cj_sig "$CJ_OLD" "$CJ_T_SIG_NEW")")"
# MUST-FAIL, D1's HEAD SCOPING. The block sits at a superseded head and the panel
# approves the current one — the builder pushed the fix. This MUST converge: the
# handoff is the only thing that re-requests the human, so an any-head
# disqualifier would stop the very act that clears it. Deadlock, not caution.
t converged-human-block-superseded-head true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_SUPERSEDED" | cj)"
# The human approving changes nothing — only CHANGES_REQUESTED closes a round.
t converged-human-approved true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_HUMAN_APPROVED" | cj)"
# MUST-FAIL, D3: $human ALONE, never "not in $panel". An advisory off-panel
# reviewer stays advisory (BUILDER.md) and triage does not vote on PRs. Keying on
# panel membership passes every other case here and blocks every handoff on the
# board the first time anyone off-panel leaves a verdict.
CJ_ADVISORY_BLOCK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"dan-claude-bot"},"state":"CHANGES_REQUESTED","submittedAt":"'$CJ_T_BLOCK'","commit":{"oid":"'$H'"}}]'
t converged-advisory-block-ignored true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_ADVISORY_BLOCK" | cj)"
# An empty $human matches nobody: what a caller that is not asking about a round
# passes, and the guard that keeps a fleet with no FLEET_HUMAN configured from
# matching a review whose author.login the API returned as null.
t converged-empty-human-arg-ignores-block true \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_AT_HEAD" | cj '' '' '')"
# A block with NO submittedAt holds, the same fail-closed direction: an absent
# timestamp cannot prove the signal answered it.
CJ_BLOCK_UNTIMED="$(printf '%s' "$CJ_BLOCK_AT_HEAD" | jq -c 'map(del(.submittedAt))')"
t converged-human-block-untimed-holds false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' "$CJ_BLOCK_UNTIMED" | cj "$(cj_sig "$H" "$CJ_T_SIG_NEW")")"

# --- addressing.jq: round-close predicate, the MIRROR of converged.jq (#130) --
# Same payload builder (mk_pr), same panel, same head-scoping — the point is
# that the two predicates agree on every input and differ only in the
# conclusion. Reuses H / REVS_OK from the converged block above.
AJQ="$SHARED/lib/jq/addressing.jq"
OLDH="cccccccccccccccccccccccccccccccccccccccc"
# A closed round without full approval: rev-a requests changes AT the head,
# rev-b approves AT the head. Every panelist opinionated, one is not an approval.
REVS_ADDR='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
# The ceremony#136 mixed round: one approval staled by a push (rev-a at an OLD
# head), the other panelist yet to review at all. NOT closed — still awaiting.
REVS_MIXED_OPEN='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$OLDH'"}}]'
addr() { jq -r --argjson panel "$PANEL" --arg addressing state:addressing -f "$AJQ"; }

# The core: a landed non-approving verdict with the whole panel opinionated at
# the head → state:addressing. This is the exact inverse of converged-true.
t addressing-closed-without-approval true "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_ADDR" | addr)"
# All approved at head → converged, NOT addressing (the two never both fire).
t addressing-all-approved-is-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_OK" | addr)"
# The #136 mixed round: a stale approval + an unreviewed panelist is a round
# still OPEN (bots-reviewing), not a closed one — addressing must not fire.
t addressing-mixed-open-round-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_MIXED_OPEN" | addr)"
# A stale approval + a head change-request (rev-a CR@head, rev-b approved OLD
# head) is not all-reviewed-at-head → not closed yet.
REVS_ADDR_STALE='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$OLDH'"}}]'
t addressing-not-all-at-head-false false "$(mk_pr "$H" MERGEABLE '[]' '[]' "$REVS_ADDR_STALE" | addr)"
# Idempotent: the label already stands → writes nothing (re-tick no-op).
t addressing-already-set-false false "$(mk_pr "$H" MERGEABLE '["state:addressing"]' '[]' "$REVS_ADDR" | addr)"
# A live panel request means the round is still open — do not stamp addressing
# over a head that was just (re-)requested; the reconciler would flip it back.
t addressing-live-request-false false "$(mk_pr "$H" MERGEABLE '[]' '["rev-a"]' "$REVS_ADDR" | addr)"
# An empty panel never closes a round vacuously (mirror of converged-empty-panel).
t addressing-empty-panel-false false \
  "$(mk_pr "$H" MERGEABLE '[]' '[]' '[]' | jq -r --argjson panel '[]' --arg addressing state:addressing -f "$AJQ")"
# Mergeability is irrelevant to addressing: a conflicting PR can still owe a fix.
t addressing-conflicting-still-addresses true "$(mk_pr "$H" CONFLICTING '[]' '[]' "$REVS_ADDR" | addr)"

# --- #130 must-fail guards (the issue's test plan, addressing-scoped) ---------
# The engine write is optimistic, the reconciler authoritative: nothing in the
# addressing path may gate a verdict or write a state it does not own.
# state:addressing must never be written before the verdict lands, and the write
# is best-effort — the marker is the `|| warn` trailing the add-label.
if grep -q '_mark_addressing' "$SHARED/lib/duty-review.sh"; then r1=wired; else r1=MISSING; fi
t addressing-wired-after-verdict wired "$r1"
# shellcheck disable=SC2016  # the grep literal contains $LABEL_ADDRESSING on purpose
if grep -q 'could not set \$LABEL_ADDRESSING' "$SHARED/lib/duty-review.sh"; then r1='best-effort'; else r1=GATING; fi
t addressing-write-is-best-effort best-effort "$r1"
# The addressing writer never touches state:building (out of scope) or
# state:needs-human (the handoff's, not the reviewer's).
if grep -RIn 'state:building' "$SHARED/lib/duty-review.sh" >/dev/null 2>&1; then r1=WRITES-IT; else r1=absent; fi
t addressing-never-writes-state-building absent "$r1"
# The predicate keys approvals/reviews on the head, same as converged.jq — a
# stale verdict at an old head is not a closed round.
# shellcheck disable=SC2016,SC2100  # jq literal; r1 is a string result here
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/addressing.jq"; then r1=head-keyed; else r1=CHANGED; fi
t addressing-keys-on-head head-keyed "$r1"
# --- round-log.jq: mirror each whole round into the PR body (#91) ------------
# Input is the GraphQL pullRequest payload; output is the NEW body when a round
# is un-recorded, or "" when every round is already marked (the crash-retry
# no-op). A round is a head SHA with an opinionated verdict; its reply is the
# author's comments after that round's newest verdict and before the next
# round's first. Each entry is keyed `<!-- round:<sha> -->` for idempotency.
RLJQ="$SHARED/lib/jq/round-log.jq"
RL_ME="me-bot"
RL_O1="1111111111111111111111111111111111111111"
RL_O2="2222222222222222222222222222222222222222"
mk_rl() {  # <body> <reviews-json> <comments-json> [commits-json] [head-oid-json]
  jq -n --arg body "$1" --argjson reviews "$2" --argjson comments "$3" \
    --argjson commits "${4:-[]}" --argjson head "${5:-null}" \
    '{data:{repository:{pullRequest:{
      body:$body, headRefOid:$head, commits:{nodes:$commits},
      reviews:{nodes:$reviews}, comments:{nodes:$comments}}}}}'
}
RL_REVS="$(printf '[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T01:00:00Z"},{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T03:00:00Z"}]' "$RL_O1" "$RL_O2")"
RL_REVS1="$(printf '[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T01:00:00Z"}]' "$RL_O1")"
RL_COMS='[{"author":{"login":"me-bot"},"body":"answering round one","createdAt":"2026-01-01T02:00:00Z"},{"author":{"login":"me-bot"},"body":"answering round two","createdAt":"2026-01-01T04:00:00Z"}]'
# rl = handoff/record-all mode ($final=true): finalize every round including the
# live last one — the record-all semantics these fixtures assert. rl_live =
# per-tick mode ($final=false): defer the live round, record only superseded ones.
rl() { jq -r --arg me "$RL_ME" --argjson final true -f "$RLJQ"; }
rl_live() { jq -r --arg me "$RL_ME" --argjson final false -f "$RLJQ"; }

# Two rounds, both answered, no markers in body → both mirrored, oldest first.
RL_OUT="$(mk_rl "Body preamble." "$RL_REVS" "$RL_COMS" | rl)"
case "$RL_OUT" in *"## Round log"*) r1=yes ;; *) r1=no ;; esac
t roundlog-appends-section yes "$r1"
case "$RL_OUT" in *"round:$RL_O1"*"round:$RL_O2"*) r1=ordered ;; *) r1=no ;; esac
t roundlog-markers-oldest-first ordered "$r1"
case "$RL_OUT" in *"answering round one"*"answering round two"*) r1=both ;; *) r1=no ;; esac
t roundlog-both-replies-present both "$r1"
case "$RL_OUT" in *"Round at 11111111"*) r1=yes ;; *) r1=no ;; esac
t roundlog-short-sha-heading yes "$r1"

# Both markers already in the body → nothing to add (the retried-tick no-op).
RL_OUT2="$(mk_rl "preamble <!-- round:$RL_O1 --> and <!-- round:$RL_O2 -->" "$RL_REVS" "$RL_COMS" | rl)"
t roundlog-idempotent-empty "" "$RL_OUT2"

# A round with a verdict but no author reply is recorded, not skipped.
RL_OUT3="$(mk_rl "Body." "$RL_REVS1" '[]' | rl)"
case "$RL_OUT3" in *"_Round passed with no written reply._"*) r1=yes ;; *) r1=no ;; esac
t roundlog-no-reply-recorded yes "$r1"

# An existing `## Round log` section is extended; sibling sections are kept.
RL_BODY_SEC="$(printf 'Intro.\n\n## Round log\n\nolder entry\n\n## Worklog\n\n- [x] a')"
RL_OUT4="$(mk_rl "$RL_BODY_SEC" "$RL_REVS1" "$RL_COMS" | rl)"
case "$RL_OUT4" in *"## Worklog"*"- [x] a"*) r1=kept ;; *) r1=LOST ;; esac
t roundlog-preserves-sibling-sections kept "$r1"
case "$RL_OUT4" in *"older entry"*"round:$RL_O1"*"## Worklog"*) r1=in-section ;; *) r1=no ;; esac
t roundlog-inserts-into-existing-section in-section "$r1"

# Round 1 already recorded, round 2 not → only round 2 appended (no dup).
RL_OUT5="$(mk_rl "has <!-- round:$RL_O1 --> already" "$RL_REVS" "$RL_COMS" | rl)"
case "$RL_OUT5" in *"round:$RL_O2"*) r1=yes ;; *) r1=no ;; esac
t roundlog-partial-appends-missing yes "$r1"
case "$RL_OUT5" in *"answering round one"*) r1=DUP ;; *) r1=clean ;; esac
t roundlog-partial-skips-recorded clean "$r1"

# --- rotate_log
printf 'x' >"$TMP/small.log"
rotate_log "$TMP/small.log"
[ -f "$TMP/small.log" ] && r1=kept || r1=gone
t rotate-small kept "$r1"

# --- seen-ledgers: ledger_filter / ledger_commit (the refire fix) ---------
# A wake whose signal is present but UNCHANGED must not re-launch a session;
# it may only wake on new-or-advanced activity. This is what stops the mention
# and held-discussion refire that burned the triage box's Fable quota.
LG="$TMP/ledger"
n() { awk 'NF{c++} END{print c+0}'; }
# cold ledger (first look): everything is new
t ledger-cold 2 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_commit "$LG"
# same state again: SUPPRESSED (the burn fix)
t ledger-suppress 0 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
# one timestamp advanced: only that id re-wakes
t ledger-advance "111 2026-07-24T20:30:00Z" "$(printf '111 2026-07-24T20:30:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG")"
# brand-new id wakes
t ledger-newid 1 "$(printf '333 2026-07-25T01:00:00Z\n' | ledger_filter "$LG" | n)"
# commit is monotonic: a stale (older) commit must not lower the mark
printf '111 2026-07-24T20:30:00Z\n' | ledger_commit "$LG"
printf '111 2026-07-01T00:00:00Z\n' | ledger_commit "$LG"
t ledger-monotonic 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"
# empty input is safe and preserves the ledger (no session -> nothing to commit)
printf '' | ledger_commit "$LG"
t ledger-empty-safe 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"

# Build ready lines are committed only when the post-session board proves the
# whole enumerated set was declined. IDs compare as whole keys (#264).
READY3='heavy-duty/crew#2 T2
heavy-duty/crew#25 T25
heavy-duty/crew#30 T30'
t ready-commit-whole-decline "$READY3" \
  "$(_ready_lines_to_commit "$READY3" $'heavy-duty/crew#2\nheavy-duty/crew#25\nheavy-duty/crew#30')"
t ready-commit-one-claimed "" \
  "$(_ready_lines_to_commit "$READY3" $'heavy-duty/crew#2\nheavy-duty/crew#30')"
t ready-commit-none-left "" "$(_ready_lines_to_commit "$READY3" '')"
t ready-commit-empty "" "$(_ready_lines_to_commit '' 'heavy-duty/crew#2')"
t ready-commit-whole-id "" \
  "$(_ready_lines_to_commit 'heavy-duty/crew#2 T2' 'heavy-duty/crew#25')"

# Drive the converted registry call site with a producer that pauses after the
# matching line. The awareness pass must wait for the complete repo list and
# therefore emit no false out-of-scope warning.
p447_registry_out="$(
  # shellcheck disable=SC2317  # invoked indirectly by _warn_unscoped_authored
  read_repo_list() { printf '%s\n' heavy-duty/crew; sleep 0.05; printf '%s\n' other/repo; }
  # shellcheck disable=SC2317  # invoked indirectly by _warn_unscoped_authored
  gh() { printf '%s\n' 'heavy-duty/crew#447'; }
  ME=andriujoseba REPOS_FILE=unused
  _warn_unscoped_authored
)"
t p447-registry-forced-race-stays-in-scope "" "$p447_registry_out"

# The orphan scan consumes head listings larger than PIPE_BUF. A merged branch
# and an open branch must never become orphans; only the absent branch is due.
P447_PIPE_BUF="$(getconf PIPE_BUF /)"
P447_MERGED_HEADS="$(awk 'BEGIN {
  print "build/900-merged"
  for (i=1; i<=10000; i++) print "build/filler-" i
}')"
if [ "${#P447_MERGED_HEADS}" -gt "$P447_PIPE_BUF" ]; then r1=large; else r1=TOO-SMALL; fi
t p447-merged-heads-exceeds-pipe-buf large "$r1"
P447_OPEN_HEADS=build/901-open
# shellcheck disable=SC2317  # invoked indirectly by _orphan_claim_nums
gh() {
  case "$*" in
    *build/900-*) printf '%s\n' build/900-merged ;;
    *build/901-*) printf '%s\n' build/901-open ;;
    *build/902-*) printf '%s\n' build/902-orphan ;;
    *) return 1 ;;
  esac
}
ME=andriujoseba p447_orphan_failures=0
for _p447_i in $(seq 1 400); do
  p447_orphans="$(_orphan_claim_nums crew '900 901 902' "$P447_MERGED_HEADS" "$P447_OPEN_HEADS")"
  [ "$p447_orphans" = " 902" ] || p447_orphan_failures=$((p447_orphan_failures+1))
done
t p447-orphan-scan-400-runs 0 "$p447_orphan_failures"
unset -f gh

# Against the pre-conversion spelling, the same large fixture makes the early
# match close the pipe while printf still has output: the predicate answers
# with SIGPIPE instead of the match. Keep the spelling assembled for the guard.
eval 'printf '\''%s\\n'\'' "$P447_MERGED_HEADS" | gr'"ep -qx build/900-merged" >/dev/null 2>&1
p447_old_orphan_rc=$?
case "$p447_old_orphan_rc" in 0) r1=MATCHED ;; *) r1=nonzero ;; esac
t p447-orphan-old-shape-races nonzero "$r1"

# cross-repo collision: discussion numbers are PER-REPO but the ledger is one
# file across every repo in repos.txt, so keys must be repo-qualified. After
# committing ceremony#1, an unchanged/older rig#1 must still wake — a bare "1"
# key would shadow it and triage would never see rig's discussion (codex, #16).
LG2="$TMP/ledger-disc"
printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_commit "$LG2"
t ledger-crossrepo-distinct 1 "$(printf 'heavy-duty/rig#1 2026-07-20T00:00:00Z\n' | ledger_filter "$LG2" | n)"
t ledger-crossrepo-samekey  0 "$(printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_filter "$LG2" | n)"

# --- ledger_suppressed: the exact inverse of ledger_filter (#59) ------------
# The two must partition the input between them. If they can ever disagree, the
# engine either pays for work it meant to suppress or goes quiet about work it
# meant to report — and the second is the dangerous one.
LG3="$TMP/ledger-inv"
printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | ledger_commit "$LG3"
IN3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T11:00:00Z\no/r#3 2026-07-27T09:00:00Z\n')"
# #1 unchanged -> suppressed; #2 advanced -> fresh; #3 unseen -> fresh
t suppressed-unchanged "o/r#1 2026-07-27T10:00:00Z" "$(printf '%s\n' "$IN3" | ledger_suppressed "$LG3")"
t suppressed-fresh-count 2 "$(printf '%s\n' "$IN3" | ledger_filter "$LG3" | n)"
# Partition: filter + suppressed together account for every input line, exactly
# once. Asserted rather than assumed — the set-arithmetic version of this that
# I wrote first reported NOTHING suppressed whenever the fresh list was empty.
t suppressed-partitions 3 "$(printf '%s\n' "$IN3" | { ledger_filter "$LG3"; printf '%s\n' "$IN3" | ledger_suppressed "$LG3"; } | n)"
t suppressed-disjoint 0 "$(comm -12 \
  <(printf '%s\n' "$IN3" | ledger_filter "$LG3" | sort) \
  <(printf '%s\n' "$IN3" | ledger_suppressed "$LG3" | sort) | n)"
# A cold ledger hides nothing.
t suppressed-cold 0 "$(printf 'o/r#9 2026-07-27T10:00:00Z\n' | ledger_suppressed "$TMP/nope" | n)"

# --- report_suppressed: stop paying, do NOT stop saying (#59) ---------------
# A ledger converts a burn into silence. An unactioned item is still a live
# board-invariant violation, so the suppressed set has to surface — but at one
# tick per five minutes, a line every tick would bury the log it informs. So:
# warn when the SET CHANGES, and again from scratch after it clears.
ST="$TMP/suppressed-state"
r1="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r1" in *"1 item(s)"*"o/r#1"*) r2=warned ;; *) r2="$r1" ;; esac
t report-first warned "$r2"
# Same set again: silent.
t report-repeat "" "$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
# Set grows: speaks again.
r3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r3" in *"2 item(s)"*) r4=warned ;; *) r4="$r3" ;; esac
t report-grew warned "$r4"
# Emptied: silent, and the state file goes, so a recurrence is reported afresh
# rather than being swallowed as "same as last time".
t report-cleared "" "$(printf '' | report_suppressed "$ST" "o/r: board")"
if [ -f "$ST" ]; then r5=kept; else r5=removed; fi
t report-state-removed removed "$r5"
r6="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r6" in *"1 item(s)"*) r7=warned ;; *) r7="$r6" ;; esac
t report-recurrence-speaks warned "$r7"
# Blank lines are not items and must not render as the malformed `()`.
r8="$(printf '\no/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$TMP/sup-blank" "review")"
case "$r8" in *'()'*) r9=MALFORMED ;; *) r9=clean ;; esac
t report-blank-line-format clean "$r9"

# An incomplete sweep cannot compare its partial set with the previous complete
# set. Preserve the state byte-for-byte; otherwise one flaky repo makes every
# healthy repo's standing suppression look changed twice (drop + return).
ST_PART="$TMP/sup-partial"
printf 'o/a#1 T1\no/b#1 T1\n' | report_suppressed "$ST_PART" "review" >/dev/null
before_part="$(cat "$ST_PART")"
printf 'o/a#1 T1\n' \
  | report_suppressed_if_complete 0 "$ST_PART" "review" >/dev/null
t report-partial-preserves-state "$before_part" "$(cat "$ST_PART")"
# The next complete steady set remains silent, proving the partial tick did not
# replace the state and manufacture a second warning when repo B returns.
t report-after-partial-still-settled "" \
  "$(printf 'o/a#1 T1\no/b#1 T1\n' \
      | report_suppressed_if_complete 1 "$ST_PART" "review")"

# --- `no build duty` names its cause (#345) --------------------------------
# One spelling for three causes cost the operator an hour on 2026-08-03: the
# line was indistinguishable from #264's burial bug and the answer was the
# boring one (the slot was held). These drive the module's own variables in the
# module's own order — enumerate, ledger-filter, gate, name the cause — because
# the gate WIPES ready_items, so a reason read off anything but the pre-gate
# snapshot collapses every scenario below onto `board empty`.
# Two ledgers, chosen per scenario rather than mutated in place: the ONLY
# difference between the slot-held and the seen-ledger cause is whether the
# board survived the filter, so a single ledger would make the scenarios
# order-dependent and the mutation count below would silently drop.
NBD_LG_COLD="$TMP/ledger-nbd-cold"
NBD_LG_HOT="$TMP/ledger-nbd-hot"
NBD_LG="$NBD_LG_COLD"
nbd() {  # nbd READY_LINES CR_LINES MINE_JSON [BOARD_READ]
  local R=heavy-duty/crew
  local ready_items="$1" cr_items="$2" mine_json="$3" board_read="${4:-1}"
  local ready_board ledgered_rounds ready_count cr_count open_pr_count
  local slot_prs="" open_pr_ids=""
  ready_board="$(printf '%s\n' "$ready_items" | awk 'NF{c++} END{print c+0}')"
  ready_count="$(printf '%s\n' "$ready_items" \
    | ledger_filter "$NBD_LG" | awk 'NF{c++} END{print c+0}')"
  ledgered_rounds="$(printf '%s\n' "$cr_items" | awk 'NF{c++} END{print c+0}')"
  cr_count="$(printf '%s\n' "$cr_items" \
    | ledger_filter "$NBD_LG" | awk 'NF{c++} END{print c+0}')"
  # shellcheck disable=SC2034  # read by _gate_ready_for_open_pr through bash's
  # dynamic scoping, exactly as _builder_repo hands them over.
  open_pr_count="$(printf '%s' "$mine_json" | jq 'length')"
  # shellcheck disable=SC2034  # same: the gate reads this, then writes slot_prs.
  open_pr_ids="$(printf '%s' "$mine_json" \
    | jq -r --arg repo "$R" '[.[].number] | sort | map("\($repo)#\(.)") | join(", ")')"
  _gate_ready_for_open_pr >/dev/null || true
  if [ "$ready_count" -gt 0 ] || [ "$cr_count" -gt 0 ]; then
    printf 'BUILD_DUTY'
    return 0
  fi
  _no_build_duty_reason "$ready_board" "$ledgered_rounds" "$slot_prs" "$board_read"
}
NBD_READY="$(printf 'heavy-duty/crew#2 T2\nheavy-duty/crew#25 T25\nheavy-duty/crew#30 T30')"
NBD_CR="$(printf 'heavy-duty/crew#40 T40')"

# (a) BOARD EMPTY — nothing enumerated on either side.
t nbd-board-empty 'board empty' "$(nbd '' '' '[]')"

# (c) SLOT HELD — a non-empty, unledgered board and an open authored PR. The
# board count is the pre-gate one: the gate has emptied ready_items by the time
# the line is written, and 3 is what the operator sees on the queue.
t nbd-slot-held 'slot held by heavy-duty/crew#231; board holds 3 ready' \
  "$(nbd "$NBD_READY" '' '[{"number":231}]')"
# The count is READ, never hardcoded: a different board gives a different N,
# which is the number #264's discriminating read depends on.
t nbd-slot-count-is-live 'slot held by heavy-duty/crew#231; board holds 1 ready' \
  "$(nbd 'heavy-duty/crew#2 T2' '' '[{"number":231}]')"
# Every PR occupying the slot is named, in numeric order, whatever order the
# listing returned — the line has to be stable across ticks.
t nbd-slot-names-all-prs \
  'slot held by heavy-duty/crew#9, heavy-duty/crew#40; board holds 3 ready' \
  "$(nbd "$NBD_READY" '' '[{"number":40},{"number":9}]')"
# (b) SEEN-LEDGER — enumerated, then hidden whole. N is the pre-filter count.
printf '%s\n%s\n' "$NBD_READY" "$NBD_CR" | ledger_commit "$NBD_LG_HOT"
NBD_LG="$NBD_LG_HOT"
t nbd-seen-ledger-ready '3 ready held by seen-ledger' "$(nbd "$NBD_READY" '' '[]')"
# An open PR does NOT claim the tick when the gate never fired: with the board
# ledgered to zero the ledger is what zeroed it, and the slot is not the news.
t nbd-slot-not-claimed-when-gate-idle '3 ready held by seen-ledger' \
  "$(nbd "$NBD_READY" '' '[{"number":231}]')"
# cr_count runs the SAME filter over a different set, so the noun follows the
# count it came from. An empty board with a ledgered round is not `board empty`.
t nbd-seen-ledger-rounds '1 round(s) held by seen-ledger' "$(nbd '' "$NBD_CR" '[{"number":40}]')"
t nbd-seen-ledger-both '3 ready, 1 round(s) held by seen-ledger' \
  "$(nbd "$NBD_READY" "$NBD_CR" '[{"number":40}]')"
# Fresh work on either side is duty, not a cause — the no-duty branch is never
# reached, so no spelling may claim it.
t nbd-fresh-ready-is-duty BUILD_DUTY "$(nbd 'heavy-duty/crew#77 T77' '' '[]')"
t nbd-fresh-round-is-duty BUILD_DUTY "$(nbd '' 'heavy-duty/crew#78 T78' '[{"number":78}]')"

# (d) BOARD UNREAD — the issue listing failed, so neither of the two above may
# be asserted. Narrower than both; it claims only that nobody read the board.
t nbd-board-unread 'board unread' "$(nbd '' '' '[]' 0)"

# MUTATION — the property that makes this issue worth building. Merge any two
# causes back into one spelling and this count drops below 4. Each scenario
# picks its own ledger, because the ledger IS the discriminator between two of
# them.
NBD_LG="$NBD_LG_COLD"; nbd_slot="$(nbd "$NBD_READY" '' '[{"number":231}]')"
NBD_LG="$NBD_LG_HOT"
NBD_ALL="$(printf '%s\n%s\n%s\n%s\n' \
  "$(nbd '' '' '[]')" \
  "$(nbd "$NBD_READY" '' '[]')" \
  "$nbd_slot" \
  "$(nbd '' '' '[]' 0)" | sort -u | awk 'NF{c++} END{print c+0}')"
t nbd-causes-are-distinct 4 "$NBD_ALL"

# CONSUMERS — the prefix is the contract. `crew status` renders the newest duty
# line as its NOTE through `cut -c1-60`, and the floor's RE_BUILD_DUTY matches
# the POSITIVE line only; a parenthetical must reach neither.
NBD_LINE="$(log "heavy-duty/crew: no build duty ($nbd_slot)")"
case "$NBD_LINE" in
  *'heavy-duty/crew: no build duty (slot held by'*) r1=prefixed ;;
  *) r1="$NBD_LINE" ;;
esac
t nbd-grep-prefix-unchanged prefixed "$r1"
case "$(printf '%s' "$NBD_LINE" | cut -c1-60)" in
  *'no build duty'*) r1=survives ;;
  *) r1=TRUNCATED_AWAY ;;
esac
t nbd-note-column-keeps-prefix survives "$r1"
if grep -qE ' (\S+): build duty \(ready unclaimed=([0-9]+), whole rounds owed=([0-9]+)\)' <<<"$NBD_LINE"; then
  r1=MATCHED_POSITIVE
else
  r1=distinct
fi
t nbd-not-mistaken-for-positive-line distinct "$r1"

# WIRING — the fixtures above prove the spellings; these pin them to the module.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_board_assign="$(grep -F 'ready_board="$(' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
case "$nbd_board_assign" in
  *ledger_filter*)  r1=LEDGERED ;;
  *'"$ready_items"'*) r1=pre-filter ;;
  *)                r1=MISSING ;;
esac
t nbd-board-count-is-pre-ledger pre-filter "$r1"
# ...and taken before the gate empties the set it counts.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_board_ln="$(grep -nF 'ready_board="$(' "$BUILDER_MOD" | head -n1 | cut -d: -f1)"
nbd_gate_ln="$(grep -nF '_gate_ready_for_open_pr || true' "$BUILDER_MOD" | head -n1 | cut -d: -f1)"
if [ -n "$nbd_board_ln" ] && [ -n "$nbd_gate_ln" ] && [ "$nbd_board_ln" -lt "$nbd_gate_ln" ]; then
  r1=before
else
  r1=AFTER_GATE
fi
t nbd-board-count-taken-before-gate before "$r1"
# Why that order is load-bearing, stated as behaviour rather than left to the
# line numbers: fed the post-gate set, the same scenario reports an empty board
# it does not have — the stale count #264's read cannot survive.
t nbd-post-gate-count-would-lie 'slot held by heavy-duty/crew#231; board holds 0 ready' \
  "$(_no_build_duty_reason 0 0 'heavy-duty/crew#231' 1)"
# The line names the cause, and names it from the board facts rather than from
# the survivors, every one of which is zero by then.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_call="$(sed -n '/log "\$R: no build duty (\$(_no_build_duty_reason/,+1p' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '"$ready_board" "$ledgered_rounds" "$slot_prs" "$board_read"' <<<"$nbd_call"; then
  r1=named
else
  r1=BARE
fi
t nbd-call-site-passes-board-facts named "$r1"
# The gate is what knows the slot fired; nothing downstream can re-derive it.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_gate_body="$(sed -n '/^_gate_ready_for_open_pr() {/,/^}/p' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq 'slot_prs="${open_pr_ids' <<<"$nbd_gate_body"; then r1=recorded; else r1=SILENT; fi
t nbd-gate-records-that-it-fired recorded "$r1"
# And records it UNCONDITIONALLY: the fallback makes the record independent of
# the id render, so an empty open_pr_ids cannot make the line blame the ledger
# for what the slot did. Text here, behaviour in claim.test.sh, which drives the
# production gate with an empty render (gate-record-survives-empty-ids).
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq 'slot_prs="${open_pr_ids:-' <<<"$nbd_gate_body"; then r1=always; else r1=CONDITIONAL; fi
t nbd-gate-record-is-unconditional always "$r1"
# One listing, several derived facts (the comment at the top of the block). A
# second ready listing would let the board count disagree with the set it
# describes. Two are expected and neither is new: the pre-session enumeration
# and #264's post-session re-query.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
nbd_ready_listings="$(grep -Fc 'gh issue list -R "$R" --state open --label "$LABEL_READY"' "$BUILDER_MOD")"
t nbd-no-second-ready-listing 2 "$nbd_ready_listings"
# Spec decision 3: a single-cause line stays exactly as it was, and no new log
# lines are added. Only the build kind has three causes to tell apart.
for nbd_kind in resume ci-red handoff rebase; do
  # shellcheck disable=SC2016  # Match literal shell source, not test variables.
  if grep -Fq "log \"\$R: no $nbd_kind duty\"" "$BUILDER_MOD"; then r1=plain; else r1=CHANGED; fi
  t "nbd-other-kind-untouched-$nbd_kind" plain "$r1"
done
# Must-not-change: the positive line and the board-anomaly NOTE.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq 'log "$R: build duty (ready unclaimed=$ready_count, whole rounds owed=$cr_count)"' \
     "$BUILDER_MOD"; then r1=intact; else r1=CHANGED; fi
t nbd-positive-line-intact intact "$r1"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq 'ready issue(s) WITH an assignee (board anomaly; hygiene'"'"'s to fix)' \
     "$BUILDER_MOD"; then r1=intact; else r1=CHANGED; fi
t nbd-anomaly-note-intact intact "$r1"

# --- #359: successful triage sessions settle ledgers at their exit state ---
TR359_T1='2026-08-05T10:00:00Z'
TR359_T2='2026-08-05T10:05:00Z'
TR359_T3='2026-08-05T10:10:00Z'
tr359_nt() { jq -nc --arg s "$1" '[{number:116,updatedAt:$s}]'; }

# A session comments on an item and leaves it needs-triage. The post-session
# timestamp, not the launching timestamp, is committed; the following tick is
# therefore quiet even though the item remains in the query.
tr_fix '[]' "$(tr359_nt "$TR359_T1")" "$(tr359_nt "$TR359_T2")" '[]' '[]' '[]'
tr_run 0
t triage359-self-write-first-tick-launches 1 "$(trc '^SESSION triage$')"
if grep -q "o/r#116 $TR359_T2" "$TRD/.seen-triage-board"; then r1=post; else r1=STALE; fi
t triage359-self-write-commits-post-session post "$r1"
tr_fix '[]' "$(tr359_nt "$TR359_T2")" "$(tr359_nt "$TR359_T2")" '[]' '[]' '[]'
tr_tick 0
t triage359-self-write-next-tick-quiet 0 "$(trc '^SESSION triage$')"

# Genuine activity after that session advances the board beyond the committed
# value and buys one new session. This is the side the safe re-read must retain.
tr_fix '[]' "$(tr359_nt "$TR359_T3")" "$(tr359_nt "$TR359_T3")" '[]' '[]' '[]'
tr_tick 0
t triage359-third-party-later-write-rewakes 1 "$(trc '^SESSION triage$')"

# Discussion rows use the same exit-state contract, with their own ledger.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
  "o/r#8 $TR359_T1" "o/r#8 $TR359_T2"
tr_run 0
if grep -q "o/r#8 $TR359_T2" "$TRD/.seen-discussions"; then r1=post; else r1=STALE; fi
t triage359-discussion-commits-post-session post "$r1"
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
  "o/r#8 $TR359_T2" "o/r#8 $TR359_T2"
tr_tick 0
t triage359-discussion-next-tick-quiet 0 "$(trc '^SESSION triage$')"

# A failed session commits none of the three ledgers. Crash-only retry remains
# the distinction between "declined" and "never got there".
tr_fix '[]' "$(tr359_nt "$TR359_T1")" "$(tr359_nt "$TR359_T2")" '[]' '[]' '[]'
tr_run 1
if [ -f "$TRD/.seen-triage-board" ]; then r1=COMMITTED; else r1=withheld; fi
t triage359-failed-session-commits-no-board withheld "$r1"

# A standing unblockable lead costs one session. Its exit timestamp settles
# the dedicated ledger; subsequent ticks report the stable lead once without
# launching, and report_suppressed then quiets the unchanged warning.
TR359_BLOCK_1='[{"number":244,"body":"Blocked by #216.","updatedAt":"2026-08-05T11:00:00Z"}]'
TR359_BLOCK_2='[{"number":244,"body":"Blocked by #216.","updatedAt":"2026-08-05T11:05:00Z"}]'
tr_fix '[]' '[]' '[]' "$TR359_BLOCK_1" "$TR359_BLOCK_2" "$TR_LANDED"
tr_run 1
if [ -f "$TRD/.seen-unblockable" ]; then r1=COMMITTED; else r1=withheld; fi
t triage359-failed-session-commits-no-unblockable withheld "$r1"
tr_fix '[]' '[]' '[]' "$TR359_BLOCK_1" "$TR359_BLOCK_2" "$TR_LANDED"
tr_run 0
t triage359-unblockable-first-tick-launches 1 "$(trc '^SESSION triage$')"
if grep -q 'o/r#244 2026-08-05T11:05:00Z' "$TRD/.seen-unblockable"; then r1=post; else r1=MISSING; fi
t triage359-unblockable-commits-post-session post "$r1"
tr_fix '[]' '[]' '[]' "$TR359_BLOCK_2" "$TR359_BLOCK_2" "$TR_LANDED"
tr_tick 0
t triage359-unblockable-next-tick-spends-no-session 0 "$(trc '^SESSION triage$')"
if grep -q 'o/r: unblockable: 1 item(s)' "$TR_LOG"; then r1=warned; else r1=SILENT; fi
t triage359-unblockable-suppression-reported warned "$r1"
tr_tick 0
if grep -q 'o/r: unblockable: 1 item(s)' "$TR_LOG"; then r1=REPEATED; else r1=quiet; fi
t triage359-unblockable-stable-warning-once quiet "$r1"

# --- the registry bounds EVERY module, attention included (#52, #66) ------
# drill/rehearsal.sh narrows repos.txt to a single sandbox repo and REFUSES to
# tick if it cannot. That is containment only for modules which actually
# consult the file, so it is asserted rather than believed.
#
# The list was review, builder, triage, hygiene. The reviewer was the exception
# until 2026-07-25 (an org-wide requested_reviewers sweep no registry could
# bound) — which is what #52 was filed doubting — and the attention wake was
# the exception until 2026-07-27, when danmt ruled on #66 that the registry
# bounds it too. `examples/repos.txt` asserted the universal for two days longer
# than the engine honoured it, and that header is what an operator reads when
# deciding whether narrowing the file contains a box.
for mod in review builder triage hygiene attention; do
  if grep -q 'REPOS_FILE' "$SHARED/lib/duty-$mod.sh"; then r1=scoped; else r1=UNSCOPED; fi
  t "registry-scoped-$mod" scoped "$r1"
done

# ...and scoped BEHAVIOURALLY, not just by mentioning the file. The partition
# is the ruling, so it is exercised directly: a grep for REPOS_FILE would pass
# against a module that read the registry and then ignored it.
# Definition-only at the top level, so sourcing costs nothing and runs nothing.
# shellcheck disable=SC1091
source "$SHARED/lib/duty-attention.sh"
ATT_MOD="$SHARED/lib/duty-attention.sh"
ATT_REG="$(printf 'heavy-duty/ceremony\nheavy-duty/rig\n')"
ATT_ROWS="$(printf 'heavy-duty/ceremony 12 T1\nouter/thing 7 T2\nheavy-duty/rig 3 T3\n')"
ATT_OUT="$(printf '%s\n' "$ATT_ROWS" | _attention_partition "$ATT_REG")"
t attention-in-registry-acted "IN heavy-duty/ceremony 12 T1
IN heavy-duty/rig 3 T3" "$(printf '%s\n' "$ATT_OUT" | grep '^IN ')"
t attention-outside-registry-not-acted "OUT outer/thing 7 T2" \
  "$(printf '%s\n' "$ATT_OUT" | grep '^OUT ')"
# A prefix must not count as membership: `heavy-duty/rig` in the registry must
# not authorize `heavy-duty/rig-fork`. grep -qxF, never a substring match.
t attention-prefix-is-not-membership "OUT heavy-duty/rig-fork 9 T4" \
  "$(printf 'heavy-duty/rig-fork 9 T4\n' | _attention_partition "$ATT_REG" | grep '^OUT ')"
# An empty registry authorizes nothing — it must not read as "no filter".
t attention-empty-registry-acts-on-nothing "" \
  "$(printf '%s\n' "$ATT_ROWS" | _attention_partition "" | grep '^IN ' || true)"

# --- the attention wake is ledgered too (#59's last site) --------------------
# It looked exempt: the pickup session acks by REMOVING the label, so the
# signal self-clears, and the module documents a deliberate crash-only retry.
# Both true, and neither covers a session that COMPLETES and correctly declines
# to ack — needs a ruling, not this box's to answer, already handled. Nothing
# removes the label and the wake re-fires every tick.
#
# It is the worst place in the engine for that: TIMEOUT_ATTENTION is 1800s,
# duty_attention runs FIRST, and it runs for EVERY role on EVERY box, where
# every other signal site is confined to one role.
ALG="$TMP/attention-ledger"
ATT_IN="$(printf 'o/r#4 T1\no/r#9 T1\n')"
t attention-first-tick-both-fire 2 "$(printf '%s\n' "$ATT_IN" | ledger_filter "$ALG" | n)"
# #4's session completed and acked (the row is gone from the query next tick);
# #9's completed and declined, so only #9's id was committed.
printf 'o/r#9 T1\n' | ledger_commit "$ALG"
t attention-declined-does-not-refire 0 "$(printf 'o/r#9 T1\n' | ledger_filter "$ALG" | n)"
# ...but it is still SAID, once per change to the set.
t attention-declined-is-reported "o/r#9" \
  "$(printf 'o/r#9 T1\n' | ledger_suppressed "$ALG" | cut -d' ' -f1)"
# A comment, an edit or a re-label advances updated_at — look again, which is
# exactly when the box should.
t attention-touched-demand-rewakes 1 "$(printf 'o/r#9 T2\n' | ledger_filter "$ALG" | n)"
# A CRASHED session commits nothing, so the same id is still fresh next tick:
# the module's documented crash-only retry has to survive the ledger.
t attention-crashed-session-retries 1 "$(printf 'o/r#4 T1\n' | ledger_filter "$ALG" | n)"
# The commit is gated on the session's own rc, per demand — a sibling that
# succeeded must not settle one that died.
if grep -q 'RUN_SESSION_RC:-1}" -eq 0' "$SHARED/lib/duty-attention.sh"; then r1=gated; else r1=UNGATED; fi
t attention-ledger-commit-gated gated "$r1"
# ...and the WAKE PATH must be the filtered set, which everything above this
# line fails to prove: the assertions exercise ledger_filter, and the module
# would still mention .seen-attention (in the suppression report) with the
# filter deleted from the wake. Ripping `ledger_filter` out of the assignment
# left all of them green. So the structure is pinned too — the same shape
# duty-review.sh's `review-partitions-before-prompt` pins, and for the same
# reason.
ATT_MOD="$SHARED/lib/duty-attention.sh"
# The SAME hole, one level up, and this one shipped to review: the behavioural
# assertions call _attention_partition directly, so they cannot see a wake path
# that computes the partition and then ignores it. kimi ran exactly that
# mutation against d849f16 —
#
#   inside="$(printf '%s\n' "$rows" | awk '{ print $1 "#" $2, $3 }')"
#
# keeping the registry read and the partition function intact, and the suite
# stayed 185 ok / 0 failed. So the wiring is pinned too: the acted set and the
# reported set must both come from $partitioned, and $outside must be what
# feeds the suppression report the operator alert keys on.
# shellcheck disable=SC2016  # the literals the module contains, not expansions
if grep -q 'inside=.*\$partitioned' "$ATT_MOD" &&
   grep -q 'outside=.*\$partitioned' "$ATT_MOD" &&
   grep -q 'printf .* "\$outside" *\\*$' "$ATT_MOD"; then
  r1=wired
else
  r1=UNWIRED
fi
t attention-acted-set-comes-from-the-partition wired "$r1"

# The two withheld sets are different events and must not read alike in
# duty.log: a ledger suppression is an item a session SAW and declined; an
# out-of-scope demand was never actionable by this box and no session ever saw
# it. The default phrase stays for the three ledger callers.
RSW="$TMP/rsw-state"
report_suppressed_out="$(printf 'x#1 T1\n' | report_suppressed "$RSW" "lbl" 2>&1)"
t report-suppressed-default-phrase reported \
  "$(grep -q 'unactioned since a previous session' <<<"$report_suppressed_out" && echo reported || echo MISSING)"
rm -f "$RSW"
report_suppressed_out="$(printf 'x#1 T1\n' | report_suppressed "$RSW" "lbl" "never actionable here" 2>&1)"
t report-suppressed-custom-phrase reported \
  "$(grep -q 'never actionable here' <<<"$report_suppressed_out" && echo reported || echo MISSING)"
rm -f "$RSW"
if grep -q 'report_suppressed .*sc_state.*\\$' "$ATT_MOD" &&
   grep -q 'this box does not carry' "$ATT_MOD"; then r1=distinct; else r1=BORROWED; fi
t attention-scope-report-has-its-own-phrase distinct "$r1"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -q 'fresh=.*ledger_filter.*\.seen-attention' "$ATT_MOD" &&
   grep -q 'rows="\$fresh"' "$ATT_MOD"; then
  r1=filtered
else
  r1=UNFILTERED
fi
t attention-wake-set-is-the-filtered-set filtered "$r1"

# The bound must not be silent, and for THIS module not only in duty.log: an
# attention demand is somebody deliberately handing this box work, so a bound
# that only logged would read to them as the box ignoring them.
if grep -q 'report_suppressed' "$SHARED/lib/duty-attention.sh"; then r1=reported; else r1=SILENT; fi
t attention-out-of-scope-reported reported "$r1"
if grep -q 'alert ' "$SHARED/lib/duty-attention.sh"; then r1=pinged; else r1=LOG-ONLY; fi
t attention-out-of-scope-pings-operator pinged "$r1"

# --- an idle tick is not a silent one (#53) -------------------------------
# The floor's SILENT rule is "no duty.log line for two tick boundaries", which
# is sound only if a tick that finds no work still writes. duty.sh logs
# `duty run start` before any role dispatch and `duty run end` on every exit
# path, and tick.sh covers the rest (skipped, FAILED) — so a duty.log with
# nothing new means no tick RAN, which is a cron problem, never a healthy idle
# box. That is the diagnosis #53 needed, and this keeps it true: an early
# `exit` added between the two lines would turn an idle box into an offline one
# on the console, and a silent box into an ambiguous one.
t duty-start-unconditional 1 "$(grep -c '^log "duty run start"' "$SHARED/bin/duty.sh")"
# Every exit path after the start line must have logged the end line first.
# A linear scan, deliberately: it is an approximation of control flow, but it
# catches the shape that actually regresses — a new early `exit` on a branch
# that forgot the evidence line.
t duty-end-on-every-exit "" "$(awk '
  /^log "duty run start"/ { started = 1; next }
  !started { next }
  /log "duty run end"/    { ended = 1 }
  /^[[:space:]]*exit / && !ended { print "line " NR; exit }
' "$SHARED/bin/duty.sh")"
# `crontab armed` must not be the last word: the crontab holding a line says
# nothing about a cron daemon existing to run it, and that gap is why three
# boxes reported armed and one ticked.
if grep -q 'cron_daemon_running' "$SHARED/install.sh"; then r1=checked; else r1=ASSUMED; fi
t install-verifies-cron-daemon checked "$r1"

# --- the two-boundary rule must exist once, not once per reader -----------
# floor.py derives it (2 * TICK_S), cli/crew names it, and probe.sh must not
# hold it at all: the box ships ::tickage and the HOST decides. A third copy
# inside the box, in a second language, meant changing TICK_S would leave the
# floor calling a box SILENT while both credential readers still said flowing
# — and rehearsal-app.sh asserts those two readers agree, so the drill would
# fail for a reason nobody would trace to a constant.
CREW_CLI="$(cd "$(dirname "$SHARED")" && pwd)/cli/crew"
FLOOR_PY="$(cd "$(dirname "$SHARED")" && pwd)/fleet-floor/server/floor.py"

FL_TICK="$(sed -n 's/^TICK_S = \([0-9]*\).*/\1/p' "$FLOOR_PY" | head -1)"
FL_SILENT=$(( ${FL_TICK:-0} * 2 ))
# shellcheck disable=SC2016  # matching crew's literal ${CREW_SILENT_AFTER:-600}
CL_SILENT="$(sed -n 's/^SILENT_AFTER_S="${CREW_SILENT_AFTER:-\([0-9]*\)}".*/\1/p' "$CREW_CLI" | head -1)"
t silent-rule-floor-derived 600 "$FL_SILENT"
t silent-rule-cli-matches-floor "$FL_SILENT" "$CL_SILENT"

# The never-ticked boundary is the same kind of shared rule and pinned the same
# way (#265). SILENT_AFTER_S was never the only number the two readers had to
# agree on — it was only the only one that EXISTED. `waiting` adds a second
# boundary, and a verdict living in one reader alone is precisely the
# disagreement auth_from_flow was written to remove: `crew status` would say a
# fresh hire is waiting while the floor called it stale, in front of the same
# operator, about the same box. Extracted rather than grepped for, so that
# moving the boundary in one reader fails HERE rather than silently.
# shellcheck disable=SC2016  # a literal fragment of cli/crew, not to expand
CL_NEVER="$(sed -n 's/^ *if \[ "$tickage" -lt \(-*[0-9][0-9]*\) \]; then.*/\1/p' "$CREW_CLI" | head -1)"
FL_NEVER="$(sed -n 's/^ *never_ticked = tick_age < \(-*[0-9][0-9]*\).*/\1/p' "$FLOOR_PY" | head -1)"
t nevertick-rule-floor-boundary 0 "$FL_NEVER"
t nevertick-rule-cli-matches-floor "$FL_NEVER" "$CL_NEVER"
# ...and it must be a verdict BOTH readers can actually produce. The boundary
# matching proves they agree on WHEN; these prove they agree on what to CALL it,
# which is the half a numeric compare cannot see: two readers could share the
# boundary exactly and still print different words at it.
# shellcheck disable=SC2016  # a literal fragment of cli/crew, not to expand
if grep -q 'printf -v "$_v" waiting' "$CREW_CLI"; then r1=emitted; else r1=MISSING; fi
t nevertick-cli-emits-waiting emitted "$r1"
if grep -q 'u\[svc\] = "waiting"' "$FLOOR_PY"; then r1=emitted; else r1=MISSING; fi
t nevertick-floor-emits-waiting emitted "$r1"

# ...and the box must hold no threshold of its own. Comments and the log-tail
# line count are stripped before looking, so only real code counts.
PROBE_SH="$(cd "$(dirname "$SHARED")" && pwd)/fleet-floor/server/probe.sh"
probe_code="$(sed -e 's/#.*//' -e '/tail -n/d' "$PROBE_SH")"
if grep -qE '\b(600|SILENT_AFTER)\b' <<<"$probe_code"; then
  r1=BAKED
else
  r1=clean
fi
t probe-holds-no-threshold clean "$r1"
# The datum it ships instead:
if grep -q 'emit tickage' "$PROBE_SH"; then r1=emitted; else r1=MISSING; fi
t probe-emits-tickage emitted "$r1"
# --- #452: the HUMAN is round_owed's second clause ---------------------------
# Until it existed, a maintainer's CHANGES_REQUESTED reached no wake in this
# engine at all: the panel clause above requires the change-requester to be in
# $panel and the maintainer is off-panel by construction, ci-red wants a failing
# check, rebase wants CONFLICTING, and every resume path wants the latest signal
# NOT to name the current head — which, after a completed handoff, it does.
HC_HUMAN_ROUND='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"}},
  {"state":"CHANGES_REQUESTED","author":{"login":"'$CJ_HUMAN'"},"commit":{"oid":"abc1234"}}
]'
HC_HUMAN_STALE='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"}},
  {"state":"CHANGES_REQUESTED","author":{"login":"'$CJ_HUMAN'"},"commit":{"oid":"oldhead"}}
]'
# The headline: the panel approves this head, the human blocks it, and the human
# is not on the request list — the ball is the builder's.
t head-round-human-block-owed owed \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$HC_HUMAN_ROUND")" | cut -f5)"
# ...and the SPEND. The handoff re-requests the human, and the clause goes false
# — the exact mirror of the panel clause's outstanding-request guard. Without it
# the wake would be permanent and the builder would be re-dispatched every tick
# for a round it has already answered.
t head-round-human-block-requested-is-spent - \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$HC_HUMAN_ROUND" '[{"login":"'$CJ_HUMAN'"}]')" | cut -f5)"
# Head-scoped like every verdict in this file: a block on a tree the builder has
# already moved past is not a wake.
t head-round-human-block-superseded - \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$HC_HUMAN_STALE")" | cut -f5)"
# MUST-FAIL, D3: $human ALONE, never "not in $panel". An implementation keying on
# panel membership passes every other case in this block and wakes the builder
# for every advisory or triage verdict on the board.
HC_ADVISORY='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"}},
  {"state":"CHANGES_REQUESTED","author":{"login":"dan-claude-bot"},"commit":{"oid":"abc1234"}}
]'
t head-round-advisory-block-not-owed - \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$HC_ADVISORY")" | cut -f5)"
# An empty $human matches nobody — what the two callers that read only the check
# column pass, beside the empty $panel that neuters the other clause.
t head-round-empty-human-arg-not-owed - \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$HC_HUMAN_ROUND")" '' | cut -f5)"
# The two clauses are independent: an outstanding PANEL request does not hold
# back a human round, and vice versa. p2 still owes a first verdict, yet the
# human's block at the head is the builder's to answer.
t head-round-human-block-with-panel-request-owed owed \
  "$(hc '["p1","p2"]' "$(mk_prc "$CHK_OK" "$HC_HUMAN_ROUND" '[{"login":"p2"}]')" | cut -f5)"

# ceremony#207: two current-head blockers and one approval, with the whole
# requested panel returned, produces one owed row (and therefore one wake).
CEREMONY_207='[
  {"state":"CHANGES_REQUESTED","author":{"login":"p1"},"commit":{"oid":"abc1234"}},
  {"state":"CHANGES_REQUESTED","author":{"login":"p2"},"commit":{"oid":"abc1234"}},
  {"state":"APPROVED","author":{"login":"p3"},"commit":{"oid":"abc1234"}}
]'
t head-round-ceremony-207-one-wake 1 \
  "$(hc '["p1","p2","p3"]' "$(mk_prc "$CHK_OK" "$CEREMONY_207")" \
    | awk -F'\t' '$5 == "owed" {n++} END {print n+0}')"
# The row's existing number+updatedAt identity remains ledger-compatible: once
# a completed session acknowledges this exact round, the next tick is quiet.
ACK_ROUND="$TMP/head-round-ack"
ACK_ITEM="$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_REQ")" \
  | awk -F'\t' '$5 == "owed" {print $1, $2}')"
printf '%s\n' "$ACK_ITEM" | ledger_commit "$ACK_ROUND"
t head-round-already-acknowledged 0 \
  "$(printf '%s\n' "$ACK_ITEM" | ledger_filter "$ACK_ROUND" | n)"

# The three round-close siblings agree on the same closed, non-approved round.
# addressing=true, round_owed=owed, converged=false.
CROSS_PR="$(jq -cn --argjson reviews "$CEREMONY_207" '{
  data:{repository:{pullRequest:{
    headRefOid:"abc1234",mergeable:"MERGEABLE",
    labels:{nodes:[]},reviewRequests:{nodes:[]},
    latestOpinionatedReviews:{nodes:$reviews}
  }}}
}')"
t round-siblings-addressing true \
  "$(printf '%s' "$CROSS_PR" | jq -r --argjson panel '["p1","p2","p3"]' \
    --arg addressing state:addressing -f "$SHARED/lib/jq/addressing.jq")"
t round-siblings-round-owed owed \
  "$(hc '["p1","p2","p3"]' "$(mk_prc "$CHK_OK" "$CEREMONY_207")" | cut -f5)"
t round-siblings-converged false \
  "$(printf '%s' "$CROSS_PR" | cj '' '["p1","p2","p3"]')"

# #286: the same agreement extended to the REQUEST side, on the #281 snapshot as
# it reads once the signal is spent — every verdict in, no request outstanding,
# and the only signal older than the blocking verdicts it supposedly answered.
# The bug was never that one of these predicates was wrong. round_owed and
# addressing.jq were both right and both held false by the engine's own request,
# so the ball landed nowhere: request-panel.jq has to agree with its siblings on
# the same payload or the round has no owner at all. Asserting the four together
# is what makes "the ball provably lands somewhere" a test rather than a claim.
PR281_PANEL='["p1","p2","p3"]'
PR281_REVIEWS='[
  {"state":"CHANGES_REQUESTED","author":{"login":"p1"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-02T10:32:33Z"},
  {"state":"CHANGES_REQUESTED","author":{"login":"p2"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-02T10:35:14Z"},
  {"state":"APPROVED","author":{"login":"p3"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-02T10:29:40Z"}]'
# The signal that opened round 1 at 10:08:12Z — older than every verdict above,
# and the only one #281 ever carried.
PR281_SIG="$(sig abc1234 2026-08-02T10:08:12Z)"
PR281_GQL="$(jq -cn --argjson reviews "$PR281_REVIEWS" '{
  data:{repository:{pullRequest:{
    headRefOid:"abc1234",mergeable:"MERGEABLE",
    labels:{nodes:[]},reviewRequests:{nodes:[]},
    latestOpinionatedReviews:{nodes:$reviews}
  }}}
}')"
t round-siblings-281-requests-none "" \
  "$(mk_rp abc1234 '[]' "$PR281_REVIEWS" '[]' | rp "$PR281_SIG" "$PR281_PANEL")"
t round-siblings-281-round-owed owed \
  "$(hc "$PR281_PANEL" "$(mk_prc "$CHK_OK" "$PR281_REVIEWS")" | cut -f5)"
t round-siblings-281-addressing true \
  "$(printf '%s' "$PR281_GQL" | jq -r --argjson panel "$PR281_PANEL" \
    --arg addressing state:addressing -f "$SHARED/lib/jq/addressing.jq")"
t round-siblings-281-converged false \
  "$(printf '%s' "$PR281_GQL" | cj "$PR281_SIG" "$PR281_PANEL")"
# The live-round half of the same agreement, and the reason state:bots-reviewing
# is true only while a request awaits a verdict: with p2 still requested, the
# round is the panel's — addressing.jq holds off, and request-panel.jq's
# coherence gate holds p1 rather than opening a second round at one head.
PR281_MID="$(printf '%s' "$PR281_GQL" \
  | jq -c '.data.repository.pullRequest.reviewRequests.nodes
             = [{requestedReviewer:{login:"p2"}}]')"
t round-siblings-281-mid-round-addressing false \
  "$(printf '%s' "$PR281_MID" | jq -r --argjson panel "$PR281_PANEL" \
    --arg addressing state:addressing -f "$SHARED/lib/jq/addressing.jq")"
t round-siblings-281-mid-round-requests-none "" \
  "$(mk_rp abc1234 '["p2"]' "$PR281_REVIEWS" '[]' \
    | rp "$(sig abc1234 2026-08-02T11:12:27Z)" "$PR281_PANEL")"

# --- the ceremony#163 regression case (#17's last acceptance criterion) ------
# The incident this issue was filed from, modelled end to end: a PR with
# current-head approvals from the full panel, mergeable, no changes requested,
# no conflict, no outstanding review request — and `release-exercise /
# fixture-chain` failed during job SETUP on an HTTP 429 fetching
# actions/checkout, so none of the PR's code ever ran. Every wake condition the
# builder had looked past it, and the PR sat.
C163_REVIEWS='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"deadbee"}},
  {"state":"APPROVED","author":{"login":"p2"},"commit":{"oid":"deadbee"}}
]'
C163="$(jq -cn --argjson lr "$C163_REVIEWS" --argjson c "$CHK_BAD" \
  '[{number:163, isDraft:false, updatedAt:"T9", headRefOid:"deadbee",
     statusCheckRollup:$c, latestOpinionatedReviews:$lr, reviewRequests:[]}]')"
C163_ROW="$(hc '["p1","p2"]' "$C163")"
# It owes no round — which is precisely why nothing woke for it before.
t c163-no-round-owed - "$(cut -f5 <<<"$C163_ROW")"
# It is red, so it wakes now.
t c163-head-is-red red "$(cut -f4 <<<"$C163_ROW")"
t c163-wakes-the-author "o/r#163@deadbee" \
  "$(awk -F'\t' "$AWK_RED" <<<"$C163_ROW" | cut -f1)"
t c163-names-the-failing-job "release-exercise / fixture-chain (FAILURE)" \
  "$(cut -f6 <<<"$C163_ROW")"
# ...and it must NOT become a build wake: claiming a new issue is the thing
# that was wrong to do while this PR sat red.
t c163-not-a-build-wake "" "$(awk -F'\t' "$AWK_ROUNDS" <<<"$C163_ROW")"
# One session per head, then quiet. A second tick on the same red head must not
# buy a second rerun — the "no blind-rerun loop" criterion, as data.
C163_LG="$TMP/c163"
C163_ITEM="$(awk -F'\t' "$AWK_RED" <<<"$C163_ROW")"
t c163-first-tick-fires 1 "$(printf '%s\n' "$C163_ITEM" | ledger_filter "$C163_LG" | n)"
printf '%s\n' "$C163_ITEM" | ledger_commit "$C163_LG"
t c163-second-tick-quiet 0 "$(printf '%s\n' "$C163_ITEM" | ledger_filter "$C163_LG" | n)"
# A corrective push is a new head, and wakes regardless of how the oid sorts.
t c163-corrective-push-wakes 1 \
  "$(printf 'o/r#163@0000001\thead\n' | ledger_filter "$C163_LG" | n)"

# --- #168: preserve before removing ------------------------------------------
# Driven against real repositories — a real bare remote, a real clone, a real
# linked worktree — because every claim here is about what git actually did:
# what the pushed tree contains, whether the ref reached the REMOTE, and
# whether the worktree survived a push that failed. A text fixture proves none
# of that, and the defect this issue exists to prevent (a --force reached
# before the push confirms) is invisible to one.
P168="$TMP/p168"
mkdir -p "$P168"
P_BARE="" P_CLONE="" P_WT=""

_p168_fixture() { # $1=name -> a bare remote, a clone with origin, a worktree
  local name="$1"
  P_BARE="$P168/$name.git"; P_CLONE="$P168/$name"; P_WT="$P168/$name-wt"
  git init -q --bare "$P_BARE"
  git init -q "$P_CLONE"
  printf 'engine\n' >"$P_CLONE/README.md"
  printf 'ignored/\n' >"$P_CLONE/.gitignore"
  git -C "$P_CLONE" add -A
  git -C "$P_CLONE" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm fixture
  git -C "$P_CLONE" remote add origin "$P_BARE"
  git -C "$P_CLONE" worktree add "$P_WT" -b "build/$name" >/dev/null 2>&1
}

_p168_wip_refs() { git -C "$1" for-each-ref --format='%(refname)' refs/heads/wip | n; }

# The record's transport is post-once.sh, so the suite stubs it where the engine
# looks: BIN_DIR, pointed at this block's own bin and restored at the end. The
# stub records the (repo, number) it was called with and the exact body, which
# is what the dedup assertion below reads — post-once.sh's own idempotence is
# tested at post-once.sh; what is this module's to prove is that it hands over a
# body that does not change when nothing changed.
P168_BIN="$P168/bin"; mkdir -p "$P168_BIN"
export P168_PO_CALLS="$P168/po-calls" P168_PO_BODY="$P168/po-body" P168_PO_RC=0
: >"$P168_PO_CALLS"; : >"$P168_PO_BODY"
cat >"$P168_BIN/post-once.sh" <<'P168PO'
#!/usr/bin/env bash
printf '%s#%s\n' "$1" "$2" >>"$P168_PO_CALLS"
printf '%s' "$3" >"$P168_PO_BODY"
exit "${P168_PO_RC:-0}"
P168PO
chmod +x "$P168_BIN/post-once.sh"
P168_BIN_SAVED="$BIN_DIR"
BIN_DIR="$P168_BIN"

# The remote a preservation goes to. `fork` where the clone has one — the bot
# cannot write to upstream, and a push that is always refused earns no force
# and preserves nothing — else `origin`, the single-remote case, which the
# amended spec still describes ("a remote the pushing identity can actually
# write to"). Triage ruled the preference in on 2026-08-05: `origin` on a fleet
# box is unwritable, so the criterion as first written was unsatisfiable.
_p168_fixture remote-choice
t p168-remote-origin-when-alone origin "$(_wt_preserve_remote "$P_CLONE")"
git -C "$P_CLONE" remote add fork "$P168/fork.git"
t p168-remote-prefers-fork fork "$(_wt_preserve_remote "$P_CLONE")"
git -C "$P_CLONE" remote remove fork
git -C "$P_CLONE" remote remove origin
if _wt_preserve_remote "$P_CLONE" >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-remote-none-refuses refused "$r1"

# 1. Real uncommitted work: modified tracked AND untracked, ignored dirt left
# out. Asserted from the BARE repo throughout — the must-fail is a
# preservation that lands only locally, and reading the clone's own objects
# would pass while the remote holds nothing.
_p168_fixture dirty
printf 'changed\n' >"$P_WT/README.md"
printf 'rescue me\n' >"$P_WT/untracked.txt"
mkdir -p "$P_WT/ignored"; printf 'noise\n' >"$P_WT/ignored/x"
P_STATUS_BEFORE="$(git -C "$P_WT" status --porcelain | sort)"
if P_OUT="$(_wt_preserve "$P_WT" build/dirty)"; then r1=pushed; else r1=REFUSED; fi
t p168-dirty-preserved pushed "$r1"
t p168-ref-is-on-the-remote 1 "$(_p168_wip_refs "$P_BARE")"
P_REMOTE_TREE="$(git -C "$P_BARE" ls-tree -r --name-only refs/heads/wip/build/dirty | sort)"
case "$P_REMOTE_TREE" in *untracked.txt*) r1=carried ;; *) r1=DROPPED ;; esac
t p168-ref-carries-untracked carried "$r1"
t p168-ref-carries-modified changed \
  "$(git -C "$P_BARE" show refs/heads/wip/build/dirty:README.md)"
case "$P_REMOTE_TREE" in *ignored/x*) r1=LEAKED ;; *) r1=excluded ;; esac
t p168-ref-excludes-ignored excluded "$r1"
# The capture is built in a scratch index, so the worktree it captured is
# byte-identical afterwards: nothing staged, nothing stashed, nothing checked
# out. A push that fails must leave the tree exactly as it was found, and this
# is the property that makes that true.
t p168-capture-leaves-worktree-untouched "$P_STATUS_BEFORE" \
  "$(git -C "$P_WT" status --porcelain | sort)"
t p168-capture-leaves-content-untouched 'rescue me' "$(cat "$P_WT/untracked.txt")"

# Idempotence: the same dirt preserved twice is one ref at one sha. The second
# pass reads the remote, finds its own tree already there, and treats that as
# the confirmation it is — never a second commit, and never the
# non-fast-forward such a commit would be refused as.
if P_OUT2="$(_wt_preserve "$P_WT" build/dirty)"; then r1=confirmed; else r1=REFUSED; fi
t p168-rerun-still-confirms confirmed "$r1"
t p168-rerun-pushes-nothing-new "$P_OUT" "$P_OUT2"
t p168-rerun-leaves-one-ref 1 "$(_p168_wip_refs "$P_BARE")"

# Dirt that CHANGED between passes is new work, and the ref moves to it — the
# new commit is parented on what the remote already holds, so the push is a
# fast-forward rather than a rejection that would strand the worktree.
printf 'later\n' >"$P_WT/second.txt"
if P_OUT3="$(_wt_preserve "$P_WT" build/dirty)"; then r1=pushed; else r1=REFUSED; fi
t p168-new-dirt-preserved pushed "$r1"
case "$P_OUT3" in "$P_OUT") r1=STALE ;; *) r1=advanced ;; esac
t p168-new-dirt-advances-the-ref advanced "$r1"
case "$(git -C "$P_BARE" ls-tree -r --name-only refs/heads/wip/build/dirty)" in
  *second.txt*) r1=carried ;; *) r1=DROPPED ;;
esac
t p168-new-dirt-carries-the-new-file carried "$r1"

# The capture's own refusal, reached directly. `_wt_preserve` refuses when what
# it captured is HEAD's own tree — nothing was at risk — and that path is
# otherwise only reachable when a removal refuses for a reason that leaves the
# tree unchanged (a locked worktree), so it is exercised here rather than left
# to the one shape that happens to reach it. The refusal is what denies the
# caller its force, and a refusal that pushed anyway would earn a force it
# cannot explain: both halves are asserted.
_p168_fixture nothing-at-risk
mkdir -p "$P_WT/ignored"; printf 'noise\n' >"$P_WT/ignored/x"
if _wt_preserve "$P_WT" build/nothing-at-risk >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-ignored-only-capture-refuses refused "$r1"
t p168-ignored-only-capture-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"
rm -rf "$P_WT/ignored"
if _wt_preserve "$P_WT" build/nothing-at-risk >/dev/null; then r1=CLAIMED; else r1=refused; fi
t p168-clean-capture-refuses refused "$r1"
t p168-clean-capture-pushes-nothing 0 "$(_p168_wip_refs "$P_BARE")"

# --- #151: AUTO_APPROVE_REREQUEST gates the APPROVE, never the re-request -----
# The flag sat in front of the whole timestamp comparison, so auto=0 collapsed
# both branches to skip: a standing block plus a newer re-request at an
# unchanged head was answered `skip` every tick, forever, and the round could
# not converge (ceremony#207, 37 minutes, cleared by hand). The suite had the
# hole too — five transitions pinned at auto=1 and exactly one at auto=0, and
# that one was the APPROVED case, so nothing asked what a live block did with
# the flag off. The flag now decides one thing only: approve, or queue a real
# review. Whether a newer re-request is consulted at all is not its business.
t rereq-auto-off-block-queues-not-skips  queue        "$(rereq_decision "$RR_H" "$RR_H" CHANGES_REQUESTED "$RR_T1" "$RR_T2" 0)"
t rereq-auto-off-dismissed-queues        queue        "$(rereq_decision "$RR_H" "$RR_H" DISMISSED "$RR_T1" "$RR_T2" 0)"
t rereq-auto-off-never-approves          queue        "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T1" "$RR_T2" 0)"
# Double-submit protection is untouched at BOTH flag values (#26/#29/#39): a
# request no newer than my verdict is the genuine mid-clear/stale-index case.
t rereq-auto-off-no-newer-request-skips  skip         "$(rereq_decision "$RR_H" "$RR_H" CHANGES_REQUESTED "$RR_T2" "$RR_T1" 0)"
t rereq-auto-off-no-request-at-all-skips skip         "$(rereq_decision "$RR_H" "$RR_H" CHANGES_REQUESTED "$RR_T1" - 0)"
t rereq-auto-off-moved-head-queues       queue        "$(rereq_decision "$RR_OLD" "$RR_H" CHANGES_REQUESTED "$RR_T1" "$RR_T2" 0)"

# --- #114: submit-verdict admits the queued round's verdict, still refuses a
# bare re-post. The compounding half of the bug: once duty-review routes a
# post-CHANGES_REQUESTED re-request to a real review session, that session's
# considered verdict is at the SAME head my old verdict already covers, so the
# (me, PR, head) coverage gate refused it — a WRONG approval became a SILENTLY
# dropped verdict. The gate is now keyed (me, PR, head, round). A stateful gh
# shim exercises the real gate end-to-end: GET reviews cats a JSON array, POST
# appends to it so mine_at_head's post-count rises, graphql returns the round's
# "<mine_at> <req_at>", the head is fixed. This block is ALSO the regression
# guard the issue names as "must fail": revert submit-verdict's re-key and
# Scenario 1 refuses the verdict (count stays 1) and goes red.
SV="$SHARED/bin/submit-verdict.sh"
SVSHIM="$TMP/sv-shim"; mkdir -p "$SVSHIM"
cat >"$SVSHIM/gh" <<'SHIM'
#!/usr/bin/env bash
set -eu
[ "$1" = api ] || exit 3
sub="$2"
case "$sub" in
  user)    printf '%s\n' "$SVSHIM_ME";    exit 0 ;;
  graphql) printf '%s\n' "$SVSHIM_ROUND"; exit 0 ;;
esac
is_post=0; cid=""; event=""
for a in "$@"; do
  [ "$a" = POST ] && is_post=1
  case "$a" in commit_id=*) cid="${a#commit_id=}" ;; event=*) event="${a#event=}" ;; esac
done
case "$sub" in
  */reviews)
    if [ "$is_post" = 1 ]; then
      case "$event" in APPROVE) st=APPROVED ;; REQUEST_CHANGES) st=CHANGES_REQUESTED ;; *) st="$event" ;; esac
      tmp="$(mktemp)"
      jq --arg me "$SVSHIM_ME" --arg st "$st" --arg cid "$cid" \
        '. + [{user:{login:$me},state:$st,commit_id:$cid}]' "$SVSHIM_REVIEWS" >"$tmp"
      mv "$tmp" "$SVSHIM_REVIEWS"
      printf '{}\n'; exit 0
    fi
    cat "$SVSHIM_REVIEWS"; exit 0 ;;
  repos/*/pulls/*) printf '%s\n' "$SVSHIM_HEAD"; exit 0 ;;
esac
exit 3
SHIM
chmod +x "$SVSHIM/gh"
SV_H="cccccccccccccccccccccccccccccccccccccccc"
SV_BODY="$TMP/sv-body.txt"; printf 'considered verdict\n' >"$SV_BODY"
sv_reviews() { printf '%s' "$1" >"$TMP/sv-reviews.json"; }
sv_count()   { jq 'length' "$TMP/sv-reviews.json"; }
sv_run() {  # <round-ts "mine req"> <verdict> [--supersede-own]
  local round="$1" verdict="$2"; shift 2
  SVSHIM_ME=kimi-bot SVSHIM_HEAD="$SV_H" SVSHIM_ROUND="$round" \
  SVSHIM_REVIEWS="$TMP/sv-reviews.json" PATH="$SVSHIM:$PATH" DUTY_DIR="$TMP" \
    bash "$SV" o/r 1 "$SV_H" "$verdict" "$SV_BODY" "$@" >/dev/null 2>&1
}
SV_CR="[{\"user\":{\"login\":\"kimi-bot\"},\"state\":\"CHANGES_REQUESTED\",\"commit_id\":\"$SV_H\"}]"
SV_AP="[{\"user\":{\"login\":\"kimi-bot\"},\"state\":\"APPROVED\",\"commit_id\":\"$SV_H\"}]"

# Scenario 1 (AC3): a standing CR at head + a re-request NEWER than it → the
# queued round's verdict is ADMITTED and lands (count 1 → 2), exit 0.
sv_reviews "$SV_CR"
if sv_run "2026-07-28T10:00:00Z 2026-07-28T11:00:00Z" request-changes; then r1=0; else r1=$?; fi
t submit-newround-admitted-rc 0 "$r1"
t submit-newround-verdict-landed 2 "$(sv_count)"

# Scenario 2 (AC4): a standing CR at head + NO newer re-request (my review is
# newer than the last request) → refused as already-present, no post (count 1).
sv_reviews "$SV_CR"
if sv_run "2026-07-28T11:00:00Z 2026-07-28T10:00:00Z" request-changes; then r1=0; else r1=$?; fi
t submit-bare-repost-rc 0 "$r1"
t submit-bare-repost-no-verdict 1 "$(sv_count)"

# Scenario 3: --supersede-own (the auto-approve path) never reaches the new
# gate — it still supersedes and lands regardless of round state (count 1 → 2).
sv_reviews "$SV_AP"
if sv_run "2026-07-28T11:00:00Z 2026-07-28T10:00:00Z" approve --supersede-own; then r1=0; else r1=$?; fi
t submit-supersede-still-lands-rc 0 "$r1"
t submit-supersede-still-lands 2 "$(sv_count)"

# --- crew host: one repo belongs to one fleet (#70) ----------------------
# The check consumes GitHub's shared board state, never another fleet's
# machine. Exercise it through `up --dry-run`: no box or registry mutation is
# needed to notice a foreign claim, and the same checkpoint runs for hire.
OFROOT="$TMP/overlap-fleet"
OFSHIM="$TMP/overlap-bin"
mkdir -p "$OFROOT" "$OFSHIM"
printf 'fixture-box claude builder\n' >"$OFROOT/fleet.roster"
printf 'fixture/overlap\n' >"$OFROOT/repos.txt"
printf 'FLEET_BENCH="local-reviewer"\nFLEET_TRIAGE="local-triage"\nFLEET_HUMAN="local-operator"\n' \
  >"$OFROOT/fleet.conf"
cat >"$OFSHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '[]\n' ;;
  *) exit 2 ;;
esac
EOF
cat >"$OFSHIM/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "${EVENT_PAYLOAD:-readable}:$*" in
  unreadable:*fixture/overlap*) printf '{"message":"API rate limit exceeded"}\n' ;;
  unreadable:*) printf '[{"type":"IssuesEvent","actor":{"login":"other-builder"},"payload":{"action":"assigned","assignee":{"login":"other-builder"}}}]\n' ;;
  empty:*) printf '[]\n' ;;
  readable:*) printf '[{"type":"IssuesEvent","actor":{"login":"local-triage"},"payload":{"action":"opened"}}]\n' ;;
  foreign:*) printf '[{"type":"IssuesEvent","actor":{"login":"%s"},"payload":{"action":"assigned","assignee":{"login":"%s"}}}]\n' \
        "$FOREIGN_ACTOR" "$FOREIGN_ACTOR" ;;
esac
EOF
REAL_JQ="$(command -v jq)"
export REAL_JQ
cat >"$OFSHIM/jq" <<'EOF'
#!/usr/bin/env bash
[ -z "${JQ_SUCCESS_STDERR:-}" ] || printf '%s\n' "$JQ_SUCCESS_STDERR" >&2
exec "$REAL_JQ" "$@"
EOF
chmod +x "$OFSHIM/box" "$OFSHIM/gh" "$OFSHIM/jq"
before_registry="$(cat "$OFROOT/repos.txt")"
GH_CALLS="$TMP/overlap-gh-calls"
overlap_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=foreign FOREIGN_ACTOR=other-builder GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$overlap_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/overlap"*) r1=named ;;
  *) r1=SILENT ;;
esac
t fleet-overlap-names-repo-and-foreign-actor named "$r1"
case "$overlap_out" in *"registries LEFT UNCHANGED"*"operators must decide"*) r1=operator ;; *) r1=actioned ;; esac
t fleet-overlap-resolution-is-operator operator "$r1"
t fleet-overlap-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

stderr_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=foreign FOREIGN_ACTOR=other-builder \
  JQ_SUCCESS_STDERR='synthetic jq warning' GH_CALLS="$GH_CALLS" PATH="$OFSHIM:$PATH" \
  bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$stderr_out" in *"synthetic jq warning"*) r1=CONTAMINATED ;; *) r1=isolated ;; esac
t fleet-overlap-successful-jq-stderr-is-not-data isolated "$r1"
case "$stderr_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/overlap"*) r1=preserved ;;
  *) r1=LOST ;;
esac
t fleet-overlap-successful-jq-stderr-preserves-data preserved "$r1"

disjoint_out="$(env CREW_CONFIG_DIR="$OFROOT" GH_CALLS="$GH_CALLS" PATH="$OFSHIM:$PATH" \
  bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$disjoint_out" in *"WARN one-repo-one-fleet"*) r1=NOISY ;; *) r1=silent ;; esac
t fleet-disjoint-is-silent silent "$r1"
t fleet-disjoint-does-not-edit-registry "$before_registry" "$(cat "$OFROOT/repos.txt")"

printf 'fixture/overlap\nfixture/zlater\n' >"$OFROOT/repos.txt"
if unreadable_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=unreadable GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"; then
  r1=survived
else
  r1=FAILED
fi
t fleet-overlap-unreadable-payload-survives survived "$r1"
case "$unreadable_out" in
  *"NOTE one-repo-one-fleet: unreadable recent board activity for fixture/overlap"*"overlap detection skipped"*) r1=named ;;
  *) r1=SILENT ;;
esac
t fleet-overlap-unreadable-payload-names-repo named "$r1"
case "$unreadable_out" in
  *"WARN one-repo-one-fleet: foreign claim by @other-builder in registered repo fixture/zlater"*) r1=continued ;;
  *) r1=STOPPED ;;
esac
t fleet-overlap-unreadable-payload-continues continued "$r1"

empty_out="$(env CREW_CONFIG_DIR="$OFROOT" EVENT_PAYLOAD=empty GH_CALLS="$GH_CALLS" \
  PATH="$OFSHIM:$PATH" bash "$ROOT/cli/crew" up --dry-run 2>&1)"
case "$empty_out" in *"one-repo-one-fleet"*) r1=NOISY ;; *) r1=silent ;; esac
t fleet-overlap-empty-array-is-silent silent "$r1"
printf 'fixture/overlap\n' >"$OFROOT/repos.txt"
if grep -q 'repos/fixture/outside/events' "$GH_CALLS"; then r1=QUERIED; else r1=silent; fi
t fleet-out-of-scope-activity-is-not-queried silent "$r1"

# --- valid_version: ONE gate, in install.sh and cli/crew, must not drift.
# The installer builds versions/<v> paths from a version, and cli/crew builds
# them for `crew use`/`uninstall` (heavy-duty/crew#96); a divergence is how a
# crafted version slips past one gate and into an rm/ln behind the other. box's
# test/cli.sh diffs its pair the same way. Assert the two copies are
# byte-identical, then drive the gate against the path-escaping shapes it exists
# to refuse.
vv_extract() { awk '/^valid_version\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$1"; }
t valid_version-parity "$(vv_extract "$ROOT/install.sh")" "$(vv_extract "$ROOT/cli/crew")"
eval "$(vv_extract "$ROOT/cli/crew")"
for bad in "" "." ".hidden" "-rf" "../evil" "a/b" "a b" "a;b"; do
  if valid_version "$bad"; then got=accept; else got=reject; fi
  t "valid_version-refuses[$bad]" reject "$got"
done
for ok in "0.1.0" "0.1.0-dev" "0.1.0-rc1" "1.2.3+meta"; do
  if valid_version "$ok"; then got=accept; else got=reject; fi
  t "valid_version-accepts[$ok]" accept "$got"
done

# --- convergence: rig's role marker, parsed (crew#220) ----------------------
# `crew hire` is crew's irreversible verb — it installs the engine and arms
# cron — and since #220 the thing that authorizes it is this parse. A box whose
# tenant role never converged was indistinguishable from a healthy one in every
# column crew had, so the marker became the discriminator; what the marker MEANS
# is decided here, in eight lines that no fixture fleet can exercise fully.
#
# Extracted and eval'd out of cli/crew, the same way valid_version above is:
# these are the shapes a real /etc/rig/role takes (heavy-duty/rig,
# commands/bootstrap-tenant.sh writes the tenant line, commands/bootstrap.sh
# the machine one) plus the hand-edited near-misses, and a stub box can only
# ever answer with one of them at a time.
# vv_extract above assumes a multi-line body, which is fine for the one
# function it takes. report_field is a ONE-LINER, and on that shape a
# stop-at-`^}` rule never fires on its own line — it runs on to the next
# function's closing brace and evals that too. It happened to be harmless here,
# which is exactly the kind of silence that stops being harmless the day
# somebody inserts a function between the two. So this one closes on its own
# line when the definition is self-contained.
cv_extract() { awk -v f="$2" '
  $0 ~ "^"f"\\(\\) \\{" { print; if ($0 ~ /\}[[:space:]]*$/) exit; p=1; next }
  p { print; if ($0 ~ /^\}$/) exit }
' "$1"; }
eval "$(cv_extract "$ROOT/cli/crew" report_field)"
eval "$(cv_extract "$ROOT/cli/crew" marker_fault)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_of)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_detail)"
eval "$(cv_extract "$ROOT/cli/crew" convergence_recovery)"
# An extraction that came back empty leaves every assertion below testing a
# function that does not exist — and `t` between two empty strings passes. The
# suite would report the gate as covered while executing none of it, which is
# the same shape of silence the manifest parse sat in. Say so once, here.
cv_lifted=""
for cv_f in report_field marker_fault convergence_of convergence_detail convergence_recovery; do
  declare -F "$cv_f" >/dev/null || cv_lifted="$cv_lifted $cv_f"
done
t convergence-functions-lifted "" "$cv_lifted"

# A box that answered NOTHING is `unknown`, and unknown is not converged. This
# is rule 5 of #220's spec and the whole safety property: the defect closed is a
# broken box passing for a healthy one, so the case crew cannot see into must
# refuse rather than proceed. An empty capture is what an unreachable box, a
# stopped box and a `box exec` that died all produce.
t convergence-empty-capture-is-unknown unknown "$(convergence_of "")"
t convergence-no-probe-line-is-unknown unknown "$(convergence_of "marker=role=claude-box tenant=yes host=no")"

# Answered, and rig never wrote a marker: the reported case. The bootstrap
# failed, so the vendor CLI was never installed.
t convergence-answered-without-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\n')")"
t convergence-empty-marker-value-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=\n')")"

# The tenant line rig actually writes.
t convergence-tenant-marker-is-converged converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box tenant=yes host=no\n')")"
# …for every agent in the bench, since the role name is data and not a fixed set.
for cv_agent in claude codex grok kimi; do
  t "convergence-tenant-marker[$cv_agent]" converged \
    "$(convergence_of "$(printf 'probe=ok\nmarker=role=%s-box tenant=yes host=no\n' "$cv_agent")")"
done
# Hand-edited with tabs or doubled spaces reads the same way, rather than
# silently failing to match — whitespace is normalised before the field test,
# exactly as rig's own root_door_of does it.
t convergence-tenant-marker-tabs-are-normalised converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box\ttenant=yes\thost=no\n')")"
t convergence-tenant-marker-double-space-is-normalised converged \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box  tenant=yes  host=no\n')")"

# A MACHINE marker is not an agent tenant. rig writes this shape for the
# `-server` roles and for a guest joined as a workload; a crew member is a box
# guest converged by the tenant bootstrap, and nothing else installed its
# vendor CLI.
t convergence-machine-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=workload-server root-door=open host=no join=yes join-by=rig\n')")"
t convergence-host-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role=staging-server root-door=closed host=yes join=yes join-by=rig\n')")"

# HALF A MARKER is not a converged box. #220 pins the verdict on both fields —
# "parses to a non-empty `role=`, and carries `tenant=yes`" — and rig writes the
# two in one line, so a marker with one and not the other is a box interrupted
# partway through converging. Reading it as converged would hire on the strength
# of the half that happened to land.
t convergence-refuses-marker-without-a-role incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=tenant=yes host=no\n')")"
t convergence-refuses-empty-role-field incomplete \
  "$(convergence_of "$(printf 'probe=ok\nmarker=role= tenant=yes host=no\n')")"
case "$(convergence_detail "$(printf 'probe=ok\nmarker=tenant=yes host=no\n')")" in
  *"no role="*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-half-written-marker named "$r1"

# The verdict and the reason are ONE reader, so they cannot drift apart. A row
# reading INCOMPLETE beside a detail saying nothing is missing is a refusal an
# operator cannot act on, and that is what two copies of this parse decay into.
cv_disagree=""
for cv_m in 'role=claude-box tenant=yes host=no' 'role=workload-server root-door=open host=no' \
            'role= tenant=yes host=no' 'tenant=yes' 'role=claude-box tenant=yesish'; do
  cv_v="$(convergence_of "$(printf 'probe=ok\nmarker=%s\n' "$cv_m")")"
  cv_d="$(convergence_detail "$(printf 'probe=ok\nmarker=%s\n' "$cv_m")")"
  case "$cv_v:$cv_d" in
    converged:*|incomplete:?*) : ;;
    *) cv_disagree="$cv_disagree [$cv_m -> $cv_v / ${cv_d:-<silence>}]" ;;
  esac
done
t convergence-verdict-and-detail-agree "" "$cv_disagree"

# MUST FAIL — the field-anchoring. rig#77 is the scar: an unanchored pattern let
# `root-door=closedish` resolve as `closed` and pass the one gate authorizing an
# irreversible act. Hiring is crew's irreversible act, so a value that merely
# EXTENDS `yes`, or a key that merely ENDS in `tenant`, must not authorize it.
for cv_bad in "tenant=yesish" "tenant=yes-not" "xtenant=yes" "no-tenant=yes" "tenant=no" "tenant=YES"; do
  t "convergence-refuses-near-miss[$cv_bad]" incomplete \
    "$(convergence_of "$(printf 'probe=ok\nmarker=role=claude-box %s host=no\n' "$cv_bad")")"
done

# The three causes take three different actions, so the detail must name which
# one it is. Collapsing them into "not converged" throws away the only part of
# the refusal an operator can act on.
case "$(convergence_detail "")" in
  *"did not answer"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-unreadable-case named "$r1"
case "$(convergence_detail "$(printf 'probe=ok\n')")" in
  *"/etc/rig/role"*"never converged"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-names-the-missing-marker named "$r1"
case "$(convergence_detail "$(printf 'probe=ok\nmarker=role=workload-server root-door=open host=no\n')")" in
  *"machine role"*"role=workload-server"*) r1=named ;; *) r1=VAGUE ;;
esac
t convergence-detail-quotes-the-machine-marker named "$r1"

# The recovery is the three commands `box` itself prints when the bootstrap
# hook fails, and it names the box's OWN tenant — a generic one is a command
# that fails when pasted.
t convergence-recovery-names-the-tenant \
  "box shell kimi-reviewer → sudo rig bootstrap kimi-box → box snapshot kimi-reviewer bootstrapped" \
  "$(convergence_recovery kimi-reviewer kimi)"
# An off-roster box names no agent. A placeholder an operator can fill in beats
# a malformed `rig bootstrap -box`.
case "$(convergence_recovery adhoc-box "")" in
  *"rig bootstrap <agent>-box"*) r1=placeholder ;; *) r1=MALFORMED ;;
esac
t convergence-recovery-without-an-agent-is-a-placeholder placeholder "$r1"
# It must never advise the verb that caused the incident. `crew hire` on a box
# the table told the operator to hire is the whole of #220.
case "$(convergence_recovery kimi-reviewer kimi)" in
  *"crew hire"*) r1=ADVISES_HIRE ;; *) r1=bootstrap ;;
esac
t convergence-recovery-does-not-advise-crew-hire bootstrap "$r1"

# --- convergence: rig's marker and manifest, as the real files (crew#220) ---
# THE REAL TEXT, not a fixture format. Read on 2026-08-01 from inside a
# rig-converged tenant box — the box this branch was built in, which is itself
# a rig box — with the files written by rig 0.3.2-dev on the same day:
#
#     $ ls -l /etc/rig/
#     -rw-r--r-- 1 root root 129 Aug  1 12:31 manifest
#     -rw-r--r-- 1 root root  35 Aug  1 12:31 role
#     $ cat /etc/rig/role
#     role=claude-box tenant=yes host=no
#     $ cat /etc/rig/manifest
#     schema=1
#     bootstrapped_by=0.3.2-dev
#     bootstrapped_at=2026-08-01T12:31:11Z
#     converged_by=0.3.2-dev
#     converged_at=2026-08-01T12:31:11Z
#
# The parse is asserted against THAT, byte for byte, rather than against a
# shape read out of rig's source: reading the writer tells you what rig means
# to emit, and only the artifact tells you what it emitted. Both files are
# 0644, which is the other fact this read establishes — crew's exec must not
# grow a `sudo`, because a `sudo` in a non-interactive `box exec` is itself a
# way to turn a converged box into a false INCOMPLETE.
cv_real_role='role=claude-box tenant=yes host=no'
cv_real_manifest="$(printf '%s\n' \
  'schema=1' \
  'bootstrapped_by=0.3.2-dev' \
  'bootstrapped_at=2026-08-01T12:31:11Z' \
  'converged_by=0.3.2-dev' \
  'converged_at=2026-08-01T12:31:11Z')"
# …assembled into the capture rig_report produces from them: `probe=ok`, the
# marker's first line, and the manifest prefixed a line at a time. The box side
# does no interpreting precisely so that this — the part that decides meaning —
# is reachable from here.
cv_real_report="$(printf 'probe=ok\nmarker=%s\n%s\n' "$cv_real_role" \
  "$(printf '%s\n' "$cv_real_manifest" | sed 's|^|rig:|')")"

t convergence-real-marker-is-converged converged "$(convergence_of "$cv_real_report")"
t convergence-real-manifest-converged-by 0.3.2-dev \
  "$(report_field rig:converged_by "$cv_real_report")"
t convergence-real-manifest-converged-at 2026-08-01T12:31:11Z \
  "$(report_field rig:converged_at "$cv_real_report")"
# The namespace, and the `^` that makes it real. `schema=1` unprefixed would
# answer a `report_field schema` somebody adds later; prefixed, and read with an
# anchor, it cannot. Drop the `^` from report_field and this is the assertion
# that reds — the namespace becomes decoration.
t convergence-real-manifest-keys-are-namespaced "" "$(report_field schema "$cv_real_report")"
t convergence-real-marker-survives-the-manifest "$cv_real_role" \
  "$(report_field marker "$cv_real_report")"

# MUST FAIL — the manifest's own `closedish`, and it is a NAMING discipline
# rather than an anchoring one. rig puts `bootstrapped_by=`/`bootstrapped_at=`
# TWO LINES ABOVE the `converged_*` pair, so any read that goes after the
# FAMILY — `.*_at=`, "grab the timestamp" — answers with the bootstrap's, which
# is the date the box was first built rather than the one that authorized the
# hire. The guard is that every read names the whole key. On the real text
# above the two pairs are equal, which is exactly why that text cannot catch it
# alone: this is the same box re-converged later by a newer rig, where they
# differ and the wrong answer is visible.
cv_reconverged="$(printf 'probe=ok\nmarker=%s\n%s\n' "$cv_real_role" "$(printf '%s\n' \
  'rig:schema=1' \
  'rig:bootstrapped_by=0.3.1' \
  'rig:bootstrapped_at=2026-07-04T08:00:00Z' \
  'rig:converged_by=0.3.2-dev' \
  'rig:converged_at=2026-08-01T12:31:11Z')")"
t convergence-converged-by-is-not-bootstrapped-by 0.3.2-dev \
  "$(report_field rig:converged_by "$cv_reconverged")"
t convergence-converged-at-is-not-bootstrapped-at 2026-08-01T12:31:11Z \
  "$(report_field rig:converged_at "$cv_reconverged")"
# …and from the other direction: a PARTIAL key name gets nothing. `verged_at`
# is a tail of `converged_at`, and a read loose enough to accept it is a read
# loose enough to accept `bootstrapped_at` too — same defect, cheaper to see.
t convergence-read-refuses-a-suffix-key "" \
  "$(report_field rig:verged_at "$cv_reconverged")"

# CORROBORATING, NEVER LOAD-BEARING. A box whose rig predates the manifest
# (rig#61) has a valid role line and no provenance at all — old, not broken.
# Gating the verdict on `converged_at` would turn every box on that rig into a
# refusal, which #220's test plan names as the outcome worse than the bug.
cv_no_manifest="$(printf 'probe=ok\nmarker=%s\n' "$cv_real_role")"
t convergence-without-a-manifest-is-still-converged converged "$(convergence_of "$cv_no_manifest")"
t convergence-without-a-manifest-reports-no-provenance "" \
  "$(report_field rig:converged_by "$cv_no_manifest")"
# …and the inverse must not rescue anything: a full manifest beside a role file
# that never got written is still INCOMPLETE. The manifest cannot vouch for a
# convergence the marker does not claim.
t convergence-manifest-without-a-marker-is-incomplete incomplete \
  "$(convergence_of "$(printf 'probe=ok\n%s\n' "$(printf '%s\n' "$cv_real_manifest" | sed 's|^|rig:|')")")"

# The marker path is rig's, and it is not crew's to invent. Asserted against the
# source so a refactor that "tidies" it to a crew-shaped path is caught here
# rather than on a real host — crew reads what rig writes, and rig writes these
# two (rig#61 for the manifest).
if grep -q '/etc/rig/role' "$ROOT/cli/crew" && grep -q '/etc/rig/manifest' "$ROOT/cli/crew"; then
  r1=rigs
else
  r1=INVENTED
fi
t convergence-reads-rigs-own-paths rigs "$r1"

# Both files are 0644 on a real box, so the read takes no privilege — and must
# never acquire one. A `sudo` in a NON-INTERACTIVE `box exec` prompts, or fails,
# and either way turns a converged box into a false INCOMPLETE: the refusal
# would then be crew's own doing, on a box that was fine.
rig_report_source="$(cv_extract "$ROOT/cli/crew" rig_report)"
if grep -q 'sudo' <<<"$rig_report_source"; then
  r1=ESCALATES
else
  r1=unprivileged
fi
t convergence-reads-the-marker-without-sudo unprivileged "$r1"
# …and it goes through bxn, never a fresh literal `box exec`. This helper runs
# inside `while read … done < <(read_roster)` in status, hire-all and up, and a
# raw exec there drains the roster FIFO and converges ONE box out of N with
# rc=0 (#48). bxn is the only shape that pins stdin to /dev/null.
if grep -qE '^[[:space:]]*bxn ' <<<"$rig_report_source" &&
   ! grep -q 'box exec' <<<"$rig_report_source"; then
  r1=bxn
else
  r1=RAW_EXEC
fi
t convergence-reads-the-marker-through-bxn bxn "$r1"

# --- cli/crew's self-description: the table is the source of truth (#97) ----
# The property under test is ANTI-DRIFT, not cosmetics. Before #97 the command
# list lived three times — the header comment printed as help, a hand-written
# dispatch case, and each verb's usage string — and it had already diverged.
# These assertions are what make "the help cannot drift from the code" a fact
# rather than a comment.
CLIBIN="$ROOT/cli/crew"
CLISHIM="$TMP/cli-bin"
mkdir -p "$CLISHIM"
cat >"$CLISHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '[]\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CLISHIM/box"
crewcli() { PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@"; }
crewrc()  { PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" >/dev/null 2>&1; echo $?; }

# Every row's function EXISTS. This is the assertion that makes the table safe
# to dispatch from: a row naming a function nobody wrote is a runtime
# "command not found" on a verb the help advertises.
missing_fn=""
while IFS='^' read -r verb _ _ fn; do
  [ -n "$verb" ] || continue
  grep -q "^$fn()" "$CLIBIN" || missing_fn="$missing_fn $verb->$fn"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-table-functions-exist "" "$missing_fn"

# Every row has a summary — an empty one renders a blank line in `crew help`,
# which is how a verb becomes invisible while still being dispatchable.
empty_sum=""
while IFS='^' read -r verb _ sum _; do
  [ -n "$verb" ] || continue
  [ -n "$sum" ] || empty_sum="$empty_sum $verb"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-table-summaries-present "" "$empty_sum"

# ...and the REVERSE, which is the direction that actually rots: a verb
# implemented but never added to the table. The first version of this suite
# only checked table -> function, so a `cmd_usage` added by a later PR would
# have been dispatchable-by-nobody and invisible in `crew help` with every
# assertion green. Found while rebasing onto #95, which is exactly when a
# sibling PR could have introduced one.
orphan=""
while read -r fn; do
  grep -qF "^$fn\"" "$CLIBIN" || orphan="$orphan $fn"
done < <(grep -oE '^cmd_[a-z_]+\(\)' "$CLIBIN" | sed 's/()//')
t cli-every-verb-has-a-table-row "" "$orphan"

# Every verb appears in `crew help`, and `crew help <verb>` works for each.
help_all="$(crewcli help 2>&1)"
absent="" helpfail=""
while IFS='^' read -r verb _ _ _; do
  [ -n "$verb" ] || continue
  case "$help_all" in *"  $verb "*) : ;; *) absent="$absent $verb" ;; esac
  [ "$(crewrc help "$verb")" = 0 ] || helpfail="$helpfail $verb"
done < <(sed -n '/^CMDS=(/,/^)/p' "$CLIBIN" | sed -n 's/^  "\(.*\)"$/\1/p')
t cli-help-lists-every-verb "" "$absent"
t cli-help-per-command-works "" "$helpfail"

# The two exit codes, which is the whole reason for the split: a caller must
# be able to tell "you typo'd" from "the fleet is broken".
t cli-unknown-command-is-2   2 "$(crewrc nonsensecommand)"
t cli-missing-arg-is-2       2 "$(crewrc hire)"
t cli-unknown-flag-is-2      2 "$(crewrc floor --bogus)"
t cli-flag-before-verb-is-2  2 "$(crewrc --dry-run up)"
t cli-absent-box-is-1        1 "$(crewrc status nosuchbox)"
t cli-help-is-0              0 "$(crewrc help)"
t cli-version-is-0           0 "$(crewrc --version)"

# A value-taking flag with NO value is a malformed invocation, so it must exit
# 2 like every other one — not die through bash's own `set -u` unbound-variable
# handler at exit 1, which is what `$2` and `${2:?...}` both did (codex, review
# of #106). Every value-taking option on every verb, because the defect was
# per-site and so is the fix.
badval=""
for spec in "new --role" "new --agent" "new --name" "new --from" \
            "hire b --role" "hire b --agent" "hire b --ref" "hire-all --ref" \
            "floor --port" "floor --bind" "floor --user" "floor --pass" \
            "floor --interval" "floor --roster"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || badval="$badval [$spec->$rc]"
done
t cli-missing-option-value-is-2 "" "$badval"

# ...and an EMPTY value is refused the same way, which is what the `${2:?}`
# sites already did and what the plain `$2` sites silently accepted.
t cli-empty-option-value-is-2 2 "$(crewrc new --agent "")"

# An unknown flag on the two one-liner parsers was SILENTLY IGNORED — worse
# than the wrong exit code, because `crew hire-all --dry-run` hired the whole
# fleet while reading like a rehearsal.
t cli-hire-all-unknown-flag-is-2 2 "$(crewrc hire-all --dry-run)"
t cli-up-unknown-flag-is-2       2 "$(crewrc up --bogus)"
t cli-up-dry-run-still-works     0 "$(crewrc up --dry-run)"

# `up --dry-run` must describe the hire that follows a create (#218). Drive a
# mixed roster through the real CLI in both modes: the box shim records the
# convergence probe at the top of every real hire_box call, giving the
# equality property without copying cmd_up's roster arithmetic into the test.
UPCONF="$TMP/up-dry-run-config"
UPSHIM="$TMP/up-dry-run-bin"
UPSTATE="$TMP/up-dry-run-state"
UPCALLS="$TMP/up-dry-run-calls"
UP_VERSION="$(head -1 "$ROOT/VERSION" | tr -d '\r\n')"
mkdir -p "$UPCONF" "$UPSHIM"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$UPCONF/"
cat >"$UPCONF/fleet.roster" <<'EOF'
fresh claude builder
running codex reviewer
stopped kimi reviewer
EOF
cat >"$UPSHIM/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat >"$UPSHIM/box" <<'EOF'
#!/usr/bin/env bash
json_state() {
  awk 'BEGIN { printf "[" } { printf "%s{\"name\":\"%s\",\"status\":\"%s\"}", sep, $1, $2; sep="," } END { print "]" }' "$UPSTATE"
}
case "$1" in
  list) json_state ;;
  info)
    state="$(awk -v name="$2" '$1 == name { print $2; exit }' "$UPSTATE")"
    printf '[{"name":"%s","status":"%s"}]\n' "$2" "$state"
    ;;
  new)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s running\n' "$name" >>"$UPSTATE"
    printf 'mutate:new:%s\n' "$name" >>"$UPCALLS"
    ;;
  start)
    printf 'mutate:start:%s\n' "$2" >>"$UPCALLS"
    ;;
  exec)
    name="$2"
    script="${*: -1}"
    case "$script" in
      *'/etc/rig/role'*)
        printf 'hire:%s\n' "$name" >>"$UPCALLS"
        printf 'probe=ok\nmarker=role=fixture tenant=yes host=no\n'
        ;;
      *'engine-manifest.sh'*)
        printf 'engine:%s\n' "$name" >>"$UPCALLS"
        printf 'state=current\nstamp=crew@%s fixture\nrecorded=crew@%s fixture\n' "$UP_VERSION" "$UP_VERSION"
        ;;
      *'repos.txt'*) printf 'fixture/operator-repo\n' ;;
      *) printf 'exec:%s\n' "$name" >>"$UPCALLS" ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$UPSHIM/gh" "$UPSHIM/box"
up_reset() {
  printf 'running running\nstopped stopped\n' >"$UPSTATE"
  : >"$UPCALLS"
}
up_run() {
  env CREW_CONFIG_DIR="$UPCONF" UPSTATE="$UPSTATE" UPCALLS="$UPCALLS" UP_VERSION="$UP_VERSION" \
    PATH="$UPSHIM:$PATH" bash "$CLIBIN" up "$@"
}

: >"$UPSTATE"
: >"$UPCALLS"
if up_new_out="$(up_run --dry-run 2>&1)"; then up_new_rc=0; else up_new_rc=$?; fi
t cli-up-dry-run-all-new-exits-zero 0 "$up_new_rc"
t cli-up-dry-run-all-new-reports-every-create 3 \
  "$(grep -c ': WOULD create ' <<<"$up_new_out" || true)"
t cli-up-dry-run-all-new-reports-every-hire 3 \
  "$(grep -c ": WOULD hire (new box — engine crew@$UP_VERSION, cron armed)$" <<<"$up_new_out" || true)"
case "$up_new_out" in
  *'up --dry-run: 3 would be created, 0 started, 3 hired'*) r1=complete ;;
  *) r1="$up_new_out" ;;
esac
t cli-up-dry-run-all-new-summary complete "$r1"
t cli-up-dry-run-all-new-touches-nothing "" "$(cat "$UPCALLS")"

up_reset
if up_dry_out="$(up_run --dry-run 2>&1)"; then up_dry_rc=0; else up_dry_rc=$?; fi
t cli-up-dry-run-mixed-exits-zero 0 "$up_dry_rc"
t cli-up-dry-run-new-box-hires 1 \
  "$(grep -c "^fresh: WOULD hire (new box — engine crew@$UP_VERSION, cron armed)$" <<<"$up_dry_out" || true)"
t cli-up-dry-run-existing-wording 2 \
  "$(grep -c ": WOULD hire (currently: crew@$UP_VERSION fixture)$" <<<"$up_dry_out" || true)"
case "$up_dry_out" in
  *'up --dry-run: 1 would be created, 1 started, 3 hired'*) r1=complete ;;
  *) r1="$up_dry_out" ;;
esac
t cli-up-dry-run-summary complete "$r1"
t cli-up-dry-run-does-not-mutate "" "$(grep '^mutate:' "$UPCALLS" || true)"
t cli-up-dry-run-does-not-probe-new-box "" "$(grep ':fresh$' "$UPCALLS" || true)"
dry_hires="$(grep -c ': WOULD hire ' <<<"$up_dry_out" || true)"

up_reset
if up_run >/dev/null 2>&1; then up_real_rc=0; else up_real_rc=$?; fi
t cli-up-real-run-mixed-exits-zero 0 "$up_real_rc"
t cli-up-dry-run-hire-count-matches-real "$dry_hires" \
  "$(grep -c '^hire:' "$UPCALLS" || true)"
t cli-up-real-run-still-creates-and-starts 'mutate:new:fresh
mutate:start:stopped' "$(grep '^mutate:' "$UPCALLS" || true)"

# create-all is a fleet convergence verb: one failed box must not prevent the
# remaining roster rows from being attempted, and the final report is the
# operator's record of the partial run (#219).
CACONF="$TMP/create-all-config"
CASHIM="$TMP/create-all-bin"
CA_CALLS="$TMP/create-all-calls"
mkdir -p "$CACONF" "$CASHIM"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$CACONF/"
cat >"$CACONF/fleet.roster" <<'EOF'
one claude triage
two codex builder
three grok reviewer
four kimi reviewer
five claude reviewer
six codex reviewer
seven grok reviewer
EOF
cat >"$CASHIM/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf '%s\n' "${BOX_LIST:-[]}" ;;
  new)
    name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$name" >>"$CA_CALLS"
    [ "$name" != "${FAIL_NAME:-}" ]
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$CASHIM/box"
ca_run() {
  env CREW_CONFIG_DIR="$CACONF" CA_CALLS="$CA_CALLS" \
    BOX_LIST="${BOX_LIST:-[]}" FAIL_NAME="${FAIL_NAME:-}" \
    PATH="$CASHIM:$PATH" bash "$CLIBIN" create-all
}
BOX_LIST='[{"name":"three"}]' FAIL_NAME=four
: >"$CA_CALLS"
if ca_out="$(ca_run 2>&1)"; then ca_rc=0; else ca_rc=$?; fi
t cli-create-all-partial-is-nonzero 1 "$ca_rc"
t cli-create-all-continues-after-failure "one
two
four
five
six
seven" "$(cat "$CA_CALLS")"
case "$ca_out" in
  *"create-all: 5 created, 1 existing, 1 failed (four)."*) r1=complete ;;
  *) r1="$ca_out" ;;
esac
t cli-create-all-partial-summary complete "$r1"

# The all-pass path retains the established closing text byte-for-byte.
BOX_LIST='[]' FAIL_NAME=''
: >"$CA_CALLS"
if ca_all_out="$(ca_run 2>&1)"; then ca_all_rc=0; else ca_all_rc=$?; fi
t cli-create-all-all-pass-is-zero 0 "$ca_all_rc"
case "$ca_all_out" in
  *"7 created. Next: log each new box in by hand"*) r1=unchanged ;;
  *) r1="$ca_all_out" ;;
esac
t cli-create-all-all-pass-summary-unchanged unchanged "$r1"

# ...and `crew upgrade --bogus` took the flag as a BOX NAME, printing
# "upgrade FAILED on --bogus" and exiting 0 — a report, not a verdict (kimi).
t cli-upgrade-unknown-flag-is-2  2 "$(crewrc upgrade --bogus)"

# The mirror of the missing-value case: an argument BEYOND the synopsis was
# silently ignored. `crew help hire unexpected` printed hire's help and exited
# 0 (codex, round 2). The verbs with while-loop parsers already refused these;
# the ones reading "${1:-}" positionally never looked.
overrun=""
for spec in "help hire junk" "status a b" "profiles junk" "down junk" \
            "create-all junk" "gold a b c"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || overrun="$overrun [$spec->$rc]"
done
t cli-excess-arguments-are-2 "" "$overrun"
# ...and the accepted forms still work, so the guard cannot over-reach.
t cli-help-one-arg-still-ok  0 "$(crewrc help hire)"
t cli-help-no-arg-still-ok   0 "$(crewrc help)"

# resolve_engine's ref failures split the same way (codex, round 3). Three are
# invocation faults — a shape that can never be valid, a ref resolving to
# nothing, a ref in the wrong form for the mode — and exit 2. Shared by
# `hire --ref`, `hire-all --ref` and `upgrade --ref`, so assert it on each.
badref=""
for spec in "upgrade --all --ref -bad" "hire somebox --ref -bad" "hire-all --ref -bad" \
            "upgrade --all --ref nosuchref-xyz"; do
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  rc="$(crewrc $spec)"
  [ "$rc" = 2 ] || badref="$badref [$spec->$rc]"
done
t cli-malformed-ref-is-2 "" "$badref"

# A typo points somewhere rather than only failing.
case "$(crewcli hier 2>&1)" in *"did you mean 'hire'"*) r1=suggested ;; *) r1=SILENT ;; esac
t cli-typo-suggests suggested "$r1"

# --version names the version AND the root: with two installs on PATH, the
# root is how you settle which crew you just ran.
ver_out="$(crewcli --version 2>&1)"
case "$ver_out" in "crew $(head -1 "$ROOT/VERSION" | tr -d '\r\n') ("*")") r1=named ;; *) r1="$ver_out" ;; esac
t cli-version-names-version-and-root named "$r1"

# `adopt` is retired but must not break a caller — and must not be advertised.
case "$(crewcli adopt 2>&1)" in *"'adopt' is now 'hire'"*) r1=warned ;; *) r1=SILENT ;; esac
t cli-adopt-alias-warns warned "$r1"
case "$help_all" in *adopt*) r1=ADVERTISED ;; *) r1=hidden ;; esac
t cli-adopt-not-in-help hidden "$r1"

# The header comment is no longer a second command list. It used to BE the
# help output, and it drifted; a reader who re-adds a verb table there
# re-creates the defect #97 closed.
# The shape being forbidden is a LISTING — an indented comment line that
# begins with `crew <verb>`, which is exactly how the old table was written
# and how it drifted. Prose that quotes a command mid-sentence is fine and is
# not what re-creates the defect; matching on that would forbid explaining it.
relisted="$(sed -n '2,/^set -euo pipefail/p' "$CLIBIN" | grep -cE '^#[[:space:]]+crew [a-z-]+' || true)"
t cli-header-is-not-a-command-list 0 "$relisted"

# --- the examples fallback creates and arms NOTHING (#216) ------------------
# A host with no operator config at all resolves to $CREW_ROOT/examples and,
# before this, presented as a fully configured seven-box fleet: `crew up`
# there created seven boxes and armed cron against the three live
# repositories the shipped registry then named. The fallback itself stays —
# it is deliberate and the config rehearsal covers it. What it loses is the
# ability to create or arm.
#
# The fixture must reproduce the REPORTED environment exactly, because every
# other test in this file arrives here through a configured path: HOME with no
# .config/crew, XDG unset, CREW_CONFIG_DIR unset, and a $PWD carrying no
# fleet.roster. Get any one of those wrong and resolution lands on an operator
# directory, CONFIG_IS_OPERATOR is 1, and the whole block asserts nothing.
FBHOME="$TMP/fallback-home"
FBPWD="$TMP/fallback-pwd"
mkdir -p "$FBHOME" "$FBPWD"
fbcrew() {  # stdout+stderr, from the unconfigured host
  (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" 2>&1)
}
fbrc() {
  (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" >/dev/null 2>&1)
  echo $?
}

# The fixture proves itself first: if this says operator, every assertion
# below is vacuous.
case "$(fbcrew status)" in
  *"NO operator fleet definition"*) r1=fallback ;;
  *) r1=OPERATOR ;;
esac
t cli-fallback-fixture-is-really-the-fallback fallback "$r1"

# Every mutating verb refuses, and every one of them names `crew init` — the
# refusal is only useful if it says what to do instead. Asserted per verb
# rather than on a sample: the defect was per-call-site and so is the fix.
#
# `floor` refuses too (#244) and is deliberately NOT in this list: fbrc runs
# each spec in the FOREGROUND with no timeout, so a regressed floor refusal
# would serve until the CI job's own limit rather than fail here. Its cases
# live in fleet-floor/test/cli.sh, which owns the verb, caps every process it
# starts and watches the port. Add it here and this suite hangs on the day the
# assertion matters.
refused="" unnamed=""
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  [ "$(fbrc $spec)" != 0 ] || refused="$refused [$spec]"
  # shellcheck disable=SC2086
  case "$(fbcrew $spec)" in *"crew init"*) : ;; *) unnamed="$unnamed [$spec]" ;; esac
done <<'SPECS'
new claude-triage
create-all
hire claude-triage
hire-all
up
down
upgrade --all
gold somebox
SPECS
t cli-fallback-mutating-verbs-refuse "" "$refused"
t cli-fallback-refusal-names-crew-init "" "$unnamed"

# ...and the read-only verbs still WORK, because inspecting a host in this
# state is exactly what they are for. A fix that made `crew status` refuse
# would take away the one instrument that explains the refusals.
t cli-fallback-status-still-works   0 "$(fbrc status)"
t cli-fallback-profiles-still-works 0 "$(fbrc profiles)"
t cli-fallback-dry-run-still-works  0 "$(fbrc up --dry-run)"

# Each of them says what it is reading. The reported symptom was a table
# nobody could tell apart from a configured fleet's, so the banner is the
# fix's user-visible half and is asserted by content, not by presence.
bannerless=""
for verb in status profiles; do
  case "$(fbcrew "$verb")" in
    *"NO operator fleet definition"*"$ROOT/examples"*) : ;;
    *) bannerless="$bannerless [$verb]" ;;
  esac
done
case "$(fbcrew up --dry-run)" in
  *"NO operator fleet definition"*"$ROOT/examples"*) : ;;
  *) bannerless="$bannerless [up --dry-run]" ;;
esac
t cli-fallback-read-only-verbs-banner "" "$bannerless"

# The banner is on stderr, so the tables stay machine-readable: a row-parsing
# caller must not have to filter it back out. This is the assertion that keeps
# a later "make it more visible" edit from breaking every such caller silently.
fb_stdout="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" status 2>/dev/null) )"
case "$fb_stdout" in
  *"NO operator fleet definition"*) r1=ON_STDOUT ;;
  *MEMBER*) r1=rows-only ;;
  *) r1="$fb_stdout" ;;
esac
t cli-fallback-banner-is-on-stderr rows-only "$r1"

# THE REGRESSION THAT MATTERS MORE THAN THE BUG: a real fleet must behave
# exactly as before. A fix that makes configured hosts refuse is a fleet
# outage; the bug it replaces is one confusing table.
OPCONF="$TMP/op-config"
mkdir -p "$OPCONF"
cp "$ROOT/examples/fleet.roster" "$ROOT/examples/fleet.conf" "$OPCONF/"
printf '# an operator registry\nfixture/operator-repo\n' >"$OPCONF/repos.txt"
printf '# an operator notify registry\nfixture/operator-repo\n' >"$OPCONF/notify-repos.txt"
opcrew() {
  (cd "$FBPWD" && env -u XDG_CONFIG_HOME -u CREW_ROSTER CREW_CONFIG_DIR="$OPCONF" \
    HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" "$@" 2>&1)
}
overreach=""
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  # shellcheck disable=SC2086  # splitting the spec into argv is the point
  case "$(opcrew $spec)" in
    *"refuses under the shipped example"*|*"NO operator fleet definition"*)
      overreach="$overreach [$spec]" ;;
  esac
done <<'SPECS'
status
profiles
up --dry-run
new claude-triage
create-all
hire claude-triage
hire-all
up
down
upgrade --all
gold somebox
SPECS
t cli-operator-config-never-refused-or-bannered "" "$overreach"

# $PWD discovery is an operator definition too — the third resolution hop, and
# the one a developer running crew from a config directory relies on. Banner
# it and this fix breaks that workflow.
pwdcrew_out="$(cd "$OPCONF" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$CLIBIN" status 2>&1)"
case "$pwdcrew_out" in
  *"NO operator fleet definition"*) r1=BANNERED ;;
  *) r1=clean ;;
esac
t cli-pwd-discovery-is-operator clean "$r1"

# The shipped registry ships EMPTY. Asserted by parsing rather than by diffing
# a literal, so a future edit that re-adds a live repository reds this instead
# of shipping a scaffold aimed at somebody else's board.
t cli-examples-registry-is-empty 0 \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$ROOT/examples/repos.txt" || true)"

# ...and the same must be true one hop later, of what an operator actually
# gets: `crew init` seeds from examples/, so a fresh fleet definition starts
# aimed at nothing and stays that way until the operator names a repo.
INIT_TARGET="$TMP/init-seeded"
init_rc="$(fbrc init "$INIT_TARGET")"
t cli-init-still-works-under-fallback 0 "$init_rc"
t cli-init-seeds-an-empty-registry 0 \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$INIT_TARGET/repos.txt" 2>/dev/null || true)"

# Validation parity: the completeness check ran only for operator definitions,
# so the LEAST trusted directory got the LEAST verification. Both directions
# are asserted, because the property is that the check does not care who wrote
# the directory.
FBROOT="$TMP/fallback-root"
mkdir -p "$FBROOT/cli"
cp "$CLIBIN" "$FBROOT/cli/crew"
cp "$ROOT/VERSION" "$FBROOT/VERSION"
ln -s "$SHARED" "$FBROOT/shared"
cp -R "$ROOT/examples" "$FBROOT/examples"
rm -f "$FBROOT/examples/repos.txt"
fb_incomplete="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$FBROOT/cli/crew" status 2>&1) )"
case "$fb_incomplete" in
  *"is incomplete; missing: repos.txt"*) r1=refused ;;
  *) r1="$fb_incomplete" ;;
esac
t cli-fallback-incompleteness-is-fatal refused "$r1"

# fleet.conf is named by the same criterion, so it is asserted by the same
# route rather than assumed to follow from repos.txt.
FBROOT2="$TMP/fallback-root-noconf"
mkdir -p "$FBROOT2/cli"
cp "$CLIBIN" "$FBROOT2/cli/crew"
cp "$ROOT/VERSION" "$FBROOT2/VERSION"
ln -s "$SHARED" "$FBROOT2/shared"
cp -R "$ROOT/examples" "$FBROOT2/examples"
rm -f "$FBROOT2/examples/fleet.conf"
fb_noconf="$( (cd "$FBPWD" && env -u CREW_CONFIG_DIR -u XDG_CONFIG_HOME -u CREW_ROSTER \
  HOME="$FBHOME" PATH="$CLISHIM:$PATH" bash "$FBROOT2/cli/crew" status 2>&1) )"
case "$fb_noconf" in
  *"is incomplete; missing: fleet.conf"*) r1=refused ;;
  *) r1="$fb_noconf" ;;
esac
t cli-fallback-missing-fleet-conf-is-fatal refused "$r1"

OPINCOMPLETE="$TMP/op-incomplete"
mkdir -p "$OPINCOMPLETE"
cp "$ROOT/examples/fleet.roster" "$ROOT/examples/fleet.conf" "$OPINCOMPLETE/"
op_incomplete="$( (cd "$FBPWD" && env -u XDG_CONFIG_HOME -u CREW_ROSTER \
  CREW_CONFIG_DIR="$OPINCOMPLETE" HOME="$FBHOME" PATH="$CLISHIM:$PATH" \
  bash "$CLIBIN" status 2>&1) )"
case "$op_incomplete" in
  *"is incomplete; missing: repos.txt"*) r1=refused ;;
  *) r1="$op_incomplete" ;;
esac
t cli-operator-incompleteness-is-fatal refused "$r1"

# --- CI split: route the browser walk without dropping coverage (#138) -----
# Repo furniture, in the same family as valid_version-parity above: assertions
# about a file the engine never executes, kept here because the property is
# anti-drift and every way of losing it is silent.
CI_SHELL="$ROOT/.github/workflows/ci-shell.yml"
CI_FLOOR="$ROOT/.github/workflows/ci-floor.yml"

ci_paths() {
  trigger="$1"
  workflow="$2"
  awk -v trigger="$trigger" '
    $0 == "  " trigger ":" { in_trigger = 1; next }
    in_trigger && /^  [[:alnum:]_-]+:/ { exit }
    in_trigger && /^    paths: \[/ {
      sub(/^    paths: \[/, "")
      sub(/\]$/, "")
      print
    }
  ' "$workflow" \
    | tr ',' '\n' | tr -d " '\"" | sed '/^$/d' | sort -u
}

# The old filter's product paths survive across the union. Its deleted
# self-path is replaced by both new workflows' paths. ci-floor.yml also routes
# to ci-shell so edits to that workflow run the assertions below; it is the one
# intentional overlap. Explicitly naming .ceremony/** prevents two
# mutually-agreeing filters from dropping the path that caught #363.
CI_EXPECTED="$(printf '%s\n' \
  '.ceremony/**' '.github/workflows/ci-floor.yml' '.github/workflows/ci-shell.yml' \
  'cli/**' 'dist/**' 'drill/**' 'examples/**' 'fleet-floor/**' 'install.sh' 'shared/**' | sort)"
CI_SHELL_PR_PATHS="$(ci_paths pull_request "$CI_SHELL")"
CI_FLOOR_PR_PATHS="$(ci_paths pull_request "$CI_FLOOR")"
CI_UNION="$(printf '%s\n%s\n' "$CI_SHELL_PR_PATHS" "$CI_FLOOR_PR_PATHS")"
t ci-path-union-preserves-coverage "$CI_EXPECTED" "$(printf '%s\n' "$CI_UNION" | sort -u)"
CI_OVERLAP="$(comm -12 <(printf '%s\n' "$CI_SHELL_PR_PATHS") <(printf '%s\n' "$CI_FLOOR_PR_PATHS"))"
t ci-path-overlap-is-only-floor-self-edit '.github/workflows/ci-floor.yml' "$CI_OVERLAP"
case "$CI_SHELL_PR_PATHS" in *'.ceremony/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-shell-keeps-ceremony-fixtures present "$r1"
case "$CI_SHELL_PR_PATHS" in *'.github/workflows/ci-floor.yml'*) r1=present ;; *) r1=MISSING ;; esac
t ci-floor-self-edit-routes-to-shell present "$r1"

# The three routing cases, plus the load-bearing CLI coverage on the cheap
# side. Native paths do the routing; a billed filter job is forbidden.
ci_shell_paths="$CI_SHELL_PR_PATHS"
case "$ci_shell_paths" in *'shared/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-shared-routes-to-shell present "$r1"
case "$ci_shell_paths" in *'cli/**'*) r1=present ;; *) r1=MISSING ;; esac
t ci-cli-routes-to-shell present "$r1"
case "$CI_FLOOR_PR_PATHS" in *'fleet-floor/**'*) r1=floor ;; *) r1=MISSING ;; esac
t ci-fleet-floor-routes-to-floor floor "$r1"
if grep -q 'fleet-floor/test/run.sh --no-browser' "$CI_SHELL"; then r1=covered; else r1=DROPPED; fi
t ci-shell-runs-floor-cli-fixtures covered "$r1"
if grep -Eq 'paths-filter|filter-changes|changes:' "$CI_SHELL" "$CI_FLOOR"; then r1=BILLED; else r1=native; fi
t ci-routing-uses-native-paths native "$r1"

# Both workflows inherit the draft wake/gate, per-ref cancellation and the
# push-to-main post-merge run. A missing half is a checkless current head.
for ci_yml in "$CI_SHELL" "$CI_FLOOR"; do
  ci_name="$(sed -n 's/^name: //p' "$ci_yml")"
  ci_types=",$(sed -n 's/^ *types: *\[\(.*\)\].*$/\1/p' "$ci_yml" | tr -d ' '),"
  for ev in opened synchronize reopened ready_for_review; do
    case "$ci_types" in *",$ev,"*) r1=present ;; *) r1=MISSING ;; esac
    t "$ci_name-trigger-fires-on[$ev]" present "$r1"
  done
  ci_if="$(awk '/^  check:/{p=1} p && /^    if:/{print; exit}' "$ci_yml")"
  case "$ci_if" in *github.event.pull_request.draft*) r1=payload ;; *) r1=MISSING ;; esac
  t "$ci_name-gates-on-draft-payload" payload "$r1"
  case "$ci_if" in *state:*|*label*) r1=LABEL ;; *) r1=payload-only ;; esac
  t "$ci_name-gate-is-not-label" payload-only "$r1"
  case "$ci_if" in *github.event_name*) r1=explicit ;; *) r1=COERCION ;; esac
  t "$ci_name-push-exemption-is-explicit" explicit "$r1"
  t "$ci_name-pushes-run-on-main" 1 "$(grep -c '^    branches: \[main\]$' "$ci_yml")"
  t "$ci_name-push-preserves-union-filter" "$CI_EXPECTED" "$(ci_paths push "$ci_yml")"
  ci_group="$(sed -n 's/^  group: *//p' "$ci_yml")"
  # shellcheck disable=SC2016  # Match the literal GitHub expression in YAML.
  case "$ci_group" in *'${{ github.ref }}'*) r1=per-ref ;; *) r1=TOO-COARSE ;; esac
  t "$ci_name-concurrency-is-per-ref" per-ref "$r1"
  t "$ci_name-cancels-superseded-runs" 1 "$(grep -c '^  cancel-in-progress: true$' "$ci_yml")"
done

# Every old step is routed. The expensive browser invocation exists only on
# the floor side; the cheap side still executes the headless floor/CLI suite.
t ci-check-names-are-distinct 2 \
  "$(sed -n 's/^    name: \(ci-.*\)$/\1/p' "$CI_SHELL" "$CI_FLOOR" | sort -u | wc -l | tr -d ' ')"
for command in 'shared/test/run.sh' 'shared/test/install-lifecycle.sh' \
  'shared/test/artifact.sh' 'shared/test/install-drill.sh'; do
  t "ci-shell-keeps[$command]" 1 "$(grep -Fc "run: $command" "$CI_SHELL")"
done
t ci-floor-keeps-python-syntax 1 "$(grep -Fc 'python3 -m py_compile fleet-floor/server/floor.py' "$CI_FLOOR")"
t ci-floor-keeps-browser-gate 1 "$(grep -Fc 'FLOOR_TEST_REQUIRE_BROWSER=1 fleet-floor/test/run.sh' "$CI_FLOOR")"
t ci-floor-keeps-built-page-check 1 "$(grep -Fc 'git diff --exit-code -- fleet-floor/index.html' "$CI_FLOOR")"
# shellcheck disable=SC2016  # Match the literal loop variable in workflow YAML.
t ci-floor-keeps-bash-syntax 1 "$(grep -Fc 'bash -n "$f"' "$CI_FLOOR")"
t ci-floor-keeps-shellcheck 1 "$(grep -c '^      - name: shellcheck (floor)$' "$CI_FLOOR")"

# The cheap cross-layer contracts that make a browser skip safe (#138 edges 1
# and 6). cmd_floor must keep the server/build/env bridge, and every operator
# command the console names must remain in the CLI's dispatch table.
CI_CREW="$ROOT/cli/crew"
CI_FLOOR_FN="$(sed -n '/^cmd_floor()/,/^}/p' "$CI_CREW")"
case "$CI_FLOOR_FN" in *'fleet-floor/index.html'*'CREW_FLOOR_PORT='*'CREW_FLOOR_BIND='*'CREW_FLOOR_USER='*'CREW_FLOOR_PASS='*'CREW_FLOOR_INTERVAL='*'CREW_FLOOR_ROSTER='*'fleet-floor/server/floor.py'*) r1=bridged ;; *) r1=BROKEN ;; esac
t cli-floor-server-contract bridged "$r1"
CI_CONSOLE_VERBS='down floor hire init new profiles status up upgrade'
CI_CONSOLE_PROSE_VERBS='and cut hangs makes on reads stopped would'
CI_CONSOLE_CANDIDATES="$(grep -ohE 'crew [a-z][a-z-]*' \
  "$ROOT/fleet-floor/server/floor.py" "$ROOT/fleet-floor/src/app.js" \
  | sed 's/^crew //' | sort -u \
  | grep -Ev "^($(printf '%s' "$CI_CONSOLE_PROSE_VERBS" | tr ' ' '|'))$")"
t floor-named-crew-verb-roster-is-complete "$CI_CONSOLE_VERBS" \
  "$(printf '%s\n' "$CI_CONSOLE_CANDIDATES" | paste -sd ' ' -)"
CI_COMMAND_ROWS="$(sed -n '/^CMDS=(/,/^)/p' "$CI_CREW")"
for verb in $CI_CONSOLE_VERBS; do
  if grep -q "crew $verb" "$ROOT/fleet-floor/server/floor.py" "$ROOT/fleet-floor/src/app.js" &&
     grep -q "^  \"$verb\\^" <<<"$CI_COMMAND_ROWS"; then
    r1=dispatchable
  else
    r1=MISSING
  fi
  t "floor-named-crew-verb-dispatches[$verb]" dispatchable "$r1"
done

# --- crew status: what the operator reads ---------------------------------
# A box is a directory here: the stub runs `box exec` bodies with HOME pointed
# into it, so the REAL engine-manifest.sh runs against a REAL installed tree
# and the column is asserted end to end rather than against a mocked verdict.
MSROOT="$TMP/status-boxes"
MSSHIM="$TMP/status-bin"
MSCONF="$TMP/status-fleet"
MSCALLS="$TMP/status-box-calls"
MSINSTALL_SCRIPTS="$TMP/status-install-scripts"
mkdir -p "$MSSHIM" "$MSCONF" "$MSROOT"
printf 'fixture-box claude reviewer\n' >"$MSCONF/fleet.roster"
printf 'FLEET_BENCH="b"\nFLEET_TRIAGE="t"\nFLEET_HUMAN="h"\n' >"$MSCONF/fleet.conf"
printf 'owner/repo\n' >"$MSCONF/repos.txt"
cat >"$MSSHIM/box" <<'EOF'
#!/usr/bin/env bash
# box list/info/exec against $MSROOT/<name>, one directory per box.
case "$1" in
  list) printf '[{"name":"fixture-box"}]\n' ;;
  info) printf '[{"status":"running"}]\n' ;;
  exec)
    name="$2"
    printf '%s\n' "$name" >>"$MSCALLS"
    shift 3                      # past: exec <name> --
    # what is left is `bash -lc <script>`. Run the script with -c rather than
    # -lc: a login shell would source this workstation's profile, and the box
    # under test is meant to be the directory and nothing else. DUTY_DIR is
    # unset because a real box has none — it resolves from HOME, which is the
    # resolution under test.
    case "$3" in *shared/install.sh*) printf '%s\n' "$3" >>"$MSINSTALL_SCRIPTS" ;; esac
    env -u DUTY_DIR HOME="$MSROOT/$name" CRON_STATE="$MSROOT/$name/crontab" bash -c "$3"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$MSSHIM/box"
ln -sf "$(command -v jq)" "$MSSHIM/jq"
# Since #189 `crew status` asks the box whether cron is armed. The shim runs
# these scripts on the HOST, so a real `crontab -l` would read whoever's
# crontab is running the suite — and on a box host that genuinely carries a
# tick.sh line the row would flip depending on the machine. Pin it. The fixture
# box is ARMED, which is the ordinary case and the one the round-trip budget
# below is about; the disarmed path is asserted separately, further down.
cat >"$MSSHIM/crontab" <<'CRONEOF'
#!/usr/bin/env bash
case "${1:-}" in
  -l)
    [ -n "${MSCRON_EMPTY:-}" ] && exit 0
    # The paused shape as the console's PAUSE_SH actually writes it: the live
    # line commented out with the marker in front. Both counts are then
    # non-trivial — armed 0, paused 1 — which is the only shape that catches a
    # record whose fields have been shifted onto a second line.
    if [ -n "${MSCRON_PAUSED:-}" ]; then
      printf '#CREW-FLOOR-PAUSED */5 * * * * $HOME/duty/bin/tick.sh\n'
    elif [ -f "$CRON_STATE" ]; then
      cat "$CRON_STATE"
    else
      printf '*/5 * * * * $HOME/duty/bin/tick.sh\n'
    fi
    ;;
  -) tmp="$CRON_STATE.new"; cat >"$tmp"; mv "$tmp" "$CRON_STATE" ;;
  *) tmp="$CRON_STATE.new"; cat "$1" >"$tmp"; mv "$tmp" "$CRON_STATE" ;;
esac
CRONEOF
chmod +x "$MSSHIM/crontab"
crewstatus() {
  env CREW_CONFIG_DIR="$MSCONF" MSROOT="$MSROOT" MSCALLS="$MSCALLS" \
    PATH="$MSSHIM:$PATH" bash "$ROOT/cli/crew" status "$@" 2>&1
}
# The fixture box IS the installed tree from the installer fixtures above.
mkdir -p "$MSROOT/fixture-box"
cp -R "$MDUTY" "$MSROOT/fixture-box/duty"
# ...and it has ticked once. Not decoration: it pins the round-trip count
# asserted below at the steady state #159 is about — a box that has never
# ticked is a different state, and it has its own coverage in
# fleet-floor/test/cli.sh (the table's NOTE, #224; the detail view's line,
# #221).
#
# It used to say the never-ticked case was UNREACHABLE here: with no duty.log
# at all the row's `tail -n 1` exited 1, and under `set -o pipefail` that
# killed cmd_status's loop after the header. #224 fixed that — the fallback
# renders, the loop survives — so the reason this fixture ticks is now the
# count above and nothing else.
printf '2026-07-29T00:00:00Z duty run start\n' >"$MSROOT/fixture-box/duty/duty.log"

# #283 — exercise the real upgrade branch and installer, not a reconstruction
# of its grep. The script capture proves which flags reached install.sh; the
# state-backed crontab shim proves what the installer left behind.
upgradefixture() {
  : >"$MSINSTALL_SCRIPTS"
  env CREW_CONFIG_DIR="$MSCONF" MSROOT="$MSROOT" MSCALLS="$MSCALLS" \
    MSINSTALL_SCRIPTS="$MSINSTALL_SCRIPTS" PATH="$MSSHIM:$PATH" \
    bash "$ROOT/cli/crew" upgrade fixture-box >/dev/null 2>&1
}
resolved_tick="$MSROOT/fixture-box/duty/bin/tick.sh"

paused_cron="#CREW-FLOOR-PAUSED */5 * * * * $resolved_tick"
printf '%s\n' "$paused_cron" >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=PASSED; else r1=absent; fi
t upgrade-paused-box-passes-no-arm-flag absent "$r1"
t upgrade-paused-box-keeps-crontab "$paused_cron" "$(cat "$MSROOT/fixture-box/crontab")"

armed_cron="*/5 * * * * $resolved_tick"
printf '%s\n' "$armed_cron" >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=present; else r1=MISSING; fi
t upgrade-armed-box-keeps-arm-flag present "$r1"
t upgrade-armed-box-has-one-canonical-tick 1 \
  "$(grep -cF "$resolved_tick" "$MSROOT/fixture-box/crontab")"

: >"$MSROOT/fixture-box/crontab"
upgradefixture
if grep -q -- '--arm-cron' "$MSINSTALL_SCRIPTS"; then r1=PASSED; else r1=absent; fi
t upgrade-never-armed-box-passes-no-arm-flag absent "$r1"
t upgrade-never-armed-box-keeps-crontab '' "$(cat "$MSROOT/fixture-box/crontab")"

# Restore the ordinary armed fixture consumed by the status cases below.
printf '%s\n' "$armed_cron" >"$MSROOT/fixture-box/crontab"

status_out="$(crewstatus)"
case "$status_out" in *INTEGRITY*) r1=present ;; *) r1=MISSING ;; esac
t status-has-an-integrity-column present "$r1"
case "$status_out" in *"fixture-box"*current*) r1=current ;; *) r1=OTHER ;; esac
t status-clean-box-reads-current current "$r1"

# The round-trip budget (#159 acceptance): reading integrity must ride the exec
# `crew status` already made. Three per box — the engine report, the auth/tick
# read, and the last log line — which is exactly what it cost before this
# existed, when the first of the three was a bare `head -1 ~/duty/VERSION`.
: >"$MSCALLS"
crewstatus >/dev/null
t status-round-trips-per-box 3 "$(grep -c . "$MSCALLS")"

# #189 — an UNARMED box. `crew status` says so and names the fix, instead of
# printing the newest duty.log line, which on a box whose cron is gone is a
# fact about the past that reads exactly like a working box. The floor answers
# from the same counts; drill/rehearsal-app.sh compares the two on real
# hardware, and that comparison is the thing that had never once run.
status_out="$(MSCRON_EMPTY=1 crewstatus)"
case "$status_out" in *"fixture-box"*disarmed*"crew hire"*) r1=named ;; *) r1="$status_out" ;; esac
t status-unarmed-box-says-disarmed named "$r1"
# ...and it costs one round trip LESS, not more: the log-line read is skipped
# precisely because its answer would mislead. The budget above is the ceiling.
: >"$MSCALLS"
MSCRON_EMPTY=1 crewstatus >/dev/null
t status-round-trips-unarmed 2 "$(grep -c . "$MSCALLS")"

# #189, round 1 (codex/grok/kimi, all three) — a PAUSED box must be told to
# resume, never to re-hire. `grep -c` PRINTS the count and exits 1 when it is
# zero, so a `|| echo 0` guard appended a SECOND zero and pushed the paused
# count onto line two; `read` saw only line one and the note came out
# "disarmed — crew hire". Armed and empty-crontab both parse that away, which
# is why the first cut of these tests went green: this case is the one shape
# where both counts are non-trivial, and it is the shape a real operator makes
# by clicking Pause.
status_out="$(MSCRON_PAUSED=1 crewstatus)"
case "$status_out" in
  *"fixture-box"*"paused by operator"*) r1=paused ;;
  *"fixture-box"*disarmed*)             r1=WRONG-FIX-NAMED ;;
  *)                                    r1="$status_out" ;;
esac
t status-paused-box-says-paused paused "$r1"

# A modified box, end to end.
printf '# hotfix by hand\n' >>"$MSROOT/fixture-box/duty/bin/duty.sh"
status_out="$(crewstatus)"
case "$status_out" in *MODIFIED*) r1=shouts ;; *) r1=SILENT ;; esac
t status-modified-box-shouts shouts "$r1"
case "$status_out" in *"MODIFIED since crew@$(head -1 "$ROOT/VERSION")"*) r1=named ;; *) r1=UNNAMED ;; esac
t status-modified-names-the-version named "$r1"

# MUST FAIL: modified and skew collapsing into one state. They ask for
# different actions — skew says "ship the engine", modified says "find out
# what someone did here" — so the HOST/ENGINE pair and the INTEGRITY column
# have to disagree independently. Here the box is at the host's own version
# and still modified: nothing about skew can be producing this word.
host_v="$(head -1 "$ROOT/VERSION")"
ms_row="$(printf '%s\n' "$status_out" | grep '^fixture-box' || true)"
case "$ms_row" in
  *"$host_v"*"crew@$host_v"*MODIFIED*) r1=same-version-and-modified ;;
  *) r1=COLLAPSED ;;
esac
t status-modified-is-not-skew same-version-and-modified "$r1"

# The per-box view lists the files, on the same single exec.
detail_out="$(crewstatus fixture-box)"
case "$detail_out" in *"integrity: MODIFIED"*"modified bin/duty.sh"*) r1=listed ;; *) r1=MISSING ;; esac
t status-detail-lists-the-files listed "$r1"
case "$detail_out" in *"--force"*) r1=told ;; *) r1=SILENT ;; esac
t status-detail-names-the-override told "$r1"

# A box hired before content stamping: no record AND no tool to compute one.
# It reads unverified in the table, never modified.
rm -f "$MSROOT/fixture-box/duty/.engine-manifest" "$MSROOT/fixture-box/duty/bin/engine-manifest.sh"
status_out="$(crewstatus)"
case "$status_out" in *unverified*) r1=unverified ;; *MODIFIED*) r1=MODIFIED ;; *) r1=OTHER ;; esac
t status-pre-existing-box-reads-unverified unverified "$r1"

# --- git identity: the second carrier of the box's login (#294) -------------
# The split rotated the gh credential and left git naming the pre-split
# account, so a builder's commits were bylined by the reviewer. These assert
# the derivation: gh says who the box is, git is made to agree, and a box that
# cannot be made to agree runs nothing.
#
# GIT_CONFIG_GLOBAL, not $HOME: the suite inherits the real HOME (see the
# export at the top), and a test that writes `git config --global` without
# this rewrites the identity of whoever ran it — which on a live box is the
# very byline #294 exists to protect.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-294"
: >"$GIT_CONFIG_GLOBAL"
GHLOG="$TMP/gh-calls-294"; : >"$GHLOG"

# The address table. Every row is a shape that reaches this parser in the
# fleet as it stands today, not a hypothetical.
t gitid-parses-id-prefixed-form cndgrr \
  "$(git_identity_login '59120057+cndgrr@users.noreply.github.com')"
t gitid-parses-bare-form cndgrr \
  "$(git_identity_login 'cndgrr@users.noreply.github.com')"
t gitid-folds-case cndgrr \
  "$(git_identity_login 'CNDGRR@Users.NoReply.GitHub.COM')"
t gitid-parses-a-hyphenated-login claude-bot-andresmgsl \
  "$(git_identity_login 'claude-bot-andresmgsl@users.noreply.github.com')"
# Not a noreply address names nobody — deliberately, per the comment on the
# function: the fleet provisions noreply addresses only, so anything else is
# an address no code here wrote.
t gitid-rejects-a-real-email "" "$(git_identity_login 'dan@example.com')"
t gitid-rejects-empty "" "$(git_identity_login '')"
t gitid-rejects-missing-local-part "" "$(git_identity_login '@users.noreply.github.com')"
t gitid-rejects-empty-id "" "$(git_identity_login '+cndgrr@users.noreply.github.com')"
# A non-numeric prefix is not an id GitHub issued. Half-parsing it would read
# `andresmgsl+cndgrr@…` as cndgrr, which is a login this box does not hold.
t gitid-rejects-non-numeric-id "" \
  "$(git_identity_login 'andresmgsl+cndgrr@users.noreply.github.com')"
# The domain must END the address; a lookalike suffix must not match.
t gitid-rejects-lookalike-domain "" \
  "$(git_identity_login '59120057+cndgrr@users.noreply.github.com.example.net')"
# Whitespace INSIDE the address names nobody. Deleting it would manufacture an
# identity out of an address GitHub attributes to no account — the parser's own
# version of the bug this file is about.
t gitid-rejects-an-interior-space "" \
  "$(git_identity_login 'cnd grr@users.noreply.github.com')"
t gitid-rejects-a-space-around-the-id "" \
  "$(git_identity_login '59120057 + cndgrr@users.noreply.github.com')"
t gitid-rejects-a-space-in-the-domain "" \
  "$(git_identity_login 'cndgrr@users.noreply.git hub.com')"
# The EDGES are still trimmed: that is a value a hand-edited config presents,
# and the address inside it is unambiguous.
t gitid-trims-surrounding-whitespace cndgrr \
  "$(git_identity_login '  59120057+cndgrr@users.noreply.github.com
')"
t gitid-rejects-whitespace-only "" "$(git_identity_login '   ')"

# --- the must-fail proof (#294's test plan) ---------------------------------
# A duty environment whose user.email does not match $ME. Reverting the assert
# greens a box that commits as somebody else, which is today's behaviour and
# the point.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-mismatched-email-is-refused refused "$r1"

# The SAME foreign address in the id-prefixed form — the row #294 singles out
# as the one that matters, because a parser that greened anything containing a
# '+' would green every foreign address on the fleet and still pass the bare
# row above.
git config --global user.email '1234567+claude-bot-andresmgsl@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-foreign-id-prefixed-form-is-refused refused "$r1"

# An address that is only this box's login once its interior whitespace is
# deleted is NOT this box's login. git config stores the value verbatim, so
# this is a state a real ~/.gitconfig can hold, and greening it would byline
# every commit to nobody while the guard reported a converged box.
git config --global user.email 'cnd grr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-interior-space-email-is-refused refused "$r1"

# Both forms of this box's own address pass. One is what provisioning writes,
# the other is what the 2026-08-02 hand sweep wrote; an assert that took only
# the first would red every box that sweep already repaired.
git config --global user.email '59120057+cndgrr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=ok; else r1=REFUSED; fi
t gitid-id-prefixed-form-passes ok "$r1"
git config --global user.email 'cndgrr@users.noreply.github.com'
if git_identity_ok cndgrr; then r1=ok; else r1=REFUSED; fi
t gitid-hand-swept-bare-form-passes ok "$r1"
if git_identity_ok CNDGRR; then r1=ok; else r1=REFUSED; fi
t gitid-login-comparison-is-case-insensitive ok "$r1"

# No configured identity is a mismatch, not a pass: git then authors commits
# as whatever the box template left behind, which is how this started.
git config --global --unset user.email
if git_identity_ok cndgrr; then r1=GREEN; else r1=refused; fi
t gitid-unset-email-is-refused refused "$r1"
# And an empty login can never be satisfied — a caller with no $ME must not
# accidentally green every box.
git config --global user.email '59120057+cndgrr@users.noreply.github.com'
if git_identity_ok ""; then r1=GREEN; else r1=refused; fi
t gitid-empty-login-is-refused refused "$r1"

# --- convergence ------------------------------------------------------------
# shellcheck disable=SC2317  # invoked indirectly, by converge_git_identity
gh() { echo "$*" >>"$GHLOG"; printf '%s\t%s\n' "$GH_STUB_LOGIN" "$GH_STUB_ID"; }
GH_STUB_LOGIN=cndgrr GH_STUB_ID=59120057

# The steady state costs NOTHING: already converged, so no network call. This
# runs on every tick of every box, so a stray `gh api user` here is a fleet's
# worth of requests for a fact already on local disk.
: >"$GHLOG"
converge_git_identity cndgrr
t gitid-converged-returns-ok 0 "$?"
t gitid-steady-state-makes-no-gh-call "" "$(cat "$GHLOG")"

# The hand-swept bare form is already converged too — it must NOT be rewritten
# on every upgrade for the rest of time.
git config --global user.email 'cndgrr@users.noreply.github.com'
: >"$GHLOG"
converge_git_identity cndgrr
t gitid-bare-form-is-not-rewritten 'cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"

# The repair: a box carrying the pre-split account converges to its own.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
: >"$GHLOG"
converge_git_identity cndgrr >/dev/null
t gitid-repair-returns-ok 0 "$?"
t gitid-repair-writes-id-prefixed-address '59120057+cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"
t gitid-repair-writes-the-name cndgrr "$(git config --global user.name)"
t gitid-repair-spends-one-gh-call 1 "$(wc -l <"$GHLOG")"

# No argument is install.sh's call — it has no $ME, so gh alone decides.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
converge_git_identity >/dev/null
t gitid-no-argument-converges-from-gh '59120057+cndgrr@users.noreply.github.com' \
  "$(git config --global user.email)"

# A dead credential must NOT be repaired-by-guess. There is no source of truth
# to copy, so the copy is left alone and the caller is told — which is what
# makes duty.sh refuse rather than run a session under a name it cannot verify.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
# shellcheck disable=SC2317
gh() { return 1; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-dead-credential-refuses 1 "$?"
t gitid-dead-credential-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"

# A credential that ROTATED between duty.sh resolving $ME and this call must
# refuse, not converge. Converging would write the NEW account and return 0
# while the tick carries on as the OLD $ME — a session acting as one identity
# whose commits byline another, which is #294 one call later rather than
# fixed. Refusing costs one tick; the next one reads both halves consistently.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
git config --global user.name 'claude-bot-andresmgsl'
# shellcheck disable=SC2317
gh() { printf '%s\t%s\n' andriujoseba 12345678; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-rotated-credential-refuses 1 "$?"
t gitid-rotated-credential-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"
# The rotation guard is the CALLER's to invoke: install.sh passes no login
# because it has no $ME, and its whole job is to write whatever gh now says.
converge_git_identity >/dev/null 2>&1
t gitid-no-argument-follows-the-rotation '12345678+andriujoseba@users.noreply.github.com' \
  "$(git config --global user.email)"

# A malformed id is the same class: an address built from it would attribute
# to nobody, and writing it would look like a repair while fixing nothing.
# The starting address is set here rather than inherited from the block above,
# so this case reds for its own reason and not for a neighbour's.
git config --global user.email 'claude-bot-andresmgsl@users.noreply.github.com'
# shellcheck disable=SC2317
gh() { printf '%s\t%s\n' cndgrr 'not-a-number'; }
converge_git_identity cndgrr >/dev/null 2>&1
t gitid-non-numeric-id-refuses 1 "$?"
t gitid-non-numeric-id-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"
unset -f gh
unset GIT_CONFIG_GLOBAL

# --- the engine actually asks, and refuses before it dispatches -------------
# Static, because duty.sh is a script and not a sourceable module. These are
# the assertions that make REVERTING the fix red: without them a reviewer's
# green tells them the helper works, not that anything calls it.
DUTYSH="$SHARED/bin/duty.sh"
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -Fq 'converge_git_identity "$ME"' "$DUTYSH"; then r1=called; else r1=MISSING; fi
t gitid-duty-converges-against-me called "$r1"

# Ordering is the whole claim: "before any session runs". A converge placed
# after the first dispatch would pass every helper test above and still let a
# session commit under another droid's name.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
conv_line="$(grep -n 'converge_git_identity "\$ME"' "$DUTYSH" | head -1 | cut -d: -f1)"
disp_line="$(grep -n '^duty_attention$' "$DUTYSH" | head -1 | cut -d: -f1)"
if [ -n "$conv_line" ] && [ -n "$disp_line" ] && [ "$conv_line" -lt "$disp_line" ]; then
  r1=before
else
  r1="AFTER(converge=$conv_line dispatch=$disp_line)"
fi
t gitid-converge-precedes-the-first-duty before "$r1"

# And the refusal ends the tick rather than logging and carrying on.
# shellcheck disable=SC2016  # match the literal duty.sh awk range
if awk_range_grep_Fq '/converge_git_identity "\$ME"/,/^fi$/' "$DUTYSH" 'exit 0'; then
  r1=exits
else
  r1=CONTINUES
fi
t gitid-refusal-ends-the-tick exits "$r1"

# install.sh writes it through the ENGINE, not a private copy of the rule. A
# second implementation of "which login is this box" is how the panel copy
# (#285) and the git copy (#294) both happened.
if grep -Fq 'converge_git_identity' "$SHARED/install.sh"; then r1=derived; else r1=MISSING; fi
t gitid-install-uses-the-shared-helper derived "$r1"

if "$SHARED/test/claim.test.sh"; then r1=0; else r1=$?; fi
t claim-regression-suite 0 "$r1"
# --- rehearsal builder fixtures: tie checks to this run (#179) -----------
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

# --- the 0.1.2 operator surfaces: every assertion red on a staged answer -
# drill/rehearsal-app-surfaces.sh holds the seven assertions drill/rehearsal-
# app.sh makes about what 0.1.2 shipped into the operator's view (#420). They
# run on a drill HOST, which CI does not have — so they are exercised the way
# the other rehearsal helpers already are here: the leg's reporters stubbed,
# the file sourced, and a WRONG answer staged into the input each assertion
# reads. An assertion nobody can red is an assertion nobody has checked, which
# is #50's defect stated once more.
SURF="$TMP/app-surfaces"
mkdir -p "$SURF"

# One truthful fleet, four boxes: two hired and answering, one never created,
# one deployed but not talking. Every payload below is this one with exactly
# one field moved, so a red is attributable to that field and nothing else.
surf_payload() {  # surf_payload '<python mutating p>' → the fleet payload
  python3 - "$1" <<'PY'
import json, sys
p = {
    "version": "crew 0.1.2 (/opt/crew)",
    # `state`, `paused` and `disarmed` are the three fields fleetState() reads
    # (fleet-floor/src/app.js:1282-1285): a DRAWN unit that is offline lands in
    # Disarmed when either flag is set and in Silent when neither is. They are
    # here because the filter assertion compares the page's groups against the
    # sets they imply — crew-b disarmed, crew-d silent — rather than only
    # against whoever the page happened to list.
    "units": [
        {"box": "crew-a", "engine": "0.1.2", "integrity": "current",
         "hired": "yes", "note": "", "state": "idle",
         "paused": False, "disarmed": False},
        {"box": "crew-b", "engine": "0.1.2", "integrity": "modified",
         "hired": "yes", "note": "", "state": "offline",
         "paused": False, "disarmed": True},
        {"box": "crew-c", "engine": "", "integrity": "",
         "hired": "no", "note": "not created — crew new crew-c",
         "state": "offline", "paused": False, "disarmed": False},
        {"box": "crew-d", "engine": "0.1.2", "integrity": "unverified",
         "hired": "unknown", "note": "stopped", "state": "offline",
         "paused": False, "disarmed": False},
    ],
}
u = {b["box"]: b for b in p["units"]}
exec(sys.argv[1])
print(json.dumps(p))
PY
}
surf_payload 'pass'                                     >"$SURF/fleet.json"
surf_payload 'p["version"] = "crew 9.9.9 (/staged)"'    >"$SURF/fleet-wrong-version.json"
surf_payload 'p["version"] = "version unavailable"'     >"$SURF/fleet-no-version.json"
surf_payload 'u["crew-b"]["integrity"] = "current"'     >"$SURF/fleet-integrity-lie.json"
surf_payload 'u["crew-c"]["note"] = "not created"'      >"$SURF/fleet-no-repair-verb.json"
surf_payload 'p["units"] = [b for b in p["units"] if b["box"] != "crew-d"]' \
                                                        >"$SURF/fleet-drops-a-box.json"
# The same drop, of the one box that IS a measured absence — so the payload is
# short AND nothing in it carries `hired=no`, which is the pair that used to
# read as "every roster box is deployed".
surf_payload 'p["units"] = [b for b in p["units"] if b["box"] != "crew-c"]' \
                                                        >"$SURF/fleet-drops-the-undeployed-box.json"
surf_payload 'u["crew-c"]["note"] = "box inventory unreadable: box list failed"' \
                                                        >"$SURF/fleet-inventory-unreadable.json"
# Short BECAUSE the inventory failed: an unmeasured fleet, which must keep
# skipping rather than being read as the dropped-box regression.
surf_payload '
u["crew-b"]["note"] = "box inventory unreadable: box list failed"
p["units"] = [b for b in p["units"] if b["box"] != "crew-c"]
'                                                       >"$SURF/fleet-inventory-unreadable-and-short.json"
surf_payload 'u["crew-c"].update(hired="yes", engine="0.1.2", integrity="current", note="")' \
                                                        >"$SURF/fleet-all-deployed.json"
surf_payload 'u["crew-d"]["note"] = ""'                 >"$SURF/fleet-all-answered.json"
# Every declared box undeployed — #204's empty floor, the state the panel
# naming `crew hire` exists for.
surf_payload '
for b in p["units"]:
    b.update(hired="no", engine="", integrity="", state="offline",
             note="not hired — crew hire " + b["box"])
'                                                       >"$SURF/fleet-all-undeployed.json"
# The floor and the CLI disagreeing about one box: the payload says crew-b is
# deliberately stopped and `crew status` does not.
surf_payload 'u["crew-b"]["disarmed"] = False'          >"$SURF/fleet-b-not-disarmed.json"
# Two boxes deliberately stopped — an ordinary fleet, and the one that puts two
# members into the disarmed direction's blind set.
surf_payload 'u["crew-d"]["disarmed"] = True'           >"$SURF/fleet-two-disarmed.json"
# Nothing quiet at all: every drawn box is ticking, so neither state group has
# a member and the filter has nothing to classify.
surf_payload '
for b in p["units"]:
    b["state"] = "idle"
'                                                       >"$SURF/fleet-none-quiet.json"

printf 'crew-a claude builder\ncrew-b codex reviewer\ncrew-c grok triage\ncrew-d kimi builder\n' \
  >"$SURF/roster"
SURF_ROSTER="$SURF/roster"
# What each box answers to `engine-manifest.sh --state`, standing in for the
# `box exec` the leg does — the second reader #190's assertion cross-checks the
# floor against.
printf 'crew-a current\ncrew-b modified\ncrew-d unverified\n' >"$SURF/integrity"
printf 'crew-a current\ncrew-b tampered\ncrew-d unverified\n' >"$SURF/integrity-fourth-word"
: >"$SURF/integrity-silent"
SURF_INTEG="$SURF/integrity"

# The leg's reporters, in a SUBSHELL so run.sh's own t() survives the stubbing:
# each verdict comes back as one "<ok|FAIL|skip> <label> <reason>" line on
# stdout, which is the whole interface the assertions below match against.
# The REASON is on the line and not only the label, because criterion 3 is
# about the reason: "no assertion silently passes when its precondition is
# absent" is a claim about what the skip SAYS, and a skip whose stated reason
# is not true is the defect the #204 gate below exists to close. Newlines are
# flattened so one verdict stays one line.
# shellcheck disable=SC2317  # the stubs are reached through "$@", which is an
# indirection shellcheck cannot follow — every one of them is called by the
# sourced assertions below.
surf() {  # surf <fn> [args...] → one verdict line per assertion the fn makes
  (
    emit() { local v="$1" m; shift; m="$*"; printf '%s %s\n' "$v" "${m//$'\n'/ }"; }
    ok()   { emit ok "$@"; }
    fail() { emit FAIL "$@"; }
    skip() { emit skip "$@"; }
    t()    { if [ "$2" = "$3" ]; then printf 'ok %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; }
    jqf()  { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
    roster_rows()   { grep -vE '^[[:space:]]*(#|$)' "$SURF_ROSTER"; }
    # The caller supplies this reader, and on a real host it shells into a box.
    # SURF_GREEDY_READER makes it behave like the one that does — `box exec`
    # inherits the loop's stdin and drains it — which truncated the roster loop
    # to its first box on the host, silently, while the label kept claiming the
    # fleet.
    box_integrity() {
      # Bounded, because the drain must not outlive the thing it is draining:
      # once the roster moved to fd 3 this `cat` no longer meets the loop's
      # pipe at all, it meets whatever stdin the suite was STARTED with — and
      # an unbounded read of a socket that nobody is going to close hangs the
      # whole suite forever. It reaches EOF instantly against a pipe or
      # /dev/null (which is CI, and is the pre-fix code path this case reds
      # on), so the bound costs nothing where it is not needed.
      [ -n "${SURF_GREEDY_READER:-}" ] && { timeout 1 cat >/dev/null 2>&1 || true; }
      awk -v b="$1" '$1 == b { print $2 }' "$SURF_INTEG"
    }
    # shellcheck source=drill/rehearsal-app-surfaces.sh
    source "$ROOT/drill/rehearsal-app-surfaces.sh"
    "$@"
  )
}
surf_says() {  # surf_says <verdict lines> <label substring> → ok|FAIL|skip|absent
  local line
  line="$(printf '%s\n' "$1" | grep -F -- "$2" | head -1)"
  [ -n "$line" ] || { printf 'absent'; return 0; }
  printf '%s' "${line%% *}"
}

# --- #114: the auto-approve must read the verdict's STATE, not just its head -
# The re-request rule (ceremony#94) existed to stop a STALE verdict blocking a
# tree that has not changed. It never consulted the verdict's state, so a
# re-request over a standing CHANGES_REQUESTED at an unchanged head was answered
# with a boilerplate approval — 3 of its 4 recorded fires rubber-stamped a live
# block. rereq_decision is that policy as a pure function; pin every transition.
# A live block (CHANGES_REQUESTED / DISMISSED) queues a real review; only a
# standing APPROVED still auto-approves. Definition-only at the top level, so
# sourcing costs nothing and runs nothing.
# shellcheck disable=SC1091
source "$SHARED/lib/duty-review.sh"

# --- #159: the stamp is a claim, the manifest is the evidence ---------------
# ~/duty/VERSION said what was SHIPPED and nothing ever looked at what was
# THERE, so a hand-edited engine reported as in-sync and the next upgrade
# deleted the edit in silence. Three surfaces, asserted in order: the
# instrument, the installer that records and refuses, and the status the
# operator reads.


suite_finish
