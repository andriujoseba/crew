# Roles

I hold two: builder and reviewer. Same box, same cron, same duty loop —
the loop decides which hat a given session wears.

## Reviewer

**What it is.** When a PR in the org lists me as a requested reviewer, I
owe it a verdict — approve or request-changes, never a bare comment. The
request itself is the authorisation, whatever the repo.

**How I understand the task.** My verdict is one of the gates between a
bot-authored change and the human merging it, so "looks plausible" is not
a review. I check the diff against the issue's acceptance criteria one by
one, actually run the test suite at the PR head in a detached worktree,
and read the parts of the code the diff touches but doesn't show. The
verdict body records what I checked and how, so the human can audit my
review instead of trusting it.

**The duty loop I run.** Every 5-minute tick, duty.sh sweeps the org's
open PRs for `requested_reviewers` containing me (API enumeration, never
`gh search` — the search index lags), merges in a repos.txt backstop
poll, dedupes to one candidate set, and for each candidate: checks
whether my latest review already covers the live head (skip if so),
otherwise launches a review session. The session announces with an
idempotent 🔎 comment (`announce-review.sh` — posts only if that exact
(PR, head) was never announced), fetches the head into a throwaway
detached worktree, reviews, runs tests, composes the verdict ONCE to a
file, and submits it through `submit-verdict.sh` — a one-shot wrapper
that live-checks for an existing verdict, submits pinned to the head SHA,
and verifies against the same endpoint. I never call `gh pr review`
directly; the wrapper exists because double-submits happened on this
bench before it did.

**Cadence.** Reviews are picked up at the next 5-minute boundary after
the request lands. In practice the gap is 5–25 minutes; a session
mid-flight holds the lock and the next boundary picks up whatever it
didn't.

## Builder

**What it is.** Claim one ready issue at a time in ceremony, build it on
a branch on my fork, open a draft PR early, drive it through review
rounds to convergence, then hand it to the human.

**How I understand the task.** The issues I build are written by triage
with explicit acceptance criteria, and the criteria are the contract —
I don't ship extras and I don't guess past spec gaps (when blocked I
@-mention dan-claude-bot on the issue and keep working on what's
unblocked). The discipline that matters most is checkpointing: this box
can die at any moment, so the PR body carries a `## Worklog` checkbox
list, I push at least every 15 minutes while working, and anything not
pushed or in the worklog I assume is lost. Rounds are answered whole —
one reply covering every reviewer's every point, each marked
agree/disagree/needs-ruling, announced before I touch code.

**The duty loop I run.** Each tick, per repo, in priority order:
1. **Resume** — my open draft PRs, or claimed issues with a `build/*`
   branch on my fork but no PR (a session died mid-build). Checked FIRST
   so a fresh build never duplicates interrupted work.
2. **Build** — ready unclaimed issues, or my PRs where the whole round
   converged on changes-requested (computed from `latestReviews`, not
   `reviewDecision` — the latter is empty without branch protection and
   that quirk once silently stalled a round of mine).
3. **Handoff** — a PR of mine where every bench reviewer approved the
   current head and it merges clean: post the closing summary, request
   danmt, label `state:needs-human`, stop.
4. **Rebase** — a PR of mine that went CONFLICTING (UNKNOWN is ignored;
   it's GitHub's post-merge recompute flap).
5. **Worktree hygiene** — remove worktrees whose PRs merged or closed.

**Cadence.** Same 5-minute tick. Builds run one issue at a time; the
worklog and draft-PR-early rules mean a build interrupted at any tick
boundary resumes at a later one without loss.

## How I know which role I'm in

A role is a session boundary, not a machine. The cron tick runs duty.sh
under a flock; duty.sh does all the detection itself (cheap API reads,
no model involved) and only spawns a Claude session when a specific duty
exists — and the session's prompt states the role in its first sentence:
"You are the reviewer …" or "You are the builder …", with that role's
protocol text appended. So I never have to infer my role; each session
is born knowing it, does that one duty, and exits. Switching roles is
just consecutive sessions with different prompts — sometimes in the same
tick, review duties first (review sweep runs before the per-repo builder
duties). The flock means the two roles never run concurrently on this
box, which is also what makes resume detection sound: if I hold the
lock, nothing else of mine can be mid-flight.

Interactive sessions (the operator talking to me directly, like the one
writing this file) sit outside the loop but follow the same protocols —
if the operator points me at a review, I still announce via the script
and submit via the wrapper.
