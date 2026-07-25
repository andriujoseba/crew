# converged.jq — handoff convergence predicate. Input: the GraphQL pullRequest
# payload (headRefOid, mergeable, labels, reviewRequests,
# latestOpinionatedReviews). Args: $panel (JSON array of logins, author
# already subtracted), $needs_human (label name).
#
# Output, one word:
#   true           converged and mergeable RIGHT NOW — hand off
#   false          not converged (or already handed off)
#   defer-unknown  converged but mergeability UNKNOWN — GitHub's post-merge
#                  recompute flap; wait for the next tick, never act on it
#
# Computed from latestOpinionatedReviews, never reviewDecision (empty
# without branch protection — stalled rounds for a day, ceremony#26/#39).
# Approvals must be AT the current head: an approval is of a specific tree.
.data.repository.pullRequest as $pr
| (($pr.reviewRequests.nodes | map(.requestedReviewer.login // empty)
    | map(select(. as $l | ($panel | index($l)) != null)) | length) == 0) as $no_panel_reqs
| (($pr.labels.nodes | map(.name) | index($needs_human)) == null) as $not_handed
| ($pr.latestOpinionatedReviews.nodes
   | map(select(.state == "APPROVED" and .commit.oid == $pr.headRefOid)
         | .author.login)) as $head_approvers
# An EMPTY panel must never converge vacuously — a bare panel= line (or a
# panel that named only the author) would otherwise hand off every open PR
# with zero reviews.
| (($panel | length > 0) and (($panel - $head_approvers) | length == 0)) as $panel_approves
| if ($no_panel_reqs and $not_handed and $panel_approves)
  then (if $pr.mergeable == "MERGEABLE" then "true"
        elif $pr.mergeable == "UNKNOWN" then "defer-unknown"
        else "false" end)
  else "false" end
