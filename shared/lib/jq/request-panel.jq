# request-panel.jq — whom the engine (re-)requests once the round is ANSWERED
# (#133). Input: the GraphQL pullRequest payload (headRefOid, reviewRequests,
# latestOpinionatedReviews). Args: $panel (JSON array of logins, author already
# subtracted), $signal (answered-head.jq's {sha, createdAt}). Output: the logins
# to request, one per line.
#
# The caller runs this ONLY when the session has SIGNALLED the round answered at
# the current head (a MARK_ANSWERED comment) and the head check is green. The
# signal is the engine's licence to act; this predicate never reads commit
# activity, so the engine cannot decide on its own that a round is done —
# #133's hardest must-fail. The sha half of that licence is the caller's gate
# and is deliberately NOT re-checked here: one predicate, one copy.
#
# Given that licence, the set to request is every panelist whose latest
# opinionated review is NOT an approval of the CURRENT head, minus those already
# requested:
#   - never reviewed                          → the first-round request
#   - reviewed an older head (a push moved it) → re-request, approvers included,
#                                                because an approval is of a
#                                                specific tree (handoff reads the
#                                                head)
#   - CHANGES_REQUESTED at the current head    → re-request so they re-read the
#                                                argument that answered them with
#                                                no code change — the no-push half
#                                                the old session rule owned
# A panelist already APPROVING the current head is not re-requested (nothing is
# owed of them); nor is one already on the request list — so a re-tick against
# an unchanged, still-signalled head writes nothing.
#
# ONE SIGNAL OPENS ONE ROUND (#286). That third case was a licence with no
# expiry: verdicts landing AFTER a signal are answers TO it, never triggers FOR
# it, and nothing here read the ordering. A current-head CHANGES_REQUESTED closes
# the round against the builder, and GitHub drops its author from
# requested_reviewers in the same instant — which made the change-requester
# immediately re-requestable under the very signal it had just answered. That is
# the #281 limit cycle: one builder engine and two reviewer boxes spending a
# session each per cycle on a tree nobody had changed, with round_owed and
# addressing.jq both held false by the engine's own request. So a panelist
# HOLDING a current-head verdict is requestable only when:
#
#   1. the signal is STRICTLY NEWER than that verdict — the builder answered it
#      after reading it. An equal-second tie holds: fail-closed costs one tick
#      and the next signal clears it, where failing open costs the cycle above.
#      Absent timestamps hold for the same reason.
#   2. no panel request is outstanding — the coherence gate (ruled 2026-08-02,
#      danmt). A `📣` posted mid-round is inert until the round closes, so one
#      signal can never blur two rounds by re-requesting a verdict-holder while
#      another panelist still owes a first verdict. Fail-safe by construction:
#      the early signal goes inert, the round completes, round_owed wakes the
#      builder, and the re-signal opens round 2 cleanly.
#
# A panelist with NO current-head verdict is untouched by either rule — the
# first-round and head-moved requests are already freshness-guaranteed by the
# caller's signal-at-head gate, and holding those behind an outstanding request
# would break the first round itself, where the whole panel is requested at once
# and each request lands beside the others.
#
# Times are GitHub ISO-8601 UTC (`2026-08-02T10:08:12Z`) — fixed width, so
# lexicographic order is chronological order. Both halves are compared as the
# strings the API returned rather than parsed, and either one missing holds.
.data.repository.pullRequest as $pr
| ($signal.createdAt // "") as $sig_at
| [$pr.reviewRequests.nodes[].requestedReviewer.login // empty] as $requested
# "The round is still open" means a PANEL request is outstanding — the same
# scoping addressing.jq's $no_panel_reqs uses, so the two never disagree about
# whether the ball is still the panel's. An off-panel request (triage, a human,
# an advisory reviewer) is not the panel's round and cannot hold one open.
| (($requested | map(select(. as $l | ($panel | index($l)) != null))
    | length) > 0) as $round_open
| ($pr.latestOpinionatedReviews.nodes
   | map(select(.commit.oid == $pr.headRefOid))) as $head_reviews
| $panel
  | map(select(. as $l | ($requested | index($l)) == null))
  | map(select(. as $l
      | ($head_reviews | map(select(.author.login == $l)) | last) as $verdict
      | if   $verdict == null             then true
        elif $verdict.state == "APPROVED" then false
        # Only CHANGES_REQUESTED closes a round against the builder, so only it
        # spends the signal. A DISMISSED verdict at the head — or any state a
        # later GitHub adds — is a withdrawn opinion, not a standing one: the
        # panelist owes a fresh verdict and NOTHING else would ask for it.
        # round_owed counts only CHANGES_REQUESTED, so holding a dismissal here
        # would leave addressing.jq true, converged.jq false and no request
        # outstanding — the stall this issue exists to end, reintroduced through
        # its own fix. Unknown states therefore keep today's behaviour.
        elif $verdict.state != "CHANGES_REQUESTED" then true
        else ($round_open | not)
             and $sig_at != ""
             and ($verdict.submittedAt // "") != ""
             and $sig_at > ($verdict.submittedAt // "")
        end))
  | .[]
