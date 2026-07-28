# round-log.jq — mirror each whole-round reply into the PR body's `## Round
# log` (#91, ceremony#196 option B). Input: the GraphQL pullRequest payload
# (body, reviews, comments). Args: $me (the author/builder login) and $final
# (true only at the handoff straggler — see the live-round note below).
#
# Output: the NEW body when there is something to append, or the empty string
# when every round is already recorded (the caller writes nothing then, so a
# retried tick is a no-op — the same discipline post-once.sh applies to a
# comment, applied to the body).
#
# A "round" is a head SHA that received at least one opinionated verdict
# (APPROVED / CHANGES_REQUESTED — a bare COMMENTED review is not a verdict).
# Its reply is the author's comments posted AFTER that round's newest verdict
# and BEFORE the next round's first verdict — the window in which the builder
# answers the round whole before pushing the fix that opens the next one. Each
# entry carries `<!-- round:<head-sha> -->`; an entry whose marker is already
# in the body is skipped, so this is idempotent under crash-retry. A round the
# builder answered with no comment is recorded as passed without one and never
# blocks the handoff.
#
# The LIVE round — the last one, with no next round to close its reply window —
# is NOT finalized during a per-tick mirror ($final=false). Because the mirror
# now runs every tick (#91 B1), a round's FIRST verdict would otherwise stamp
# `<!-- round:<head> -->` with "no written reply" while the remaining verdicts
# and the builder's whole-round reply are still arriving — and the already-in-
# body skip would then lock the real reply out forever. So per-tick we record
# only SUPERSEDED rounds ($i+1 < $n), whose window is closed; the live round's
# reply is never lost (it lives in the comments and is recorded once a newer
# round supersedes it, or at handoff). The handoff straggler passes $final=true
# to finalize the last round too — that is where the terminal round that
# legitimately passed with no written reply is recorded.
.data.repository.pullRequest as $pr
| ($pr.body // "")                                                as $body
| [ ($pr.reviews.nodes // [])[]
    | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
    | select(.commit.oid != null and .submittedAt != null)
    | {oid: .commit.oid, at: .submittedAt} ]                      as $verdicts
| [ ($pr.comments.nodes // [])[]
    | select(.author.login == $me)
    | {body: .body, at: .createdAt} ]                             as $mine
| ( $verdicts | group_by(.oid)
    | map({ oid: .[0].oid,
            newest: (map(.at) | max),
            first:  (map(.at) | min) })
    | sort_by(.first) )                                           as $rounds
| ($rounds | length)                                              as $n
| [ range(0; $n) as $i
    # Defer the live (last) round unless $final: only a superseded round is
    # closed enough to finalize per-tick. See the header note.
    | select($i + 1 < $n or $final)
    | $rounds[$i] as $r
    | (if $i + 1 < $n then $rounds[$i + 1].first else null end) as $next
    | { oid: $r.oid,
        marker: ("<!-- round:" + $r.oid + " -->"),
        replies: [ $mine[]
                   | select(.at > $r.newest and ($next == null or .at < $next))
                   | .body ] } ]
  | map(. as $e | select(($body | contains($e.marker)) | not))   as $todo
| if ($todo | length) == 0 then ""
  else
    ( $todo
      | map( .marker + "\n\n"
             + "**Round at " + (.oid[0:8]) + "**\n\n"
             + ( if (.replies | length) == 0
                 then "_Round passed with no written reply._"
                 else (.replies | join("\n\n")) end ) )
      | join("\n\n") + "\n" )                                     as $additions
    # Insert newest-last inside the `## Round log` section — before the next
    # heading if one follows, else at the section's end. Splitting on "\n## "
    # keeps every other section byte-identical; the preamble ($parts[0]) has no
    # heading prefix, which join restores for the rest.
    | ($body | split("\n## "))                                   as $parts
    | ( [ $parts[] | select(startswith("Round log")) ] | length ) as $has_section
    | if $has_section > 0
      then ( [ $parts[]
               | if startswith("Round log")
                 then (. + "\n\n" + $additions)
                 else . end ]
             | join("\n## ") )
      else ($body + "\n\n## Round log\n\n" + $additions)
      end
  end
