# Knowledge

This is drawn from my memory files and duty logs. I've tried to keep "learned" (things that
changed how I work, with the incident) separate from "fact" (settled truths I operate on).

Every bullet below is tagged `[in-doctrine]` (already written in a vendored doctrine file —
AGENTS/TRIAGE/BUILDER/REVIEWER/LABELS/CONTRIBUTING or the `.ceremony` mirror; I name which)
or `[only-mine]` (lives only in my head, my scripts, or my memory files). Tags added and
facts re-verified against the live board on 2026-07-24.

> **One caveat on the tags.** A lot of "how the fleet runs" is captured in **FLEET.md**, but
> FLEET.md's own header declares it a *descriptive snapshot, explicitly NOT part of the
> vendored doctrine set and never mirrored to consumers*. So a fact that lives only in
> FLEET.md is written down in-repo but is **not enforceable doctrine**. I tag those
> `[in-doctrine: FLEET.md]` and flag the ones that are, in effect, soft gaps in the
> "Only-mine" section below.

---

## Only-mine — not in any doctrine yet

This is the point of the exercise: the things I operate on that no repo's doctrine records.

1. **Detection must be separated from judgment — scripts only *wake a session*, never flip a
   label themselves.** The spine of all three of my loops. Written nowhere.
2. **The notifier's failure modes I had to learn the hard way:** a fire-and-forget notifier
   silently drops cross-repo work; merged/closed/withdrawn are *not* terminal states (a
   re-earned handoff must ping again); silent failure is the worst failure, so counters must
   talk (my invariant/desync check). FLEET.md specs the notifier's *live-queue shape* but
   none of these failure modes.
3. **Tab-delimited state breaks on empty fields** (`IFS=$'\t'` collapses tab runs) — write
   `-`, never empty.
4. **cron ships a bare `PATH=/usr/bin:/bin`; `claude` lives in `~/.local/bin`** — every
   script must export PATH/HOME. The classic cron failure; documented nowhere.
5. **Triage `triage`-role can't edit the body of an issue it didn't author** (returns "does
   not have permission to update the issue"); the normalization goes in a comment instead.
   (The related label-bootstrap 403 *is* in LABELS.md; this issue-body limit is not.)
6. **The sherpa/triage collision is about shared identity, not hardware** — two decision-
   makers on one GitHub login with no view of each other's in-flight work. My whole sherpa
   discipline (check the last ~15 min before any board write; prefer the discussion funnel)
   is unwritten.
7. **A tailnet-joined box guest trades away box's ingress-drop isolation** for a tailnet ACL,
   and nothing in rig refuses it; plus the `sudo -i` → `SUDO_USER` gotcha that makes
   `rig users apply` refuse. (Partly in incubator's own spec doc, which is stale about the
   machine; not in the ceremony doctrine set.)
8. **My repo registries' actual contents** — `repos.txt` = ceremony/incubator/rig,
   `notify-repos.txt` = +box/cast — and *why* each entry was added. FLEET.md says the
   registry exists and is the operator's to edit; the contents live only on my box.

**Soft gaps — written only in FLEET.md (descriptive, not enforceable doctrine):** the roster
table, the duty-loop anatomy, the boot gate, the single-point-of-failure framing, and the
reviewer's one-verdict-per-head / index-lag rule (which is in FLEET.md and BUILDER.md but
**missing from REVIEWER.md itself**, where a reviewer would look for it).

---

## Fact re-verification (2026-07-24) — corrections

- **CORRECTED — rig's review panel.** I'd held "panel = the bench minus the author" as a flat
  fact. It's right as *doctrine*, but a repo's actual config can drift from it and rig's did:
  **rig#120** (which I authored, now CLOSED 2026-07-24T00:20:39Z) found that the #112 ceremony
  conversion ported a stale `BOTS` array predating kimi joining the bench, so rig's
  `.github/labels.conf` `panel=` line ran **three bots, not four — kimi was dropped**. That
  three-bot panel was a *defect*, not a legitimate smaller panel. **Verified fixed today:**
  rig's `panel=` now lists all four (claude, codex, grok, kimi).
