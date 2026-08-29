# round-count.jq — every issue's round count, and the board's distribution of
# them, as sizing evidence for triage (#503). Input: a JSON array of GraphQL
# `pullRequest` nodes — OPEN, CLOSED and MERGED alike — each carrying `number`,
# `state`, `body`, `commits` and `reviews`. Args: $re (the closes/refs pattern,
# passed rather than inlined) and $cap (the round cap, read from round-cap.jq).
# Output: one object,
#
#   { "cap": 5,
#     "issues": [ {"issue": 503, "rounds": 8, "prs": [566, 586]}, … ],
#     "distribution": {"issues": 12, "min": 1, "median": 3, "max": 14,
#                      "at_or_over_cap": 2, "pending": 1, "unattributed": 4} }
#
# THE COUNT IS THE SAME NUMBER round-cap.jq REPORTS, and it is the same number
# because it is the same partition: both include rounds.jq. What differs is only
# what is asked of it. round-cap.jq asks a PR whether it has reached the cap —
# builder-side, per-PR, open PRs only, and interesting exactly when a PR stalls.
# This program asks the board what a round count NORMALLY is here, which is a
# question about issues and about history, and it is the half doctrine's sizing
# rule reads (`TRIAGE.md` `## Sizing`, ceremony#419).
#
# IT IS REPORTED AGAINST THE ISSUE, NOT THE PR (#503 D2), because the sizing
# decision is about the issue and outlives every PR that carried it. So each
# issue contributes exactly ONE figure — the rounds of every PR that named it,
# summed.
#
# WHICH IS ALSO WHY A CUT CHAIN COUNTS ONCE. The round cap closes a predecessor
# and opens a successor on the same branch, and step 3 of the cut edits the
# predecessor's body `Closes #N` → `Refs #N` so that only one of the two claims
# to close the issue. Both still NAME it, so both land in the same group and a
# five-round predecessor followed by a three-round successor is one issue at
# eight rounds — never two observations of five and three, which would report
# the cap as ordinary and halve the very issue the evidence exists to show.
#
# ...AND WHY THIS DOES NOT USE `closingIssuesReferences`. GitHub's closing graph
# is authoritative for `Closes #N` and is what `refs-not-closing` reads (#200,
# #218), but it holds no entry at all for a `Refs #N` PR — so it would see the
# successor and lose the predecessor, which is precisely the chain this
# criterion is about. The body pattern matches both forms and is therefore the
# only one that can sum a chain. It is duty-builder.sh's `_RESUME_ISSUE_RE`,
# passed in rather than restated for the reason that constant already gives:
# "a second copy of a regex whose every clause was bought by a named failure is
# a second thing to keep true, and the drift would be silent" (#479).
#
# EVIDENCE, AND NOTHING ELSE (#503 D4). This program emits no verdict, no
# threshold and no recommendation. It says what the numbers are and stops; the
# judgement is triage's. `at_or_over_cap` is not a threshold crew picked — it is
# the ruled five, read from round-cap.jq where the literal lives "and nowhere
# else" (#502 D1), and it is reported as one figure of a distribution rather
# than as a test any issue passes or fails. A bare number would invite exactly
# the threshold D3 refuses.
#
# ZEROS ARE HELD OUT OF THE DISTRIBUTION AND COUNTED SEPARATELY, as `pending`.
# An issue whose only PR opened an hour ago has taken no rounds YET, and folding
# that 0 into the median answers a different question — "how far along is the
# board" rather than "what does an issue cost here" — by dragging the figure
# triage reads down with work that has not happened. They are reported rather
# than dropped, because a filter nobody can see is a filter nobody can check.
# `unattributed` is the same honesty about coverage: PRs whose body names no
# issue are in no issue's total, and the count says how many.
include "rounds";
[ .[]
  | select(.number != null)
  | { number: .number,
      issue: (first((.body // "") | capture($re; "i") | .n) // ""),
      rounds: (round_verdicts | round_heads | length) } ]      as $prs
| ( [ $prs[] | select(.issue != "") ]
    | group_by(.issue)
    | map({ issue:  (.[0].issue | tonumber),
            rounds: (map(.rounds) | add),
            prs:    (map(.number) | sort) })
    | sort_by([-.rounds, .issue]) )                            as $issues
| [ $issues[] | select(.rounds > 0) | .rounds ] | sort         as $values
| ($values | length)                                           as $n
| { cap: $cap,
    issues: $issues,
    distribution:
      { issues:         $n,
        min:            (if $n == 0 then 0 else $values[0] end),
        median:         (if $n == 0 then 0
                         elif ($n % 2) == 1 then $values[(($n - 1) / 2) | floor]
                         else (($values[($n / 2 | floor) - 1]
                                + $values[($n / 2 | floor)]) / 2)
                         end),
        max:            (if $n == 0 then 0 else $values[$n - 1] end),
        at_or_over_cap: ([$values[] | select(. >= $cap)] | length),
        pending:        ([$issues[] | select(.rounds == 0)] | length),
        unattributed:   ([$prs[] | select(.issue == "")] | length) } }
