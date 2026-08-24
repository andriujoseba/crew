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

t phase0-verifier-covers-suite-roots covered \
  "$(phase0_coverage_result "$HERE/run.sh" "$ROOT/drill/rehearsal.sh")"

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
if grep -Fqx 'unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG' "$HERE/run.sh"; then r1=guarded; else r1=MISSING; fi
t suite-unsets-ambient-crew-config guarded "$r1"
# shellcheck disable=SC2016  # Match the literal assignment in this file.
if grep -Fqx 'export XDG_CONFIG_HOME="$TMP/xdg-empty"' "$HERE/run.sh"; then r1=guarded; else r1=MISSING; fi
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

# List prompt slots omitted by engine render sites. Calls are folded to one
# logical line first; advancing past only the opening "$(`` also finds nested
# render_prompt calls such as review.txt's ONESHOT_RULES argument.
render_site_missing_slots() {  # render_site_missing_slots PROMPTS SOURCE...
  local prompts="$1" source site call rest prompt slot supplied
  shift
  for source in "$@"; do
    while IFS='|' read -r site call; do
      [ -n "$call" ] || continue
      rest="${call#*render_prompt }"
      prompt="${rest%%[[:space:]]*}"
      [ -f "$prompts/$prompt" ] || continue
      supplied="$(printf '%s\n' "$call" | grep -oE '[A-Z_][A-Z_]*=' | tr -d '=' | sort -u)"
      while read -r slot; do
        [ -n "$slot" ] || continue
        case "$slot" in
          DOCTRINE_ENTRYPOINT|DOCTRINE_TRIAGE|DOCTRINE_BUILDER|DOCTRINE_REVIEWER) continue ;;
        esac
        if ! grep -qx "$slot" <<<"$supplied"; then
          printf '%s:%s: %s missing %s\n' "$source" "$site" "$prompt" "$slot"
        fi
      done < <(grep -oE '\{\{[A-Z_][A-Z_]*\}\}' "$prompts/$prompt" \
        | tr -d '{}' | sort -u)
    done < <(awk '
      function calls(text, line, rest, tail, endpos, call) {
        rest = text
        while (match(rest, /\$\(render_prompt[[:space:]]+/)) {
          tail = substr(rest, RSTART)
          endpos = index(tail, ")")
          call = endpos ? substr(tail, 1, endpos) : tail
          print line "|" call
          rest = substr(rest, RSTART + 2)
        }
      }
      {
        if (buf == "") start = NR
        buf = buf $0
        if (sub(/\\[[:space:]]*$/, "", buf)) next
        calls(buf, start)
        buf = ""
      }
      END { if (buf != "") calls(buf, start) }
    ' "$source")
  done
}

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

# --- the leg, driven under a stubbed bx() ---------------------------------
NOTIFY_BX_CALLS="$TMP/rehearsal-notify-bx-calls"
NOTIFY_READS="$TMP/rehearsal-notify-work-reads"
NOTIFY_NOTIFY_READS="$TMP/rehearsal-notify-watch-reads"
# Box-side paths: these tildes are expanded by the BOX's login shell inside
# bx(), which is the whole reason the drill stores them unexpanded.
# shellcheck disable=SC2088
NOTIFY_BACKUP_PATH='~/duty/notify-repos.txt.pre-drill-99'
# shellcheck disable=SC2088
NOTIFY_WORK_BACKUP_PATH='~/duty/repos.txt.pre-drill-99'
notify_snap_reply() {  # $1 present|absent|<anything else = the box did not answer>, $2 contents
  case "$1" in
    present) printf 'present\n'; [ -n "$2" ] && printf '%s\n' "$2"; return 0 ;;
    absent)  printf 'absent\n'; return 0 ;;
    *)       return 255 ;;
  esac
}
notify_stub_bx() {  # $1 the box command, $2 how the second repos.txt read answers
  local n
  printf '%s\n' "$1" >>"$NOTIFY_BX_CALLS"
  case "$1" in
    *getMe*)               printf 'ok\n' ;;
    *fleet.defaults.conf*) printf 'state:needs-human\n' ;;
    # The interlock's backup of the work registry, read through the same
    # three-state snapshot as everything else — this is the read the notify
    # half's safety check is made of. Matched BEFORE the plain repos.txt read
    # below, whose pattern the snapshot's own `cat ~/duty/repos.txt.pre-drill-99`
    # would otherwise match first.
    *"-e ~/duty/repos.txt.pre-drill"*)
      notify_snap_reply "$NOTIFY_WORK_BACKUP_STATE" "$NOTIFY_WORK_BACKUP_TEXT" ;;
    *"cat ~/duty/repos.txt"*)
      n="$(( $(cat "$NOTIFY_READS") + 1 ))"
      printf '%s\n' "$n" >"$NOTIFY_READS"
      if [ "$n" -le 1 ] || [ "$NOTIFY_SECOND_READ" = same ]; then
        printf '%s\n' "$NOTIFY_WORK"
      else
        printf '%s\nheavy-duty/crew\n' "$NOTIFY_WORK"
      fi ;;
    # The three-state read of notify-repos.txt, answered as a real box would:
    # `present` with the contents, `present` alone for a file that exists and
    # is empty, `absent`, or a box that does not answer at all.
    #
    # Counted, because the leg reads this file on both sides of its own write:
    # reads 1 (the pre-drill capture) and 2 (the writer's absence probe) are
    # the pre-drill box, and the read-back in the restore check is the box
    # AFTER teardown. The stub restores nothing, so the default post state is a
    # file that is present and empty — which is exactly what the old
    # `cat … || true` read-back reported on every path, and what the two
    # capture cases below are asserting against.
    *"-e ~/duty/notify-repos.txt"*)
      n="$(( $(cat "$NOTIFY_NOTIFY_READS") + 1 ))"
      printf '%s\n' "$n" >"$NOTIFY_NOTIFY_READS"
      if [ "$n" -le 2 ]; then
        notify_snap_reply "$NOTIFY_PRE_STATE" "$NOTIFY_PRE_TEXT"
      else
        notify_snap_reply "$NOTIFY_POST_STATE" "$NOTIFY_POST_TEXT"
      fi ;;
    *) : ;;
  esac
}
notify_run_leg() {  # $1 how the post-write repos.txt read answers
  NOTIFY_SECOND_READ="$1"
  NOTIFY_PRE_STATE="${2:-present}"
  NOTIFY_PRE_TEXT="${3:-}"
  NOTIFY_WORK_BACKUP_STATE="${4:-present}"
  NOTIFY_WORK_BACKUP_TEXT="$NOTIFY_PRE_DRILL"
  NOTIFY_POST_STATE="${5:-present}"
  NOTIFY_POST_TEXT=""
  : >"$NOTIFY_BX_CALLS"
  printf '0\n' >"$NOTIFY_READS"
  printf '0\n' >"$NOTIFY_NOTIFY_READS"
  REHEARSAL_NOTIFY_BACKUP=""
  REHEARSAL_NOTIFY_ABSENT=0
  (
    REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
    bx() { notify_stub_bx "$1"; }
    gh() { case "$1 $2" in "repo view") return 0 ;; *) return 2 ;; esac; }
    ok()   { printf 'ok   %s\n' "$1"; }
    fail() { printf 'FAIL %s\n' "$1"; }
    skip() { printf 'skip %s\n' "$1"; }
    rehearsal_notify_drill "$NOTIFY_WORK" owner reviewer 2>&1
    printf 'rc=%s\n' "$?"
  )
}

