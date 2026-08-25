#!/usr/bin/env bash
# shared/test/hygiene.sh — standalone hygiene subject suite.
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
# shellcheck source=shared/lib/duty-attention.sh
source "$SHARED/lib/duty-attention.sh"
# shellcheck source=shared/lib/duty-hygiene.sh
source "$SHARED/lib/duty-hygiene.sh"
ATT_MOD="$SHARED/lib/duty-attention.sh"

# --- malformed attention audit (#303) --------------------------------------
ATT_AUDIT_ROWS="$(printf 'heavy-duty/crew 285 issue 1\nheavy-duty/crew 310 issue 0\nheavy-duty/crew 293 pr 0\nheavy-duty/crew 294 pr 1\n')"
t attention-audit-classifies-all-shapes "OK heavy-duty/crew 285 issue 1
UNASSIGNED heavy-duty/crew 310 issue 0
PR heavy-duty/crew 293 pr 0
PR heavy-duty/crew 294 pr 1" \
  "$(printf '%s\n' "$ATT_AUDIT_ROWS" | _attention_audit_classify)"
t attention-audit-empty-input-is-empty "" \
  "$(printf '' | _attention_audit_classify)"

ATT_AUDIT="$TMP/attention-audit"
mkdir -p "$ATT_AUDIT"
# shellcheck disable=SC2034,SC2317  # variables/functions consumed by the sourced audit
attention_audit_case() { # attention_audit_case <rows> [failed-repo] [registry]
  local supplied="$1" failed="${2:-}" registry="${3:-heavy-duty/crew}" rc
  : >"$ATT_AUDIT/gh-calls"
  (
    DUTY_DIR="$ATT_AUDIT"
    REPOS_FILE="$ATT_AUDIT/repos.txt"
    LABEL_ATTENTION=attention
    read_repo_list() { printf '%s\n' "$registry"; }
    gh() {
      printf 'GH %s\n' "$*" >>"$ATT_AUDIT/gh-calls"
      case "$*" in *"/repos/$failed/issues?"*) return 1 ;; esac
      printf '%s\n' "$supplied"
    }
    warn() { printf 'WARN %s\n' "$*"; }
    alert() { printf 'ALERT %s\n' "$*"; }
    duty_attention_audit
    rc=$?
    printf 'RC %s\n' "$rc"
  )
}

# A valid board is silent apart from its single bounded read.
rm -f "$ATT_AUDIT/.attention-malformed"
ATT_AUDIT_OK="$(attention_audit_case 'heavy-duty/crew 285 issue 1')"
t attention-audit-valid-board-has-no-warning 0 \
  "$(printf '%s\n' "$ATT_AUDIT_OK" | grep -c '^WARN ' || true)"
t attention-audit-valid-board-has-no-alert 0 \
  "$(printf '%s\n' "$ATT_AUDIT_OK" | grep -c '^ALERT ' || true)"
t attention-audit-one-read-per-registry-repo 1 \
  "$(grep -c '^GH api /repos/heavy-duty/crew/issues?' "$ATT_AUDIT/gh-calls" || true)"

# A fetch failure is evidence, not a failed tick, and leaves report state
# untouched so a partial registry sweep cannot falsely announce a repair.
printf 'heavy-duty/crew#293 PR\n' >"$ATT_AUDIT/.attention-malformed"
ATT_AUDIT_FAIL="$(attention_audit_case '' heavy-duty/crew "$(printf 'heavy-duty/crew\nother/repo\n')")"
t attention-audit-fetch-failure-warns 1 \
  "$(printf '%s\n' "$ATT_AUDIT_FAIL" | grep -c '^WARN ' || true)"
t attention-audit-fetch-failure-returns-zero 'RC 0' \
  "$(printf '%s\n' "$ATT_AUDIT_FAIL" | tail -1)"
t attention-audit-fetch-failure-keeps-state 'heavy-duty/crew#293 PR' \
  "$(cat "$ATT_AUDIT/.attention-malformed")"
