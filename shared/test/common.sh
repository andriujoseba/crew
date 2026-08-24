#!/usr/bin/env bash
# shared/test/common.sh — standalone common subject suite.
# shellcheck disable=SC2100  # fixture labels and identifiers containing hyphens are strings
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

t phase0-verifier-covers-suite-roots covered \
  "$(phase0_split_coverage_result "$ROOT/drill/rehearsal.sh")"

# Source common.sh against a scratch DUTY_DIR.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck disable=SC1091
source "$SHARED/lib/common.sh"
# shellcheck disable=SC1091
source "$SHARED/lib/duty-builder.sh"

PIPE_GUARD_FIXTURE="$TMP/pipefail-grep-q.fixture"
printf '%s%s\n' 'if producer | ' 'grep --binary-files=text -Fq MATCH; then :; fi' >"$PIPE_GUARD_FIXTURE"
guard_mutation="$(pipefail_grep_q_sites "$PIPE_GUARD_FIXTURE")"
case "$guard_mutation" in
  *"$PIPE_GUARD_FIXTURE:1:"*) r1=red ;; *) r1=MISSED ;;
esac
t pipefail-grep-q-guard-reds-on-reintroduction red "$r1"
rm -f "$PIPE_GUARD_FIXTURE"

guard_findings="$(pipefail_grep_q_sites)"
t pipefail-grep-q-guard-finds-zero "" "$guard_findings"

pipefail_population="$(pipefail_grep_q_population)"
for inherited in \
    "$ROOT/fleet-floor/test/cases.sh" \
    "$ROOT/drill/rehearsal-attention.sh" \
    "$ROOT/drill/install-payload.sh" \
    "$SHARED/lib/duty-builder.sh" \
    "$SHARED/lib/duty-review.sh" \
    "$SHARED/lib/duty-attention.sh"; do
  case "$pipefail_population" in
    *"$inherited"*) r1=inherited ;; *) r1=MISSING ;; esac
  t "pipefail-population-inherits-${inherited##*/}" inherited "$r1"
done

# #449: the live pipefail-setting entrypoints, and the one file that can only
# arrive behind them. Deleting the widened candidate lines reds every row.
for admitted in \
    "$ROOT/cli/crew" \
    "$ROOT/install.sh" \
    "$SHARED/install.sh" \
    "$ROOT/dist/curl-install.sh" \
    "$ROOT/dist/fetch.sh" \
    "$ROOT/dist/make-installer.sh" \
    "$ROOT/dist/release-artifact.sh" \
    "$SHARED/lib/version-skew.sh"; do
  case "$pipefail_population" in
    *"$admitted"*) r1=admitted ;; *) r1=MISSING ;; esac
  t "pipefail-population-admits-${admitted#"$ROOT"/}" admitted "$r1"
done

# The membership above is only worth its criterion if version-skew.sh arrived
# through a parent. It seeds nothing of its own, and both parents carry the
# literal source edge the derivation matches and are in the population
# themselves — a run that seeded it by name would pass the row above and fail
# these three.
if grep -Eq '^[[:space:]]*set[[:space:]]+[^#]*pipefail' "$SHARED/lib/version-skew.sh"
then r1=SEEDS-ITSELF; else r1=by-edge; fi
t pipefail-version-skew-seeds-nothing by-edge "$r1"
for parent in "$ROOT/cli/crew" "$ROOT/install.sh"; do
  r1=MISSING-EDGE
  if grep -Eq '^[[:space:]]*(source|\.)[[:space:]].*/version-skew\.sh' "$parent"; then
    case "$pipefail_population" in *"$parent"*) r1=parent ;; *) r1=PARENT-OUTSIDE ;; esac
  fi
  t "pipefail-version-skew-parent-${parent#"$ROOT"/}" parent "$r1"
done

# Criterion 6: tick.sh is a candidate the derivation reaches and declines. The
# exclusion must be its missing pipefail, not the candidate set's reach — so
# assert both halves, or a future widening could satisfy this vacuously.
pipefail_candidates="$(pipefail_grep_q_candidates | sort -u)"
if grep -qxF "$SHARED/bin/tick.sh" <<<"$pipefail_candidates"
then r1=candidate; else r1=UNREACHED; fi
t pipefail-tick-is-a-candidate candidate "$r1"
if grep -Eq '^[[:space:]]*set[[:space:]]+[^#]*pipefail' "$SHARED/bin/tick.sh"
then r1=SETS-PIPEFAIL; else r1=sets-none; fi
t pipefail-tick-sets-no-pipefail sets-none "$r1"
case "$pipefail_population" in
  *"$SHARED/bin/tick.sh"*) r1=INCLUDED ;; *) r1=excluded ;; esac
t pipefail-population-excludes-tick.sh excluded "$r1"

# #449: the payload exemption is a shape, not a path. This fixture carries the
# four live payload spellings under a filename no clause names — under the old
# rehearsal-app.sh clause every one of them flags. The control on line 5 is
# assembled rather than written so this suite does not carry the live shape,
# and it proves the fixture is exempt by that shape and not inert.
PAYLOAD_FIXTURE="$TMP/remote-payload.fixture"
cat >"$PAYLOAD_FIXTURE" <<'PAYLOADS'
if bxn "$b" 'crontab -l 2>/dev/null | grep -qE "^[^#].*tick\.sh"' 2>/dev/null; then :; fi
armed()   { box exec "$1" -- bash -lc "crontab -l 2>/dev/null | grep -qE '^[^#].*tick\.sh'" >/dev/null 2>&1; }
paused()  { box exec "$1" -- bash -lc "crontab -l 2>/dev/null | grep -q '^#CREW-FLOOR-PAUSED'" >/dev/null 2>&1; }
present() { box exec "$1" -- bash -lc 'crontab -l 2>/dev/null | grep -qF "$HOME/duty/bin/tick.sh"' >/dev/null 2>&1; }
PAYLOADS
printf '%s%s\n' 'if producer | ' 'grep -q CONTROL; then :; fi' >>"$PAYLOAD_FIXTURE"
# Lines 6-8 are the negative the shape rule owes: a payload opener whose grep
# sits OUTSIDE the payload quote is a local pipeline under this file's own
# pipefail, so it must flag. One line per payload spelling, plus a local
# pipeline wrapped around a payload that has a pipe of its own — the case a
# body-contains-a-pipe test cannot separate. Assembled for the same reason the
# control is: written literally they would flag this suite.
payload_gq='grep -q'
cat >>"$PAYLOAD_FIXTURE" <<PAYLOAD_LOCALS
box exec "\$1" -- bash -lc 'crontab -l' | $payload_gq OUTSIDE
out=\$(bxn "\$b" 'echo hi'); printf '%s\n' "\$out" | $payload_gq OUTSIDE
box exec "\$1" -- bash -lc 'crontab -l | $payload_gq INSIDE' | $payload_gq OUTSIDE
PAYLOAD_LOCALS
# Lines 9-12 are the negative the invocation-context bound owes: opener-shaped
# text that is data, not an invocation, because it sits inside an ordinary
# quoted string. Its apparent quote has no mate, so a matcher that looks for
# opener shapes anywhere on the line reads the rest of the line as an
# unterminated payload and erases the local pipeline — a silent pass. Both
# spellings, and both quote pairings, because the lookalike works either way.
cat >>"$PAYLOAD_FIXTURE" <<PAYLOAD_LOOKALIKES
echo 'bash -lc "' | $payload_gq OUTSIDE
note='bxn box "'; producer | $payload_gq OUTSIDE
echo "bash -lc '" | $payload_gq OUTSIDE
note="bxn box '"; producer | $payload_gq OUTSIDE
PAYLOAD_LOOKALIKES
payload_findings="$(pipefail_grep_q_sites "$PAYLOAD_FIXTURE")"
payload_exempt="$(awk -F: '$2 < 5 { print }' <<<"$payload_findings")"
t pipefail-payload-exempt-by-shape "" "$payload_exempt"
payload_control="$(awk -F: '$2 == 5 { print $2 }' <<<"$payload_findings")"
t pipefail-payload-fixture-control-flags 5 "$payload_control"
payload_local="$(awk -F: '$2 > 5 && $2 < 9 { print $2 }' <<<"$payload_findings" \
  | sort -n | paste -sd' ' -)"
t pipefail-payload-local-pipe-flags "6 7 8" "$payload_local"
payload_lookalike="$(awk -F: '$2 > 8 { print $2 }' <<<"$payload_findings" \
  | sort -n | paste -sd' ' -)"
t pipefail-payload-lookalike-flags "9 10 11 12" "$payload_lookalike"
rm -f "$PAYLOAD_FIXTURE"

# The four live sites: present, so this cannot pass by their disappearance, and
# unflagged now that cli/crew is in the population.
payload_live="$(awk '
  /(bxn|bash[[:space:]]+-lc)/ && /[|][[:space:]]*grep[[:space:]]+-[[:alnum:]]*q/ { n++ }
  END { print n+0 }' "$ROOT/cli/crew" "$ROOT/drill/rehearsal-app.sh")"
t pipefail-payload-live-sites-present 4 "$payload_live"
payload_live_findings="$(pipefail_grep_q_sites "$ROOT/cli/crew" "$ROOT/drill/rehearsal-app.sh")"
t pipefail-payload-live-sites-unflagged "" "$payload_live_findings"

# The old predicate is deliberately assembled so the guard does not mistake
# this regression fixture for a live site. Its producer writes a match, pauses,
# then writes again: pipefail exposes grep -q closing the pipe as rc 141.
slow_lines() { env printf '%s\n' MATCH; sleep 0.05; env printf '%s\n' more; }
set -o pipefail
eval 'slow_lines | gr'"ep -qx MATCH" >/dev/null 2>&1
old_slow_rc=$?
slow_materialized="$(slow_lines)"
grep -qx MATCH <<<"$slow_materialized"; new_slow_match_rc=$?
grep -qx ABSENT <<<"$slow_materialized"; new_slow_miss_rc=$?
case "$old_slow_rc" in 0) r1=MATCHED ;; *) r1=nonzero ;; esac
t pipefail-materialized-old-race nonzero "$r1"
t pipefail-materialized-match 0 "$new_slow_match_rc"
t pipefail-materialized-nonmatch 1 "$new_slow_miss_rc"
unset -f slow_lines

