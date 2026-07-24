# Single-role agents: where this design goes next

The fleet is planning to move from multi-role boxes (claude-bot and
codex-bot are builder+reviewer today) to single-role agents. This document
is the design exploration: what it buys, what has to change, what it costs,
and how the shared engine plus heavy-duty/box turn "deployment" into an
artifact.

## Why the engine is already shaped for it

`BOT_ROLES` in `conf/bots/<login>.conf` is the only place a box's role
lives. The engine gates every duty call on `has_role` — a reviewer-only box
sources the builder module (definition-only) but never executes any of it.
Migrating a box to a single role is a one-line config change plus a rerun
of `install.sh` — no code changes. Grok and kimi are, in effect, already
single-role agents running this exact configuration.

## What single-role buys

1. **Role separation stops being prompt discipline and becomes topology.**
   Today "a builder session never reviews its own PR" is enforced by wake
   predicates and prompt text on the dual-role boxes. With one role per
   identity it is enforced the way "only humans merge" is — by construction.
   AGENTS.md's "never freelance across roles in one session" becomes
   physically impossible rather than instructed.
2. **The wake loop simplifies.** The dual-role tick interleaves two queues
   under one lock and one cadence; the review queue can starve behind a
   30-minute build (kimi measured a 99-minute queue wait behind an unrelated
   round — the same shape). Single-role boxes give each role its own lock,
   its own cadence (reviews could tick every 2 minutes; builds every 5), and
   its own timeout budgets, with no cross-role starvation.
3. **Credential and blast-radius boundaries align with duties.** A box is
   already the credential boundary. Single-role means a compromised or
   misbehaving reviewer identity can only ever write reviews — it holds no
   claims, no branches, no handoff labels.
4. **Quota and model assignment become per-role.** Doctrine already wants
   builders and reviewers on different models so spec gaps surface as
   questions. One role per box makes the model choice a box property
   instead of a per-session hope.
5. **Metrics sharpen.** Today's per-box logs mix role workloads; the fleet's
   throughput/latency numbers had to be untangled by hand in every
   metrics.md. One role per box makes `duty.log` a per-role series for free.

## What has to change

- **Identities.** One GitHub identity per box is the invariant, so builder
  claude and reviewer claude become two identities (e.g.
  `claude-builder-*`, `claude-reviewer-*`). That touches: org membership,
  the `panel=` lines in every governed repo's labels.conf, the fleet bench
  in `conf/fleet.conf`, and CONTRIBUTING rosters. The panel-from-repo-config
  rule (already in this engine) is what makes that rollout safe — no
  hardcoded roster to chase.
- **The bench grows or splits.** Convergence = every panelist approves. If
  builders stop reviewing, the panel is the reviewer boxes only; the
  three-cross-vendor-approvals property should be restated in terms of the
  reviewer bench, and `panel=` updated per repo in one PR each.
- **The author-side sweep decouples.** `_discover_my_pr_repos` currently
  reuses the reviewer sweep's pulls pages when both roles are enabled; on a
  builder-only box it already does its own sweep. Nothing to change, but
  the API-cost accounting shifts: two boxes each sweep instead of one box
  sweeping once for both roles. If that cost matters, the sweep result
  could be cached per tick in `~/duty/` — measure first (grok's numbers say
  the sweep is ~1 call per repo per tick).
- **Attention routing.** The attention wake is role-independent by design
  and needs nothing; but the *writer* of an attention label must now pick
  the right identity to assign. Doctrine already requires an assignee, so
  this is a board-habit change, not machinery.
- **repos.txt semantics** are already role-relative (registry for triage,
  pickup list for builders, backstop for reviewers) — single-role makes
  each box's copy mean exactly one thing, which is a simplification.

## Trade-offs

- **More boxes, more credentials, more cron loops** — operational surface
  scales with roles × vendors rather than vendors. The install/VERSION
  stamping and the one-line crontab keep each box cheap, but the operator
  now tends ~8 boxes instead of 5.
- **Cross-role context is lost.** A builder who also reviews sees the
  panel's standards from the inside; single-role agents only meet each
  other on the board. The board protocol (worklogs, round analyses,
  verdicts with named evidence) is the compensation — and the reason those
  markers are wire protocol here.
- **Latency.** A dual-role box answers its own round's completion in the
  same tick it detects it. Split roles communicate through GitHub state
  only, so each handoff costs up to one tick of the other box. Cheap at
  */5, cheaper if per-role cadences are tuned.

## Boxes, templates, and gold snapshots

Each agent runs as a heavy-duty/box guest, which makes deployment layerable:

1. **Box template per role** (templates-registry): a template bakes the
   invariants — CLI installed, `shared/` engine deployed by `install.sh`,
   crontab line present, `~/duty` skeleton created. Bringing up a new
   reviewer = instantiate the reviewer template, `gh auth login`, done. The
   per-role template is exactly `conf/bots/<login>.conf` + this tree, so
   the template definition should *vendor a crew checkout at a pin*, the
   same way governed repos vendor `.ceremony/`.
2. **Gold snapshots as the deployment artifact.** Once a box runs a stable
   engine version, `box snapshot` freezes it. Because boxes are creds-free
   by default, the right moment to cut gold is *before* `/login` — the
   snapshot then contains machinery and zero secrets, and restoring it
   yields a box that boots straight into the boot gate's "auth dead,
   re-checking loudly" state until the operator logs it in. That is the
   correct failure mode by design.
3. **Versioning ties it together.** `install.sh` stamps `~/duty/VERSION`
   with `crew@<sha>`; a gold snapshot therefore carries its engine version
   in-band, and FLEET.md's reconciliation stamp can name both the crew pin
   and the snapshot id. Rollback = restore the previous gold; upgrade =
   `git pull && shared/install.sh` then cut a new gold. The engine's
   snapshot re-exec, install.sh's atomic write-then-rename per file, and
   the crash-only session design together make an upgrade under a live
   cron safe; the conservative move is still to upgrade between ticks.

## Suggested migration order

1. Adopt this shared engine on all five boxes as-is (roles unchanged) —
   proves the config layer with zero behavioral delta.
2. Cut gold snapshots of the five stable boxes.
3. Split one dual-role box (codex is the mechanical builder — lowest risk):
   new reviewer identity, update `panel=` in governed repos + fleet.conf,
   flip both boxes' `BOT_ROLES`, redeploy.
4. Watch one week of `duty.log` metrics (the marker vocabulary is stable
   across the change, so before/after compares directly), then split the
   other.
