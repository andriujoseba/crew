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
  *"number,body,updatedAt,labels"*) cat "$TR_FIX/board.$p.json" ;;
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

# Before any triage session launches, the shared open-board snapshot and each
# remaining independent signal are still polled exactly once.
# A successful session deliberately adds the #359 exit-state reads; a quiet
# tick adds none. These counts distinguish that bounded re-read from polling
# twice before the launch decision.
tr_fix "$TR_MENTION" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-reads-notifications-once 1 "$(trc 'api notifications')"
t triage253-reads-open-board-once     1 "$(trc 'number,body,updatedAt,labels')"
t triage253-reads-discussions-once    1 "$(trc 'api graphql')"
t triage253-gh-calls-with-mention     3 "$(grep -vc '^SESSION' "$TR_CALLS")"
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage253-gh-calls-without-mention  3 "$(grep -vc '^SESSION' "$TR_CALLS")"
t triage253-quiet-tick-spends-nothing 0 "$(trc '^SESSION')"
if grep -q 'quiet — no mentions, no triage signals' "$TR_LOG"; then
  r1=said; else r1="$(cat "$TR_LOG")"; fi
t triage253-quiet-tick-log-unchanged said "$r1"
# The state-map reads still ride the non-empty declaration graph, and nothing else.
tr_fix '[]' '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
t triage253-gh-calls-with-blocked-list 9 "$(grep -vc '^SESSION' "$TR_CALLS")"

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

# The neutral session gets no checkout doctrine. Each thread must first resolve
# its own repository's entrypoint over the API and follow that router, rather
# than treating a bare role filename as relative to DUTY_DIR.
# shellcheck disable=SC2016  # the rendered prompt deliberately carries $repo
if grep -Fq 'gh api "repos/$repo/contents/AGENTS.md"' "$TR_PROMPT.mention" &&
   grep -Fq 'same repository-qualified contents API' "$TR_PROMPT.mention"; then
  r1=qualified; else r1=MISSING; fi
t triage466-doctrine-entrypoint-is-repository-qualified qualified "$r1"
doctrine_line="$(grep -n 'default-branch entrypoint' "$TR_PROMPT.mention" | head -1 | cut -d: -f1)"
thread_line="$(grep -n 'subject URL to fetch' "$TR_PROMPT.mention" | head -1 | cut -d: -f1)"
if [ -n "$doctrine_line" ] && [ -n "$thread_line" ] && [ "$doctrine_line" -lt "$thread_line" ]; then
  r1=before; else r1=WRONG_ORDER; fi
t triage466-doctrine-is-read-before-thread before "$r1"
if grep -Fq 'answer per TRIAGE.md' "$TR_PROMPT.mention" ||
   ! grep -Fq 'Do not resolve doctrine from the working directory' "$TR_PROMPT.mention"; then
  r1=RELATIVE; else r1=neutral-safe; fi
t triage466-doctrine-has-no-working-directory-relative-path neutral-safe "$r1"

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
t triage466-ceiling-deferred-repos-not-quiet 2 \
  "$(grep -c 'mentions deferred by fleet ceiling' "$TR_LOG")"
if grep -E '^(c/three|d/four): quiet — no mentions' "$TR_LOG" >/dev/null; then
  r1=QUIET; else r1=deferred; fi
t triage466-ceiling-deferred-repos-state-named deferred "$r1"
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

# A successful notifications request may produce no pagination documents at
# all. That is an empty snapshot, not a probe failure.
tr_fix '' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage466-empty-response-fetch-once 1 "$(trc 'api notifications')"
t triage466-empty-response-no-session 0 "$(trc '^SESSION')"
if grep -q 'notifications probe failed' "$TR_LOG"; then r1=WARNED; else r1=empty; fi
t triage466-empty-response-is-not-probe-failure empty "$r1"