# Drive the two converted awk-range call sites with a producer that pauses
# after its match. The old predicate is assembled so the source guard itself
# does not carry the prohibited spelling.
slow_awk() { env printf '%s\n' MATCH; sleep 0.05; env printf '%s\n' more; }
old_pipe='slow_awk | '
old_match='grep -q MATCH'
if eval "$old_pipe$old_match"; then old_predicate_rc=0; else old_predicate_rc=$?; fi
case "$old_predicate_rc" in 0) r1=FALSE-GREEN ;; *) r1=red ;; esac
t pipefail-awk-range-old-shape-reds red "$r1"
awk() { slow_awk; }
if awk_range_grep_q ignored ignored MATCH; then r1=matched; else r1=MISSED; fi
t pipefail-awk-range-basic-survives-race matched "$r1"
if awk_range_grep_Fq ignored ignored MATCH; then r1=matched; else r1=MISSED; fi
t pipefail-awk-range-fixed-survives-race matched "$r1"
if awk_range_grep_q ignored ignored ABSENT; then r1=FALSE-POSITIVE; else r1=absent; fi
t pipefail-awk-range-keeps-negative-direction absent "$r1"
unset -f awk slow_awk
unset old_match old_pipe old_predicate_rc guard_findings guard_mutation
unset pipefail_population inherited PIPE_GUARD_FIXTURE
unset admitted parent pipefail_candidates PAYLOAD_FIXTURE
unset payload_findings payload_exempt payload_control payload_live payload_live_findings

# #411: force the box-existence producer to pause after its matching line.
# The stub is deliberately `box list`, so this exercises the predicate's
# contract at its real boundary. The former pipeline returns 141 when the
# producer wakes and writes the final name after grep has exited successfully.
box_exists_source="$(sed -n '/^box_exists()/p' "$ROOT/cli/crew")"
eval "$box_exists_source"
# shellcheck disable=SC2317  # called by the box_exists body loaded through eval
box() {
  [ "${1:-}" = list ] || return 2
  printf '%s\n' crew-drill crew-drill-triage
  sleep 0.05
  printf '%s\n' crew-drill-builder
}
# shellcheck disable=SC2317  # called by the box_exists body loaded through eval
box_names() { box list; }
if box_exists crew-drill-triage; then r1=found; else r1=MISSED; fi
t box-exists-survives-a-descheduled-producer found "$r1"
if box_exists someone-elses-box; then r1=FALSE-POSITIVE; else r1=absent; fi
t box-exists-keeps-the-negative-direction absent "$r1"
unset -f box box_names box_exists
unset box_exists_source

# Keep ambient operator configuration out of fixture resolution. These static
# assertions make removing either half of the suite guard fail visibly.
r1=guarded
for suite in "${SUITES[@]}"; do
  grep -Fqx 'unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG' "$HERE/$suite.sh" || r1=MISSING
done
t suite-unsets-ambient-crew-config guarded "$r1"
# shellcheck disable=SC2016  # Match the literal assignment in this file.
r1=guarded
for suite in "${SUITES[@]}"; do
  grep -Fqx 'export XDG_CONFIG_HOME="$TMP/xdg-empty"' "$HERE/$suite.sh" || r1=MISSING
done
t suite-pins-empty-xdg-config guarded "$r1"

# --- #285: per-author repository panels ------------------------------------
PANEL_REPO="$TMP/panel-repo"
git init -q "$PANEL_REPO"
mkdir -p "$PANEL_REPO/.github"
cat >"$PANEL_REPO/.github/labels.conf" <<'EOF'
panel=full-a full-b builder-one
panel[builder-one]=author-a author-b builder-one
panel[hyphen-builder]=hyphen-a hyphen-b
EOF
git -C "$PANEL_REPO" add .github/labels.conf
git -C "$PANEL_REPO" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
git -C "$PANEL_REPO" update-ref refs/remotes/origin/main HEAD
t panel-author-line-preferred '["author-a","author-b","builder-one"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" builder-one)"
t panel-author-safety-subtraction '["author-a","author-b"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" builder-one | jq -c --arg me builder-one '. - [$me]')"
t panel-hyphen-author-literal '["hyphen-a","hyphen-b"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" hyphen-builder)"
t panel-missing-author-falls-back '["full-a","full-b","builder-one"]' \
  "$(panel_for_repo owner/repo "$PANEL_REPO" unknown-builder)"

# A repo absent locally must choose the same author line from the contents API.
PANEL_API_CONF="$(base64 -w0 "$PANEL_REPO/.github/labels.conf")"
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { printf '%s\n' "$PANEL_API_CONF"; }
t panel-api-author-line '["author-a","author-b","builder-one"]' \
  "$(panel_for_repo owner/api "$TMP/not-cloned" builder-one)"
unset -f gh

# A stale/local config with no panel row retains the old contents-API fallback.
PANEL_EMPTY_REPO="$TMP/panel-empty-repo"
git init -q "$PANEL_EMPTY_REPO"
mkdir -p "$PANEL_EMPTY_REPO/.github"
printf '%s\n' 'scope:test|C5DEF5|fixture' >"$PANEL_EMPTY_REPO/.github/labels.conf"
git -C "$PANEL_EMPTY_REPO" add .github/labels.conf
git -C "$PANEL_EMPTY_REPO" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
git -C "$PANEL_EMPTY_REPO" update-ref refs/remotes/origin/main HEAD
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { printf '%s\n' "$PANEL_API_CONF"; }
t panel-local-without-panel-uses-api '["full-a","full-b","builder-one"]' \
  "$(panel_for_repo owner/stale "$PANEL_EMPTY_REPO" unknown-builder)"
unset -f gh

# With neither repository config path available, the fleet bench is unchanged.
# shellcheck disable=SC2034  # consumed dynamically by sourced panel_for_repo
PANEL_SAVED_BENCH="${FLEET_BENCH-}"
PANEL_BENCH_WAS_SET="${FLEET_BENCH+x}"
FLEET_BENCH='bench-a bench-b'
# shellcheck disable=SC2317  # called indirectly by panel_for_repo
gh() { return 1; }
t panel-bench-fallback '["bench-a","bench-b"]' \
  "$(panel_for_repo owner/missing "$TMP/not-cloned" builder-one)"
unset -f gh
if [ -n "$PANEL_BENCH_WAS_SET" ]; then
  FLEET_BENCH="$PANEL_SAVED_BENCH"
else
  unset FLEET_BENCH
fi

# Both request and convergence paths must receive an author-aware roster.
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
if grep -Fq 'panel_for_repo "$R" "$dir" "$ME"' "$SHARED/lib/duty-builder.sh"; then r1=author_aware; else r1=FULL_PANEL; fi
t panel-builder-resolution author_aware "$r1"
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
if grep -Fq 'panel_for_repo "$repo" "$WORK_DIR/${repo//\//__}-review" "$author"' "$SHARED/lib/duty-review.sh"; then r1=author_aware; else r1=FULL_PANEL; fi
t panel-reviewer-resolution author_aware "$r1"
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
if grep -Fq '_mark_addressing "$SRa" "$Na"' "$SHARED/lib/duty-review.sh" && \
    ! grep -Fq 'repos/$SRa/pulls/$Na' "$SHARED/lib/duty-review.sh"; then r1=payload-author; else r1=EXTRA-FETCH; fi
t panel-reviewer-reuses-payload-author payload-author "$r1"

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

