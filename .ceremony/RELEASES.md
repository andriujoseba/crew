# Release management

This file describes the release-management pattern available to governed
repositories. Adoption is per repository and operator-ruled: a repository
without version epics is not out of compliance. A repo-local roadmap is the
map; each epic remains the source of truth for its own release. Where an older
repo-local description differs from this file, this file governs.

## The ladder

Represent each planned release with one version epic. The epic is the working
surface for that release: it states the goal, names the members, and records
the ordered waves as checklists. Keep the machine-readable progress checklist
under a heading matching `## Task list`, case-insensitively; the issue-flow
sweep reads task rows there until the next heading when it decides whether to
nudge triage about a completed epic. Other member or wave headings are not
completion inputs.

Keep a short repo-local roadmap beside the epics. The roadmap shows the whole
ladder and points to each working surface; it does not duplicate the live
member lists or ordering. crew's roadmap discussion [heavy-duty/crew#338](https://github.com/heavy-duty/crew/discussions/338)
maps the ladder whose `0.1.2` working surface moved from the crufty ledger
[heavy-duty/crew#162](https://github.com/heavy-duty/crew/issues/162) to
[heavy-duty/crew#346](https://github.com/heavy-duty/crew/issues/346).

## Gates

Each version epic declares `Blocked by <predecessor>`. Special ordering — a
double gate or an out-of-chain gate — is written explicitly on that epic;
there is no hidden global schedule. The epic carries `epic` and the
repository's release label, with no queue label. Its `Blocked by` line is a
declaration a human reads: shipping closes the predecessor, then triage opens
the next window by hand as the first step of release-init. The issue-flow
sweep does not promote version epics; automating that gate would require a
separately specified change to its queue-category model.

The gate orders windows, not their contents. Members enter a release only by
decision during release-init. The double gate on
[heavy-duty/crew#163](https://github.com/heavy-duty/crew/issues/163) and the
out-of-chain track on [heavy-duty/crew#348](https://github.com/heavy-duty/crew/issues/348)
are worked examples of exceptions declared where they apply.

## Release-init

The predecessor closing and clearing the next epic's declared gate is the
trigger, and today triage must notice it and open that window by hand.
[heavy-duty/ceremony#253](https://github.com/heavy-duty/ceremony/issues/253)
tracks the not-yet-shipped sweep announcement of that duty; do not treat the
announcement as present until the consumer's pin carries it. Triage runs five
steps:

1. Mint the epic's “to mint when this arc opens” list together with findings,
   deferred work, and discussion outcomes accumulated since the epic was
   written. Each member initially declares `Blocked by <the epic>`.
2. Graph hard `Blocked by` edges and same-file clusters on the epic.
3. Write the waves into the epic body as checklists in claim order, with a
   separate verification lane and the progress view under `## Task list`.
4. Ask the operator to bless the order, then have triage open the first wave
   by applying the flip mechanics below. The operator's blessing is the one
   step this chain never automates.
5. Ship through the repository's cut process, close the epic, and treat that
   close as the trigger for the next window.

heavy-duty/crew#346 is the worked wave plan; its graph made both hard edges
and shared-file contention visible before builders entered the queue. If init
finds no work worth minting, the operator either folds the empty window into a
later release or skips the version, recording that ruling on the epic before
closing it unshipped.

## One primary window, declared parallel tracks

Run one primary release window by default. A cut takes whatever has landed, so
interleaving unrelated windows blurs both the release story and the evidence
behind it. Gates open windows; they do not silently admit members, so builders
still see one deliberately ordered queue.

While a window stands — an open release-labeled issue with a non-empty
enumerated gate — its members form a DAG whose sink is the release issue.
Every member reaches that sink. Members declare only their immediate
predecessors; ordering edges live on members, while the sink records membership
only; and the `ready` set is exactly the graph's current sources. Every close
releases exactly its declared successors, and that whole set is concurrently
claimable: a member may have multiple successors, while the collision rule
already orders any that share a deliverable. Insertion re-points downstream
edges rather than merely appending membership at the sink. It follows that
every `ready` issue is a gate member. `epic` and `post-merge` issues are exempt
because neither is claimable (#292).

The operator may declare a parallel track at init when its footprint is
disjoint from the primary window: another repository, another artifact, or
provably non-overlapping clusters. The declaration names the boundary and any
bridge work that must rejoin the primary. [heavy-duty/crew#348](https://github.com/heavy-duty/crew/issues/348)
is the worked example: its app and artifact form a parallel track while its
small crew-side bridge remains in the primary window.

## Flip mechanics

To admit a member, delete or rewrite its literal, parseable
`Blocked by <the epic>` declaration and swap `blocked` to `ready` in the same
edit. Markdown or HTML strikethrough is insufficient: the blocker parser reads
the raw marker text and still returns the reference. Never preserve history by
negating the marker phrase — the parser unions declarations even when prose
says they no longer apply. Preserve the history only after rewriting the
marker into non-parseable prose, then verify that the parser returns an empty
set for the release gate.

Release membership is a decision, never a sweep default. Triage performs each
flip only after the operator blesses the wave; the issue-flow sweep may resolve
ordinary issue dependencies, but it does not choose a release's contents.
heavy-duty/crew#346 records the member-by-member flip that opened its first
wave.

## The ledger pattern

When a release epic has become too crufty to remain a clear working surface,
create a replacement and treat the old epic as a ledger. Do not close the old
epic until every live member declaration points at the replacement and the
blocker parser verifies the new set. Closing early can release every member
that still names the old issue.

The [heavy-duty/crew#162](https://github.com/heavy-duty/crew/issues/162) to
[heavy-duty/crew#346](https://github.com/heavy-duty/crew/issues/346)
transition is the worked example: all member declarations were re-pointed and
parse-verified before #162 closed; #162 remains the historical record while
#346 is the release's working surface.
