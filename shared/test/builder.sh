#!/usr/bin/env bash
# shared/test/builder.sh — standalone builder subject suite.
# shellcheck disable=SC2100  # tick-N fixture identifiers are strings, not arithmetic
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
mkdir -p "$TMP/prompts"

H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PANEL='["rev-a","rev-b"]'
REVS_OK='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
CJQ="$SHARED/lib/jq/converged.jq"
CJ_HUMAN="danmt"
CJ_NO_SIG='{"sha":"","createdAt":""}'
mk_pr() {  # head mergeable labels requests reviews
  jq -n --arg head "$1" --arg m "$2" --argjson labels "$3" --argjson reqs "$4" --argjson revs "$5" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head, mergeable:$m,
      labels:{nodes:($labels|map({name:.}))},
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$revs}}}}}'
}
cj() {  # cj [signal-json] [panel-json] [human]
  jq -r --argjson panel "${2:-$PANEL}" --arg needs_human state:needs-human \
    --arg human "${3-$CJ_HUMAN}" --argjson signal "${1:-$CJ_NO_SIG}" -f "$CJQ"
}

# --- #133: engine (re-)requests the panel, keyed off the session's SIGNAL -----
# request-panel.jq answers "whom, given the engine already holds the licence";
# answered-head.jq is that licence — the head the session last signalled, and
# (since #286) WHEN it signalled — and the engine acts only when that head
# equals the current one, never on commit activity (#133's hardest must-fail).
RPJQ="$SHARED/lib/jq/request-panel.jq"
AHJQ="$SHARED/lib/jq/answered-head.jq"
RP_OLD="dddddddddddddddddddddddddddddddddddddddd"
RP_MARK="📣 round answered at head"
# The fixture CLOCK (#286). Ordering is the whole subject now, so every fixture
# states its times against these three, taken from the #281 transcript: the
# signal that OPENED round 1, the verdict that CLOSED it, and a later signal that
# would answer that verdict. T_SIG_OPEN < T_VERDICT < T_SIG_ANSWER.
RP_T_SIG_OPEN="2026-08-02T10:08:12Z"
RP_T_VERDICT="2026-08-02T10:32:33Z"
RP_T_SIG_ANSWER="2026-08-02T11:12:27Z"
# payload builder carrying comments (the signal lives there), reviewRequests and
# latestOpinionatedReviews. Reuses H from the converged block.
#
# Timestamps are DEFAULTED, not forced: a review node with no submittedAt gets
# RP_T_VERDICT and a comment with no createdAt gets RP_T_SIG_ANSWER, so a
# fixture that says nothing about time describes the ordinary case — the builder
# signalled after reading the verdict. A fixture that cares states its own, and
# one that means "the API returned no time here" says so with an explicit null,
# which `has` preserves. Before #286 the nodes carried no times at all, and that
# is precisely why no test could fail on this bug.
mk_rp() {  # <head> <reqs-json> <revs-json> <comments-json>
  jq -n --arg head "$1" --argjson reqs "$2" --argjson revs "$3" --argjson coms "$4" \
    --arg rev_at "$RP_T_VERDICT" --arg com_at "$RP_T_SIG_ANSWER" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head,
      reviewRequests:{nodes:($reqs|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:($revs|map(
        if has("submittedAt") then . else . + {submittedAt:$rev_at} end))},
      comments:{nodes:($coms|map(
        if has("createdAt") then . else . + {createdAt:$com_at} end))}}}}}'
}
# The signal request-panel.jq is handed. Shaped exactly like answered-head.jq's
# output, because in the engine it IS that output — the two are wired together
# in _request_panel and nowhere else.
sig() { jq -cn --arg sha "$1" --arg at "$2" '{sha:$sha,createdAt:$at}'; }
rp() {  # <signal-json> [panel-json]
  jq -r --argjson panel "${2:-$PANEL}" --argjson signal "$1" -f "$RPJQ" \
    | tr '\n' ' ' | sed 's/ $//'
}
ah() { jq -c --arg me me-bot --arg mark "$RP_MARK" -f "$AHJQ"; }
ah_sha() { ah | jq -r '.sha'; }
# The default signal: at the current head, later than the default verdict time.
# Fixtures with no current-head verdict are indifferent to it by construction.
RP_SIG_LATE="$(sig "$H" "$RP_T_SIG_ANSWER")"
RP_CR_AT_HEAD='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"'$H'"}}]'
RP_STALE_BOTH='[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"'$RP_OLD'"}},{"author":{"login":"rev-b"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$RP_OLD'"}}]'

# request-panel.jq — whom to request once licensed.
t rp-first-round-requests-all "rev-a rev-b" \
  "$(mk_rp "$H" '[]' '[]' '[]' | rp "$RP_SIG_LATE")"
# The no-push half #133 exists for: a change-request AT the current head is
# re-requested (the builder answered with argument), the head approver is not.
# RETIMED for #286, not preserved: this case was written with no comments at
# all, so its signal could never be newer than the verdict it claimed to answer,
# and it expected rev-a anyway. It is now the boundary PAIR below — the same
# reviews read twice, once under a signal newer than the verdict and once under
# the signal that opened the round. Leaving it as it stood and still passing
# would mean the predicate is not reading the ordering.
t rp-no-push-cr-at-head-requests-cr-er "rev-a" \
  "$(mk_rp "$H" '[]' "$RP_CR_AT_HEAD" '[]' | rp "$(sig "$H" "$RP_T_SIG_ANSWER")")"
t rp-no-push-stale-signal-requests-none "" \
  "$(mk_rp "$H" '[]' "$RP_CR_AT_HEAD" '[]' | rp "$(sig "$H" "$RP_T_SIG_OPEN")")"
t rp-converged-requests-none "" \
  "$(mk_rp "$H" '[]' "$REVS_OK" '[]' | rp "$RP_SIG_LATE")"
# Head moved: every prior review is stale → all re-requested, approvers included.
t rp-head-moved-requests-all "rev-a rev-b" \
  "$(mk_rp "$H" '[]' "$RP_STALE_BOTH" '[]' | rp "$RP_SIG_LATE")"
t rp-already-requested-none "" \
  "$(mk_rp "$H" '["rev-a","rev-b"]' "$RP_STALE_BOTH" '[]' | rp "$RP_SIG_LATE")"
# Never triage: the request derives only from $panel, so an off-panel identity
# (dan-claude-bot) that left a review or a request cannot be returned.
RP_TRIAGE_REV='[{"author":{"login":"dan-claude-bot"},"state":"CHANGES_REQUESTED","commit":{"oid":"'$RP_OLD'"}}]'
t rp-never-targets-triage "rev-a rev-b" \
  "$(mk_rp "$H" '["dan-claude-bot"]' "$RP_TRIAGE_REV" '[]' | rp "$RP_SIG_LATE")"

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

# --- Live-round deferral (per-tick, $final=false): the regression codex found
# on the mirror-every-tick change. Because the mirror now runs every tick, a
# round's FIRST verdict would otherwise stamp `<!-- round:<head> -->` with "no
# written reply" while the round is still live — and the already-recorded skip
# then locks the real reply out forever. Per-tick records only SUPERSEDED
# rounds; the live last round is deferred to a later tick or to the handoff.

# Tick 1: the live round has one verdict and no reply yet → deferred → nothing
# written. Crucially, NO `<!-- round:O1 -->` marker to lock the reply out.
RL_LIVE1="$(mk_rl "Body." "$RL_REVS1" '[]' | rl_live)"
t roundlog-live-round-no-premature-marker "" "$RL_LIVE1"

# Same live round, now WITH the whole-round reply, still the last round →
# still deferred per-tick (no next round has closed its window yet).
RL_ONECOM='[{"author":{"login":"me-bot"},"body":"the whole-round reply","createdAt":"2026-01-01T02:00:00Z"}]'
RL_LIVE2="$(mk_rl "Body." "$RL_REVS1" "$RL_ONECOM" | rl_live)"
t roundlog-live-round-with-reply-still-deferred "" "$RL_LIVE2"

# Once a NEWER round supersedes it (a verdict on O2), the closed round O1 is
# recorded per-tick WITH its real reply — not "no written reply" — while the
# new live round O2 stays deferred. Proves the reply is never lost, only timed.
RL_SUP="$(mk_rl "Body." "$RL_REVS" "$RL_COMS" | rl_live)"
case "$RL_SUP" in *"round:$RL_O1"*) r1=yes ;; *) r1=no ;; esac
t roundlog-superseded-round-recorded-per-tick yes "$r1"
case "$RL_SUP" in *"answering round one"*) r1=real ;; *) r1=no ;; esac
t roundlog-superseded-round-keeps-real-reply real "$r1"
case "$RL_SUP" in *"round:$RL_O2"*) r1=LEAKED ;; *) r1=deferred ;; esac
t roundlog-live-round-deferred-when-superseded deferred "$r1"
case "$RL_SUP" in *"no written reply"*) r1=PREMATURE ;; *) r1=clean ;; esac
t roundlog-superseded-no-premature-noreply clean "$r1"

# The sequential two-tick regression codex reproduced: after tick 1 defers the
# live round (writing NO marker, above), the round completes and the builder
# replies; the handoff straggler ($final=true) then records the REAL reply —
# not the premature "no written reply" the old code locked in.
RL_HANDOFF="$(mk_rl "Body." "$RL_REVS1" "$RL_ONECOM" | rl)"
case "$RL_HANDOFF" in *"the whole-round reply"*) r1=real ;; *) r1=no ;; esac
t roundlog-handoff-finalizes-real-reply real "$r1"
case "$RL_HANDOFF" in *"no written reply"*) r1=PREMATURE ;; *) r1=clean ;; esac
t roundlog-handoff-not-premature-noreply clean "$r1"

# The terminal no-comment case survives the deferral: a round that genuinely
# passed with no reply is still recorded at handoff ($final=true).
RL_TERM="$(mk_rl "Body." "$RL_REVS1" '[]' | rl)"
case "$RL_TERM" in *"_Round passed with no written reply._"*) r1=yes ;; *) r1=no ;; esac
t roundlog-terminal-no-comment-at-handoff yes "$r1"

# #249: GitHub can re-point an existing verdict to a base-merge commit made
# after the verdict. Repair only that impossible key to the newest commit that
# existed when the verdict was submitted.
RL_OLD="6bb9f61000000000000000000000000000000000"
RL_HEAD="bfb1f3a4dc313b370981f75e0034d7c0ec720324"
RL_227_COMMITS="$(printf '[{"commit":{"oid":"%s","committedDate":"2026-01-01T13:39:23Z"}},{"commit":{"oid":"%s","committedDate":"2026-01-01T14:56:52Z"}}]' "$RL_OLD" "$RL_HEAD")"
RL_227_REVS="$(printf '[{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T14:46:20Z"},{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T14:48:02Z"},{"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T14:54:22Z"}]' "$RL_HEAD" "$RL_HEAD" "$RL_OLD")"
RL_227_FINAL="$(mk_rl "Body." "$RL_227_REVS" '[]' "$RL_227_COMMITS" "\"$RL_HEAD\"" | rl)"
case "$RL_227_FINAL" in *"round:$RL_OLD"*) r1=old ;; *) r1=WRONG ;; esac
t roundlog-repointed-verdicts-use-original-head old "$r1"
case "$RL_227_FINAL" in *"round:$RL_HEAD"*) r1=LEAKED ;; *) r1=one-round ;; esac
t roundlog-repointed-verdicts-form-one-round one-round "$r1"
RL_227_LIVE="$(mk_rl "Body." "$RL_227_REVS" '[]' "$RL_227_COMMITS" "\"$RL_HEAD\"" | rl_live)"
t roundlog-repointed-live-payload-stays-empty "" "$RL_227_LIVE"

# A possible reported key stays put even when a newer commit exists: this is
# not a blanket timestamp-based forward re-key.
RL_STALE_REVS="$(printf '[{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T16:00:00Z"}]' "$RL_OLD")"
RL_STALE="$(mk_rl "Body." "$RL_STALE_REVS" '[]' "$RL_227_COMMITS" null | rl)"
case "$RL_STALE" in *"round:$RL_OLD"*) r1=kept ;; *) r1=MOVED ;; esac
t roundlog-possible-stale-key-is-preserved kept "$r1"

# If the verdict predates every returned commit, retain and render its reported
# key: truncated or rewritten history is not evidence for a guessed repair.
RL_PRE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
RL_PRE_REVS="$(printf '[{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T12:00:00Z"}]' "$RL_PRE")"
RL_PRE_OUT="$(mk_rl "Body." "$RL_PRE_REVS" '[]' "$RL_227_COMMITS" null | rl)"
case "$RL_PRE_OUT" in *"round:$RL_PRE"*) r1=rendered ;; *) r1=DROPPED ;; esac
t roundlog-prehistory-verdict-keeps-reported-key rendered "$r1"

# The current-head guard is independent of sort position: defer a current head
# even when a later round exists, but finalize it at handoff.
RL_HEAD_FIRST_REVS="$(printf '[{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T01:00:00Z"},{"state":"APPROVED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T02:00:00Z"}]' "$RL_O1" "$RL_O2")"
RL_HEAD_FIRST_LIVE="$(mk_rl "Body." "$RL_HEAD_FIRST_REVS" '[]' '[]' "\"$RL_O1\"" | rl_live)"
case "$RL_HEAD_FIRST_LIVE" in *"round:$RL_O1"*) r1=LEAKED ;; *) r1=deferred ;; esac
t roundlog-current-head-deferred-out-of-sort-position deferred "$r1"
RL_HEAD_FIRST_FINAL="$(mk_rl "Body." "$RL_HEAD_FIRST_REVS" '[]' '[]' "\"$RL_O1\"" | rl)"
case "$RL_HEAD_FIRST_FINAL" in *"round:$RL_O1"*) r1=finalized ;; *) r1=MISSING ;; esac
t roundlog-current-head-finalized-at-handoff finalized "$r1"

# The live GraphQL query carries the repair inputs and stays at GitHub's
# connection ceiling.
if grep -q 'headRefOid' "$SHARED/lib/duty-builder.sh" \
  && grep -q 'commits(last:100){nodes{commit{oid committedDate}}}' "$SHARED/lib/duty-builder.sh"; then
  r1=present
else
  r1=MISSING
fi
t roundlog-query-carries-head-and-commits present "$r1"

# B1 (#91): mirroring must be wired into the per-tick `my_open` builder sweep,
# not only into `_handoff_finalize` — else the Round log fills only at
# convergence and a never-converging PR never mirrors. The sweep call is
# `_mirror_rounds "$R" "$N"` (the handoff call uses the function's own
# repo/num locals), so its presence pins the timing fix against a regression to
# handoff-only. shellcheck-disable: matching the literal call, not expanding it.
# shellcheck disable=SC2016
if grep -q '_mirror_rounds "\$R" "\$N"' "$SHARED/lib/duty-builder.sh"; then r1=per-tick; else r1=handoff-only; fi
t roundlog-mirrored-in-per-tick-sweep per-tick "$r1"

# --- _handoff_finalize under a gh shim: one comment, one request, one label,
# ZERO sessions/clones (#91). The stateful shim answers the two GraphQL reads
# (round-log payload and handoff-comment payload), records the REST writes, and
# a post-once.sh stub records the comment. run_session / ensure_main_clone are
# overridden to tripwire the log — if the handoff ever spends a session or a
# clone the test goes red. This is the issue's must-fail floor: the session/
# clone controls, and the label-not-gated-on-a-failing-request control below.
# post-once.sh lives at $DUTY_DIR/bin — common.sh derives BIN_DIR from DUTY_DIR
# at source time, so an env BIN_DIR would be clobbered; place the stub where the
# engine will look.
HFSHIM="$TMP/hf-shim"; HFDUTY="$TMP/hf-duty"
mkdir -p "$HFSHIM" "$HFDUTY/bin" "$HFDUTY/lib/jq"
cp "$SHARED/lib/jq/round-log.jq" "$HFDUTY/lib/jq/"
HF_CALLS="$TMP/hf-calls.log"
HFP_RL="$TMP/hf-rl-payload.json"; HFP_HC="$TMP/hf-hc-payload.json"
# Round-log payload: a body with no marker and one answered round → non-empty
# newbody → the body PATCH fires (exercises _mirror_rounds end to end).
printf '{"data":{"repository":{"pullRequest":{"body":"Body.","reviews":{"nodes":[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-01-01T01:00:00Z"}]},"comments":{"nodes":[{"author":{"login":"me-bot"},"body":"my round reply","createdAt":"2026-01-01T02:00:00Z"}]}}}}}' "$RL_O1" >"$HFP_RL"
# Handoff-comment payload: both panelists approve the current head.
printf '{"data":{"repository":{"pullRequest":{"headRefOid":"%s","latestOpinionatedReviews":{"nodes":[{"author":{"login":"rev-a"},"state":"APPROVED","commit":{"oid":"%s"}},{"author":{"login":"rev-b"},"state":"APPROVED","commit":{"oid":"%s"}}]}}}}}' "$RL_O2" "$RL_O2" "$RL_O2" >"$HFP_HC"
cat >"$HFSHIM/gh" <<'HFGH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  case "$*" in
    *latestOpinionatedReviews*) cat "$HF_HCPAYLOAD" ;;
    *) cat "$HF_RLPAYLOAD" ;;
  esac
  exit 0
fi
is_patch=0 is_reqrev=0 is_label=0
for a in "$@"; do
  [ "$a" = PATCH ] && is_patch=1
  [ "$a" = --add-label ] && is_label=1
  case "$a" in */requested_reviewers) is_reqrev=1 ;; esac
done
if [ "$is_patch" = 1 ]; then cat >/dev/null; printf 'PATCH\n' >>"$HF_CALLS"; exit 0; fi
if [ "$is_reqrev" = 1 ]; then printf 'REQUEST\n' >>"$HF_CALLS"; [ "${HF_REQ_FAIL:-0}" = 1 ] && exit 1; exit 0; fi
if [ "$is_label" = 1 ]; then printf 'LABEL\n' >>"$HF_CALLS"; exit 0; fi
exit 0
HFGH
cat >"$HFDUTY/bin/post-once.sh" <<'HFPO'
#!/usr/bin/env bash
printf 'COMMENT\n' >>"$HF_CALLS"
exit 0
HFPO
cat >"$TMP/hf-run.sh" <<'HFRUN'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/common.sh"
# shellcheck disable=SC1091
. "$SHARED_DIR/lib/duty-builder.sh"
run_session(){ printf 'SESSION\n' >>"$HF_CALLS"; }
ensure_main_clone(){ printf 'CLONE\n' >>"$HF_CALLS"; }
_handoff_finalize "$1" "$2"
HFRUN
chmod +x "$HFSHIM/gh" "$HFDUTY/bin/post-once.sh"
hf_run() {  # <req-fail 0|1>
  : >"$HF_CALLS"
  SHARED_DIR="$SHARED" HF_CALLS="$HF_CALLS" HF_RLPAYLOAD="$HFP_RL" HF_HCPAYLOAD="$HFP_HC" \
  HF_REQ_FAIL="$1" DUTY_DIR="$HFDUTY" ME=me-bot FLEET_HUMAN=the-human \
  LABEL_NEEDS_HUMAN=state:needs-human MARK_HANDOFF='🤝 handed off at head' \
  PATH="$HFSHIM:$PATH" bash "$TMP/hf-run.sh" the/repo 7 >/dev/null 2>&1
}
hfc() { grep -c "^$1\$" "$HF_CALLS"; }

hf_run 0
t handoff-posts-one-comment 1 "$(hfc COMMENT)"
t handoff-requests-human-once 1 "$(hfc REQUEST)"
t handoff-sets-label-once 1 "$(hfc LABEL)"
t handoff-writes-body-once 1 "$(hfc PATCH)"
t handoff-spends-no-session 0 "$(hfc SESSION)"
t handoff-spends-no-clone 0 "$(hfc CLONE)"

# The label is notify.sh's poll signal, so it must NOT be gated on a review
# request that can fail — a failed request with the label set still pings the
# human. Must-fail: gate the label on the request and this goes red.
hf_run 1
t handoff-request-attempted-on-fail 1 "$(hfc REQUEST)"
t handoff-label-set-even-if-request-fails 1 "$(hfc LABEL)"

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

# --- suppression state must be PER REPO (#60 review) ------------------------
# Both duty modules call report_suppressed inside a per-repo loop. With ONE
# shared state file, repo B's set replaces repo A's, and a repo with nothing
# suppressed rm -f's the file outright — so A's unchanged set looks new on the
# next tick and warns again, every tick, on exactly the 3-repo production box
# this was written to protect. codex-bot and grok-bot both caught it; grok-bot
# reproduced the flip-flop with these helpers.
sup_says() { if grep -q 'item(s)'; then echo warned; else echo silent; fi; }
SUP_A='o/a#1 2026-07-27T10:00:00Z'
SUP_B='o/b#1 2026-07-27T10:00:00Z'

# Per-repo files: each repo settles independently and stays quiet.
STA="$TMP/sup.o_a"; STB="$TMP/sup.o_b"
printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" >/dev/null
t report-perrepo-a-settles silent "$(printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" | sup_says)"
t report-perrepo-b-settles silent "$(printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" | sup_says)"

# The shape that was wrong, kept as a negative control: sharing one file makes
# A speak again after B has been through it. If this ever reads `silent` the
# helper has changed and the per-repo keying above may no longer be load-bearing.
SUP_SHARED="$TMP/sup.shared"
printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$SUP_SHARED" "o/b: board" >/dev/null
t report-shared-state-refires warned "$(printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" | sup_says)"

# ...and the modules must actually key by repo, not just be capable of it.
for pair in "duty-triage.sh:suppressed-triage-board" "duty-builder.sh:suppressed-build"; do
  mod="${pair%%:*}"; sfile="${pair##*:}"
  if grep -qE "$sfile\.\\\$\{?(R|slug)" "$SHARED/lib/$mod"; then r1=perrepo; else r1=SHARED; fi
  t "suppression-state-perrepo-$mod" perrepo "$r1"
done

# --- every state signal is ledgered (#59) -----------------------------------
# The engine had TWO ledgers, both in triage, while builder and reviewer had
# none — so any signal cleared by an in-session action the agent may DECLINE
# re-fired a model session every tick forever. These pin the wiring: a new
# signal site added without a ledger is the regression.
for pair in "duty-triage.sh:.seen-triage-board" "duty-builder.sh:.seen-build" \
            "duty-review.sh:.seen-review" "duty-attention.sh:.seen-attention"; do
  mod="${pair%%:*}"; led="${pair##*:}"
  if grep -q "$led" "$SHARED/lib/$mod"; then r1=ledgered; else r1=UNGUARDED; fi
  t "signal-ledgered-$mod" ledgered "$r1"
  # ...and committed only after a session that actually completed.
  if grep -q 'RUN_SESSION_RC:-1}" -eq 0' "$SHARED/lib/$mod"; then r1=gated; else r1=UNGATED; fi
  t "ledger-commit-gated-$mod" gated "$r1"
  # ...and what it hides must be reported.
  if grep -q 'report_suppressed' "$SHARED/lib/$mod"; then r1=reported; else r1=SILENT; fi
  t "suppression-reported-$mod" reported "$r1"
done

BUILDER_MOD="$SHARED/lib/duty-builder.sh"
builder_commit_block="$(sed -n '/# Record what this session SAW/,/# --- HANDOFF:/p' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '_ready_lines_to_commit "$ready_items" "$post_ready_ids"' <<<"$builder_commit_block" &&
   ! grep -Fq '"$ready_items" "$cr_items" | ledger_commit' <<<"$builder_commit_block"; then
  r1=narrowed