# Must fail: a leg that widened repos.txt reds and ABORTS — the interlock
# outranks the coverage, so the round never reaches the union it came for.
notify_out="$(notify_run_leg widened)"
t notify-widened-work-registry-aborts-the-round "rc=2" "$(tail -n 1 <<<"$notify_out")"
t notify-widened-work-registry-reds-by-name 1 \
  "$(grep -cF 'FAIL notify: repos.txt unchanged' <<<"$notify_out")"
t notify-widened-work-registry-never-reaches-the-union 0 \
  "$(grep -cF 'notify: both halves of the union' <<<"$notify_out")"
t notify-widened-work-registry-runs-no-notify-tick 0 \
  "$(grep -cF 'tick.sh notify' "$NOTIFY_BX_CALLS")"

# The same leg with a stable registry gets past the interlock and restores
# both files on the way out.
notify_out="$(notify_run_leg same)"
t notify-stable-work-registry-passes-the-interlock 1 \
  "$(grep -cF 'ok   notify: repos.txt unchanged' <<<"$notify_out")"
t notify-stable-work-registry-restores-both 1 \
  "$(grep -cF 'ok   notify: teardown restored both registries' <<<"$notify_out")"
t notify-write-replaces-the-fleet-notify-list 1 \
  "$(grep -cF "printf '%s\\n' '$NOTIFY_WORK-notify' > ~/duty/notify-repos.txt" "$NOTIFY_BX_CALLS")"