# --- agent profiles and rehearsal selection -----------------------------
for profile in "$SHARED"/conf/agents/*.conf; do
  agent="$(basename "$profile" .conf)"
  if bash -c '. "$1"; type bot_cli_probe >/dev/null; test -n "$AGENT_LOGIN_HINT"' _ "$profile"; then
    r1=sourceable
  else
    r1=broken
  fi
  t "agent-conf-$agent-standalone" sourceable "$r1"
  profile_login_hints="$(sed -n '/^AGENT_LOGIN_HINT=.*${/p' "$profile")"
  if grep -q . <<<"$profile_login_hints"; then
    r1=deferred
  else
    r1=literal
  fi
  t "agent-conf-$agent-login-hint-literal" literal "$r1"
done

if unknown_out="$(bash "$ROOT/drill/rehearsal.sh" --agent nosuchagent 2>&1)"; then
  unknown_rc=0
else
  unknown_rc=$?
fi
t rehearsal-unknown-agent-rc 1 "$unknown_rc"
case "$unknown_out" in
  *"unknown agent 'nosuchagent'"*"claude"*"codex"*"grok"*"kimi"*) r1=listed ;;
  *) r1=missing ;;
esac
t rehearsal-unknown-agent-list listed "$r1"

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

# --- rehearsal terminal-breaker leg: sourceable mutations (#424) ---------
BREAKER_KIND=attention
BREAKER_THRESHOLD=3
BREAKER_TERMINAL_LOG="2026-08-09T00:00:01Z SESSION START kind=$BREAKER_KIND key=owner/repo#1 timeout=5s log=/tmp/one
2026-08-09T00:00:02Z SESSION END kind=$BREAKER_KIND key=owner/repo#1 rc=1 dur=1s outcome=TERMINAL acted=no"
if rehearsal_breaker_below_threshold_from_log \
    "$BREAKER_KIND" "$BREAKER_TERMINAL_LOG"; then
  r1=accepted
else
  r1=WRONG
fi
t rehearsal-breaker-below-threshold-terminal-counts accepted "$r1"
if rehearsal_breaker_below_threshold_from_log "$BREAKER_KIND" \
    "$BREAKER_TERMINAL_LOG
2026-08-09T00:00:03Z WARN: session breaker: kind=$BREAKER_KIND tripped after $BREAKER_THRESHOLD consecutive terminal failures"; then
  r1=WRONG
else
  r1=red
fi
t rehearsal-breaker-below-threshold-trip-mutation-reds red "$r1"

BREAKER_TRIP_LOG="$BREAKER_TERMINAL_LOG
$BREAKER_TERMINAL_LOG
$BREAKER_TERMINAL_LOG
2026-08-09T00:00:03Z WARN: session breaker: kind=$BREAKER_KIND tripped after $BREAKER_THRESHOLD consecutive terminal failures; log=/tmp/three"
if rehearsal_breaker_trip_from_log \
    "$BREAKER_KIND" "$BREAKER_THRESHOLD" "$BREAKER_TRIP_LOG"; then
  r1=tripped
else
  r1=WRONG
fi
t rehearsal-breaker-trip-at-installed-threshold tripped "$r1"
# Required mutation: disabling the breaker removes its trip line from the
# exact log input the sourceable live assertion reads. The trip assertion must
# red even though all terminal dispatches still happened.
if rehearsal_breaker_trip_from_log "$BREAKER_KIND" "$BREAKER_THRESHOLD" \
    "${BREAKER_TRIP_LOG%$'\n'*}"; then
  r1=WRONG
else
  r1=red
fi
t rehearsal-breaker-disabled-mutation-reds-trip red "$r1"
if rehearsal_breaker_trip_from_log "$BREAKER_KIND" "$BREAKER_THRESHOLD" \
    "$BREAKER_TRIP_LOG
2026-08-09T00:00:04Z WARN: session breaker: kind=$BREAKER_KIND tripped after $BREAKER_THRESHOLD consecutive terminal failures; log=/tmp/four"; then
  r1=WRONG
else
  r1=red
fi
t rehearsal-breaker-second-trip-mutation-reds red "$r1"

BREAKER_SKIP_LOG="2026-08-09T00:00:05Z SESSION SKIP kind=$BREAKER_KIND key=owner/repo#1 reason=terminal-breaker count=$BREAKER_THRESHOLD"
if rehearsal_breaker_suppressed_from_log \
    "$BREAKER_KIND" "$BREAKER_THRESHOLD" 1 "$BREAKER_SKIP_LOG"; then
  r1=suppressed
else
  r1=WRONG
fi
t rehearsal-breaker-stopped-tick-skips-session suppressed "$r1"
BREAKER_SPLIT_SKIP_LOG="2026-08-09T00:00:05Z SESSION SKIP kind=$BREAKER_KIND key=owner/repo#1 reason=some-other-gate count=$BREAKER_THRESHOLD
2026-08-09T00:00:05Z diagnostic reason=terminal-breaker count=$BREAKER_THRESHOLD"
if rehearsal_breaker_suppressed_from_log "$BREAKER_KIND" \
    "$BREAKER_THRESHOLD" 1 "$BREAKER_SPLIT_SKIP_LOG"; then
  r1=WRONG
else
  r1=red
fi
t rehearsal-breaker-split-skip-reason-mutation-reds red "$r1"
if rehearsal_breaker_suppressed_from_log "$BREAKER_KIND" \
    "$BREAKER_THRESHOLD" 1 "$BREAKER_SKIP_LOG
2026-08-09T00:00:06Z SESSION START kind=$BREAKER_KIND key=owner/repo#1 timeout=5s log=/tmp/four"; then
  r1=WRONG
else
  r1=red
fi
t rehearsal-breaker-dispatch-past-threshold-mutation-reds red "$r1"

BREAKER_ALERT="🚨 crew-drill: $BREAKER_KIND session dispatch stopped after $BREAKER_THRESHOLD terminal failures (acted=no) — /tmp/session.log"
if rehearsal_breaker_alert_count_is_one "$BREAKER_KIND" \
    "$BREAKER_ALERT"; then r1=once; else r1=WRONG; fi
t rehearsal-breaker-single-alert-counted once "$r1"
if rehearsal_breaker_alert_count_is_one "$BREAKER_KIND" \
    "$BREAKER_ALERT
$BREAKER_ALERT"; then r1=WRONG; else r1=red; fi
t rehearsal-breaker-second-alert-mutation-reds red "$r1"
if rehearsal_breaker_alert_count_is_one "$BREAKER_KIND" \
    "$BREAKER_ALERT
🚨 crew-drill: review session dispatch stopped after $BREAKER_THRESHOLD terminal failures (acted=no) — /tmp/other.log"; then
  r1=once
else
  r1=WRONG
fi
t rehearsal-breaker-unrelated-lane-alert-ignored once "$r1"

BREAKER_RECOVERY_LOG="2026-08-09T00:00:07Z session breaker: kind=$BREAKER_KIND recovered; dispatch resumed
2026-08-09T00:00:07Z SESSION START kind=$BREAKER_KIND key=owner/repo#1 timeout=5s log=/tmp/recovered"
if rehearsal_breaker_recovered_from_log \
    "$BREAKER_KIND" "$BREAKER_RECOVERY_LOG"; then
  r1=recovered
else
  r1=WRONG
fi
t rehearsal-breaker-restored-cli-recovers-next-tick recovered "$r1"
if rehearsal_breaker_recovered_from_log "$BREAKER_KIND" \
    "${BREAKER_RECOVERY_LOG%$'\n'*}"; then
  r1=WRONG
else
  r1=red
fi
t rehearsal-breaker-hand-resume-mutation-reds red "$r1"

t rehearsal-breaker-summary-skipped-phase-incomplete \
  "INCOMPLETE breaker  (phase 2 skipped)" \
  "$(rehearsal_breaker_summary 1 ' builder' 2)"
t rehearsal-breaker-summary-failure-stays-failure \
  "FAIL       breaker" "$(rehearsal_breaker_summary 1 ' builder' 1)"
t rehearsal-breaker-mixed-fail-then-skip-stays-failure 1 \
  "$(rehearsal_breaker_combine_result \
    "$(rehearsal_breaker_combine_result 2 1)" 2)"
t rehearsal-breaker-mixed-fail-then-pass-stays-failure 1 \
  "$(rehearsal_breaker_combine_result \
    "$(rehearsal_breaker_combine_result 2 1)" 0)"
t rehearsal-breaker-mixed-skip-then-pass-is-ok 0 \
  "$(rehearsal_breaker_combine_result \
    "$(rehearsal_breaker_combine_result 2 2)" 0)"
t rehearsal-breaker-failure-reds-green-round 1 \
  "$(rehearsal_breaker_round_result 0 1 1)"
t rehearsal-breaker-failure-keeps-red-round-red 1 \
  "$(rehearsal_breaker_round_result 1 1 1)"
t rehearsal-breaker-incomplete-makes-green-round-incomplete 2 \
  "$(rehearsal_breaker_round_result 0 1 2)"
t rehearsal-breaker-pass-does-not-clear-incomplete-round 2 \
  "$(rehearsal_breaker_round_result 2 1 0)"
t rehearsal-breaker-skip-does-not-clear-incomplete-round 2 \
  "$(rehearsal_breaker_round_result 2 1 2)"
t rehearsal-breaker-opt-out-keeps-green-round-green 0 \
  "$(rehearsal_breaker_round_result 0 0 2)"
if rehearsal_breaker_attention_is_clear_from_json \
    '{"labels":[{"name":"claimed"}]}'; then
  r1=clear
else
  r1=WRONG
fi
t rehearsal-breaker-recovered-session-acks-attention clear "$r1"
if rehearsal_breaker_attention_is_clear_from_json \
    '{"labels":[{"name":"attention"}]}'; then
  r1=WRONG
else
  r1=red
fi
t rehearsal-breaker-standing-attention-mutation-reds red "$r1"

BREAKER_FIXTURE_HOME="$TMP/rehearsal-breaker-fixture"
mkdir -p "$BREAKER_FIXTURE_HOME/duty/conf/roles"
printf 'TIMEOUT_REVIEW=1\n' >"$BREAKER_FIXTURE_HOME/duty/conf/roles/reviewer.conf"
bx() { HOME="$BREAKER_FIXTURE_HOME" bash -c "$1"; }
if rehearsal_breaker_install_fixture reviewer; then r1=installed; else r1=WRONG; fi
t rehearsal-breaker-cli-fixture-installs installed "$r1"
t rehearsal-breaker-cli-fixture-overrides-command 1 \
  "$(grep -cF '# rehearsal-breaker begin' "$BREAKER_FIXTURE_HOME/duty/conf/roles/reviewer.conf")"
if rehearsal_breaker_restore_cli_for_recovery; then r1=restored; else r1=WRONG; fi
t rehearsal-breaker-recovery-restores-real-cli restored "$r1"
t rehearsal-breaker-recovery-keeps-alert-interceptor 1 \
  "$(grep -cF '# rehearsal-breaker recovery begin' "$BREAKER_FIXTURE_HOME/duty/conf/roles/reviewer.conf")"
t rehearsal-breaker-recovery-keeps-fixture-until-teardown present \
  "$([ -e "$BREAKER_FIXTURE_HOME/.crew-breaker-drill" ] && printf present || printf absent)"
bx() { return 1; }
if rehearsal_breaker_restore_cli; then r1=WRONG; else r1=red; fi
t rehearsal-breaker-failed-teardown-mutation-reds red "$r1"
t rehearsal-breaker-failed-teardown-keeps-fixture present \
  "$([ -e "$BREAKER_FIXTURE_HOME/.crew-breaker-drill" ] && printf present || printf absent)"
bx() { HOME="$BREAKER_FIXTURE_HOME" bash -c "$1"; }
if rehearsal_breaker_restore_cli; then r1=restored; else r1=WRONG; fi
t rehearsal-breaker-cli-fixture-restores-profile restored "$r1"
t rehearsal-breaker-cli-fixture-removes-directory absent \
  "$([ -e "$BREAKER_FIXTURE_HOME/.crew-breaker-drill" ] && printf present || printf absent)"
t rehearsal-breaker-cli-fixture-restores-content 'TIMEOUT_REVIEW=1' \
  "$(cat "$BREAKER_FIXTURE_HOME/duty/conf/roles/reviewer.conf")"
if rehearsal_breaker_profile_is_restored; then r1=restored; else r1=WRONG; fi
t rehearsal-breaker-cli-fixture-removes-role-overrides restored "$r1"
mv "$BREAKER_FIXTURE_HOME/duty/conf/roles/reviewer.conf" \
  "$BREAKER_FIXTURE_HOME/duty/conf/roles/reviewer.conf.missing"
if rehearsal_breaker_profile_is_restored; then r1=WRONG; else r1=red; fi
t rehearsal-breaker-missing-restored-profile-mutation-reds red "$r1"
mv "$BREAKER_FIXTURE_HOME/duty/conf/roles/reviewer.conf.missing" \
  "$BREAKER_FIXTURE_HOME/duty/conf/roles/reviewer.conf"
unset -f bx

# shellcheck disable=SC2016  # literal wiring string; expansions must remain intact
if grep -Fq -- '--no-breaker-drill' "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'breaker  (trip + single alert + recovery)' \
      "$ROOT/drill/rehearsal-breaker.sh" \
    && grep -Fq "rehearsal_breaker_drill \"\$SANDBOX\" \"\$inum\" \"\$ROLE\"" \
      "$ROOT/drill/rehearsal.sh" \
    && grep -Fq '"$overall" "$BREAKER_DRILL" "$breaker_result")"' \
      "$ROOT/drill/rehearsal-all.sh"; then
  r1=wired
else
  r1=MISSING
fi
t rehearsal-breaker-live-leg-and-opt-out-wired wired "$r1"
if grep -Eq 'SESSION_TERMINAL_THRESHOLD=[0-9]|run_session attention' \
    "$ROOT/drill/rehearsal-breaker.sh"; then
  r1=HARDCODED
else
  r1=derived
fi
t rehearsal-breaker-threshold-and-kind-not-hardcoded derived "$r1"

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

# --- rehearsal attention leg: dispatch without code, timeout report (#440) --
# Every input here is the value the live row reads — board JSON, session
# output, a box path under a stubbed bx() — so each mutation is the decision
# boundary itself and needs no drill host.
ATT_REPO=owner/sandbox
ATT_ISSUE=77
ATT_IDENTITY=drill-identity
ATT_FILED=2026-08-09T10:00:00Z
ATT_PICKUP='📌 picked up'
ATT_PHRASE='attention pickup timed out'
ATT_RUNLOG=/home/drill/duty/logs/20260809T110000Z-attention-owner__sandbox_77.log
ATT_LINK=/home/drill/duty/logs/attention-owner__sandbox_77-latest.log

att_row() {  # att_row <row name> <predicate...> — the live grading, captured
  (
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    rehearsal_attention_graded "$@"
  )
}

# §4.1 no PR authored for the dispatched claim.
ATT_PULLS_CLEAN='[{"number":5,"body":"Closes #12","head":"build/12-elsewhere"}]'
ATT_PULLS_BUILT='[{"number":9,"body":"Closes #77 for the demand","head":"build/77-oops"}]'
if rehearsal_attention_prs_for_issue_from_json "$ATT_ISSUE" "$ATT_PULLS_CLEAN" >/dev/null; then
  r1=absent
else
  r1=WRONG
fi
t attention-dispatch-no-pr-holds absent "$r1"
ATT_OUT="$(att_row 'attention: dispatch opened no PR for the claim' \
  rehearsal_attention_prs_for_issue_from_json "$ATT_ISSUE" "$ATT_PULLS_BUILT")"
t attention-dispatch-also-built-a-pr-reds 1 \
  "$(grep -cFx 'FAIL attention: dispatch opened no PR for the claim' <<<"$ATT_OUT")"
t attention-dispatch-pr-red-quotes-the-pr 1 \
  "$(grep -cF 'read: #9 (build/77-oops)' <<<"$ATT_OUT")"
# "Opened no PR" is an absence, and an absence that could not read its source
# is not one. A pulls endpoint that would not list reds this row naming itself,
# exactly as an unlistable branch source reds its twin below — the row used to
# take a failed read as an empty board and print `ok`.
ATT_OUT="$(att_row 'attention: dispatch opened no PR for the claim' \
  rehearsal_attention_prs_for_issue_from_json "$ATT_ISSUE" '[]' "$ATT_REPO")"
t attention-dispatch-unreadable-pulls-source-reds 1 \
  "$(grep -cFx 'FAIL attention: dispatch opened no PR for the claim' <<<"$ATT_OUT")"
t attention-dispatch-unreadable-pulls-source-named 1 \
  "$(grep -cF "read: could not list pull requests of: $ATT_REPO" <<<"$ATT_OUT")"

# The read that feeds it. It reports gh's OWN status rather than the pipeline's,
# because the helper is sourceable and its caller's shell options are not its
# guarantee: through `gh | jq -s`, a `--paginate` that dies after page one hands
# back a SHORT list under a zero status, which is a false absence. Staged with
# pipefail off, which is where the difference between the two shapes lives.
att_pulls_read() {  # att_pulls_read <state> — prints "<rc>|<entries read>"
  local state="$1" out rc=0
  out="$(
    set +o pipefail
    gh() {
      case "$state" in
        empty) printf '%s\n' '[]' ;;
        one)   printf '%s\n' "[{\"user\":{\"login\":\"$ATT_IDENTITY\"},\"number\":9,
                 \"body\":\"Closes #$ATT_ISSUE\",\"head\":{\"ref\":\"build/$ATT_ISSUE-oops\"}}]" ;;
        fail)  echo 'gh: API rate limit exceeded (HTTP 403)' >&2; return 1 ;;
        short) printf '%s\n' '[]'; return 1 ;;
      esac
    }
    rehearsal_attention_open_prs_json "$ATT_REPO" "$ATT_IDENTITY"
  )" || rc=$?
  # `-` is "nothing came back", told apart from a legitimately empty board:
  # `jq length` reads null as 0 and would spell the two the same way.
  printf '%s|%s\n' "$([ "$rc" -eq 0 ] && echo 0 || echo nonzero)" \
    "$([ -n "$out" ] && jq -r 'length' <<<"$out" 2>/dev/null || echo -)"
}
t attention-pulls-read-of-an-empty-board-is-clean '0|0' "$(att_pulls_read empty)"
t attention-pulls-read-sees-the-authors-pr '0|1' "$(att_pulls_read one)"
t attention-pulls-read-fails-on-an-api-failure 'nonzero|-' "$(att_pulls_read fail)"
# The one the pipeline shape passed: valid JSON out, non-zero status.
t attention-truncated-pulls-pagination-is-not-a-clean-read 'nonzero|-' \
  "$(att_pulls_read short)"

# §4.2 no build/<issue>-* branch — on the BUILDER FORK as well as the sandbox.
# The route says fork (shared/prompts/attention.txt) and a builder pushes there
# (git push -u fork), so a row reading only the sandbox is green on the one
# mutation it exists for. Entries carry the repo they were read from.
ATT_FORK="$ATT_IDENTITY/${ATT_REPO##*/}"
ATT_BRANCHES_CLEAN='[{"repo":"owner/sandbox","name":"main"},
  {"repo":"drill-identity/sandbox","name":"build/12-elsewhere"}]'