else
  r1=WHOLE_SET
fi
t builder-ready-commit-routed-through-helper narrowed "$r1"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '"$ready_commit" "$cr_items" | ledger_commit' <<<"$builder_commit_block"; then
  r1=preserved
else
  r1=DROPPED
fi
t builder-round-items-preserved preserved "$r1"
# The build ledger commit must stay inside this call site's success guard. A
# whole-module grep can accidentally match the independent ci-red guard.
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
builder_rc_block="$(sed -n '/^    if \[ "${RUN_SESSION_RC:-1}" -eq 0 \]; then$/,/^    fi$/p' "$BUILDER_MOD")"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '"$ready_commit" "$cr_items" | ledger_commit' <<<"$builder_rc_block"; then
  r1=gated
else
  r1=UNGATED
fi
t builder-ready-commit-gated-by-session-rc gated "$r1"
# A failed re-query must stay visible and fail open toward another session,
# never burying the whole pre-session ready set (#264 D4).
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if [ "$(grep -Fc 'post-session ready re-query failed; committing no ready lines (#264)' \
     <<<"$builder_commit_block")" -eq 1 ] &&
   ! grep -Fq 'ready_commit="$ready_items"' <<<"$builder_commit_block"; then
  r1=safe
else
  r1=WHOLE_SET
fi
t builder-ready-requery-failure-commits-none safe "$r1"
# shellcheck disable=SC2016  # Match literal shell source, not test variables.
if grep -Fq '[ -e "$marker" ] && return 0' "$BUILDER_MOD" &&
   grep -Fq '_repair_seen_build_264' "$BUILDER_MOD"; then
  r1=gated
else
  r1=UNGATED
fi
t builder-ledger-repair-marker-gated gated "$r1"
# The repair is box-wide, so it runs once before duty_builder enters its
# per-repository loop rather than once from _builder_repo (#264 D5).
builder_entry_block="$(sed -n '/^duty_builder() {/,/^_builder_repo() {/p' "$BUILDER_MOD")"
if [ "$(grep -Fc '_repair_seen_build_264' <<<"$builder_entry_block")" -eq 1 ]; then
  r1=once-per-box
else
  r1=PER_REPO
fi
t builder-ledger-repair-call-site once-per-box "$r1"

# The repair clears both state classes once, names #264, and leaves files
# created after its marker untouched on later invocations.
REPAIR_DIR="$TMP/repair-264"
mkdir -p "$REPAIR_DIR"
printf old >"$REPAIR_DIR/.seen-build"
printf old >"$REPAIR_DIR/.suppressed-build.one"
repair_log="$(DUTY_DIR="$REPAIR_DIR" _repair_seen_build_264)"
[ -e "$REPAIR_DIR/.seen-build" ] && r1=kept || r1=deleted
t builder-ledger-repair-seen deleted "$r1"
[ -e "$REPAIR_DIR/.suppressed-build.one" ] && r1=kept || r1=deleted
t builder-ledger-repair-suppressed deleted "$r1"
[ -e "$REPAIR_DIR/.seen-build.repair-264" ] && r1=created || r1=missing
t builder-ledger-repair-marker created "$r1"
case "$repair_log" in *'#264'*) r1=named ;; *) r1=missing ;; esac
t builder-ledger-repair-log-names-issue named "$r1"
printf later >"$REPAIR_DIR/.seen-build"
printf later >"$REPAIR_DIR/.suppressed-build.two"
t builder-ledger-repair-second-log "" "$(DUTY_DIR="$REPAIR_DIR" _repair_seen_build_264)"
t builder-ledger-repair-second-seen later "$(cat "$REPAIR_DIR/.seen-build")"
t builder-ledger-repair-second-suppressed later "$(cat "$REPAIR_DIR/.suppressed-build.two")"

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
TR_CALLS="$TMP/tr-calls.log"; TR_PHASE="$TMP/tr-phase"
TR_LOG="$TMP/tr-log.txt"; TR_PROMPT="$TMP/tr-prompt"

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
ensure_checkout() { return 0; }
_triage_repo o/r
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
  rm -f "$TR_PHASE" "$TR_PROMPT".*
  SHARED_DIR="$SHARED" TR_CALLS="$TR_CALLS" TR_PHASE="$TR_PHASE" TR_FIX="$TRF" \
  TR_PROMPT="$TR_PROMPT" TR_SESSION_RC="$1" DUTY_DIR="$TRD" ME=me-bot \
  TIMEOUT_MENTION=1 TIMEOUT_TRIAGE=1 \
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

# The reviewer must carry updated_at from the existing pulls page, partition
# before assembling per-repo prompts, and commit that repo's exact fresh set.
REVIEW_MOD="$SHARED/lib/duty-review.sh"
if grep -Fq "\\(.updated_at) \\(\$sr) \\(.number)" "$REVIEW_MOD"; then r1=carried; else r1=MISSING; fi
t review-carries-updated-at carried "$r1"
if grep -q 'fresh_items=.*ledger_filter.*seen-review' "$REVIEW_MOD" &&
   grep -q 'suppressed=.*ledger_suppressed.*seen-review' "$REVIEW_MOD"; then
  r1=partitioned
else
  r1=UNPARTITIONED
fi
t review-partitions-before-prompt partitioned "$r1"
commit_block="$(awk '
  /if \[ "\$\{RUN_SESSION_RC:-1\}" -eq 0 \]; then/ { inside=1 }
  inside { print }
  inside && /^[[:space:]]*fi$/ { exit }
' "$REVIEW_MOD")"
if grep -Fq "\${repo_items[\$SR]}" <<<"$commit_block" &&
   grep -Fq "ledger_commit \"\$DUTY_DIR/.seen-review\"" <<<"$commit_block"; then
  r1=exact
else
  r1=MISMATCH
fi
t review-commits-prompted-set exact "$r1"
if grep -q 'report_suppressed_if_complete.*sweep_complete' "$REVIEW_MOD"; then
  r1=guarded
else
  r1=UNGUARDED
fi
t review-partial-sweep-preserves-report-state guarded "$r1"

# Behavioral mixed case: #5 is unchanged and suppressed; #6 in the same repo
# is fresh. Only #6 enters the prompted/committed set. After that successful
# commit both are settled; advancing #5's updated_at wakes it again.
RLG="$TMP/review-ledger"
printf 'o/r#5 T1\n' | ledger_commit "$RLG"
RQ="$(printf 'o/r#5 T1\no/r#6 T1\n')"
RP="$(printf '%s\n' "$RQ" | ledger_filter "$RLG")"
RS="$(printf '%s\n' "$RQ" | ledger_suppressed "$RLG")"
t review-mixed-prompt-only-fresh "o/r#6 T1" "$RP"
t review-mixed-report-only-suppressed "o/r#5 T1" "$RS"
printf '%s\n' "$RP" | ledger_commit "$RLG"
t review-mixed-commit-settles-both 0 "$(printf '%s\n' "$RQ" | ledger_filter "$RLG" | n)"
t review-advanced-suppressed-rewakes "o/r#5 T2" \
  "$(printf 'o/r#5 T2\n' | ledger_filter "$RLG")"

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
# --- head-checks.jq: the check at the head, and the round it gates (#45/#17) --
# The engine never read statusCheckRollup at all, which is both bugs at once: a
# fix round opened on a red head (#45) and a red head that woke nothing (#17).
HC="$SHARED/lib/jq/head-checks.jq"
hc() {  # hc <panel-json> <pr-array-json> [human] -> rows
  printf '%s' "$2" | jq -r --argjson panel "$1" --arg repo "o/r" \
    --arg human "${3-$CJ_HUMAN}" -f "$HC"
}
mk_prc() {  # mk_prc <rollup> [opinionated-reviews] [requests] [isDraft]
  jq -cn --argjson c "$1" --argjson lr "${2:-[]}" --argjson rr "${3:-[]}" \
     --argjson d "${4:-false}" \
     '[{number:1, isDraft:$d, updatedAt:"T1", headRefOid:"abc1234",
        statusCheckRollup:$c, latestOpinionatedReviews:$lr, reviewRequests:$rr}]'
}
CHK_OK='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS"}]'
CHK_BAD='[{"__typename":"CheckRun","name":"release-exercise / fixture-chain","status":"COMPLETED","conclusion":"FAILURE"}]'
CHK_RUNNING='[{"__typename":"CheckRun","name":"check","status":"IN_PROGRESS","conclusion":null}]'
CHK_CANCEL='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"CANCELLED"}]'
CHK_STALE='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"STALE"}]'
CHK_NEUTRAL='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"NEUTRAL"}]'
CHK_SKIPPED='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SKIPPED"}]'
# A conclusion this engine has never heard of. GitHub adds these.
CHK_UNKNOWN='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"QUANTUM_FAILURE"}]'
# Same-head reruns are all present in the rollup. The latest run of each check
# name is the check's answer; older runs are not independent evidence.
CHK_CANCEL_THEN_OK='[
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:04Z"},
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:07Z","completedAt":"2026-07-29T11:00:17Z"}]'
CHK_OK_THEN_CANCEL='[
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:04Z"},
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-07-29T11:00:07Z","completedAt":"2026-07-29T11:00:08Z"}]'
CHK_SAME_SECOND_CANCEL_LAST='[
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:17Z"},
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:04Z"}]'
CHK_WORKFLOW_COLLISION_FAILURE_FIRST='[
  {"__typename":"CheckRun","name":"test","workflowName":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-29T10:00:00Z","completedAt":"2026-07-29T10:01:00Z"},
  {"__typename":"CheckRun","name":"test","workflowName":"nightly","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T10:05:00Z","completedAt":"2026-07-29T10:06:00Z"}]'
CHK_WORKFLOW_COLLISION_FAILURE_LAST="$(printf '%s' "$CHK_WORKFLOW_COLLISION_FAILURE_FIRST" | jq 'reverse')"
CHK_SUPERSEDED_CANCEL_AND_FAILURE='[
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-07-29T11:00:03Z","completedAt":"2026-07-29T11:00:04Z"},
  {"__typename":"CheckRun","name":"labels / reconcile","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:07Z","completedAt":"2026-07-29T11:00:17Z"},
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-29T10:58:47Z","completedAt":"2026-07-29T10:59:22Z"}]'
CHK_FAILURE_THEN_RUNNING='[
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-07-29T10:58:47Z","completedAt":"2026-07-29T10:59:22Z"},
  {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-07-29T11:02:00Z","completedAt":null}]'
# The StatusContext shape. THIS is the fixture that matters: crew's own CI is a
# single CheckRun, so an implementation that discriminates on __typename and
# reads only .conclusion passes every other test in this file and reports a
# FAILING status context as green — a pass for a reason unrelated to the claim,
# which is #50's shape. Reintroduce that discrimination and these two go red.
SC_BAD='[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'
SC_ERR='[{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}]'
SC_MIX='[{"__typename":"CheckRun","name":"check","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'
# The status carries `startedAt`, not `createdAt`: `gh` requests GitHub's
# `createdAt` for a StatusContext and serialises it under its own key, so
# `createdAt` never reaches a caller. `latest_checks` reads `.startedAt //
# .createdAt`, so the generation ordering this fixture pins is unchanged either
# way — but the fiction is the one that went on to kill `_resume_newest_check`
# one module over (#391 round 2), and a fixture file cannot hold a shape
# contract while contradicting it here.
SC_COLLISION_STATUS_LAST='[
  {"__typename":"CheckRun","name":"ci/build","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-07-29T11:00:07Z","completedAt":"2026-07-29T11:00:17Z"},
  {"__typename":"StatusContext","context":"ci/build","state":"FAILURE","startedAt":"2026-07-29T11:05:00Z"}]'
SC_COLLISION_STATUS_FIRST="$(printf '%s' "$SC_COLLISION_STATUS_LAST" | jq 'reverse')"

state_of() { hc '[]' "$(mk_prc "$1")" | cut -f4; }
t head-check-run-success      green   "$(state_of "$CHK_OK")"
t head-check-run-failure      red     "$(state_of "$CHK_BAD")"
t head-status-context-failure red     "$(state_of "$SC_BAD")"
t head-status-context-error   red     "$(state_of "$SC_ERR")"
t head-mixed-shapes-one-red   red     "$(state_of "$SC_MIX")"
t head-colliding-status-last-is-red red "$(state_of "$SC_COLLISION_STATUS_LAST")"
t head-colliding-status-first-is-red red "$(state_of "$SC_COLLISION_STATUS_FIRST")"
t head-check-still-running    pending "$(state_of "$CHK_RUNNING")"
t head-no-checks-is-not-green none    "$(state_of '[]')"
# GREEN IS A WHITELIST; ANYTHING ELSE IS RED (codex, #64). The first version
# enumerated the failing conclusions and let the rest fall through to green,
# arguing a CANCELLED run is one superseded by a newer push. Same-head rollups
# can retain several generations of one check name, but after reducing those
# generations a latest cancellation is a head that is not passing. Reading it
# green defeated #45's gate and blinded #17's wake at the same time. This test
# previously asserted `green` and locked that in, which is why it is called
# out here rather than quietly flipped.
t head-cancelled-is-red       red     "$(state_of "$CHK_CANCEL")"
t head-stale-is-red           red     "$(state_of "$CHK_STALE")"
# ...and the point of a whitelist: a conclusion nobody has written a branch for
# fails CLOSED. Enumerating the bad ones would have gotten this wrong the same
# way, silently, the next time GitHub adds one.
t head-unknown-conclusion-is-red red  "$(state_of "$CHK_UNKNOWN")"
# #146: a concurrency cancellation superseded by a later same-name success is
# not evidence; a cancellation that remains the latest run is still fail-closed.
t head-cancelled-then-succeeded-is-green green "$(state_of "$CHK_CANCEL_THEN_OK")"
t head-cancelled-as-last-word-is-red red "$(state_of "$CHK_OK_THEN_CANCEL")"
t head-same-second-cancel-last-is-green green "$(state_of "$CHK_SAME_SECOND_CANCEL_LAST")"
# Same-named jobs in different workflows are independent evidence. Neither
# rollup order may let one workflow's success discard another one's failure.
t head-workflow-collision-failure-first-is-red red \
  "$(state_of "$CHK_WORKFLOW_COLLISION_FAILURE_FIRST")"
t head-workflow-collision-failure-last-is-red red \
  "$(state_of "$CHK_WORKFLOW_COLLISION_FAILURE_LAST")"
# An unrelated failure survives even while the superseded cancellation from
# another check identity disappears.
t head-unrelated-failure-survives-superseded-cancel red \
  "$(state_of "$CHK_SUPERSEDED_CANCEL_AND_FAILURE")"
t head-unrelated-failure-is-named "test (FAILURE)" \
  "$(hc '[]' "$(mk_prc "$CHK_SUPERSEDED_CANCEL_AND_FAILURE")" | cut -f6)"
# A rerun in progress is the latest word and therefore pending, not the stale
# failure from the earlier run.
t head-running-rerun-supersedes-failure pending "$(state_of "$CHK_FAILURE_THEN_RUNNING")"
# The genuinely-not-a-failure conclusions stay green, or every skipped matrix
# leg would wake a builder.
t head-neutral-is-green       green   "$(state_of "$CHK_NEUTRAL")"
t head-skipped-is-green       green   "$(state_of "$CHK_SKIPPED")"
# Drafts are never rows: a panel is never requested on a draft, and a draft's
# red CI is the author's in-flight business (resume owns it).
t head-drafts-excluded "" "$(hc '[]' "$(mk_prc "$CHK_BAD" '[]' '[]' true)")"

# The failing check's name reaches the operator and the prompt, spaces and all
# — which is why the row is TAB-delimited and the names are last.
t head-failing-names-carried "release-exercise / fixture-chain (FAILURE)" \
  "$(hc '[]' "$(mk_prc "$CHK_BAD")" | cut -f6)"
t head-green-names-dash "-" "$(hc '[]' "$(mk_prc "$CHK_OK")" | cut -f6)"

# Round-owed, and the two facts arriving on one row.
CR_REQ='[{"state":"CHANGES_REQUESTED","author":{"login":"p1"},"commit":{"oid":"abc1234"}}]'
t head-round-owed-green owed "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_REQ")" | cut -f5)"
t head-round-owed-red-still-owed owed "$(hc '["p1"]' "$(mk_prc "$CHK_BAD" "$CR_REQ")" | cut -f5)"
t head-round-owed-red-is-red red "$(hc '["p1"]' "$(mk_prc "$CHK_BAD" "$CR_REQ")" | cut -f4)"
# Verdicts are opinions about a tree. A stale change request does not wake the
# builder for a head that reviewer has not seen.
CR_STALE='[{"state":"CHANGES_REQUESTED","author":{"login":"p1"},"commit":{"oid":"oldhead"}}]'
t head-round-stale-change-request - \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_STALE")" | cut -f5)"
# latestOpinionatedReviews retains the standing blocker even if a later plain
# review comment displaced it from gh-pr-list's latestReviews. Carry the empty
# commit oid that listing exposes as a trap: reading or head-filtering that
# field would turn this owed round into a silent stall.
COMMENT_MASKED="$(mk_prc "$CHK_OK" "$CR_REQ" \
  | jq '.[0].latestReviews=[
      {state:"COMMENTED",author:{login:"p1"},commit:{oid:""}}
    ]')"
t head-round-comment-does-not-mask-change owed \
  "$(hc '["p1"]' "$COMMENT_MASKED" | cut -f5)"
# GraphQL has already reduced a same-head request-changes → approve flip to the
# reviewer's latest opinionated verdict.
CR_FLIPPED='[{"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"}}]'
t head-round-flipped-to-approve - \
  "$(hc '["p1"]' "$(mk_prc "$CHK_OK" "$CR_FLIPPED")" | cut -f5)"
# An outstanding panel request means the round is not whole yet.
t head-round-not-whole - \
  "$(hc '["p1","p2"]' "$(mk_prc "$CHK_OK" "$CR_REQ" '[{"login":"p2"}]')" | cut -f5)"
# An all-approved completed round is not builder work.
ALL_APPROVED='[
  {"state":"APPROVED","author":{"login":"p1"},"commit":{"oid":"abc1234"}},
  {"state":"APPROVED","author":{"login":"p2"},"commit":{"oid":"abc1234"}}
]'
t head-round-all-approved - \
  "$(hc '["p1","p2"]' "$(mk_prc "$CHK_OK" "$ALL_APPROVED")" | cut -f5)"
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

# --- the ci-red ledger key: why the head is the ID, not the value (#17) -------
# #243: a ready PR missing its current-head signal becomes resume work only on
# the twelfth consecutive tick. The state is keyed by head, so a push resets
# the count even when the PR number is unchanged.
STRANDED_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
STRANDED_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
STRANDED_NONE="cccccccccccccccccccccccccccccccccccccccc"
STRANDED_JSON="$(jq -cn --arg head "$STRANDED_HEAD" --arg old "$STRANDED_OLD" --arg none "$STRANDED_NONE" '[
  {number:1,isDraft:true,headRefOid:$head,comments:[]},
  {number:2,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER `" + $head + "`")}]},
  {number:3,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER " + $old)}]},
  {number:4,isDraft:false,headRefOid:$none,comments:[
    {author:{login:"other"},body:("ANSWER " + $none)}]},
  {number:5,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER: " + $head)}]}
]')"
t stranded-keys-exclude-draft-and-current-signal \
  "$(printf 'o/r#3@%s\no/r#4@%s' "$STRANDED_HEAD" "$STRANDED_NONE")" \
  "$(printf '%s' "$STRANDED_JSON" | _stranded_resume_keys o/r me ANSWER)"
# #286: the licence grew a createdAt half, and THIS path stays indifferent to
# it. These listings carry the field natively — `gh pr list --json comments`
# returns it — so the fixture proves the extra field changes nothing here.
# The two cases are deliberately inverted against the clock: #6 signals the
# CURRENT head with the OLDER comment and is not stranded, #7 signals an OLD
# head with the NEWER comment and is. A path that started reading the time
# instead of the sha would get both backwards. Stranded detection asks which
# head a signal names; whether that signal was spent by the verdicts answering
# it is the request side's question (#286), never resume's (#243).
STRANDED_TIMED="$(jq -cn --arg head "$STRANDED_HEAD" --arg old "$STRANDED_OLD" '[
  {number:6,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER " + $head),createdAt:"2026-08-02T10:08:12Z"}]},
  {number:7,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("ANSWER " + $old),createdAt:"2026-08-02T11:12:27Z"}]}
]')"
t stranded-keys-ignore-the-signal-clock \
  "$(printf 'o/r#7@%s' "$STRANDED_HEAD")" \
  "$(printf '%s' "$STRANDED_TIMED" | _stranded_resume_keys o/r me ANSWER)"
STRANDED_STATE="$TMP/resume-unsignalled"
for _tick in $(seq 1 11); do
  stranded_out="$(printf 'o/r#243@aaa\n' | _stranded_resume_due "$STRANDED_STATE" 12)"
done
t stranded-resume-not-before-12 "" "$stranded_out"
t stranded-resume-on-12 243 \
  "$(printf 'o/r#243@aaa\n' | _stranded_resume_due "$STRANDED_STATE" 12)"
t stranded-resume-state-file-format-byte-compatible \
  $'o/r#243@aaa\t12' "$(cat "$STRANDED_STATE")"
t stranded-resume-push-resets "" \
  "$(printf 'o/r#243@bbb\n' | _stranded_resume_due "$STRANDED_STATE" 12)"
t stranded-resume-new-head-count-is-one 1 \
  "$(awk -F'\t' '$1 == "o/r#243@bbb" {print $2}' "$STRANDED_STATE")"
# A signal removes the PR from the candidate input; a later new head starts a
# fresh episode rather than inheriting the old count.
printf '' | _stranded_resume_due "$STRANDED_STATE" 12 >/dev/null
t stranded-resume-signal-clears-state 0 "$(wc -l <"$STRANDED_STATE" | tr -d ' ')"

# #403: the near-miss bypass and the post-twelve stranded output each pass
# through the same reporting adapter but own independent breaker state. Drive
# ticks 1→5 at one head, then a push and ticks 6→8: a single call cannot prove
# that the fourth and fifth attempts stay suppressed or that head movement is
# the only reset.
lane_tick() {
  local lane="$1" state="$2" keys="$3" log_file="$4"
  _resume_lane_breaker o/r "$lane" "$state" "$keys" >>"$log_file" 2>&1
  LANE_OUT="$RESUME_LANE_DISPATCH_NUMS"
}
for lane in near-miss stranded; do
  lane_state="$TMP/resume-zero-action-$lane"
  lane_log="$TMP/resume-zero-action-$lane.log"
  : >"$lane_log"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-dispatch-1" 403 "$LANE_OUT"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-dispatch-2" 403 "$LANE_OUT"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-dispatch-3" 403 "$LANE_OUT"
  t "$lane-breaker-trip-at-3" 1 \
    "$(grep -c "WARN: o/r#403: $lane resume dispatch 3 of 3 at head aaa — the previous 2 produced no commit" "$lane_log")"
  t "$lane-breaker-trip-claims-no-third-result" 0 \
    "$(grep -c 'previous 3 produced no commit' "$lane_log")"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-suppresses-4" "" "$LANE_OUT"
  lane_tick "$lane" "$lane_state" 'o/r#403@aaa' "$lane_log"
  t "$lane-breaker-suppresses-5" "" "$LANE_OUT"
  t "$lane-breaker-suppression-speaks-every-tick" 2 \
    "$(grep -c "o/r#403 $lane lane suppressed at aaa after 3 zero-action dispatches" "$lane_log")"
  lane_tick "$lane" "$lane_state" 'o/r#403@bbb' "$lane_log"
  t "$lane-breaker-push-resets-to-1" 403 "$LANE_OUT"
  t "$lane-breaker-push-state-count" 1 \
    "$(awk -F'\t' '$1 == "o/r#403@bbb" { print $2 }' "$lane_state")"
  lane_tick "$lane" "$lane_state" 'o/r#403@bbb' "$lane_log"
  lane_tick "$lane" "$lane_state" 'o/r#403@bbb' "$lane_log"
  t "$lane-breaker-post-push-dispatch-3" 403 "$LANE_OUT"
  t "$lane-breaker-logs-lane-pr-count-head" 1 \
    "$(grep -c "o/r#403: $lane resume dispatch 3 of 3 at bbb" "$lane_log")"
  lane_tick "$lane" "$lane_state" 'o/r#404@ccc' "$lane_log"
  t "$lane-breaker-prunes-left-set" $'o/r#404@ccc\t1' "$(cat "$lane_state")"