# A box that shipped a real notify-repos.txt is captured as those bytes, not
# as the empty string a `cat … || true` used to hand back. Proven where it
# matters: the leg's own restore comparison, whose stub puts nothing back, now
# NOTICES — under the old capture it compared "" against "" and passed.
notify_out="$(notify_run_leg same present 'heavy-duty/ceremony')"
t notify-pre-drill-capture-keeps-the-fleet-bytes 1 \
  "$(grep -cF 'FAIL notify: teardown restored both registries' <<<"$notify_out")"
notify_out="$(notify_run_leg same present)"
t notify-pre-drill-capture-empty-file-is-not-a-mismatch 1 \
  "$(grep -cF 'ok   notify: teardown restored both registries' <<<"$notify_out")"

# Must fail: the box stops answering when the leg reads notify-repos.txt back
# after its own restore. The pre-drill file here was present and EMPTY, which
# is the one shape the old `cat … || true` read-back could not tell from
# silence — "" compared equal to "" and the leg reported both registries
# restored, on a box nobody had heard from. The authoritative comparison is
# rehearsal_cleanup's, but this one runs where the leg can still report and it
# should not be the weaker read of the two (claude-bot, round 3).
notify_out="$(notify_run_leg same present '' present unanswerable)"
t notify-in-leg-restore-unanswerable-read-is-not-empty-bytes 1 \
  "$(grep -cF 'FAIL notify: teardown restored both registries' <<<"$notify_out")"
t notify-in-leg-restore-unanswerable-read-is-never-a-pass 0 \
  "$(grep -cF 'ok   notify: teardown restored both registries' <<<"$notify_out")"

# Must fail: the box does not answer when asked what notify-repos.txt held.
# The old read was `cat … 2>/dev/null || true`, so this arrived as empty bytes
# with CAPTURED=1 — and teardown then compared the restored fleet registry
# against "" and passed. Nothing may be written on this path: the absence
# branch of the probe is what licenses teardown's `rm -f`.
notify_out="$(notify_run_leg same unanswerable)"
t notify-unreadable-pre-drill-registry-reds 1 \
  "$(grep -cF 'FAIL notify: the box could not be asked what notify-repos.txt held before the drill' <<<"$notify_out")"
t notify-unreadable-pre-drill-registry-emits-no-ok-union 0 \
  "$(grep -cF 'notify: both halves of the union' <<<"$notify_out")"
t notify-unreadable-pre-drill-registry-writes-nothing 0 \
  "$(grep -cF "> ~/duty/notify-repos.txt" "$NOTIFY_BX_CALLS")"
t notify-unreadable-pre-drill-registry-runs-no-notify-tick 0 \
  "$(grep -cF 'tick.sh notify' "$NOTIFY_BX_CALLS")"

