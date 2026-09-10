#!/usr/bin/env bash
# shared/test/common/identity.sh — standalone suite for shared/lib/common/identity.sh.
#
# One suite per module at the mirrored relative path: this file covers that one
# and nothing else. The invariant is the layout, not this file (#507).
set -uo pipefail

# ../ : lib.sh lives beside the subject suites, one level up from the module
# tree, and derives HERE from itself so both depths resolve the same paths.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
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
# duty.sh is read by the wiring assertions below.
DUTYSH="$SHARED/bin/duty.sh"

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

# --- gh_identity's stdout is the login and nothing else (#708) --------------
# `ME="$(gh_identity)"` is a command substitution, so whatever the function
# writes to stdout BECOMES the box's own login. Both recorders it calls
# announce themselves through log()/warn(), which write there — so on the
# FIRST failing tick $ME was the WARN line itself: non-empty, duty.sh's
# `cannot resolve own login` branch skipped, and converge_git_identity handed
# a log line as its wanted login. Tick two behaved as documented because
# note_auth_failure returns early, which is exactly why the defect survived to
# a drill rather than to a fixture (drills/0.1.2.md finding 1).
#
# The two streams are read the way tick.sh separates them — stdout is the
# value, stderr is what `2>&1` puts in duty.log — and BOTH halves come off one
# call. Asserting only that $ME is empty would green a fix that deleted the
# WARN, which is the same box going quiet by another route.
GHID="$TMP/ghid"; mkdir -p "$GHID"
DUTY_DIR="$GHID"
GHID_ALERTS="$GHID/alerts"; : >"$GHID_ALERTS"
alert() { printf '%s\n' "$*" >>"$GHID_ALERTS"; }
# shellcheck disable=SC2317  # invoked indirectly, by gh_identity
gh() { printf '%s\n' 'gh: HTTP 401: Bad credentials' >&2; return 4; }

GHID_LOG1="$GHID/tick1.log"
r1="$(gh_identity 2>"$GHID_LOG1")"
t ghid-failed-credential-yields-no-login "" "$r1"
case "$(cat "$GHID_LOG1")" in *'auth: gh rejected us'*) r1=warned ;; *) r1=SILENT ;; esac
t ghid-failure-warn-reaches-the-log warned "$r1"
case "$(cat "$GHID_LOG1")" in *'401'*'Bad credentials'*) r1=carried ;; *) r1=LOST ;; esac
t ghid-failure-warn-carries-the-api-reason carried "$r1"
t ghid-failure-writes-the-marker present \
  "$([ -s "$GHID/.auth-fail.gh" ] && echo present || echo MISSING)"
t ghid-failure-marker-is-one-line 1 "$(wc -l <"$GHID/.auth-fail.gh")"
t ghid-failure-alerts-once 1 "$(grep -c '^🔑 ' "$GHID_ALERTS")"

# The SECOND failing tick, with the marker already present. note_auth_failure
# returns early there, so this is the branch that behaved correctly all along
# — and the one that must not start returning a login now that the recorder
# has moved. `$ME` is empty whenever `gh api user` fails, on every tick.
GHID_LOG2="$GHID/tick2.log"
FIRST="$(cat "$GHID/.auth-fail.gh")"
r1="$(gh_identity 2>"$GHID_LOG2")"
t ghid-second-failing-tick-yields-no-login "" "$r1"
t ghid-second-failing-tick-is-silent "" "$(cat "$GHID_LOG2")"
t ghid-second-failing-tick-keeps-the-first-record "$FIRST" "$(cat "$GHID/.auth-fail.gh")"
t ghid-second-failing-tick-does-not-realert 1 "$(grep -c '^🔑 ' "$GHID_ALERTS")"

# A successful call that returns an EMPTY login is a failure too — the `-z`
# arm of the same branch, reached when the credential answers but names
# nobody. It must not hand the tick an empty-but-announced identity either.
rm -f "$GHID/.auth-fail.gh"
# shellcheck disable=SC2317
gh() { printf '\n'; }
GHID_LOG3="$GHID/tick3.log"
r1="$(gh_identity 2>"$GHID_LOG3")"
t ghid-empty-login-yields-no-login "" "$r1"
case "$(cat "$GHID_LOG3")" in *'auth: gh rejected us'*) r1=warned ;; *) r1=SILENT ;; esac
t ghid-empty-login-warn-reaches-the-log warned "$r1"