done

# The concrete call sites and consumers are both part of the contract: sharing
# either new file resets the other lane, while ignoring either verdict restores
# the unbounded wiring without disturbing the helper-level breaker tests.
# shellcheck disable=SC2016  # matching shell source literally
if [ "$(grep -cF '.resume-zero-action-nearmiss.$slug' "$SHARED/lib/duty-builder.sh")" = 1 ] \
  && grep -Fq 'near_miss_nums="$RESUME_LANE_DISPATCH_NUMS"' "$SHARED/lib/duty-builder.sh"; then
  r1=bounded
else
  r1=UNBOUNDED-OR-SHARED
fi
t resume-lane-breaker-nearmiss-wiring bounded "$r1"
# shellcheck disable=SC2016  # matching shell source literally
if [ "$(grep -cF '.resume-zero-action-stranded.$slug' "$SHARED/lib/duty-builder.sh")" = 1 ] \
  && grep -Fq 'stranded_nums="$RESUME_LANE_DISPATCH_NUMS"' "$SHARED/lib/duty-builder.sh"; then
  r1=bounded
else
  r1=UNBOUNDED-OR-SHARED
fi
t resume-lane-breaker-stranded-wiring bounded "$r1"
ISO_NEAR="$TMP/resume-isolation-near"; ISO_STRANDED="$TMP/resume-isolation-stranded"
lane_tick near-miss "$ISO_NEAR" 'o/r#403@same' "$TMP/resume-isolation.log"
lane_tick near-miss "$ISO_NEAR" 'o/r#403@same' "$TMP/resume-isolation.log"
lane_tick stranded "$ISO_STRANDED" 'o/r#403@same' "$TMP/resume-isolation.log"
t resume-lane-breaker-state-files-do-not-touch $'2\t1' \
  "$(paste <(cut -f2 "$ISO_NEAR") <(cut -f2 "$ISO_STRANDED"))"

# A suppressed near miss must not hitchhike in the prompt when an unrelated PR
# independently buys the session. Drive A past its breaker and B through the
# real twelve-tick threshold, then build the same final dispatch union and
# description the repository tick uses.
MIXED_NEAR_STATE="$TMP/resume-mixed-near"
MIXED_NEAR_LOG="$TMP/resume-mixed-near.log"
for _tick in $(seq 1 4); do
  lane_tick near-miss "$MIXED_NEAR_STATE" 'o/r#403@aaa' "$MIXED_NEAR_LOG"
done
MIXED_DUE_STATE="$TMP/resume-mixed-due"
for _tick in $(seq 1 12); do
  mixed_due_nums="$(printf 'o/r#404@bbb\n' | _stranded_resume_due "$MIXED_DUE_STATE" 12)"
done
mixed_stranded_nums="$(printf '%s %s' "$mixed_due_nums" "$LANE_OUT" \
  | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
mixed_near_desc="$(_near_miss_dispatch_desc $'403\t9001' "$mixed_stranded_nums")"
t resume-lane-mixed-unrelated-pr-still-wakes 404 "$(printf '%s' "$mixed_stranded_nums" | xargs)"
t resume-lane-mixed-suppressed-near-miss-not-actionable "" "$mixed_near_desc"
# If an independent lane admits the same PR, retain why its signal looked like
# a near miss even though the near-miss lane itself is suppressed.
t resume-lane-mixed-same-pr-keeps-near-miss-context '#403 (comment 9001)' \
  "$(_near_miss_dispatch_desc $'403\t9001' '403')"

# The post-twelve lane has two counters with different questions. Trip its
# dispatch breaker after ticks 12–14, then move the head: the unsignalled
# counter starts at one immediately, while the breaker starts at one when that
# new head first becomes dispatchable on its twelfth tick.
DUAL_DUE="$TMP/resume-dual-unsignalled"
DUAL_BREAKER="$TMP/resume-dual-breaker"
DUAL_LOG="$TMP/resume-dual.log"
for _tick in $(seq 1 14); do
  dual_num="$(printf 'o/r#403@aaa\n' | _stranded_resume_due "$DUAL_DUE" 12)"
  dual_keys=""
  [ -z "$dual_num" ] || dual_keys='o/r#403@aaa'
  lane_tick stranded "$DUAL_BREAKER" "$dual_keys" "$DUAL_LOG"
done
t stranded-lane-trips-after-three-past-threshold-dispatches 3 \
  "$(cut -f2 "$DUAL_BREAKER")"
dual_num="$(printf 'o/r#403@bbb\n' | _stranded_resume_due "$DUAL_DUE" 12)"
lane_tick stranded "$DUAL_BREAKER" "" "$DUAL_LOG"
t stranded-lane-push-restarts-unsignalled-at-one $'o/r#403@bbb\t1' \
  "$(cat "$DUAL_DUE")"
for _tick in $(seq 2 12); do
  dual_num="$(printf 'o/r#403@bbb\n' | _stranded_resume_due "$DUAL_DUE" 12)"
done
dual_keys=""; [ -z "$dual_num" ] || dual_keys='o/r#403@bbb'
lane_tick stranded "$DUAL_BREAKER" "$dual_keys" "$DUAL_LOG"
t stranded-lane-push-restarts-breaker-at-one $'o/r#403@bbb\t1' \
  "$(cat "$DUAL_BREAKER")"

# The no-signal hold speaks once for one repo/PR/head, then speaks again when a
# push changes the key. report_suppressed writes through warn on stderr.
hold1="$(_report_unsignalled_hold o/r 243 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)"
hold2="$(_report_unsignalled_hold o/r 243 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1)"
hold3="$(_report_unsignalled_hold o/r 243 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>&1)"
t unsignalled-hold-first-warns 1 "$(grep -c 'no round-answered signal' <<<"$hold1")"
t unsignalled-hold-same-head-quiet 0 "$(grep -c 'no round-answered signal' <<<"$hold2")"
t unsignalled-hold-new-head-warns 1 "$(grep -c 'no round-answered signal' <<<"$hold3")"
# Pin the wake-path wiring too: helper-only tests stay green if the request
# gate regresses to the old bare log that flooded #227 on every tick.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_report_unsignalled_hold "$repo" "$num" "$gql_head"' "$SHARED/lib/duty-builder.sh"; then
  r1=wired
else
  r1=BARE-OR-MISSING
fi
t unsignalled-hold-wired-into-request-gate wired "$r1"

# --- #319: a round-answered signal that missed the wire ---------------------
# PR #311 posted `{{MARK_ANSWERED}} 3741918e…` — the literal slot name, then the
# correct head. The marker is accepted only as a prefix, so to the engine that
# was not a partial signal, it was no comment at all: no panel requested,
# state:addressing standing over an answered round at a green head, and the
# twelve-tick stranded path an hour away. A near-miss is detectable on sight,
# and these fixtures ARE that comment body.
NM_HEAD=3741918e27139974532956470a2c411e5bc6ad62
NM_OLD=f117b520f117b520f117b520f117b520f117b520
NMJQ="$SHARED/lib/jq/near-miss-signal.jq"
nm_payload() {  # nm_payload <comment json>... -> the GraphQL payload shape
  jq -cn --argjson nodes "$(printf '%s\n' "$@" | jq -sc '.')" \
    '{data:{repository:{pullRequest:{comments:{nodes:$nodes}}}}}'
}
nm_comment() {  # nm_comment LOGIN BODY [ID] [CREATED]
  jq -cn --arg login "$1" --arg body "$2" --arg id "${3:-5165639326}" \
    --arg at "${4:-2026-08-03T11:17:54Z}" \
    '{author:{login:$login},body:$body,createdAt:$at,id:$id}'
}
nm() { jq -c --arg me me -f "$NMJQ"; }

# The incident, byte for byte.
t near-miss-detects-the-incident \
  "{\"sha\":\"$NM_HEAD\",\"createdAt\":\"2026-08-03T11:17:54Z\",\"id\":\"5165639326\"}" \
  "$(nm_payload "$(nm_comment me "{{MARK_ANSWERED}} $NM_HEAD")" | nm)"
# Any unrendered slot is the same defect: the shape is the evidence, not the
# name. Whichever marker the session meant, a ready PR at a head with no valid
# signal is owed the round-answered one, so resume's next act is the same.
t near-miss-matches-any-marker-slot "$NM_HEAD" \
  "$(nm_payload "$(nm_comment me "{{MARK_RESUME}} $NM_HEAD")" | nm | jq -r .sha)"
# MUST FAIL — a near-miss treated as a signal. The two predicates partition the
# same thread: neither body is ever both, in either direction. The engine
# requesting a panel off unrendered template text is a worse failure than the
# stall #319 fixes.
NM_REAL="$(nm_payload "$(nm_comment me "📣 round answered at head $NM_HEAD")")"
t near-miss-real-signal-is-not-a-near-miss "" \
  "$(printf '%s' "$NM_REAL" | nm | jq -r .sha)"
t near-miss-real-signal-still-reads-as-a-signal "$NM_HEAD" \
  "$(printf '%s' "$NM_REAL" \
     | jq -r --arg me me --arg mark '📣 round answered at head' -f "$AHJQ" | jq -r .sha)"
NM_PLACEHOLDER="$(nm_payload "$(nm_comment me "{{MARK_ANSWERED}} $NM_HEAD")")"
t near-miss-placeholder-is-not-a-signal "" \
  "$(printf '%s' "$NM_PLACEHOLDER" \
     | jq -r --arg me me --arg mark '📣 round answered at head' -f "$AHJQ" | jq -r .sha)"
# Anchored, like the startswith it mirrors: a body that MENTIONS a placeholder —
# a reviewer quoting the incident, this suite's own prose — is discussion, and
# must never make a PR resume-due.
t near-miss-prose-mentioning-a-slot-is-not-one "" \
  "$(nm_payload "$(nm_comment me "the session posted {{MARK_ANSWERED}} $NM_HEAD by mistake")" \
     | nm | jq -r .sha)"
# A slot with no head names nothing to resume at.
t near-miss-without-a-head-is-nothing "" \
  "$(nm_payload "$(nm_comment me '{{MARK_ANSWERED}} (sha to follow)')" | nm | jq -r .sha)"
# Somebody else's botched marker is not my signal, exactly as in answered-head.
t near-miss-is-mine-only "" \
  "$(nm_payload "$(nm_comment other "{{MARK_ANSWERED}} $NM_HEAD")" | nm | jq -r .sha)"
# Latest wins, and the id travels with the sha it belongs to.
t near-miss-latest-wins "$NM_HEAD 5165639326" \
  "$(nm_payload "$(nm_comment me "{{MARK_ANSWERED}} $NM_OLD" 111)" \
       "$(nm_comment me "{{MARK_ANSWERED}} $NM_HEAD" 5165639326)" \
     | nm | jq -r '"\(.sha) \(.id)"')"
# The sha is captured from what FOLLOWS the slot, so a near-miss that quotes
# another commit first cannot name the wrong head.
t near-miss-reads-the-head-after-the-slot "$NM_HEAD" \
  "$(nm_payload "$(nm_comment me "{{MARK_ANSWERED}} $NM_HEAD (was $NM_OLD)")" | nm | jq -r .sha)"
t near-miss-empty-thread-is-empty "" "$(echo '{}' | nm | jq -r .sha)"

# THE PANEL IS NOT REQUESTED FROM A NEAR-MISS, end to end. With only that
# comment on the thread, answered-head.jq reads no signal, so _request_panel
# returns at its gate; and request-panel.jq, handed the empty licence that gate
# would have handed it, names nobody. `me-bot` and `$H` are the request-side
# fixture's own author and head (above), so this is that block's PR with the
# incident's comment body substituted for its signal — the only difference.
NM_ONLY="$(mk_rp "$H" '[]' '[]' \
  "$(jq -cn --arg b "{{MARK_ANSWERED}} $H" '[{author:{login:"me-bot"},body:$b}]')")"
t near-miss-answered-head-reads-no-signal "" "$(printf '%s' "$NM_ONLY" | ah_sha)"
# ...and _request_panel therefore issues nothing. Driven through the gate itself
# rather than through request-panel.jq, because the sha half of the licence is
# the CALLER's gate and is deliberately not re-checked in the predicate (that
# file's header) — asking the predicate would be asking the wrong layer. `gh` is
# a shell function here, so any API call the gate lets through is recorded
# instead of made.
NM_DUTY="$TMP/near-miss-duty"; mkdir -p "$NM_DUTY/lib"
ln -sfn "$SHARED/lib/jq" "$NM_DUTY/lib/jq"
NM_STUB="$TMP/near-miss-bin"; mkdir -p "$NM_STUB"
cat >"$NM_STUB/gh" <<'NMGH'
#!/usr/bin/env bash
# Every API call the gate lets through is recorded here instead of made.
printf '%s\n' "$*" >>"$NM_GH_LOG"
NMGH
chmod +x "$NM_STUB/gh"
# Driven in a child shell with that stub first on PATH, rather than with a `gh`
# function in this one: a fixture that calls an engine function directly drags
# the engine's own dataflow into this file's static analysis, and the child
# keeps the two apart.
# `nm_pr` / `nm_log`, not `payload` / `gh_log`: a variable named `payload` in
# this file makes shellcheck read the unrelated `r1=payload-author` above as
# arithmetic (SC2100), and the suite is shellcheck-clean in CI.
nm_request() {  # nm_request <payload> <call-log> -> how many API calls it made
  local nm_pr="$1" nm_log="$2"
  : >"$nm_log"
  PATH="$NM_STUB:$PATH" NM_GH_LOG="$nm_log" ME="me-bot" MARK_ANSWERED="$RP_MARK" \
    DUTY_DIR="$NM_DUTY" LABEL_BOTS_REVIEWING="state:bots-reviewing" \
    bash -c 'set -uo pipefail
      # shellcheck disable=SC1090
      source "$1/lib/common.sh"
      # shellcheck disable=SC1090
      source "$1/lib/duty-builder.sh"
      _request_panel o/r 311 "$2" "$3" green "$4"' \
    nm_request "$SHARED" "$nm_pr" "$PANEL" "$H" >/dev/null 2>&1
  awk 'NF' "$nm_log" | wc -l | tr -d ' '
}
t near-miss-request-issues-no-review-request 0 \
  "$(nm_request "$NM_ONLY" "$TMP/near-miss-gh-calls")"
# The control: the same payload with a REAL signal in place of the near-miss
# does request, so the zero above is the near-miss being refused and not the
# harness being inert.
NM_REAL_ONLY="$(mk_rp "$H" '[]' '[]' \
  "$(jq -cn --arg b "$RP_MARK $H" '[{author:{login:"me-bot"},body:$b}]')")"
t near-miss-control-real-signal-does-request 3 \
  "$(nm_request "$NM_REAL_ONLY" "$TMP/near-miss-gh-calls-control")"

# The detection over a listing. Fixtures, never a live box (#319's test plan).
NM_LISTING="$(jq -cn --arg head "$NM_HEAD" --arg old "$NM_OLD" '[
  {number:311,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("{{MARK_ANSWERED}} " + $head),id:"5165639326",
     createdAt:"2026-08-03T11:17:54Z"}]},
  {number:312,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("{{MARK_ANSWERED}} " + $old),id:"222",
     createdAt:"2026-08-03T11:17:54Z"}]},
  {number:313,isDraft:false,headRefOid:$head,comments:[]},
  {number:314,isDraft:true,headRefOid:$head,comments:[
    {author:{login:"me"},body:("{{MARK_ANSWERED}} " + $head),id:"444",
     createdAt:"2026-08-03T11:17:54Z"}]},
  {number:315,isDraft:false,headRefOid:$head,comments:[
    {author:{login:"me"},body:("{{MARK_ANSWERED}} " + $head),id:"555",
     createdAt:"2026-08-03T11:17:54Z"},
    {author:{login:"me"},body:("ANSWER " + $head),
     createdAt:"2026-08-03T11:32:08Z"}]},
  {number:316,isDraft:false,headRefOid:$head,comments:null}
]')"
# Called in THIS shell, never inside a command substitution: the answer comes
# back in a global, and a subshell's globals die with it. Its reports go to
# stdout like every other log line, so they are captured through a file.
_near_miss_resume_rows o/r me ANSWER "$NM_LISTING" >"$TMP/near-miss.log" 2>&1
nm_out="$(cat "$TMP/near-miss.log")"
# 311 alone: 312's near-miss names a SUPERSEDED head — its own push invalidated
# what it announced — 313 is genuine silence, 314 is a draft (the draft path
# already owns it), 315 signalled properly beside its near-miss, and 316's
# thread could not be read.
t near-miss-rows-only-the-current-head-case "$(printf '311\t5165639326')" \
  "$(printf '%s' "$NEAR_MISS_ROWS" | awk 'NF')"
# MUST FAIL — the bypass firing on genuine silence. #313 has no signal and no
# near-miss and must still wait the full twelve ticks; collapsing that threshold
# is a different decision with a different cost, and it is not #319's.
t near-miss-silence-is-not-a-near-miss 0 \
  "$(printf '%s' "$NEAR_MISS_ROWS" | grep -c '^313')"
# MUST FAIL — a near-miss naming a stale head triggering the bypass.
t near-miss-stale-head-does-not-bypass 0 \
  "$(printf '%s' "$NEAR_MISS_ROWS" | grep -c '^312')"
# ...and all four of those PRs are still stranded the ordinary way, so the
# bypass adds a reason to be due and never removes one.
t near-miss-non-bypassed-still-stranded "$(printf 'o/r#311@%s\no/r#312@%s\no/r#313@%s' \
    "$NM_HEAD" "$NM_HEAD" "$NM_HEAD")" \
  "$(printf '%s' "$NM_LISTING" | _stranded_resume_keys o/r me ANSWER)"
# EXACTLY ONE WARN per detection, naming the PR, the head in full, and the
# comment id — the three things a reader needs to find the malformed comment.
t near-miss-warns-once 1 "$(grep -c 'WARN.*o/r#311' <<<"$nm_out")"
t near-miss-warn-names-the-head 1 "$(grep -c "$NM_HEAD" <<<"$nm_out")"
t near-miss-warn-names-the-comment 1 "$(grep -c '5165639326' <<<"$nm_out")"
t near-miss-warn-is-silent-about-the-rest 1 "$(grep -c 'WARN' <<<"$nm_out")"
# MUST FAIL — the malformed comment edited, hidden or deleted. The board record
# is the only trace this class leaves; a fix that tidies it destroys the
# evidence. The detection makes NO GitHub write of any kind: it reads the
# listing it was handed and warns.
nm_body="$(declare -f _near_miss_resume_rows)"
t near-miss-detection-makes-no-github-call 0 "$(grep -c 'gh ' <<<"$nm_body")"
if grep -Fq 'LEAVE THE MALFORMED COMMENT WHERE IT IS' "$SHARED/prompts/resume.txt" \
  && grep -Fq 'do not edit it, hide it, delete it' "$SHARED/prompts/resume.txt"; then
  r1=left-alone
else
  r1=TIDIED
fi
t near-miss-prompt-leaves-the-comment-alone left-alone "$r1"
# MUST FAIL — a second definition of the marker. A hand-rolled brace match or a
# marker comparison inside duty-builder.sh is exactly what answered-head.jq's
# header warns about; both predicates live in jq, and the shell only calls them.
t near-miss-no-hand-rolled-slot-match-in-the-engine 0 \
  "$(grep -c 'MARK_[A-Z]*}}' "$SHARED/lib/duty-builder.sh")"
t near-miss-has-one-placeholder-parser 1 \
  "$(grep -l 'MARK_\[A-Z0-9_\]' "$SHARED"/lib/jq/*.jq | wc -l | tr -d ' ')"
# The predicate is its own file, never a fallback branch inside answered-head.jq:
# a fallback there is how placeholder text becomes wire protocol.
t near-miss-not-a-branch-of-the-signal-parser 0 \
  "$(grep -c 'MARK_\[A-Z0-9_\]' "$SHARED/lib/jq/answered-head.jq")"
# MUST FAIL — the state file's format changing. `.resume-unsignalled.<slug>` is
# written by a live fleet, and a format change strands every counter on every
# box at upgrade. The bypass rides BESIDE _stranded_resume_due, never through
# it: same threshold, same call, same two-column state file, and its tests above
# run unmodified.
# shellcheck disable=SC2016,SC2100  # matching shell source literally
if grep -Fq '_stranded_resume_due "$DUTY_DIR/.resume-unsignalled.$slug" 12' \
     "$SHARED/lib/duty-builder.sh"; then r1=threshold-intact; else r1=DISTURBED; fi
t near-miss-threshold-call-unchanged threshold-intact "$r1"
NM_STATE="$TMP/resume-unsignalled-319"
printf 'o/r#311@%s\n' "$NM_HEAD" | _stranded_resume_due "$NM_STATE" 12 >/dev/null
t near-miss-state-file-format-unchanged "o/r#311@$NM_HEAD	1" "$(cat "$NM_STATE")"
# The near-miss PR's counter advances exactly as any other stranded PR's does:
# the bypass adds a second, independent reason to be due, and takes nothing
# away from the evidence the threshold path is accumulating.
printf 'o/r#311@%s\n' "$NM_HEAD" | _stranded_resume_due "$NM_STATE" 12 >/dev/null
t near-miss-counter-still-advances "o/r#311@$NM_HEAD	2" "$(cat "$NM_STATE")"

# The listing stopped carrying comments at 70823ac (#314) and `.comments // []`
# read the absence as an empty thread, so every non-draft authored PR has
# classified as unsignalled since. The signal half is read per PR now; these pin
# the route and the reason it is not the listing's own connection.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'gh api --paginate "repos/$repo/issues/$num/comments?per_page=100"' \
     "$SHARED/lib/duty-builder.sh"; then r1=paginated; else r1=CAPPED; fi
t near-miss-comments-read-is-paginated paginated "$r1"
# A thread that could not be read is NOT an empty thread: the PR leaves the
# stranded set for the tick rather than accruing toward a resume the evidence
# does not support.
t near-miss-unread-thread-is-not-stranded "" \
  "$(printf '%s' "$NM_LISTING" | jq -c '[.[] | select(.number == 316)]' \
     | _stranded_resume_keys o/r me ANSWER)"
