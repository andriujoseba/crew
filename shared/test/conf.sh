#!/usr/bin/env bash
# shared/test/conf.sh — standalone conf subject suite.
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

# Shared installer fixture used by the configuration and profile cases below.
ISHIM="$TMP/install-bin"
IHOME="$TMP/install-home"
IDUTY="$IHOME/duty"
CRON_STATE="$TMP/crontab"
mkdir -p "$ISHIM" "$IHOME"
for cmd in awk bash basename cat chmod cp date dirname env find grep head mkdir mktemp mv readlink rm sed sha256sum sort tail tr wc xargs; do
  ln -s "$(command -v "$cmd")" "$ISHIM/$cmd"
done
printf '#!/usr/bin/env bash\nprintf "claude-builder\\n"\n' >"$ISHIM/hostname"
chmod +x "$ISHIM/hostname"
ln -s "$(command -v jq)" "$ISHIM/jq"
printf '#!/usr/bin/env bash\nexit 1\n' >"$ISHIM/gh"
# shellcheck disable=SC2016  # expanded when the fixture shim runs
printf '#!/usr/bin/env bash\n[ "${FIXTURE_GITLESS:-0}" != 1 ] || exit 1\nprintf "fixture-sha\\n"\n' >"$ISHIM/git"
chmod +x "$ISHIM/gh" "$ISHIM/git"

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

# --- #286: ONE SIGNAL OPENS ONE ROUND ----------------------------------------
# The licence is spent by the verdicts that answer it. Every case below was
# inexpressible before the fixtures had a clock.
#
# THE #281 LOOP, in one fixture. Signal opens the round; both panelists answer
# it at the head, one blocking; GitHub has dropped them from requested_reviewers
# the instant they submitted. Before the fix this returned the change-requester
# and did so on every tick, forever, on a tree nobody had changed.
RP_281='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"},"submittedAt":"'$RP_T_VERDICT'"},
         {"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"},"submittedAt":"2026-08-02T10:29:40Z"}]'
# The same blocking verdict with rev-b's approval removed: rev-b now owes a
# first verdict at this head, so it rides through every hold that binds rev-a
# and each fixture below shows WHICH panelist was held rather than an empty set
# that two different rules could have produced.
RP_CR_A_ONLY='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"},"submittedAt":"'$RP_T_VERDICT'"}]'
t rp-286-closed-round-requests-none "" \
  "$(mk_rp "$H" '[]' "$RP_281" '[]' | rp "$(sig "$H" "$RP_T_SIG_OPEN")")"
# ...and the no-push resolution still works: the builder answers with argument,
# pushes nothing, re-signals — a signal NEWER than the blocking verdict — and
# exactly the change-requester is re-requested. The pair is the boundary: revert
# the predicate and the fixture above goes red while this one stays green.
t rp-286-newer-signal-requests-cr-er "rev-a" \
  "$(mk_rp "$H" '[]' "$RP_281" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
# An equal-second tie HOLDS — fail-closed. A signal posted in the same second as
# the verdict cannot be shown to have read it, and the cost of guessing wrong is
# the loop above; the cost of holding is one tick, cleared by the next signal.
t rp-286-same-second-tie-holds "" \
  "$(mk_rp "$H" '[]' "$RP_281" '[]' | rp "$(sig "$H" "$RP_T_VERDICT")")"
# Absent times hold for the same reason — an unstamped verdict is not evidence
# that the signal came after it. (An engine reading a payload from before the
# query carried submittedAt would see exactly this.)
RP_CR_UNSTAMPED='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"},"submittedAt":null}]'
t rp-286-unstamped-verdict-holds "rev-b" \
  "$(mk_rp "$H" '[]' "$RP_CR_UNSTAMPED" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
t rp-286-unstamped-signal-holds "rev-b" \
  "$(mk_rp "$H" '[]' "$RP_CR_A_ONLY" '[]' | rp "$(sig "$H" "")")"
# THE COHERENCE GATE (ruled 2026-08-02, danmt). A `📣` posted mid-round is inert
# until the round closes: rev-a blocked and the builder re-signalled, but rev-b
# still owes a first verdict, so the round is still the panel's and rev-a is not
# re-requested under a signal that would blur two rounds into one head.
t rp-286-coherence-holds-mid-round "" \
  "$(mk_rp "$H" '["rev-b"]' "$RP_CR_A_ONLY" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
# ...and it is the PANEL's round that holds it open, not any request: an
# off-panel reviewer's outstanding request (triage, a human, an advisory
# reviewer) is not the panel's verdict to wait for. Same scoping as
# addressing.jq's $no_panel_reqs, so the two never disagree about whose ball it
# is.
t rp-286-offpanel-request-does-not-hold-the-round "rev-a" \
  "$(mk_rp "$H" '["dan-claude-bot"]' "$RP_CR_AT_HEAD" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
# The gate is narrow BY DESIGN: it binds verdict-holders only. A panelist who
# owes a first verdict at this head is requested even while another request is
# outstanding — otherwise the first round, where the whole panel is requested at
# once and each request lands beside the others, could never complete. Three
# panelists, because that is the smallest set where the two rules can be told
# apart: rev-a is held by the gate, rev-b holds the round open, rev-c rides
# through untouched.
t rp-286-coherence-spares-first-verdicts "rev-c" \
  "$(mk_rp "$H" '["rev-b"]' "$RP_CR_A_ONLY" '[]' \
    | rp "$(sig "$H" "$RP_T_SIG_ANSWER")" '["rev-a","rev-b","rev-c"]')"
# No reviewer is requested twice at one head under one signal: the engine's own
# request puts them back on the list, and the next tick sees that and holds.
t rp-286-requested-not-requested-again "" \
  "$(mk_rp "$H" '["rev-a"]' "$RP_281" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
# The hold is scoped to CHANGES_REQUESTED, the only state that closes a round
# against the builder. A DISMISSED verdict at the head is a WITHDRAWN opinion:
# round_owed does not count it, addressing.jq calls the round closed and
# converged.jq calls it unapproved, so if this predicate held it too the
# panelist would owe a verdict nobody would ever ask for — the stall this issue
# exists to end, arriving through its own fix. An unknown future state takes the
# same door for the same reason.
RP_DISMISSED='[{"author":{"login":"rev-a"},"state":"DISMISSED","commit":{"oid":"'$H'"},"submittedAt":"'$RP_T_VERDICT'"}]'
RP_FUTURE_STATE='[{"author":{"login":"rev-a"},"state":"PONDERED","commit":{"oid":"'$H'"},"submittedAt":"'$RP_T_VERDICT'"}]'
t rp-286-dismissed-verdict-is-re-requested "rev-a rev-b" \
  "$(mk_rp "$H" '[]' "$RP_DISMISSED" '[]' | rp "$(sig "$H" "$RP_T_SIG_OPEN")")"
t rp-286-unknown-state-is-re-requested "rev-a rev-b" \
  "$(mk_rp "$H" '[]' "$RP_FUTURE_STATE" '[]' | rp "$(sig "$H" "$RP_T_SIG_OPEN")")"

# answered-head.jq — the signal. This is the WIP-safety property: a mid-fix push
# moves the head away from the last signalled one, so the engine holds.
RP_SIG_H='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$H"'"}]'
RP_SIG_OLD='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$RP_OLD"'"}]'
RP_SIG_TWO='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$RP_OLD"'"},{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$H"'"}]'
t ah-signal-at-head "$H" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_H" | ah_sha)"
t ah-no-signal-empty "" "$(mk_rp "$H" '[]' '[]' '[]' | ah_sha)"
t ah-latest-signal-wins "$H" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_TWO" | ah_sha)"
# The must-fail made concrete: a WIP push after the last signal (signal at OLD,
# head now H) yields a signalled head != current head, so the engine's
# `answered_head = gql_head` gate is false — it does NOT request. No commit
# inference.
t ah-wip-push-stales-signal "$RP_OLD" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_OLD" | ah_sha)"
# Another user's MARK_ANSWERED is not my signal.
RP_SIG_OTHER='[{"author":{"login":"someone"},"body":"'"$RP_MARK"' '"$H"'"}]'
t ah-other-user-signal-ignored "" "$(mk_rp "$H" '[]' '[]' "$RP_SIG_OTHER" | ah_sha)"
# #286: the licence carries its TIME, and it is the time of the signal it
# returned — the latest one, not the first. Both halves come out of one program
# so no caller can pair a sha with another signal's clock.
RP_SIG_TWO_TIMED='[{"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$RP_OLD"'","createdAt":"'$RP_T_SIG_OPEN'"},
                   {"author":{"login":"me-bot"},"body":"'"$RP_MARK"' '"$H"'","createdAt":"'$RP_T_SIG_ANSWER'"}]'
t ah-carries-the-signal-time "$RP_T_SIG_ANSWER" \
  "$(mk_rp "$H" '[]' '[]' "$RP_SIG_TWO_TIMED" | ah | jq -r '.createdAt')"
t ah-pairs-sha-with-its-own-time "$H $RP_T_SIG_ANSWER" \
  "$(mk_rp "$H" '[]' '[]' "$RP_SIG_TWO_TIMED" | ah | jq -r '"\(.sha) \(.createdAt)"')"
# No signal is the empty OBJECT, never null: _request_panel reads .sha off it
# unconditionally, and request-panel.jq reads .createdAt, so the shape has to
# survive the absence.
t ah-no-signal-is-an-empty-object '{"sha":"","createdAt":""}' \
  "$(mk_rp "$H" '[]' '[]' '[]' | ah)"

# Structural gates (#133 test plan, must-fails).
# The engine acts on the signal, not commits: _request_panel gates on
# answered-head == current head before requesting.
# shellcheck disable=SC2016  # the grep literal contains $gql_head on purpose
if grep -q 'answered-head.jq' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'answered_head" != "\$gql_head"' "$SHARED/lib/duty-builder.sh"; then r1=signal-gated; else r1=UNGATED; fi
t engine-request-requires-signal signal-gated "$r1"
# #286: a predicate can only read what the query asks for, and the handoff query
# carried neither timestamp — which is why the ordering bug was invisible to
# every fixture in this file. Pin both fields at the query.
if grep -q 'comments(last:100){nodes{author{login} body createdAt}}' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'latestOpinionatedReviews(first:50){nodes{author{login} state submittedAt commit{oid}}}' \
       "$SHARED/lib/duty-builder.sh"; then r1=timestamped; else r1=UNTIMED; fi
t engine-request-fetches-ordering-evidence timestamped "$r1"
# The licence crosses into jq as ONE object: request-panel.jq is HANDED the
# signal and reads its time, rather than parsing MARK_ANSWERED out of the
# comments a second time. Two parsers would be two copies of the predicate, and
# the copies drift — head-checks.jq's header is the standing warning. Pinned on
# the wire string, not on prose: a second parser needs $mark to find a signal at
# all, so its absence here is the property.
# shellcheck disable=SC2016  # the grep literals contain $signal_json / $mark
if grep -q -- '--argjson signal "\$signal_json"' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'signal\.createdAt' "$SHARED/lib/jq/request-panel.jq" \
  && ! grep -q 'mark' "$SHARED/lib/jq/request-panel.jq"; then r1=one-object; else r1=RE-DERIVED; fi
t engine-request-passes-the-whole-signal one-object "$r1"
# And exactly one PROGRAM parses the signal, for the same reason. Not one call
# site: #243's resume scan is a second legitimate consumer, and it deliberately
# reuses this parser rather than keeping its own definition of MARK_ANSWERED —
# fleet comments wrap the SHA in backticks or trail punctuation after the
# marker, and resume must classify the exact bodies the request gate does.
# shellcheck disable=SC2016  # the grep literal contains $mark on purpose
t engine-has-one-signal-parser 1 \
  "$(grep -l 'startswith(\$mark)' "$SHARED"/lib/jq/*.jq | wc -l | tr -d ' ')"
# Every consumer reads the licence as the OBJECT it now is: a consumer left
# comparing the raw output to a head would classify every PR as unsignalled —
# resume would re-answer finished rounds forever and the request gate would
# never open (#286).
#
# #452 adds the first consumer that reads it WHOLE: converged.jq is handed the
# same {sha, createdAt} object request-panel.jq gets, and spends the human's
# block with its createdAt. So "one `.sha` read per call site" stops being the
# shape of the property — it was always a proxy — while the property itself is
# unchanged. Every call site is accounted for by exactly one consumption, a
# `.sha` read or a whole-object pass, and the two must still add up: a new call
# site that does neither is a raw output nobody read as an object.
ah_calls="$(grep -c -- '-f "\$[A-Z_]*DIR[A-Za-z_/]*/jq/answered-head\.jq"' "$SHARED/lib/duty-builder.sh")"
ah_sha_reads="$(grep -c "jq -r '\.sha // \"\"'" "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # the grep literal contains $handoff_signal
ah_whole_reads="$(grep -c -- '--argjson signal "\$handoff_signal"' "$SHARED/lib/duty-builder.sh")"
if [ "$ah_calls" -gt 0 ] && [ "$ah_calls" -eq "$((ah_sha_reads + ah_whole_reads))" ]; then
  r1=object-read