# The RESTORE path is the same defect on the tick a credential comes back:
# clear_auth_failure's line was captured into $ME too, and a $ME carrying it
# made converge_git_identity refuse as a rotation — the recovering tick
# spending no session, with the restore line never reaching the log.
# shellcheck disable=SC2317
gh() { printf '%s\n' cndgrr; }
GHID_LOG4="$GHID/tick4.log"
r1="$(gh_identity 2>"$GHID_LOG4")"
t ghid-restored-credential-yields-only-the-login cndgrr "$r1"
case "$(cat "$GHID_LOG4")" in *'auth: gh is working again'*) r1=logged ;; *) r1=SILENT ;; esac
t ghid-restore-line-reaches-the-log logged "$r1"
t ghid-restore-clears-the-marker absent \
  "$([ -f "$GHID/.auth-fail.gh" ] && echo PRESENT || echo absent)"
t ghid-restore-alerts-once 1 "$(grep -c '^✅ ' "$GHID_ALERTS")"

# The steady state — working credential, no marker — writes nothing at all.
GHID_LOG5="$GHID/tick5.log"
r1="$(gh_identity 2>"$GHID_LOG5")"
t ghid-steady-state-yields-only-the-login cndgrr "$r1"
t ghid-steady-state-is-silent "" "$(cat "$GHID_LOG5")"

# The INVARIANT, not the two calls that hold it today. Every fixture above
# exercises the recorders that exist now; a call added inside this function
# tomorrow would pass all of them and reintroduce #708 exactly, because the
# capture is a property of the call site and not of who is speaking.
r1="$(awk '
  /^gh_identity\(\) \{/ { inside = 1; next }
  inside && /^\}/ { exit }
  /^[[:space:]]*#/ { next }
  inside && /(^|[[:space:];&|(])(note_auth_failure|clear_auth_failure|log|warn|alert)[[:space:]]/ && !/>&2/ {
    print "WRITES-TO-STDOUT:" $0; exit
  }
' "$SHARED/lib/common/identity.sh")"
r1="${r1:-clean}"
t ghid-nothing-in-gh-identity-writes-to-stdout clean "$r1"

# --- the first tick, driven through duty.sh's own source (#708 D2) ----------
# Static greps cannot see this one: the bug is what a value CONTAINS at run
# time, and every line of duty.sh involved is spelled correctly. So the real
# block runs — from `ME="$(gh_identity)"` through the refusal — under a dead
# credential, with stdout and stderr joined into one file exactly as tick.sh
# joins them into duty.log.
#
# GIT_CONFIG_GLOBAL is scratch for the same reason the section below sets it:
# on the pre-fix path this block reaches converge_git_identity, and a fixture
# must not read (or, on some future path, write) the identity of whoever ran
# the suite.
FIRSTTICK_DIR="$TMP/first-tick"; mkdir -p "$FIRSTTICK_DIR"
FIRSTTICK="$TMP/first-tick.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
  # shellcheck disable=SC2016  # writing literal fixture source
  printf '%s\n' 'source "$SHARED/lib/common.sh"'
  printf '%s\n' 'alert() { :; }' 'hostname() { printf fixture; }'
  # shellcheck disable=SC2016  # writing literal fixture source
  printf '%s\n' 'gh() { printf "%s\n" "gh: HTTP 401: Bad credentials" >&2; return 4; }'
  printf '%s\n' 'boot_id=fixture-boot'
  awk '
    /^ME="\$\(gh_identity\)"$/ { keep=1 }
    keep && /^# shellcheck source=\.\.\/lib\/duty-attention\.sh/ { exit }
    keep { print }
  ' "$DUTYSH"
} >"$FIRSTTICK"
t firsttick-fixture-carries-the-real-block called \
  "$(grep -Fq 'converge_git_identity "$ME"' "$FIRSTTICK" && echo called || echo MISSING)"
FIRSTTICK_LOG="$TMP/first-tick.log"
DUTY_DIR="$FIRSTTICK_DIR" SHARED="$SHARED" GIT_CONFIG_GLOBAL="$TMP/gitconfig-708" \
  bash "$FIRSTTICK" >"$FIRSTTICK_LOG" 2>&1