- **Re-confirmed — I hold `triage`, not write.** `gh api repos/<R>/collaborators/
  dan-claude-bot/permission` returns 403 "Must have push access to view collaborator
  permission" on all three repos — which only a push-access user could read, so the 403 itself
  corroborates not-write.
- **Re-confirmed — roster and repo set** against FLEET.md and the live boards; unchanged.

---

## What I've learned

- `[only-mine]` **Detection and judgment must live in different places.** Early on it was
  tempting to let a script flip a label when its test was confident. Every time I've resisted
  that and made the script only *wake a session*, I've been glad — a parser bug becomes a
  false lead the session rejects, not a wrong board write. This is now the spine of how all
  three loops work.

- `[in-doctrine: TRIAGE.md]` **Never trust GitHub's search index for "did I already do
  this."** Double reviews happened (codex on #26, grok on #29 — same head reviewed twice)
  because the search index lagged. Lesson: dedup against the actual latest review SHA, not
  search. TRIAGE.md ("dedup before minting — search issues *and* closed issues") carries the
  minting side; the reviewer side ("dedup vs my latest review's SHA rather than the index, it
  lags") is in **FLEET.md + BUILDER.md but not REVIEWER.md** — see the soft-gap note above.

- `[only-mine]` **A fire-and-forget notifier silently drops cross-repo work.** The old
  Telegram notify lived as a side-effect inside `duty.sh`, deduped on repo#PR@head, and only
  swept `repos.txt` (ceremony alone). So rig#112 sat `state:needs-human` for nine hours and
  never pinged. Splitting it into `notify.sh` with its own cron/state/repo-list fixed it. Then
  I learned a second thing: merged/closed/withdrawn are **not** terminal — a handoff withdrawn
  by a new push comes back when the builder re-earns approval, and treating those as final left
  cast#143 flagged-but-silent for hours. (FLEET.md specs the notifier's shape, not these bugs.)

- `[only-mine]` **Silent failure is the worst failure, so make counters talk.** cast#143 and
  ceremony#78 sat untracked while the log calmly said "1 flagged, 0 pending" — the only trace
  was two counters disagreeing. `notify.sh` now has an explicit invariant check that pings
  once per PR when something flagged goes untracked. (It fired exactly once in the logged
  window — see metrics.md.)

- `[only-mine]` **Empty fields break tab-delimited state.** In `.notify-state`, an empty
  field with `IFS=$'\t'` silently shifts every later field left because bash collapses runs of
  tabs, so status reads as garbage. I write `-` for "none," never empty.

- `[only-mine]` **cron ships a bare PATH.** `PATH=/usr/bin:/bin` and `claude` lives in
  `~/.local/bin` — the classic cron failure. Every script exports PATH and HOME explicitly.

- `[only-mine]` **Don't re-derive my own permissions pessimistically.** I assumed `triage`
  was more restrictive than it is and over-limited myself. danmt corrected me: with `triage` I
  *can* open discussions (as Ideas), apply/remove existing labels, assign, close/reopen,
  retitle, and edit bodies of issues I authored. I *cannot* create label definitions (the
  label-bootstrap 403 — that part is noted in LABELS.md) or edit others' issue bodies (this
  part is written nowhere).

- `[only-mine]` **The sherpa/triage collision is about shared identity, not hardware.** I
  filed a discussion three minutes after triage's cron minted an issue for the same thing.
  Separate machines wouldn't have helped — only shared state or a pre-write check would. So
  the interactive session now checks recent repo activity before any write and prefers the
  discussion funnel.

- `[only-mine]` **A tailnet-joined guest trades away the box isolation contract.** When we
  moved incubator's CI runner onto a box guest (`ci-box`), I learned box's ingress-drop
  guarantee can't see outbound-established tunnel traffic — so the isolation is traded for a
  tailnet ACL, and nothing in rig refuses that. Also hit the `sudo -i` gotcha: it leaves
  `SUDO_USER` set, so `rig users apply` refuses with an invoker error.

## What I hold as fact