t near-miss-unread-thread-is-not-a-detection 0 \
  "$(printf '%s' "$NEAR_MISS_ROWS" | grep -c '^316')"
# The wake path: the rows reach the resume prompt, and the prompt tells the
# session what the comment it is looking at actually is.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'NEAR_MISS="${near_miss_desc:-none}"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq '{{NEAR_MISS}}' "$SHARED/prompts/resume.txt"; then r1=wired; else r1=UNWIRED; fi
t near-miss-wired-into-the-resume-prompt wired "$r1"
if grep -Fq 'OPENS WITH AN UNRENDERED TEMPLATE SLOT' "$SHARED/prompts/resume.txt"; then
  r1=explained
else
  r1=MISSING
fi
t near-miss-prompt-explains-the-comment explained "$r1"

# --- #314: the doable-work gate on resume dispatch --------------------------
# Resume was the one wake with no doable-work condition — it fired on "is there
# a draft", and a park is invisible to that. PR #311 spent 58 sessions at one
# head across 4h45m with zero commits, and every comment on it was the
# builder's own. These fixtures ARE that incident: the self comment advances
# every tick, which is what makes an "anything changed" fingerprint re-arm
# itself and suppress nothing.
RG_HEAD=9ff004ac9ff004ac9ff004ac9ff004ac9ff004ac
RG_HEAD2=1782445178244517824451782445178244517824
RG_DUTY="$TMP/resume-gate"; RG_LOG="$TMP/resume-gate.log"
RG_SPEECH="$TMP/resume-speech"
mkdir -p "$RG_DUTY" "$RG_SPEECH"
# THE ACTIVITY THE STUBBED API SERVES, one file per PR number, `login<TAB>stamp`
# per line — the shape _resume_newest_foreign consumes. It is a FILE and not a
# variable on purpose: the call sites below wrap rg_listing in a command
# substitution, and a subshell's variables die with it while its files do not.
rg_say() {  # rg_say NUM comments|reviews [LOGIN TS]...
  local f="$RG_SPEECH/$1.$2"; shift 2
  : >"$f"
  while [ "$#" -ge 2 ]; do
    [ -n "$2" ] && printf '%s\t%s\n' "$1" "$2" >>"$f"
    shift 2
  done
  return 0
}
rg_listing() {  # rg_listing HEAD NEWEST-SELF-TS NEWEST-FOREIGN-TS BODY
  # No `comments`/`reviews` in the listing, because the engine no longer asks
  # for them: those nested connections are `first: 100` and never paginate, so
  # the foreign half is read from the paginated REST endpoints instead.
  rg_say 311 comments me "$2" other "$3"
  rg_say 311 reviews
  rg_say 999 comments
  rg_say 999 reviews
  jq -cn --arg head "$1" --arg body "$4" '[
    { number: 311, isDraft: true, headRefOid: $head, body: $body },
    { number: 999, isDraft: false, headRefOid: $head, body: "Closes #99" }
  ]'
}
RG_ISSUE_TS="2026-08-01T00:00:00Z"
RG_GH_FAIL=""   # "", "issue", "foreign" or "all"
# shellcheck disable=SC2317  # called indirectly by _resume_gate
gh() {
  # Joined FIRST: `${*##pat}` strips element-wise and only then joins, which
  # silently parsed the wrong number out of the comments URL.
  local args="$*" n kind
  case "$args" in
    */comments*|*/reviews*)
      case "$RG_GH_FAIL" in foreign|all) return 1 ;; esac
      case "$args" in */comments*) kind=comments ;; *) kind=reviews ;; esac
      n="${args##*/issues/}"; n="${n##*/pulls/}"; n="${n%%/*}"
      [ -f "$RG_SPEECH/$n.$kind" ] || return 0
      # THE PAGE BOUNDARY IS HONOURED, and that is the point of this stub. A
      # JSON fixture cannot reproduce a GraphQL connection's cap, but a REST
      # page is exactly reproducible: without `--paginate` the caller gets the
      # FIRST page and nothing after it. That makes the deep-thread cases below
      # behavioural must-fails rather than assertions about source text.
      case "$args" in
        *--paginate*) cat "$RG_SPEECH/$n.$kind" ;;
        *) head -100 "$RG_SPEECH/$n.$kind" ;;
      esac
      return 0 ;;
    *)
      case "$RG_GH_FAIL" in issue|all) return 1 ;; esac
      printf '%s\n' "$RG_ISSUE_TS" ;;
  esac
  return 0
}
# shellcheck disable=SC2031  # breaker fixtures above intentionally isolate DUTY_DIR in subshells
RG_SAVED_DUTY="$DUTY_DIR"; RG_SAVED_ME="${ME-}"; RG_ME_WAS_SET="${ME+x}"
DUTY_DIR="$RG_DUTY"; ME=me
rg_reset() { rm -f "$RG_DUTY/.seen-resume" "$RG_DUTY/.resume-zero-action.o__r"; }
rg_tick() {  # rg_tick LISTING [SESSION-RC] — one duty tick, caller side included
  # Cleared, not assumed: against a tree without the gate this keeps `set -u`
  # from taking the whole suite down, so each case below reports its own FAIL
  # rather than the run dying at the first one.
  RESUME_DISPATCH_NUMS=""; RESUME_COMMIT_LINES=""
  _resume_gate o/r o__r "$1" >"$RG_LOG" 2>&1 || true
  if [ "${2:-0}" -eq 0 ] && [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then
    printf '%s' "$RESUME_COMMIT_LINES" | ledger_commit "$RG_DUTY/.seen-resume"
  fi
}

# The pure half first: one line per DRAFT, the issue read from the body and
# never from a branch name. The foreign half is NOT here — see the block below.
t resume-fp-one-line-per-draft \
  "o/r#311@$RG_HEAD	290" \
  "$(rg_listing "$RG_HEAD" 2026-08-03T00:05:52Z 2026-08-02T19:20:37Z 'Closes #290' \
     | _resume_pr_fingerprints o/r)"
# Body forms: Refs is the post-merge citation, Part of is CROSS-repo and must
# not be mistaken for a local issue, and a body with neither degrades to the PR
# half rather than erroring.
rg_ref() { rg_listing "$RG_HEAD" T '' "$1" | _resume_pr_fingerprints o/r | cut -f2; }
t resume-fp-body-refs 314 "$(rg_ref 'Refs #314')"
t resume-fp-body-closes 290 "$(rg_ref 'Closes #290')"
t resume-fp-body-cross-repo-ignored "" "$(rg_ref 'Part of heavy-duty/crew#280')"
t resume-fp-body-bare-hash-ignored "" "$(rg_ref 'see #280 for the epic')"
t resume-fp-body-none-degrades "" "$(rg_ref 'no reference at all')"
# The word boundary: without it `discloses` ends in `closes` and this body
# declares a wake on an issue nobody named, costing a gh call every tick.
t resume-fp-body-word-boundary "" "$(rg_ref 'the operator discloses #99 in passing')"
t resume-fp-body-boundary-keeps-real-refs 290 "$(rg_ref 'and so, Closes #290')"

# THE FOREIGN HALF, at any thread length. `gh pr list --json comments,reviews`
# generates `comments(first: 100)` and does not paginate it, so reading the
# newest foreign activity from the listing froze it at the newest of the first
# hundred — measured on the incident PR itself, which is past that mark.
rg_say 311 comments me 2026-08-03T00:05:52Z other 2026-08-02T19:20:37Z
rg_say 311 reviews
t resume-nf-excludes-me 2026-08-02T19:20:37Z "$(_resume_newest_foreign o/r 311 me)"
# Nobody else has spoken: empty, which the gate floors to `0` — a stamp that
# sorts below any ISO one and keeps the ledger line at NF>=2.
rg_say 311 comments me 2026-08-03T00:05:52Z
t resume-nf-nobody-spoke "" "$(_resume_newest_foreign o/r 311 me)"
# A foreign REVIEW counts the same as a foreign comment, and comes from the
# other endpoint — the reviews connection is capped identically.
rg_say 311 comments me 2026-08-03T00:00:00Z
rg_say 311 reviews other 2026-08-02T20:00:00Z
t resume-nf-foreign-review 2026-08-02T20:00:00Z "$(_resume_newest_foreign o/r 311 me)"
# The newest wins across both endpoints, not the last one read.
rg_say 311 comments other 2026-08-04T00:00:00Z
rg_say 311 reviews other 2026-08-02T20:00:00Z
t resume-nf-newest-across-endpoints 2026-08-04T00:00:00Z "$(_resume_newest_foreign o/r 311 me)"
# THE 100-CAP REGRESSION, behavioural. 130 of my own comments, then the foreign
# one that must wake it: any lookup that reads only a first page — the capped
# listing connection, or a `per_page=1` REST read, whose `sort`/`direction` this
# endpoint ignores — answers with one of MY stamps and the draft never wakes.
: >"$RG_SPEECH/311.comments"
for _i in $(seq 1 130); do
  printf 'me\t2026-08-03T00:%02d:00Z\n' "$(( _i % 60 ))" >>"$RG_SPEECH/311.comments"
done
printf 'other\t2026-08-04T09:00:00Z\n' >>"$RG_SPEECH/311.comments"
rg_say 311 reviews
t resume-nf-past-the-hundredth 2026-08-04T09:00:00Z "$(_resume_newest_foreign o/r 311 me)"
# A lookup that FAILS is not a lookup that found nothing: nonzero, so the gate
# can say so rather than silently flooring the fingerprint.
RG_GH_FAIL=foreign
t resume-nf-failure-is-nonzero 1 "$(_resume_newest_foreign o/r 311 me >/dev/null 2>&1; echo $?)"
RG_GH_FAIL=""

# 1. THE FLOOD, reproduced and then impossible. Three consecutive ticks whose
# only new comments are the builder's own marker and checkpoint. Pre-fix this
# dispatches three times; post-fix the cold ledger dispatches once and the next
# two are suppressed and SAID (#59: stop paying, do not stop saying).
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-02T19:20:37Z '' 'Closes #290')"
t resume-gate-cold-dispatches-once 311 "$RESUME_DISPATCH_NUMS"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-02T19:25:41Z '' 'Closes #290')"
t resume-gate-self-comment-suppressed "" "$RESUME_DISPATCH_NUMS"
t resume-gate-suppression-is-logged 1 \
  "$(grep -c "no resume duty: o/r#311 unchanged at $RG_HEAD" "$RG_LOG")"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T00:05:52Z '' 'Closes #290')"
t resume-gate-self-comment-still-suppressed "" "$RESUME_DISPATCH_NUMS"
t resume-gate-suppression-logged-every-tick 1 \
  "$(grep -c "no resume duty: o/r#311 unchanged at $RG_HEAD" "$RG_LOG")"
# A non-draft PR is not this gate's business at all.
t resume-gate-ignores-non-drafts 0 "$(grep -c 'o/r#999' "$RG_LOG")"

# 2. A FOREIGN comment wakes it, and the ledger advances.
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T00:05:52Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-foreign-comment-wakes 311 "$RESUME_DISPATCH_NUMS"
t resume-gate-ledger-advanced 1 \
  "$(grep -c "^o/r#311@$RG_HEAD 2026-08-03T01:00:00Z$" "$RG_DUTY/.seen-resume")"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T02:00:00Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-foreign-comment-once "" "$RESUME_DISPATCH_NUMS"

# 3. A PUSH wakes it even when no one else has spoken. The head is in the ID,
# so this holds however the two SHAs happen to sort — the ci-red lesson (#17).
rg_tick "$(rg_listing "$RG_HEAD2" 2026-08-03T02:00:00Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-push-wakes 311 "$RESUME_DISPATCH_NUMS"

# 4. AN ISSUE-SIDE WAKE, with the PR untouched — the #311/#290 shape, where the
# wake that lifts the park lands off the PR entirely.
rg_tick "$(rg_listing "$RG_HEAD2" 2026-08-03T02:00:00Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-issue-quiet-suppressed "" "$RESUME_DISPATCH_NUMS"
RG_ISSUE_TS="2026-08-03T10:18:04Z"
rg_tick "$(rg_listing "$RG_HEAD2" 2026-08-03T02:00:00Z 2026-08-03T01:00:00Z 'Closes #290')"
t resume-gate-issue-wake-dispatches 311 "$RESUME_DISPATCH_NUMS"
# A body naming no local issue cannot be woken from the issue side, and must
# still be gated rather than erroring: the clock moves, the draft stays quiet.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T02:00:00Z '' 'no reference at all')"
t resume-gate-no-ref-cold-dispatches 311 "$RESUME_DISPATCH_NUMS"
RG_ISSUE_TS="2026-08-04T00:00:00Z"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T03:00:00Z '' 'no reference at all')"
t resume-gate-no-ref-degrades-to-pr-half "" "$RESUME_DISPATCH_NUMS"
RG_ISSUE_TS="2026-08-01T00:00:00Z"
# An issue lookup that fails degrades the same way and says so rather than
# silently pinning the fingerprint to the PR half.
RG_GH_FAIL=issue
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T '' 'Closes #290')"
t resume-gate-issue-fetch-failure-warns 1 \
  "$(grep -c 'issue #290 lookup failed for the resume fingerprint' "$RG_LOG")"
t resume-gate-issue-fetch-failure-still-dispatches 311 "$RESUME_DISPATCH_NUMS"
# So does a FOREIGN lookup that fails — and it must be its own line, because the
# two halves degrade to each other and a human reading duty.log needs to know
# which one went dark.
RG_GH_FAIL=foreign
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T '' 'Closes #290')"
t resume-gate-foreign-fetch-failure-warns 1 \
  "$(grep -c 'the foreign-activity lookup failed for the resume fingerprint' "$RG_LOG")"
t resume-gate-foreign-fetch-failure-still-dispatches 311 "$RESUME_DISPATCH_NUMS"
# A failed foreign lookup floors to `0` for the tick, which HOLDS against a
# stored stamp rather than losing the wake: the real stamp returns next tick and
# still sorts greater than what the ledger holds.
RG_GH_FAIL=""
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T01:00:00Z 'Closes #290')"
RG_GH_FAIL=foreign
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T02:00:00Z 'Closes #290')"
t resume-gate-foreign-failure-holds "" "$RESUME_DISPATCH_NUMS"
RG_GH_FAIL=""
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T02:00:00Z 'Closes #290')"
t resume-gate-foreign-failure-loses-no-wake 311 "$RESUME_DISPATCH_NUMS"

# 5. rc != 0 DOES NOT COMMIT the ledger: a session that fails re-dispatches on
# the next tick rather than losing the wake it never got to act on.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T '' 'Closes #290')" 1
t resume-gate-failed-session-dispatched 311 "$RESUME_DISPATCH_NUMS"
t resume-gate-failed-session-uncommitted 0 \
  "$(awk 'NF' "$RG_DUTY/.seen-resume" 2>/dev/null | wc -l | tr -d ' ')"
rg_tick "$(rg_listing "$RG_HEAD" T '' 'Closes #290')" 1
t resume-gate-failed-session-redispatches 311 "$RESUME_DISPATCH_NUMS"

# 6. THE BREAKER. Three consecutive dispatches at one head that produce no
# commit trip it: no fourth dispatch at that head, exactly one WARN, and a push
# resets the count to one. Foreign comments advance every tick here, so the
# ledger admits each one — this is precisely the case the ledger does NOT catch.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T01:00:00Z 'Closes #290')"
t resume-breaker-first-dispatch 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-quiet-at-one 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T02:00:00Z 'Closes #290')"
t resume-breaker-second-dispatch 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-quiet-at-two 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T03:00:00Z 'Closes #290')"
t resume-breaker-third-dispatch 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-trips-once 1 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
# The WHOLE line, not a prefix: the declared wake is the half a human reads to
# know where the park expects its signal, and a prefix match let a `:+`/`:-`
# pair that printed the issue number twice through in review.
# ANCHORED at the end, deliberately: an unanchored match is a substring match,
# and the `:+`/`:-` pair this replaced printed `o/r#290290` — which a prefix
# assertion accepts.
# It also asserts only what is OBSERVED at trip time: the third dispatch is
# going out as this fires, so two are known commitless and the third has not run.
t resume-breaker-warn-names-pr-head-count 1 \
  "$(grep -c "WARN: o/r#311: resume dispatch 3 of 3 at head ${RG_HEAD:0:12} — the previous 2 produced no commit, and after this one resume is suppressed at this head until it moves (#314); declared wake: o/r#290\$" "$RG_LOG")"
t resume-breaker-warn-claims-no-unrun-session 0 \
  "$(grep -c '3 consecutive resume dispatches' "$RG_LOG")"
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T04:00:00Z 'Closes #290')"
t resume-breaker-no-fourth-dispatch "" "$RESUME_DISPATCH_NUMS"
t resume-breaker-suppression-is-said 1 \
  "$(grep -c "breaker-suppressed at $RG_HEAD after 3 zero-action dispatches" "$RG_LOG")"
t resume-breaker-warns-only-once 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
# A push clears it: a new head is a new key, and the count starts at one.
rg_tick "$(rg_listing "$RG_HEAD2" T 2026-08-03T05:00:00Z 'Closes #290')"
t resume-breaker-push-clears-suppression 311 "$RESUME_DISPATCH_NUMS"
t resume-breaker-push-resets-count-to-one 1 \
  "$(awk -F'\t' -v k="o/r#311@$RG_HEAD2" '$1 == k {print $2}' "$RG_DUTY/.resume-zero-action.o__r")"
# A tick the LEDGER held must not reset the count: the breaker bounds
# consecutive DISPATCHES, and a quiet tick between two of them is not progress.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T01:00:00Z 'Closes #290')"
rg_tick "$(rg_listing "$RG_HEAD" T 2026-08-03T01:00:00Z 'Closes #290')"
t resume-breaker-quiet-tick-held "" "$RESUME_DISPATCH_NUMS"
t resume-breaker-quiet-tick-preserves-count 1 \
  "$(awk -F'\t' -v k="o/r#311@$RG_HEAD" '$1 == k {print $2}' "$RG_DUTY/.resume-zero-action.o__r")"
# Three ticks at DIFFERENT heads must never trip it — the must-fail case.
rg_reset
rg_tick "$(rg_listing aaa1 T 2026-08-03T01:00:00Z 'Closes #290')"
rg_tick "$(rg_listing aaa2 T 2026-08-03T02:00:00Z 'Closes #290')"
rg_tick "$(rg_listing aaa3 T 2026-08-03T03:00:00Z 'Closes #290')"
t resume-breaker-different-heads-never-trip 0 "$(grep -c 'produced no commit, and after this one' "$RG_LOG")"
t resume-breaker-different-heads-still-dispatch 311 "$RESUME_DISPATCH_NUMS"
# The state prunes: a key gone from the input (merged, closed, undrafted) does
# not accumulate forever.
t resume-breaker-state-prunes 1 "$(awk 'NF' "$RG_DUTY/.resume-zero-action.o__r" | wc -l | tr -d ' ')"

# 7. THE SUPPRESSED SET AND THE DISPATCHED SET PARTITION the draft set — no
# draft in both, none missing. The `suppressed-partitions` assertion above is
# the model; here it is asserted end to end, through the gate.
RG_TWO="$(jq -cn --arg h "$RG_HEAD" '[
  {number:1,isDraft:true,headRefOid:$h,body:""},
  {number:2,isDraft:true,headRefOid:$h,body:""}]')"
rg_reset
rg_say 1 comments; rg_say 1 reviews; rg_say 2 comments; rg_say 2 reviews
rg_tick "$RG_TWO"
# Only #2 is spoken to on the second tick, so the two sets must partition.
rg_say 2 comments other 2026-08-03T09:00:00Z
rg_tick "$RG_TWO"
t resume-gate-partition-dispatched 2 "$RESUME_DISPATCH_NUMS"
t resume-gate-partition-suppressed 1 "$(grep -c 'no resume duty: o/r#1 unchanged' "$RG_LOG")"
t resume-gate-partition-disjoint 0 "$(grep -c 'no resume duty: o/r#2 unchanged' "$RG_LOG")"

# 8. THE 100-CAP, END TO END THROUGH THE GATE. The draft is quiet on the ledger,
# and the one comment that must wake it sits past the hundredth — where the
# listing's capped connection cannot see it. This is the #311 shape after the
# flood: a builder that floods its own PR past 100 comments must not be left
# permanently unwakeable by anyone speaking on it.
rg_reset
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T00:00:00Z '' 'Closes #290')"
t resume-gate-deep-thread-cold-dispatches 311 "$RESUME_DISPATCH_NUMS"
rg_tick "$(rg_listing "$RG_HEAD" 2026-08-03T00:30:00Z '' 'Closes #290')"
t resume-gate-deep-thread-then-quiet "" "$RESUME_DISPATCH_NUMS"
: >"$RG_SPEECH/311.comments"
for _i in $(seq 1 130); do
  printf 'me\t2026-08-03T00:%02d:00Z\n' "$(( _i % 60 ))" >>"$RG_SPEECH/311.comments"
done
printf 'other\t2026-08-04T09:00:00Z\n' >>"$RG_SPEECH/311.comments"
rg_say 311 reviews
RESUME_DISPATCH_NUMS=""; RESUME_COMMIT_LINES=""
_resume_gate o/r o__r "$(jq -cn --arg h "$RG_HEAD" \
  '[{number:311,isDraft:true,headRefOid:$h,body:"Closes #290"}]')" >"$RG_LOG" 2>&1 || true
t resume-gate-wakes-past-the-hundredth 311 "$RESUME_DISPATCH_NUMS"

# 9. A BROKEN GATE FAILS OPEN AND SAYS SO. jq's stderr is no longer swallowed,
# and an unparseable listing returns nonzero so the caller keeps its pre-gate
# draft list. The alternative — empty globals, silently — is `no resume duty`
# forever with nothing warned, which is the #59 failure inside the fix for it.
rg_reset
RESUME_DISPATCH_NUMS=""; RESUME_COMMIT_LINES=""
_resume_gate o/r o__r 'not json at all' >"$RG_LOG" 2>&1
t resume-gate-broken-filter-returns-nonzero 1 "$?"
t resume-gate-broken-filter-warns 1 \
  "$(grep -c 'the resume fingerprint filter failed' "$RG_LOG")"
t resume-gate-broken-filter-commits-nothing "" "${RESUME_COMMIT_LINES//[[:space:]]/}"
DUTY_DIR="$RG_SAVED_DUTY"
if [ -n "$RG_ME_WAS_SET" ]; then ME="$RG_SAVED_ME"; else unset ME; fi
unset -f gh

# 8. THE WIRING. Helper-level tests stay green if the dispatch site stops
# routing through the ledger, which is exactly how the flood would come back.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'ledger_filter "$DUTY_DIR/.seen-resume"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq 'ledger_suppressed "$DUTY_DIR/.seen-resume"' "$SHARED/lib/duty-builder.sh"; then
  r1=gated
else
  r1=UNGATED
fi
t resume-gate-wired-through-the-ledger gated "$r1"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_resume_gate "$R" "$slug" "$resume_json"' "$SHARED/lib/duty-builder.sh"; then r1=wired; else r1=BYPASSED; fi
t resume-gate-wired-into-dispatch wired "$r1"
# The commit must stay rc-gated at the call site, not merely inside the helper.
# shellcheck disable=SC2016  # matching shell source literally
resume_commit_block="$(grep -F -A2 'if [ "${RUN_SESSION_RC:-1}" -eq 0 ] && [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then' \
       "$SHARED/lib/duty-builder.sh")"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'ledger_commit "$DUTY_DIR/.seen-resume"' <<<"$resume_commit_block"; then
  r1='rc-gated'
