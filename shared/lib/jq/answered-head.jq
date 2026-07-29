# answered-head.jq — the head the session last SIGNALLED a round answered at
# (#133). Input: the GraphQL pullRequest payload (comments.nodes[].author.login,
# .body). Args: $me (my login), $mark (the MARK_ANSWERED wire string). Output:
# the 40-hex head SHA of my latest MARK_ANSWERED comment, or "" if I have not
# signalled a round answered on this PR.
#
# This is the whole of "the engine acts on the session's signal, never on commit
# activity" (#133's hardest must-fail): the engine requests only when this head
# equals the current head. A mid-fix WIP push moves the head away from the last
# signalled one, so the engine holds until the session signals again — it can
# never decide on its own that a round is done.
#
# Assumes the caller's payload carries a deep enough comments page for the latest
# MARK_ANSWERED to be present (duty-builder reads comments(last:100)). On a round
# so chatty the signal scrolls past that window the engine holds one extra tick
# until the next signal or re-tick — a delay, never a wrong request.
[ .data.repository.pullRequest.comments.nodes[]?
  | select((.author.login // "") == $me and ((.body // "") | startswith($mark)))
  | ((.body | ltrimstr($mark) | capture("(?<sha>[0-9a-f]{40})").sha) // empty) ]
| last // ""