# With no configured repositories there is nothing to partition, so the tick
# does not spend an otherwise-useless notifications pagination or create work.
: >"$TRD/repos.txt"
tr_fix "$TR_MENTION" '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage466-empty-repo-list-fetches-nothing 0 "$(trc 'api notifications')"
t triage466-empty-repo-list-launches-nothing 0 "$(trc '^SESSION')"
if [ -s "$TR_CHECKOUT" ]; then r1=CREATED; else r1=none; fi
t triage466-empty-repo-list-creates-no-checkout none "$r1"

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
for probe in '_triage_discussion_items "$R"' 'number,body,updatedAt,labels'; do
  probe_ln="$(tr_ln "$probe")"
  if [ -n "$probe_ln" ] && [ "$probe_ln" -gt "$tr_mention_ln" ]; then
    r1=after; else r1="BEFORE($probe_ln vs $tr_mention_ln)"; fi
  t "triage253-poll-after-mention:$probe" after "$r1"
  if [ -n "$probe_ln" ] && [ "$probe_ln" -lt "$tr_decide_ln" ]; then
    r1=before; else r1="AFTER($probe_ln vs $tr_decide_ln)"; fi
  t "triage253-poll-before-decision:$probe" before "$r1"
done

# --- #468: fast-tick triage receives the enumerated wake set ---------------
TR468_STAMP='2026-08-26T08:00:00Z'
tr468_only_family() {  # expected line, forbidden family headings
  local expected="$1" forbidden="$2"
  if grep -Fq -- "$expected" "$TR_PROMPT.triage"; then r1=named; else r1=MISSING; fi
  t "triage468-names:${expected%%:*}" named "$r1"
  if grep -Eq -- "$forbidden" "$TR_PROMPT.triage"; then r1=EMPTY_HEADING; else r1=omitted; fi
  t "triage468-omits-empty:${expected%%:*}" omitted "$r1"
}

# One family at a time proves that the identifiers already used for ledger
# gating reach the prompt, while absent families render no empty headings.
tr_fix '[]' '[{"number":101,"updatedAt":"2026-08-26T08:00:00Z"}]' \
  '[{"number":101,"updatedAt":"2026-08-26T08:00:00Z"}]' '[]' '[]' '[]'
tr_run 0
tr468_only_family 'Needs-triage issues: #101' \
  'Queue-unlabeled issues:|Unresolved discussions without your voice:|Possibly unblockable issues:'

tr_fix '[]' '[]' '[]' '[]' '[]' '[]' \
  '[{"number":102,"labels":[],"updatedAt":"2026-08-26T08:00:00Z"}]'
tr_run 0
tr468_only_family 'Queue-unlabeled issues: #102' \
  'Needs-triage issues:|Unresolved discussions without your voice:|Possibly unblockable issues:'

tr_fix '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' \
  "o/r#103 $TR468_STAMP"
tr_run 0
tr468_only_family 'Unresolved discussions without your voice: #103' \
  'Needs-triage issues:|Queue-unlabeled issues:|Possibly unblockable issues:'

tr_fix '[]' '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
tr468_only_family 'Possibly unblockable issues: #244' \
  'Needs-triage issues:|Queue-unlabeled issues:|Unresolved discussions without your voice:'
if grep -Fq 'Treat these as leads, not verdicts' "$TR_PROMPT.triage"; then
  r1=preserved; else r1=MISSING; fi
t triage468-unblockable-caveat-preserved preserved "$r1"
if grep -Fq 'every issue or PR named in their "Blocked by" clause must now read CLOSED or MERGED' \
    "$TR_PROMPT.triage"; then r1=preserved; else r1=MISSING; fi
t triage468-unblockable-condition-preserved preserved "$r1"
if grep -q '{{' "$TR_PROMPT.triage"; then r1=RAW_SLOT; else r1=rendered; fi
t triage468-renders-all-template-slots rendered "$r1"