else
  r1="MISMATCH($ah_calls/$ah_sha_reads+$ah_whole_reads)"
fi
t engine-signal-consumers-read-the-object object-read "$r1"
# Green-head precondition, mechanical half only: request on green|none, hold else.
# shellcheck disable=SC2016  # the shell literal contains $check_state
if grep -q 'green|none)' "$SHARED/lib/duty-builder.sh"; then r1=green-gated; else r1=UNGATED; fi
t engine-request-green-gated green-gated "$r1"
# Drafts excluded: the request rides the my_open list, built non-draft.
# shellcheck disable=SC2016
if grep -q 'select(.isDraft | not)' "$SHARED/lib/duty-builder.sh"; then r1=draft-excluded; else r1=EXPOSED; fi
t engine-request-excludes-drafts draft-excluded "$r1"
# #155: GitHub rejects connection pages above 100 instead of truncating them.
# Pin the live API ceiling across shared/, not only the query that exposed it.
oversized_connections="$(grep -REho '(first|last):[0-9]+' "$SHARED" \
  | awk -F: '$2 > 100 { print }')"
t graphql-connection-pages-live-valid "" "$oversized_connections"
# A GraphQL error can be non-empty stdout with a non-zero status and a null PR.
# The handoff sweep must validate the object before either _request_panel or
# converged.jq sees it; non-empty is not evidence of a successful fetch.
GQL_EXCESSIVE='{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"EXCESSIVE_PAGINATION"}]}'
GQL_LONG_OK="$(mk_rp "$H" '[]' "$REVS_OK" '[]' | jq --arg mark "$RP_MARK $H" '
  .data.repository.pullRequest += {
    mergeable:"MERGEABLE", labels:{nodes:[]},
    comments:{nodes:([range(0;99) | {author:{login:"someone"},body:"thread"}]
      + [{author:{login:"me-bot"},body:$mark}])}
  }')"
payload_usable() {
  jq -e '.data.repository.pullRequest != null' >/dev/null 2>&1 \
    && printf usable || printf unusable
}
t graphql-error-body-is-unusable unusable "$(printf '%s' "$GQL_EXCESSIVE" | payload_usable)"
t graphql-long-thread-payload-is-usable usable "$(printf '%s' "$GQL_LONG_OK" | payload_usable)"
t graphql-long-thread-converges true \
  "$(printf '%s' "$GQL_LONG_OK" | cj)"
if grep -q "jq -e '.data.repository.pullRequest != null'" "$SHARED/lib/duty-builder.sh" \
  && grep -q 'PR state payload unusable; skipping request and handoff' "$SHARED/lib/duty-builder.sh"; then
  r1=gated
else
  r1=EXPOSED
fi
t graphql-error-gates-request-and-handoff gated "$r1"
# bots-reviewing is best-effort (|| warn), never gating.
# shellcheck disable=SC2016
if grep -q 'could not set \$LABEL_BOTS_REVIEWING' "$SHARED/lib/duty-builder.sh"; then r1='best-effort'; else r1=GATING; fi
t engine-bots-reviewing-best-effort best-effort "$r1"
# MARK_ANSWERED is defined and wire-protected against operator override.
if grep -q '^MARK_ANSWERED=' "$SHARED/conf/fleet.defaults.conf" \
  && grep -q 'wire_answered' "$SHARED/lib/common.sh"; then r1=wire; else r1=UNPROTECTED; fi
t mark-answered-is-wire-protocol wire "$r1"
# The session posts the signal and no longer requests; the argued-exception and
# the resume re-signal survive.
if grep -q 'MARK_ANSWERED' "$SHARED/prompts/fragment-round-rules.txt" \
  && grep -qi 'YOU DO NOT REQUEST' "$SHARED/prompts/fragment-round-rules.txt"; then r1=signals; else r1=STILL-REQUESTS; fi
t round-rules-session-signals signals "$r1"
if grep -qi 'argued exception' "$SHARED/prompts/fragment-round-rules.txt"; then r1=kept; else r1=LOST; fi
t round-rules-argued-exception-kept kept "$r1"
if grep -qi 'round-answered signal' "$SHARED/prompts/resume.txt"; then r1=resignals; else r1=MISSING; fi
t resume-re-signals-after-death resignals "$r1"

# THE ROUND-1 FIX (codex/grok/kimi): the ready→signal death window. The cure is
# ordering — SIGNAL THEN READY, with the signal posted while the PR is still a
# DRAFT (harmless, the engine ignores drafts), so every death lands where resume
# recovers it. Pinned structurally, not by prose grep, in both prompts that flip
# a draft to ready.
for p in build.txt resume.txt; do
  if grep -qiE 'signal[^.]*then[^.]*mark the PR ready-for-review' "$SHARED/prompts/$p"; then r1=signal-first; else r1=WRONG-ORDER; fi
  t "signal-before-ready-$p" signal-first "$r1"
done
# End-to-end of the covered transition: a PR flipped ready with the signal
# already at its head → the engine requests (die-after-ready is safe). The
# die-before-ready arm is a still-draft PR, excluded by my_open
# (engine-request-excludes-drafts) and recovered by resume — proven above.
#
# The two programs are wired together here exactly as _request_panel wires them
# — answered-head.jq's object is what request-panel.jq is handed — so this case
# also pins that the licence survives the trip between them (#286).
RP_READY_SIGNALLED="$(mk_rp "$H" '[]' '[]' "$RP_SIG_H")"
t strand-fix-ready-with-signal-requests "rev-a rev-b" \
  "$(printf '%s' "$RP_READY_SIGNALLED" \
    | rp "$(printf '%s' "$RP_READY_SIGNALLED" | ah)")"
t strand-fix-ready-with-signal-has-signal "$H" \
  "$(printf '%s' "$RP_READY_SIGNALLED" | ah_sha)"
# rebase.txt aligns with the engine: it posts the signal, it does not re-request.
if grep -qi 'MARK_ANSWERED' "$SHARED/prompts/rebase.txt" \
  && ! grep -qi 're-request every panel reviewer' "$SHARED/prompts/rebase.txt"; then r1=aligned; else r1=RACES; fi
t rebase-posts-signal-not-request aligned "$r1"

# --- builder attention dispatch and timeout evidence (#301) -----------------
# A builder pickup may finish an existing PR in this slot, but must hand a new
# build to the normal duty tick. Pin the ruling in both render layers so a
# route/prompt drift cannot silently restore the half-budget build lifecycle.
if grep -q 'test whether it already has an open PR' "$ATT_MOD" &&
   ! grep -q 'IS build work: do it now' "$ATT_MOD"; then r1=dispatched; else r1=BUILDING; fi
t attention-builder-route-dispatches-new-build dispatched "$r1"
if grep -q 'For a builder claim with no open PR, your output is board state, never code' \
     "$SHARED/prompts/attention.txt" &&
   grep -q 'when one exists, keep the issue claimed and assigned' "$ATT_MOD" &&
   grep -q 'A pushed branch keeps the issue claimed and assigned for ORPHANS resume' \
     "$SHARED/prompts/attention.txt" &&
   grep -q 'If a directed hold remains, keep the issue claimed and assigned' "$ATT_MOD" &&
   grep -q 'a standing hold keeps it claimed and assigned with its park re-stated' \
     "$SHARED/prompts/attention.txt" &&
   grep -q 'Only when no build branch exists and no hold remains' "$ATT_MOD" &&
   grep -q 'Only genuinely unstarted work with no remaining hold is unassigned' \
     "$SHARED/prompts/attention.txt"; then
  r1=dispatched
else
  r1=MISSING
fi
t attention-prompt-dispatches-new-build dispatched "$r1"
# Production run_session, not only the behavior stub below, must expose the
# immutable log path consumed by the timeout evidence branch.
# shellcheck disable=SC2016  # literal source assignment, not test expansion
if grep -q 'RUN_SESSION_LOG="\$slog"' "$SHARED/lib/common.sh"; then
  r1=exposed
else
  r1=MISSING
fi
t attention-run-session-exposes-log exposed "$r1"
# shellcheck disable=SC2016  # literal source wiring, not this test's expansion
if grep -q 'fragment-round-rules.txt.*MARK_ANSWERED="\$MARK_ANSWERED"' "$ATT_MOD"; then
  r1=whole
else
  r1=BROKEN
fi
t attention-builder-round-rules-still-whole whole "$r1"
if grep -q '^TIMEOUT_ATTENTION=1800$' "$SHARED/conf/fleet.defaults.conf"; then
  r1=1800
else
  r1=CHANGED
fi
t attention-timeout-budget-unchanged 1800 "$r1"
# duty_attention and duty_builder are separate sessions in one normal tick;
# builder follows attention and launches through the full build budget.
attention_ln="$(grep -n '^duty_attention$' "$SHARED/bin/duty.sh" | cut -d: -f1)"
builder_ln="$(grep -n '^  duty_builder$' "$SHARED/bin/duty.sh" | cut -d: -f1)"
# shellcheck disable=SC2016  # literal source wiring, not this test's expansion
builder_session_block="$(grep -A2 'run_session build ' "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # literal source wiring, not this test's expansion
if [ "$attention_ln" -lt "$builder_ln" ] &&
   grep -q '"\$TIMEOUT_BUILD"' <<<"$builder_session_block"; then
  r1=full-budget
else
  r1=BROKEN
fi
t attention-dispatch-reaches-normal-build-session full-budget "$r1"

# Drive the actual wake with a stubbed run_session. The output log records only
# externally visible effects: COMMENT, ALERT and LEDGER. This distinguishes all
# three outcomes and proves the timeout branch does not settle the seen ledger.
ATT_BEHAVIOR="$TMP/attention-behavior"
mkdir -p "$ATT_BEHAVIOR/bin" "$ATT_BEHAVIOR/work"
cat >"$ATT_BEHAVIOR/bin/post-once.sh" <<'ATTPO'
#!/usr/bin/env bash
printf 'COMMENT %s#%s %s\n' "$1" "$2" "$3" >>"$ATT_CALLS"
ATTPO
chmod +x "$ATT_BEHAVIOR/bin/post-once.sh"
attention_case() { # attention_case <run_session rc> <tag>
  local case_rc="$1" tag="${2:-one}" calls
  calls="$ATT_BEHAVIOR/calls-$case_rc-$tag"
  : >"$calls"
  ATT_CASE_RC="$case_rc" ATT_CASE_TAG="$tag" ATT_CALLS="$calls" \
    bash -s -- "$SHARED" "$ATT_BEHAVIOR" <<'ATTCASE'
set -u
SHARED="$1"; ATT_BEHAVIOR="$2"
export ATT_CALLS
LABEL_ATTENTION=attention
REPOS_FILE="$ATT_BEHAVIOR/repos.txt"
DUTY_DIR="$ATT_BEHAVIOR/duty"
WORK_DIR="$ATT_BEHAVIOR/work"
TREES_DIR="$ATT_BEHAVIOR/trees"
BIN_DIR="$ATT_BEHAVIOR/bin"
ME=builder
TIMEOUT_ATTENTION=1800
DOCTRINE_TRIAGE=TRIAGE.md
DOCTRINE_ENTRYPOINT=AGENTS.md
DOCTRINE_BUILDER=BUILDER.md
DOCTRINE_REVIEWER=REVIEWER.md
FLEET_TRIAGE=triage
FLEET_BENCH=bench
MARK_ADDRESSING=addressing
MARK_ANSWERED=answered
MARK_PICKUP=pickup
mkdir -p "$DUTY_DIR"
gh() { printf 'GH %s\n' "$*" >>"$ATT_CALLS"; printf 'o/r 9 T1\n'; }
read_repo_list() { printf 'o/r\n'; }
report_suppressed() { cat >/dev/null; }
ledger_filter() { cat; }
ledger_suppressed() { cat >/dev/null; }
ledger_commit() { cat >/dev/null; printf 'LEDGER\n' >>"$ATT_CALLS"; }
has_role() { [ "$1" = builder ]; }
ensure_main_clone() { mkdir -p "$2"; }
render_prompt() { printf 'prompt'; }
run_session() {
  RUN_SESSION_RC="$ATT_CASE_RC"
  mkdir -p "$ATT_BEHAVIOR/logs"
  RUN_SESSION_LOG="$ATT_BEHAVIOR/logs/$ATT_CASE_TAG.log"
  : >"$RUN_SESSION_LOG"
}
alert() { printf 'ALERT %s\n' "$1" >>"$ATT_CALLS"; }
warn() { printf 'WARN %s\n' "$1" >>"$ATT_CALLS"; }
log() { :; }
# shellcheck disable=SC1090
source "$SHARED/lib/duty-attention.sh"
duty_attention
ATTCASE
  cat "$calls"
}
ATT_124="$(attention_case 124)"
t attention-timeout-comments-once 1 "$(printf '%s\n' "$ATT_124" | grep -c '^COMMENT ' || true)"
t attention-timeout-alerts-once 1 "$(printf '%s\n' "$ATT_124" | grep -c '^ALERT ' || true)"
t attention-timeout-names-session-log named \
  "$(grep -q 'attention-o__r_9-latest.log' <<<"$ATT_124" && echo named || echo MISSING)"
