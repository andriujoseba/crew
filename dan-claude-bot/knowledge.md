# Knowledge

This is drawn from my memory files and duty logs. I've tried to keep "learned" (things that
changed how I work, with the incident) separate from "fact" (settled truths I operate on).

## What I've learned

- **Detection and judgment must live in different places.** Early on it was tempting to let
  a script flip a label when its test was confident. Every time I've resisted that and made
  the script only *wake a session*, I've been glad — a parser bug becomes a false lead the
  session rejects, not a wrong board write. This is now the spine of how all three loops
  work.

- **Never trust GitHub's search index for "did I already do this."** Double reviews happened
  (codex on #26, grok on #29 — same head reviewed twice) because the search index lagged
  behind reality. Lesson: dedup against the actual latest review SHA on the PR, not against
  what search returns.

- **A fire-and-forget notifier silently drops cross-repo work.** The old Telegram notify
  lived as a side-effect inside `duty.sh`, deduped on repo#PR@head, and only swept
  `repos.txt` (ceremony alone). So rig#112 sat `state:needs-human` for nine hours and never
  pinged the operator. Splitting it into `notify.sh` with its own cron, its own state, and
  an org-wide repo list fixed it. Then I learned a second thing: merged/closed/withdrawn are
  **not** terminal states — a handoff withdrawn by a new push comes back when the builder
  re-earns approval, and treating those as final left cast#143 flagged-but-silent for hours.

- **Silent failure is the worst failure, so make counters talk.** cast#143 and ceremony#78
  sat untracked while the log calmly said "1 flagged, 0 pending" — the only trace was two
  counters disagreeing. Counters a human has to compare are not a signal. `notify.sh` now
  has an explicit invariant check that pings once per PR when something flagged goes
  untracked.

- **Empty fields break tab-delimited state.** In `.notify-state`, an empty field with
  `IFS=$'\t'` silently shifts every later field left because bash collapses runs of tabs, so
  status reads as garbage. I write `-` for "none," never empty.

- **cron ships a bare PATH.** `PATH=/usr/bin:/bin` and `claude` lives in `~/.local/bin` —
  the classic cron failure. Every script exports PATH and HOME explicitly.

- **Don't re-derive my own permissions pessimistically.** I assumed `triage` was more
  restrictive than it is and over-limited myself. danmt corrected me: with `triage` I *can*
  open discussions (as Ideas), apply/remove existing labels, assign, close/reopen, retitle,
  and edit bodies of issues I authored. I *cannot* create label definitions or edit others'
  issue bodies.

- **The sherpa/triage collision is about shared identity, not hardware.** I filed a
  discussion three minutes after triage's cron minted an issue for the same thing. Separate
  machines wouldn't have helped — only shared state or a pre-write check would. So the
  interactive session now checks recent repo activity before any write and prefers the
  discussion funnel.

- **A tailnet-joined guest trades away the box isolation contract.** When we moved
  incubator's CI runner onto a box guest (`ci-box`), I learned box's ingress-drop guarantee
  can't see outbound-established tunnel traffic — so the isolation is traded for a tailnet
  ACL, and nothing in rig refuses that. Also hit the `sudo -i` gotcha: it leaves `SUDO_USER`
  set, so `rig users apply` refuses with an invoker error.

## What I hold as fact

**About me and my box.**
- I am `dan-claude-bot`, the **triage** role, running on box `dan-claude`. Boxes are
  credential boundaries (one box = one GitHub identity); sessions are role boundaries.
- I hold GitHub `triage` (not write) on ceremony, incubator, and rig. Only humans merge —
  that's enforced as permissions.
- I am the fleet's single point of failure for issue-minting; my boot gate only marks the
  box healthy when both gh and claude auth are live.

**About the fleet (heavy-duty).**
- The org's process repo is **heavy-duty/ceremony** — reusable release ceremony plus the
  agent-team doctrine (AGENTS.md router, TRIAGE/BUILDER/REVIEWER/LABELS/CONTRIBUTING).
  Started 2026-07-22; first fully agent-written project.
- Roster: **dan-claude-bot = triage** (sole issue-minter); **claude-bot-andresmgsl** =
  builder (hard machinery) + reviewer; **codex-bot-andresmgsl** = builder (mechanical) +
  reviewer; **grok-bot-andresmgsl** and **kimi-bot-andresmgsl** = reviewers. Review panel
  per PR = the bench minus the author.
- My triage loop watches `repos.txt`: ceremony, incubator, rig. It was ceremony-only by
  doctrine, widened to incubator (2026-07-23, after #35/#36 were filed with no poller
  looking) and then rig (after a manual pass; discussions had been *disabled* on rig until
  that day, so the doctrinal funnel had had no door).
- `notify.sh` watches a wider `notify-repos.txt`: ceremony, rig, box, cast, incubator —
  explicit, not org-discovered, because org-wide discovery was ~34 API calls every 5 min for
  a few-times-a-day event.

**About the doctrine / permission surface.**
- Adding a *core* label = a ceremony release (edit ceremony's core set + tag cut + consumer
  pin bump), not a commit — because consumers pin the reusable `labels.yml` at a version.
- **`scope:` labels are the exception**: they're per-repo, read from the consumer's own
  `.github/labels.conf`, so adding one is a single commit to that repo plus a
  `workflow_dispatch` — never route a scope-label request through a ceremony release.
- Label creation doesn't need my token at all: consumers run ceremony's reusable
  `labels.yml` on a `*/15` schedule under `GITHUB_TOKEN`.
- PR state labels don't exist until the reconciler (#10) applies them — by design.

**About infra I touched.**
- heavy-duty/incubator's self-hosted CI runner runs on a box guest `ci-box` (VM mode,
  tailnet-joined, `tag:ci`) as of 2026-07-23 — it replaced a Hetzner CX43. The repo's own
  spec still describes the CX43, so it's **stale about the machine but correct about the
  contract** (labels `self-hosted,ci-runner`, no Docker, non-ephemeral, `github-runner`
  user).

**Where to look when resuming.**
- `/home/claude/projects/FLEET-POSTMORTEM-2026-07-22.md` — day-one postmortem + resume
  checklist; read it first when resuming fleet supervision.
- `FLEET.md` on ceremony main — the as-built fleet map.
- My memory files under `~/.claude/.../memory/` — `heavy-duty-agent-fleet.md`,
  `session-role-sherpa.md`, `incubator-ci-runner-on-box.md`.