ATT_BRANCHES_ON_FORK='[{"repo":"owner/sandbox","name":"main"},
  {"repo":"drill-identity/sandbox","name":"build/77-oops"}]'
ATT_BRANCHES_ON_SANDBOX='[{"repo":"owner/sandbox","name":"build/77-oops"}]'
if rehearsal_attention_build_branches_from_json \
    "$ATT_ISSUE" "$ATT_BRANCHES_CLEAN" '' >/dev/null; then
  r1=absent
else
  r1=WRONG
fi
t attention-dispatch-no-build-branch-holds absent "$r1"
ATT_OUT="$(att_row 'attention: dispatch pushed no build branch' \
  rehearsal_attention_build_branches_from_json "$ATT_ISSUE" "$ATT_BRANCHES_ON_FORK" '')"
t attention-dispatch-build-branch-on-the-fork-reds 1 \
  "$(grep -cFx 'FAIL attention: dispatch pushed no build branch' <<<"$ATT_OUT")"
t attention-dispatch-branch-red-names-the-fork 1 \
  "$(grep -cF "read: $ATT_FORK build/77-oops" <<<"$ATT_OUT")"
ATT_OUT="$(att_row 'attention: dispatch pushed no build branch' \
  rehearsal_attention_build_branches_from_json "$ATT_ISSUE" "$ATT_BRANCHES_ON_SANDBOX" '')"
t attention-dispatch-build-branch-on-the-sandbox-reds 1 \
  "$(grep -cF "read: $ATT_REPO build/77-oops" <<<"$ATT_OUT")"
# A source that exists and will not list its branches must not read as "none".
ATT_OUT="$(att_row 'attention: dispatch pushed no build branch' \
  rehearsal_attention_build_branches_from_json "$ATT_ISSUE" '[]' "$ATT_FORK")"
t attention-dispatch-unreadable-branch-source-reds 1 \
  "$(grep -cFx 'FAIL attention: dispatch pushed no build branch' <<<"$ATT_OUT")"
t attention-dispatch-unreadable-source-named 1 \
  "$(grep -cF "read: could not list branches of: $ATT_FORK" <<<"$ATT_OUT")"
# Both sources are asked for, and the fork is derived, never typed.
t attention-branch-sources-are-sandbox-and-fork "$ATT_REPO $ATT_FORK" \
  "$(rehearsal_attention_branch_sources "$ATT_REPO" "$ATT_IDENTITY" | tr '\n' ' ' \
    | sed 's/ $//')"
# The collector is where "the fork does not exist" and "the fork exists and
# will not list" are told apart, and getting that wrong is how reading two
# sources becomes silently blinder than reading one. Staged under a stubbed gh.
#
# ATT_SB / ATT_FK are each a branch-list JSON or one of three failures the
# collector must NOT confuse: X (the repo is there and will not list its
# branches), 404 (no such repo), ERR (auth, rate limit, 5xx, network — fails
# exactly like the other two at the exit-code level and establishes nothing).
# The probe writes gh's own message to STDERR, because that message is the only
# place the difference between 404 and ERR actually exists.
# Prints "<branches>|<unreadable>".
att_probe() {  # att_probe <state> — `gh api repos/<src>` as the collector sees it
  case "$1" in
    404) echo 'gh: Not Found (HTTP 404)' >&2; return 1 ;;
    ERR) echo 'error connecting to api.github.com' >&2; return 1 ;;
    *)   return 0 ;;
  esac
}
att_collect() {
  (
    gh() {
      case "$*" in
        *"repos/$ATT_REPO/branches"*)
          case "$ATT_SB" in X|404|ERR) return 1 ;; esac
          printf '%s\n' "$ATT_SB" ;;
        *"repos/$ATT_FORK/branches"*)
          case "$ATT_FK" in X|404|ERR) return 1 ;; esac
          printf '%s\n' "$ATT_FK" ;;
        "api repos/$ATT_REPO") att_probe "$ATT_SB" ;;
        "api repos/$ATT_FORK") att_probe "$ATT_FK" ;;
        *) return 1 ;;
      esac
    }
    rehearsal_attention_collect_branches "$ATT_REPO" "$ATT_FORK"
    printf '%s|%s\n' "$(jq -c . <<<"$REHEARSAL_ATTENTION_BRANCHES")" \
      "$REHEARSAL_ATTENTION_BRANCH_UNREADABLE"
  )
}
ATT_SB='[{"name":"main"}]'; ATT_FK='[{"name":"build/77-oops"}]'
t attention-collector-unions-both-sources-and-names-each \
  '[{"repo":"owner/sandbox","name":"main"},{"repo":"drill-identity/sandbox","name":"build/77-oops"}]|' \
  "$(att_collect)"