t attention-timeout-does-not-commit 0 "$(printf '%s\n' "$ATT_124" | grep -c '^LEDGER$' || true)"
t attention-timeout-gh-read-only 1 "$(printf '%s\n' "$ATT_124" | grep -c '^GH api /issues?' || true)"
t attention-timeout-gh-makes-no-writes 0 \
  "$(printf '%s\n' "$ATT_124" | grep '^GH ' | grep -Ec 'issue edit| -X (POST|PATCH|DELETE)|--add-|--remove-' || true)"
# A retry has a different immutable run log but hands post-once a byte-identical
# stable link, so its exact-body match suppresses duplicate board comments.
ATT_124_RETRY="$(attention_case 124 retry)"
t attention-timeout-comment-body-stable \
  "$(printf '%s\n' "$ATT_124" | grep '^COMMENT ')" \
  "$(printf '%s\n' "$ATT_124_RETRY" | grep '^COMMENT ')"
ATT_0="$(attention_case 0)"
t attention-success-no-comment 0 "$(printf '%s\n' "$ATT_0" | grep -c '^COMMENT ' || true)"
t attention-success-no-alert 0 "$(printf '%s\n' "$ATT_0" | grep -c '^ALERT ' || true)"
t attention-success-commits-ledger 1 "$(printf '%s\n' "$ATT_0" | grep -c '^LEDGER$' || true)"
ATT_1="$(attention_case 1)"
t attention-crash-no-comment 0 "$(printf '%s\n' "$ATT_1" | grep -c '^COMMENT ' || true)"
t attention-crash-no-alert 0 "$(printf '%s\n' "$ATT_1" | grep -c '^ALERT ' || true)"
t attention-crash-does-not-commit 0 "$(printf '%s\n' "$ATT_1" | grep -c '^LEDGER$' || true)"

# The drill's separate check survives the ruling, with a changed job: it used
# to be the ONLY containment for this module, and is now an independent
# verification that the filter above actually holds. Keeping it is the
# difference between testing the invariant and trusting it.
if grep -q 'rehearsal_attention_is_clear' "$ROOT/drill/rehearsal-safety.sh" &&
   grep -q 'rehearsal_attention_is_clear' "$ROOT/drill/rehearsal.sh"; then r1=checked; else r1=ASSUMED; fi
t "drill-checks-attention-outside-sandbox" checked "$r1"

# --- credential state reported by the flow (replaces the polled probes) ----
# These run against the REAL common.sh sourced above, with DUTY_DIR pointed at
# a scratch dir, so the marker contract the floor reads is asserted here and
# not merely described in a comment.

# alert() would try to curl Telegram from a unit test; the token files do not
# exist so it returns early, but stub it anyway — a test that depends on the
# absence of a file in $HOME is a test that fails on somebody's laptop.
alert() { :; }

AUTHDIR="$TMP/authstate"; mkdir -p "$AUTHDIR"
DUTY_DIR="$AUTHDIR"

note_auth_failure gh "401 Bad credentials"
t authfail-file-per-service present "$([ -f "$AUTHDIR/.auth-fail.gh" ] && echo present || echo MISSING)"
t authfail-does-not-touch-other-service absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo LEAKED || echo absent)"
t authfail-records-reason found \
  "$(grep -q '401 Bad credentials' "$AUTHDIR/.auth-fail.gh" && echo found || echo MISSING)"

# The first failure must win. Rewriting every tick resets mtime, so a
# credential that died on Monday reads as having died just now — and "when did
# this break" is the only question the file exists to answer.
FIRST="$(cat "$AUTHDIR/.auth-fail.gh")"
sleep 1
note_auth_failure gh "403 something else entirely"
t authfail-first-failure-wins "$FIRST" "$(cat "$AUTHDIR/.auth-fail.gh")"

clear_auth_failure gh
t authfail-cleared absent "$([ -f "$AUTHDIR/.auth-fail.gh" ] && echo PRESENT || echo absent)"
clear_auth_failure gh   # must be idempotent, not an error under set -e
t authfail-clear-idempotent 0 "$?"

# Cross the file-contract boundary instead of testing only its writer. The
# floor probe must read the exact marker common.sh writes, including the
# service-specific filename and its single-line reason (#138, edge 3).
printf 'crew@fixture\n' >"$AUTHDIR/VERSION"
note_auth_failure gh "fixture rejection"
AUTH_PROBE="$(DUTY_DIR="$AUTHDIR" bash "$ROOT/fleet-floor/server/probe.sh" </dev/null)"
case "$AUTH_PROBE" in *$'::gh missing\n'*) r1=missing ;; *) r1=UNREAD ;; esac
t authfail-common-to-probe-state missing "$r1"
case "$AUTH_PROBE" in *'::authfail-gh '*'fixture rejection'*) r1=reason ;; *) r1=LOST ;; esac
t authfail-common-to-probe-reason reason "$r1"
clear_auth_failure gh

# Multi-line reasons: gh's errors routinely are, and one record must stay one
# line or probe.sh's ::key contract silently gains phantom keys.
note_auth_failure vendor "$(printf 'line one\nline two\nline three')"
t authfail-single-line 1 "$(wc -l < "$AUTHDIR/.auth-fail.vendor")"
clear_auth_failure vendor

# check_vendor_credential's tri-state. 2 means "this profile cannot tell from
# local state" and MUST change nothing: neither raise an alarm nor clear a
# real failure someone still has to fix.
# shellcheck disable=SC2034  # read by check_vendor_credential in common.sh
AGENT_LOGIN_HINT="run the thing"
# shellcheck disable=SC2317  # invoked indirectly, by check_vendor_credential
bot_cli_present() { return 0; }
check_vendor_credential
t vendor-present-no-failure absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo PRESENT || echo absent)"

# shellcheck disable=SC2317
bot_cli_present() { return 1; }
check_vendor_credential
t vendor-absent-raises present \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo present || echo MISSING)"

# shellcheck disable=SC2317
bot_cli_present() { return 2; }
check_vendor_credential
t vendor-unknown-does-not-clear present \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo present || echo CLEARED)"
rm -f "$AUTHDIR/.auth-fail.vendor"
check_vendor_credential
t vendor-unknown-does-not-raise absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo RAISED || echo absent)"
unset -f bot_cli_present

# An older agent profile with neither function must be a no-op, not a failure:
# install.sh does not upgrade confs in place, so mid-rollout boxes will have
# exactly this shape.
check_vendor_credential
t vendor-legacy-profile-silent absent \
  "$([ -f "$AUTHDIR/.auth-fail.vendor" ] && echo RAISED || echo absent)"

# --- each agent profile reads its OWN credential store, locally -------------
# Driven against the real conf files with a fabricated HOME, because the whole
# claim of bot_cli_present is that it needs nothing but local disk.

CREDH="$TMP/credhome"; mkdir -p "$CREDH"
cred_rc() {  # cred_rc <agent> <home> [KIMI_CODE_HOME] -> rc of bot_cli_present
  local rc=0
  # Every vendor env override is cleared, not just the one under test: these
  # are read by the sourced profile, and inheriting the RUNNER's credentials
  # would make the result depend on whose machine ran the suite. KIMI_CODE_HOME
  # is the one a caller may set back, in $3, because kimi's home resolver gives
  # it precedence over both probed homes and that precedence is under test.
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$2" KIMI_CODE_HOME="${3:-}" CODEX_HOME="" GROK_HOME="" \
    ANTHROPIC_API_KEY="" XAI_API_KEY=""
    # shellcheck disable=SC1090
    source "$SHARED/conf/agents/$1.conf"; bot_cli_present ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
# base64url with the padding stripped, the way a JWT actually arrives.
b64url() { base64 -w0 | tr '/+' '_-' | tr -d '='; }

# -- claude: refreshTokenExpiresAt, in MILLISECONDS
CH="$CREDH/claude"; mkdir -p "$CH/.claude"
CLAUDE_EXP_MS=$(( ($(date +%s) + 20 * 86400) * 1000 ))
jq -n --argjson r "$CLAUDE_EXP_MS" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-present 0 "$(cred_rc claude "$CH")"

# THE trap, and the reason this profile reads refreshTokenExpiresAt: an access
# token that lapsed hours ago while the refresh token is still good is the
# ordinary steady state, refreshed silently on next use. A profile testing
# `expiresAt` would call a perfectly healthy box logged out three times a day.
jq -n --argjson r "$CLAUDE_EXP_MS" --argjson a "$(( ($(date +%s) - 3600) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:$a,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-stale-access-token-is-fine 0 "$(cred_rc claude "$CH")"

# An expired REFRESH token is the real logout: nothing can renew it but a human.
jq -n --argjson r "$(( ($(date +%s) - 86400) * 1000 ))" \
  '{claudeAiOauth:{accessToken:"a",expiresAt:1,refreshTokenExpiresAt:$r}}' \
  > "$CH/.claude/.credentials.json"
t cred-claude-expired-refresh 1 "$(cred_rc claude "$CH")"
t cred-claude-no-file 1 "$(cred_rc claude "$CREDH/nothing")"

# -- kimi: the refresh token is a JWT; its exp claim is the relogin deadline
KH="$CREDH/kimi"; mkdir -p "$KH/.kimi-code/credentials"
KIMI_EXP=$(( $(date +%s) + 30 * 86400 ))
# A payload sized so base64url PADDING is required — the case a naive decoder
# silently fails on.
KJWT="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code","sub":"u"}' "$KIMI_EXP" | b64url).sig"
jq -n --arg rt "$KJWT" \
  '{access_token:"a",refresh_token:$rt,expires_at:1,token_type:"Bearer"}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-present 0 "$(cred_rc kimi "$KH")"
t cred-kimi-no-file 1 "$(cred_rc kimi "$CREDH/nothing")"
# An expired refresh JWT is a logout, not merely "cannot tell".
KJWT_OLD="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"exp":%d,"scope":"kimi-code"}' "$(( $(date +%s) - 86400 ))" | b64url).sig"
jq -n --arg rt "$KJWT_OLD" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-expired-refresh 1 "$(cred_rc kimi "$KH")"
# Garbage in the JWT slot must be "cannot tell" (2), never a confident logout.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH/.kimi-code/credentials/kimi-code.json"
t cred-kimi-unparseable-is-unknown 2 "$(cred_rc kimi "$KH")"

# -- kimi, the second home. The shipped CLI keeps the same credential at
# ~/.kimi, not ~/.kimi-code, so the profile resolves the home instead of
# assuming it (#240): the fleet's kimi box reported a dead vendor credential
# on every tick while being perfectly logged in. cred_rc clears
# KIMI_CODE_HOME by design, so these four are the unset case.
KH2="$CREDH/kimialt"; mkdir -p "$KH2/.kimi/credentials"
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KH2/.kimi/credentials/kimi-code.json"
t cred-kimi-alt-home-present 0 "$(cred_rc kimi "$KH2")"
# A wider search must reach the SAME parser, not a second, dumber one.
jq -n '{access_token:"a",refresh_token:"not-a-jwt",expires_at:1}' \
  > "$KH2/.kimi/credentials/kimi-code.json"
t cred-kimi-alt-home-unparseable-is-unknown 2 "$(cred_rc kimi "$KH2")"
# Neither home holds anything: still a CONFIDENT logout. A resolver that fell
# back to a path it never checked would answer 2 here and silence a real one.
KH0="$CREDH/kiminone"; mkdir -p "$KH0/.kimi/credentials" "$KH0/.kimi-code/credentials"
t cred-kimi-neither-home 1 "$(cred_rc kimi "$KH0")"

# KIMI_CODE_HOME is explicit operator intent and outranks both probes. Proven
# by pointing it at a home with NO credential while BOTH known homes hold a
# good one: a resolver that probed first would answer 0. cred_rc's third
# argument is the only vendor override it does not clear, for exactly this.
KHO="$CREDH/kimiover"; mkdir -p "$KHO/.kimi/credentials" "$KHO/.kimi-code/credentials" "$KHO/elsewhere/credentials"
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KHO/.kimi/credentials/kimi-code.json"
cp "$KHO/.kimi/credentials/kimi-code.json" "$KHO/.kimi-code/credentials/kimi-code.json"
t cred-kimi-override-outranks-probe 1 "$(cred_rc kimi "$KHO" "$KHO/elsewhere")"
# ...and it reaches a credential neither probe would ever find.
jq -n --arg rt "$KJWT" '{access_token:"a",refresh_token:$rt,expires_at:1}' \
  > "$KHO/elsewhere/credentials/kimi-code.json"