else
  r1=UNCONDITIONAL
fi
t resume-gate-commit-is-rc-gated rc-gated "$r1"
# THE LISTING MUST NOT CARRY THE FOREIGN HALF. `gh pr list --json comments` /
# `--json reviews` generate `first: 100` nested connections that never paginate:
# the array is oldest-first and truncated, so `max` over it freezes at the
# newest of the first hundred and the draft becomes permanently unwakeable by
# anyone speaking on it. Measured on the incident PR — the listing returns
# exactly 100 comments for heavy-duty/crew#311 while the paginated REST endpoint
# has 124. A JSON fixture cannot reproduce a GraphQL cap, so this binds at the
# shape level: the capped fields must not be requested at all.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq -- '--json number,isDraft,headRefOid,body' "$SHARED/lib/duty-builder.sh" \
  && ! grep -Fq -- '--json number,isDraft,headRefOid,comments,reviews,body' "$SHARED/lib/duty-builder.sh"; then
  r1=uncapped
else
  r1='CAPPED-LISTING'
fi
t resume-gate-listing-omits-capped-connections uncapped "$r1"
# And the fingerprint filter must not read them either, however they arrive.
if grep -Eq '\.comments|\.reviews' \
     <(sed -n '/^_resume_pr_fingerprints()/,/^}/p' "$SHARED/lib/duty-builder.sh"); then
  r1='READS-LISTING-ARRAYS'
else
  r1=clean
fi
t resume-fp-does-not-read-listing-arrays clean "$r1"
# The replacement must actually paginate. A single page of either endpoint is
# not "the newest": `sort`/`direction` are not parameters of
# `GET /repos/{owner}/{repo}/issues/{n}/comments` — they belong to the
# repo-level `/issues/comments` list — so GitHub ignores them and a `per_page=1`
# read returns the OLDEST comment. Verified live on heavy-duty/crew#311.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq -- '--paginate "repos/$repo/issues/$num/comments?per_page=100"' \
     "$SHARED/lib/duty-builder.sh" \
  && grep -Fq -- '--paginate "repos/$repo/pulls/$num/reviews?per_page=100"' \
     "$SHARED/lib/duty-builder.sh"; then
  r1=paginated
else
  r1='SINGLE-PAGE'
fi
t resume-nf-lookup-is-paginated paginated "$r1"
# A gate that cannot run must not become a silent stall: the caller keeps its
# pre-gate draft list when _resume_gate returns nonzero (#59).
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'if _resume_gate "$R" "$slug" "$resume_json"; then' "$SHARED/lib/duty-builder.sh"; then
  r1='fails-open'
else
  r1='FAILS-CLOSED'
fi
t resume-gate-failure-fails-open fails-open "$r1"

# 9. THE PROMPT AND THE DOCTRINE STATE THE SAME RULE. The prompt must carry no
# instruction to comment that is unconditional on the session acting — a parked
# builder cannot obey both halves of a fork, and #311's builder correctly obeyed
# the prompt.
RG_PROMPT="$SHARED/prompts/resume.txt"
if grep -Fq 'For each draft PR: post one comment' "$RG_PROMPT"; then
  r1=UNCONDITIONAL
else
  r1=conditional
fi
t resume-prompt-marker-not-unconditional conditional "$r1"
if grep -Fq 'ONLY WHEN YOU ARE GOING TO ACT' "$RG_PROMPT" \
  && grep -Fq 'POST NOTHING AT ALL' "$RG_PROMPT"; then r1=gated; else r1=MISSING; fi
t resume-prompt-marker-gated-on-acting gated "$r1"
# The doctrine sentences themselves, quoted rather than paraphrased, so the
# two files can be read side by side.
#
# Compared on whitespace-NORMALISED text, never line by line. `.ceremony/` is
# machine-written by `docs-sync --fix` at whatever pin is vendored, so its
# prose REWRAPS on a bump that changes no word — and a line-based `grep -Fq`
# reads that rewrap as a divergence. That is half of how the 0.6.0 re-vendor
# reddened main (#363): the sentence had moved across a line break as well as
# changed wording, so re-syncing the prompt alone would still have failed here
# and invited the assertion to be gutted instead. Normalising costs nothing and
# leaves the real contract — same words, both files — exactly as strict.
# This clause stops before the Markdown emphasis around the preceding words.
assert_doctrine_quote "$RG_PROMPT" \
  'a resumption finding nothing changed posts nothing' \
  resume-prompt-quotes-the-doctrine
# This clause stops before the Markdown emphasis around `no open PR`.
assert_doctrine_quote "$RG_PROMPT" \
  'Each change owes one comment — the wait resolves or changes hands, the shape changes, the claim unparks.' \
  resume-prompt-quotes-each-change-doctrine
# The prompt citation includes its prose context, while the doctrine side must
# be the exact heading; neither asserted substring contains emphasis syntax.
assert_doctrine_quote "$RG_PROMPT" 'under Claiming:' \
  resume-prompt-cites-claiming-heading '## Claiming'

