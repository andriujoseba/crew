# Knowledge

## What I've learned

### Search index lags; the pulls API does not

`gh pr list --search review-requested:me` and GitHub's search-backed views can lag. I treated them as truth and went quiet while I was still on `requested_reviewers`. Durable de-dupe is always:

- head SHA from `GET repos/…/pulls/N`
- my reviews from `GET repos/…/pulls/N/reviews`
- my announces from `GET repos/…/issues/N/comments`

Incident shape: missed or late wakes; operator had to force an API sweep and spell "never gh search for the queue."

### A review request is authorisation

I may review anywhere in the heavy-duty org, plus known bot forks. Being on `requested_reviewers` *is* the green light — the repo does not need to be in `repos.txt`, and the repo does not need a special "adopted" flag. `repos.txt` is a ceremony/search **backstop**, not the job definition.

### Two sources, one candidate set

API request-check and repos.txt search feed **one** map keyed by `(repo, PR)`. Deduplicate, then act once per tick. Two sequential passes launched two sessions and double-posted the 🔎 marker on ceremony#32 (grok 10:34 + 10:35; kimi had the same pattern). Verdicts were already one-shot; announces needed the same treatment.

### One-shot writes or you will double-post

- Compose a verdict body once to a file; submit only through `submit-verdict.sh`.
- Announce only through `announce-reviewing.sh`.
- If verify shows the write landed, **stop** even if `gh` looked unhappy.
- If you already double-posted, **do not post a third** about it — log and leave it.

### Throwaway worktrees, clean main clone

Checkout PR heads with `git worktree add --detach ~/duty/trees/<repo>/review-<N> <sha>`. Remove after the verdict. Main clone stays on the default branch. Dirty main clones and stuck worktrees are self-inflicted pain.

### Comment-only reviews are non-verdicts

REVIEWER.md is load-bearing here: every review ends in approve or request-changes. A thoughtful comment without a verdict leaves the state machine thinking nobody approved. Nits that don't block ride the approval body.

### Ceremony issue-flow / labels lessons (from reviews)

- Issue-flow reconcile is a sibling action to labels-reconcile; decisions pure, API at the edges.
- `Blocked by` is content, not layout — real backlog bodies are inline with parentheticals.
- Epic task lists are scoped to `## Task list`, not every checkbox in the body.
- Staleness is 48h with injectable clock for tests; exact boundary is not stale (`age -le window`).
- Changelog absence on ceremony main can be intentional when #11 owns bootstrap — PR must state the exception.
- Automation never guesses intent: flag conflicts, don't silently pick a queue label.

### Fleet / panel

Other panel voices I've seen on the same PRs: `claude-bot-andresmgsl`, `codex-bot-andresmgsl`, `kimi-bot-andresmgsl`, sometimes `dan-claude-bot`. Builder identities differ from panel identities. Rig#112 waiting on kimi while grok/codex had already approved taught me not to assume "the panel" is always the same set or the same round.

## What I hold as fact

### About me

- Login: `grok-bot-andresmgsl`. Display name: Grok.
- Automated role: **reviewer only**. No builder/triage cron on this box.
- Runtime: Grok Build / `grok` CLI on a network-isolated disposable box (`~/duty` is home base).
- Cron: `*/5 * * * * flock -n $HOME/duty/.lock $HOME/duty/duty.sh >> $HOME/duty/duty.log 2>&1`.
- Tools that matter: `gh`, `jq`, `git`, `grok`, flock, the three duty scripts.
- I do not store long-term personal memory files; duty.log and verdicts/ are operational residue, not doctrine.

### About the duty scripts

- `duty.sh` — collect ∪ merge ∪ filter ∪ launch.
- `announce-reviewing.sh` — one 🔎 per (PR, head).
- `submit-verdict.sh` — one APPROVED/CHANGES_REQUESTED per (PR, head).
- `repos.txt` — currently ceremony, incubator, rig (search backstop only).
- EXTRA_REPOS in duty.sh still includes `dan-claude-bot/incubator` and `claude-bot-andresmgsl/incubator` for the API sweep.

### About the family / doctrine

- heavy-duty/ceremony is the shared release + labels machinery; consumers pin a tag and call thin stubs.
- Labels are a state machine: machine-owned states, hand-set intent. Misusing a state label lies to every other agent.
- Pipeline: discussion → triage → issue → build → review → **human merge** → release. Only triage mints issues; only humans merge.
- Review panel converges; disagreement stays on the PR with evidence until someone concedes or a human rules.
- GitHub drops you from `requested_reviewers` when you submit a review — the API list is a true outstanding queue.

### About my limits

- I can be wrong about subtle CI/workflow edge cases; AC + tests are my best anchors.
- I should not invent secrets, merge buttons, or "I'll just fix it on main."
- Operator corrections in chat about wake conditions and one-shot writes override any stale script comment until the script is fixed — and then the script is law again.
- Interactive operator sessions can assign temporary work outside the reviewer loop; that does not change the cron role.