t firsttick-ends-the-tick-cleanly 0 "$?"
case "$(cat "$FIRSTTICK_LOG")" in
  *'cannot resolve own login (gh auth dead?) — nothing to do this tick'*) r1=logged ;;
  *) r1=MISSING ;;
esac
t firsttick-logs-the-documented-login-warn logged "$r1"
case "$(cat "$FIRSTTICK_LOG")" in *'auth: gh rejected us'*) r1=logged ;; *) r1=MISSING ;; esac
t firsttick-logs-the-credential-rejection logged "$r1"
# The credential branch is the one that fires. A git-identity WARN here means
# $ME was non-empty and the tick went on to converge against it — the defect,
# stated as the line it leaves behind.
t firsttick-does-not-blame-git-identity 0 \
  "$(grep -c 'GitHub credential used by gh api user failed' "$FIRSTTICK_LOG" || true)"
t firsttick-writes-the-auth-marker present \
  "$([ -s "$FIRSTTICK_DIR/.auth-fail.gh" ] && echo present || echo MISSING)"
t firsttick-marker-is-one-line 1 "$(wc -l <"$FIRSTTICK_DIR/.auth-fail.gh")"

unset -f gh
alert() { :; }
DUTY_DIR="$AUTHDIR"

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
#
# Read over the whole module tree, not the entry point. common.sh is 45 lines
# of `source` since #507, so a grep pinned there passes whatever the modules
# say — a guard that cannot fail, which is worse than no guard.
if grep -rq 'record_token_expiry\|token-expiry' "$SHARED/lib/common.sh" "$SHARED/lib/common/"; then r1=TRACKED; else r1=clean; fi
t no-expiry-date-tracked clean "$r1"

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
gh() { echo "$*" >>"$GHLOG"; printf '%s\n' 'gh: HTTP 401: Bad credentials' >&2; return 1; }
: >"$GHLOG"
dead_warn="$TMP/dead-credential.warn"
converge_git_identity cndgrr >"$dead_warn" 2>/dev/null
t gitid-dead-credential-refuses 1 "$?"
t gitid-dead-credential-writes-nothing 'claude-bot-andresmgsl@users.noreply.github.com' \
  "$(git config --global user.email)"
t gitid-dead-credential-is-classified credential "$GIT_IDENTITY_FAILURE_KIND"
case "$GIT_IDENTITY_FAILURE_EVIDENCE" in *'401'*'Bad credentials'*) r1=carried ;; *) r1=LOST ;; esac
t gitid-dead-credential-carries-api-response carried "$r1"
t gitid-dead-credential-spends-one-gh-call 1 "$(wc -l <"$GHLOG")"
r1="$(git_identity_failure_message)"
case "$r1" in *'GitHub credential used by gh api user failed'*'401'*'Bad credentials'*) r1=credential ;; *) r1=WRONG ;; esac
t gitid-dead-credential-message-names-credential credential "$r1"
case "$(git_identity_failure_message)" in *'git identity'*) r1=CONFUSED ;; *) r1=separate ;; esac
t gitid-dead-credential-message-does-not-blame-git separate "$r1"
case "$(cat "$dead_warn")" in *'GitHub credential used by gh api user failed'*'401'*'Bad credentials'*) r1=warned ;; *) r1=SILENT ;; esac
t gitid-dead-credential-helper-warns-reason warned "$r1"

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
t gitid-rotation-is-an-identity-failure identity "$GIT_IDENTITY_FAILURE_KIND"
t gitid-rotation-carries-observed-login andriujoseba "$GIT_IDENTITY_FAILURE_LOGIN"
r1="$(git_identity_failure_message)"
case "$r1" in *"git identity 'claude-bot-andresmgsl@users.noreply.github.com'"*"GitHub login 'andriujoseba'"*) r1=named ;; *) r1=WRONG ;; esac
t gitid-mismatch-message-names-both-identities named "$r1"
case "$(git_identity_failure_message)" in *cndgrr*) r1='BOX_LOGIN_LEAKED' ;; *) r1='observed-only' ;; esac
t gitid-mismatch-message-does-not-name-box-login observed-only "$r1"
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
t gitid-incomplete-response-is-not-git-identity api-response "$GIT_IDENTITY_FAILURE_KIND"
case "$(git_identity_failure_message)" in *'git identity '*) r1=CONFUSED ;; *'GitHub identity response'*) r1=response ;; *) r1=WRONG ;; esac
t gitid-incomplete-response-message-names-response response "$r1"