# A mixed wake is one block with all four families, not four independently
# rendered fragments. Each family retains its own item identifiers.
tr_fix '[]' '[{"number":111,"updatedAt":"2026-08-26T08:00:00Z"}]' \
  '[{"number":111,"updatedAt":"2026-08-26T08:00:00Z"}]' \
  "$TR_LEAD" "$TR_LEAD" "$TR_LANDED" \
  '[{"number":112,"labels":[],"updatedAt":"2026-08-26T08:00:00Z"}]' \
  '[{"number":112,"labels":[],"updatedAt":"2026-08-26T08:00:00Z"}]' \
  "o/r#113 $TR468_STAMP" "o/r#113 $TR468_STAMP"
tr_run 0
for named in 'Needs-triage issues: #111' 'Queue-unlabeled issues: #112' \
             'Unresolved discussions without your voice: #113' \
             'Possibly unblockable issues: #244'; do
  if grep -Fq -- "$named" "$TR_PROMPT.triage"; then r1=named; else r1=MISSING; fi
  t "triage468-mixed:${named%%:*}" named "$r1"
done
t triage468-mixed-one-signal-block 1 \
  "$(grep -c 'This fast-tick session was launched for the following named work:' "$TR_PROMPT.triage")"
if grep -q '^Converge the named items first[.] The whole-board sweep runs hourly under ' \
    "$TR_PROMPT.triage"; then r1=separate; else r1=JOINED; fi
t triage468-instructions-follow-signal-block-on-new-line separate "$r1"

# Scope changes, not quality changes: the old issue contract, outcome list and
# label-event rule remain exact substrings, behind the newly named work.
# shellcheck disable=SC2016  # the backticks are literal prompt prose
for required in \
  'The whole-board sweep runs hourly under `hygiene.txt`; this fast-tick session does not enumerate the board for more work.' \
  'You may act outside the named set when resolving one of its items requires it, but do not enumerate outside the set.' \
  'For stray issues — anything not minted by you — either normalize them to the issue contract or close them politely, pointing the filer at Discussions: their idea is welcome, the door is over there.' \
  'For discussions, converge each unresolved one to exactly one outcome — answer, ask, escalate, decline, or accept — and every issue you mint meets the contract.' \
  "Before asserting label-borne state in prose, re-read the issue's label events (the timeline API), not just its comments — label events govern over stale prose."; do
  if grep -Fq -- "$required" "$TR_PROMPT.triage"; then r1=present; else r1=MISSING; fi
  t "triage468-required-prose:${required%% *}" present "$r1"
done

# The empty-signal path remains the existing early return: no prompt is
# rendered and no repo session launches.
tr_fix '[]' '[]' '[]' '[]' '[]' '[]'
tr_run 0
t triage468-empty-set-launches-nothing 0 "$(trc '^SESSION triage$')"
if [ -f "$TR_PROMPT.triage" ]; then r1=RENDERED; else r1=absent; fi
t triage468-empty-set-renders-no-prompt absent "$r1"

# --- #471: declared predecessor state changes wake a scoped re-read --------
tr471_issue() {  # tr471_issue NUMBER BODY
  jq -nc --argjson n "$1" --arg body "$2" \
    '[{number:$n,body:$body,labels:[{name:"ready"}],updatedAt:"2026-08-26T09:00:00Z"}]'
}
tr471_states() {  # tr471_states NUMBER STATE [NUMBER STATE ...]
  local rows='[]' number state
  while [ "$#" -gt 0 ]; do
    number="$1"; state="$2"; shift 2
    rows="$(jq -c --argjson n "$number" --arg s "$state" \
      '. + [{number:$n,state:$s}]' <<<"$rows")"
  done
  printf '%s\n' "$rows"
}

TR471_ONE="$(tr471_issue 471 'Blocked by #900. This discharged declaration remains as prose.')"

