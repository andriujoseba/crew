# rounds.jq — the round partition, as one definition (#503).
#
# A jq MODULE, included with `-L <this directory>` and `include "rounds";`. It
# holds no top-level program and is never run with `-f`.
#
# WHY THIS FILE EXISTS. round-cap.jq's own header states the hazard it was
# written under: "Two programs partitioning the same thread into rounds by
# different rules would disagree about which round a builder is in, and the
# rendered `## Round log` is what a human reads that answer off. The partition
# is therefore copied expression for expression and pinned by a sibling
# fixture." That discipline held for two programs. #503 adds a third consumer —
# the per-issue round count triage reads as sizing evidence — and a third copy
# of an expression whose every clause was bought by a named failure is a third
# thing to keep true, with the drift silent because all three parse and only one
# of them is right. The same argument duty-builder.sh makes for
# `_RESUME_ISSUE_RE` being a constant with two consumers (#479), reached one
# consumer later.
#
# WHAT IS SHARED AND WHAT IS NOT. Only the partition lives here — which head
# SHAs received verdicts, and in what order. Every judgement built ON the
# partition stays with its consumer: the cap is a literal in round-cap.jq "and
# nowhere else" (#502 D1) and does not move here, and the distribution's
# arithmetic stays in round-count.jq. This module answers one question and takes
# no position on what its answer means.
#
# round-log.jq is deliberately NOT converted. Its partition is fused into a
# markdown rendering pipeline, the existing sibling fixture already pins it
# against round-cap.jq, and rewriting a landed renderer is not what #503 is.
# Three copies became two, and the fixture that pinned the remaining pair is
# untouched.

# round_verdicts — input: a GraphQL `pullRequest` node carrying `commits` and
# `reviews`. Output: one entry per opinionated verdict,
#
#   [ {oid, at, who, state}, … ]
#
# A ROUND IS KEYED BY THE HEAD SHA THAT RECEIVED AT LEAST ONE OPINIONATED
# VERDICT. APPROVED / CHANGES_REQUESTED only — a bare COMMENTED review is not a
# verdict and opens no round.
#
# THE BASE-MERGE REPAIR. GitHub re-points a review onto a base-merge commit
# created after the verdict was submitted; left alone that splits one round in
# two, or invents a round nobody voted in. Where the commit a review reports was
# committed AFTER the review was submitted, the verdict is moved back to the
# newest payload commit at or before its submission.
#
# `reviews`, never `latestOpinionatedReviews`: the latter carries one verdict per
# author, so four of a five-round history are invisible to it.
def round_verdicts:
  ( [ (.commits.nodes // [])[]
      | .commit
      | select(.oid != null and .committedDate != null) ]
    | sort_by(.committedDate) )                                    as $commits
  | [ (.reviews.nodes // [])[]
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
      | select(.commit.oid != null and .submittedAt != null)
      | . as $review
      | ([$commits[] | select(.oid == $review.commit.oid)] | first) as $reported
      | { oid: (if $reported != null
                   and $reported.committedDate > $review.submittedAt
                then ([$commits[]
                       | select(.committedDate <= $review.submittedAt)]
                      | last | .oid) // $review.commit.oid
                else $review.commit.oid
                end),
          at: $review.submittedAt,
          who: ($review.author.login // ""),
          state: $review.state } ];

# round_heads — input: the array round_verdicts returns. Output: one entry per
# round, in the order the rounds OPENED,
#
#   [ {oid, first}, … ]
#
# Ordered by when each head took its first verdict, never by commit date: a
# reviewer voting late on an older head belongs to the round that head opened.
def round_heads:
  group_by(.oid)
  | map({ oid: .[0].oid, first: (map(.at) | min) })
  | sort_by(.first);