# Drive duty.sh's real refusal block twice. gh_identity has already accepted
# the credential at this point in a tick, so clear_auth_failure models that
# successful first call before converge_git_identity receives an incomplete
# login/id pair from its second call. That state is an identity-response
# failure, not rejected authentication: it must use the once-per-boot identity
# alert without creating an auth marker or flapping restored/failed alerts on
# the next tick. Extracting the production block keeps the regression pinned
# to its actual case routing rather than a test-side copy of it.
IDENTITY_TICK_DIR="$TMP/incomplete-response-ticks"
IDENTITY_TICK="$TMP/incomplete-response-tick.sh"
IDENTITY_ALERTS="$IDENTITY_TICK_DIR/alerts"
mkdir -p "$IDENTITY_TICK_DIR"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail'
  # shellcheck disable=SC2016  # writing literal fixture source
  printf '%s\n' 'source "$SHARED/lib/common.sh"'
  # shellcheck disable=SC2016  # writing literal fixture source
  printf '%s\n' 'alert() { printf "%s\n" "$*" >>"$IDENTITY_ALERTS"; }'
  printf '%s\n' 'warn() { :; }' 'log() { :; }' 'hostname() { printf fixture; }'
  printf '%s\n' 'converge_git_identity() {'
  printf '%s\n' '  GIT_IDENTITY_FAILURE_KIND=api-response'
  printf '%s\n' '  GIT_IDENTITY_FAILURE_EVIDENCE="gh api user returned an incomplete login/id response"'
  printf '%s\n' '  GIT_IDENTITY_FAILURE_LOGIN=cndgrr'
  printf '%s\n' '  return 1' '}'
  printf '%s\n' 'git_identity_failure_message() { printf "GitHub identity response from gh api user failed"; }'
  printf '%s\n' 'ME=cndgrr' 'boot_id=fixture-boot' 'clear_auth_failure gh'
  awk '
    /^if ! converge_git_identity "\$ME"; then$/ { keep=1 }
    keep && /^# shellcheck source=\.\.\/lib\/duty-attention\.sh/ { exit }
    keep { print }
  ' "$DUTYSH"
} >"$IDENTITY_TICK"
for _tick in 1 2; do
  DUTY_DIR="$IDENTITY_TICK_DIR" SHARED="$SHARED" IDENTITY_ALERTS="$IDENTITY_ALERTS" \
    bash "$IDENTITY_TICK"
done
t gitid-incomplete-response-alerts-once-per-boot 1 \
  "$(grep -c '^🪪 ' "$IDENTITY_ALERTS")"
t gitid-incomplete-response-does-not-use-auth-alerts 0 \
  "$(grep -Ec '^🔑 |^✅ ' "$IDENTITY_ALERTS" || true)"
t gitid-incomplete-response-does-not-write-auth-marker absent \
  "$([ -f "$IDENTITY_TICK_DIR/.auth-fail.gh" ] && echo PRESENT || echo absent)"
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

# The caller uses the classification produced by the SAME failed API call;
# it neither guesses from the box login nor pays for another auth probe.
# shellcheck disable=SC2016  # matching literal duty.sh source text
if awk_range_grep_Fq '/converge_git_identity "\$ME"/,/^fi$/' "$DUTYSH" \
  'git_identity_failure_message'; then r1=carried; else r1=LOST; fi
t gitid-duty-carries-failure-evidence carried "$r1"
# shellcheck disable=SC2016  # matching literal duty.sh source text
if awk_range_grep_q '/converge_git_identity "\$ME"/,/^fi$/' "$DUTYSH" \
  'gh api\|gh auth'; then r1=PROBED; else r1=clean; fi
t gitid-duty-failure-path-adds-no-network-call clean "$r1"

# install.sh writes it through the ENGINE, not a private copy of the rule. A
# second implementation of "which login is this box" is how the panel copy
# (#285) and the git copy (#294) both happened.
if grep -Fq 'converge_git_identity' "$SHARED/install.sh"; then r1=derived; else r1=MISSING; fi
t gitid-install-uses-the-shared-helper derived "$r1"

suite_finish