# Signals (e) and (f) must recognize exactly the same declaration grammar.
# The graph parser points back to the canonical corpus-tested jq file; this
# comparison prevents either byte-identical definition drifting silently.
tr471_graph_blockers="$(awk '
  /^    def blockers:/ { on=1 }
  on { sub(/^    /, ""); print }
  on && /;$/ { exit }
' "$SHARED/lib/duty-triage.sh")"
tr471_unblockable_blockers="$(awk '
  /^def blockers:/ { on=1 }
  on { print }
  on && /;$/ { exit }
' "$SHARED/lib/jq/blockers.jq")"
t triage471-signals-e-and-f-share-blocker-parser \
  "$tr471_unblockable_blockers" "$tr471_graph_blockers"

# A cold edge is work once, including the historical-prose shape where the
# predecessor landed before this ledger existed. The successful session
# records the exact edge state, so an unchanged second tick is silent.
tr_fix '[]' '[]' '[]' '[]' '[]' "$(tr471_states 900 CLOSED)" \
  "$TR471_ONE" "$TR471_ONE"
tr_run 0
t triage471-closed-prose-wakes-once 1 "$(trc '^SESSION triage$')"
if grep -Fq '#471 depends on #900: UNSEEN -> CLOSED' "$TR_PROMPT.triage"; then
  r1=named; else r1=MISSING; fi
t triage471-closed-prose-names-transition named "$r1"
if grep -q '^o/r#471#900 CLOSED$' "$TRD/.seen-graph"; then r1=edge-keyed; else r1=MISSING; fi
t triage471-ledger-keys-on-edge edge-keyed "$r1"
tr_tick 0
t triage471-closed-prose-second-tick-quiet 0 "$(trc '^SESSION triage$')"
# On this exact ready/prose fixture, origin/main's steady tick spends five
# calls: notifications, needs-triage, strays, discussions, and blocked issues.
# The widened graph replaces the three issue-list calls with one shared board
# read, spending the saved two on the issue/PR state map and preserving five.
TR471_PRE_CHANGE_PROSE_CALL_FLOOR=5
t triage471-retained-prose-keeps-pre-change-call-floor \
  "$TR471_PRE_CHANGE_PROSE_CALL_FLOOR" "$(grep -vc '^SESSION' "$TR_CALLS")"

# The #159 shape: a predecessor moves from OPEN to MERGED while the dependant
# remains open. The prompt names both ends, the transition, and the bounded
# body re-read; the engine itself performs no board write.
tr_fix '[]' '[]' '[]' '[]' '[]' "$(tr471_states 900 OPEN)" \
  "$TR471_ONE" "$TR471_ONE"
tr_run 0
tr_fix '[]' '[]' '[]' '[]' '[]' "$(tr471_states 900 MERGED)" \
  "$TR471_ONE" "$TR471_ONE"
tr_tick 0
t triage471-merged-predecessor-wakes 1 "$(trc '^SESSION triage$')"
if grep -Fq '#471 depends on #900: OPEN -> MERGED' "$TR_PROMPT.triage" && \
   grep -Fq "Re-read each dependant's body" "$TR_PROMPT.triage"; then
  r1=named; else r1=MISSING; fi
t triage471-merged-prompt-names-edge-and-action named "$r1"
if grep -Eq 'issue (edit|comment)|api .*(POST|PATCH)|--add-label|--remove-label' "$TR_CALLS"; then
  r1=MUTATED; else r1=read-only; fi
t triage471-path-writes-no-label-or-comment read-only "$r1"
t triage471-reads-open-issues-once 1 "$(trc 'number,body,updatedAt,labels')"
if grep -Fq 'These are leads, not verdicts' "$TR_PROMPT.triage"; then
  r1=present; else r1=MISSING; fi
t triage471-lead-not-verdict-caveat present "$r1"

# Reopening is a state change too: comparison is exact, not an assumed
# one-way ordering of GitHub's state words.
tr_fix '[]' '[]' '[]' '[]' '[]' "$(tr471_states 900 OPEN)" \
  "$TR471_ONE" "$TR471_ONE"
