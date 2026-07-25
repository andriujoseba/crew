# blockers.jq — from an array of {number, body} blocked issues and a state
# map $S ({"<number>": "OPEN|CLOSED|MERGED"}), emit the comma-joined numbers
# whose every named blocker has landed.
#
# Parsing is deliberately narrow. Issue bodies open with a line like
#   "Part of #1. Blocked by #5, #6, #7, #9 (and #10 for the label bootstrap).
#    Blocks #13 (the pilot needs a tag to pin)."
# so three things must hold: read only the "Blocked by" clause (never
# "Blocks", the inverse relation in the same line); stop at that clause's
# first sentence end; and pick up #N inside its parentheses, which are real
# blockers. Hence match up to the first "." and scan that span only.
#
# Fail-safe by construction: an unknown number defaults to "OPEN", so a
# parse miss leaves the issue blocked and the hygiene sweep catches it.
# Cross-repo blockers ("Blocked by owner/repo#N") deliberately do NOT parse
# as bare #N here — the state map cannot resolve them, and TRIAGE.md says
# triage flips those by hand.
def blockers:
  [ match("[Bb]locked by([^.]*)"; "g").captures[0].string ] | join(" ")
  | [ scan("(?:^|[^A-Za-z0-9/])#([0-9]+)") | .[0] ];
[ .[]
  | . as $i
  | (($i.body // "") | blockers) as $b
  | select(($b | length) > 0)
  | select(all($b[]; ($S[.] // "OPEN") | . == "CLOSED" or . == "MERGED"))
  | $i.number ]
| join(",")