# Count every direct BUILDER doctrine slot in every prompt. In resume.txt the
# four occurrences are: bare opening reference; quotation attribution for the
# declaration/Claiming passage; bare acceptance reference; quotation
# attribution for the draft-flip passage. build.txt's two occurrences are bare
# governing/acceptance references. fragment-round-rules.txt's two occurrences
# are bare green-head/panel references. attention.txt, ci-red.txt,
# fragment-floor-envelope.txt, fragment-oneshot-rules.txt,
# fragment-unblockable.txt, fragment-wt-rules.txt, hygiene.txt, mention.txt,
# rebase.txt, review.txt, and triage.txt contain no direct occurrence.
declare -A doctrine_builder_occurrences=(
  [attention.txt]=0 [build.txt]=2 [ci-red.txt]=0
  [fragment-floor-envelope.txt]=0 [fragment-oneshot-rules.txt]=0
  [fragment-round-rules.txt]=2 [fragment-unblockable.txt]=0
  [fragment-wt-rules.txt]=0 [hygiene.txt]=0 [mention.txt]=0
  [rebase.txt]=0 [resume.txt]=4 [review.txt]=0 [triage.txt]=0
)
for doctrine_prompt in "$SHARED"/prompts/*.txt; do
  doctrine_prompt_name="$(basename "$doctrine_prompt")"
  doctrine_actual_count="$(grep -oF '{{DOCTRINE_BUILDER}}' "$doctrine_prompt" | wc -l)"
  t "doctrine-builder-occurrences-$doctrine_prompt_name" \
    "${doctrine_builder_occurrences[$doctrine_prompt_name]-UNCLASSIFIED}" \
    "$doctrine_actual_count"
done

# --- #384: three stuck states the resume gate could not leave ----------------
# A session finished a fix round on PR #381, pushed d4b8035, and parked waiting
# for `ci-floor` before signalling. `ci-floor` went green at ~07:52Z; the session
# was still parked at 08:38Z and the operator unstuck it by hand. There was no
# wake to be had: `_resume_newest_foreign` paginates comments and reviews, and a
# check conclusion is neither, so nothing in the fingerprint could move.
#
# These fixtures are that timeline, plus PR #386's — a ready, green, correctly
# signalled PR converted to draft six seconds into the request pass, which the
# handoff listing then skipped and the resume ledger then suppressed.
P384_HEAD=d4b8035d4b8035d4b8035d4b8035d4b8035d4b80
P384_OLD=aa11bb22aa11bb22aa11bb22aa11bb22aa11bb22
P384_START=2026-08-06T07:41:19Z
P384_DONE=2026-08-06T07:52:18Z
p384_run() {  # p384_run CONCLUSION [COMPLETED] — one CheckRun in a rollup
  # The jq arg is `fin`, not `done`: shellcheck reads a bare `done` after --arg
  # as the loop keyword and warns (SC1010), and ci-shell runs it without a
  # severity floor, so a warning is a red job.
  #
  # THE RUNNING SHAPE IS `gh`'s, NOT A TIDIED ONE. A running CheckRun comes back
  # with `conclusion:""` and Go's ZERO TIME in `completedAt` — neither key is
  # ever absent, live on nodejs/node:
  #   {"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z",
  #    "conclusion":"","name":"coverage-windows","status":"IN_PROGRESS",...}
  # The first cut of this fixture omitted both, which is the only reason a
  # `completedAt != ""` test for "has concluded" passed here while fabricating a
  # stamp on every real running check (#391 round 2, claude).
  jq -cn --arg c "$1" --arg fin "${2:-}" --arg started "$P384_START" \
    '[{__typename:"CheckRun", name:"ci-floor", workflowName:"ci-floor",
       status:(if $c == "" then "IN_PROGRESS" else "COMPLETED" end),
       conclusion:$c, startedAt:$started,
       completedAt:(if $fin == "" then "0001-01-01T00:00:00Z" else $fin end)}]'
}
P384_ZERO_TIME=0001-01-01T00:00:00Z
P384_GREEN="$(p384_run SUCCESS "$P384_DONE")"
P384_PENDING="$(p384_run "" "")"
P384_RED="$(p384_run FAILURE "$P384_DONE")"
p384_pr() {  # p384_pr NUM DRAFT ROLLUP SIGNAL-SHA REQUESTED-JSON
  jq -cn --argjson num "$1" --argjson draft "$2" --argjson roll "$3" \
    --arg head "$P384_HEAD" --arg sig "$4" --argjson req "${5:-[]}" \
    '{number:$num, isDraft:$draft, headRefOid:$head, body:"Closes #290",
      statusCheckRollup:$roll, reviewRequests:$req,
      comments:(if $sig == "" then []
                else [{author:{login:"me"}, body:("ANSWER " + $sig),
                       createdAt:"2026-08-06T07:39:00Z", id:"9001"}] end)}'
}

# 1. THE CONCLUSION STAMP. A CheckRun contributes only once it has finished, so
# a running check is no stamp at all — reading `startedAt` here would move the
# fingerprint when CI STARTS, which is the tick the session is still working
# through rather than the one it is waiting for.
P384_ONE="$(jq -cn --argjson pr "$(p384_pr 381 true "$P384_GREEN" '' )" '[$pr]')"
t p384-check-stamp-is-the-conclusion "$P384_DONE" "$(_resume_newest_check "$P384_ONE" 381)"
P384_RUNNING="$(jq -cn --argjson pr "$(p384_pr 381 true "$P384_PENDING" '')" '[$pr]')"
t p384-running-check-has-no-stamp "" "$(_resume_newest_check "$P384_RUNNING" 381)"
t p384-running-check-does-not-leak-startedAt 0 \
  "$(_resume_newest_check "$P384_RUNNING" 381 | grep -c "$P384_START")"
# …and does not leak the ZERO TIME either. `completedAt` is present-but-zero
# while a check runs, so "has concluded" is `.status == "COMPLETED"` and not a
# non-empty string. The three assertions above are one contract read three ways:
# a running check contributes NOTHING, neither a real start nor a fabricated
# end. A fabricated one sorts below every genuine stamp so it would never mask a
# conclusion — but it displaces the documented `0` floor, and the floor is what
# the gate's own comment promises a reader.
t p384-running-check-does-not-leak-the-zero-time 0 \
  "$(_resume_newest_check "$P384_RUNNING" 381 | grep -c "$P384_ZERO_TIME")"
t p384-running-fixture-carries-the-zero-time 1 \
  "$(printf '%s' "$P384_RUNNING" | grep -c "$P384_ZERO_TIME")"
# A RED check has concluded, and its stamp counts: the fingerprint's job is to
# say the head answered, not that it passed. Whether green or red is the
# due-predicates' question, two blocks down.
P384_FAILED="$(jq -cn --argjson pr "$(p384_pr 381 true "$P384_RED" '')" '[$pr]')"
t p384-red-check-still-concludes "$P384_DONE" "$(_resume_newest_check "$P384_FAILED" 381)"
# The NEWEST across several checks, not the last one read.
P384_MANY="$(jq -cn --arg h "$P384_HEAD" '[{number:381,isDraft:true,headRefOid:$h,body:"",
  reviewRequests:[],comments:[],statusCheckRollup:[
    {__typename:"CheckRun",name:"a",status:"COMPLETED",conclusion:"SUCCESS",
     startedAt:"2026-08-06T07:00:00Z",completedAt:"2026-08-06T07:10:00Z"},
    {__typename:"CheckRun",name:"b",status:"COMPLETED",conclusion:"SUCCESS",
     startedAt:"2026-08-06T07:00:00Z",completedAt:"2026-08-06T07:52:18Z"}]}]')"
t p384-check-stamp-is-the-newest "$P384_DONE" "$(_resume_newest_check "$P384_MANY" 381)"
# A StatusContext has no completedAt at all, so its start stands in — but only
# where its state is TERMINAL. A PENDING context's stamp is when the wait began,
# and the rollup mixes the two shapes (head-checks.jq's header).
#
# THE KEY IS `startedAt`, WHICH GITHUB'S SCHEMA DOES NOT HAVE. `gh` requests
# StatusContext.createdAt and serialises it under its own `startedAt`, so
# `createdAt` never reaches a caller of `gh pr list --json statusCheckRollup`.
# Live on python/cpython:
#   {"__typename":"StatusContext","context":"CLA Signing",
#    "startedAt":"2026-08-06T15:09:40Z","state":"SUCCESS","targetUrl":""}
# The first cut of this fixture fabricated `createdAt`, so it passed against a
# shape that does not occur while the branch was dead against every real rollup
# — met for a repo whose checks are CheckRuns, crew's own among them, and unmet
# exactly where a legacy status concludes. That is head-checks.jq's #50 (its
# header, and `head-status-context-failure` above) transposed from grading to
# stamping, which is why this fixture is now `gh`'s output key for key
# (#391 round 2, codex and claude).
P384_CTX="$(jq -cn --arg h "$P384_HEAD" --arg s "$P384_DONE" '[{number:381,isDraft:true,
  headRefOid:$h,body:"",reviewRequests:[],comments:[],
  statusCheckRollup:[{__typename:"StatusContext",context:"legacy",state:"SUCCESS",
                      startedAt:$s,targetUrl:""}]}]')"
t p384-status-context-concludes "$P384_DONE" "$(_resume_newest_check "$P384_CTX" 381)"
# The negative was VACUOUS before the fix — there was no `createdAt` for the
# terminal-state gate to reject, so it could not fail. It is a real assertion
# for the first time here.
P384_CTX_WAIT="$(printf '%s' "$P384_CTX" | jq -c '.[0].statusCheckRollup[0].state = "PENDING" | .')"
t p384-pending-status-context-has-no-stamp "" "$(_resume_newest_check "$P384_CTX_WAIT" 381)"
# The `//` form, not a bare swap to `.startedAt`: `head-checks.jq`'s own idiom
# in `latest_checks`, so a fleet box whose `gh` serialises GitHub's key
# unrenamed still stamps rather than going quietly dead a second time.
P384_CTX_CREATED="$(printf '%s' "$P384_CTX" \
  | jq -c '.[0].statusCheckRollup[0] |= (.createdAt = .startedAt | del(.startedAt))')"
t p384-status-context-createdAt-still-concludes "$P384_DONE" \
  "$(_resume_newest_check "$P384_CTX_CREATED" 381)"
# No checks configured is not a conclusion either; the gate floors it to `0`.
P384_NOCI="$(jq -cn --argjson pr "$(p384_pr 381 true '[]' '')" '[$pr]')"
t p384-no-checks-no-stamp "" "$(_resume_newest_check "$P384_NOCI" 381)"
# A lookup that FAILED is not a lookup that found nothing — the
# _resume_newest_foreign contract, so the gate can warn rather than silently
# flooring a half it could not read.
t p384-check-lookup-failure-is-nonzero 1 \
  "$(_resume_newest_check "$P384_ONE" 999 >/dev/null 2>&1; echo $?)"

# MUST FAIL — a rollup fixture that is not the shape `gh` emits. Both halves of
# the round-2 defect were fixtures, not code: the code was a correct reading of
# a rollup nobody receives, and every test above passed against it. crew's own
# CI is a single CheckRun, so this repo's CI can never catch either one — the
# same reason head-checks.jq keeps `SC_BAD` and says so in its header. That
# makes a shape guard the only thing standing between this class and its next
# recurrence, and it is asserted on the fixtures as DATA rather than by reading
# the source, so a fixture built by transform is covered like a literal one.
p384_shape_lies() {  # p384_shape_lies ROLLUP — count nodes lying about `gh`
  printf '%s' "$1" | jq '[ .[] | select(
      # `gh` renames StatusContext.createdAt to `startedAt` on the way out, so a
      # fixture carrying createdAt is asserting against a shape that never
      # arrives — the dead branch, exactly.
      (.__typename == "StatusContext" and has("createdAt"))
      # A running CheckRun carries a present-but-zero completedAt, so a fixture
      # omitting the key lets a non-empty test for "has concluded" pass here and
      # fabricate a stamp in production — the half claude found, exactly.
      or (.__typename == "CheckRun" and (.status // "") != "COMPLETED"
          and ((has("completedAt") and .completedAt != null) | not))
    )] | length'
}
p384_rollup_of() { printf '%s' "$1" | jq -c '.[0].statusCheckRollup'; }
t p384-fixture-shape-green 0 "$(p384_shape_lies "$P384_GREEN")"
t p384-fixture-shape-pending 0 "$(p384_shape_lies "$P384_PENDING")"
t p384-fixture-shape-red 0 "$(p384_shape_lies "$P384_RED")"
t p384-fixture-shape-many 0 "$(p384_shape_lies "$(p384_rollup_of "$P384_MANY")")"
t p384-fixture-shape-status-context 0 "$(p384_shape_lies "$(p384_rollup_of "$P384_CTX")")"
t p384-fixture-shape-pending-status-context 0 \
  "$(p384_shape_lies "$(p384_rollup_of "$P384_CTX_WAIT")")"
t p384-fixture-shape-collision 0 "$(p384_shape_lies "$SC_COLLISION_STATUS_LAST")"
# The guard catches the shapes this round shipped broken, or it is decoration.
t p384-shape-guard-catches-status-createdAt 1 \
  "$(p384_shape_lies "$(p384_rollup_of "$P384_CTX_CREATED")")"
t p384-shape-guard-catches-running-without-completedAt 1 \
  "$(p384_shape_lies "$(printf '%s' "$P384_PENDING" | jq -c 'map(del(.completedAt))')")"
# `P384_CTX_CREATED` is the ONE fixture that carries createdAt on purpose — it
# asserts the `//` fallback for a `gh` that does not rename the field — so it is
# named here rather than exempted quietly, and the assertion above is that the
# guard does see it. Every other fixture in this file is `gh`'s shape, which a
# literal scan says in one line and independently of the list above.
# The pattern is split across two lines on purpose: written whole it would
# match ITSELF and the guard would red on its own source.
P384_SC_LITERAL='__typename":"StatusContext"'
t p384-no-fixture-fabricates-status-createdAt 0 \
  "$(grep -c "$P384_SC_LITERAL"'.*createdAt":' "$SHARED/test/run.sh")"

# 2. THE CHECK STATE, graded through head-checks.jq and never restated here.
t p384-state-green "$(printf '381\tgreen')" "$(_resume_check_states o/r "$P384_ONE")"
t p384-state-pending "$(printf '381\tpending')" "$(_resume_check_states o/r "$P384_RUNNING")"
t p384-state-red "$(printf '381\tred')" "$(_resume_check_states o/r "$P384_FAILED")"
# Drafts are graded too, which head-checks.jq alone will not do — the flip-owed
# predicate's whole subject is a draft.
t p384-state-grades-drafts 1 "$(_resume_check_states o/r "$P384_ONE" | grep -c green)"
t p384-state-unreadable-is-nonzero 1 \
  "$(_resume_check_states o/r 'not json' >/dev/null 2>&1; echo $?)"
# MUST FAIL — a second copy of the green whitelist in this module. `is_green`
# is fail-closed by construction (#64) and a restatement of it here would be a
# second predicate that drifts the first time GitHub adds a conclusion.
t p384-green-is-not-restated-in-the-engine 0 \
  "$(grep -c 'SUCCESS.*NEUTRAL.*SKIPPED' "$SHARED/lib/duty-builder.sh")"

# 3. THE GREEN-HEAD DUE-PREDICATE. Its evidence is a check conclusion where
# #319's is a near-miss comment, and it reaches the same conclusion from it: the
# checks have finished, the head is passing, and there is nothing left to wait
# for, so the twelve ticks are no longer buying information.
P384_GH_LISTING="$(jq -cn \
  --argjson a "$(p384_pr 381 false "$P384_GREEN" '')" \
  --argjson b "$(p384_pr 382 false "$P384_PENDING" '')" \
  --argjson c "$(p384_pr 383 false "$P384_RED" '')" \
  --argjson d "$(p384_pr 384 false "$P384_GREEN" "$P384_HEAD")" \
  --argjson e "$(p384_pr 385 false "$P384_GREEN" "$P384_OLD")" \
  --argjson f "$(p384_pr 386 true "$P384_GREEN" '')" \
  --argjson g "$(p384_pr 387 false '[]' '')" \
  '[$a,$b,$c,$d,$e,$f,$g] | map(if .number == 388 then . else . end)')"
# #388: a thread that could not be read is not an empty thread.
P384_GH_LISTING="$(printf '%s' "$P384_GH_LISTING" | jq -c \
  --argjson h "$(p384_pr 388 false "$P384_GREEN" '')" '. + [$h | .comments = null]')"
_green_head_resume_rows o/r me ANSWER "$P384_GH_LISTING" >"$TMP/p384-green.log" 2>&1
p384_gh_out="$(cat "$TMP/p384-green.log")"
# 381 and 385 alone. 382 is PENDING and 383 is RED — the measured twelve-tick
# case, untouched; 384 signalled its current head; 386 is a draft (the draft
# path owns it); 387 has no checks configured, which is not green; 388's thread
# could not be read.
p384_gh_nums="$(printf '%s' "$GREEN_HEAD_ROWS" | awk -F'\t' 'NF{print $1}')"
t p384-green-head-rows "$(printf '381\n385')" "$p384_gh_nums"
# MUST FAIL, one per line — these are the regressions, and each is its own
# assertion so a failure names which guarantee broke rather than "the set moved".
t p384-pending-head-still-waits-twelve 0 "$(grep -c '^382$' <<<"$p384_gh_nums")"
t p384-red-head-still-waits-twelve 0 "$(grep -c '^383$' <<<"$p384_gh_nums")"
t p384-correct-signal-is-never-resumed 0 "$(grep -c '^384$' <<<"$p384_gh_nums")"
t p384-draft-is-not-this-predicates-business 0 "$(grep -c '^386$' <<<"$p384_gh_nums")"
t p384-no-checks-is-not-green 0 "$(grep -c '^387$' <<<"$p384_gh_nums")"
t p384-unread-thread-is-not-a-detection 0 "$(grep -c '^388$' <<<"$p384_gh_nums")"
# A signal naming a SUPERSEDED head is no signal at this head: 385 is due.
t p384-stale-signal-is-still-unsignalled 1 "$(grep -c '^385$' <<<"$p384_gh_nums")"
# THE HEAD RIDES WITH THE NUMBER, from this read and not a second one: the
# caller builds the breaker's `<repo>#<num>@<head>` key out of this row, and two
# reads of the listing are two chances to key a count to the wrong head.
t p384-green-row-carries-the-head "$(printf '381\t%s\n385\t%s' "$P384_HEAD" "$P384_HEAD")" \
  "$(printf '%s' "$GREEN_HEAD_ROWS" | awk 'NF')"
# EXACTLY ONE WARN per detection, naming the head in full and the reason.
t p384-green-warns-once-per-detection 2 "$(grep -c 'WARN' <<<"$p384_gh_out")"
t p384-green-warn-names-the-head 2 "$(grep -c "green and no signal names that head" <<<"$p384_gh_out")"
t p384-green-warn-carries-the-full-sha 2 "$(grep -c "$P384_HEAD" <<<"$p384_gh_out")"
t p384-green-warn-names-the-pr 1 "$(grep -c 'WARN.*o/r#381' <<<"$p384_gh_out")"
# DETECTION DOES NOT PROMISE A DISPATCH. Whether this tick actually resumes is
# the breaker's answer, said at the breaker's site — so the detection WARN must
# not carry the old "so resuming this tick instead of the twelfth" tail, which
# would be a claim this function cannot make once a bypass can be suppressed.
t p384-green-warn-does-not-promise-a-dispatch 0 \
  "$(grep -c 'resuming this tick' <<<"$p384_gh_out")"
# The bypass ADDS a reason to be due and removes none: both PRs it named are
# still stranded the ordinary way, their counters advancing exactly as before,
# and so are the three it declined to name. Five in total — 384 signalled its
# head, 386 is a draft and 388's thread could not be read, and none of those
# three was ever stranded.
t p384-green-bypassed-are-still-stranded "$(printf 'o/r#381@%s\no/r#385@%s' \
    "$P384_HEAD" "$P384_HEAD")" \
  "$(printf '%s' "$P384_GH_LISTING" | _stranded_resume_keys o/r me ANSWER \
     | grep -E '#(381|385)@')"
t p384-green-declined-are-still-stranded "$(printf 'o/r#382@%s\no/r#383@%s\no/r#387@%s' \
    "$P384_HEAD" "$P384_HEAD" "$P384_HEAD")" \
  "$(printf '%s' "$P384_GH_LISTING" | _stranded_resume_keys o/r me ANSWER \
     | grep -E '#(382|383|387)@')"
t p384-green-strands-nothing-new 5 \
  "$(printf '%s' "$P384_GH_LISTING" | _stranded_resume_keys o/r me ANSWER | wc -l | tr -d ' ')"
# FAIL-SOFT: a rollup that cannot be graded warns and leaves every PR out for
# the tick. It must NEVER fabricate a green — the whole predicate is an
# assertion about evidence, and inventing the evidence inverts it.
_green_head_resume_rows o/r me ANSWER 'not json' >"$TMP/p384-green-fail.log" 2>&1
t p384-green-ungradeable-detects-nothing "" "$(printf '%s' "$GREEN_HEAD_ROWS" | awk 'NF')"
t p384-green-ungradeable-warns 1 \
  "$(grep -c 'check rollup could not be graded' "$TMP/p384-green-fail.log")"

# 3b. THE GREEN-HEAD BOUND. Detection above answers "is this PR due"; the
# breaker answers "how many times may being due buy a session before the
# evidence is that the sessions produce nothing". The predicate holds no state
# of its own, so unbounded it would name the same PR every tick for as long as
# the head stood — a resume session every five minutes, indefinitely, which is
# the #314 flood re-entering through the door built to end it. That is this
# PR's own argument for bounding the flip-owed lane, and it is no weaker here:
# "non-draft, green head, no signal at that head" is a shape every PR passes
# through on the ordinary path between CI concluding and its builder signalling.
P384_GB="$TMP/p384-green-breaker"; P384_GB_LOG="$TMP/p384-green-breaker.log"
mkdir -p "$P384_GB"
P384_GB_SAVED_DUTY="$DUTY_DIR"; DUTY_DIR="$P384_GB"
p384_gb_tick() {  # p384_gb_tick ROWS — one tick of the bypass, caller side
  GREEN_HEAD_DISPATCH_NUMS=""
  _green_head_breaker o/r o__r "$1" >"$P384_GB_LOG" 2>&1 || true
}
P384_GB_ROWS="$(printf '381\t%s\n' "$P384_HEAD")"
for _p384_i in 1 2 3; do
  p384_gb_tick "$P384_GB_ROWS"
  t "p384-green-bypass-dispatch-$_p384_i" 381 "$GREEN_HEAD_DISPATCH_NUMS"
done
t p384-green-bypass-dispatch-is-said 1 \
  "$(grep -c "green head owed a signal .* dispatch 3 of 3 at $P384_HEAD" "$P384_GB_LOG")"
# The trip fires as the THIRD dispatch goes out and asserts only what is
# observed — the previous two produced nothing; the third has not run yet.
t p384-green-bypass-trips-once 1 \
  "$(grep -c 'the previous 2 produced no signal' "$P384_GB_LOG")"
# AND NO FOURTH. This is the assertion the round asked for.
p384_gb_tick "$P384_GB_ROWS"
t p384-green-bypass-no-fourth-dispatch "" "$GREEN_HEAD_DISPATCH_NUMS"
t p384-green-bypass-suppression-is-said 1 \
  "$(grep -c "green-head bypass suppressed at $P384_HEAD after 3 zero-action dispatches" "$P384_GB_LOG")"
# SUPPRESSION ENDS THE BYPASS, NOT THE PR'S CLAIM ON RESUME: the twelve-tick
# counter is a different lane with a different state file, and the suppression
# line says so rather than leaving a reader to infer the PR was abandoned.
t p384-green-bypass-suppression-names-the-other-lane 1 \
  "$(grep -c 'the twelve-tick counter still runs' "$P384_GB_LOG")"
# A PUSH ENDS THE EPISODE, with no separate observation of "produced no commit":
# the head is in the key, so a moved head is a key never seen.
p384_gb_tick "$(printf '381\t%s\n' "$P384_OLD")"
t p384-green-bypass-push-resets 381 "$GREEN_HEAD_DISPATCH_NUMS"
t p384-green-bypass-count-restarts-at-one 1 \
  "$(awk -F'\t' -v k="o/r#381@$P384_OLD" '$1 == k {print $2}' "$P384_GB/.resume-zero-action-green.o__r")"
t p384-green-bypass-prunes-the-old-head 0 \
  "$(grep -c "@$P384_HEAD" "$P384_GB/.resume-zero-action-green.o__r")"
# THE TWO LANES DO NOT SHARE A STATE FILE, and this is why. _resume_breaker
# rebuilds its state from stdin alone and `mv`s it into place, so keys absent
# from a call are pruned (`resume-breaker-state-prunes` pins it deliberately).
# Two call sites on one file would therefore erase each other's counters every
# tick — the gate's drafts are not in the bypass's stdin, and the bypass's PRs
# are not in the gate's. Written through _resume_breaker itself, so this is the
# gate's own state file in the gate's own format.
printf 'o/r#999@%s\tfresh\n' "$P384_HEAD" \
  | _resume_breaker "$P384_GB/.resume-zero-action.o__r" 3 >/dev/null
p384_gb_tick "$(printf '381\t%s\n' "$P384_OLD")"
t p384-green-bypass-leaves-the-gate-counters 1 \
  "$(awk -F'\t' -v k="o/r#999@$P384_HEAD" '$1 == k {print $2}' "$P384_GB/.resume-zero-action.o__r")"
t p384-green-bypass-keeps-its-own-count 2 \
  "$(awk -F'\t' -v k="o/r#381@$P384_OLD" '$1 == k {print $2}' "$P384_GB/.resume-zero-action-green.o__r")"
# A QUIET TICK DISPATCHES NOTHING AND RESETS NOTHING. The count is of
# consecutive DISPATCHES, not consecutive ticks — the breaker's own rule — so a
# tick with no rows returns early rather than rebuilding an empty state file.
p384_gb_tick ""
t p384-green-bypass-quiet-tick-is-empty "" "$GREEN_HEAD_DISPATCH_NUMS"
t p384-green-bypass-quiet-tick-keeps-the-count 2 \
  "$(awk -F'\t' -v k="o/r#381@$P384_OLD" '$1 == k {print $2}' "$P384_GB/.resume-zero-action-green.o__r")"
DUTY_DIR="$P384_GB_SAVED_DUTY"
unset -f p384_gb_tick

# 4. THE FLIP-OWED DUE-PREDICATE — the terminal state neither path can leave.
# PR #386 was ready, green and correctly signalled when it was converted to
# draft six seconds into the request pass. The request path stopped seeing it
# (the handoff listing is `select(.isDraft | not)`) and the resume ledger
# suppressed it (unchanged head, nobody foreign spoke). Both correct; together a
# hole, and no panel was ever requested.
P384_PANEL='["p1","p2"]'
P384_SIG_AT=2026-08-06T09:54:56Z
# The verdicts the stubbed GraphQL serves, one file per PR — a FILE for the same
# reason the #314 block's speech files are: the call sites wrap this in a command
# substitution and a subshell's variables die with it.
P384_GQL="$TMP/p384-gql"; mkdir -p "$P384_GQL"
p384_verdicts() {  # p384_verdicts NUM REQUESTED-JSON REVIEWS-JSON
  jq -cn --argjson req "$2" --argjson rev "$3" \
    '{requested:$req, reviews:$rev}' >"$P384_GQL/$1"
}
p384_review() {  # p384_review LOGIN STATE SUBMITTED [OID]
  jq -cn --arg l "$1" --arg s "$2" --arg at "$3" --arg oid "${4:-$P384_HEAD}" \
    '{author:{login:$l}, state:$s, submittedAt:$at, commit:{oid:$oid}}'
}
# shellcheck disable=SC2317  # called indirectly by _flip_owed_resume_rows
gh() {
  local args="$*" n f
  n="${args##*num=}"; n="${n%% *}"
  f="$P384_GQL/$n"
  [ -f "$f" ] || return 1
  jq -cn --arg head "$P384_HEAD" --arg sig "$P384_HEAD" --arg at "$P384_SIG_AT" \
    --argjson v "$(cat "$f")" \
    '{data:{repository:{pullRequest:{
        headRefOid:$head,
        comments:{nodes:[{author:{login:"me"}, body:("ANSWER " + $sig), createdAt:$at}]},
        reviewRequests:{nodes:($v.requested | map({requestedReviewer:{login:.}}))},
        latestOpinionatedReviews:{nodes:$v.reviews}}}}}'
}
p384_verdicts 386 '[]' '[]'
p384_verdicts 387 '["p1"]' '[]'
p384_verdicts 388 '[]' '[]'
p384_verdicts 389 '[]' '[]'
p384_verdicts 390 '[]' '[]'
p384_verdicts 391 '[]' '[]'
p384_verdicts 392 '["advisory-bot"]' '[]'
# 393 is the case that rewrote this predicate: a draft the ENGINE made, because
# a round closed against its author (_redraft_authored_pr), whose thread still
# carries the signal that opened that round. Both panelists answered it with
# CHANGES_REQUESTED at this head AFTER it was posted, and GitHub drops a
# change-requester from requested_reviewers in the same instant — so "nobody is
# on reviewRequests" is true of it, and it owes a ROUND REPLY, not a flip.
p384_verdicts 393 '[]' "$(jq -cn --argjson a "$(p384_review p1 CHANGES_REQUESTED 2026-08-06T10:30:00Z)" \
  --argjson b "$(p384_review p2 CHANGES_REQUESTED 2026-08-06T10:31:00Z)" '[$a,$b]')"
# 394 is its control: the same shape with the verdicts PRECEDING the signal, so
# the signal answers them and the panel is owed a re-read. #286's ordering rule,
# reached through request-panel.jq rather than restated here.
p384_verdicts 394 '[]' "$(jq -cn --argjson a "$(p384_review p1 CHANGES_REQUESTED 2026-08-06T09:00:00Z)" \
  --argjson b "$(p384_review p2 CHANGES_REQUESTED 2026-08-06T09:01:00Z)" '[$a,$b]')"
# 395: the whole panel already APPROVES this head. Nothing is owed of anyone, so
# nothing is requestable and this is a converged draft, not a stranded one.
p384_verdicts 395 '[]' "$(jq -cn --argjson a "$(p384_review p1 APPROVED 2026-08-06T10:30:00Z)" \
  --argjson b "$(p384_review p2 APPROVED 2026-08-06T10:31:00Z)" '[$a,$b]')"
P384_FO_LISTING="$(jq -cn \
  --argjson a "$(p384_pr 386 true "$P384_GREEN" "$P384_HEAD")" \
  --argjson b "$(p384_pr 387 true "$P384_GREEN" "$P384_HEAD" '[{"login":"p1"}]')" \
  --argjson c "$(p384_pr 388 true "$P384_GREEN" '')" \
  --argjson d "$(p384_pr 389 true "$P384_PENDING" "$P384_HEAD")" \
  --argjson e "$(p384_pr 390 false "$P384_GREEN" "$P384_HEAD")" \
  --argjson f "$(p384_pr 391 true "$P384_GREEN" "$P384_OLD")" \
  --argjson g "$(p384_pr 392 true "$P384_GREEN" "$P384_HEAD" '[{"login":"advisory-bot"}]')" \
  --argjson h "$(p384_pr 393 true "$P384_GREEN" "$P384_HEAD")" \
  --argjson i "$(p384_pr 394 true "$P384_GREEN" "$P384_HEAD")" \
  --argjson j "$(p384_pr 395 true "$P384_GREEN" "$P384_HEAD")" \
  '[$a,$b,$c,$d,$e,$f,$g,$h,$i,$j]')"
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_FO_LISTING" >"$TMP/p384-flip.log" 2>&1
p384_fo_out="$(cat "$TMP/p384-flip.log")"
# 386, 392 and 394. 387 has a PANELIST requested, so the round is live and the
# move is someone else's. 388 carries no signal at all — ordinary interrupted
# work on its existing path. 389's head is pending. 390 is not a draft, so the
# request path can see it. 391's signal names a superseded head. 392's only
# requested reviewer is OFF-panel, which BUILDER.md rules advisory and never the
# ask. 393's signal was SPENT by the verdicts that answered it. 395 is converged.
t p384-flip-owed-rows "$(printf '386\n392\n394')" "$(printf '%s' "$FLIP_OWED_ROWS" | awk 'NF')"
# 387 is deliberately PARTLY requested — p1 asked, p2 not. request-panel.jq
# still names p2 there, which is why the "nobody was ever asked" gate is its own
# test and not folded into that predicate: a panelist already reading the tree
# is a live round, and the next move is theirs rather than resume's.
t p384-requested-panelist-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^387$')"
t p384-unsignalled-draft-is-untouched 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^388$')"
t p384-pending-draft-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^389$')"
t p384-non-draft-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^390$')"
t p384-stale-signal-draft-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^391$')"
t p384-advisory-reviewer-is-not-the-ask 1 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^392$')"
# MUST FAIL, and it is why this predicate asks request-panel.jq instead of
# reading `reviewRequests` itself. A draft the ENGINE redrafted over a closed
# round has no panelist requested and a current-head signal on its thread, so
# the obvious predicate names it — and the session would then be told to mark an
# UNANSWERED round ready-for-review. The spent-signal rule (#286) is what parts
# it from #386, and 394 next door proves the rule is the ordering and not merely
# "any verdict at the head".
t p384-spent-signal-draft-is-not-owed-a-flip 0 \
  "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^393$')"
t p384-answered-verdicts-are-still-owed-a-panel 1 \
  "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^394$')"
t p384-converged-draft-is-not-owed 0 "$(printf '%s' "$FLIP_OWED_ROWS" | grep -c '^395$')"
# The ledger keys the gate is handed, head included so a push ends the episode.
t p384-flip-owed-force-fresh-keys \
  "$(printf 'o/r#386@%s\no/r#392@%s\no/r#394@%s' "$P384_HEAD" "$P384_HEAD" "$P384_HEAD")" \
  "$(printf '%s' "$RESUME_FORCE_FRESH" | awk 'NF')"
t p384-flip-warns-once-per-detection 3 "$(grep -c 'WARN' <<<"$p384_fo_out")"
t p384-flip-warn-names-the-reason 3 \
  "$(grep -c 'the handoff was consumed, not completed' <<<"$p384_fo_out")"
t p384-flip-warn-carries-the-full-sha 3 "$(grep -c "$P384_HEAD" <<<"$p384_fo_out")"
# The WARN names the panel that is owed, which is the evidence a reader needs to
# tell this state from a converged one without opening the PR.
t p384-flip-warn-names-the-owed-panel 1 \
  "$(grep -c 'WARN.*o/r#386.*owing a panel (p1 p2)' <<<"$p384_fo_out")"
# DETECTED, NEVER HONOURED. The flip asserts the round was answered whole, which
# BUILDER.md rules the one judgement its author cannot delegate — so the WARN
# says so, and the predicate buys a session rather than performing the act. It
# computes exactly whom the engine WOULD request, and requests nobody.
t p384-flip-warn-leaves-the-flip-to-the-builder 3 \
  "$(grep -c 'The flip stays yours' <<<"$p384_fo_out")"
builder_doctrine_flat="$(tr -s '[:space:]' ' ' <"$ROOT/.ceremony/BUILDER.md")"
if grep -Fq 'an engine may draft a PR but only the builder undrafts it' <<<"$builder_doctrine_flat"; then
  r1=agreed
else
  r1=DIVERGED
fi
t p384-flip-doctrine-still-says-so agreed "$r1"
# This complete clause contains no Markdown syntax, so it is the longest safe
# prompt-side comparison to pair beside the existing doctrine-only assertion.
assert_doctrine_quote "$RG_PROMPT" \
  'an engine may draft a PR but only the builder undrafts it' \
  resume-prompt-quotes-undraft-doctrine
# MUST FAIL — the engine flipping, requesting or labelling. Neither predicate
# writes to the board at all: no undraft, no reviewer, no label. The one GitHub
# call the flip predicate makes is a READ, pinned below.
p384_bodies="$(cat <(declare -f _green_head_resume_rows) <(declare -f _flip_owed_resume_rows))"
t p384-predicates-never-flip 0 \
  "$(grep -cE 'ready-for-review|--undraft|markPullRequestReadyForReview' <<<"$p384_bodies")"
t p384-predicates-never-request 0 \
  "$(grep -cE '_request_panel|--add-reviewer|requested_reviewers' <<<"$p384_bodies")"
t p384-predicates-never-label 0 \
  "$(grep -cE 'LABEL_|--add-label|/labels' <<<"$p384_bodies")"
t p384-predicates-never-mutate 0 "$(grep -c 'mutation' <<<"$p384_bodies")"
t p384-flip-makes-exactly-one-read 1 "$(grep -c 'gh api graphql' <<<"$p384_bodies")"
# A verdict lookup that fails leaves that draft out for the tick rather than
# guessing — the same fail-soft direction as everything else on this path.
rm -f "$P384_GQL/386"
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" \
  "$(jq -cn --argjson a "$(p384_pr 386 true "$P384_GREEN" "$P384_HEAD")" '[$a]')" \
  >"$TMP/p384-flip-gql-fail.log" 2>&1
t p384-flip-verdict-failure-detects-nothing "" "$(printf '%s' "$FLIP_OWED_ROWS" | awk 'NF')"
t p384-flip-verdict-failure-warns 1 \
  "$(grep -c 'verdict lookup failed' "$TMP/p384-flip-gql-fail.log")"
p384_verdicts 386 '[]' '[]'
# FAIL-SOFT on the rollup, the same contract as the green-head half.
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" 'not json' >"$TMP/p384-flip-fail.log" 2>&1
t p384-flip-ungradeable-detects-nothing "" "$(printf '%s' "$FLIP_OWED_ROWS" | awk 'NF')"
t p384-flip-ungradeable-forces-nothing "" "$(printf '%s' "$RESUME_FORCE_FRESH" | awk 'NF')"
t p384-flip-ungradeable-warns 1 \
  "$(grep -c 'check rollup could not be graded' "$TMP/p384-flip-fail.log")"
unset -f gh

# 5. THROUGH THE GATE. Its own DUTY_DIR and its own `gh` stub, in the shape the
# #314 block above establishes: the foreign half is served from files so a
# command substitution cannot lose it, and the issue half from a variable.
P384_DUTY="$TMP/p384-gate"; P384_LOG="$TMP/p384-gate.log"
P384_SPEECH="$TMP/p384-speech"
mkdir -p "$P384_DUTY" "$P384_SPEECH"
: >"$P384_SPEECH/381.comments"; : >"$P384_SPEECH/381.reviews"
: >"$P384_SPEECH/386.comments"; : >"$P384_SPEECH/386.reviews"
P384_ISSUE_TS="2026-08-01T00:00:00Z"
# shellcheck disable=SC2317  # called indirectly by _resume_gate
gh() {
  local args="$*" n kind
  case "$args" in
    *graphql*)
      # The flip-owed predicate's one read. Only #386 is signalled here, and it
      # is signalled with nobody requested and nobody having reviewed — the
      # state that PR was actually in when the draft consumed its handoff.
      n="${args##*num=}"; n="${n%% *}"
      [ "$n" = 386 ] || return 1
      jq -cn --arg head "$P384_HEAD" --arg at "$P384_SIG_AT" \
        '{data:{repository:{pullRequest:{
            headRefOid:$head,
            comments:{nodes:[{author:{login:"me"}, body:("ANSWER " + $head), createdAt:$at}]},
            reviewRequests:{nodes:[]},
            latestOpinionatedReviews:{nodes:[]}}}}}'
      return 0 ;;
    */comments*|*/reviews*)
      case "$args" in */comments*) kind=comments ;; *) kind=reviews ;; esac
      n="${args##*/issues/}"; n="${n##*/pulls/}"; n="${n%%/*}"
      [ -f "$P384_SPEECH/$n.$kind" ] && cat "$P384_SPEECH/$n.$kind"
      return 0 ;;
    *) printf '%s\n' "$P384_ISSUE_TS" ;;
  esac
  return 0
}
P384_SAVED_DUTY="$DUTY_DIR"; P384_SAVED_ME="${ME-}"; P384_ME_WAS_SET="${ME+x}"
DUTY_DIR="$P384_DUTY"; ME=me
p384_reset() {
  rm -f "$P384_DUTY/.seen-resume" "$P384_DUTY/.resume-zero-action.o__r"
  RESUME_FORCE_FRESH=""
}
p384_tick() {  # p384_tick LISTING — one duty tick, caller side included
  RESUME_DISPATCH_NUMS=""; RESUME_COMMIT_LINES=""
  _resume_gate o/r o__r "$1" >"$P384_LOG" 2>&1 || true
  if [ -n "${RESUME_COMMIT_LINES//[[:space:]]/}" ]; then
    printf '%s' "$RESUME_COMMIT_LINES" | ledger_commit "$P384_DUTY/.seen-resume"
  fi
}
p384_draft() {  # p384_draft ROLLUP -> the one-draft listing #381 is
  jq -cn --argjson roll "$1" --arg head "$P384_HEAD" \
    '[{number:381,isDraft:true,headRefOid:$head,body:"Closes #290",
       statusCheckRollup:$roll,reviewRequests:[],comments:[]}]'
}