t cred-kimi-override-reaches-elsewhere 0 "$(cred_rc kimi "$KH0" "$KHO/elsewhere")"

# -- the SAME resolution drives PATH, and until now nothing asserted that half
# of #240's D2: BOT_PATH_PREPEND is an assignment evaluated when the profile is
# sourced, so reading it back also proves the resolver is defined ABOVE it.
# The resolved home's bin comes first, then every other known home's — a
# non-existent PATH entry costs nothing, which is why the fallbacks are cheaper
# than guessing right. Only PRESENCE of the credential picks the home here, not
# whether its JWT parses, so the fixtures above are reused exactly as they lie.
path_prepend() {  # path_prepend <home> [KIMI_CODE_HOME] -> BOT_PATH_PREPEND
  # shellcheck disable=SC2034  # consumed inside the conf sourced below
  ( HOME="$1" KIMI_CODE_HOME="${2:-}"
    # shellcheck disable=SC1091
    source "$SHARED/conf/agents/kimi.conf"; printf '%s' "$BOT_PATH_PREPEND" ) 2>/dev/null
}
t path-kimi-alt-home-first "$KH2/.kimi/bin:$KH2/.kimi-code/bin" "$(path_prepend "$KH2")"
t path-kimi-old-home-first "$KH/.kimi-code/bin:$KH/.kimi/bin" "$(path_prepend "$KH")"
# No credential anywhere: the ~/.kimi-code fallback leads, and the other home
# is still on PATH — the CLI may be installed where the credential is not.
t path-kimi-neither-home-falls-back "$KH0/.kimi-code/bin:$KH0/.kimi/bin" "$(path_prepend "$KH0")"
# Explicit operator intent leads here too, even though both probes would hit.
t path-kimi-override-first "$KHO/elsewhere/bin:$KHO/.kimi/bin:$KHO/.kimi-code/bin" \
  "$(path_prepend "$KHO" "$KHO/elsewhere")"

# -- codex: file-backed vs keyring-backed, and NO expiry at all
DH="$CREDH/codex"; mkdir -p "$DH/.codex"
jq -n '{auth_mode:"chatgpt",tokens:{access_token:"a.b.c",refresh_token:"opaque"}}' > "$DH/.codex/auth.json"
t cred-codex-present 0 "$(cred_rc codex "$DH")"
t cred-codex-no-file-is-logout 1 "$(cred_rc codex "$CREDH/nothing")"
# ...unless the box keeps its credential in the desktop keyring, where a
# missing auth.json is normal and must not be reported as a logout.
KB="$CREDH/codexkeyring"; mkdir -p "$KB/.codex"
echo 'cli_auth_credentials_store = "keyring"' > "$KB/.codex/config.toml"
t cred-codex-keyring-is-unknown 2 "$(cred_rc codex "$KB")"

# -- grok: its probe was already a local file test, so it is authoritative
# -- grok: a MAP of "<issuer>::<client_id>" slots, refresh token opaque
GH_="$CREDH/grok"; mkdir -p "$GH_/.grok"
jq -n '{"https://auth.x.ai::abc":{key:"j.w.t",refresh_token:"opaque",expires_at:"2026-07-27T19:54:18Z"}}' \
  > "$GH_/.grok/auth.json"
t cred-grok-present 0 "$(cred_rc grok "$GH_")"
t cred-grok-no-file 1 "$(cred_rc grok "$CREDH/nothing")"
# An empty map is a non-empty FILE. The old `[ -s ]` test called this logged
# in; it is a failed login, and the honest answer is "cannot tell".
echo '{}' > "$GH_/.grok/auth.json"
t cred-grok-empty-map-is-unknown 2 "$(cred_rc grok "$GH_")"

# No profile may define bot_cli_expiry: the floor tracks no expiry dates, and
# a profile still exporting one would be dead code drifting out of sync.
for agent in claude codex grok kimi; do
  r1=absent
  # shellcheck disable=SC1090
  ( source "$SHARED/conf/agents/$agent.conf"; command -v bot_cli_expiry >/dev/null ) 2>/dev/null && r1=DEFINED
  t "cred-$agent-defines-no-expiry" absent "$r1"
done

# --- the per-tick path must not have reacquired a network auth probe -------
# `gh auth status` in the tick is the exact cost this change removed; it would
# pass every assertion above while restoring 7k requests/day.
# The boot gate ABOVE the identity call may still pay for a real probe once
# per boot — certainty is worth one round-trip there. What must never come
# back is a probe in the per-tick path, so the assertion is positional:
# nothing after `ME="$(gh_identity)"` may call it.
r1="$(awk '
  /ME="\$\(gh_identity\)"/ { after = 1 }
  after && /^[^#]*gh auth status/ { print "POLLED"; exit }
' "$SHARED/bin/duty.sh")"
r1="${r1:-clean}"
t tick-does-not-poll-gh-auth clean "$r1"
# ...and the identity call must be the one that harvests the expiry header.
if grep -q 'gh_identity' "$SHARED/bin/duty.sh"; then r1=wired; else r1=MISSING; fi
t tick-uses-gh-identity wired "$r1"
# No expiry date is tracked anywhere any more: four providers express it four
# ways and two cannot answer locally at all, so the countdown was the flaky
# half of the idea. A reintroduced record_token_expiry would put it back.
if grep -q 'record_token_expiry\|token-expiry' "$SHARED/lib/common.sh"; then r1=TRACKED; else r1=clean; fi
t no-expiry-date-tracked clean "$r1"

# Every agent profile must define bot_cli_present, or its box silently never
# reports vendor credential state at all.
missing=""
for agent in claude codex grok kimi; do
  grep -q 'bot_cli_present()' "$SHARED/conf/agents/$agent.conf" || missing="$missing $agent"
done
t agent-profiles-define-present "" "$missing"

# ...and every profile must launch its CLI NON-INTERACTIVELY. run_session runs
# each CLI with </dev/null, deliberately, so a tool-approval prompt has no
# stdin to read and no human to answer it: the session blocks until the role
# budget kills it and writes rc=124 outcome=TIMEOUT — no verdict, no comment,
# 45 minutes spent. kimi shipped with no flag at all and did exactly that on
# every session, which kept every PR in this repo one panel verdict short
# (#240). Nothing here read BOT_CLI_CMD before, so the only detector was a
# 45-minute silence on one box. The flag's SPELLING is the vendor's; that one
# is present is crew's, and this is where crew says so.
for pair in \
  "claude:--dangerously-skip-permissions" \
  "codex:--dangerously-bypass-approvals-and-sandbox" \
  "grok:--permission-mode bypassPermissions" \
  "kimi:--afk"; do
  agent="${pair%%:*}"; want="${pair#*:}"
  # The array is joined and matched with surrounding spaces so a multi-token
  # flag is pinned whole and a longer flag that merely starts the same cannot
  # pass for it.
  # shellcheck disable=SC1090
  got="$( source "$SHARED/conf/agents/$agent.conf"; printf '%s' "${BOT_CLI_CMD[*]}" )"
  case " $got " in *" $want "*) r1=present ;; *) r1=MISSING ;; esac
  t "agent-conf-$agent-non-interactive" present "$r1"
done

# The boot gate must exercise the same Kimi command shape as a real session.
# `kimi doctor` looked plausible but bypassed both --afk and the resolved
# credential home, so the upgraded Kimi box warned on every tick while real
# review sessions succeeded at the same minutes (#240). This fixture accepts
# only the command/environment pair that makes sessions work on that box.
KIMI_PROBE_HOME="$TMP/kimi-probe-home"
mkdir -p "$KIMI_PROBE_HOME/.kimi/bin" "$KIMI_PROBE_HOME/.kimi/credentials"
printf '%s\n' '{"refresh_token":"fixture"}' \
  >"$KIMI_PROBE_HOME/.kimi/credentials/kimi-code.json"
cat >"$KIMI_PROBE_HOME/.kimi/bin/kimi" <<'EOF'
#!/usr/bin/env bash
[ "${KIMI_CODE_HOME:-}" = "$HOME/.kimi" ] || exit 21
[ "${KIMI_PROBE_AUTH:-accept}" != reject ] || exit 23
[ "${KIMI_PROBE_EXPECT_GUARDS:-0}" != 1 ] || {
  [ -z "${DUTY_LOCKED+x}${NOTIFY_LOCKED+x}${DUTY_SNAPSHOT+x}" ] || exit 24
}
[ "${KIMI_PROBE_READ_STDIN:-0}" != 1 ] || cat >/dev/null
[ "${KIMI_PROBE_HANG:-0}" != 1 ] || while :; do sleep 10; done
case " $* " in
  *" --afk -p "*) exit 0 ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$KIMI_PROBE_HOME/.kimi/bin/kimi"

KIMI_TIMEOUT_BIN="$TMP/kimi-timeout-bin"
KIMI_TIMEOUT_CAPTURE="$TMP/kimi-timeout-args"
mkdir -p "$KIMI_TIMEOUT_BIN"
cat >"$KIMI_TIMEOUT_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >"$KIMI_TIMEOUT_CAPTURE"
shift 3
exec /usr/bin/timeout -k 1 1 "$@"
EOF
chmod +x "$KIMI_TIMEOUT_BIN/timeout"

kimi_probe_rc() {  # kimi_probe_rc [working|interactive|logged-out|stdin|guards|bound]
  local shape="${1:-working}" auth=accept read_stdin=0 expect_guards=0 hang=0 rc=0
  [ "$shape" != logged-out ] || auth=reject
  [ "$shape" != stdin ] || read_stdin=1
  [ "$shape" != guards ] || expect_guards=1
  [ "$shape" != bound ] || hang=1
  # shellcheck disable=SC2016  # expansion belongs to the fixture shell
  /usr/bin/timeout -k 1 3 \
    env HOME="$KIMI_PROBE_HOME" SHARED="$SHARED" KIMI_PROBE_SHAPE="$shape" \
    KIMI_PROBE_AUTH="$auth" KIMI_PROBE_READ_STDIN="$read_stdin" \
    KIMI_PROBE_EXPECT_GUARDS="$expect_guards" KIMI_PROBE_HANG="$hang" \
    KIMI_TIMEOUT_BIN="$KIMI_TIMEOUT_BIN" \
    KIMI_TIMEOUT_CAPTURE="$KIMI_TIMEOUT_CAPTURE" \
    DUTY_LOCKED=1 NOTIFY_LOCKED=1 DUTY_SNAPSHOT=fixture \
    bash -c '
      unset KIMI_CODE_HOME
      source "$SHARED/conf/agents/kimi.conf"
      export PATH="$BOT_PATH_PREPEND:$KIMI_TIMEOUT_BIN:/usr/bin:/bin"
      [ "$KIMI_PROBE_SHAPE" != interactive ] || \
        BOT_CLI_CMD=(env "KIMI_CODE_HOME=$(_kimi_home)" kimi -p)
      bot_cli_probe
    ' >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
t kimi-boot-probe-matches-working-session 0 "$(kimi_probe_rc working)"
if [ "$(kimi_probe_rc interactive)" -eq 0 ]; then r1=PASSED; else r1=failed; fi
t kimi-boot-probe-rejects-interactive-session failed "$r1"
if [ "$(kimi_probe_rc logged-out)" -eq 0 ]; then r1=PASSED; else r1=failed; fi
t kimi-boot-probe-rejects-logged-out-session failed "$r1"
KIMI_STDIN_FIFO="$TMP/kimi-probe-stdin"
mkfifo "$KIMI_STDIN_FIFO"
( sleep 5 >"$KIMI_STDIN_FIFO" ) & kimi_stdin_writer=$!
t kimi-boot-probe-closes-inherited-stdin 0 "$(kimi_probe_rc stdin <"$KIMI_STDIN_FIFO")"
kill "$kimi_stdin_writer" 2>/dev/null || true
wait "$kimi_stdin_writer" 2>/dev/null || true
t kimi-boot-probe-clears-lock-environment 0 "$(kimi_probe_rc guards)"
rm -f "$KIMI_TIMEOUT_CAPTURE"
if [ "$(kimi_probe_rc bound)" -eq 0 ]; then r1=PASSED; else r1=failed; fi
t kimi-boot-probe-bounds-hung-cli failed "$r1"
t kimi-boot-probe-timeout-arguments "-k 10 60" \
  "$(cat "$KIMI_TIMEOUT_CAPTURE" 2>/dev/null)"

# --- session action telemetry is best-effort and additive (#256) ----------
SA_LOG="$TMP/session-action.log"
printf 'OpenAI Codex\nfinal answer: Please connect a plugin.\n' >"$SA_LOG"
t session-hookless-is-unknown unknown "$(session_acted "$SA_LOG")"
t session-reply-tail-captured 'final answer: Please connect a plugin.' \
  "$(session_reply_tail "$SA_LOG" | base64 -d)"

codex_acted() {
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/codex.conf"
  bot_session_acted "$SA_LOG" && printf yes || printf no
}
t session-codex-no-tool-is-no no "$(codex_acted)"
printf 'OpenAI Codex\nexec\n/bin/bash -lc git status\nfinal answer: done\n' >"$SA_LOG"
t session-codex-exec-is-yes yes "$(codex_acted)"

claude_acted() {
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/claude.conf"
  session_acted "$SA_LOG"
}
printf 'Claude Code\nfinal answer: I need more information.\n' >"$SA_LOG"
t session-claude-print-log-is-unknown unknown "$(claude_acted)"

# Exercise run_session itself so a helper-only implementation cannot pass.
SA_WORK="$TMP/session-work"; mkdir -p "$SA_WORK"
BOT_CLI_CMD=(bash -c 'printf "exec\ncommand output\nfinal reply\n"')
# shellcheck disable=SC2317  # invoked indirectly by session_acted
bot_session_acted() { grep -qx exec "$1"; }
sa_end="$(run_session build fixture/test "$SA_WORK" 5 prompt | tail -1)"
case "$sa_end" in
  *'outcome=ok acted=yes reply_tail='*) r1=present ;;
  *) r1=MISSING ;;