ATT_SB='[]'; ATT_FK=X
t attention-collector-flags-a-source-that-exists-and-will-not-list \
  '[]|drill-identity/sandbox' "$(att_collect)"
# A fork that has not been created cannot hold a pushed branch: skipped. This
# is the ONLY failure that may be skipped, and only because the 404 says so.
ATT_SB='[]'; ATT_FK=404
t attention-collector-skips-a-fork-that-does-not-exist '[]|' "$(att_collect)"
ATT_SB='[]'; ATT_FK='[]'
t attention-collector-empty-source-is-not-unreadable '[]|' "$(att_collect)"
# Absence is a POSITIVE finding. An auth/rate-limit/network failure fails the
# probe too and proves nothing, so the fork is unread, not absent — reading the
# two alike is how the load-bearing branch row greened without a source read.
ATT_SB='[]'; ATT_FK=ERR
t attention-collector-non-404-fork-failure-is-unreadable \
  '[]|drill-identity/sandbox' "$(att_collect)"
# The sandbox is the one source known to exist: this leg filed its fixture
# there. Its branch read failing is ALWAYS unreadable...
ATT_SB=X; ATT_FK='[]'
t attention-collector-unlistable-sandbox-is-unreadable '[]|owner/sandbox' \
  "$(att_collect)"
# ...including when the probe answers 404, which for the sandbox means the
# world is broken, not that there is nothing to read.
ATT_SB=404; ATT_FK='[]'
t attention-collector-sandbox-is-never-skipped '[]|owner/sandbox' "$(att_collect)"
# Both sources down at once — the reviewed defect exactly: `branches=[]` with
# `unreadable=''`, which graded PASS having read neither source.
ATT_SB=ERR; ATT_FK=ERR
t attention-collector-total-failure-is-not-an-empty-board \
  '[]|owner/sandbox drill-identity/sandbox' "$(att_collect)"
# ...and that state now reds the row it feeds, which is the point of all of it.
ATT_OUT="$(att_row 'attention: dispatch pushed no build branch' \
  rehearsal_attention_build_branches_from_json "$ATT_ISSUE" '[]' \
  "$ATT_REPO $ATT_FORK")"
t attention-unread-sources-red-the-branch-row 1 \
  "$(grep -cFx 'FAIL attention: dispatch pushed no build branch' <<<"$ATT_OUT")"

# The probe on its own: only a matched 404 is absence.
att_absent() {  # att_absent <state>
  local state="$1"
  (
    gh() { att_probe "$state"; }
    if rehearsal_attention_repo_absent "$ATT_FORK"; then echo absent; else echo present; fi
  )
}
t attention-repo-absent-on-a-404 absent "$(att_absent 404)"
t attention-repo-absent-refuses-a-connection-failure present "$(att_absent ERR)"
t attention-repo-absent-refuses-a-reachable-repo present "$(att_absent OK)"

# A failed union is not a clean read either: it would leave the list at its
# previous value with nothing recorded, so a stale list grades as an empty one.
att_collect_broken_union() {
  (
    gh() {
      case "$*" in
        *"repos/$ATT_REPO/branches"*) printf '%s\n' '[{"name":"main"}]' ;;
        *"repos/$ATT_FORK/branches"*) printf '%s\n' '[]' ;;
        *) return 0 ;;
      esac
    }
    jq() { case "$*" in "-s add") return 5 ;; *) command jq "$@" ;; esac; }
    rehearsal_attention_collect_branches "$ATT_REPO" "$ATT_FORK"
    printf '%s\n' "$REHEARSAL_ATTENTION_BRANCH_UNREADABLE"
  )
}
t attention-collector-failed-union-is-unreadable \
  'owner/sandbox drill-identity/sandbox' "$(att_collect_broken_union)"

# Both reads in the dispatch half — the fixture precondition and the graded row
# — go through the collector, so neither can drift back to the sandbox alone.
# shellcheck disable=SC2016  # the needle is source text, not an expansion
t attention-branch-reads-all-go-through-the-collector 2 \
  "$(grep -cF 'rehearsal_attention_collect_branches "${sources[@]}"' \
    "$ROOT/drill/rehearsal-attention.sh" | tr -d ' ')"

# §4.3 the claim is released to ready — the swap, not merely the addition.
ATT_ISSUE_READY='{"labels":[{"name":"ready"}],"assignees":[]}'
ATT_ISSUE_CLAIMED='{"labels":[{"name":"claimed"},{"name":"ready"}],"assignees":[]}'
ATT_ISSUE_ASSIGNED='{"labels":[{"name":"ready"}],"assignees":[{"login":"drill-identity"}]}'
if rehearsal_attention_is_ready_from_json "$ATT_ISSUE_READY" >/dev/null; then
  r1=released
else
  r1=WRONG
fi
t attention-dispatch-ready-holds released "$r1"
ATT_OUT="$(att_row 'attention: dispatch left the issue ready' \
  rehearsal_attention_is_ready_from_json "$ATT_ISSUE_CLAIMED")"
t attention-dispatch-still-claimed-reds 1 \
  "$(grep -cFx 'FAIL attention: dispatch left the issue ready' <<<"$ATT_OUT")"
t attention-dispatch-label-red-quotes-the-set 1 \
  "$(grep -cF 'read: claimed ready' <<<"$ATT_OUT")"

# §4.4 the identity is unassigned.
if rehearsal_attention_identity_released_from_json "$ATT_IDENTITY" "$ATT_ISSUE_READY" >/dev/null; then
  r1=unassigned
else
  r1=WRONG
fi
t attention-dispatch-unassigned-holds unassigned "$r1"
ATT_OUT="$(att_row 'attention: dispatch unassigned the identity' \
  rehearsal_attention_identity_released_from_json "$ATT_IDENTITY" "$ATT_ISSUE_ASSIGNED")"
t attention-dispatch-still-assigned-reds 1 \
  "$(grep -cFx 'FAIL attention: dispatch unassigned the identity' <<<"$ATT_OUT")"
t attention-dispatch-assignee-red-quotes-the-login 1 \
  "$(grep -cF "read: $ATT_IDENTITY" <<<"$ATT_OUT")"

# §4.5 the next build step is recorded — a comment by the identity that is not
# the ack. An ack-only thread is the mutation: the route released a claim
# without recording where it got to.
ATT_COMMENTS_STEP='[{"user":{"login":"drill-identity"},"created_at":"2026-08-09T10:01:00Z","body":"📌 picked up"},{"user":{"login":"drill-identity"},"created_at":"2026-08-09T10:02:00Z","body":"Next build step: add drill-attention.txt and open the PR."}]'
ATT_COMMENTS_ACK='[{"user":{"login":"drill-identity"},"created_at":"2026-08-09T10:01:00Z","body":"📌 picked up"}]'
if rehearsal_attention_records_next_step_from_json \
    "$ATT_PICKUP" "$ATT_IDENTITY" "$ATT_FILED" "$ATT_COMMENTS_STEP" >/dev/null; then
  r1=recorded
else
  r1=WRONG
fi
t attention-dispatch-next-step-holds recorded "$r1"
ATT_OUT="$(att_row 'attention: dispatch recorded the next build step' \
  rehearsal_attention_records_next_step_from_json \
  "$ATT_PICKUP" "$ATT_IDENTITY" "$ATT_FILED" "$ATT_COMMENTS_ACK")"
t attention-dispatch-ack-only-reds 1 \
  "$(grep -cFx 'FAIL attention: dispatch recorded the next build step' <<<"$ATT_OUT")"
t attention-dispatch-next-step-red-quotes-the-count 1 \
  "$(grep -cF 'read: 0 non-ack comment' <<<"$ATT_OUT")"
# A comment posted before this run's fixture is not this run's evidence.
t attention-dispatch-next-step-window-is-this-run 0 \
  "$(rehearsal_attention_next_step_count_from_json "$ATT_PICKUP" "$ATT_IDENTITY" \
    2026-08-09T23:00:00Z "$ATT_COMMENTS_STEP")"

# §5.1 the ⏱️ comment lands exactly once across two lowered invocations.
ATT_TIMEOUT_BODY="⏱️ $ATT_PHRASE; work may be incomplete. Session log: $ATT_LINK"
ATT_TIMEOUT_ONE="$(jq -n --arg b "$ATT_TIMEOUT_BODY" '[{body:$b}]')"
ATT_TIMEOUT_TWICE="$(jq -n --arg b "$ATT_TIMEOUT_BODY" '[{body:$b},{body:$b}]')"
ATT_TIMEOUT_NONE='[{"body":"📌 picked up"}]'
if rehearsal_attention_timeout_comment_once_from_json "$ATT_PHRASE" "$ATT_TIMEOUT_ONE" >/dev/null; then
  r1=once
else
  r1=WRONG
fi
t attention-timeout-comment-once-holds once "$r1"
ATT_OUT="$(att_row 'attention: timeout comment posted exactly once' \
  rehearsal_attention_timeout_comment_once_from_json "$ATT_PHRASE" "$ATT_TIMEOUT_TWICE")"
t attention-timeout-comment-duplicated-reds 1 \
  "$(grep -cFx 'FAIL attention: timeout comment posted exactly once' <<<"$ATT_OUT")"
t attention-timeout-duplicate-red-quotes-the-count 1 \
  "$(grep -cF 'read: 2 timeout comment' <<<"$ATT_OUT")"
ATT_OUT="$(att_row 'attention: timeout comment posted exactly once' \
  rehearsal_attention_timeout_comment_once_from_json "$ATT_PHRASE" "$ATT_TIMEOUT_NONE")"