t attention-audit-fetch-failure-still-reads-later-repos 2 \
  "$(grep -c '^GH api /repos/' "$ATT_AUDIT/gh-calls" || true)"

# report_suppressed makes a stable malformed set speak once, then re-arms
# when the set changes. The operator alert follows exactly the same cadence.
rm -f "$ATT_AUDIT/.attention-malformed"
ATT_AUDIT_TWO="$(attention_audit_case "$(printf 'heavy-duty/crew 293 pr 0\nheavy-duty/crew 310 issue 0\n')")"
ATT_AUDIT_SAME="$(attention_audit_case "$(printf 'heavy-duty/crew 293 pr 0\nheavy-duty/crew 310 issue 0\n')")"
ATT_AUDIT_ONE="$(attention_audit_case 'heavy-duty/crew 293 pr 0')"
t attention-audit-first-set-reports 1 \
  "$(printf '%s\n' "$ATT_AUDIT_TWO" | grep -c '^WARN ' || true)"
t attention-audit-first-set-alerts 1 \
  "$(printf '%s\n' "$ATT_AUDIT_TWO" | grep -c '^ALERT ' || true)"
t attention-audit-unchanged-set-is-silent 0 \
  "$(printf '%s\n' "$ATT_AUDIT_SAME" | grep -Ec '^(WARN|ALERT) ' || true)"
t attention-audit-shrunk-set-reports 1 \
  "$(printf '%s\n' "$ATT_AUDIT_ONE" | grep -c '^WARN ' || true)"
t attention-audit-shrunk-set-alerts 1 \
  "$(printf '%s\n' "$ATT_AUDIT_ONE" | grep -c '^ALERT ' || true)"

# Pin the wiring and the negative contract: one call, inside both the triage
# role and interval guards, before hygiene; no board write or model launch.
DUTYSH="$SHARED/bin/duty.sh"
AUDIT_BLOCK="$(awk '/if has_role triage; then/{b=$0 ORS; next} b!=""{b=b $0 ORS} /duty_hygiene &&/{print b; exit}' "$DUTYSH")"
if grep -q 'HYGIENE_INTERVAL' <<<"$AUDIT_BLOCK" &&
   grep -q 'duty_attention_audit' <<<"$AUDIT_BLOCK" &&
   grep -q 'duty_hygiene' <<<"$AUDIT_BLOCK"; then r1=gated; else r1=UNGATED; fi
t attention-audit-is-triage-hygiene-gated gated "$r1"
t attention-audit-has-one-call-site 1 \
  "$(grep -c '^[[:space:]]*duty_attention_audit$' "$DUTYSH")"
AUDIT_SOURCE="$(awk '/^duty_attention_audit\(\)/,/^}/' "$ATT_MOD")"
if grep -Eq 'gh api -X|--method|gh issue edit|run_session' <<<"$AUDIT_SOURCE"; then
  r1=WRITES
else
  r1=read-only
fi
t attention-audit-is-read-only read-only "$r1"
# shellcheck disable=SC2016  # matching the literal query, not expanding it
if grep -Fq '/issues?filter=assigned&state=open&labels=$LABEL_ATTENTION&per_page=100' "$ATT_MOD"; then
  r1=unchanged
else
  r1=CHANGED
fi
t attention-wake-query-unchanged unchanged "$r1"
# shellcheck disable=SC2016  # matching the prompt's literal Markdown
if grep -Fq 'put `attention` on the assigned issue that owns the claim — never on a pull request or an unassigned issue' \
     "$SHARED/prompts/triage.txt"; then r1=named; else r1=MISSING; fi
t triage-prompt-names-attention-target named "$r1"

# --- the hygiene change gate (#465) ----------------------------------------
#
# The sweep used to be unconditional: one session per repo, every interval,
# forever. These cases pin the gate that ended that, and every one of them is
# written against the thing the gate must NOT become — a board that stops being
# swept. The floor, the fail-open branches and the per-interval skip line are
# each asserted on their own, because dropping any one of them turns a saving
# into a hole and the ledger row would look identical either way.
HYG="$TMP/hygiene"
HYG_MOD="$SHARED/lib/duty-hygiene.sh"
HYG_PROMPT="$SHARED/prompts/hygiene.txt"
HYG_CONF="$SHARED/conf/roles/triage.conf"
mkdir -p "$HYG/work"