tr_tick 0
if grep -Fq '#471 depends on #900: MERGED -> OPEN' "$TR_PROMPT.triage"; then
  r1=named; else r1=MISSING; fi
t triage471-reopened-predecessor-wakes named "$r1"

# Three edges on one dependant are independent ledger keys. Advancing one per
# tick must produce one named transition per tick rather than collapsing the
# whole dependant after the first wake.
TR471_THREE="$(tr471_issue 472 'Blocked by #901, #902, #903.')"
tr_fix '[]' '[]' '[]' '[]' '[]' \
  "$(tr471_states 901 OPEN 902 OPEN 903 OPEN)" "$TR471_THREE" "$TR471_THREE"
tr_run 0
t triage471-three-edges-recorded 3 "$(grep -c '^o/r#472#90[123] OPEN$' "$TRD/.seen-graph")"
for landed in 901 902 903; do
  s901=OPEN; s902=OPEN; s903=OPEN
  [ "$landed" -ge 901 ] && s901=MERGED
  [ "$landed" -ge 902 ] && s902=MERGED
  [ "$landed" -ge 903 ] && s903=MERGED
  tr_fix '[]' '[]' '[]' '[]' '[]' \
    "$(tr471_states 901 "$s901" 902 "$s902" 903 "$s903")" \
    "$TR471_THREE" "$TR471_THREE"
  tr_tick 0
  t "triage471-three-edges-tick-$landed-wakes-once" 1 \
    "$(grep -c 'depends on' "$TR_PROMPT.triage")"
done

# Multiple edges advancing in one tick render as multiple prompt lines. This
# catches both a collapsed edge list and a literal trailing backslash-n.
TR471_TWO="$(tr471_issue 473 'Blocked by #904, #905.')"
tr_fix '[]' '[]' '[]' '[]' '[]' \
  "$(tr471_states 904 MERGED 905 CLOSED)" "$TR471_TWO" "$TR471_TWO"
tr_run 0
t triage471-two-same-tick-edges-render-two-lines 2 \
  "$(grep -c '^  - #473 depends on #90[45]:' "$TR_PROMPT.triage")"
if grep -Fq '\n' "$TR_PROMPT.triage"; then r1=LITERAL_ESCAPE; else r1=rendered; fi
t triage471-two-same-tick-edges-have-no-literal-escape rendered "$r1"

# Signal (e) still consumes the blocked subset from the widened read and
# renders its established lead alongside (f); no existing verdict moved.
tr_fix '[]' '[]' '[]' "$TR_LEAD" "$TR_LEAD" "$TR_LANDED"
tr_run 0
if grep -Fq 'Possibly unblockable issues: #244' "$TR_PROMPT.triage"; then
  r1=unchanged; else r1=MISSING; fi
t triage471-signal-e-unblockable-verdict-unchanged unchanged "$r1"

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
tr358_select="$(awk '/if ! stray_items=/,/stray parse failed/' "$SHARED/lib/duty-triage.sh")"
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

# --- #461: operator ownership composes with ready, but is not build duty ----
# Signal (b) stays a six-queue-label question. The builder consumes the same
# board differently: `ready` says the work is unblocked, while `operator` says
# it belongs to a human rather than this engine. Drive the production filter
# directly, then derive the exact board count / ledger count / no-duty branch
# its call site uses. This keeps an empty ledger from accidentally becoming the
# implementation and makes the populated-ledger control the same observation.
# shellcheck disable=SC1091
source "$SHARED/lib/duty-builder.sh"