t attention-timeout-comment-absent-reds 1 \
  "$(grep -cFx 'FAIL attention: timeout comment posted exactly once' <<<"$ATT_OUT")"

# §5.2 that comment names the STABLE link, which is what survives a retry.
ATT_TIMEOUT_STAMPED="$(jq -n --arg b "⏱️ $ATT_PHRASE; work may be incomplete. Session log: $ATT_RUNLOG" '[{body:$b}]')"
if rehearsal_attention_timeout_names_link_from_json \
    "$ATT_PHRASE" "$ATT_LINK" "$ATT_TIMEOUT_ONE" >/dev/null; then
  r1=named
else
  r1=WRONG
fi
t attention-timeout-comment-names-stable-link named "$r1"
ATT_OUT="$(att_row 'attention: timeout comment names the stable log link' \
  rehearsal_attention_timeout_names_link_from_json \
  "$ATT_PHRASE" "$ATT_LINK" "$ATT_TIMEOUT_STAMPED")"
t attention-timeout-timestamped-path-reds 1 \
  "$(grep -cFx 'FAIL attention: timeout comment names the stable log link' <<<"$ATT_OUT")"
# An empty link would grep for "" and match any body at all — a vacuous pass
# standing beside a run-log row already red for the same reason.
ATT_OUT="$(att_row 'attention: timeout comment names the stable log link' \
  rehearsal_attention_timeout_names_link_from_json \
  "$ATT_PHRASE" '' "$ATT_TIMEOUT_STAMPED")"
t attention-no-derived-link-reds-rather-than-matching-anything 1 \
  "$(grep -cFx 'FAIL attention: timeout comment names the stable log link' <<<"$ATT_OUT")"
t attention-no-derived-link-red-says-why 1 \
  "$(grep -cF 'read: no stable link derived to check the comment against' <<<"$ATT_OUT")"

# §5.3 the stable link exists and resolves to a readable file. Staged for real
# against a stubbed bx(), so the three states an operator can find are read
# rather than argued: present, dangling, absent.
ATT_LINKDIR="$TMP/attention-link"
mkdir -p "$ATT_LINKDIR"
printf 'session\n' >"$ATT_LINKDIR/run.log"
ln -sfn run.log "$ATT_LINKDIR/latest.log"
bx() { bash -c "$1"; }
if rehearsal_attention_stable_log_readable "$ATT_LINKDIR/latest.log"; then
  r1=readable
else
  r1=WRONG
fi
t attention-stable-link-readable-holds readable "$r1"
rm -f "$ATT_LINKDIR/run.log"
if rehearsal_attention_stable_log_readable "$ATT_LINKDIR/latest.log"; then
  r1=WRONG
else
  r1=dangling
fi
t attention-stable-link-dangling-reds dangling "$r1"
rm -f "$ATT_LINKDIR/latest.log"
if rehearsal_attention_stable_log_readable "$ATT_LINKDIR/latest.log"; then
  r1=WRONG
else
  r1=absent
fi
t attention-stable-link-absent-reds absent "$r1"
# A regular file in the link's place is not the link the engine plants.
printf 'not a link\n' >"$ATT_LINKDIR/latest.log"
if rehearsal_attention_stable_log_readable "$ATT_LINKDIR/latest.log"; then
  r1=WRONG
else
  r1=refused
fi
t attention-stable-link-plain-file-reds refused "$r1"
unset -f bx

# §5.4 the operator alert names the IMMUTABLE run log, not the stable link:
# the two paths are deliberately different subjects and swapping them is the
# mutation that would go unnoticed.
ATT_SESSION_OUT="2026-08-09T11:00:00Z SESSION START kind=attention key=$ATT_REPO#$ATT_ISSUE timeout=1s log=$ATT_RUNLOG
2026-08-09T11:00:02Z SESSION END kind=attention key=$ATT_REPO#$ATT_ISSUE rc=124 dur=1s outcome=TIMEOUT acted=no reply_tail="
t attention-run-log-read-from-the-session-record "$ATT_RUNLOG" \
  "$(rehearsal_attention_run_log_from_output "$ATT_REPO" "$ATT_ISSUE" "$ATT_SESSION_OUT")"
t attention-stable-link-derived-not-parsed "$ATT_LINK" \
  "$(rehearsal_attention_stable_link_for "$ATT_REPO" "$ATT_ISSUE" "$ATT_RUNLOG")"
if rehearsal_attention_run_log_from_output "$ATT_REPO" "$ATT_ISSUE" \
    "2026-08-09T11:00:00Z SESSION START kind=attention key=other/repo#1 timeout=1s log=/tmp/other" >/dev/null; then
  r1=WRONG
else
  r1=refused
fi
t attention-run-log-of-another-key-refused refused "$r1"
ATT_ALERTS="⏱️ host: $ATT_PHRASE for $ATT_REPO#$ATT_ISSUE — session log: $ATT_RUNLOG"
if rehearsal_attention_alert_names_run_log \
    "$ATT_PHRASE for $ATT_REPO#$ATT_ISSUE" "$ATT_RUNLOG" "$ATT_ALERTS" >/dev/null; then
  r1=named
else
  r1=WRONG
fi
t attention-alert-names-run-log-holds named "$r1"
ATT_OUT="$(att_row 'attention: operator alert named the run log' \
  rehearsal_attention_alert_names_run_log \
  "$ATT_PHRASE for $ATT_REPO#$ATT_ISSUE" "$ATT_RUNLOG" \
  "⏱️ host: $ATT_PHRASE for $ATT_REPO#$ATT_ISSUE — session log: $ATT_LINK")"
t attention-alert-naming-the-link-reds 1 \
  "$(grep -cFx 'FAIL attention: operator alert named the run log' <<<"$ATT_OUT")"
ATT_OUT="$(att_row 'attention: operator alert named the run log' \
  rehearsal_attention_alert_names_run_log \
  "$ATT_PHRASE for $ATT_REPO#$ATT_ISSUE" "$ATT_RUNLOG" '')"
t attention-alert-absent-reds 1 \
  "$(grep -cF 'read: <no timeout alert>' <<<"$ATT_OUT")"

# The capture path EXECUTED, not a prebuilt alert string handed to the
# predicate. The override is generated by the leg, run by a shell the way the
# box's bash runs it, and read back — which is the only shape that catches an
# escaping level: a definition one backslash too deep captures the literal $*
# and no alert can ever match, so the row reds against a correct engine.
ATT_CAPTURE="$TMP/attention-alert-capture"
: >"$ATT_CAPTURE"
ATT_ALERT_DEF="$(
  bx() { printf '%s' "$1"; }
  rehearsal_attention_timeout_invoke "$ATT_IDENTITY" 1 "$ATT_CAPTURE"
)"
ATT_ALERT_DEF="$(grep -F 'alert()' <<<"$ATT_ALERT_DEF")"
bash -c "$ATT_ALERT_DEF; alert '⏱️ host: $ATT_PHRASE for $ATT_REPO#$ATT_ISSUE — session log: $ATT_RUNLOG'"
t attention-generated-alert-expands-its-arguments 0 \
  "$(grep -cFx '$*' "$ATT_CAPTURE" | tr -d ' ')"
if rehearsal_attention_alert_names_run_log \
    "$ATT_PHRASE for $ATT_REPO#$ATT_ISSUE" "$ATT_RUNLOG" \
    "$(cat "$ATT_CAPTURE")" >/dev/null; then
  r1=named
else
  r1=WRONG
fi
t attention-generated-alert-capture-feeds-the-row named "$r1"

# The graded pair must come from ONE invocation. run_session stamps the log at
# second granularity, so two lowered invocations name two run logs; grading the
# last alert against the first run log reds on a correct engine. This is the
# capture the row used to see.
ATT_RUNLOG2=/home/drill/duty/logs/20260809T110004Z-attention-owner__sandbox_77.log
ATT_ALERTS_BOTH="⏱️ host: $ATT_PHRASE for $ATT_REPO#$ATT_ISSUE — session log: $ATT_RUNLOG
⏱️ host: $ATT_PHRASE for $ATT_REPO#$ATT_ISSUE — session log: $ATT_RUNLOG2"
ATT_OUT="$(att_row 'attention: operator alert named the run log' \
  rehearsal_attention_alert_names_run_log \
  "$ATT_PHRASE for $ATT_REPO#$ATT_ISSUE" "$ATT_RUNLOG" "$ATT_ALERTS_BOTH")"
t attention-alert-of-another-invocation-reds 1 \
  "$(grep -cFx 'FAIL attention: operator alert named the run log' <<<"$ATT_OUT")"
t attention-mixed-invocation-red-quotes-the-other-log 1 \
  "$(grep -cF "read: ⏱️ host: $ATT_PHRASE for $ATT_REPO#$ATT_ISSUE — session log: $ATT_RUNLOG2" \
    <<<"$ATT_OUT")"
# So the half gives each invocation its own capture and grades the first's.
# shellcheck disable=SC2016  # the needle is source text, not an expansion
t attention-each-invocation-has-its-own-capture 2 \
  "$(grep -cE 'rehearsal_attention_timeout_invoke "\$identity" "\$budget" "\$capture_(first|second)"' \
    "$ROOT/drill/rehearsal-attention.sh" | tr -d ' ')"
t attention-graded-alert-comes-from-the-first-capture 1 \
  "$(grep -cF "cat '\$capture_first'" "$ROOT/drill/rehearsal-attention.sh" | tr -d ' ')"

# The restore. The lowered budget lives in one box shell, so the proof is that
# a fresh load_conf still resolves the installed number — an after that equals
# the lowered value is exactly the leak this row exists to catch.
if rehearsal_attention_timeout_restored 1800 1800 1 >/dev/null; then
  r1=restored
else
  r1=WRONG
fi
t attention-installed-budget-restored-holds restored "$r1"
ATT_OUT="$(att_row 'attention: installed pickup budget survives the lowered run' \
  rehearsal_attention_timeout_restored 1800 1 1)"
t attention-lowered-budget-leaked-reds 1 \
  "$(grep -cFx 'FAIL attention: installed pickup budget survives the lowered run' <<<"$ATT_OUT")"
t attention-budget-red-quotes-both-readings 1 \
  "$(grep -cF 'read: installed TIMEOUT_ATTENTION before=1800 after=1' <<<"$ATT_OUT")"