hyg_board() {  # hyg_board "<number>|<updatedAt>|<labels csv>|<assignees csv>"...
  local spec num ts labels assignees
  if [ "$#" -eq 0 ]; then printf '[]\n'; return 0; fi
  for spec in "$@"; do
    IFS='|' read -r num ts labels assignees <<<"$spec"
    jq -cn --argjson n "$num" --arg t "$ts" --arg l "$labels" --arg a "$assignees" \
      '{number: $n, updatedAt: $t,
        labels:    (if $l == "" then [] else ($l | split(",")) end | map({name:  .})),
        assignees: (if $a == "" then [] else ($a | split(",")) end | map({login: .}))}'
  done | jq -cs '.'
}

# hygiene_case BOARD [FLOOR|unset] [SESSION-RC] — one interval over a one-repo
# registry. BOARD is the listing JSON, or the literal ERR for a gh that cannot
# answer. Everything the duty reaches outside itself is stubbed, so the only
# things under test are the gate's decision and what it says about it.
# shellcheck disable=SC2317  # the stubs run inside the sourced duty
hygiene_case() {
  local board="$1" floor="${2:-43200}" srun="${3:-0}"
  (
    DUTY_DIR="$HYG"
    WORK_DIR="$HYG/work"
    REPOS_FILE="$HYG/repos.txt"
    TIMEOUT_HYGIENE=10
    ME=triage-bot
    HYG_BOARD="$board"
    HYG_RC="$srun"
    if [ "$floor" = unset ]; then unset HYGIENE_FLOOR; else HYGIENE_FLOOR="$floor"; fi
    read_repo_list() { printf 'heavy-duty/crew\n'; }
    render_prompt() { printf 'PROMPT'; }
    ensure_checkout() { return 0; }
    gh() {
      printf 'GH %s\n' "$*" >>"$HYG/gh-calls"
      if [ "$HYG_BOARD" = ERR ]; then return 1; fi
      printf '%s\n' "$HYG_BOARD"
    }
    log() { printf 'LOG %s\n' "$*"; }
    warn() { printf 'WARN %s\n' "$*"; }
    run_session() { printf 'SESSION %s %s\n' "$1" "$2"; RUN_SESSION_RC="$HYG_RC"; }
    duty_hygiene
    printf 'RC %s\n' "$?"
  )
}

# The two-repo registry, for the one property a single repo cannot show: a
# skipped repo must `continue`, not end the sweep.
# shellcheck disable=SC2317  # the stubs run inside the sourced duty
hygiene_two_case() {  # hygiene_two_case <board-for-crew> <board-for-ceremony>
  local b1="$1" b2="$2"
  (
    DUTY_DIR="$HYG"
    WORK_DIR="$HYG/work"
    REPOS_FILE="$HYG/repos.txt"
    TIMEOUT_HYGIENE=10
    ME=triage-bot
    HYGIENE_FLOOR=43200
    HYG_B1="$b1"
    HYG_B2="$b2"
    read_repo_list() { printf 'heavy-duty/crew\nheavy-duty/ceremony\n'; }
    render_prompt() { printf 'PROMPT'; }
    ensure_checkout() { return 0; }
    gh() {
      case "$*" in
        *heavy-duty/ceremony*) printf '%s\n' "$HYG_B2" ;;
        *)                     printf '%s\n' "$HYG_B1" ;;
      esac
    }
    log() { printf 'LOG %s\n' "$*"; }
    warn() { printf 'WARN %s\n' "$*"; }
    run_session() { printf 'SESSION %s %s\n' "$1" "$2"; RUN_SESSION_RC=0; }
    duty_hygiene
  )
}