# THE #381 REPLAY. The session pushed d4b8035 and parked on `ci-floor`. Tick one
# is the cold ledger and dispatches; tick two is the same head with the check
# still running and nobody foreign speaking, and is correctly suppressed. Then
# `ci-floor` CONCLUDES at 07:52:18Z — and that is the tick the old engine could
# not see, because a check conclusion is neither a comment nor a review. It
# dispatches now, forty-six minutes and eleven ticks before the twelfth.
p384_reset
p384_tick "$(p384_draft "$P384_PENDING")"
t p384-replay-cold-dispatches 381 "$RESUME_DISPATCH_NUMS"
p384_tick "$(p384_draft "$P384_PENDING")"
t p384-replay-parked-on-a-running-check-is-quiet "" "$RESUME_DISPATCH_NUMS"
t p384-replay-quiet-tick-is-said 1 \
  "$(grep -c "no resume duty: o/r#381 unchanged at $P384_HEAD" "$P384_LOG")"
p384_tick "$(p384_draft "$P384_GREEN")"
t p384-replay-the-conclusion-wakes-it 381 "$RESUME_DISPATCH_NUMS"
# ...and the ledger advanced to the conclusion stamp, so the value is what fired
# and not some coincidence of the other halves.
t p384-replay-ledger-carries-the-conclusion 1 \
  "$(grep -c "^o/r#381@$P384_HEAD $P384_DONE\$" "$P384_DUTY/.seen-resume")"
# THE ID IS UNTOUCHED. A check term in the id would mint an id never seen on
# every re-run and fire again on an unchanged tree; the head stays its whole
# content, exactly as the ci-red scheme requires (#17).
t p384-ledger-id-carries-only-the-head 1 \
  "$(awk '{print $1}' "$P384_DUTY/.seen-resume" | grep -cx "o/r#381@$P384_HEAD")"
# The value stays ALL ISO-8601, which is what makes a lexical max a
# chronological one — the invariant the fingerprint block's header states.
t p384-ledger-value-is-iso8601 1 \
  "$(awk '{print $2}' "$P384_DUTY/.seen-resume" \
     | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"
# A RE-RUN of the same check does not re-fire. Its conclusion stamp is not newer
# than the one already committed, so the value does not sort greater and the
# ledger holds — which is the difference between a term in the value and a term
# in the id, asserted rather than argued.
p384_tick "$(p384_draft "$P384_GREEN")"
t p384-rerun-of-the-same-check-does-not-refire "" "$RESUME_DISPATCH_NUMS"
# A LATER conclusion does: a rerun that finishes at a new time is new evidence.
P384_RERUN="$(p384_run SUCCESS 2026-08-06T09:30:00Z)"
p384_tick "$(p384_draft "$P384_RERUN")"
t p384-a-later-conclusion-refires 381 "$RESUME_DISPATCH_NUMS"

# FAIL-SOFT AT THE GATE. A check lookup that errors warns and drops that half
# for the tick; the other halves still decide, and no green is fabricated.
p384_reset
P384_REAL_CHECK="$(declare -f _resume_newest_check)"
# shellcheck disable=SC2317  # reinstated immediately below
_resume_newest_check() { return 1; }
p384_tick "$(p384_draft "$P384_GREEN")"
t p384-check-failure-warns 1 \
  "$(grep -c 'check-conclusion lookup failed for the resume fingerprint' "$P384_LOG")"
t p384-check-failure-still-decides-on-the-rest 381 "$RESUME_DISPATCH_NUMS"
t p384-check-failure-fabricates-no-stamp 0 \
  "$(grep -c "$P384_DONE" "$P384_DUTY/.seen-resume")"
eval "$P384_REAL_CHECK"

# THE #386 REPLAY. A draft carrying a valid signal at a green head with no panel
# requested: the head has not moved and nobody foreign has spoken, so the ledger
# is right to hold it and would hold it forever. The force-fresh override is
# what makes it due.
P384_386="$(jq -cn --argjson roll "$P384_GREEN" --arg head "$P384_HEAD" \
  '[{number:386,isDraft:true,headRefOid:$head,body:"Closes #291",
     statusCheckRollup:$roll,reviewRequests:[],
     comments:[{author:{login:"me"},body:("ANSWER " + $head),
                createdAt:"2026-08-06T09:54:56Z",id:"9002"}]}]')"
p384_reset
p384_tick "$P384_386"
t p384-386-cold-dispatches 386 "$RESUME_DISPATCH_NUMS"
# THE CONTROL: without the override the second tick is suppressed, which is the
# state #386 actually sat in. This assertion is what makes the next one mean
# something — it shows the ledger genuinely holds this shape.
p384_tick "$P384_386"
t p384-386-ledger-would-hold-it-forever "" "$RESUME_DISPATCH_NUMS"
t p384-386-hold-is-said 1 \
  "$(grep -c "no resume duty: o/r#386 unchanged at $P384_HEAD" "$P384_LOG")"
# Now the predicate speaks, and the same unchanged tick becomes due.
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_386" >/dev/null 2>&1
p384_tick "$P384_386"
t p384-386-force-fresh-makes-it-due 386 "$RESUME_DISPATCH_NUMS"
# BOUNDED. The override rides _resume_breaker rather than going around it: three
# consecutive zero-action dispatches at one head and no fourth. An unbounded
# bypass would dispatch every five minutes for as long as the draft stood, which
# is the #314 flood re-entering through the door built to end it.
#
# The COUNTER is reset here and the LEDGER deliberately is not, so all three
# dispatches below are the override's own — with the ledger left holding, a
# dispatch can have no other cause, and the bound is measured on exactly the
# path this PR adds rather than on the cold-start it inherits.
rm -f "$P384_DUTY/.resume-zero-action.o__r"
for _p384_i in 1 2 3; do
  _flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_386" >/dev/null 2>&1
  p384_tick "$P384_386"
  t "p384-386-override-dispatch-$_p384_i" 386 "$RESUME_DISPATCH_NUMS"
done
t p384-386-breaker-trips-once 1 \
  "$(grep -c 'produced no commit, and after this one' "$P384_LOG")"
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_386" >/dev/null 2>&1
p384_tick "$P384_386"
t p384-386-no-fourth-dispatch "" "$RESUME_DISPATCH_NUMS"
t p384-386-breaker-suppression-is-said 1 \
  "$(grep -c "breaker-suppressed at $P384_HEAD after 3 zero-action dispatches" "$P384_LOG")"
# A PUSH ends the episode: the signal at the old head is no longer at the head,
# so the predicate stops naming it and the ordinary path takes over.
P384_386_MOVED="$(printf '%s' "$P384_386" | jq -c --arg h "$P384_OLD" '.[0].headRefOid = $h | .')"
_flip_owed_resume_rows o/r me ANSWER "$P384_PANEL" "$P384_386_MOVED" >/dev/null 2>&1
t p384-386-push-ends-the-episode "" "$(printf '%s' "$FLIP_OWED_ROWS" | awk 'NF')"
DUTY_DIR="$P384_SAVED_DUTY"
if [ -n "$P384_ME_WAS_SET" ]; then ME="$P384_SAVED_ME"; else unset ME; fi
unset -f gh
RESUME_FORCE_FRESH=""

# 6. THE WIRING. Helper-level tests stay green if the dispatch site stops
# consulting either predicate, which is exactly how these stalls come back.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_green_head_resume_rows "$R" "$ME" "$MARK_ANSWERED" "$resume_json"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq '_flip_owed_resume_rows "$R" "$ME" "$MARK_ANSWERED" "$panel_json" "$resume_json"' "$SHARED/lib/duty-builder.sh"; then
  r1=wired
else
  r1=UNWIRED
fi
t p384-predicates-wired-into-the-tick wired "$r1"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq 'GREEN_HEAD="${green_head_nums:-none}"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq '{{GREEN_HEAD}}' "$RG_PROMPT" \
  && grep -Fq 'FLIP_OWED="${flip_owed_nums:-none}"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq '{{FLIP_OWED}}' "$RG_PROMPT"; then
  r1=wired
else
  r1=UNWIRED
fi
t p384-reasons-reach-the-resume-prompt wired "$r1"
# The prompt must hand the flip BACK to the builder rather than instructing the
# session to rubber-stamp it: the judgement is the whole reason a session is
# bought instead of the engine acting.
if grep -Fq 'THE FLIP IS YOURS AND ONLY YOURS' "$RG_PROMPT"; then r1=owned; else r1=DELEGATED; fi
t p384-prompt-keeps-the-flip-with-the-builder owned "$r1"
# The green-head reason rides BESIDE the threshold — #319's assertions on
# _stranded_resume_due's call, threshold and state-file format above run
# unmodified, and this pins the union that adds the second reason — and THROUGH
# the breaker, which is the half a helper-level test cannot see. An earlier cut
# of this PR had the union alone, and this assertion as written then pinned the
# unbounded wiring rather than catching it; both halves are named now.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '"$stranded_nums" "$green_head_nums"' "$SHARED/lib/duty-builder.sh"; then
  r1=beside
else
  r1=THROUGH
fi
t p384-green-rides-beside-the-threshold beside "$r1"
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_green_head_breaker "$R" "$slug" "$green_head_rows"' "$SHARED/lib/duty-builder.sh" \
  && grep -Fq 'green_head_nums="$GREEN_HEAD_DISPATCH_NUMS"' "$SHARED/lib/duty-builder.sh"; then
  r1=bounded
else
  r1=UNBOUNDED
fi
t p384-green-also-rides-the-breaker bounded "$r1"
# ...on a state file of its own. A second call site against the gate's file
# would silently prune the gate's counters every tick, so the path is part of
# the wiring and not an implementation detail.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '_resume_breaker "$DUTY_DIR/.resume-zero-action-green.$slug"' "$SHARED/lib/duty-builder.sh" \
  && [ "$(grep -cF '_resume_breaker "$DUTY_DIR/.resume-zero-action.$slug"' "$SHARED/lib/duty-builder.sh")" = 1 ]; then
  r1=separate
else
  r1=SHARED
fi
t p384-green-breaker-has-its-own-state-file separate "$r1"

# A ci-red session returning zero does not consume an unsettled same-head item.
# Red is terminal and remains one-shot; a moved head settles the old key and
# will independently enter under its new id if it is red.
CI_PENDING="$(jq -cn '{number:243,isDraft:false,updatedAt:"T",headRefOid:"aaa",statusCheckRollup:[{name:"ci",status:"IN_PROGRESS"}]}')"
CI_RED="$(jq -cn '{number:243,isDraft:false,updatedAt:"T",headRefOid:"aaa",statusCheckRollup:[{name:"ci",status:"COMPLETED",conclusion:"FAILURE"}]}')"
CI_MOVED="$(jq -cn '{number:243,isDraft:false,updatedAt:"T",headRefOid:"bbb",statusCheckRollup:[{name:"ci",status:"IN_PROGRESS"}]}')"
if printf '%s' "$CI_PENDING" | _ci_red_rollup_settled aaa; then r1=settled; else r1=retry; fi
t ci-red-pending-remains-retryable retry "$r1"
if printf '%s' "$CI_RED" | _ci_red_rollup_settled aaa; then r1=settled; else r1=retry; fi
t ci-red-red-remains-one-shot settled "$r1"
if printf '%s' "$CI_MOVED" | _ci_red_rollup_settled aaa; then r1=settled; else r1=retry; fi
t ci-red-moved-head-settles-old-key settled "$r1"

# The settle predicate must gate the ledger commit, not merely exist beside a
# post-session rollup re-read. Removing this condition restores the
# unconditional commit while leaving the fixture-level helper tests green.
# shellcheck disable=SC2016  # matching shell source literally
if grep -Fq '| _ci_red_rollup_settled "${red_key##*@}"; then' "$SHARED/lib/duty-builder.sh"; then
  r1=gated
else
  r1=UNCONDITIONAL
fi
t ci-red-ledger-commit-is-settle-gated gated "$r1"

# `attention` remains a hand-written demand. Reads in duty-attention.sh are the
# wake mechanism and are allowed; engine label writes are not. Fold continued
# shell lines before looking for add/remove-label or labels[]= writes so moving
# an argument onto the next source line cannot evade the guard.
attention_writes="$(awk '
  FNR == 1 { logical = "" }
  {
    line = $0
    if (logical != "") line = logical line
    if (line ~ /\\[[:space:]]*$/) {
      sub(/\\[[:space:]]*$/, " ", line)
      logical = line
      next
    }
    logical = ""
    if (line !~ /^[[:space:]]*#/ &&
        line ~ /(--add-label|--remove-label|labels\[\])/ &&
        line ~ /(LABEL_ATTENTION|attention)/) print FILENAME ":" FNR ":" line
  }
' "$SHARED"/lib/*.sh "$SHARED"/bin/* 2>/dev/null)"
t engine-never-writes-attention-label "" "$attention_writes"

# ledger_filter re-fires when the value sorts GREATER, and a SHA has no order.
# This is the negative control for the scheme NOT used: keyed the ordinary way,
# a corrective push whose oid happens to sort below the previous one is
# suppressed — the wake would be lost exactly when the builder fixed something.
CLG_NAIVE="$TMP/ci-naive"
printf 'o/r#7 fff0000\n' | ledger_commit "$CLG_NAIVE"
t ci-red-naive-sha-value-loses-the-push 0 \
  "$(printf 'o/r#7 000ffff\n' | ledger_filter "$CLG_NAIVE" | n)"
# The scheme the module uses: head in the id, fixed sentinel value.
CLG="$TMP/ci-red"
printf 'o/r#7@fff0000\thead\n' | ledger_commit "$CLG"
t ci-red-new-head-wakes 1 "$(printf 'o/r#7@000ffff\thead\n' | ledger_filter "$CLG" | n)"
t ci-red-same-head-quiet 0 "$(printf 'o/r#7@fff0000\thead\n' | ledger_filter "$CLG" | n)"
# ...and an unchanged red head is reported rather than silently dropped (#59).
t ci-red-same-head-reported "o/r#7@fff0000" \
  "$(printf 'o/r#7@fff0000\thead\n' | ledger_suppressed "$CLG" | cut -f1)"

# --- the module's row slicing ------------------------------------------------
# The awk programs are asserted literally against the module AND run here on a
# fixture. Neither alone is enough: the grep proves the module still contains
# this expression, the fixture proves the expression is right. Edit both and
# the behaviour is still checked; edit the module alone and the grep fails.
BMOD="$SHARED/lib/duty-builder.sh"
# shellcheck disable=SC2016  # awk field refs, quoted exactly as the module has them
AWK_ROUNDS='$5 == "owed" && ($4 == "green" || $4 == "none") { print $1, $2 }'
# shellcheck disable=SC2016
AWK_BLOCKED='$5 == "owed" && $4 == "red" { print $1 }'
# shellcheck disable=SC2016
AWK_HELD='$5 == "owed" && $4 == "pending" { print $1 }'
# shellcheck disable=SC2016
AWK_RED='$4 == "red" { print $1 "@" $3 "\thead\t" $6 }'
for pair in "rounds:$AWK_ROUNDS" "blocked:$AWK_BLOCKED" "held:$AWK_HELD" "red:$AWK_RED"; do
  if grep -Fq "${pair#*:}" "$BMOD"; then r1=present; else r1=MISSING; fi
  t "ci-red-awk-in-module-${pair%%:*}" present "$r1"
done
ROWS="$(printf '%s\n' \
  "$(printf 'o/r#1\tT1\taaa\tred\towed\tcheck (FAILURE)')" \
  "$(printf 'o/r#2\tT2\tbbb\tgreen\towed\t-')" \
  "$(printf 'o/r#3\tT3\tccc\tred\t-\tcheck (FAILURE)')" \
  "$(printf 'o/r#4\tT4\tddd\tpending\towed\t-')")"
# #45: the red-headed round is NOT a build wake — and neither is the pending
# one (danmt's ruling, #64). Opening a round while the check is still running
# spends the panel on a head that may go red, which is what #45 measured on
# crew#40. Only o/r#2 (green) survives; o/r#4 (pending) is now held.
t ci-red-rounds-exclude-red "$(printf 'o/r#2 T2')" \
  "$(awk -F'\t' "$AWK_ROUNDS" <<<"$ROWS")"
# ...but neither hold is silent — the operator is told which round is held and
# why, and the two reasons are NOT interchangeable: red is the author's own
# work, pending is a wait that nobody owes anything for.
t ci-red-blocked-round-named "o/r#1" "$(awk -F'\t' "$AWK_BLOCKED" <<<"$ROWS")"
t ci-red-held-round-named "o/r#4" "$(awk -F'\t' "$AWK_HELD" <<<"$ROWS")"
# A pending head must NOT wake ci-red: nothing has failed, so there is no
# investigation to launch and no rerun to cap.
t pending-head-does-not-wake-ci-red "" \
  "$(awk -F'\t' "$AWK_RED" <<<"$(printf 'o/r#4\tT4\tddd\tpending\towed\t-')")"
# The two hold messages must not be the same string, or the pending hold reads
# as "CI first, fix it" and tells the operator the author owes work.
RED_MSG="$(grep -c 'the check at its head is RED' "$BMOD")"
HELD_MSG="$(grep -c 'has not finished' "$BMOD")"
t hold-messages-are-distinct "1 1" "$RED_MSG $HELD_MSG"
# #17: every red head wakes, round owed or not.
t ci-red-items-both-heads "$(printf 'o/r#1@aaa\thead\tcheck (FAILURE)\no/r#3@ccc\thead\tcheck (FAILURE)')" \
  "$(awk -F'\t' "$AWK_RED" <<<"$ROWS")"

# codex's regression ask, end to end rather than at the classifier: a CANCELLED
# head with a round owed must not reach the build wake, and must reach the
# ci-red wake instead. The classifier tests above prove `red`; these prove the
# consequence, which is what #45 and #17 are actually about.
CANCEL_ROW="$(hc '["p1"]' "$(mk_prc "$CHK_CANCEL" "$CR_REQ")")"
t head-cancelled-round-is-blocked "" "$(awk -F'\t' "$AWK_ROUNDS" <<<"$CANCEL_ROW")"
t head-cancelled-wakes-ci-red "o/r#1@abc1234" \
  "$(awk -F'\t' "$AWK_RED" <<<"$CANCEL_ROW" | cut -f1)"
t head-cancelled-named-in-the-wake "check (CANCELLED)" "$(cut -f6 <<<"$CANCEL_ROW")"

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

# --- #139: a closed fix round returns to draft ------------------------------
# GitHub preserves pending review requests across conversion (crew#110 is the
# live trace), so the existing addressing predicate's no-panel-request gate is
# load-bearing: conversion happens only after the whole round closes. The last
# reviewer's triage-scoped box writes state:addressing; the author-owned builder
# tick performs the draft mutation. Those acts are independent and idempotent.
AR_H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
AR_T_VERDICT="2026-08-05T18:57:00Z"
AR_T_SIGNAL="2026-08-05T19:00:00Z"
AR_BLOCKED='[{"author":{"login":"rev-a"},"state":"CHANGES_REQUESTED","submittedAt":"'$AR_T_VERDICT'","commit":{"oid":"'$AR_H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","submittedAt":"'$AR_T_VERDICT'","commit":{"oid":"'$AR_H'"}}]'
AR_APPROVED='[{"author":{"login":"rev-a"},"state":"APPROVED","submittedAt":"'$AR_T_VERDICT'","commit":{"oid":"'$AR_H'"}},{"author":{"login":"rev-b"},"state":"APPROVED","submittedAt":"'$AR_T_VERDICT'","commit":{"oid":"'$AR_H'"}}]'
mk_addressing_payload() {  # draft labels requests reviews [comments]
  jq -cn --argjson draft "$1" --argjson labels "$2" --argjson requests "$3" \
    --argjson reviews "$4" --argjson comments "${5:-[]}" --arg head "$AR_H" \
    '{data:{repository:{pullRequest:{
      id:"PR_fixture",isDraft:$draft,headRefOid:$head,author:{login:"builder"},
      labels:{nodes:($labels|map({name:.}))},
      comments:{nodes:$comments},
      reviewRequests:{nodes:($requests|map({requestedReviewer:{login:.}}))},
      latestOpinionatedReviews:{nodes:$reviews}}}}}'
}
# shellcheck disable=SC2034,SC2317  # vars/functions consumed by engine helpers
review_addressing_actions() (  # payload [label-rc]
  AR_PAYLOAD="$1"; AR_LABEL_RC="${2:-0}"
  LABEL_ADDRESSING=state:addressing
  DUTY_DIR="$SHARED"
  AR_LOG="$TMP/addressing-actions"; : >"$AR_LOG"
  panel_for_repo() { printf '%s\n' '["rev-a","rev-b"]'; }
  log() { :; }
  warn() { :; }
  gh() {
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      printf '%s\n' "$AR_PAYLOAD"
      return 0
    fi
    if [ "$1" = issue ] && [ "$2" = edit ]; then
      printf '%s\n' label >>"$AR_LOG"
      return "$AR_LABEL_RC"
    fi
    return 3
  }
  _mark_addressing owner/repo 7
  ar_rc=$?
  printf 'rc=%s actions=%s' "$ar_rc" "$(paste -sd, "$AR_LOG")"
)
# shellcheck disable=SC2317  # mock functions are called indirectly by helper
author_redraft_actions() (  # payload [draft-rc]
  AR_PAYLOAD="$1"; AR_DRAFT_RC="${2:-0}"
  LABEL_ADDRESSING=state:addressing
  DUTY_DIR="$SHARED" ME=builder MARK_ANSWERED="$RP_MARK"
  AR_LOG="$TMP/redraft-actions"; : >"$AR_LOG"
  log() { :; }
  warn() { :; }
  gh() {
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      if [[ "$*" == *convertPullRequestToDraft* ]]; then
        printf '%s\n' draft >>"$AR_LOG"
        return "$AR_DRAFT_RC"
      fi
      printf '%s\n' "$AR_PAYLOAD"
      return 0
    fi
    return 3
  }
  _redraft_authored_pr owner/repo 7 '["rev-a","rev-b"]'
  ar_rc=$?
  printf 'rc=%s actions=%s' "$ar_rc" "$(paste -sd, "$AR_LOG")"
)
AR_OPEN="$(mk_addressing_payload false '[]' '[]' "$AR_BLOCKED")"
AR_LABELLED="$(mk_addressing_payload false '["state:addressing"]' '[]' "$AR_BLOCKED")"
AR_DRAFT="$(mk_addressing_payload true '["state:addressing"]' '[]' "$AR_BLOCKED")"
AR_DRAFT_UNLABELLED="$(mk_addressing_payload true '[]' '[]' "$AR_BLOCKED")"
AR_OK="$(mk_addressing_payload false '[]' '[]' "$AR_APPROVED")"
AR_LIVE="$(mk_addressing_payload false '[]' '["rev-b"]' "$AR_BLOCKED")"
t redraft-reviewer-writes-addressing-only 'rc=0 actions=label' \
  "$(review_addressing_actions "$AR_OPEN")"
t redraft-author-converts-after-label 'rc=0 actions=draft' \
  "$(author_redraft_actions "$AR_LABELLED")"
t redraft-full-approval-writes-nothing 'rc=0 actions=' \
  "$(author_redraft_actions "$AR_OK")"
t redraft-live-panel-request-writes-nothing 'rc=0 actions=' \
  "$(author_redraft_actions "$AR_LIVE")"
t redraft-second-tick-is-noop 'rc=0 actions=' \
  "$(author_redraft_actions "$AR_DRAFT")"
t redraft-draft-guard-does-not-depend-on-label 'rc=0 actions=' \
  "$(author_redraft_actions "$AR_DRAFT_UNLABELLED")"
t redraft-retries-after-label-landed 'rc=0 actions=draft' \
  "$(author_redraft_actions "$AR_LABELLED")"
t redraft-label-failure-is-best-effort 'rc=0 actions=label' \
  "$(review_addressing_actions "$AR_OPEN" 1)"