if rehearsal_attention_timeout_restored '' '' 1 >/dev/null; then
  r1=WRONG
else
  r1=refused
fi
t attention-unresolvable-budget-refused refused "$r1"
# One red row, two causes: a budget that never resolved is not one left lowered,
# and the aggregate summary line names the one that happened.
if rehearsal_attention_timeout_unresolved '' ''; then r1=unresolved; else r1=WRONG; fi
t attention-unresolved-budget-is-its-own-cause unresolved "$r1"
if rehearsal_attention_timeout_unresolved 1800 1; then r1=WRONG; else r1=leak; fi
t attention-lowered-budget-is-not-an-unresolved-one leak "$r1"

# --- the halves' own bookkeeping: a red row must reach the verdict ----------
#
# rehearsal-all.sh reads this leg's summary row off the drill's return code,
# which is read off the two halves' return codes. So a red row that cannot
# reach a half's return code prints `ok attention` into the round summary and
# drills/<version>.md for a round that asserted nothing — the #423 defect (see
# the notify leg above) relocated into this leg's own bookkeeping, and the
# reason drill/rehearsal-resume.sh pairs every `fail` with a verdict.
#
# Staged as the halves actually run, with the filer, the invoker, gh and bx
# stubbed; each mutation is one realistic blip, not a broken engine.
ATT_SESSION_OUT2="2026-08-09T11:00:04Z SESSION START kind=attention key=$ATT_REPO#$ATT_ISSUE timeout=1s log=$ATT_RUNLOG2
2026-08-09T11:00:06Z SESSION END kind=attention key=$ATT_REPO#$ATT_ISSUE rc=124 dur=1s outcome=TIMEOUT acted=no reply_tail="
ATT_ALERTS_FIRST="⏱️ host: $ATT_PHRASE for $ATT_REPO#$ATT_ISSUE — session log: $ATT_RUNLOG"

att_half_stubs() {
  ok()   { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  # rehearsal.sh's wait_for, minus the sleeping.
  wait_for() {
    local name="$2"; shift 2
    if "$@" >/dev/null 2>&1; then ok "$name"; return 0; fi
    fail "$name (timeout)"; return 1
  }
  rehearsal_attention_file_fixture() { REHEARSAL_ATTENTION_NUM="$ATT_ISSUE"; }
  rehearsal_attention_close_fixture() { return 0; }
  # shellcheck disable=SC2317  # invoked indirectly, by the half under test
  rehearsal_attention_demand_visible() { return "${ATT_VISIBLE:-0}"; }
}

att_dispatch_half() {  # rows on stdout, the half's rc as the exit status
  # The half reads pulls TWICE — the fixture precondition, then the graded row
  # minutes later — and either read can blip on its own. Counted in a file for
  # the same reason the timeout half's invocations are: the reads happen inside
  # command substitutions, and a shell variable would go with the subshell.
  printf '0' >"$TMP/att-pulls-n"
  (
    att_half_stubs
    rehearsal_attention_dispatch_invoke() { printf '%s\n' "$ATT_WAKE"; }
    rehearsal_attention_open_prs_json() {
      local n
      n=$(( $(cat "$TMP/att-pulls-n") + 1 ))
      printf '%s' "$n" >"$TMP/att-pulls-n"
      case "${ATT_PULLS_FAIL:-none}" in
        first)  if [ "$n" -eq 1 ]; then return 1; fi ;;
        second) if [ "$n" -eq 2 ]; then return 1; fi ;;
      esac
      printf '%s\n' "$ATT_PULLS_CLEAN"
    }
    rehearsal_attention_settled_issue_json() { printf '%s\n' "$ATT_ISSUE_READY"; }
    rehearsal_attention_collect_branches() {
      REHEARSAL_ATTENTION_BRANCHES="$ATT_BRANCHES_CLEAN"
      REHEARSAL_ATTENTION_BRANCH_UNREADABLE=""
    }
    gh() {
      case "$*" in
        *"/comments"*) printf '%s\n' "$ATT_COMMENTS_STEP" ;;
        *) printf '%s\n' "$ATT_FILED" ;;
      esac
    }
    rehearsal_attention_dispatch_half "$ATT_REPO" "$ATT_IDENTITY" "$ATT_PICKUP"
  )
}

att_timeout_half() {  # rows on stdout, the half's rc as the exit status
  printf '0' >"$TMP/att-invoke-n"
  (
    att_half_stubs
    rehearsal_attention_stable_log_readable() { return 0; }
    # Called in a command substitution, so the counter cannot live in a shell
    # variable — the subshell would take each increment with it.
    rehearsal_attention_timeout_invoke() {
      local n
      n=$(( $(cat "$TMP/att-invoke-n") + 1 ))
      printf '%s' "$n" >"$TMP/att-invoke-n"
      if [ "$n" -eq 1 ]; then printf '%s\n' "$ATT_FIRST"; else printf '%s\n' "$ATT_SECOND"; fi
    }
    bx() { case "$1" in cat*) printf '%s\n' "$ATT_ALERTS_FIRST" ;; *) return 0 ;; esac; }
    gh() { printf '%s\n' "$ATT_TIMEOUT_ONE"; }
    rehearsal_attention_timeout_half "$ATT_REPO" "$ATT_IDENTITY" "$ATT_PHRASE" \
      "$TMP/att-capture" 1
  )
}

# Control: every row green, both halves return 0.
ATT_WAKE="$ATT_SESSION_OUT"
ATT_FIRST="$ATT_SESSION_OUT"; ATT_SECOND="$ATT_SESSION_OUT2"
ATT_OUT="$(att_dispatch_half)"; r1=$?
t attention-dispatch-half-green-returns-0 "0|0" \
  "$r1|$(grep -c '^FAIL' <<<"$ATT_OUT" | tr -d ' ')"
ATT_OUT="$(att_timeout_half)"; r1=$?
t attention-timeout-half-green-returns-0 "0|0" \
  "$r1|$(grep -c '^FAIL' <<<"$ATT_OUT" | tr -d ' ')"

# Mutation: the wake launched no pickup session. The row reds; before the fix
# the half still returned 0 and the round summary said `ok attention`.
ATT_WAKE="2026-08-09T11:00:00Z attention: none"
ATT_OUT="$(att_dispatch_half)"; r1=$?
ATT_WAKE="$ATT_SESSION_OUT"
t attention-dispatch-wake-red-reaches-the-halfs-verdict 1 "$r1"
t attention-dispatch-wake-red-is-a-red-row 1 \
  "$(grep -cFx 'FAIL attention: dispatch wake launched a pickup session' <<<"$ATT_OUT")"

# Mutation: the SECOND lowered invocation never ran — duty_attention took its
# `attention fetch failed this tick` return and never reached the timeout
# branch. The row that must red is the invocation one, and the row that stays
# green is why it matters: "posted exactly once" is TRIVIALLY true with one
# invocation, so a half returning 0 here reports `ok` on a round in which
# post-once.sh was never asked to dedup at all.
ATT_SECOND="attention: none new in registry"
ATT_OUT="$(att_timeout_half)"; r1=$?
t attention-timeout-invocation-red-reaches-the-halfs-verdict 1 "$r1"
t attention-timeout-second-invocation-red-is-a-red-row 1 \
  "$(grep -cFx 'FAIL attention: both lowered invocations timed out' <<<"$ATT_OUT")"
t attention-dedup-row-greens-alone-which-is-the-point 1 \
  "$(grep -cFx 'ok   attention: timeout comment posted exactly once' <<<"$ATT_OUT")"
# And that red stays legible: bare "$first$second" ran the first invocation's
# last line into the second's first, in the one place an operator has to tell
# the two apart. The needle is the glue itself — this fixture's first capture
# ends at `reply_tail=` and the second opens with the registry line, so the two
# meet inside the SESSION END row the red quotes.
t attention-invocation-red-does-not-glue-the-two-captures 0 \
  "$(grep -c 'reply_tail=attention: none new in registry' <<<"$ATT_OUT" | tr -d ' ')"
ATT_SECOND="$ATT_SESSION_OUT2"

# Mutation: the run log does not resolve. Its own row reds and reaches the
# verdict — and the alert row must red WITH it rather than grepping for ""
# and matching any line, which greened §5's "the operator alert fired naming
# the run log" on an alert nothing had checked.
ATT_FIRST="2026-08-09T11:00:02Z SESSION END kind=attention key=$ATT_REPO#$ATT_ISSUE rc=124 dur=1s outcome=TIMEOUT acted=no reply_tail="
ATT_OUT="$(att_timeout_half)"; r1=$?
ATT_FIRST="$ATT_SESSION_OUT"
t attention-run-log-red-reaches-the-halfs-verdict 1 "$r1"
t attention-no-run-log-reds-the-alert-row 1 \
  "$(grep -cFx 'FAIL attention: operator alert named the run log' <<<"$ATT_OUT")"
t attention-no-run-log-alert-red-says-why 1 \
  "$(grep -cF 'read: no run log resolved to check the alert against' <<<"$ATT_OUT")"
# The guard on its own, beside its twin on the derived link.
if rehearsal_attention_alert_names_run_log \
    "$ATT_PHRASE for $ATT_REPO#$ATT_ISSUE" '' "$ATT_ALERTS" >/dev/null; then
  r1=WRONG
else
  r1=refused
fi
t attention-empty-run-log-refuses-rather-than-matching-anything refused "$r1"

# The index the wake reads is cross-repo and lags the assignment that fills it,
# so both halves wait for their own demand to appear in it before invoking —
# otherwise the wake row reds on a correct engine.
ATT_VISIBLE=1
ATT_OUT="$(att_dispatch_half)"; r1=$?
t attention-dispatch-waits-for-the-demand-index 1 \
  "$(grep -cF 'FAIL attention: dispatch demand visible to the identity' <<<"$ATT_OUT")"
t attention-invisible-demand-reaches-the-dispatch-verdict 1 "$r1"
ATT_OUT="$(att_timeout_half)"; r1=$?
t attention-timeout-waits-for-the-demand-index 1 \
  "$(grep -cF 'FAIL attention: timeout demand visible to the identity' <<<"$ATT_OUT")"
t attention-invisible-demand-reaches-the-timeout-verdict 1 "$r1"
ATT_VISIBLE=0

