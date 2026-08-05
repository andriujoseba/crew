# near-miss-signal.jq — the SIGNAL THAT MISSED THE WIRE: a comment of mine that
# begins with an unsubstituted marker PLACEHOLDER and then names a head (#319).
# Input: the same GraphQL pullRequest payload answered-head.jq reads
# (comments.nodes[].author.login, .body, .createdAt, .id). Args: $me (my login).
# Output: one object, {sha, createdAt, id} — the 40-hex head named by my latest
# near-miss comment, when it was posted, and which comment it is — or
# {sha:"", createdAt:"", id:""} when I have posted no such comment here.
#
# A NEAR-MISS IS DETECTED, NEVER HONOURED. This predicate is not a second way to
# signal: nothing requests a panel from what it returns, and it deliberately
# lives in its own file rather than as a fallback branch inside answered-head.jq,
# because a fallback there is exactly how placeholder text becomes wire protocol.
# The engine acts only on the session's real signal (#133); all this says is
# "the session tried to signal and the wire did not carry it", which is the one
# fact that tells resume it has nothing to wait for.
#
# THE PLACEHOLDER IS THE EVIDENCE, and it is matched by SHAPE, not by name. Any
# `{{MARK_…}}` slot left unrendered is the same defect and gets the same answer:
# whichever marker the session meant, a ready PR of mine sitting at a head with
# no valid signal is owed the round-answered one, so resume's next act does not
# depend on which slot name survived. Anchored at the start for the same reason
# answered-head.jq uses startswith: a body that MENTIONS a placeholder — this
# comment's own prose, a reviewer quoting the incident — is discussion, not a
# botched signal, and must never make a PR resume-due.
#
# The sha is captured from what FOLLOWS the placeholder, never from the whole
# body, so a near-miss quoting some other commit before its head cannot name the
# wrong one. `.id` is carried because the WARN this feeds must point a reader at
# the exact comment; it is stringified because the two payload shapes disagree
# about its type (REST's numeric id, GraphQL's opaque node id) and the WARN
# prints either.
#
# Same page-depth assumption as answered-head.jq: the caller supplies a payload
# deep enough for the latest such comment to be present. A near-miss that has
# scrolled out of the window is not detected, and the PR falls back to the
# ordinary twelve-tick stranded path — a delay, never a wrong resume.
[ .data.repository.pullRequest.comments.nodes[]?
  | select((.author.login // "") == $me
           and ((.body // "") | test("^\\{\\{MARK_[A-Z0-9_]+\\}\\}")))
  | (.createdAt // "") as $at
  | ((.id // "") | tostring) as $id
  | ((.body | sub("^\\{\\{MARK_[A-Z0-9_]+\\}\\}"; "")
            | capture("(?<sha>[0-9a-f]{40})").sha) // empty) as $sha
  | {sha: $sha, createdAt: $at, id: $id} ]
| last // {sha: "", createdAt: "", id: ""}