t redraft-conversion-failure-is-best-effort 'rc=0 actions=draft' \
  "$(author_redraft_actions "$AR_LABELLED" 1)"

# The author-aware panel is resolved once per repository tick and passed into
# every PR predicate. panel_for_repo owns the safe fleet-bench fallback, so the
# redraft path must not advertise an unreachable lookup-failure branch.
# shellcheck disable=SC2016  # grep literals intentionally contain shell syntax
t redraft-panel-resolved-once-per-repo 1 \
  "$(grep -c 'panel_for_repo "\$R" "\$dir" "\$ME"' "$SHARED/lib/duty-builder.sh")"
if grep -q 'panel lookup failed' "$SHARED/lib/duty-builder.sh"; then
  r1=MISLEADING
else
  r1=fallback-owned
fi
t redraft-panel-fallback-contract fallback-owned "$r1"

# The engine owns only the ready -> draft edge. Ready-for-review remains the
# builder's judgement, and draft exclusion is shared by request and handoff.
if ! grep -q 'convertPullRequestToDraft' "$SHARED/lib/duty-review.sh" \
  && grep -q 'convertPullRequestToDraft' "$SHARED/lib/duty-builder.sh" \
  && ! grep -Rq 'markPullRequestReadyForReview\|gh pr ready' \
       "$SHARED/lib" "$SHARED/bin" "$ROOT/cli"; then
  r1=one-way
else
  r1=ENGINE-MARKS-READY
fi
t redraft-engine-never-marks-ready one-way "$r1"
if grep -qi "while it is still draft, mark it ready with no commit between, and let the head checks settle" \
     "$SHARED/prompts/fragment-round-rules.txt" \
  && grep -qi 'requests the panel only after that ready head is green' \
     "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=builder-owned
else
  r1=MISSING
fi
t redraft-prompt-returns-ready-act-to-builder builder-owned "$r1"
if grep -Fq 'A draft carrying a completed review round is actionable' \
     "$SHARED/prompts/resume.txt" \
  && grep -Fq "append the round's fix steps" "$SHARED/prompts/resume.txt" \
  && grep -Fq 'AND NO COMPLETED ROUND STANDS, POST NOTHING AT ALL' \
       "$SHARED/prompts/resume.txt"; then
  r1=woken
else
  r1=STRANDED
fi
t redraft-resume-names-completed-round woken "$r1"

# The issue's whole lifecycle in one stateful fixture. It drives the real
# reviewer and author helpers against one mutable PR, reads the checked-in CI
# workflow gates for the draft-push/ready edges, then hands the real signal
# object to request-panel.jq. A broken link changes or stops this trace.
# shellcheck disable=SC2034,SC2317  # vars/mocks consumed by engine helpers
redraft_round_trip() (
  AR_IS_DRAFT=false AR_LABELS='[]' AR_COMMENTS='[]' AR_ACTIONS=""
  LABEL_ADDRESSING=state:addressing LABEL_BOTS_REVIEWING=state:bots-reviewing
  DUTY_DIR="$SHARED" ME=builder MARK_ANSWERED="$RP_MARK"
  panel_for_repo() { printf '%s\n' '["rev-a","rev-b"]'; }
  log() { :; }
  warn() { :; }
  ar_payload() {
    mk_addressing_payload "$AR_IS_DRAFT" "$AR_LABELS" '[]' "$AR_BLOCKED" "$AR_COMMENTS"
  }
  gh() {
    if [ "$1" = api ] && [ "$2" = graphql ]; then
      if [[ "$*" == *convertPullRequestToDraft* ]]; then
        AR_IS_DRAFT=true
        AR_ACTIONS="${AR_ACTIONS:+$AR_ACTIONS,}draft"
        return 0
      fi
      ar_payload
      return 0
    fi
    if [ "$1" = api ] && [[ "$2" == repos/*/requested_reviewers ]]; then
      local ar_arg
      for ar_arg in "$@"; do
        case "$ar_arg" in
          reviewers\[\]=*)
            AR_ACTIONS="${AR_ACTIONS:+$AR_ACTIONS,}request:${ar_arg#*=}"
            ;;
        esac
      done
      return 0
    fi
    if [ "$1" = issue ] && [ "$2" = edit ]; then
      if [[ "$*" == *state:bots-reviewing* ]]; then
        return 0
      fi
      AR_LABELS='["state:addressing"]'
      AR_ACTIONS="${AR_ACTIONS:+$AR_ACTIONS,}addressing"
      return 0
    fi
    return 3
  }
  _mark_addressing owner/repo 7
  _redraft_authored_pr owner/repo 7 '["rev-a","rev-b"]'
  [ "$AR_IS_DRAFT" = true ] || { printf 'NOT-DRAFT'; return; }
  for ar_ci in "$ROOT/.github/workflows/ci-shell.yml" "$ROOT/.github/workflows/ci-floor.yml"; do
    grep -q 'github.event.pull_request.draft == false' "$ar_ci" || { printf 'DRAFT-CI'; return; }
    grep -q 'ready_for_review' "$ar_ci" || { printf 'NO-READY-WAKE'; return; }
  done
  AR_ACTIONS="$AR_ACTIONS,draft-push:no-ci"
  # SIGNAL THEN READY is the builder-owned edge. This no-push answer retains
  # the standing current-head reviews. The next real author sweep must consume
  # the newer signal as proof that this round was already converted and leave
  # the PR ready; pending CI still holds the real request helper, then green
  # re-requests only the current-head change-requester.
  AR_COMMENTS='[{"author":{"login":"builder"},"body":"'"$RP_MARK"' '"$AR_H"'","createdAt":"'"$AR_T_SIGNAL"'"}]'
  AR_IS_DRAFT=false
  AR_ACTIONS="$AR_ACTIONS,signal,ready"
  _redraft_authored_pr owner/repo 7 '["rev-a","rev-b"]'
  [ "$AR_IS_DRAFT" = false ] || { printf 'REDRAFT-LOOP'; return; }
  _request_panel owner/repo 7 "$(ar_payload)" '["rev-a","rev-b"]' pending "$AR_H"
  AR_ACTIONS="$AR_ACTIONS,ci:green"
  _request_panel owner/repo 7 "$(ar_payload)" '["rev-a","rev-b"]' green "$AR_H"
  printf '%s' "$AR_ACTIONS"
)
t redraft-full-round-trip \
  'addressing,draft,draft-push:no-ci,signal,ready,ci:green,request:rev-a' \
  "$(redraft_round_trip)"

# MUST FAIL before the ceremony prerequisite: the caller pin must be at least
# the release that shipped round-over-draft precedence, and the vendored state
# table must still state that a standing non-approval makes a draft addressing.
AR_LABELS_REF="$(sed -n 's|.*heavy-duty/ceremony/.github/workflows/labels.yml@||p' \
  "$ROOT/.github/workflows/labels.yml")"
AR_OLDEST="$(printf '%s\n%s\n' 0.5.0 "$AR_LABELS_REF" | sort -V | head -n1)"
# shellcheck disable=SC2016  # literal doctrine text contains backticks
labels_doctrine_flat="$(tr -s '[:space:]' ' ' <"$ROOT/.ceremony/LABELS.md")"
# shellcheck disable=SC2016  # literal doctrine text contains backticks
if [ "$AR_OLDEST" = 0.5.0 ] \
  && grep -Fq 'Draft is evidence for it, not the definition of it: a draft carrying a standing non-approving verdict is a fix round and reads `state:addressing`' <<<"$labels_doctrine_flat"; then
  r1=present
else
  r1=MISSING
fi
t redraft-ceremony-round-precedence-prerequisite present "$r1"

# Conversion precedes draft discovery in the author tick, so the foreign
# closing verdict reaches resume immediately rather than waiting another tick.
# shellcheck disable=SC2016  # grep patterns intentionally contain shell syntax
AR_REDAFT_LINE="$(grep -n '_redraft_authored_rounds "$R"' "$SHARED/lib/duty-builder.sh" | cut -d: -f1)"
# shellcheck disable=SC2016
AR_RESUME_LINE="$(grep -n 'resume_json="$(gh pr list' "$SHARED/lib/duty-builder.sh" | cut -d: -f1)"
if [ -n "$AR_REDAFT_LINE" ] && [ -n "$AR_RESUME_LINE" ] \
  && [ "$AR_REDAFT_LINE" -lt "$AR_RESUME_LINE" ]; then
  r1=ordered
else
  r1=WRONG-ORDER
fi
t redraft-author-converts-before-resume-discovery ordered "$r1"

RR_H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
RR_OLD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RR_T1="2026-07-28T10:00:00Z"; RR_T2="2026-07-28T11:00:00Z"
t rereq-approved-rerequest-auto-approves auto-approve "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T1" "$RR_T2" 1)"
t rereq-changes-requested-queues         queue        "$(rereq_decision "$RR_H" "$RR_H" CHANGES_REQUESTED "$RR_T1" "$RR_T2" 1)"
t rereq-dismissed-queues                 queue        "$(rereq_decision "$RR_H" "$RR_H" DISMISSED "$RR_T1" "$RR_T2" 1)"
t rereq-moved-head-queues                queue        "$(rereq_decision "$RR_OLD" "$RR_H" APPROVED "$RR_T1" "$RR_T2" 1)"
t rereq-covered-no-newer-request-skips   skip         "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T2" "$RR_T1" 1)"
t rereq-covered-no-request-at-all-skips  skip         "$(rereq_decision "$RR_H" "$RR_H" APPROVED "$RR_T1" - 1)"

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

# --- the gate is a whitelist: green or none (danmt's ruling, #64) ------------
# Codex asked for `$4 == "green"`. The ruling took the pending half of that and
# refused the `none` half, because the two are not the same fact: pending is
# transient and resolves itself, `none` is terminal. These tests pin BOTH
# halves, so neither can be reintroduced by someone who reads only one of them.
GATE_ROWS="$(printf '%s\n' \
  "$(printf 'o/noci#1\tT1\taaa\tnone\towed\t-')" \
  "$(printf 'o/q#2\tT2\tbbb\tpending\towed\t-')" \
  "$(printf 'o/g#3\tT3\tccc\tgreen\towed\t-')" \
  "$(printf 'o/x#4\tT4\tddd\tred\towed\tcheck (FAILURE)')")"
t gate-admits-green-and-none "$(printf 'o/noci#1 T1\no/g#3 T3')" \
  "$(awk -F'\t' "$AWK_ROUNDS" <<<"$GATE_ROWS")"
t gate-holds-red "o/x#4" "$(awk -F'\t' "$AWK_BLOCKED" <<<"$GATE_ROWS")"
t gate-holds-pending "o/q#2" "$(awk -F'\t' "$AWK_HELD" <<<"$GATE_ROWS")"
# The `none` half, as a standing negative control. A repo with no CI configured
# is `none` FOREVER, so a gate of `$4 == "green"` does not delay its owed
# rounds — it retires them, and the engine can never open a review round in
# that repo again. head-checks.jq rules `none` a state of its own for exactly
# this reason; the gate has to agree with the classifier.
t gate-green-only-would-strand-the-ci-less-repo "o/g#3 T3" \
  "$(awk -F'\t' '$5 == "owed" && $4 == "green" { print $1, $2 }' <<<"$GATE_ROWS")"
# Every owed round is accounted for — admitted, held-red or held-pending. A
# state that falls out of all three is a round nobody wakes for and nobody
# reports, which is the silent-stall shape this whole PR is against.
t gate-partitions-every-owed-round 4 \
  "$(awk -F'\t' '$5 == "owed" && ($4 == "green" || $4 == "none" || $4 == "red" || $4 == "pending") { c++ } END { print c+0 }' <<<"$GATE_ROWS")"

# What the gate owes for admitting a head with NO evidence: name it. Same
# assert-the-literal-AND-run-it discipline as the row slicing above.
# shellcheck disable=SC2016  # awk field refs, quoted exactly as the module has them
AWK_NOCHECK='$5 == "owed" && $4 == "none" { s = s (s ? "; " : "") $1 " (no checks configured)" } END { print s }'
if grep -Fq "$AWK_NOCHECK" "$BMOD"; then r1=present; else r1=MISSING; fi
t nocheck-awk-in-module present "$r1"
t nocheck-heads-named "o/noci#1 (no checks configured)" \
  "$(awk -F'\t' "$AWK_NOCHECK" <<<"$GATE_ROWS")"
# A green-only set must produce the empty string, which is what the module
# turns into "-" — a literal "" reaching the prompt would read as a bug.
t nocheck-empty-when-all-green "" \
  "$(awk -F'\t' "$AWK_NOCHECK" <<<"$(printf 'o/g#3\tT3\tccc\tgreen\towed\t-')")"
# The datum has to REACH the session, or naming it in the log helps nobody:
# the slot exists in the prompt and the module fills it.
if grep -q '{{HEAD_CHECKS}}' "$SHARED/prompts/build.txt"; then r1=slotted; else r1=MISSING; fi
t build-prompt-has-head-checks-slot slotted "$r1"
# shellcheck disable=SC2016  # matching the module's literal, not expanding it
if grep -q 'HEAD_CHECKS="\$head_checks"' "$BMOD"; then r1=rendered; else r1=MISSING; fi
t build-prompt-head-checks-rendered rendered "$r1"
# render_prompt leaves an unfilled slot in place verbatim, so a slot nobody
# fills would ship "{{HEAD_CHECKS}}" to the model as if it were prose.
printf 'checks: {{HEAD_CHECKS}}' >"$TMP/prompts/hc.txt"
t head-checks-slot-substitutes "checks: o/q#2 (pending)" \
  "$(render_prompt hc.txt HEAD_CHECKS="o/q#2 (pending)")"

# Pending-is-not-green is the ENGINE's gate (head-checks.jq is_pending), while
# the builder declares as soon as the round is complete. Pin both actors so a
# future prose edit cannot move the engine's wait back into the session.
if grep -q 'def is_pending' "$SHARED/lib/jq/head-checks.jq" \
  && grep -qi 'engine holds the request until it settles' "$SHARED/prompts/fragment-round-rules.txt" \
  && grep -qi 'you do not wait to signal' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=ruled
else
  r1=SILENT
fi
t round-rules-rule-pending ruled "$r1"
# Each prompt carried its own form of the builder-side wait. These file-local
# negatives keep a fixed shared fragment from hiding a stale local restatement.
if ! grep -qiE 'check at your head green|ANSWER IS COMPLETE AND THE HEAD IS GREEN|WAIT for it to settle before you signal|signal once it is green' \
     "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=clear
else
  r1=BUILDER-WAITS
fi
t round-rules-no-builder-check-wait-fragment clear "$r1"
if ! grep -qiE 'round-answered SIGNAL at your green head|check at your head is green|final green head' \
     "$SHARED/prompts/build.txt"; then
  r1=clear
else
  r1=BUILDER-WAITS
fi
t round-rules-no-builder-check-wait-build clear "$r1"
if ! grep -qiE 'final green head|wait for a green current head|current head is green, and if it is' \
     "$SHARED/prompts/resume.txt"; then
  r1=clear
else
  r1=BUILDER-WAITS
fi
t round-rules-no-builder-check-wait-resume clear "$r1"
if ! grep -qiE "waiting for the new head.s check to settle before signalling" \
     "$SHARED/prompts/ci-red.txt"; then
  r1=clear
else
  r1=BUILDER-WAITS
fi
t round-rules-no-builder-check-wait-ci-red clear "$r1"
# ...with the one carve-out that keeps a CI-less repo from waiting forever for
# a check that is never coming — the same `none` case as the gate above.
if grep -qi 'NO checks configured' "$SHARED/prompts/fragment-round-rules.txt"; then
  r1=carved
else
  r1=MISSING
fi
t round-rules-carve-out-no-checks carved "$r1"
# The ruled classification is ceremony's (BUILDER.md, operator 2026-07-27) and
# the classifier already implements it; the prompt must not disagree with
# either. cancelled/stale not green, skipped/neutral green.
for term in 'cancelled or stale' 'skipped or neutral'; do
  if grep -qi "$term" "$SHARED/prompts/fragment-round-rules.txt"; then r1=stated; else r1=SILENT; fi
  t "round-rules-ruled-classification-${term// /-}" stated "$r1"
done

# --- the duty order on paper matches the duty order in the code -------------
# FLEET.md states the fleet-standard order and points at these files as the
# mechanism; ceremony#190 merged that order with ci-red in it. A header that
# lags the module order is how the #149 drift went unnoticed, so it is
# asserted rather than remembered (grok, #64).
for f in bin/duty.sh lib/duty-builder.sh README.md; do
  if grep -q 'resume → ci-red' "$SHARED/$f"; then r1=named; else r1=STALE; fi
  t "duty-order-names-ci-red-${f//\//-}" named "$r1"
done
# Handoff is deliberately NOT gated on a green head, and the reason has to sit
# where the "obvious improvement" would be typed (grok, #64): ci-red fires once
# per head, so a green-gated handoff strands exactly ceremony#163 again.
if awk_range_grep_q '/--- HANDOFF/,/--- REBASE/' "$BMOD" 'NOT GATED ON A GREEN HEAD'; then
  r1=called-out
else
  r1=SILENT
fi
t handoff-green-gating-called-out called-out "$r1"

# --- configurable doctrine keeps the shipped prompts byte-identical (#76) ---
saved_prompts_dir="$PROMPTS_DIR"
PROMPTS_DIR="$SHARED/prompts"
# shellcheck disable=SC2034  # consumed indirectly by sourced render_prompt
DOCTRINE_ENTRYPOINT=AGENTS.md DOCTRINE_TRIAGE=TRIAGE.md \
  DOCTRINE_BUILDER=BUILDER.md DOCTRINE_REVIEWER=REVIEWER.md
for prompt_path in "$SHARED"/prompts/*.txt; do
  prompt_name="$(basename "$prompt_path")"
  expected="$(sed \
    -e 's/{{DOCTRINE_ENTRYPOINT}}/AGENTS.md/g' \
    -e 's/{{DOCTRINE_TRIAGE}}/TRIAGE.md/g' \
    -e 's/{{DOCTRINE_BUILDER}}/BUILDER.md/g' \
    -e 's/{{DOCTRINE_REVIEWER}}/REVIEWER.md/g' "$prompt_path")"
  t "doctrine-default-byte-identical-$prompt_name" "$expected" \
    "$(render_prompt "$prompt_name")"
done

# shellcheck disable=SC2034  # consumed indirectly by sourced render_prompt
DOCTRINE_ENTRYPOINT=GUIDE.md DOCTRINE_TRIAGE=OPERATE.md \
  DOCTRINE_BUILDER=CREATE.md DOCTRINE_REVIEWER=VERIFY.md
doctrine_leaks=""
doctrine_unresolved=""
for prompt_path in "$SHARED"/prompts/*.txt; do
  prompt_name="$(basename "$prompt_path")"
  rendered="$(render_prompt "$prompt_name")"
  if grep -Eq 'AGENTS\.md|TRIAGE\.md|BUILDER\.md|REVIEWER\.md' <<<"$rendered"; then
    doctrine_leaks="$doctrine_leaks $prompt_name"
  fi
  if grep -q '{{DOCTRINE_' <<<"$rendered"; then
    doctrine_unresolved="$doctrine_unresolved $prompt_name"
  fi
done
t doctrine-custom-no-shipped-name-leaks "" "$doctrine_leaks"
t doctrine-custom-no-unresolved-slots "" "$doctrine_unresolved"

# Every engine render site must fill every prompt slot. render_prompt leaves
# unknown slots literal deliberately, so this belongs in CI rather than the
# runtime tick. The fixture mutations prove both missing-argument failure
# shapes and the built-in doctrine exemption.
render_sources=("$SHARED"/lib/*.sh "$SHARED"/bin/*.sh)
t render-sites-supply-every-prompt-slot "" \
  "$(render_site_missing_slots "$SHARED/prompts" "${render_sources[@]}")"

RS_PROMPTS="$TMP/render-site-prompts"
RS_SOURCE="$TMP/render-site.sh"
mkdir -p "$RS_PROMPTS"
printf 'required {{GIVEN}} {{MISSING}} {{DOCTRINE_BUILDER}}' >"$RS_PROMPTS/fixture.txt"
# shellcheck disable=SC2016  # fixture source must contain the literal expansion
printf 'x="$(render_prompt fixture.txt GIVEN="$value")"\n' >"$RS_SOURCE"
render_missing="$(render_site_missing_slots "$RS_PROMPTS" "$RS_SOURCE")"
case "$render_missing" in
  *"$RS_SOURCE:1: fixture.txt missing MISSING"*) r1=named ;;
  *) r1="$render_missing" ;;
esac
t render-sites-name-missing-slot named "$r1"
if grep -q 'DOCTRINE_BUILDER' <<<"$render_missing"; then r1=FLAGGED; else r1=exempt; fi
t render-sites-exempt-built-in-doctrine exempt "$r1"

printf 'required {{GIVEN}} {{ANYTHING}}' >"$RS_PROMPTS/fixture.txt"
render_missing="$(render_site_missing_slots "$RS_PROMPTS" "$RS_SOURCE")"
case "$render_missing" in *'missing ANYTHING'*) r1=failed ;; *) r1=MISSED ;; esac
t render-sites-new-slot-without-argument-fails failed "$r1"

cp "$BMOD" "$TMP/duty-builder-missing-round.sh"
# shellcheck disable=SC2016  # removing the module's literal argument
sed -i 's/ ROUND_RULES="$round_rules"//' "$TMP/duty-builder-missing-round.sh"
render_missing="$(render_site_missing_slots "$SHARED/prompts" "$TMP/duty-builder-missing-round.sh")"
case "$render_missing" in *'ci-red.txt missing ROUND_RULES'*) r1=failed ;; *) r1=MISSED ;; esac
t render-sites-ci-red-missing-round-rules-fails failed "$r1"

cp "$SHARED/lib/duty-attention.sh" "$TMP/duty-attention-missing-answered.sh"
# shellcheck disable=SC2016  # removing the module's literal argument
sed -i 's/ MARK_ANSWERED="$MARK_ANSWERED"//' "$TMP/duty-attention-missing-answered.sh"
render_missing="$(render_site_missing_slots "$SHARED/prompts" "$TMP/duty-attention-missing-answered.sh")"
case "$render_missing" in *'fragment-round-rules.txt missing MARK_ANSWERED'*) r1=failed ;; *) r1=MISSED ;; esac
t render-sites-attention-missing-answered-fails failed "$r1"

# shellcheck disable=SC2016  # matching the module's literal, not expanding it
if grep -q '{{ROUND_RULES}}' "$SHARED/prompts/ci-red.txt" \
  && grep -q 'ROUND_RULES="$round_rules"' "$BMOD"; then r1=rendered; else r1=MISSING; fi
t ci-red-renders-round-rules rendered "$r1"
if grep -q 'signal is' "$SHARED/prompts/ci-red.txt" \
  && ! grep -q "let the new head's check speak for itself" "$SHARED/prompts/ci-red.txt"; then
  r1=signals
else
  r1=STALE
fi
t ci-red-fix-ends-in-signal signals "$r1"
if grep -REq 'AGENTS\.md|TRIAGE\.md|BUILDER\.md|REVIEWER\.md' "$SHARED/prompts"; then
  r1=HARDCODED
else
  r1=slotted
fi
t doctrine-templates-have-no-hardcoded-paths slotted "$r1"
PROMPTS_DIR="$saved_prompts_dir"


suite_finish
