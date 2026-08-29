# round-log.jq — render review-round facts into the PR body's rolling
# `## Round log` summary (#504, ceremony#418). Input: the GraphQL pullRequest
# payload (body, reviews, comments). Args: $me (the author/builder login) and
# $final (true only at the handoff straggler — see the live-round note below).
#
# Output: the NEW body when there is something to render, or the empty string
# when every round is already recorded. Each rendered round is keyed by the
# legacy-compatible `<!-- round:<head-sha> -->` marker, so retries are no-ops
# and bodies that already carry verbatim mirrored replies are never rewritten.
#
# The builder owns `### Current state` and the `requested` / `done` prose cells.
# The engine owns only the other four cells: round number, head, verdict facts,
# and a permalink to the author's existing reply comment. If the builder has
# already written the row, its two trailing prose cells are preserved exactly.
# If no row exists, the engine adds one with em-dash prose placeholders; the
# doctrine's handoff precondition still requires the builder to fill them.
# Reply bytes never enter the body.
#
# A "round" is keyed by the head SHA that received at least one opinionated
# verdict (APPROVED / CHANGES_REQUESTED — a bare COMMENTED review is not a
# verdict). GitHub can re-point a review to a base-merge commit created after
# the verdict. That impossible key is repaired to the newest payload commit at
# or before the verdict; when history has no such commit, the reported key is
# retained rather than guessed.
#
# The reply permalink is the newest author comment after that round's newest
# verdict and before the next round's first verdict. The comment itself is not
# edited or deleted. A unanimously passing terminal round can have no written
# reply, in which case the fact cell is an em dash.
#
# The LIVE round — the current head, or the last one when no next round closes
# its reply window — is NOT finalized during a per-tick render ($final=false).
# Per-tick rendering records only superseded rounds; handoff passes $final=true
# to finalize the terminal round.

def fact_header:
  "| # | head | verdicts | reply | requested | done |";

def fact_rule:
  "| --- | --- | --- | --- | --- | --- |";

def round_section_scaffold:
  "### Current state\n\n"
  + "<!-- What the PR does now, and what is outstanding. Budget: 1,500 chars. -->\n\n"
  + "### Rounds\n\n"
  + "<!-- One row per round. Prose cells: 500 chars each. -->\n\n"
  + fact_header + "\n" + fact_rule;

# Add the current doctrine's table without disturbing existing body bytes. A
# pre-doctrine `### Rounds` subsection may remain above it during migration;
# legacy round markers make those old entries ineligible for rendering again.
def ensure_fact_table:
  if contains(fact_header) then .
  elif contains("\n## Round log") then
    split("\n## ") as $parts
    | [ $parts[]
        | if startswith("Round log")
          then (. + "\n\n" + round_section_scaffold)
          else .
          end ]
    | join("\n## ")
  else . + "\n\n## Round log\n\n" + round_section_scaffold
  end;

def row_indices($lines; $header_i):
  [ range($header_i + 2; $lines | length)
    | select($lines[.] | startswith("| "))
    | select(($lines[.] | startswith("| ---")) | not) ];

# Render one row. Only the four leading fact cells are replaced; everything
# after the fourth separator is the builder's requested/done prose and is
# carried byte-for-byte. When no authored row exists, append the fixed shape.
def render_round($round):
  if contains($round.marker) then .
  else
    ensure_fact_table
    | split("\n") as $lines
    | ([range(0; $lines | length) | select($lines[.] == fact_header)] | last) as $header_i
    | row_indices($lines; $header_i) as $rows
    | ($round.number - 1) as $row_n
    | ("| " + ($round.number | tostring)
       + " | `" + $round.oid + "`"
       + " | " + $round.verdict_text
       + " | " + $round.reply_text + " |") as $facts
    | if $row_n < ($rows | length) then
        ($rows[$row_n]) as $row_i
        | ($lines[$row_i]
           | (capture("^\\|[^|]*\\|[^|]*\\|[^|]*\\|[^|]*\\|(?<prose>.*)$")? // null)
           | if . == null then null else .prose end) as $prose
        | if $prose == null then
            ($lines[0:$row_i]
             + [$facts + " — | — |", $round.marker]
             + $lines[$row_i + 1:]
             | join("\n"))
          else
            ($lines[0:$row_i]
             + [$facts + $prose, $round.marker]
             + $lines[$row_i + 1:]
             | join("\n"))
          end
      else
        (($rows | last) // ($header_i + 1)) as $insert_i
        | ($lines[0:$insert_i + 1]
           + [$facts + " — | — |", $round.marker]
           + $lines[$insert_i + 1:]
           | join("\n"))
      end
  end;

.data.repository.pullRequest as $pr
| ($pr.body // "")                                                as $body
| [ ($pr.commits.nodes // [])[]
    | .commit
    | select(.oid != null and .committedDate != null) ]
  | sort_by(.committedDate)                                      as $commits
| [ ($pr.reviews.nodes // [])[]
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
        author: ($review.author.login // "unknown"),
        state: $review.state,
        at: $review.submittedAt} ]                                as $verdicts
| [ ($pr.comments.nodes // [])[]
    | select(.author.login == $me)
    | select(.createdAt != null)
    | {url: .url, at: .createdAt} ]
  | sort_by(.at)                                                  as $mine
| ( $verdicts | group_by(.oid)
    | map({ oid: .[0].oid,
            newest: (map(.at) | max),
            first:  (map(.at) | min),
            verdicts: (sort_by(.at)
                       | group_by(.author)
                       | map(last)
                       | sort_by(.author)) })
    | sort_by(.first) )                                           as $rounds
| ($rounds | length)                                              as $n
| [ range(0; $n) as $i
    | $rounds[$i] as $r
    | select($final or ($i + 1 < $n
                        and $r.oid != ($pr.headRefOid // "")))
    | (if $i + 1 < $n then $rounds[$i + 1].first else null end) as $next
    | ([ $mine[]
         | select(.at > $r.newest and ($next == null or .at < $next)) ]
       | last) as $reply
    | { number: ($i + 1),
        oid: $r.oid,
        marker: ("<!-- round:" + $r.oid + " -->"),
        verdict_text: ($r.verdicts
          | map("@" + .author + " "
                + (if .state == "APPROVED" then "approved"
                   else "requested changes" end))
          | join("; ")),
        reply_text: (if $reply == null then "—"
                     elif $reply.url != null
                     then "[reply](" + $reply.url + ")"
                     else error("round reply has no permalink") end) } ] as $renderable
| (reduce $renderable[] as $round ($body; render_round($round)))  as $newbody
| if $newbody == $body then "" else $newbody end