# Must fail: the guard that refuses fleet repositories cannot read the half of
# the host's watch set that the interlock put aside. The read was
# `cat $REPOS_BACKUP ~/duty/notify-repos.txt 2>/dev/null || true` with a caller
# that took the output and no status, so a missing or unreadable backup handed
# the check a SHORTER list at rc 0 — and a check that silently narrows to what
# it can still read is not the refusal the criterion asks for. Nothing may be
# written on this path: the refusal has to land before the registry write.
for notify_backup_state in unanswerable absent; do
  notify_out="$(notify_run_leg same present '' "$notify_backup_state")"
  t "notify-unvouched-work-backup-$notify_backup_state-reds" 1 \
    "$(grep -cF "FAIL notify: the host's pre-drill registries can be read before the notify half is chosen" <<<"$notify_out")"
  t "notify-unvouched-work-backup-$notify_backup_state-writes-nothing" 0 \
    "$(grep -cF "> ~/duty/notify-repos.txt" "$NOTIFY_BX_CALLS")"
  t "notify-unvouched-work-backup-$notify_backup_state-runs-no-notify-tick" 0 \
    "$(grep -cF 'tick.sh notify' "$NOTIFY_BX_CALLS")"
  t "notify-unvouched-work-backup-$notify_backup_state-emits-no-ok-union" 0 \
    "$(grep -cF 'notify: both halves of the union' <<<"$notify_out")"
  t "notify-unvouched-work-backup-$notify_backup_state-mints-no-second-sandbox-write" 0 \
    "$(grep -cF "printf '%s\\n' '$NOTIFY_WORK-notify' > ~/duty/notify-repos.txt" "$NOTIFY_BX_CALLS")"
done
# The round says which, in the verdict block below where the leg's own verdicts
# are read: notify-verdict-unvouched-work-backup-is-a-fail.

# The list the guard reads is really BOTH halves. A repository named only in
# the pre-drill repos.txt backup is refused as the notify candidate, which is
# the half a partial read used to drop.
notify_pre_drill_probe() {  # $1 candidate, $2 backup state, $3 handle: set|unset
  local cand="$1" state="$2" handle="${3:-set}" notify_pre
  (
    NOTIFY_PROBE_STATE="$state"
    REPOS_BACKUP=""
    [ "$handle" = set ] && REPOS_BACKUP="$NOTIFY_WORK_BACKUP_PATH"
    bx() {
      case "$1" in
        *"-e ~/duty/repos.txt.pre-drill"*) notify_snap_reply "$NOTIFY_PROBE_STATE" 'heavy-duty/rig' ;;
        *) return 255 ;;
      esac
    }
    if ! notify_pre="$(rehearsal_notify_pre_drill_registry 'heavy-duty/ceremony' 2>/dev/null)"; then
      printf 'refused\n'
      exit 0
    fi
    rehearsal_notify_candidate_is_safe "$cand" "$NOTIFY_WORK" "$notify_pre" >/dev/null 2>&1
    printf 'rc=%s\n' "$?"
  )
}
t notify-pre-drill-union-refuses-the-work-half "rc=7" \
  "$(notify_pre_drill_probe heavy-duty/rig present)"
t notify-pre-drill-union-refuses-the-notify-half "rc=7" \
  "$(notify_pre_drill_probe heavy-duty/ceremony present)"
t notify-pre-drill-union-passes-a-minted-sandbox "rc=0" \
  "$(notify_pre_drill_probe "$NOTIFY_EXTRA" present)"
t notify-pre-drill-union-refuses-to-answer-unvouched refused \
  "$(notify_pre_drill_probe heavy-duty/rig unanswerable)"
t notify-pre-drill-union-refuses-to-answer-when-the-backup-is-gone refused \
  "$(notify_pre_drill_probe heavy-duty/rig absent)"
t notify-pre-drill-union-refuses-to-answer-with-no-handle refused \
  "$(notify_pre_drill_probe heavy-duty/rig present unset)"
unset -f notify_pre_drill_probe

# The same refusal at the level of the writer itself, which is where the
# `rm -f` is decided: an unanswerable probe leaves no backup path behind, so
# teardown has nothing to restore and nothing to delete.
(
  bx() { return 255; }
  REHEARSAL_NOTIFY_ABSENT=0
  rehearsal_notify_write_registry "$NOTIFY_EXTRA" >/dev/null 2>&1
  printf 'rc=%s absent=%s backup=[%s]\n' \
    "$?" "$REHEARSAL_NOTIFY_ABSENT" "$REHEARSAL_NOTIFY_BACKUP"
) >"$TMP/notify-write-unanswerable"
t notify-write-unanswerable-probe-refuses 'rc=1 absent=0 backup=[]' \
  "$(cat "$TMP/notify-write-unanswerable")"

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