esac
t session-end-fields-written present "$r1"
t session-end-outcome-token-unchanged ok \
  "$(printf '%s\n' "$sa_end" | sed -n 's/.* outcome=\([^ ]*\).*/\1/p')"
unset -f bot_session_acted

# --- terminal session classification and per-kind breaker (#388) ----------
TERM_LOG="$TMP/session-terminal.log"
printf '%s\n' "Server: Error code: 403 - {'error': {'message': \"You've reached your usage limit for this billing cycle.\", 'type': 'access_terminated_error'}}" >"$TERM_LOG"

kimi_session_classification() (
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  printf "provider error: {'type': 'access_terminated_error'}\n" >"$TERM_LOG"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  printf 'provider error: access_terminated_error; reached your usage limit\n' >"$TERM_LOG"
  if bot_session_terminal "$TERM_LOG"; then printf terminal; else printf transient; fi
  printf '|'
  if bot_session_terminal "$SHARED/conf/agents/kimi.conf"; then printf terminal; else printf transient; fi
  printf '|'
  printf 'Used Shell (gh api repos/o/r/pulls/1/reviews)\n' >"$TERM_LOG.acted"
  if bot_session_acted "$TERM_LOG.acted"; then printf yes; else printf no; fi
  printf '|'
  printf 'Final answer only\n' >"$TERM_LOG.acted"
  if bot_session_acted "$TERM_LOG.acted"; then printf yes; else printf no; fi
)
t kimi-session-hooks 'terminal|terminal|transient|transient|yes|no' \
  "$(kimi_session_classification)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
kimi_quoted_terminal_then_transient() (
  local bdir="$TMP/terminal-breaker-kimi-quoted" i state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  # shellcheck disable=SC1091
  source "$SHARED/conf/agents/kimi.conf"
  BOT_CLI_CMD=(bash -c '
    printf x >>"$BREAKER_CALLS"
    printf "%s\n" "Used Shell (gh issue view 388)"
    printf "%s\n" "Server: Error code: 403 - {'\''error'\'': {'\''message'\'': \"You'\''ve reached your usage limit for this billing cycle.\", '\''type'\'': '\''access_terminated_error'\''}}"
    printf "%s\n" "transient network failure: dial tcp i/o timeout"
    exit 1
  ')
  bot_cli_probe() { printf probe >>"$bdir/probes"; return 0; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in $(seq 1 16); do
    run_session review fixture/repo "$bdir/work" 5 prompt
  done >"$bdir/output"
  state="$(_session_terminal_state review)"
  printf '%s|%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$(grep -c 'outcome=FAILED' "$bdir/output" || true)" \
    "$([ -e "$state" ] && echo tripped || echo clear)" \
    "$([ -e "$bdir/alerts" ] && wc -l <"$bdir/alerts" || echo 0)" \
    "$([ -e "$bdir/probes" ] && wc -c <"$bdir/probes" || echo 0)"
)
t kimi-quoted-terminal-payload-ending-transient-never-trips '16|16|clear|0|0' \
  "$(kimi_quoted_terminal_then_transient)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_case() ( # terminal_breaker_case terminal|transient|hookless
  local shape="$1" bdir="$TMP/terminal-breaker-$1" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"
  LOG_DIR="$bdir/logs"
  DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"
  : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf "%s\n" "$BREAK_TEXT"; exit 1')
  export BREAK_TEXT=transient-network-failure
  if [ "$shape" = terminal ]; then
    BREAK_TEXT=access_terminated_error
    export BREAK_TEXT
    bot_session_terminal() { grep -q access_terminated_error "$1"; }
  elif [ "$shape" = transient ]; then
    bot_session_terminal() { grep -q access_terminated_error "$1"; }
  else
    unset -f bot_session_terminal
  fi
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { printf '%s\n' "$*" >>"$bdir/alerts"; }
  for i in $(seq 1 16); do
    run_session review fixture/repo "$bdir/work" 5 prompt
  done >"$bdir/output"
  local alert_count=0
  [ ! -f "$bdir/alerts" ] || alert_count="$(wc -l <"$bdir/alerts")"
  printf '%s|%s|%s|%s' \
    "$(wc -c <"$BREAKER_CALLS")" \
    "$alert_count" \
    "$(grep -c 'outcome=TERMINAL' "$bdir/output" || true)" \
    "$(grep -c 'SESSION SKIP.*terminal-breaker' "$bdir/output" || true)"
)
t terminal-breaker-replays-sixteen-as-three-dispatches '3|1|3|13' \
  "$(terminal_breaker_case terminal)"
t transient-failures-never-trip '16|0|0|0' \
  "$(terminal_breaker_case transient)"
t hookless-failures-remain-transient '16|0|0|0' \
  "$(terminal_breaker_case hookless)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_resets_sequence() (
  local bdir="$TMP/terminal-breaker-reset" state
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  BOT_CLI_CMD=(bash -c 'printf "%s\n" "$BREAK_TEXT"; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  alert() { :; }
  export BREAK_TEXT=access_terminated_error
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  BREAK_TEXT=transient-network-failure
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  BREAK_TEXT=access_terminated_error
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  state="$(_session_terminal_state review)"
  if [ -s "$state" ]; then
    IFS=$'\t' read -r count status _ <"$state"
    printf '%s|%s' "$count" "$status"
  else
    printf missing
  fi
)
t terminal-breaker-transient-resets-consecutive-count '2|closed' \
  "$(terminal_breaker_resets_sequence)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_timeout_case() (
  local bdir="$TMP/terminal-breaker-timeout" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  BOT_CLI_CMD=(bash -c 'exit 124')
  bot_session_terminal() { return 0; }
  bot_session_acted() { return 1; }
  alert() { printf alert >>"$bdir/alerts"; }
  for i in $(seq 1 16); do run_session review fixture/repo "$bdir/work" 5 prompt; done >"$bdir/output"
  printf '%s|%s' "$(grep -c 'outcome=TIMEOUT' "$bdir/output")" \
    "$([ -e "$(_session_terminal_state review)" ] && echo tripped || echo clear)"
)
t timeout-failures-never-trip '16|clear' "$(terminal_timeout_case)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_kind_isolation() (
  local bdir="$TMP/terminal-breaker-kind" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf access_terminated_error; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  for i in 1 2 3; do run_session review fixture/repo "$bdir/work" 5 prompt; done >/dev/null
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  run_session build fixture/repo "$bdir/work" 5 prompt >/dev/null
  printf '%s|%s' "$(wc -c <"$BREAKER_CALLS")" \
    "$([ -e "$(_session_terminal_state review)" ] && echo review-stopped || echo review-open)"
)
t terminal-breaker-is-keyed-by-kind '4|review-stopped' "$(terminal_kind_isolation)"

# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
terminal_breaker_recovery() (
  local bdir="$TMP/terminal-breaker-recovery" i
  mkdir -p "$bdir/logs" "$bdir/work"
  DUTY_DIR="$bdir"; LOG_DIR="$bdir/logs"; DUTY_TICK_ID=tick-1
  SESSION_TERMINAL_THRESHOLD=3
  export BREAKER_CALLS="$bdir/calls"; : >"$BREAKER_CALLS"
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; printf access_terminated_error; exit 1')
  bot_session_terminal() { grep -q access_terminated_error "$1"; }
  bot_session_acted() { return 1; }
  bot_cli_probe() { return 1; }
  alert() { :; }
  for i in 1 2 3; do run_session review fixture/repo "$bdir/work" 5 prompt; done >/dev/null
  DUTY_TICK_ID=tick-2
  bot_cli_probe() { return 0; }
  BOT_CLI_CMD=(bash -c 'printf x >>"$BREAKER_CALLS"; exit 0')
  run_session review fixture/repo "$bdir/work" 5 prompt >/dev/null
  state="$(_session_terminal_state review)"
  printf '%s|%s' "$(wc -c <"$BREAKER_CALLS")" "$([ -e "$state" ] && echo present || echo cleared)"
)
t terminal-breaker-recovers-on-next-tick '4|cleared' "$(terminal_breaker_recovery)"

# --- #452: THE BOUNCE IS GONE — the two predicates on ONE human-block payload -
# The siblings' agreement extended to the round the human owns. This is the
# whole defect in one snapshot: the panel approves the head, the maintainer
# blocks it, nothing is requested. Before the fix round_owed said `-` and
# converged said true, so the tick handed off — re-requesting the human and
# re-setting state:needs-human over the very block that had just come in, while
# the builder was never woken. The ball has to land on exactly one of these two,
# and asserting both against one payload is what makes that a test rather than a
# claim. Read again with the human RE-REQUESTED, both flip: the wake is spent
# and the PR is legitimately the human's.
HB_PANEL='["p1"]'
HB_REVIEWS='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-11T09:30:00Z"},
  {"state":"CHANGES_REQUESTED","author":{"login":"'$CJ_HUMAN'"},"commit":{"oid":"abc1234"},"submittedAt":"2026-08-11T10:00:00Z"}]'
HB_GQL="$(jq -cn --argjson reviews "$HB_REVIEWS" '{
  data:{repository:{pullRequest:{
    headRefOid:"abc1234",mergeable:"MERGEABLE",
    labels:{nodes:[]},reviewRequests:{nodes:[]},
    latestOpinionatedReviews:{nodes:$reviews}
  }}}
}')"
t round-siblings-human-block-owed owed \
  "$(hc "$HB_PANEL" "$(mk_prc "$CHK_OK" "$HB_REVIEWS")" | cut -f5)"
t round-siblings-human-block-not-converged false \
  "$(printf '%s' "$HB_GQL" | cj '' "$HB_PANEL")"
# Requested: state:needs-human stands, the builder is not re-woken, and the
# handoff does not refire either — nothing re-requests a human already on the
# list, and the label is already set.
HB_REQUESTED="$(printf '%s' "$HB_GQL" \
  | jq -c --arg h "$CJ_HUMAN" '.data.repository.pullRequest.reviewRequests.nodes
             = [{requestedReviewer:{login:$h}}]')"
t round-siblings-human-block-requested-not-owed - \
  "$(hc "$HB_PANEL" "$(mk_prc "$CHK_OK" "$HB_REVIEWS" '[{"login":"'$CJ_HUMAN'"}]')" | cut -f5)"
t round-siblings-human-block-requested-still-not-converged false \
  "$(printf '%s' "$HB_REQUESTED" | cj '' "$HB_PANEL")"
# And the answered round, at the same unchanged head: converged again, so the
# argument reaches the human — while round_owed has NOT re-fired, the human
# still being off the request list until the handoff puts them back on it. The
# builder answering is what moves this, never the engine deciding on its own.
t round-siblings-human-block-answered-converges true \
  "$(printf '%s' "$HB_GQL" | cj "$(sig abc1234 2026-08-11T11:00:00Z)" "$HB_PANEL")"

# The wiring, not just the predicates: both facts must actually reach both
# programs at the handoff call site, off the SAME payload and through the same
# licence program the request path uses. A predicate nobody passes $human to is
# a fix that ships inert.
# shellcheck disable=SC2016
if grep -q 'arg human "\${FLEET_HUMAN:-}"' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'argjson signal "\$handoff_signal"' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'jq/answered-head.jq' "$SHARED/lib/duty-builder.sh"; then
  r1=wired
else
  r1=INERT
