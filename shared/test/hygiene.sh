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


suite_finish