OP461_T='2026-08-27T00:00:00Z'
OP461_OPERATOR="$(jq -cn --arg t "$OP461_T" '[{
  number: 461, assignees: [], updatedAt: $t,
  labels: [{name:"ready"},{name:"operator"}]
}]')"
OP461_PLAIN="$(jq -cn --arg t "$OP461_T" '[{
  number: 461, assignees: [], updatedAt: $t,
  labels: [{name:"ready"}]
}]')"
OP461_SEEN_COLD="$TMP/op461-seen-cold"
OP461_SEEN_HOT="$TMP/op461-seen-hot"
printf 'o/r#461 %s\n' "$OP461_T" | ledger_commit "$OP461_SEEN_HOT"

op461_signal() {  # JSON OPERATOR_LABEL LEDGER — session-count<TAB>reason
  local json="$1" operator_label="$2" ledger="$3"
  local items board count sessions=0 reason=""
  items="$(printf '%s' "$json" | _ready_issue_lines o/r "$operator_label")"
  board="$(printf '%s\n' "$items" | awk 'NF{c++} END{print c+0}')"
  count="$(printf '%s\n' "$items" | ledger_filter "$ledger" | awk 'NF{c++} END{print c+0}')"
  if [ "$count" -gt 0 ]; then
    sessions=1
    reason=build-duty
  else
    reason="$(_no_build_duty_reason "$board" 0 '' 1)"
  fi
  printf '%s\t%s' "$sessions" "$reason"
}

OP461_COLD="$(op461_signal "$OP461_OPERATOR" operator "$OP461_SEEN_COLD")"
OP461_HOT="$(op461_signal "$OP461_OPERATOR" operator "$OP461_SEEN_HOT")"
t operator-ready-cold-starts-no-session 0 "${OP461_COLD%%$'\t'*}"
t operator-ready-cold-is-board-empty 'board empty' "${OP461_COLD#*$'\t'}"
case "$OP461_COLD" in *seen-ledger*) r1=WRONG_NOUN ;; *) r1=absent ;; esac
t operator-ready-is-not-ledger-held absent "$r1"
t operator-ready-ledger-independent "$OP461_COLD" "$OP461_HOT"

OP461_PLAIN_SIGNAL="$(op461_signal "$OP461_PLAIN" operator "$OP461_SEEN_COLD")"
t operator-plain-ready-starts-one-session 1 "${OP461_PLAIN_SIGNAL%%$'\t'*}"
t operator-plain-ready-is-build-duty build-duty "${OP461_PLAIN_SIGNAL#*$'\t'}"

# Compatibility is fail-open by design: an older/unset config sees exactly the
# pre-#461 ready set and raises no jq error.
OP461_UNSET="$(op461_signal "$OP461_OPERATOR" '' "$OP461_SEEN_COLD")"
t operator-unset-keeps-ready-pickable 1 "${OP461_UNSET%%$'\t'*}"
t operator-unset-keeps-old-build-signal build-duty "${OP461_UNSET#*$'\t'}"

# Wiring: the one existing ready listing carries labels, the production
# ready_items assignment calls the filter, and the filtered set is counted
# afterwards. A prompt-only implementation or an after-ready_board exclusion
# fails one of these independently of the behavioural helper cases above.
OP461_BUILD="$SHARED/lib/duty-builder.sh"
if grep -Fq -- '--json number,assignees,labels,updatedAt' "$OP461_BUILD"; then
  r1=fetched
else
  r1=MISSING
