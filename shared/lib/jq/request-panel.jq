# request-panel.jq — whom the engine (re-)requests once the round is ANSWERED
# (#133). Input: the GraphQL pullRequest payload (headRefOid, reviewRequests,
# latestOpinionatedReviews). Args: $panel (JSON array of logins, author already
# subtracted). Output: the logins to request, one per line.
#
# The caller runs this ONLY when the session has SIGNALLED the round answered at
# the current head (a MARK_ANSWERED comment) and the head check is green. The
# signal is the engine's licence to act; this predicate never reads commit
# activity, so the engine cannot decide on its own that a round is done —
# #133's hardest must-fail.
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
.data.repository.pullRequest as $pr
| [$pr.reviewRequests.nodes[].requestedReviewer.login // empty] as $requested
| ($pr.latestOpinionatedReviews.nodes
   | map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid)
         | .author.login)) as $head_approvers
| $panel
  | map(select(. as $l | ($head_approvers | index($l)) == null))
  | map(select(. as $l | ($requested | index($l)) == null))
  | .[]