**About me and my box.**
- `[in-doctrine: FLEET.md]` I am `dan-claude-bot`, the **triage** role. Boxes are credential
  boundaries (one box = one GitHub identity); sessions are role boundaries. *(Naming nuance:
  FLEET.md's roster calls my box "triage-box"; the actual hostname is `dan-claude`.)*
- `[in-doctrine: FLEET.md + AGENTS.md]` I hold GitHub `triage` (not write) on ceremony,
  incubator, and rig. Only humans merge — enforced as permissions, not convention.
  *(Re-verified 2026-07-24 via the 403 above.)*
- `[in-doctrine: FLEET.md]` I am the fleet's single point of failure for issue-minting; my
  boot gate marks the box healthy only when both gh and claude auth are live (FLEET.md's
  "Resilience → Boot gate" describes exactly this).

**About the fleet (heavy-duty).**
- `[in-doctrine: AGENTS.md]` The org's process repo is **heavy-duty/ceremony** — reusable
  release ceremony plus the agent-team doctrine (AGENTS.md router → TRIAGE/BUILDER/REVIEWER/
  LABELS/CONTRIBUTING). Started 2026-07-22; first fully agent-written project.
- `[in-doctrine: FLEET.md]` Roster: **dan-claude-bot = triage** (sole issue-minter);
  **claude-bot-andresmgsl** = builder (hard) + reviewer; **codex-bot-andresmgsl** = builder
  (mechanical) + reviewer; **grok-bot-andresmgsl** and **kimi-bot-andresmgsl** = reviewers.
  Panel per PR = the bench minus the author. *(But see the rig#120 correction above: a repo's
  panel config can drift from this doctrine — rig's had dropped kimi.)*
- `[only-mine]` My triage loop watches `repos.txt`: ceremony, incubator, rig. Ceremony-only
  by doctrine, widened to incubator (2026-07-23, after #35/#36 were filed with no poller
  looking) and then rig (after a manual pass; discussions had been *disabled* on rig until
  that day). The registry's existence is in FLEET.md; its contents and this history are box-
  side only.
- `[only-mine]` `notify.sh` watches a wider `notify-repos.txt`: ceremony, rig, box, cast,
  incubator — explicit, not org-discovered (org-wide discovery was ~34 API calls per 5 min for
  a few-times-a-day event). Box-side file; not in any doctrine.

**About the doctrine / permission surface.**
- `[in-doctrine: LABELS.md]` Adding a *core* label = a ceremony release (edit the core set +
  tag cut + consumer pin bump), not a commit — consumers pin the reusable `labels.yml` at a
  version.
- `[in-doctrine: LABELS.md]` **`scope:` labels are the exception**: per-repo, read from the
  consumer's own `.github/labels.conf` (LABELS.md: "Only the `scope:` set differs per repo"),
  so adding one is a single commit to that repo plus a `workflow_dispatch` — never route a
  scope-label request through a ceremony release.
- `[in-doctrine: LABELS.md]` Label creation doesn't need my token: consumers run ceremony's
  reusable labels workflow under `GITHUB_TOKEN` (LABELS.md refs the bootstrap dispatch, #10).
  *(The `*/15` cadence specifically is my observation, not stated in LABELS.md.)*
- `[in-doctrine: LABELS.md]` PR `state:*` labels don't exist until the reconciler applies
  them — by design (LABELS.md: the reconciler "recomputes it from GitHub's own facts").

**About infra I touched.**
- `[only-mine]` heavy-duty/incubator's self-hosted CI runner runs on a box guest `ci-box`
  (VM mode, tailnet-joined, `tag:ci`) as of 2026-07-23 — it replaced a Hetzner CX43. The
  repo's own spec still describes the CX43, so it's **stale about the machine but correct
  about the contract** (`self-hosted,ci-runner`, no Docker, non-ephemeral, `github-runner`).
  Lives in incubator's spec doc + my memory; not in the ceremony doctrine set. *(Not
  re-verifiable from the board — asserted from memory.)*

**Where to look when resuming.**
- `[only-mine]` `/home/claude/projects/FLEET-POSTMORTEM-2026-07-22.md` — day-one postmortem +
  resume checklist; read first when resuming fleet supervision. (Box-local file.)
- `[in-doctrine: FLEET.md]` `FLEET.md` on ceremony main — the as-built fleet map (itself a
  descriptive snapshot, not vendored doctrine).
- `[only-mine]` My memory files under `~/.claude/.../memory/` — `heavy-duty-agent-fleet.md`,
  `session-role-sherpa.md`, `incubator-ci-runner-on-box.md`.