fi
t operator-ready-listing-fetches-labels fetched "$r1"
# shellcheck disable=SC2016  # source literals, not test-shell expansions
op461_filter_ln="$(grep -nF '| _ready_issue_lines "$R" "${LABEL_OPERATOR:-}"' "$OP461_BUILD" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # source literal, not command substitution here
op461_board_ln="$(grep -nF 'ready_board="$(' "$OP461_BUILD" | head -1 | cut -d: -f1)"
if [ -n "$op461_filter_ln" ] && [ -n "$op461_board_ln" ] &&
   [ "$op461_filter_ln" -lt "$op461_board_ln" ]; then
  r1=before
else
  r1=AFTER
fi
t operator-filter-precedes-ready-board before "$r1"

# The composing flag is configured beside the other cross-cutting names and
# never enters either copy of the six-member queue set. The existing #358 set
# equality above is the behavioural half; these assertions pin the tempting
# but wrong "seventh queue label" tidy-up.
if grep -q '^LABEL_OPERATOR="operator"$' "$SHARED/conf/fleet.defaults.conf"; then
  r1=defined
else
  r1=MISSING
fi
t operator-conf-defines-composing-label defined "$r1"
op461_queue_count="$(sed -n '/^LABEL_READY=/,/^LABEL_NEEDS_TRIAGE=/p' \
  "$SHARED/conf/fleet.defaults.conf" | grep -c '^LABEL_[A-Z_]*=')"
t operator-queue-set-stays-six 6 "$op461_queue_count"
op461_queue_block="$(sed -n '/^LABEL_READY=/,/^LABEL_NEEDS_TRIAGE=/p' \
  "$SHARED/conf/fleet.defaults.conf")"
if grep -q 'LABEL_OPERATOR' <<<"$op461_queue_block"; then
  r1=IN_QUEUE
else
  r1=outside
fi
t operator-label-stays-outside-queue-block outside "$r1"
if grep -q 'LABEL_OPERATOR' "$SHARED/lib/duty-triage.sh"; then
  r1=TOUCHED
else
  r1=untouched
fi
t operator-triage-detector-needs-no-new-label untouched "$r1"

# `ready` already satisfies triage signal (b), so composing `operator` must not
# turn the issue into a stray. Conversely operator alone is not a queue state.
OP461_STRAY_READY='[{"number":461,"labels":[{"name":"ready"},{"name":"operator"}],"updatedAt":"2026-08-27T00:00:00Z"}]'
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$OP461_STRAY_READY"
tr_run 0
t operator-ready-is-not-a-triage-session 0 "$(trc '^SESSION triage$')"
if grep -q 'queue-unlabeled' "$TR_LOG"; then r1=NAMED; else r1=silent; fi
t operator-ready-is-not-queue-unlabeled silent "$r1"
OP461_STRAY_ONLY='[{"number":461,"labels":[{"name":"operator"}],"updatedAt":"2026-08-27T00:00:00Z"}]'
tr_fix '[]' '[]' '[]' '[]' '[]' '[]' "$OP461_STRAY_ONLY"
tr_run 0
t operator-alone-is-still-a-stray 1 "$(trc '^SESSION triage$')"

# The prompt clause uses the configured name and disappears completely when
# unset. Its empty rendering preserves the old sentence byte-for-byte around
# the insertion point; the configured rendering tells a session the same rule
# the engine enforced.
t operator-empty-prompt-clause-is-byte-empty '' "$(_operator_build_prompt_clause '')"
OP461_CLAUSE="$(_operator_build_prompt_clause operator)"
# shellcheck disable=SC2016  # prompt backticks are literal prose
case "$OP461_CLAUSE" in
  *'`operator`'*'operator-owned work, not work for a builder'*) r1=named ;;
  *) r1=MISSING ;;
esac
t operator-configured-prompt-clause-names-ownership named "$r1"
OP461_PROMPT_EMPTY="$(PROMPTS_DIR="$SHARED/prompts" render_prompt build.txt OPERATOR_CLAUSE='')"
if grep -Fq 'otherwise pick ONE ready unclaimed issue, claim it' <<<"$OP461_PROMPT_EMPTY" &&
   ! grep -q '{{OPERATOR_CLAUSE}}' <<<"$OP461_PROMPT_EMPTY"; then
  r1=identical
else
  r1=CHANGED