fi
t engine-handoff-reads-the-human wired "$r1"
# ...and it is read GUARDED. duty.sh runs `set -euo pipefail`, FLEET_HUMAN has
# no entry in fleet.defaults.conf, and the round-detection call site above runs
# on every tick for every repo — a bare deref there turns "the operator never
# set FLEET_HUMAN" from a handoff that fails into a builder that does not run at
# all. Both new sites take `${FLEET_HUMAN:-}`; empty is the predicates'
# documented "matches nobody", which is exactly today's behaviour.
# shellcheck disable=SC2016
t engine-human-arg-is-set-u-safe 0 \
  "$(grep -c -- '--arg human "\$FLEET_HUMAN"' "$SHARED/lib/duty-builder.sh" || true)"
# Every head-checks.jq and converged.jq invocation passes $human — jq aborts on
# an undefined argument, so a missed call site is a silently empty row or an
# `err` branch, not a loud failure.
# `case` over the captured context, not a `| grep -q`: this file runs under
# pipefail and an early-exiting grep at the end of a pipe is the SIGPIPE red
# the guard above exists to keep out (#443, #449).
# The line numbers arrive by process substitution rather than by a pipe into
# the loop, and the loop reads them one line at a time (SC2013): `missing_human`
# accumulates in the loop BODY, so a `grep | while read` would spend every hit
# in a subshell and leave this guard passing vacuously. `cut` drains its input,
# so nothing at the end of that feeding pipe exits early either.
missing_human=""
while read -r _ph_ln; do
  _ph_ctx="$(sed -n "$((_ph_ln > 6 ? _ph_ln - 6 : 1)),${_ph_ln}p" \
    "$SHARED/lib/duty-builder.sh")"
  case "$_ph_ctx" in
    *"--arg human"*) : ;;
    *) missing_human="${missing_human}${_ph_ln} " ;;
  esac
done < <(grep -n 'jq/head-checks\.jq\|jq/converged\.jq' \
  "$SHARED/lib/duty-builder.sh" | cut -d: -f1)
t engine-every-predicate-call-passes-human "" "${missing_human% }"

# --- wiring (#45/#17) --------------------------------------------------------
if grep -q 'statusCheckRollup' "$BMOD"; then r1=fetched; else r1=MISSING; fi
t ci-red-rollup-fetched fetched "$r1"
# The rollup rides listings that are fetched anyway; it never gets a call of its
# own. THREE fetches, each named: the resume block's authored-PR listing (#384),
# the round/ci-red authored-PR listing, and the one post-ci-red `gh pr view`
# re-read #243 added so a session exiting while checks are pending does not
# consume the head. The resume listing and the round listing are deliberately
# NOT merged into one — the round listing is fetched AFTER the resume sessions
# precisely so a session's own push is visible to it, and a merged snapshot
# would grade ci-red and round-owed against a pre-session tree.
#
# COUNTED AS FETCHES, NOT AS OCCURRENCES OF THE WORD. The old form grepped the
# whole module for the string and had to strip comment lines to keep from
# counting its own explanation — "a detector tripping on its own documentation,
# which this repo has now managed three separate times". It then counted
# `_resume_newest_check`'s jq field READ as a fourth API call, which is the same
# defect one layer down: parsing a field you already have is not fetching it.
# Only a `--json` argument list can name a field to fetch, so that is what is
# counted, and the explanation above can say `statusCheckRollup` freely.
t ci-red-rollup-fetched-on-three-listings 3 \
  "$(grep -c -- '--json [^ ]*statusCheckRollup' "$BMOD")"
# The resume half of that count adds no CALL — the listing was already being
# fetched, and #384 put two more fields on it. A `gh` call inside either new
# predicate would be a per-PR-per-tick cost the issue explicitly priced out.
# _flip_owed_resume_rows is deliberately absent: it makes exactly one GraphQL
# READ per green-headed signalled draft, because the verdicts it must weigh
# cannot come off a listing (#147), and that read is pinned by
# `p384-flip-makes-exactly-one-read` beside the assertions that it never writes.
t resume-check-read-adds-no-gh-call 0 \
  "$(cat <(declare -f _resume_newest_check) <(declare -f _resume_check_states) \
       <(declare -f _green_head_resume_rows) \
     | grep -c 'gh ')"
if grep -q 'number,isDraft,reviewRequests,updatedAt,headRefOid,statusCheckRollup' "$BMOD"; then
  r1=shared
else
  r1=SEPARATE
fi
t ci-red-rollup-on-the-round-call shared "$r1"
# GitHub GraphQL connections cap first/last at 100. The later payload carries
# comments for round-answer detection; pin its live-valid page size.
if grep -q 'comments(last:100)' "$BMOD" \
  && ! grep -Eq 'comments\\((first|last):([1-9][0-9]{2,}|[2-9][0-9]{2})\\)' "$BMOD"; then
  r1=bounded
else
  r1=EXCESSIVE
fi
t builder-comments-page-live-valid bounded "$r1"
# round_owed reads before sessions, while request/convergence reads fresh
# afterward. Two GraphQL snapshots encode that separation; the meaningful
# hc_head/gql_head guard then catches a push between them.
t builder-review-payload-has-early-and-late-snapshots 2 \
  "$(grep -c 'pr_payload=.*gh api graphql' "$BMOD")"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '[ "$hc_head" = "$gql_head" ]' "$BMOD"; then r1=guarded; else r1=MISSING; fi
t builder-late-head-drift-defers-request guarded "$r1"
if grep -q '.seen-ci-red' "$BMOD"; then r1=ledgered; else r1=UNGUARDED; fi
t ci-red-signal-ledgered ledgered "$r1"
# shellcheck disable=SC2016  # the literal the module contains, not an expansion
if grep -Fq '.suppressed-ci-red.$slug' "$BMOD"; then r1=perrepo; else r1=SHARED; fi
t ci-red-suppression-perrepo perrepo "$r1"
# An idle tick must still write a line (#53): a block that logs only when it
# fires makes a quiet box and a busy box look identical.
if grep -q 'no ci-red duty' "$BMOD"; then r1=logged; else r1=SILENT; fi
t ci-red-idle-logs logged "$r1"
# #17's first acceptance criterion: the builder wakes for its own red PR BEFORE
# claiming another issue. Ordering in the file is the ordering in the tick.
ci_at="$(grep -n -- '--- CI-RED' "$BMOD" | head -1 | cut -d: -f1)"
build_at="$(grep -n -- '--- BUILD' "$BMOD" | head -1 | cut -d: -f1)"
if [ -n "$ci_at" ] && [ -n "$build_at" ] && [ "$ci_at" -lt "$build_at" ]; then
  r1=before
else
  r1=AFTER
fi
t ci-red-wakes-before-build before "$r1"
t ci-red-prompt-exists yes "$([ -f "$SHARED/prompts/ci-red.txt" ] && echo yes || echo NO)"
t ci-red-budget-defined yes \
  "$(grep -q '^TIMEOUT_CIRED=' "$SHARED/conf/roles/builder.conf" && echo yes || echo NO)"
# The doctrine half of #45, now the request half of #133: the green-check
# precondition is enforced by the ENGINE (_request_panel requests only on a
# green or absent head) and the prompt keeps green as a ruled term for the
# argued-exception the session still owns.
# shellcheck disable=SC2016  # the shell literal contains $check_state
if grep -q 'green|none)' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'GREEN IS A RULED TERM' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=stated
else
  r1=SILENT
fi
t round-rules-state-green-head stated "$r1"
# ...including the exception, or the rule becomes one agents route around
# silently instead of arguing with in the open.
if grep -q 'argued exception' "$SHARED/prompts/fragment-round-rules.txt"; then r1=stated; else r1=SILENT; fi
t round-rules-state-exception stated "$r1"

# --- re-request by head, not by verdict (danmt, #64 round) -------------------
# BUILDER.md and build.txt both said to re-request "exactly the non-approvers",
# while converged.jq counts an approval ONLY at the current head:
#
#   map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid) | ...)
#     as $head_approvers
#   | (($panel - $head_approvers) | length == 0) as $panel_approves
#
# So the moment a fix round pushes a commit, an earlier approver goes stale, is
# not re-requested, never re-approves, and $panel - $head_approvers is never
# empty — the handoff wake cannot fire and the PR stalls looking finished. The
# same silent-stall shape as the reviewDecision bug (ceremony#26/#39). This PR
# was itself a live instance: grok approved at e13b0dd, the rebase onto #57
# moved the head, and re-requesting only the two change-requesters would have
# left it unconvergeable.
#
# rebase.txt already had the principle right — it is the one prompt where a
# push is guaranteed. Asserting the invariant rather than the prose: the
# predicate keys on the head, so the prompts that tell a builder whom to
# re-request must say head.
# shellcheck disable=SC2016,SC2100  # jq literal; r1 is a string result here
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/converged.jq"; then
  r1=head-keyed
else
  r1=CHANGED
fi
t converged-counts-approvals-at-head head-keyed "$r1"
# The invariant is unchanged; #133 MOVED the actor. "Re-request by head, not by
# verdict" now lives in request-panel.jq, which returns every panelist not
# approving the CURRENT head (approvers included after a push) — so the
# head-keying that used to have to survive in prompt prose survives as code.
# shellcheck disable=SC2016,SC2100  # jq literal; r1 is a string result here
if grep -q 'commit.oid == \$pr.headRefOid' "$SHARED/lib/jq/request-panel.jq"; then r1=head-keyed; else r1=CHANGED; fi
t requestpanel-keys-on-head head-keyed "$r1"
# The prompts must tell the builder the ENGINE requests — a builder still told to
# re-request would race the engine and the reconciler.
for p in build.txt fragment-round-rules.txt; do
  if grep -qi 'engine' "$SHARED/prompts/$p" && grep -qiE 'do not request|engine requests|engine (does|then requests)' "$SHARED/prompts/$p"; then
    r1=stated
  else
    r1=SILENT
  fi
  t "rerequest-moved-to-engine-$p" stated "$r1"
done
# The no-push half survives, now engine-side: request-panel.jq re-requests a
# change-requester still AT the current head once the round is signalled answered
# (proved by rp-no-push-cr-at-head-requests-cr-er above), and the prompt names
# that case so the builder knows an argument-only answer still reaches the panel.
if grep -qi 'pushed nothing' "$SHARED/prompts/fragment-round-rules.txt"; then r1=carved; else r1=MISSING; fi
t rerequest-no-push-half-engine-side carved "$r1"
if grep -q 'AUTO_APPROVE_REREQUEST' "$SHARED/conf/fleet.defaults.conf"; then r1=present; else r1=GONE; fi
t auto-approve-rerequest-still-backs-the-carveout present "$r1"

# --- install.sh: the operator agent-profile transport contract (#75) --------
# The ordering is the whole difficulty (codex Blocking 4 on #73): install.sh
# refuses an unknown agent BEFORE it creates conf/agents, so a profile that
# arrived only with the conf copy would fail its own validation — a vendor
# that lists in `crew profiles` and dies at `crew hire`. The host stages
# operator profiles into ~/duty/.crew-seed-agents ahead of the run; these
# fixtures assert every clause: a seeded profile passes validation, the
# operator copy is what conf/agents carries (same-name wins where load_conf
# reads), the seed is consumed on success AND failure, and an unseeded
# unknown agent still dies.
PHOME="$TMP/profile-home"
PDUTY="$PHOME/duty"
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/vendorx.conf" <<'EOF'
# vendorx — operator-supplied fixture vendor (never shipped)
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="vendorx"
AGENT_LOGIN_HINT="vendorx auth login"
bot_cli_probe() { return 0; }
bot_cli_present() { command -v vendorx >/dev/null 2>&1; }
EOF
profile_install() {
  env HOME="$PHOME" DUTY_DIR="$PDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" "$@"
}
if profile_install --agent vendorx --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-validates-before-conf-exists 0 "$r1"
[ -f "$PDUTY/conf/agents/vendorx.conf" ] && r1=installed || r1=missing
t operator-profile-lands-in-conf-agents installed "$r1"
if grep -q 'operator-supplied fixture vendor' "$PDUTY/conf/agents/vendorx.conf" 2>/dev/null; then
  r1=operator
else
  r1=other
fi
t operator-profile-is-the-operator-copy operator "$r1"
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed consumed "$r1"
# The shipped set still installs whole beside the operator's addition.
[ -f "$PDUTY/conf/agents/claude.conf" ] && r1=present || r1=missing
t operator-profile-shipped-set-intact present "$r1"

# Same-name precedence: an operator claude.conf beats the shipped one — and
# the win must hold at RUNTIME, where load_conf sources whatever
# conf/agents carries (common.sh:34); settled in the copy, not by a reader.
mkdir -p "$PDUTY/.crew-seed-agents"
cat >"$PDUTY/.crew-seed-agents/claude.conf" <<'EOF'
# claude — operator override fixture
# shellcheck shell=bash disable=SC2034
BOT_PATH_PREPEND=""
BOT_CLI_CMD="claude"
AGENT_LOGIN_HINT="operator override wins"
bot_cli_probe() { return 0; }
bot_cli_present() { return 0; }
EOF
profile_install --agent claude --role reviewer >/dev/null 2>&1
if grep -q 'operator override fixture' "$PDUTY/conf/agents/claude.conf" 2>/dev/null; then
  r1=operator
