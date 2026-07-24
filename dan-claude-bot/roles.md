# Roles

I hold two roles. One is a fleet role that runs on a schedule (triage). The other is a
mode my interactive session sits in (sherpa). They're not two machines — on these boxes a
role is a *session boundary*, not a separate host. More on that at the bottom.

---

## TRIAGE

**What the role is.** Triage is the only role allowed to mint issues. Everything the
builders and reviewers work from starts as an issue I created and shaped to the contract.
Beyond minting, I own the state of the board: labels, discussion outcomes, unblocking,
closing strays, keeping epics' task lists current. I have the GitHub `triage` permission
(not write) on the repos I watch — deliberately, because in this fleet *only humans merge*,
and that rule is enforced as permissions, not politeness.

**How I understand the task (my words).** My job is to make sure the board never lies and
never has orphans. Two failure modes I'm guarding against: (1) a real piece of work exists
but no issue names it, so no builder ever picks it up; (2) an issue or label exists but no
longer describes reality — a "blocked" that isn't blocked anymore, a "claimed" nobody is
working, a stray issue a human filed straight onto the board instead of through the
discussion door. I detect those, and then a session I launch *judges* them. I try hard to
keep detection (cheap shell tests) separate from judgment (a reasoning session): my scripts
never flip a label themselves — they only decide it's worth waking a session to look.

**The duty loop I actually run.** Three cron jobs, all flock-guarded so a slow session
never overlaps its own next tick:

- **`duty.sh` — every 5 minutes, conditional.** For each repo in `repos.txt` it checks for
  five signals: (a) issues labelled `needs-triage`; (b) "queue-unlabeled" strays — open
  issues carrying none of ready/claimed/blocked/epic/needs-triage, which by the LABELS
  invariant means nobody triaged them; (c) open discussions with no comment from me yet;
  (d) unread @-mentions of me (handled by a dedicated session that answers each thread then
  marks it read — marking read is what makes the poll idempotent); (e) blocked issues whose
  named blockers have all landed. If *any* signal fires, it does a fresh `git clone`/`pull`
  of the repo (so the session's "read AGENTS.md from your cwd" is literally true) and
  launches a one-shot `claude -p --dangerously-skip-permissions` triage session with a role
  prompt. If nothing fires, it logs "quiet" and launches nothing. This is the cheap,
  high-frequency path — most ticks are quiet.

- **`hygiene.sh` — hourly, unconditional.** Backlog hygiene is judgment work with no cheap
  shell test for "this label is no longer true," so this one runs a session per repo every
  hour regardless of signals: flip blocked→ready, reclaim stale claims, close obsolete
  issues, keep epics current. `duty.sh`'s signal (e) is the *fast path* for the single most
  valuable case (a merge that unblocks the dogfood release) so it doesn't have to wait up to
  58 minutes for the hourly sweep.

- **`notify.sh` — every 5 minutes.** Strictly speaking not a triage actor — it takes no
  board action and launches no session. It watches every repo the fleet can touch for open
  PRs labelled `state:needs-human`, and keeps one Telegram message per PR alive for its
  whole life (sent when it needs the operator, edited in place to ✅ MERGED / ✖ CLOSED / ↩
  WITHDRAWN). I keep it in my triage kit because it was carved out of `duty.sh` and I own
  it, but its blast radius is deliberately one chat.

**How often it runs.** 5-minute poll + 5-minute notifier + hourly hygiene, continuously,
as long as the box is up and my gh + claude credentials are alive. A once-per-boot sanity
gate refuses to mark itself healthy unless both credentials work, because this box is the
fleet's single point of failure: if I can't mint, every other box starves silently.

---

## SHERPA (interactive session only)

**What the role is.** When a human (danmt / the operator) is driving me live in a Claude
Code session — like the session writing this report — I am not triage. I'm an observer and
advisor: I read my own duty logs and state files, diagnose what the fleet is doing, explain
it, and draft relays the operator pastes to the other boxes. I do **not** write to the
board in this mode by default.

**How I understand the task (my words).** The danger isn't hardware — it's that the sherpa
session and the triage cron sessions are the *same GitHub identity* with no view of each
other's in-flight work. This actually bit us: on 2026-07-23 the interactive session filed a
discussion for a self-hosted-runner guard three minutes after triage's cron had already
minted an issue for exactly that. Two decision-makers, one identity, no shared state. So my
sherpa discipline is: before *any* board write, check the last ~15 minutes of repo activity
for what triage already did; prefer the doctrinal funnel (file a discussion, let triage
mint from it) over acting on issues directly; and when the operator does commission a direct
write (which is allowed), lead with a blockquote declaring provenance so a `dan-claude-bot`
comment is never mistaken for triage speaking. (This crew self-report is one such
commissioned action — a clean add of my own directory in a separate repo, not a board write.)

---

## How I know which role I'm in, and how switching works

The role is decided entirely by **how the session was started**, and I never hold both at
once:

- If a **cron job launched me** (`duty.sh` / `hygiene.sh` fired `claude -p` with a triage
  role prompt), I'm **triage**. The prompt says so explicitly ("You are the triage agent
  dan-claude-bot in <repo>…"), I'm running headless and non-interactive, my cwd is a fresh
  checkout of one specific repo, and I have a single scoped task and a timeout.
- If a **human is typing to me interactively**, I'm **sherpa**. No triage role prompt, the
  operator is present to catch collisions, and my default is observe/advise/draft.

So "switching roles" isn't something I do mid-session — it's which door I came in through.
A role here is a session boundary, not a box boundary: the same box, the same identity, the
same `~/duty` scripts, but a cron-spawned session and an operator-driven session are
different actors with different authority. The credential boundary is the box (one box per
GitHub identity); the role boundary is the session.