# --- install.sh: fleet.roster is the one agent/role declaration (#35) ----
RHOME="$TMP/roster-home"
RDUTY="$RHOME/duty"
mkdir -p "$RHOME"
roster_install() {
  case " $* " in
    *" --converge-registries "*)
      [ -f "$RDUTY/.crew-seed-repos.txt" ] ||
        cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-seed-repos.txt"
      [ -f "$RDUTY/.crew-example-repos.txt" ] ||
        cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-example-repos.txt"
      [ -f "$RDUTY/.crew-example-notify-repos.txt" ] ||
        cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-example-notify-repos.txt"
      [ -f "$RDUTY/.crew-seed-notify-repos.txt" ] ||
        cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-seed-notify-repos.txt"
      ;;
  esac
  env HOME="$RHOME" DUTY_DIR="$RDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" "$@"
}
roster_install --box claude-builder >/dev/null 2>&1
t install-roster-hire-role 'BOT_ROLES="builder"' "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"
roster_install --box claude-builder >/dev/null 2>&1
t install-roster-upgrade-keeps-role 'BOT_ROLES="builder"' "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"
t install-roster-agent 'BOT_AGENT=claude' "$(grep '^BOT_AGENT=' "$RDUTY/conf/instance.conf")"

# Flagless means preserve, never infer from a production-looking hostname.
roster_install --agent claude --role reviewer >/dev/null 2>&1
roster_install >/dev/null 2>&1
t install-flagless-keeps-explicit-role 'BOT_ROLES="reviewer"' \
  "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"

while read -r roster_box roster_agent roster_role _roster_from; do
  roster_install --box "$roster_box" >/dev/null 2>&1
  hire_conf="$(grep -E '^BOT_(AGENT|ROLES)=' "$RDUTY/conf/instance.conf")"
  roster_install --box "$roster_box" >/dev/null 2>&1
  upgrade_conf="$(grep -E '^BOT_(AGENT|ROLES)=' "$RDUTY/conf/instance.conf")"
  t "install-hire-upgrade-stable-$roster_box" "$hire_conf" "$upgrade_conf"
  t "install-roster-declares-$roster_box" \
    "BOT_AGENT=$roster_agent
BOT_ROLES=\"$roster_role\"" "$upgrade_conf"
done < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/examples/fleet.roster")

# A roster staged by the host beats the shipped fallback.
printf 'claude-builder claude reviewer\n' >"$RDUTY/fleet.roster"
roster_install --box claude-builder >/dev/null 2>&1
t install-staged-roster-wins 'BOT_ROLES="reviewer"' \
  "$(grep '^BOT_ROLES=' "$RDUTY/conf/instance.conf")"

# Operator config and untouched registries converge; local divergence vetoes.
printf 'FLEET_HUMAN="fixture-human"\nMARK_PICKUP="not-the-protocol"\n' >"$RDUTY/conf/fleet.conf"
rm -f "$RDUTY/repos.txt" "$RDUTY/notify-repos.txt"
printf 'fixture/first\n' >"$RDUTY/.crew-seed-repos.txt"
printf 'fixture/wide\n' >"$RDUTY/.crew-seed-notify-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-operator-conf-transport 'FLEET_HUMAN="fixture-human"' \
  "$(grep '^FLEET_HUMAN=' "$RDUTY/conf/fleet.conf")"
t install-registry-first-convergence fixture/first "$(cat "$RDUTY/repos.txt")"
t install-builder-notify-triage-only absent \
  "$([ -f "$RDUTY/notify-repos.txt" ] && printf present || printf absent)"
t install-seed-payload-discarded absent \
  "$([ -e "$RDUTY/.crew-seed-repos.txt" ] || [ -e "$RDUTY/.crew-seed-notify-repos.txt" ] && printf present || printf absent)"