hyg_reset() { rm -f "$HYG/.seen-hygiene" "$HYG/gh-calls"; }
hyg_count() { printf '%s\n' "$1" | grep -c -- "$2" || true; }

# The variants change ONE field each, and the three that can hold updatedAt
# still do: a digest built over numbers, or over timestamps alone, passes the
# count case and fails these, which is the whole point of asserting per field.
BOARD_A="$(hyg_board '10|2026-08-25T00:00:00Z|ready|' '11|2026-08-25T01:00:00Z|claimed|cndgrr')"
BOARD_NEW="$(hyg_board '10|2026-08-25T00:00:00Z|ready|' '11|2026-08-25T01:00:00Z|claimed|cndgrr' '12|2026-08-25T02:00:00Z||')"
BOARD_CLOSED="$(hyg_board '10|2026-08-25T00:00:00Z|ready|')"
BOARD_LABEL="$(hyg_board '10|2026-08-25T00:00:00Z|blocked|' '11|2026-08-25T01:00:00Z|claimed|cndgrr')"
BOARD_ASSIGNEE="$(hyg_board '10|2026-08-25T00:00:00Z|ready|' '11|2026-08-25T01:00:00Z|claimed|andriujoseba')"
BOARD_TS="$(hyg_board '10|2026-08-25T09:00:00Z|ready|' '11|2026-08-25T01:00:00Z|claimed|cndgrr')"
BOARD_EMPTY="$(hyg_board)"

# The defect, reproduced and then closed: two intervals over a board that did
# not move used to buy two sessions.
hyg_reset
HYG_RUN1="$(hygiene_case "$BOARD_A")"
HYG_RUN2="$(hygiene_case "$BOARD_A")"
t hygiene-first-interval-sweeps 1 "$(hyg_count "$HYG_RUN1" '^SESSION ')"
t hygiene-first-sweep-names-its-reason 1 "$(hyg_count "$HYG_RUN1" 'launching hygiene sweep (first)')"
t hygiene-unchanged-board-launches-no-session 0 "$(hyg_count "$HYG_RUN2" '^SESSION ')"
t hygiene-unchanged-board-says-so-by-repo 1 "$(hyg_count "$HYG_RUN2" 'no hygiene duty: heavy-duty/crew')"
t hygiene-unchanged-board-returns-zero 'RC 0' "$(printf '%s\n' "$HYG_RUN2" | tail -1)"
t hygiene-gate-reads-the-board-once-per-repo 2 \
  "$(grep -c -- '^GH issue list -R heavy-duty/crew' "$HYG/gh-calls" || true)"

# A suppression nobody can see is the #59 failure. Three consecutive skipped
# intervals produce three lines, not one speak-on-change warning.
HYG_S1="$(hygiene_case "$BOARD_A")"
HYG_S2="$(hygiene_case "$BOARD_A")"
HYG_S3="$(hygiene_case "$BOARD_A")"
t hygiene-skip-is-logged-every-interval 3 \
  "$(hyg_count "$(printf '%s\n%s\n%s' "$HYG_S1" "$HYG_S2" "$HYG_S3")" 'no hygiene duty: heavy-duty/crew')"

# One field at a time. Each starts from a ledger holding BOARD_A's digest.
hyg_changed() {  # hyg_changed <variant board> -> sessions launched
  hyg_reset
  hygiene_case "$BOARD_A" >/dev/null
  hyg_count "$(hygiene_case "$1")" '^SESSION '
}
t hygiene-new-issue-sweeps 1 "$(hyg_changed "$BOARD_NEW")"
t hygiene-closed-issue-sweeps 1 "$(hyg_changed "$BOARD_CLOSED")"
t hygiene-label-change-sweeps 1 "$(hyg_changed "$BOARD_LABEL")"
t hygiene-assignee-change-sweeps 1 "$(hyg_changed "$BOARD_ASSIGNEE")"
t hygiene-updated-at-change-sweeps 1 "$(hyg_changed "$BOARD_TS")"
t hygiene-emptied-board-sweeps 1 "$(hyg_changed "$BOARD_EMPTY")"
hyg_reset
hygiene_case "$BOARD_A" >/dev/null
t hygiene-changed-board-names-its-reason 1 \
  "$(hyg_count "$(hygiene_case "$BOARD_LABEL")" 'launching hygiene sweep (changed)')"