else
  r1=shipped
fi
t operator-profile-same-name-wins operator "$r1"
# shellcheck disable=SC2016  # $DUTY_DIR and $AGENT_LOGIN_HINT expand in the child shell
runtime_hint="$(env DUTY_DIR="$PDUTY" HOME="$PHOME" bash -c \
  '. "$DUTY_DIR/lib/common.sh"; load_conf; printf %s "$AGENT_LOGIN_HINT"')"
t operator-profile-wins-at-load_conf "operator override wins" "$runtime_hint"

# The gap the contract closes, inverted: an agent nobody transported and
# nobody ships must still die at validation, not at first duty tick.
if profile_install --agent vendory --role reviewer >/dev/null 2>&1; then r1=0; else r1=$?; fi
t operator-profile-unknown-still-refused 1 "$r1"

# A one-install transport on FAILURE too: a failing install (here: a role
# that does not exist, checked after the agent) must not leave seeds behind
# for a later bare run to resurrect.
mkdir -p "$PDUTY/.crew-seed-agents"
printf '# vendorz — fixture\n' >"$PDUTY/.crew-seed-agents/vendorz.conf"
profile_install --agent vendorz --role nosuchrole >/dev/null 2>&1 || true
[ -d "$PDUTY/.crew-seed-agents" ] && r1=lingers || r1=consumed
t operator-profile-seed-consumed-on-failure consumed "$r1"

# --- the instrument, against a scratch tree -------------------------------
EM="$SHARED/bin/engine-manifest.sh"
EMDUTY="$TMP/manifest-duty"
mkdir -p "$EMDUTY/bin" "$EMDUTY/lib/jq" "$EMDUTY/prompts" "$EMDUTY/conf/roles" "$EMDUTY/conf/agents"
printf 'echo duty\n'    >"$EMDUTY/bin/duty.sh"
printf 'common\n'       >"$EMDUTY/lib/common.sh"
printf '.a\n'           >"$EMDUTY/lib/jq/x.jq"
printf 'prompt\n'       >"$EMDUTY/prompts/p.txt"
printf 'role\n'         >"$EMDUTY/conf/roles/reviewer.conf"
printf 'agent\n'        >"$EMDUTY/conf/agents/claude.conf"
printf 'defaults\n'     >"$EMDUTY/conf/fleet.defaults.conf"
printf 'crew@9.9.9 (deadbee)\ninstalled 2026-07-29T00:00:00Z\n' >"$EMDUTY/VERSION"
em() { env DUTY_DIR="$EMDUTY" bash "$EM" "$@"; }
em_field() { em --report | sed -n "s/^$1=//p" | head -1; }

# A box with an engine and no record is UNVERIFIED, never modified: on the day
# this ships every box in the fleet is in exactly this state, and a fleet-wide
# false alarm is how an instrument gets ignored forever.
t manifest-no-record-is-unverified unverified "$(em_field state)"
t manifest-no-record-has-no-recorded-version "" "$(em_field recorded)"
em --record
t manifest-after-record-is-current current "$(em_field state)"
t manifest-records-the-stamp "crew@9.9.9 (deadbee)" "$(em_field recorded)"

# MUST FAIL: a hash over names and mtimes. touch moves every mtime and no
# content, and a same-size edit moves content and no size.
touch "$EMDUTY/bin/duty.sh" "$EMDUTY/lib/common.sh"
t manifest-touch-is-not-modification current "$(em_field state)"
printf 'echo DUTY\n' >"$EMDUTY/bin/duty.sh"   # same byte count, different bytes
t manifest-same-size-edit-is-modified modified "$(em_field state)"
t manifest-edit-names-the-path "path=modified bin/duty.sh" \
  "$(em --report --paths | grep '^path=')"
t manifest-modified-still-names-its-version "crew@9.9.9 (deadbee)" "$(em_field recorded)"

# Re-shipping identical bytes converges: the same content hashes the same, so a
# converging re-run stays converging and still says so.
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"
t manifest-identical-bytes-converge current "$(em_field state)"

# An added file and a deleted one are somebody's hand on the box too, and the
# hashes alone cannot tell them apart from each other — the names must be in
# the manifest, which is why it is a listing and not one digest.
printf 'hotfix\n' >"$EMDUTY/bin/hotfix.sh"
t manifest-added-file-is-detected modified "$(em_field state)"
t manifest-added-file-is-named "path=added bin/hotfix.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin/hotfix.sh" "$EMDUTY/lib/jq/x.jq"
t manifest-deleted-file-is-named "path=removed lib/jq/x.jq" "$(em --report --paths | grep '^path=')"
printf '.a\n' >"$EMDUTY/lib/jq/x.jq"

# MUST FAIL: enumerating `-type f`. find does not follow symlinks, so a symlink
# is neither `f` nor `d` and a -type f walk goes straight past it — one
# `ln -s /anything ~/duty/bin/hotfix.sh` was an executable path the record
# never named and every upgrade certified clean.
ln -s /bin/sh "$EMDUTY/bin/hotfix.sh"
t manifest-added-symlink-is-detected modified "$(em_field state)"
t manifest-added-symlink-is-named "path=added bin/hotfix.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin/hotfix.sh"
t manifest-after-symlink-removed-is-current current "$(em_field state)"

# A symlink is hashed by what it IS, never by what it points at. sha256sum on a
# link silently hashes the referent, so a shipped file replaced by a link to a
# byte-identical copy elsewhere would read `current` while the engine executes
# a file the record never measured.
cp "$EMDUTY/bin/duty.sh" "$TMP/manifest-duty-elsewhere.sh"
rm -f "$EMDUTY/bin/duty.sh"
ln -s "$TMP/manifest-duty-elsewhere.sh" "$EMDUTY/bin/duty.sh"
t manifest-file-swapped-for-link-is-modified modified "$(em_field state)"
t manifest-file-swapped-for-link-is-named "path=modified bin/duty.sh" \
  "$(em --report --paths | grep '^path=')"

# ...and the same link DANGLING must still be a verdict, not a crash: sha256sum
# on a broken link fails, and under `pipefail` that would take state() down with
# it — the instrument going silent on the one box that needs it.
rm -f "$EMDUTY/bin/duty.sh"
ln -s "$TMP/no-such-file-anywhere" "$EMDUTY/bin/duty.sh"
if em --state >/dev/null 2>&1; then r1=0; else r1=$?; fi
t manifest-dangling-link-does-not-crash 0 "$r1"
t manifest-dangling-link-is-modified modified "$(em_field state)"
rm -f "$EMDUTY/bin/duty.sh"
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"

# Nor is a symlink the only entry a -type f walk misses; the rule that survives
# review is the simple one — under an engine root, anything that is not a
# directory is engine surface.
mkfifo "$EMDUTY/lib/pipe"
t manifest-added-fifo-is-detected modified "$(em_field state)"
t manifest-added-fifo-is-named "path=added lib/pipe" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/lib/pipe"

# An engine ROOT replaced by a symlink is the same hole one level up: the link
# must be named AND the tree behind it still measured, or an operator redirects
# bin/ and every file the engine runs goes unread.
mkdir -p "$TMP/manifest-elsewhere-bin"
mv "$EMDUTY/bin/duty.sh" "$TMP/manifest-elsewhere-bin/duty.sh"
rmdir "$EMDUTY/bin"
ln -s "$TMP/manifest-elsewhere-bin" "$EMDUTY/bin"
t manifest-redirected-root-is-named "path=added bin" "$(em --report --paths | grep '^path=')"
printf 'echo TAMPERED\n' >"$TMP/manifest-elsewhere-bin/duty.sh"
t manifest-redirected-root-still-measures-content \
  "path=added bin
path=modified bin/duty.sh" "$(em --report --paths | grep '^path=')"
rm -f "$EMDUTY/bin"
mkdir -p "$EMDUTY/bin"
printf 'echo duty\n' >"$EMDUTY/bin/duty.sh"
t manifest-after-root-restored-is-current current "$(em_field state)"

# Every root install.sh writes into is covered — a gap here is a file an
# operator can edit invisibly, and the list is easy to under-fill by hand.
for f in bin/duty.sh lib/common.sh lib/jq/x.jq prompts/p.txt \
         conf/roles/reviewer.conf conf/agents/claude.conf conf/fleet.defaults.conf; do
  printf 'tampered\n' >>"$EMDUTY/$f"
  t "manifest-covers[$f]" modified "$(em_field state)"
  case "$f" in
    bin/duty.sh)              printf 'echo duty\n' >"$EMDUTY/$f" ;;
    lib/common.sh)            printf 'common\n'    >"$EMDUTY/$f" ;;
    lib/jq/x.jq)              printf '.a\n'        >"$EMDUTY/$f" ;;
    prompts/p.txt)            printf 'prompt\n'    >"$EMDUTY/$f" ;;
    conf/roles/reviewer.conf) printf 'role\n'      >"$EMDUTY/$f" ;;
    conf/agents/claude.conf)  printf 'agent\n'     >"$EMDUTY/$f" ;;
    *)                        printf 'defaults\n'  >"$EMDUTY/$f" ;;
  esac
done
t manifest-restored-tree-is-current current "$(em_field state)"

# Per-box state and configuration are OUT of the manifest, each for its own
# reason: duty.log and the work trees change on every tick; instance.conf is
# machine-derived and the drill itself appends to it (rehearsal.sh's
# AUTO_APPROVE_REREQUEST fixture); fleet.conf is transported on every install;
# the registries carry their own divergence provenance in apply_registry.
# Any of these inside the manifest reports a healthy fleet as modified.
mkdir -p "$EMDUTY/work" "$EMDUTY/trees" "$EMDUTY/logs"
printf 'tick\n'                     >"$EMDUTY/duty.log"
printf 'AUTO_APPROVE_REREQUEST=0\n' >"$EMDUTY/conf/instance.conf"
printf 'FLEET_BENCH="x"\n'          >"$EMDUTY/conf/fleet.conf"
printf 'owner/repo\n'               >"$EMDUTY/repos.txt"
printf 'scratch\n'                  >"$EMDUTY/work/session.json"
t manifest-ignores-per-box-state current "$(em_field state)"

# A record this shape cannot read is unverified, not modified: the algorithm
# ships WITH the engine, so a record from another format version must never
# read as somebody's edit.
cp "$EMDUTY/.engine-manifest" "$TMP/manifest-v1-backup"
sed -i '1s/.*/# crew-engine-manifest v99 crew@9.9.9/' "$EMDUTY/.engine-manifest"
t manifest-foreign-format-is-unverified unverified "$(em_field state)"
cp "$TMP/manifest-v1-backup" "$EMDUTY/.engine-manifest"

# No engine at all is `absent`, which is not a fault to report — it is `crew
# hire`, and the status table already says so.
mv "$EMDUTY/VERSION" "$TMP/manifest-version-backup"
t manifest-no-engine-is-absent absent "$(em_field state)"
mv "$TMP/manifest-version-backup" "$EMDUTY/VERSION"

# --- the installer: records, then refuses ---------------------------------
# Real installs into a scratch DUTY_DIR, through the same curated PATH the
# other installer fixtures use.
MHOME="$TMP/manifest-install-home"
MDUTY="$MHOME/duty"
mkdir -p "$MHOME"
minstall() {
  env HOME="$MHOME" DUTY_DIR="$MDUTY" PATH="$ISHIM" CRON_STATE="$CRON_STATE" \
    /bin/bash "$SHARED/install.sh" --agent claude --role reviewer "$@"
}
mstate() { env DUTY_DIR="$MDUTY" bash "$EM" --state; }
minstall >/dev/null 2>&1
t install-records-a-manifest current "$(mstate)"
t install-manifest-names-the-version "crew@$(head -1 "$ROOT/VERSION") (fixture-sha)" \
  "$(env DUTY_DIR="$MDUTY" bash "$EM" --report | sed -n 's/^recorded=//p')"

# The converging re-run: identical bytes, so the box is still current and the
# installer does not refuse itself.
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-reship-identical-rc 0 "$r1"
t install-reship-identical-stays-current current "$(mstate)"

# The half of this issue that loses work: a modified tree is REFUSED, and
# nothing is written.
printf '# hotfix by hand\n' >>"$MDUTY/bin/duty.sh"
hotfix_before="$(cat "$MDUTY/bin/duty.sh")"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-modified-rc 1 "$r1"
case "$refuse_out" in *"REFUSING to overwrite a MODIFIED engine"*) r1=refused ;; *) r1=SILENT ;; esac
t install-refusal-is-loud refused "$r1"
case "$refuse_out" in *"modified bin/duty.sh"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-path named "$r1"
case "$refuse_out" in *"crew@$(head -1 "$ROOT/VERSION")"*) r1=versioned ;; *) r1=BARE ;; esac
t install-refusal-names-the-version versioned "$r1"
t install-refusal-changes-nothing "$hotfix_before" "$(cat "$MDUTY/bin/duty.sh")"

