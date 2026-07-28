# request-panel.jq — which panelists the engine must (re-)request on this head
# (#130). Input: the GraphQL pullRequest payload (headRefOid, reviewRequests,
# latestOpinionatedReviews). Args: $panel (JSON array of logins, author already
# subtracted).
#
# Output: the logins to request, one per line — the panelists whose latest
# opinionated review is NOT at the current head (never reviewed it, or reviewed
# a head a later push superseded) and who are not already requested. Empty when
# the round needs no request: every panelist already covers the head (converged
# or a round owed to the builder) or is already on the request list.
#
# This is the whole of "re-request by head, not by verdict" (BUILDER.md) as a
# predicate: after a push moves the head, every panelist's prior review —
# approval or changes-request alike — is no longer at the head, so all of them
# reappear here and are re-requested. A panelist who requested changes at the
# CURRENT head still covers it and is NOT returned: that round is owed to the
# builder, whose fix push is what surfaces them again. The caller gates the
# whole act on a green (or none) head; the argued-exception red-head request
# stays a session judgement (fragment-round-rules.txt), never this predicate's.
.data.repository.pullRequest as $pr
| [$pr.reviewRequests.nodes[].requestedReviewer.login // empty] as $requested
| ($pr.latestOpinionatedReviews.nodes
   | map(select(.commit.oid == $pr.headRefOid) | .author.login)) as $head_reviewers
| $panel
  | map(select(. as $l | ($head_reviewers | index($l)) == null))
  | map(select(. as $l | ($requested | index($l)) == null))
  | .[]