printf 'fixture/second\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-converges-untouched fixture/second "$(cat "$RDUTY/repos.txt")"
printf 'fixture/contained\n' >"$RDUTY/repos.txt"
printf 'fixture/third\n' >"$RDUTY/.crew-seed-repos.txt"
veto_out="$(roster_install --box claude-builder --converge-registries 2>&1)"
t install-registry-vetoes-divergence fixture/contained "$(cat "$RDUTY/repos.txt")"
case "$veto_out" in *"claude-builder: repos.txt diverged"*"LEFT UNCHANGED"*) r1=named ;; *) r1=silent ;; esac
t install-registry-veto-is-loud named "$r1"

# The documented adoption path must work even when provenance records the
# older transported value: manually matching the incoming bytes adopts it.
printf 'fixture/third\n' >"$RDUTY/repos.txt"
printf 'fixture/third\n' >"$RDUTY/.crew-seed-repos.txt"
adopt_out="$(roster_install --box claude-builder --converge-registries 2>&1)"
t install-registry-adopts-manual-match fixture/third "$(cat "$RDUTY/repos.txt")"
case "$adopt_out" in *"adopted and converged"*) r1=adopted ;; *) r1=missing ;; esac
t install-registry-adoption-is-visible adopted "$r1"

# A current-fleet copy matching the shipped example can be adopted without
# provenance; an unknown local copy cannot.
rm -f "$RDUTY/.repos.txt.crew-provenance"
printf 'fixture/shipped-example\n' >"$RDUTY/repos.txt"
printf 'fixture/shipped-example\n' >"$RDUTY/.crew-example-repos.txt"
printf 'fixture/migrated\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-adopts-example fixture/migrated "$(cat "$RDUTY/repos.txt")"
t install-transported-example-discarded absent \
  "$([ -e "$RDUTY/.crew-example-repos.txt" ] && printf present || printf absent)"
rm -f "$RDUTY/.repos.txt.crew-provenance"
printf 'fixture/unknown-local\n' >"$RDUTY/repos.txt"
printf 'fixture/incoming\n' >"$RDUTY/.crew-seed-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-registry-migration-vetoes-unknown fixture/unknown-local "$(cat "$RDUTY/repos.txt")"

# Convergence must fail closed when any one-shot transport leg is absent.
# Call install.sh directly: roster_install deliberately backfills the payloads
# so the ordinary convergence cases exercise the complete host transport.
printf 'fixture/notify-contained\n' >"$RDUTY/notify-repos.txt"
for missing_payload in \
  .crew-seed-repos.txt \
  .crew-seed-notify-repos.txt \
  .crew-example-repos.txt \
  .crew-example-notify-repos.txt; do
  cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-seed-repos.txt"
  cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-seed-notify-repos.txt"
  cp "$ROOT/examples/repos.txt" "$RDUTY/.crew-example-repos.txt"
  cp "$ROOT/examples/notify-repos.txt" "$RDUTY/.crew-example-notify-repos.txt"
  rm -f "$RDUTY/$missing_payload"
  before_repos="$(cat "$RDUTY/repos.txt")"
  before_notify_repos="$(cat "$RDUTY/notify-repos.txt")"
  if refusal_out="$(env HOME="$RHOME" DUTY_DIR="$RDUTY" PATH="$ISHIM" \
    CRON_STATE="$CRON_STATE" /bin/bash "$SHARED/install.sh" \
    --box claude-builder --converge-registries 2>&1)"; then
    r1=0
  else
    r1=$?
  fi
  t "install-incomplete-$missing_payload-refused" 1 "$r1"
  case "$refusal_out" in
    *"missing transported registry payload $missing_payload"*) r1=named ;;
    *) r1="missing: $refusal_out" ;;
  esac
  t "install-incomplete-$missing_payload-named" named "$r1"
  t "install-incomplete-$missing_payload-keeps-repos" \
    "$before_repos" "$(cat "$RDUTY/repos.txt")"
  t "install-incomplete-$missing_payload-keeps-notify-repos" \
    "$before_notify_repos" "$(cat "$RDUTY/notify-repos.txt")"
done
rm -f "$RDUTY/notify-repos.txt"