# Mutation: ONLY the pulls endpoint blips. The branch reads are clean, the wake
# is correct, the board is correct — this is one `repos/<sandbox>/pulls` call
# meeting a secondary rate limit, and it is the likelier of the half's two
# board reads to do so, being the `--paginate` listing over the sandbox the
# builder legs above have been opening PRs into. The half reads it twice, at
# two separate moments, so each read is failed on its own.
#
# Before the fix both fell back to `[]`: the precondition passed on a fixture
# it had not checked, and `attention: dispatch opened no PR for the claim` —
# the row #440 §4 calls load-bearing FIRST — printed `ok` having read nothing.
ATT_PULLS_FAIL=first
ATT_OUT="$(att_dispatch_half)"; r1=$?
t attention-unread-pulls-reds-the-fixture-precondition 1 \
  "$(grep -cFx 'FAIL attention: dispatch fixture starts with no PR and no build branch' \
    <<<"$ATT_OUT")"
t attention-unread-pulls-precondition-reaches-the-verdict 1 "$r1"
ATT_PULLS_FAIL=second
ATT_OUT="$(att_dispatch_half)"; r1=$?
ATT_PULLS_FAIL=none
# The precondition is not a backstop for the graded row: the first read was
# clean and passed it, and the second read failed minutes later.
t attention-unread-pulls-precondition-passes-on-the-clean-first-read 1 \
  "$(grep -cFx 'ok   attention: dispatch fixture starts with no PR and no build branch' \
    <<<"$ATT_OUT")"
t attention-unread-pulls-reds-the-graded-absence-row 1 \
  "$(grep -cFx 'FAIL attention: dispatch opened no PR for the claim' <<<"$ATT_OUT")"
t attention-unread-pulls-red-names-the-source 1 \
  "$(grep -cF "read: could not list pull requests of: $ATT_REPO" <<<"$ATT_OUT")"
t attention-unread-pulls-reaches-the-halfs-verdict 1 "$r1"

# The fixture registry the EXIT trap reads (rehearsal.sh). It is written by the
# filer, so the filer must not be called in a command substitution: bash runs
# one in a subshell and the registry dies with it, leaving an open assigned
# claimed+attention issue on the sandbox for the next duty tick.
(
  REHEARSAL_ATTENTION_REPO=""
  REHEARSAL_ATTENTION_ISSUES=""
  gh() { printf '%s\n' 91; }
  rehearsal_attention_file_fixture "$ATT_REPO" "$ATT_IDENTITY" title body
  gh() { printf '%s\n' 92; }
  rehearsal_attention_file_fixture "$ATT_REPO" "$ATT_IDENTITY" title body
  printf '%s|%s|%s\n' "$REHEARSAL_ATTENTION_REPO" \
    "$REHEARSAL_ATTENTION_ISSUES" "$REHEARSAL_ATTENTION_NUM"
) >"$TMP/attention-registry" 2>/dev/null
t attention-fixture-registers-in-the-callers-shell "$ATT_REPO|91 92|92" \
  "$(cat "$TMP/attention-registry")"
t attention-fixture-filer-is-never-command-substituted 0 \
  "$(grep -cE '\$\(rehearsal_attention_file_fixture' \
    "$ROOT/drill/rehearsal-attention.sh" | tr -d ' ')"
# And the registry survives an early return, which is the path that strands a
# fixture: the precondition red at the top of the dispatch half.
(
  REHEARSAL_ATTENTION_REPO=""
  REHEARSAL_ATTENTION_ISSUES=""
  gh() { printf '%s\n' 93; }
  rehearsal_attention_file_fixture "$ATT_REPO" "$ATT_IDENTITY" title body
  # The fixture precondition's own `return 1` path: filed, nothing closed yet.
  gh() { printf '%s\n' "$*" >>"$TMP/attention-cleanup-calls"; }
  rehearsal_attention_cleanup
) 2>/dev/null
t attention-cleanup-closes-the-fixture-after-an-early-return 1 \
  "$(grep -cF "api -X PATCH repos/$ATT_REPO/issues/93 -f state=closed" \
    "$TMP/attention-cleanup-calls" | tr -d ' ')"
t attention-cleanup-clears-the-fixtures-demand 1 \
  "$(grep -cF "api -X DELETE repos/$ATT_REPO/issues/93/labels/attention" \
    "$TMP/attention-cleanup-calls" | tr -d ' ')"

# The opt-out is a skip with a reason, never a silent pass.
REHEARSAL_ATTENTION_STATUS="$TMP/attention-leg-verdicts"
: >"$REHEARSAL_ATTENTION_STATUS"
(
  # shellcheck disable=SC2030  # the fixture identity is intentionally local
  ROLE=builder
  REHEARSAL_ATTENTION_DRILL=0
  skip() { :; }
  rehearsal_attention_drill "$ATT_REPO" "$ATT_IDENTITY" >/dev/null
)
t attention-verdict-opt-out-is-a-skip "builder skip --no-attention-drill" \
  "$(cat "$REHEARSAL_ATTENTION_STATUS")"
unset REHEARSAL_ATTENTION_STATUS

# No agent or box name in the leg: the identity reaches every assertion from
# the round's own variables.
t attention-leg-names-no-agent-or-box 0 \
  "$(grep -ciE 'claude|codex|grok|kimi|crew-drill' \
    "$ROOT/drill/rehearsal-attention.sh" | tr -d ' ')"

# Wiring: the leg is sourced and called in the builder block, and it runs
# AFTER the two wake rows it sits beside, which are unchanged.
# shellcheck disable=SC2016  # match literal builder-block source text
attention_builder_block="$(sed -n '/elif \[ "$ROLE" = "builder" \]/,/^[[:space:]]*else$/p' \
    "$ROOT/drill/rehearsal.sh")"
# shellcheck disable=SC2016  # match literal builder-block source text
if grep -Fq '. "$ROOT/drill/rehearsal-attention.sh"' <<<"$attention_builder_block"; then
  r1=wired
else
  r1=MISSING
fi
t attention-helper-sourced-in-builder-block wired "$r1"
ATT_WAKE_LINE="$(grep -nF 'attention: 📌 pickup comment' "$ROOT/drill/rehearsal.sh" | head -1 | cut -d: -f1)"
ATT_ACK_LINE="$(grep -nF 'attention: label removed (ack re-arms)' "$ROOT/drill/rehearsal.sh" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # match the literal call site in rehearsal.sh
ATT_LEG_LINE="$(grep -nF 'rehearsal_attention_drill "$SANDBOX"' "$ROOT/drill/rehearsal.sh" | head -1 | cut -d: -f1)"
if [ -n "$ATT_WAKE_LINE" ] && [ -n "$ATT_ACK_LINE" ] && [ -n "$ATT_LEG_LINE" ] \
    && [ "$ATT_WAKE_LINE" -lt "$ATT_ACK_LINE" ] && [ "$ATT_ACK_LINE" -lt "$ATT_LEG_LINE" ]; then
  r1=after
else
  r1=WRONG
fi
t attention-leg-follows-the-existing-wake-rows after "$r1"
if grep -Fq -- '--no-attention-drill' "$ROOT/drill/rehearsal-all.sh" \
    && grep -Fq 'attention  (dispatch without code + timeout report)' \
      "$ROOT/drill/rehearsal-all.sh"; then
  r1=wired
else
  r1=MISSING
fi
t attention-all-opt-out-and-summary-wired wired "$r1"

# Neither mark is retyped in the leg. Staged against the real engine source
# with bx() pointed at it in place of the installed tree: a rename in the
# module or the conf must move this leg's subject with it, and the loader is
# the row that says so.
# shellcheck disable=SC2088  # a literal box path, matched not expanded
ATT_BOXPATH='~/duty/'
bx() { bash -c "${1//$ATT_BOXPATH/$ROOT/shared/}"; }
ok() { :; }
fail() { :; }
rehearsal_attention_load_installed_marks
t attention-marks-resolve-from-the-engine-source "present present" \
  "$([ -n "$REHEARSAL_ATTENTION_MARK_PICKUP" ] && printf present || printf MISSING) $([ -n "$REHEARSAL_ATTENTION_TIMEOUT_PHRASE" ] && printf present || printf MISSING)"
t attention-pickup-mark-is-the-confs-own 1 \
  "$(grep -cF "MARK_PICKUP=\"$REHEARSAL_ATTENTION_MARK_PICKUP\"" \
    "$ROOT/shared/conf/fleet.defaults.conf")"
t attention-timeout-phrase-is-the-modules-own 1 \
  "$(grep -cF "$REHEARSAL_ATTENTION_TIMEOUT_PHRASE;" \
    "$ROOT/shared/lib/duty-attention.sh")"
unset -f bx ok fail
# An engine this leg can no longer read is a red row, never a silent pass on
# an empty needle that every body would then contain.
ATT_OUT="$(
  bx() { printf '\n'; }
  ok() { printf 'ok   %s\n' "$1"; }
  fail() { printf 'FAIL %s\n' "$1"; }
  rehearsal_attention_load_installed_marks
)"
t attention-unreadable-marks-red 1 \
  "$(grep -cFx 'FAIL attention: installed pickup mark and timeout phrase resolve' <<<"$ATT_OUT")"

# The lowering is confined to one box shell, which is why no exit path can
# leave it behind. Both halves of that claim are read off the script the leg
# actually sends: the assignment lands AFTER load_conf, in the process that
# calls duty_attention, and nothing under the installed conf or lib is written.
ATT_SCRIPT="$(
  bx() { printf '%s' "$1"; }
  rehearsal_attention_timeout_invoke drill-identity 1 /tmp/attention-capture
)"
t attention-lowering-follows-load-conf 1 \
  "$(awk '/load_conf/ { seen = 1 } seen && /^ *TIMEOUT_ATTENTION=1$/ { print; exit }' \
    <<<"$ATT_SCRIPT" | wc -l | tr -d ' ')"
t attention-lowered-run-writes-no-installed-file 0 \
  "$(grep -cE '(>>?|tee |sed -i|cp ).*duty/(conf|lib)' <<<"$ATT_SCRIPT" | tr -d ' ')"
t attention-lowered-run-calls-the-module-directly 1 \
  "$(grep -cx ' *duty_attention' <<<"$ATT_SCRIPT" | tr -d ' ')"



suite_finish