# --force is the whole escape hatch, and it must actually proceed.
if minstall --force >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-force-proceeds-rc 0 "$r1"
case "$(cat "$MDUTY/bin/duty.sh")" in *"hotfix by hand"*) r1=SURVIVED ;; *) r1=overwritten ;; esac
t install-force-overwrites overwritten "$r1"
t install-force-re-records-current current "$(mstate)"

# The other half of --force, and the reason it is an escape hatch rather than a
# laundering step: a file the incoming tree does not ship must not RIDE THROUGH
# it. Copying over matching names converges every file the tree has and says
# nothing about one it does not, so before this an added ~/duty/bin/hotfix.sh
# was refused, then survived --force, then got hashed into the new record — the
# box read `current` with unshipped executable code in it, certified by the
# instrument built to catch exactly that.
printf '#!/bin/sh\necho hotfix\n' >"$MDUTY/bin/hotfix.sh"
chmod +x "$MDUTY/bin/hotfix.sh"
added_before="$(cat "$MDUTY/bin/hotfix.sh")"
t install-added-file-reads-modified modified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-refuses-added-file 1 "$r1"
if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-added-file-rc 0 "$r1"
if [ -e "$MDUTY/bin/hotfix.sh" ]; then r1=SURVIVED; else r1=gone; fi
t install-force-removes-the-added-file gone "$r1"
# Moved, not deleted: the hotfix nobody told the fleet about is evidence.
t install-force-parks-it-in-legacy "$added_before" "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$force_out" in
  *"moved unshipped engine file to legacy/: bin/hotfix.sh"*) r1=named ;;
  *) r1=SILENT ;;
esac
t install-force-names-what-it-moved named "$r1"
case "$(cat "$MDUTY/.engine-manifest")" in *hotfix*) r1=BLESSED ;; *) r1=absent ;; esac
t install-force-does-not-record-the-added-file absent "$r1"
t install-force-over-added-file-is-current current "$(mstate)"
# ...and the engine that was installed around it is intact.
if [ -x "$MDUTY/bin/duty.sh" ]; then r1=installed; else r1=MISSING; fi
t install-force-sweep-leaves-the-engine installed "$r1"

# The sweep enumerates the same surface the manifest does, or the hole above
# reopens in the installer: `find -type f` walks past a symlink, so an added
# LINK was refused, survived --force, and was then recorded as shipped. This
# also lands on the plain legacy/ name the added FILE above already took, so it
# is the collision case too: the first park must survive, because parking
# instead of deleting is an evidence argument and evidence the next run
# silently replaces is not evidence.
ln -s /bin/sh "$MDUTY/bin/hotfix.sh"
t install-added-symlink-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-added-symlink 1 "$r1"
case "$refuse_out" in *"added bin/hotfix.sh"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-symlink named "$r1"
if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-added-symlink-rc 0 "$r1"
if [ -e "$MDUTY/bin/hotfix.sh" ] || [ -L "$MDUTY/bin/hotfix.sh" ]; then r1=SURVIVED; else r1=gone; fi
t install-force-removes-the-added-symlink gone "$r1"
case "$(cat "$MDUTY/.engine-manifest")" in *hotfix*) r1=BLESSED ;; *) r1=absent ;; esac
t install-force-does-not-record-the-added-symlink absent "$r1"
t install-force-over-added-symlink-is-current current "$(mstate)"
# Parked as the link it was — not as a copy of whatever it pointed at.
parked_link=""
for p in "$MDUTY"/legacy/bin/hotfix.sh.*; do
  [ -e "$p" ] || [ -L "$p" ] || continue
  parked_link="${p##*/}"; break
done
if [ -L "$MDUTY/legacy/bin/$parked_link" ]; then r1='link'; else r1=NOT-A-LINK; fi
t install-force-parks-the-symlink-as-a-link link "$r1"
t install-force-parks-the-symlink-target /bin/sh \
  "$(readlink "$MDUTY/legacy/bin/$parked_link" 2>/dev/null)"
t install-second-park-keeps-the-first "$added_before" \
  "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$force_out" in *"kept as bin/$parked_link"*) r1=named ;; *) r1=SILENT ;; esac
t install-collided-park-names-where-it-went named "$r1"

# The same hole one component UP, and the reason the sweep alone cannot close
# it: the sweep descends a symlinked root but never sweeps the root entry, so an
# operator's `ln -s elsewhere ~/duty/bin` was detected, refused — and then
# survived --force, was written into the record, and the box read `current` with
# its engine executing out of a directory this version never shipped. Detection
# already names the redirect, so blessing it is worse than never having looked.
REDIR="$TMP/manifest-redirect-target"
mkdir -p "$REDIR"
mv "$MDUTY/bin" "$REDIR/bin"
ln -s "$REDIR/bin" "$MDUTY/bin"
t install-redirected-root-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-redirected-root 1 "$r1"
case "$refuse_out" in *"added bin"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-redirected-root named "$r1"
# ...and the refusal changed nothing: the redirect is still exactly as it was.
if [ -L "$MDUTY/bin" ]; then r1=intact; else r1=DISTURBED; fi
t install-refusal-leaves-the-redirect-alone intact "$r1"

if force_out="$(minstall --force 2>&1)"; then r1=0; else r1=$?; fi
t install-force-over-redirected-root-rc 0 "$r1"
# The convergence: a real directory where the link was, not a link crew ships.
if [ -d "$MDUTY/bin" ] && [ ! -L "$MDUTY/bin" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-redirect-with-a-real-dir real "$r1"
# Moved, not deleted — and parked as a LINK, so the target it pointed at is the
# evidence, sitting outside the engine surface.
redir_park=""
for p in "$MDUTY"/legacy/bin "$MDUTY"/legacy/bin.*; do
  if [ -L "$p" ]; then redir_park="$p"; break; fi
done
if [ -n "$redir_park" ]; then r1='link'; else r1=NOT-PARKED-AS-LINK; fi
t install-force-parks-the-redirect-as-a-link link "$r1"
t install-force-parks-the-redirect-target "$REDIR/bin" \
  "$(readlink "$redir_park" 2>/dev/null)"
case "$force_out" in
  *"replaced redirected engine directory with a real one: bin"*) r1=named ;;
  *) r1=SILENT ;;
esac
t install-force-names-the-redirect-it-replaced named "$r1"
# The record must not carry the redirect: `bin` as an entry is the blessing.
case "$(sed -n 's/.*  \(bin\)$/\1/p' "$MDUTY/.engine-manifest")" in
  bin) r1=BLESSED ;; *) r1=absent ;;
esac
t install-force-does-not-record-the-redirect absent "$r1"
t install-force-over-redirected-root-is-current current "$(mstate)"
if [ -x "$MDUTY/bin/duty.sh" ]; then r1=installed; else r1=MISSING; fi
t install-force-through-redirect-leaves-the-engine installed "$r1"
# The park above collided by construction: the added-file fixtures further up
# already left legacy/bin as a DIRECTORY holding hotfix.sh, so parking a link
# called `bin` had to take the timestamped name instead of replacing it. Evidence
# the next run overwrites is not evidence, and a redirect park is no exception.
t install-redirect-park-keeps-the-earlier-evidence "$added_before" \
  "$(cat "$MDUTY/legacy/bin/hotfix.sh" 2>/dev/null)"
case "$redir_park" in
  *"/legacy/bin."*) r1=timestamped ;; *) r1=CLOBBERED-THE-DIRECTORY ;;
esac
t install-redirect-park-takes-a-free-name timestamped "$r1"

# One level FURTHER up, where it was not even detected: conf/ carries
# conf/roles, conf/agents and conf/fleet.defaults.conf without being a manifest
# root itself, so a redirect there resolved, hashed clean, and never refused —
# the whole role and agent set read from wherever an operator pointed it while
# the instrument said `current`.
#
# This is also why the contents are copied back through the link rather than the
# root simply emptied: OPERATOR_CONF falls back to the shipped example only when
# the box has no conf/fleet.conf of its own, so a normalization that dropped the
# redirect's contents would destroy a transported one.
printf 'FLEET_KEEPME=1\n' >>"$MDUTY/conf/fleet.conf"
minstall --force >/dev/null 2>&1   # re-record with the marker in place
mv "$MDUTY/conf" "$REDIR/conf"
ln -s "$REDIR/conf" "$MDUTY/conf"
t install-redirected-ancestor-reads-modified modified "$(mstate)"
if refuse_out="$(minstall 2>&1)"; then r1=0; else r1=$?; fi
t install-refuses-redirected-ancestor 1 "$r1"
case "$refuse_out" in *"added conf"*) r1=named ;; *) r1=UNNAMED ;; esac
t install-refusal-names-the-redirected-ancestor named "$r1"
minstall --force >/dev/null 2>&1
if [ -d "$MDUTY/conf" ] && [ ! -L "$MDUTY/conf" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-redirected-ancestor real "$r1"
# The per-box configuration behind the redirect came back with it.
case "$(cat "$MDUTY/conf/fleet.conf" 2>/dev/null)" in
  *FLEET_KEEPME*) r1=kept ;; *) r1=LOST ;;
esac
t install-redirect-normalization-keeps-the-operator-fleet-conf kept "$r1"
if [ -f "$MDUTY/conf/instance.conf" ]; then r1=present; else r1=MISSING; fi
t install-redirect-normalization-keeps-instance-conf present "$r1"
t install-force-over-redirected-ancestor-is-current current "$(mstate)"

# A DANGLING root redirect must not take the install down with it: there is no
# content to restore, so the right answer is an empty real directory the install
# then fills, not a crash under `set -e`.
rm -rf "$MDUTY/prompts"
ln -s "$TMP/manifest-redirect-nowhere" "$MDUTY/prompts"
t install-dangling-root-redirect-reads-modified modified "$(mstate)"
if minstall --force >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-force-over-dangling-root-redirect-rc 0 "$r1"
if [ -d "$MDUTY/prompts" ] && [ ! -L "$MDUTY/prompts" ]; then r1=real; else r1=STILL-A-LINK; fi
t install-force-replaces-the-dangling-redirect real "$r1"
if [ -n "$(ls -A "$MDUTY/prompts" 2>/dev/null)" ]; then r1=filled; else r1=EMPTY; fi
t install-force-refills-the-dangling-redirect filled "$r1"
t install-force-over-dangling-redirect-is-current current "$(mstate)"

# A converging re-install sweeps NOTHING. Every install parking files in
# legacy/ would make the mechanism noise, and noise is how the one real one
# gets missed.
legacy_before="$(cd "$MDUTY/legacy" && find . -type f | LC_ALL=C sort)"
reship_out="$(minstall 2>&1)"
t install-clean-reship-sweeps-nothing "$legacy_before" \
  "$(cd "$MDUTY/legacy" && find . -type f | LC_ALL=C sort)"
case "$reship_out" in *"moved unshipped engine file"*) r1=NOISY ;; *) r1=quiet ;; esac
t install-clean-reship-is-quiet quiet "$r1"

# The migration: a box hired before content stamping has no record. It must
# read unverified, must NOT be refused, and one install must cure it.
rm -f "$MDUTY/.engine-manifest"
t install-pre-existing-box-is-unverified unverified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-pre-existing-box-is-not-refused 0 "$r1"
t install-pre-existing-box-is-cured current "$(mstate)"

# The obsolete half, on the box where it actually happens: an `unverified` box
# is deliberately NOT refused, so nothing else would ever notice the module it
# has been carrying since two versions ago. The install that cures it sweeps it
# — at depth, and without --force — instead of recording it as shipped.
rm -f "$MDUTY/.engine-manifest"
printf 'dead\n' >"$MDUTY/lib/jq/obsolete.jq"
t install-obsolete-file-box-is-unverified unverified "$(mstate)"
if minstall >/dev/null 2>&1; then r1=0; else r1=$?; fi
t install-unforced-sweep-rc 0 "$r1"
if [ -e "$MDUTY/lib/jq/obsolete.jq" ]; then r1=SURVIVED; else r1=gone; fi
t install-unforced-sweeps-the-obsolete-file gone "$r1"
t install-unforced-sweep-parks-it dead "$(cat "$MDUTY/legacy/lib/jq/obsolete.jq" 2>/dev/null)"
case "$(cat "$MDUTY/.engine-manifest")" in *obsolete*) r1=BLESSED ;; *) r1=absent ;; esac
t install-unforced-sweep-does-not-record-it absent "$r1"
t install-unforced-sweep-is-current current "$(mstate)"


suite_finish