runtime_fleet="$(DUTY_DIR="$RDUTY" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_fleet_conf; printf "%s|%s" "$FLEET_HUMAN" "$MARK_PICKUP"')"
t install-loads-defaults-then-operator 'fixture-human|📌 picked up' "$runtime_fleet"
# MARK_HANDOFF is a protocol mark like the others: an operator fleet.conf must
# not be able to override it (post-once.sh's dedup keys on the first line, so a
# drifted mark would silently double-post the handoff). Same wire-pin (#91).
printf 'MARK_HANDOFF="not-the-protocol"\n' >>"$RDUTY/conf/fleet.conf"
t handoff-mark-wire-pinned '🤝 handed off at head' \
  "$(DUTY_DIR="$RDUTY" bash -c '. "$DUTY_DIR/lib/common.sh"; load_fleet_conf; printf "%s" "$MARK_HANDOFF"')"
printf 'claude-builder claude triage\n' >"$RDUTY/fleet.roster"
printf 'fixture/wide\n' >"$RDUTY/.crew-seed-notify-repos.txt"
roster_install --box claude-builder --converge-registries >/dev/null 2>&1
t install-triage-notify-seed fixture/wide "$(cat "$RDUTY/notify-repos.txt")"

# The role registry is conf/roles/*.conf and nothing else; a second list — a
# "role manifest" — is what this refuses. Two unrelated manifests have since
# turned up, so rather than delete the guard it subtracts exactly those two
# uses: the content hash of the installed ENGINE tree (#159), and rig's
# PROVENANCE file (#220 — /etc/rig/manifest, which rig owns and crew only
# reads; crew declares no roles in it and could not, since it never writes it).
# A `manifest` that is neither is still a duplicated registry, and the
# subtraction is per LINE, so the qualified phrase has to be written out every
# time it appears in these files.
manifest_hits="$(grep -Rsinw 'manifest' "$SHARED/docs" "$SHARED/README.md" "$SHARED/conf" \
    "$SHARED/lib" "$SHARED/install.sh" "$ROOT/examples/fleet.roster" "$ROOT/cli/crew" \
    "$ROOT/drill" 2>/dev/null \
    | grep -vi 'engine[ ._-]manifest' | grep -vi 'rig[ /._-]manifest' || true)"
if [ -n "$manifest_hits" ]; then
  r1="DUPLICATED: $manifest_hits"
else
  r1=single-source
fi
t install-no-second-role-registry single-source "$r1"
if grep -q -- "--box '\$b'" "$ROOT/cli/crew" || grep -q "install_identity_args.*\\\$b" "$ROOT/cli/crew"; then
  r1=box-keyed
else
  r1=UNKEYED
fi
t upgrade-passes-roster-box-key box-keyed "$r1"

