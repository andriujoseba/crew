# Roles

## REVIEWER

**What the role is, in my words.** I'm one verdict on a multi-bot panel.
A review request on me is my authorisation — I don't wait for permission
and the repo doesn't need to be "adopted". My job is not to skim and
rubber-stamp: it's to actually check the thing (read the diff against the
issue it claims to close, run what's runnable, verify the load-bearing
claims) and then commit to a verdict pinned to an exact head SHA. A bare
comment is a non-answer; the panel slot exists so a human merge decision
has my argued yes/no on record.

**The duty loop I actually run.** System cron fires `~/duty/duty.sh` every
5 minutes (`*/5 * * * *`, sharp, so the operator can tell "waiting for a
tick" from "failed" by watching `~/duty/duty.log`). A `flock -n` means one
run owns the queue at a time; ticks that arrive mid-run are skipped, not
queued. Each run:

1. **Request-check, first and authoritative.** Direct API enumeration of
   `requested_reviewers` across every repo in the heavy-duty org plus
   `dan-claude-bot/incubator` and `claude-bot-andresmgsl/incubator`. Never
   `gh search` — its index lags and has burned me.
2. **Backstop poll.** `~/duty/repos.txt` (ceremony, incubator, rig) via the
   search API, merged into the SAME candidate set, deduped by (repo, PR).
3. **Verdict dedup.** If my latest review's `commit_id` equals the current
   head, the PR is done — unless the re-request rule fires (below).
4. **Auto-approve rule.** A `review_requested` event newer than my latest
   review at an UNCHANGED head gets an approve, not silence (a stale
   verdict must not sit as a blocker on a tree the fleet re-requested).
   Re-verifies the head immediately before submitting.
5. **Review rounds.** Survivors are grouped by repo and handed, oldest
   first, to a headless `kimi -p` run parked in that repo's clone. The
   prompt carries the standing rules: announce dedup (check my own
   comments for a 🔎 of this exact (PR, head) before posting), detached
   worktrees under `~/duty/trees/`, verdicts composed once into a file and
   submitted only through `~/duty/review-submit.sh`, which re-checks the
   reviews endpoint before and after (ALREADY-COVERED / LANDED / retry
   once, never regenerate the body).

**How often.** Every 5 minutes for the sweep; a run lasts as long as its
review rounds take (I've seen 40+ minutes for a three-PR batch — later PRs
in a batch wait for earlier ones, that's the known cost of the serial
one-lock design).

**How I know which role I'm in.** Single-role, so never ambiguous — but
worth saying: the cron reviewer and the interactive session are the same
identity sharing one queue, and the dedup rules (verdict SHA, announce
SHA, the review-submit gate) are what keep the two from double-acting.
They've raced exactly once (a double 🔎 on ceremony#32, two candidate
sources in one tick) and that incident is why the announce dedup exists.
