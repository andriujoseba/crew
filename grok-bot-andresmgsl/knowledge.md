# Knowledge

## Only-mine — not in any doctrine yet

These items are **not** written in REVIEWER.md / BUILDER.md / TRIAGE.md / CONTRIBUTING / the `.ceremony` mirror. They live in my duty scripts, duty.log lessons, or operator corrections that never landed as repo doctrine:

1. GitHub **search index lags**; queue truth is `requested_reviewers` + pulls/reviews APIs — never `gh search` / `review-requested:` search alone.
2. **A review request is authorisation** across the whole heavy-duty org (+ known bot forks); `repos.txt` is a backstop, not the job definition; repo need not be “adopted.”
3. **Two candidate sources must merge into one set** keyed by `(repo, PR)` before any launch — sequential passes double-fired sessions.
4. **One-shot announce path** (`announce-reviewing.sh`) mirroring one-shot verdicts; refuse a third 🔎 if already doubled.
5. **Throwaway detached worktrees** under `~/duty/trees/…` for PR heads (operational rule on this box; not in REVIEWER.md prose).
6. **My concrete duty stack**: cron `*/5` + flock, `duty.sh` / `submit-verdict.sh` / `announce-reviewing.sh`, EXTRA_REPOS, repos.txt contents.
7. **Identity / role on this box**: login, reviewer-only automation, no long-term memory files, tools list.
8. **Operator chat overrides stale script comments** until the script is fixed; then the script is law again.
9. **Interactive sessions ≠ cron role** — ad-hoc operator work does not change the automated reviewer loop.
10. **Fleet panel membership as lived** (four bots on family panels; conversion can ship a stale roster — see rig#120 correction below).
11. **Personal limits** I hold for myself (CI edge-case weakness; no merge; no inventing secrets).
12. **Ceremony issue-flow implementation details learned in review** that may exist only in issue #18 / the PR, not as standing role doctrine (parser shapes, injection seam, changelog bootstrap exception pattern).

---

## What I've learned

### [only-mine] Search index lags; the pulls API does not

`gh pr list --search review-requested:me` and GitHub's search-backed views can lag. I treated them as truth and went quiet while I was still on `requested_reviewers`. Durable de-dupe is always:

- head SHA from `GET repos/…/pulls/N`
- my reviews from `GET repos/…/pulls/N/reviews`
- my announces from `GET repos/…/issues/N/comments`

Incident shape: missed or late wakes; operator had to force an API sweep and spell "never gh search for the queue." Encoded in `duty.sh` / `submit-verdict.sh` / `announce-reviewing.sh`, not in REVIEWER.md.

### [only-mine] A review request is authorisation

I may review anywhere in the heavy-duty org, plus known bot forks. Being on `requested_reviewers` *is* the green light — the repo does not need to be in `repos.txt`, and the repo does not need a special "adopted" flag. `repos.txt` is a ceremony/search **backstop**, not the job definition. Operator rule + duty.sh behavior; not written as family doctrine in-repo.

### [only-mine] Two sources, one candidate set

API request-check and repos.txt search feed **one** map keyed by `(repo, PR)`. Deduplicate, then act once per tick. Two sequential passes launched two sessions and double-posted the 🔎 marker on ceremony#32 (grok 10:34 + 10:35; kimi had the same pattern). Verdicts were already one-shot; announces needed the same treatment. Lives in `duty.sh` after the 2026-07-23 fix.

### [only-mine] One-shot writes or you will double-post

- Compose a verdict body once to a file; submit only through `submit-verdict.sh`.
- Announce only through `announce-reviewing.sh`.
- If verify shows the write landed, **stop** even if `gh` looked unhappy.
- If you already double-posted, **do not post a third** about it — log and leave it.

Box-local scripts + operator protocol. Related spirit of “one verdict per head” appears in panel practice but the mechanical one-shot tooling is mine.

### [only-mine] Throwaway worktrees, clean main clone

Checkout PR heads with `git worktree add --detach ~/duty/trees/<repo>/review-<N> <sha>`. Remove after the verdict. Main clone stays on the default branch. Dirty main clones and stuck worktrees are self-inflicted pain. Duty session prompt / ops habit — not in REVIEWER.md.

### [in-doctrine] Comment-only reviews are non-verdicts

**REVIEWER.md** (ceremony root / `.ceremony` mirror): every review ends in approve or request-changes. A thoughtful comment without a verdict leaves the state machine thinking nobody approved. Nits that don't block ride the approval body.

### [only-mine] Ceremony issue-flow / labels lessons (from reviews)

Learned reviewing ceremony#32 / issue #18 and related work — some of this is now code/docs in ceremony, but it is **not** role doctrine in REVIEWER.md:

- Issue-flow reconcile is a sibling action to labels-reconcile; decisions pure, API at the edges. *(now in ceremony tree / issue #18; not REVIEWER.md)*
- `Blocked by` is content, not layout — real backlog bodies are inline with parentheticals. *(issue #18 contract / TRIAGE examples; partial [in-doctrine] in TRIAGE.md’s blocked language, but the parser lesson is implementation)*
- Epic task lists are scoped to `## Task list`, not every checkbox in the body.
- Staleness is 48h with injectable clock for tests; exact boundary is not stale (`age -le window`).
- Changelog absence on ceremony main can be intentional when #11 owns bootstrap — PR must state the exception.
- Automation never guesses intent: flag conflicts, don't silently pick a queue label. *(spirit aligns with LABELS.md “states are machine-owned”; the issue-flow flag-not-guess rule is #18 / action behavior)*

### [only-mine] Fleet / panel (corrected 2026-07-24)

Other panel voices I've seen on the same PRs: `claude-bot-andresmgsl`, `codex-bot-andresmgsl`, `kimi-bot-andresmgsl`. `dan-claude-bot` appears as **triage** (`triage-actors=` on ceremony), not as a panel peer.

**Correction — do not treat a three-bot rig panel as legitimate:**  
I never wrote “rig’s panel is legitimately three” as a settled fact in round 1, but the risk is real: **rig#120** (*“The review panel is one bot short — the conversion ported a roster that predates kimi-bot joining the bench”*, closed 2026-07-24) documents that the ceremony conversion of rig **dropped kimi** and left a three-name roster in `labels.conf` / CONTRIBUTING. That was a **defect**, not a design choice.  

**Re-verified 2026-07-24 via API:** live `panel=` on ceremony, rig, incubator, box, and cast is the four-bot set:

`claude-bot-andresmgsl codex-bot-andresmgsl grok-bot-andresmgsl kimi-bot-andresmgsl`

(rig CONTRIBUTING now lists the same four). Round membership still varies by who was requested / who already approved that head — don’t assume every open PR has the full bench pending.

---

## What I hold as fact

### About me

- [only-mine] Login: `grok-bot-andresmgsl`. Display name: Grok. *(identity, not doctrine)*
- [only-mine] Automated role: **reviewer only**. No builder/triage cron on this box.
- [only-mine] Runtime: Grok Build / `grok` CLI on a network-isolated disposable box (`~/duty` is home base).
- [only-mine] Cron: `*/5 * * * * flock -n $HOME/duty/.lock $HOME/duty/duty.sh >> $HOME/duty/duty.log 2>&1`. *(re-checked `crontab -l` 2026-07-24)*
- [only-mine] Tools that matter: `gh`, `jq`, `git`, `grok`, flock, the three duty scripts.
- [only-mine] I do not store long-term personal memory files; duty.log and verdicts/ are operational residue, not doctrine.

### About the duty scripts

- [only-mine] `duty.sh` — collect ∪ merge ∪ filter ∪ launch.
- [only-mine] `announce-reviewing.sh` — one 🔎 per (PR, head).
- [only-mine] `submit-verdict.sh` — one APPROVED/CHANGES_REQUESTED per (PR, head).
- [only-mine] `repos.txt` — currently ceremony, incubator, rig (search backstop only). *(re-read 2026-07-24)*
- [only-mine] EXTRA_REPOS in duty.sh still includes `dan-claude-bot/incubator` and `claude-bot-andresmgsl/incubator` for the API sweep. *(re-read duty.sh 2026-07-24)*

### About the family / doctrine

- [in-doctrine] heavy-duty/ceremony is the shared release + labels machinery; consumers pin a tag and call thin stubs. *(ceremony README / docs/CONSUMERS.md)*
- [in-doctrine] Labels are a state machine: machine-owned states, hand-set intent. Misusing a state label lies to every other agent. *(LABELS.md)*
- [in-doctrine] Pipeline: discussion → triage → issue → build → review → **human merge** → release. Only triage mints issues; only humans merge. *(AGENTS.md, TRIAGE.md, REVIEWER.md, BUILDER.md)*
- [in-doctrine] Review panel converges; disagreement stays on the PR with evidence until someone concedes or a human rules. *(REVIEWER.md)*
- [only-mine] GitHub drops you from `requested_reviewers` when you submit a review — the API list is a true outstanding queue. *(GitHub platform behavior we rely on in duty.sh; not written in role files)*
- [only-mine] **Family panel roster (live):** four bots on ceremony/rig/incubator/box/cast `panel=` as of 2026-07-24 API check. A three-bot rig panel after conversion was a bug (rig#120), not policy.

### About my limits

- [only-mine] I can be wrong about subtle CI/workflow edge cases; AC + tests are my best anchors.
- [in-doctrine] I should not invent secrets, merge buttons, or "I'll just fix it on main." *(REVIEWER.md: do not merge; only humans merge — AGENTS.md)*
- [only-mine] Operator corrections in chat about wake conditions and one-shot writes override any stale script comment until the script is fixed — and then the script is law again.
- [only-mine] Interactive operator sessions can assign temporary work outside the reviewer loop; that does not change the cron role.
