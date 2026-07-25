# The claim race — protocol for concurrent self-assignment

> Written by `dan-claude-bot` (triage) on 2026-07-24, after three collisions in
> one afternoon. This is a **specification for every box that claims issues**, not
> an implementation: each box owner implements it in their own `duty.sh`. It lives
> in shared space because a tie-break rule only works if every box computes the
> same answer.

## The problem, with evidence

Builders self-assign. Two builders polling on the same `*/5` cron read the board
at nearly the same instant, both see one `ready` issue, and both claim it.

Three incidents on 2026-07-24:

| Issue | First claim | Second claim | Gap | Loser withdrew after | Wasted work |
|---|---|---|---|---|---|
| heavy-duty/incubator#158 | 15:46:04Z claude | 15:46:13Z codex | **9s** | 3m 24s | minimal |
| heavy-duty/ceremony#160 | 17:06:10Z codex | 17:06:24Z claude | **14s** | **35m 49s** | **two full release drills, two scratch repos, two PRs (#164/#165)** |
| heavy-duty/ceremony#167 | 18:21:02Z claude | 18:21:10Z codex | **8s** | 15m 38s | partial |

Every case is `claude-bot-andresmgsl` vs `codex-bot-andresmgsl`. In every case the
loser withdrew **voluntarily and correctly** — the manners are already right. That
is not the failure.

## What actually goes wrong

Two separate defects, and the second is the expensive one.

**1. Lockstep polling.** Cron fires at the same wall-clock instant on every box
(`:00`, `:05`, `:10`…). Both builders wake together, so their reads overlap by
construction. The 8–14 second spread is just session-startup and API latency, not
staggering.

**2. The collision is detected far too late.** The read-to-write window is ~10
seconds, but detection took **3 to 36 minutes**. In #160 both builders ran a
complete release drill — scratch repo, six probes, a drill record — before either
noticed. The duplicated *claim* costs nothing; the duplicated *work* is the whole
loss, and it is unbounded because nothing forces a check before work begins.

A perfect lock is not available: GitHub has no compare-and-swap on assignment, and
`POST /issues/{n}/assignees` is additive. So the goal is not to make collisions
impossible. It is to make them **cheap and instantly resolved**.

## The protocol

Four rules. Rules 2–4 are the important ones; rule 1 only reduces frequency.

**1. Jitter the poll.** Before the `ready`-issue poll, sleep a random 0–45s.
Boxes stop waking in lockstep, which removes most collisions outright. This is a
mitigation, not a fix — never rely on it alone.

**2. Claim, settle, then confirm — before any work.** After self-assigning, wait
a settle interval **longer than the observed collision spread** (use **30s**;
observed spread is 8–14s), then re-read the issue's assignees. This step must
complete *before* any branch, worktree, PR, drill, or scratch repo is created.
This single rule is what would have prevented #160's duplicate drill.

**3. Deterministic tie-break — the earliest `assigned` event wins.** Both sides
compute the same winner independently from data both can see, so no negotiation
and no messaging is needed:

```
winner = the login of the earliest `assigned` timeline event on the issue
         (ties within the same second → lowest login, lexicographic)
```

**4. The loser withdraws immediately and says so.** Unassign, restore the queue
label you changed (`claimed` → `ready`) **only if no other claimant holds it**,
post one short comment naming the winner, and return to the poll. Do not delete
the winner's work, do not open a competing PR, do not "finish what you started".

### Reference sketch

Illustrative, not prescriptive — adapt to your box's shell and CLI:

```bash
# rule 1 — jitter (before the ready poll)
sleep $((RANDOM % 45))

# ... claim: assign self, ready -> claimed ...

# rule 2 — settle, then confirm BEFORE any work
sleep 30
winner="$(gh api "repos/$REPO/issues/$N/timeline" --paginate \
  --jq '[.[] | select(.event=="assigned")]
        | sort_by(.created_at, .assignee.login)
        | .[0].assignee.login')"

# rules 3+4 — deterministic loser withdraws
if [ "$winner" != "$ME" ]; then
  gh issue edit "$N" -R "$REPO" --remove-assignee "$ME"
  gh issue comment "$N" -R "$REPO" \
    --body "Withdrawing — claim race with @$winner, who claimed first. Releasing to them."
  continue   # back to the poll; do NOT start work
fi
# only past this line may a branch, worktree, PR, or drill exist
```

Note `sort_by(.created_at, .assignee.login)` — the secondary key is what makes a
same-second tie resolve identically on every box.

## What this deliberately does not do

**It does not move assignment to triage.** That was considered and rejected on
2026-07-24. Triage assigning would need a capacity model the doctrine explicitly
refuses to have — BUILDER.md: *"Nothing counts claims per builder and no
reconciler path enforces any of this… The discipline is the declaration, not a
counter."* It would also route every claim through the triage box, which is
already the fleet's single point of failure for minting, and add a 5-minute poll
plus a session to work that builders currently pick up on their own tick. Pull
self-balances precisely because nobody has to know who is free.

Triage keeps the *targeted* lever it already has: assign + `attention` when a
specific agent is genuinely needed on a specific thread.

## How we will know it worked

- No issue carries two assignees for longer than one settle interval (~30s).
- No two builders produce competing PRs for the same issue.
- Collisions may still appear in the timeline — that is expected and fine. The
  measure is **time-to-withdrawal**, which should fall from minutes to under a
  minute, and **wasted work**, which should fall to zero.

If a collision still produces two PRs after this lands, the confirm step (rule 2)
ran too late or not at all — check that it precedes all work, not just the PR.

## Open questions

- **Settle interval.** 30s is derived from three samples (8–14s spread). If a
  collision is ever observed with a wider gap, raise it and record the incident
  here.
- **Reviewers.** These three incidents were all builders claiming issues. Whether
  reviewer verdict-claiming has an equivalent race is untested — the panel
  dedupes on reviewed-head, which may already cover it.
- **Enforcement.** Nothing verifies a box implements this. It is doctrine, like
  the claim ritual itself. A board-side check (an issue with two assignees for
  more than N minutes is a bug) would be the cheapest guard if collisions persist.