# D2. The floor is what keeps the gate a saving rather than a hole: without it
# a board that never changes is never swept again, and the 48h reclaim and the
# 7-day post-merge nudge go with it. Ages are set on the committed row, so no
# clock is mocked; the margins are wide enough that a slow box cannot flip one.
hyg_age_ledger() {  # hyg_age_ledger <seconds ago>
  local digest now
  digest="$(awk '{print $2}' "$HYG/.seen-hygiene")"
  now="$(date +%s)"
  printf 'heavy-duty/crew %s %s\n' "$digest" "$((now - $1))" >"$HYG/.seen-hygiene"
}
hyg_reset
hygiene_case "$BOARD_A" >/dev/null
hyg_age_ledger 50000
HYG_FLOOR="$(hygiene_case "$BOARD_A")"
t hygiene-floor-fires-on-a-never-changing-board 1 "$(hyg_count "$HYG_FLOOR" '^SESSION ')"
t hygiene-floor-sweep-names-its-reason 1 "$(hyg_count "$HYG_FLOOR" 'launching hygiene sweep (floor)')"
hyg_reset
hygiene_case "$BOARD_A" >/dev/null
hyg_age_ledger 40000
t hygiene-inside-the-floor-still-skips 0 "$(hyg_count "$(hygiene_case "$BOARD_A")" '^SESSION ')"
# The module's fallback is what runs if a role conf predates HYGIENE_FLOOR; a
# bare reference under set -u would abort the tick instead of degrading.
hyg_reset
hygiene_case "$BOARD_A" unset >/dev/null
t hygiene-unset-floor-does-not-abort-the-sweep 0 \
  "$(hyg_count "$(hygiene_case "$BOARD_A" unset)" '^SESSION ')"

# D3. Everything the gate cannot read sweeps anyway and says which repo.
hyg_reset
hygiene_case "$BOARD_A" >/dev/null
HYG_LEDGER_BEFORE="$(cat "$HYG/.seen-hygiene")"
HYG_ERR="$(hygiene_case ERR)"
t hygiene-listing-failure-sweeps-anyway 1 "$(hyg_count "$HYG_ERR" '^SESSION ')"
t hygiene-listing-failure-warns-by-repo 1 \
  "$(hyg_count "$HYG_ERR" '^WARN heavy-duty/crew: the hygiene board listing failed')"
t hygiene-listing-failure-returns-zero 'RC 0' "$(printf '%s\n' "$HYG_ERR" | tail -1)"
t hygiene-listing-failure-commits-no-digest "$HYG_LEDGER_BEFORE" "$(cat "$HYG/.seen-hygiene")"
# stderr is dropped for this case alone: the gate deliberately does NOT swallow
# jq's, so exercising the branch prints a real parse error the suite would
# otherwise carry into the CI log as if something had gone wrong.
HYG_JUNK="$(hygiene_case 'not json at all' 2>/dev/null)"
t hygiene-unparseable-listing-sweeps-anyway 1 "$(hyg_count "$HYG_JUNK" '^SESSION ')"
t hygiene-unparseable-listing-warns-by-repo 1 \
  "$(hyg_count "$HYG_JUNK" '^WARN heavy-duty/crew: the hygiene board digest could not be computed')"

hyg_reset
printf 'heavy-duty/crew 12345-678\n' >"$HYG/.seen-hygiene"
HYG_SHORT="$(hygiene_case "$BOARD_A")"
t hygiene-short-ledger-row-sweeps-anyway 1 "$(hyg_count "$HYG_SHORT" '^SESSION ')"
t hygiene-short-ledger-row-warns-by-repo 1 \
  "$(hyg_count "$HYG_SHORT" '^WARN heavy-duty/crew: the hygiene ledger row is malformed')"
