# round-cap.jq — how many rounds this PR has carried, and whether the round cap
# has been reached (#502). Input: the GraphQL pullRequest payload (headRefOid,
# commits, reviews). Args: $panel (JSON array of logins, author already
# subtracted). Output: one compact object,
#
#   {"rounds": <n>, "cap": 5, "at_cap": true|false}
#
# THE CAP IS A LITERAL HERE AND NOWHERE ELSE. Doctrine: "A PR carries at most
# five rounds … Round six never opens on the same PR. Five is ruled, not derived
# from any measurement, and no build re-derives it (#420)." A configuration key
# would be re-derivation with extra steps and a per-role override would be a
# licence for some role to open round six, so the number is written once, in the
# predicate, where no conf file and no environment can reach it (#502 D1).
#
# THE ENGINE COUNTS; IT DOES NOT CUT. Doctrine again: "nothing counts rounds for
# you, nothing enforces the cut, and nothing stops a sixth round on one PR. Where
# an engine does count and says the boundary is here, that is instruction and
# never performance." This program is the whole of the counting, and its consumer
# emits an instruction and suppresses one request — it opens no PR, closes none,
# and edits no body (#502 D2).
#
# A ROUND IS KEYED THE WAY round-log.jq KEYS ONE, deliberately and to the letter:
# the head SHA that received at least one opinionated verdict (APPROVED /
# CHANGES_REQUESTED — a bare COMMENTED review is not a verdict), with GitHub's
# re-point of a review onto a base-merge commit created after the verdict
# repaired to the newest payload commit at or before it. Two programs partitioning
# the same thread into rounds by different rules would disagree about which round
# a builder is in, and the rendered `## Round log` is what a human reads that
# answer off. The partition is therefore copied expression for expression and
# pinned by a sibling fixture — round-cap.jq's count must equal the number of
# rounds round-log.jq renders for the same payload — which is the same discipline
# addressing.jq and converged.jq keep against each other (#130).
#
# `reviews`, never `latestOpinionatedReviews`: the latter carries one verdict per
# author, so four of a five-round history are invisible to it.
#
# WHY at_cap NEEDS THE ROUND TO HAVE CLOSED. Doctrine "permits no mid-round cut —
# the cut already spends the approvals, and cutting mid-round spends a round's
# work on top of them". A bare `rounds >= 5` reaches true on round 5's FIRST
# verdict, with two panelists still reading, so the instruction would arrive
# while the round it names is still open. The closing term is the one
# addressing.jq draws — every panelist holds an opinionated verdict at that
# round's head — asked of the FIFTH round's head rather than of the current one,
# because the two stop being the same commit the moment the builder pushes the
# round's fixes and the cut must still stand after that push.
#
# ...AND WHY IT ALSO NEEDS THE ROUND TO HAVE CLOSED *WITHOUT FULL APPROVAL*.
# addressing.jq's round-close term is TWO conjuncts, not one — every panelist
# reviewed this head AND at least one did not approve — and taking only the first
# made this program true on a fifth round that closed UNANIMOUSLY APPROVED. That
# is the ordinary way a long PR finally passes, and there the engine both handed
# the PR to the human (converged.jq is true on the same tick) and, because the
# census enumerates open authored PRs until a human merges them, named it for the
# cut in every builder-side prompt for the whole of that window — beside an
# instruction whose step 4 is "Close the predecessor". Found by two reviewers on
# PR #566; the mirror this header already claimed is now actually implemented.
#
# The cut is written for a round that closed with WORK STILL OWED, and every part
# of doctrine says so: step 1 is "Answer round 5 whole … Push the fixes", which a
# unanimous close has nothing to do; step 2's rationale is "the cut spends every
# approval, so a verdict bought on the predecessor is a verdict on a PR that will
# never merge", whose premise fails exactly when the predecessor is about to
# merge; and the cap is justified as a consensus-surface rule — "the longer a PR
# runs the harder it is to bring the whole panel onto one head" — so the state
# where the panel IS on one head is the outcome it exists to reach. "Round six
# never opens on the same PR" is satisfied there by the merge, with no cut.
#
# THE CARVE-OUT IS NARROWER THAN "NOT CONVERGED", deliberately. It asks that the
# full approval STILL STAND AT THE CURRENT HEAD. Where the fifth round closed
# fully approved and the builder has since pushed, those approvals are spent,
# converged.jq is false, the panel is re-requested, and the verdicts that land
# form ROUND SIX on the same PR — the one thing doctrine forbids outright. So a
# stale full approval stays AT the cap, and only a live one lifts it. A plain
# "did the fifth round approve?" test would have opened that hole.
#
# Under a triage ruling ask (#566): this narrows #502's unconditionally-worded
# acceptance criterion, and if the ruling goes the other way it is this conjunct
# that comes back out.
#
# An EMPTY panel never closes a round vacuously, the guard addressing.jq and
# converged.jq both carry against a bare `panel=` line.
.data.repository.pullRequest as $pr
| 5                                                                as $cap
| [ ($pr.commits.nodes // [])[]
    | .commit
    | select(.oid != null and .committedDate != null) ]
  | sort_by(.committedDate)                                        as $commits
| [ ($pr.reviews.nodes // [])[]
    | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
    | select(.commit.oid != null and .submittedAt != null)
    | . as $review
    | ([$commits[] | select(.oid == $review.commit.oid)] | first)  as $reported
    | { oid: (if $reported != null
                 and $reported.committedDate > $review.submittedAt
              then ([$commits[]
                     | select(.committedDate <= $review.submittedAt)]
                    | last | .oid) // $review.commit.oid
              else $review.commit.oid
              end),
        at: $review.submittedAt,
        who: ($review.author.login // ""),
        state: $review.state } ]                                   as $verdicts
| ( $verdicts | group_by(.oid)
    | map({ oid: .[0].oid, first: (map(.at) | min) })
    | sort_by(.first) )                                            as $rounds
| ($rounds | length)                                               as $n
# The cap-th round, by the order rounds opened. Reading index $cap-1 rather than
# the last one is what keeps the answer monotone: a sixth round that opened in
# spite of the rule does not un-close the fifth.
| (if $n >= $cap then $rounds[$cap - 1].oid else null end)         as $cap_oid
# One verdict per reviewer at the cap round's head — the LATEST, which is what
# latestOpinionatedReviews hands addressing.jq for the current head. `reviews`
# carries the whole thread, so a panelist who requested changes and then approved
# at the same head appears twice, and counting them as "not approved" would hold a
# PR at the cap the panel had in fact released.
| ( $verdicts | map(select(.oid == $cap_oid))
    | group_by(.who)
    | map({ who: .[0].who,
            state: (sort_by(.at) | last | .state) }) )             as $cap_latest
| ( $cap_latest | map(.who) )                                      as $cap_reviewers
| ( $cap_latest | map(select(.state == "APPROVED") | .who) )       as $cap_approvers
# addressing.jq's two conjuncts, asked of the cap round's head.
| ( ($panel | length) > 0
    and $cap_oid != null
    and (($panel - $cap_reviewers) | length) == 0 )                as $cap_round_closed
| ( (($panel - $cap_approvers) | length) == 0 )                    as $cap_round_approved
# ...and the third term, which is not addressing.jq's because addressing.jq only
# ever asks about the current head: do those approvals still stand on the tree the
# PR is at now? A cut is owed unless the fifth round left the PR finished.
| ( $cap_oid == $pr.headRefOid )                                   as $approvals_stand
| { rounds: $n,
    cap: $cap,
    at_cap: ( $cap_round_closed
              and (($cap_round_approved and $approvals_stand) | not) ) }