fi
t operator-unset-prompt-keeps-old-sentence identical "$r1"
OP461_PROMPT_SET="$(PROMPTS_DIR="$SHARED/prompts" render_prompt build.txt OPERATOR_CLAUSE="$OP461_CLAUSE")"
# shellcheck disable=SC2016  # prompt backticks are literal prose
if grep -Fq 'a ready issue carrying `operator` is operator-owned work, not work for a builder; otherwise pick ONE ready unclaimed issue, claim it' <<<"$OP461_PROMPT_SET"; then
  r1=rendered
else
  r1=MISSING
fi
t operator-configured-prompt-renders-clause rendered "$r1"

# A doctrine-gap duty exists only when the configured upstream is inside the
# operator's repos.txt containment boundary. Empty preserves today's prompt
# byte-for-byte; an unlisted value warns and still renders today's prompt.
DOCTRINE463_BASE="$(DOCTRINE_REPO='' PROMPTS_DIR="$SHARED/prompts" render_prompt triage.txt \
  ME=me-bot REPO=o/r SIGNAL_BLOCK='signals')"
DOCTRINE463_TODAY="$(sed 's/{{ME}}/me-bot/g; s|{{REPO}}|o/r|g; s/{{SIGNAL_BLOCK}}/signals/g; s/{{DOCTRINE_ENTRYPOINT}}/AGENTS.md/g; s/{{DOCTRINE_TRIAGE}}/TRIAGE.md/g' \
  "$SHARED/prompts/triage.txt")"
t doctrine-upstream-empty-is-byte-identical "$DOCTRINE463_TODAY" "$DOCTRINE463_BASE"
if grep -Eq 'DOCTRINE_REPO|owner/repo|upstream duty|consumer guide' <<<"$DOCTRINE463_BASE"; then
  r1=LEAKED
else
  r1=inert
fi
t doctrine-upstream-empty-is-inert inert "$r1"

printf 'o/r\n' >"$TRD/repos.txt"
DOCTRINE463_WARN="$TMP/doctrine463-warn"
DOCTRINE463_UNLISTED="$(DOCTRINE_REPO='heavy-duty/ceremony' REPOS_FILE="$TRD/repos.txt" \
  PROMPTS_DIR="$SHARED/prompts" render_prompt triage.txt \
  ME=me-bot REPO=o/r SIGNAL_BLOCK='signals' 2>"$DOCTRINE463_WARN")"
t doctrine-upstream-unlisted-renders-no-duty "$DOCTRINE463_BASE" "$DOCTRINE463_UNLISTED"
if grep -Fq 'heavy-duty/ceremony' "$DOCTRINE463_WARN" &&
   grep -Fq "$TRD/repos.txt" "$DOCTRINE463_WARN"; then
  r1=bounded
else
  r1=MISSING
fi
t doctrine-upstream-unlisted-warns-with-repo-and-registry bounded "$r1"

printf '%s\n' o/r heavy-duty/ceremony >"$TRD/repos.txt"
DOCTRINE463_LISTED="$(DOCTRINE_REPO='heavy-duty/ceremony' REPOS_FILE="$TRD/repos.txt" \
  PROMPTS_DIR="$SHARED/prompts" render_prompt triage.txt \
  ME=me-bot REPO=o/r SIGNAL_BLOCK='signals')"
if grep -Fq 'discussion in heavy-duty/ceremony' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq "Quote the rule at this repository's pin" <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'link the local issue' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'state the workaround and its retirement condition' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'any issue its triage later mints, from the consumer workaround' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'keep the upstream request linked back to that consumer' <<<"$DOCTRINE463_LISTED" &&
   grep -Fq 'Never mint an upstream issue yourself.' <<<"$DOCTRINE463_LISTED"; then
  r1=complete
else
  r1=MISSING
fi
t doctrine-upstream-listed-renders-bounded-duty complete "$r1"
if git -C "$SHARED/.." diff --quiet origin/main -- shared/lib/duty-triage.sh; then
  r1=untouched
else
  r1=TOUCHED
fi
t doctrine-upstream-adds-no-new-triage-signal untouched "$r1"

suite_finish