t hygiene-short-ledger-row-is-rewritten-whole 3 "$(awk 'NR==1{print NF}' "$HYG/.seen-hygiene")"
hyg_reset
printf 'heavy-duty/crew 12345-678 not-an-epoch\n' >"$HYG/.seen-hygiene"
t hygiene-non-numeric-epoch-warns-by-repo 1 \
  "$(hyg_count "$(hygiene_case "$BOARD_A")" '^WARN heavy-duty/crew: the hygiene ledger row is malformed')"

# The row is earned by the session, the rule .seen-build and .seen-resume
# already follow: a crashed sweep must not buy a digest it never acted on.
hyg_reset
hygiene_case "$BOARD_A" 43200 1 >/dev/null
t hygiene-failed-session-commits-no-row "" "$(cat "$HYG/.seen-hygiene" 2>/dev/null)"
t hygiene-failed-session-resweeps-next-interval 1 \
  "$(hyg_count "$(hygiene_case "$BOARD_A" 43200 1)" '^SESSION ')"

# A skipped repo continues the sweep rather than ending it.
hyg_reset
hygiene_two_case "$BOARD_A" "$BOARD_A" >/dev/null
HYG_TWO="$(hygiene_two_case "$BOARD_A" "$BOARD_LABEL")"
t hygiene-skipped-repo-does-not-end-the-sweep 1 "$(hyg_count "$HYG_TWO" '^SESSION hygiene heavy-duty/ceremony')"
t hygiene-skipped-repo-is-still-skipped 0 "$(hyg_count "$HYG_TWO" '^SESSION hygiene heavy-duty/crew')"
t hygiene-two-repo-ledger-holds-a-row-each 2 "$(awk 'NF' "$HYG/.seen-hygiene" | wc -l | tr -d ' ')"

# The digest itself: order-independent, one value per board state, and refusing
# a listing it cannot see all of.
HYG_D_A="$(printf '%s' "$BOARD_A" | _hygiene_digest)"
t hygiene-digest-is-order-independent "$HYG_D_A" \
  "$(printf '%s' "$BOARD_A" | jq -c 'reverse' | _hygiene_digest)"
