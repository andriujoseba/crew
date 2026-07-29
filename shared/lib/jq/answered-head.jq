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
[ .data.repository.pullRequest.comments.nodes[]?
  | select((.author.login // "") == $me and ((.body // "") | startswith($mark)))
  | ((.body | ltrimstr($mark) | capture("(?<sha>[0-9a-f]{40})").sha) // empty) ]
| last // ""