# #283 — every reader of the armed state must agree that only a live tick
# line counts. A paused line contains tick.sh too, so an unanchored probe makes
# routine maintenance silently resume a box the operator deliberately paused.
status_tick_pattern="$(sed -n 's/.*grep -cE "\([^"]*tick\\\.sh\)".*/\1/p' "$ROOT/cli/crew" | head -1)"
upgrade_tick_pattern="$(sed -n 's/.*grep -qE "\([^"]*tick\\\.sh\)".*/\1/p' "$ROOT/cli/crew" | tail -1)"
floor_tick_pattern="$(sed -n "s/.*grep -cE '\([^']*tick\\\\\.sh\)'.*/\1/p" "$ROOT/fleet-floor/server/probe.sh" | head -1)"
t upgrade-status-armed-pattern-is-present present "$([ -n "$status_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-armed-pattern-is-present present "$([ -n "$upgrade_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-floor-armed-pattern-is-present present "$([ -n "$floor_tick_pattern" ] && printf present || printf MISSING)"
t upgrade-armed-pattern-matches-status "$status_tick_pattern" "$upgrade_tick_pattern"
t upgrade-armed-pattern-matches-floor "$floor_tick_pattern" "$upgrade_tick_pattern"

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

# --- notify repo set: work repos union additive handoff targets (#316) ----
# Run the real notifier with an empty-board gh shim. This observes every
# repository it queries without network access or duplicating its set logic in
# the test. A repo in repos.txt is always covered; notify-repos.txt only adds
# cross-repo targets; overlap is queried once.
NSHIM="$TMP/notify-bin"
NLOG="$TMP/notify-gh.log"
mkdir -p "$NSHIM"
cat >"$NSHIM/gh" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-R" ]; then printf '%s\n' "$2" >>"$NLOG"; break; fi
  shift
done
printf '[]\n'
EOF
chmod +x "$NSHIM/gh"
printf '\nBOT_PATH_PREPEND=%q\n' "$NSHIM" >>"$LHOME/duty/conf/agents/claude.conf"
printf 'fixture/work-only\nfixture/both\n' >"$LHOME/duty/repos.txt"
printf 'fixture/notify-only\nfixture/both\n' >"$LHOME/duty/notify-repos.txt"
printf 'fixture-token\n' >"$LHOME/.tg_bot_token"
printf 'fixture-chat\n' >"$LHOME/.tg_chat_id"
: >"$NLOG"
env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh" >/dev/null
t notify-repos-union "fixture/both
fixture/notify-only
fixture/work-only" "$(sort "$NLOG")"
t notify-repos-overlap-once 1 "$(grep -cxF fixture/both "$NLOG")"

# A present but unreadable additive registry takes the same explicit fallback
# path: the work set remains covered, the sweep succeeds, and the operator is
# told that only repos.txt participated.
chmod 000 "$LHOME/duty/notify-repos.txt"
: >"$NLOG"
if notify_unreadable_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh")"; then
  notify_unreadable_rc=0
else
  notify_unreadable_rc=$?
fi
t notify-repos-unreadable-rc 0 "$notify_unreadable_rc"
t notify-repos-unreadable-fallback "fixture/both
fixture/work-only" "$(sort "$NLOG")"
case "$notify_unreadable_out" in
  *"notify-repos.txt missing — falling back to repos.txt"*) r1=logged ;;
  *) r1=SILENT ;;
esac
t notify-repos-unreadable-fallback-is-logged logged "$r1"
chmod 600 "$LHOME/duty/notify-repos.txt"

# With no additive registry the work set is still watched, and the existing
# fallback log remains explicit.
rm -f "$LHOME/duty/notify-repos.txt"
: >"$NLOG"
notify_fallback_out="$(env HOME="$LHOME" DUTY_DIR="$LHOME/duty" NLOG="$NLOG" \
  /bin/bash "$LHOME/duty/bin/notify.sh")"
t notify-repos-fallback "fixture/both
fixture/work-only" "$(sort "$NLOG")"
case "$notify_fallback_out" in
  *"notify-repos.txt missing — falling back to repos.txt"*) r1=logged ;;
  *) r1=SILENT ;;
esac
t notify-repos-fallback-is-logged logged "$r1"

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
cp "$HERE/run.sh" "$P0COVER_SUITE"
cp "$ROOT/drill/rehearsal.sh" "$P0COVER_REHEARSAL"
# shellcheck disable=SC2016  # write a literal synthetic suite dependency
printf '%s%s\n' '$ROOT' '/postmortems' >>"$P0COVER_SUITE"
t phase0-new-suite-root-needs-verification missing:postmortems \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/run.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # write a literal brace-form suite dependency
printf '%s%s\n' '${ROOT}' '/postmortems/report.md' >>"$P0COVER_SUITE"
t phase0-braced-suite-root-needs-verification missing:postmortems \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/run.sh" "$P0COVER_SUITE"
# shellcheck disable=SC2016  # write a dependency beneath the excluded subtree
printf '%s%s\n' '$ROOT' '/fleet-floor/dev/assets.json' >>"$P0COVER_SUITE"
t phase0-excluded-suite-path-refused excluded:fleet-floor/dev \
  "$(phase0_coverage_result "$P0COVER_SUITE" "$P0COVER_REHEARSAL")"
cp "$HERE/run.sh" "$P0COVER_SUITE"
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
  "$(phase0_coverage_result "$HERE/run.sh" "$P0COVER_REHEARSAL")"

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


suite_finish
