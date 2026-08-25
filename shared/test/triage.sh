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
# --- the triage board poll follows the mention session (#253) ---------------
# _triage_repo used to compute all four board signals, THEN run the mention
# session (ceiling TIMEOUT_MENTION=1500), THEN decide on the values it had
# computed up to 25 minutes earlier — so a lead that died during the session
# still spent a full triage session, and a signal born during it waited a
# whole tick. These drive the real module under a stateful `gh` shim whose
# answers change when the mention session runs, in the shape _handoff_finalize
# is tested in above.
TRD="$TMP/tr-duty"; TRS="$TMP/tr-shim"; TRF="$TMP/tr-fix"
mkdir -p "$TRD/lib/jq" "$TRD/work" "$TRD/conf" "$TRS" "$TRF"
cp "$SHARED/lib/jq/blockers.jq" "$TRD/lib/jq/"
cp -r "$SHARED/prompts" "$TRD/prompts"
# The label vocabulary comes from the SHIPPED conf, not from assignments in
# this file (#358). The runner calls load_fleet_conf against this copy, so a
# queue label the engine's config does not define is a label these fixtures
# cannot silently supply on its behalf.
cp "$SHARED/conf/fleet.defaults.conf" "$TRD/conf/"
printf 'o/r\n' >"$TRD/repos.txt"
TR_CALLS="$TMP/tr-calls.log"; TR_PHASE="$TMP/tr-phase"
TR_LOG="$TMP/tr-log.txt"; TR_PROMPT="$TMP/tr-prompt"; TR_CHECKOUT="$TMP/tr-checkout"

# Phase 1 is the board before the mention session, phase 2 the board after it;
# the runner's run_session override flips the phase file. Every invocation is
# recorded, so the call log doubles as the "no extra reads" guard.
cat >"$TRS/gh" <<'TRGH'
#!/usr/bin/env bash
set -eu
# One line per invocation — the GraphQL query argument is multi-line, and the
# call log is counted, not just grepped.
printf '%s\n' "${*//$'\n'/ }" >>"$TR_CALLS"
p=1; [ -f "$TR_PHASE" ] && p="$(cat "$TR_PHASE")"
case "$*" in
  *"api notifications"*)    cat "$TR_FIX/notif.json" ;;
  *"api graphql"*)          cat "$TR_FIX/disc.$p.rows" ;;  # --jq is already applied
  *"--label needs-triage"*) cat "$TR_FIX/nt.$p.json" ;;
  *"--label blocked"*)      cat "$TR_FIX/blocked.$p.json" ;;
  *"--state all"*)          cat "$TR_FIX/numstates.json" ;;
  *"number,body,labels,updatedAt"*) cat "$TR_FIX/board.$p.json" ;;
  *"issue list"*)           cat "$TR_FIX/stray.$p.json" ;;
  *)                        printf '[]\n' ;;
esac
exit 0
TRGH
chmod +x "$TRS/gh"

cat >"$TMP/tr-run.sh" <<'TRRUN'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/duty-triage.sh"
load_fleet_conf
run_session() {
  printf 'SESSION %s\n' "$1" >>"$TR_CALLS"
  printf '%s' "$5" >"$TR_PROMPT.$1"
  # Phase 2 is the server state after either kind of session returns. The
  # production success path must re-read this state rather than committing
  # the phase-1 rows that launched it (#359).
  printf '2' >"$TR_PHASE"
  RUN_SESSION_RC="${TR_SESSION_RC:-0}"
}
ensure_checkout() { printf '%s\n' "$*" >>"$TR_CHECKOUT"; return 0; }
duty_triage
TRRUN