t hygiene-digest-is-stable-across-calls "$HYG_D_A" "$(printf '%s' "$BOARD_A" | _hygiene_digest)"
for hyg_pair in "label:$BOARD_LABEL" "assignee:$BOARD_ASSIGNEE" "new:$BOARD_NEW" "closed:$BOARD_CLOSED"; do
  if [ "$HYG_D_A" = "$(printf '%s' "${hyg_pair#*:}" | _hygiene_digest)" ]; then r1=SAME; else r1=differs; fi
  t "hygiene-digest-separates-a-${hyg_pair%%:*}-change" differs "$r1"
done
HYG_AT_CAP="$(jq -cn --argjson n "$HYGIENE_LISTING_LIMIT" \
  '[range($n) | {number: ., updatedAt: "2026-08-25T00:00:00Z", labels: [], assignees: []}]')"
HYG_UNDER_CAP="$(jq -cn --argjson n "$((HYGIENE_LISTING_LIMIT - 1))" \
  '[range($n) | {number: ., updatedAt: "2026-08-25T00:00:00Z", labels: [], assignees: []}]')"
if printf '%s' "$HYG_AT_CAP" | _hygiene_digest >/dev/null 2>&1; then r1=DIGESTED; else r1=refused; fi
t hygiene-digest-refuses-a-listing-at-the-cap refused "$r1"
if printf '%s' "$HYG_UNDER_CAP" | _hygiene_digest >/dev/null 2>&1; then r1=digested; else r1=REFUSED; fi
t hygiene-digest-accepts-a-listing-under-the-cap digested "$r1"
if printf 'not json' | _hygiene_digest >/dev/null 2>&1; then r1=DIGESTED; else r1=refused; fi
t hygiene-digest-refuses-unparseable-json refused "$r1"
if printf '' | _hygiene_digest >/dev/null 2>&1; then r1=DIGESTED; else r1=refused; fi
t hygiene-digest-refuses-an-empty-read refused "$r1"

# The gate spends one bounded read and writes nothing to the board.
HYG_GATE_SOURCE="$(awk '/^_hygiene_gate\(\)/,/^}/' "$HYG_MOD")"
HYG_LIST_SOURCE="$(awk '/^_hygiene_listing\(\)/,/^}/' "$HYG_MOD")"
if grep -Eq 'gh api -X|--method|gh issue edit|gh pr |run_session' <<<"$HYG_GATE_SOURCE$HYG_LIST_SOURCE"; then
  r1=WRITES
else
  r1=read-only
fi
t hygiene-gate-is-read-only read-only "$r1"
if grep -Fq -- '--json number,updatedAt,labels,assignees' <<<"$HYG_LIST_SOURCE"; then r1=pinned; else r1=CHANGED; fi
t hygiene-listing-fields-pinned pinned "$r1"

# The floor's two homes must agree, or the fallback silently becomes a second
# policy the operator's conf does not describe.
t hygiene-floor-default-matches-conf \
  "$(awk -F= '/^HYGIENE_FLOOR=/{print $2}' "$HYG_CONF")" \
  "$(awk -F= '/^HYGIENE_FLOOR_DEFAULT=/{print $2}' "$HYG_MOD")"
t hygiene-floor-is-configured-in-triage-conf 1 "$(grep -c -- '^HYGIENE_FLOOR=' "$HYG_CONF" || true)"
t hygiene-interval-is-unchanged 1 "$(grep -c -- '^HYGIENE_INTERVAL=3600$' "$HYG_CONF" || true)"

# D4/D5/D6 on the prompt. The two removals are asserted as the absence of the
# instruction, so a later edit cannot quietly restore the duplication, and the
# ownership sentence is asserted present so its absence is not read as nobody
# doing them.
if grep -Fq -- 'flip blocked issues to ready' "$HYG_PROMPT"; then r1=PRESENT; else r1=gone; fi
t hygiene-prompt-drops-the-blocked-to-ready-instruction gone "$r1"
if grep -Fq -- 'reclaim claimed issues' "$HYG_PROMPT"; then r1=PRESENT; else r1=gone; fi
t hygiene-prompt-drops-the-reclaim-instruction gone "$r1"
if grep -Fq -- 'issueflow-reconcile owns' "$HYG_PROMPT"; then r1=named; else r1=MISSING; fi
t hygiene-prompt-names-the-reconciler-as-owner named "$r1"
if grep -Fq -- 'do not read their absence from this prompt as nobody doing them' "$HYG_PROMPT"; then
  r1=said
else
  r1=MISSING
fi
t hygiene-prompt-says-the-absence-is-not-a-gap said "$r1"
if grep -Fq -- 'close obsolete issues with reasons' "$HYG_PROMPT"; then r1=kept; else r1=DROPPED; fi
t hygiene-prompt-keeps-close-obsolete kept "$r1"
if grep -Fq -- 'keep judgment-borne labels true' "$HYG_PROMPT"; then r1=kept; else r1=DROPPED; fi
t hygiene-prompt-keeps-labels-true kept "$r1"
if grep -Fq -- "keep epics' task lists current" "$HYG_PROMPT"; then r1=kept; else r1=DROPPED; fi
t hygiene-prompt-keeps-epic-task-lists kept "$r1"
if grep -Fq -- 'epic-complete nudge' "$HYG_PROMPT"; then r1=narrowed; else r1=UNNARROWED; fi
t hygiene-prompt-narrows-the-epic-instruction narrowed "$r1"
if grep -Fq -- 'If nothing needs doing, say so and exit.' "$HYG_PROMPT"; then r1=kept; else r1=DROPPED; fi
t hygiene-prompt-still-ends-with-the-exit-instruction kept "$r1"

suite_finish
