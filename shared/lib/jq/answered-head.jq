# answered-head.jq — the SIGNAL the session last posted: the head it answered a
# round at, and WHEN it said so (#133, #286). Input: the GraphQL pullRequest
# payload (comments.nodes[].author.login, .body, .createdAt). Args: $me (my
# login), $mark (the MARK_ANSWERED wire string). Output: one object,
# {sha, createdAt} — the 40-hex head SHA of my latest MARK_ANSWERED comment and
# its posting time — or {sha:"", createdAt:""} if I have not signalled a round
# answered on this PR.
#
# This is the whole of "the engine acts on the session's signal, never on commit
# activity" (#133's hardest must-fail): the engine requests only when this head
# equals the current head. A mid-fix WIP push moves the head away from the last
# signalled one, so the engine holds until the session signals again — it can
# never decide on its own that a round is done.
#
# The head alone made the licence a LEVEL condition — true at an unchanged head
# forever — so one signal posted before a round opened kept re-requesting the
# panel after that round had closed against the builder (#286: PR #281 cycled
# three verdicts on a tree nobody had touched). `createdAt` is what spends it:
# request-panel.jq requires the signal to be strictly newer than the verdict it
# claims to answer. The time is carried HERE, beside the sha it belongs to,
# because the licence is one fact — a caller re-deriving either half separately
# is the second copy of a predicate head-checks.jq's header warns about.
#
# Assumes the caller's payload carries a deep enough comments page for the latest
# MARK_ANSWERED to be present (duty-builder reads comments(last:100)). On a round
# so chatty the signal scrolls past that window the engine holds one extra tick
# until the next signal or re-tick — a delay, never a wrong request.
[ .data.repository.pullRequest.comments.nodes[]?
  | select((.author.login // "") == $me and ((.body // "") | startswith($mark)))
  | (.createdAt // "") as $at
  | ((.body | ltrimstr($mark) | capture("(?<sha>[0-9a-f]{40})").sha) // empty) as $sha
  | {sha: $sha, createdAt: $at} ]
| last // {sha: "", createdAt: ""}