# Stray and discussion arguments are optional and default to an empty board,
# so calls written before their fixtures keep their meaning.
tr_fix() {  # notif nt1 nt2 blocked1 blocked2 numstates [stray1] [stray2] [disc1] [disc2]
  local p nt_file blocked_file stray_file
  printf '%s' "$1" >"$TRF/notif.json"
  printf '%s' "$2" >"$TRF/nt.1.json";      printf '%s' "$3" >"$TRF/nt.2.json"
  printf '%s' "$4" >"$TRF/blocked.1.json"; printf '%s' "$5" >"$TRF/blocked.2.json"
  printf '%s' "$6" >"$TRF/numstates.json"
  printf '%s' "${7:-[]}" >"$TRF/stray.1.json"
  printf '%s' "${8:-${7:-[]}}" >"$TRF/stray.2.json"
  printf '%s' "${9:-}" >"$TRF/disc.1.rows"
  printf '%s' "${10:-${9:-}}" >"$TRF/disc.2.rows"
  for p in 1 2; do
    nt_file="$TRF/nt.$p.json"
    blocked_file="$TRF/blocked.$p.json"
    stray_file="$TRF/stray.$p.json"
    jq -s '
      (.[0] | map(. + {body:(.body // null), labels:[{name:"needs-triage"}]}))
      + (.[1] | map(. + {updatedAt:(.updatedAt // "2026-08-01T00:00:00Z"),
                         labels:[{name:"blocked"}]}))
      + (.[2] | map(. + {body:(.body // null)}))
    ' "$nt_file" "$blocked_file" "$stray_file" >"$TRF/board.$p.json"
  done
}
tr_tick() {  # tr_tick <run_session rc>, preserving ledgers from earlier ticks
  : >"$TR_CALLS"
  : >"$TR_CHECKOUT"
  rm -f "$TR_PHASE" "$TR_PROMPT".*
  SHARED_DIR="$SHARED" TR_CALLS="$TR_CALLS" TR_PHASE="$TR_PHASE" TR_FIX="$TRF" \
  TR_PROMPT="$TR_PROMPT" TR_CHECKOUT="$TR_CHECKOUT" TR_SESSION_RC="$1" \
  DUTY_DIR="$TRD" ME=me-bot \
  TIMEOUT_MENTION=1 TIMEOUT_TRIAGE=1 MENTION_THREAD_CEILING="${TR_CEILING:-50}" \
  PATH="$TRS:$PATH" bash "$TMP/tr-run.sh" >"$TR_LOG" 2>&1
}
tr_run() {  # tr_run <run_session rc>, starting with cold ledgers
  rm -f "$TRD"/.seen-* "$TRD"/.suppressed-*
  tr_tick "$1"
}
trc() { grep -c -- "$1" "$TR_CALLS"; }
TR_MENTION='[{"id":"t1","reason":"mention","updated_at":"2026-08-01T15:40:00Z",
  "repository":{"full_name":"o/r"},"subject":{"url":"https://api/x"}}]'
TR_LEAD='[{"number":244,"body":"Blocked by #216.","updatedAt":"2026-08-01T15:30:00Z"}]'
TR_LANDED='[{"number":216,"state":"CLOSED"}]'

# The reported case: the sweep clears #244 forty-four seconds after the poll,
# and the session that would have been launched on it starts nineteen minutes
# later. Polled after the mention session, the lead is simply gone.
tr_fix "$TR_MENTION" '[]' '[]' "$TR_LEAD" '[]' "$TR_LANDED"
tr_run 0
t triage253-dead-lead-spends-no-triage-session 0 "$(trc '^SESSION triage$')"
t triage253-dead-lead-still-runs-the-mention 1 "$(trc '^SESSION mention$')"
if grep -q 'no triage signals — mention session was the only wake' "$TR_LOG"; then
  r1=said; else r1="$(cat "$TR_LOG")"; fi
t triage253-dead-lead-logs-mention-only said "$r1"
# Asserted on the prompt text, not only the session count: the two differ the
# moment another signal is live.
if [ -f "$TR_PROMPT.triage" ] && grep -q '244' "$TR_PROMPT.triage"; then
  r1=STALE_LEAD; else r1=none; fi
t triage253-dead-lead-not-in-prompt none "$r1"

# The positive control that keeps the assertion above from being vacuous: a
# lead that is STILL live after the mention session reaches the prompt.
tr_fix "$TR_MENTION" '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
t triage253-live-lead-launches-triage 1 "$(trc '^SESSION triage$')"
if grep -q 'unblockable' "$TR_PROMPT.triage" && grep -q '244' "$TR_PROMPT.triage"; then
  r1=named; else r1=MISSING; fi
t triage253-live-lead-named-in-prompt named "$r1"

# The inverse: a signal BORN during the mention session is seen by the same
# tick instead of waiting for the next one.
tr_fix "$TR_MENTION" '[]' '[{"number":999,"updatedAt":"2026-08-01T15:50:00Z"}]' \
  '[]' '[]' '[]'
tr_run 0
t triage253-newborn-signal-wakes-same-tick 1 "$(trc '^SESSION triage$')"
if grep -q '1x needs-triage' "$TR_LOG"; then r1=named; else r1="$(cat "$TR_LOG")"; fi
t triage253-newborn-signal-in-log named "$r1"
if grep -q 'o/r#999' "$TRD/.seen-triage-board"; then r1=ledgered; else r1=MISSING; fi
t triage253-newborn-signal-ledgered ledgered "$r1"

# Before any triage session launches, each signal is still polled exactly once.
# A successful session deliberately adds the #359 exit-state reads; a quiet
# tick adds none. These counts distinguish that bounded re-read from polling
# twice before the launch decision.
tr_fix "$TR_MENTION" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-reads-notifications-once 1 "$(trc 'api notifications')"
t triage253-reads-needs-triage-once   1 "$(trc '--label needs-triage')"
t triage253-reads-strays-once         1 "$(trc 'number,labels,updatedAt')"
t triage253-reads-discussions-once    1 "$(trc 'api graphql')"
t triage253-reads-blocked-once        1 "$(trc '--label blocked')"
t triage253-gh-calls-with-mention     5 "$(grep -vc '^SESSION' "$TR_CALLS")"
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-gh-calls-without-mention  5 "$(grep -vc '^SESSION' "$TR_CALLS")"
t triage253-quiet-tick-spends-nothing 0 "$(trc '^SESSION')"
if grep -q 'quiet — no mentions, no triage signals' "$TR_LOG"; then
  r1=said; else r1="$(cat "$TR_LOG")"; fi
t triage253-quiet-tick-log-unchanged said "$r1"
# The state-map reads still ride the non-empty blocked list, and nothing else.
tr_fix '[]' '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
t triage253-gh-calls-with-blocked-list 11 "$(grep -vc '^SESSION' "$TR_CALLS")"

# The mention path itself is untouched — the regression that matters, since
# this change moves code around that block. One session, kind mention, and the
# ledger committed only on rc 0.
tr_fix "$TR_MENTION" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-mention-only-one-session 1 "$(trc '^SESSION')"
t triage253-mention-only-kind        1 "$(trc '^SESSION mention$')"
if grep -q '^t1 ' "$TRD/.seen-mentions"; then r1=committed; else r1=MISSING; fi
t triage253-mention-ledger-on-rc0 committed "$r1"
tr_run 1
if [ -f "$TRD/.seen-mentions" ]; then r1=COMMITTED; else r1=withheld; fi
t triage253-mention-ledger-not-on-rcfail withheld "$r1"

# --- #466: one tick-wide mention batch across every configured repository --
tr466_mentions="$(jq -nc '[
  {id:"t1",reason:"mention",updated_at:"2026-08-24T10:01:00Z",
   repository:{full_name:"a/one"},subject:{url:"https://api/x/1",title:"SECRET-TITLE-ONE"}},
  {id:"t2",reason:"team_mention",updated_at:"2026-08-24T10:02:00Z",
   repository:{full_name:"b/two"},subject:{url:"https://api/x/2",title:"SECRET-TITLE-TWO"}},
  {id:"t3",reason:"mention",updated_at:"2026-08-24T10:03:00Z",
   repository:{full_name:"c/three"},subject:{url:"https://api/x/3",title:"SECRET-TITLE-THREE"}},
  {id:"t4",reason:"mention",updated_at:"2026-08-24T10:04:00Z",
   repository:{full_name:"d/four"},subject:{url:"https://api/x/4",title:"SECRET-TITLE-FOUR"}}
]')"
printf '%s\n' a/one b/two c/three d/four >"$TRD/repos.txt"
tr_fix "$tr466_mentions" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage466-four-repos-one-mention-session 1 "$(trc '^SESSION mention$')"
t triage466-four-repos-one-notifications-fetch 1 "$(trc 'api notifications')"
for repo in a/one b/two c/three d/four; do
  if grep -q "\"repo\":\"$repo\"" "$TR_PROMPT.mention"; then r1=qualified; else r1=MISSING; fi
  t "triage466-prompt-qualifies:$repo" qualified "$r1"
done
t triage466-success-commits-whole-batch 4 "$(awk 'NF{n++} END{print n+0}' "$TRD/.seen-mentions")"
if grep -q 'SECRET-TITLE' "$TR_PROMPT.mention"; then r1=LEAKED; else r1=absent; fi
t triage466-permissionless-prompt-omits-titles absent "$r1"
if [ -s "$TR_CHECKOUT" ]; then r1=CREATED; else r1=none; fi
t triage466-mention-batch-creates-no-checkout none "$r1"

# Crash and timeout are distinct exits but share the transaction boundary:
# neither may commit even one thread from the selected batch.
tr_run 1
if [ -f "$TRD/.seen-mentions" ]; then r1=COMMITTED; else r1=withheld; fi
t triage466-crash-commits-none withheld "$r1"
tr_run 124
if [ -f "$TRD/.seen-mentions" ]; then r1=COMMITTED; else r1=withheld; fi
t triage466-timeout-commits-none withheld "$r1"

# The ceiling is delivery control, not truncation: only the selected prefix is
# committed, and the remainder is the sole wake on the following tick.
TR_CEILING=2
tr_run 0
t triage466-ceiling-first-tick-commits-two 2 "$(awk 'NF{n++} END{print n+0}' "$TRD/.seen-mentions")"
t triage466-ceiling-first-tick-one-session 1 "$(trc '^SESSION mention$')"
tr_tick 0
t triage466-ceiling-second-tick-commits-remainder 4 "$(awk 'NF{n++} END{print n+0}' "$TRD/.seen-mentions")"
t triage466-ceiling-second-tick-one-session 1 "$(trc '^SESSION mention$')"
if grep -q '"thread":"t1"\|"thread":"t2"' "$TR_PROMPT.mention"; then r1=REPEATED; else r1=remainder-only; fi
t triage466-ceiling-second-prompt-is-remainder remainder-only "$r1"
unset TR_CEILING
# shellcheck disable=SC2016  # matching the module's literal variable reference
if grep -q '^MENTION_THREAD_CEILING=[0-9][0-9]*$' "$SHARED/conf/roles/triage.conf" &&
   grep -q 'ceiling="$MENTION_THREAD_CEILING"' "$SHARED/lib/duty-triage.sh"; then
  r1=wired; else r1=MISSING; fi
t triage466-configurable-thread-ceiling-wired wired "$r1"

# A quiet snapshot is still one bounded fetch, with no model or checkout.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage466-quiet-four-repo-fetch-once 1 "$(trc 'api notifications')"
t triage466-quiet-four-repo-no-session 0 "$(trc '^SESSION')"
if [ -s "$TR_CHECKOUT" ]; then r1=CREATED; else r1=none; fi
t triage466-quiet-four-repo-no-checkout none "$r1"

# Restore the single-repo fixture used by the pre-existing signal cases.
printf 'o/r\n' >"$TRD/repos.txt"

# Static ordering, in the style of the module-wiring checks above: every board
# read must sit BELOW the mention call site, and the launch decision below all
# of them. Cheap, and it fails loudly if a later edit hoists a poll back up.
TRIAGE_MOD="$SHARED/lib/duty-triage.sh"
tr_ln() { grep -Fn -- "$1" "$TRIAGE_MOD" | head -1 | cut -d: -f1; }
tr_mention_ln="$(tr_ln 'run_session mention')"
# shellcheck disable=SC2016  # matching the module's literal source text
tr_decide_ln="$(tr_ln '[ -z "$signals" ]')"
# shellcheck disable=SC2016  # ditto
for probe in '--label "$LABEL_NEEDS_TRIAGE"' 'number,labels,updatedAt' \
             '_triage_discussion_items "$R"' '--label "$LABEL_BLOCKED"'; do
  probe_ln="$(tr_ln "$probe")"
  if [ -n "$probe_ln" ] && [ "$probe_ln" -gt "$tr_mention_ln" ]; then
    r1=after; else r1="BEFORE($probe_ln vs $tr_mention_ln)"; fi
  t "triage253-poll-after-mention:$probe" after "$r1"
  if [ -n "$probe_ln" ] && [ "$probe_ln" -lt "$tr_decide_ln" ]; then
    r1=before; else r1="AFTER($probe_ln vs $tr_decide_ln)"; fi
  t "triage253-poll-before-decision:$probe" before "$r1"
done

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

# --- #358: post-merge is a queue label, and the engine's set is LABELS.md's -
# LABELS.md declares a SIX-label board invariant; fleet.defaults.conf defined
# five and signal (b) selected on those five. So the moment triage did its job
# — a Refs-linked PR merges, the issue moves claimed -> post-merge — it turned
# that issue into a permanent violation of the engine's own invariant, one no
# session could ever clear because post-merge is the correct terminal state.
# All four live matches on this board were that false positive.
#
# Both directions are driven through the real module and the same shim: the
# select is proven by what it selects, never by reading it. The label values
# reach the module from the SHIPPED conf (see the TRD/conf copy above), so a
# label the engine's config does not define cannot pass here.
TR358_STAMP='2026-08-05T00:00:00Z'
tr358_board() {  # tr358_board <label|-> ... — one open issue per argument
  printf '%s\n' "$@" | jq -R . | jq -cs --arg s "$TR358_STAMP" \
    'to_entries | map({number: (100 + .key),
                       labels: (if .value == "-" then [] else [{name: .value}] end),
                       updatedAt: $s})'
}

# Direction one — an issue whose only queue label is post-merge is not a stray.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$(tr358_board post-merge)"
tr_run 0
t triage358-post-merge-spends-no-session 0 "$(trc '^SESSION')"
if grep -q 'queue-unlabeled' "$TR_LOG"; then r1="$(cat "$TR_LOG")"; else r1=silent; fi
t triage358-post-merge-raises-no-signal silent "$r1"
if grep -q 'quiet — no mentions, no triage signals' "$TR_LOG"; then
  r1=quiet; else r1="$(cat "$TR_LOG")"; fi
t triage358-post-merge-tick-is-quiet quiet "$r1"
# The fixture analogue of this issue's post-merge criterion: the suppression
# report must not name it either. A signal that is merely ledgered still WARNs
# every tick, which is the cost this issue is about.
suppressed_triage_board="$(cat "$TRD"/.suppressed-triage-board.* 2>/dev/null)"
if grep -q 'o/r#100' <<<"$suppressed_triage_board"; then
  r1=NAMED; else r1=absent; fi
t triage358-post-merge-not-in-suppressed absent "$r1"

# Direction two — an issue carrying none of the six still is one. The detector
# is narrowed to the truth, not silenced; a select widened until it is quiet is
# the failure mode this half exists to prevent.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$(tr358_board -)"
tr_run 0
t triage358-unlabeled-still-a-stray 1 "$(trc '^SESSION triage$')"
if grep -q '1x queue-unlabeled' "$TR_LOG"; then r1=named; else r1="$(cat "$TR_LOG")"; fi
t triage358-unlabeled-signal-named named "$r1"
# ...and a label outside the queue vocabulary does not stand in for one.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$(tr358_board bug)"
tr_run 0
t triage358-non-queue-label-still-a-stray 1 "$(trc '^SESSION triage$')"

# The doctrine's own sentence, parsed rather than restated: from its opening
# clause to the end of that sentence, which is the first backtick-then-period
# — the full stop closing the last backticked label.
tr358_doctrine="$(awk '
  /invariant a board scan relies on/ { on = 1 }
  on { printf "%s ", $0 }
  on && /`\./ { exit }
' "$ROOT/.ceremony/LABELS.md")"
tr358_doctrine="${tr358_doctrine%%\`.*}\`"
# shellcheck disable=SC2016  # a grep pattern: the backticks are LABELS.md's
tr358_doctrine_set="$(printf '%s' "$tr358_doctrine" | grep -o '`[a-z][a-z-]*`' \
  | tr -d '`' | sort -u | tr '\n' ' ')"
# Anti-vacuity guard, and the only place a count is written down: without it a
# parse that silently stops matching compares an empty set to an empty set and
# passes. It asserts cardinality, never membership — the comparison below is
# what asserts which labels, and it is derived on both sides.
t triage358-doctrine-set-nonvacuous 6 "$(printf '%s' "$tr358_doctrine_set" | wc -w | tr -d ' ')"

# The engine's set, taken from signal (b)'s own --arg list and resolved through
# the shipped conf. A label added to LABELS.md and not to the engine fails
# here, and so does one added to the engine and not to LABELS.md.
tr358_select="$(awk '/elif ! stray_items=/,/stray parse failed/' "$SHARED/lib/duty-triage.sh")"
# shellcheck disable=SC2016  # a grep pattern: the $LABEL_ is the module's text
tr358_pairs="$(printf '%s\n' "$tr358_select" \
  | grep -o -- '--arg [a-z_]* "\$LABEL_[A-Z_]*"' \
  | sed 's/--arg \([a-z_]*\) "\$\(LABEL_[A-Z_]*\)"/\1 \2/')"
tr358_engine_set=""
while read -r tr358_arg tr358_var; do
  [ -n "${tr358_arg:-}" ] || continue
  # Declared is not consulted: an --arg the select never tests is a label the
  # engine does not actually accept, so it is reported rather than counted.
  case "$tr358_select" in
    *". == \$$tr358_arg"*) ;;
    *) tr358_engine_set="$tr358_engine_set UNCONSULTED-$tr358_arg"; continue ;;
  esac
  tr358_engine_set="$tr358_engine_set $(sed -n "s/^$tr358_var=\"\(.*\)\"\$/\1/p" \
    "$SHARED/conf/fleet.defaults.conf" | head -1)"
done <<TR358PAIRS
$tr358_pairs
TR358PAIRS
# shellcheck disable=SC2086  # deliberate word-splitting: these are set members
tr358_engine_set="$(printf '%s\n' $tr358_engine_set | sort -u | tr '\n' ' ')"
t triage358-engine-set-is-the-doctrine-set "$tr358_doctrine_set" "$tr358_engine_set"
# Named separately so the conf's own omission — the whole defect — reads as
# itself rather than as a set diff.
if grep -q '^LABEL_POST_MERGE="post-merge"$' "$SHARED/conf/fleet.defaults.conf"; then
  r1=defined; else r1=MISSING; fi
t triage358-conf-defines-post-merge defined "$r1"

suite_finish
