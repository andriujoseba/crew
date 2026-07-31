# Changelog

The ledger starts at `0.1.0`. crew reached this file with tags never cut and
every PR merged without a changelog fragment, so there is no accurate section
to reconstruct — an invented history is worse than an honest starting line.
History before `0.1.0` lives in git; this file starts there, and the first
assembled section is the one the `0.1.0` release stamps from the fragments in
[`changelog.d/`](changelog.d/README.md).

This decision is the recorded one heavy-duty/crew#84 asks for: **start the
ledger at 0.1.0**, do not backfill.

<!-- Release sections land below this line, newest first, each stamped by the
release PR from the fragments in changelog.d/. There are none yet: 0.1.0 has
not been cut. -->

## 0.1.0 — 2026-07-31

### Added

- A `curl | bash` install channel, `dist/curl-install.sh` — the latest release by default, `CREW_REF` for a tag or the tip, and a refusal rather than a silent fallback when no release resolves. Temporary: it goes when crew moves off GitHub (#171).
- `crew status` reports engine integrity — `current`, `modified` or `unverified` — from a content hash of the installed engine tree, and names the files that differ (#159)
- `crew upgrade` and `crew hire` refuse to overwrite a modified engine, naming what differs; `--force` overwrites it (#159)
- installing converges the engine tree to what the version ships: anything the incoming tree does not carry — a file, a symlink, any entry that is not a directory — is moved to `~/duty/legacy/`, named on the way, rather than left behind and recorded as shipped (#159)
- the engine's own directories count as shipped content too: `~/duty/bin`, `lib`, `prompts` or `conf` redirected through a symlink now reads `modified` (#159)
- installing replaces such a redirect with a real directory holding what was behind it, and parks the link in `~/duty/legacy/` as evidence of where it pointed (#159)
- `fleet-floor/dev/whiteboard.html` — every robot, room and state as one asset map, built from `src/` and rendered by the app's own engine (#142)
- The engine sets `state:addressing` when a review round closes without full approval — the reviewer that lands the last verdict writes it, without waiting for the scheduled reconciler (#130).
- `drill/rehearsal-all.sh` drives the installer drill’s offline harnesses and five real-box observations into Section A record output (#117)
- Self-contained, offline, scp-able installer per version — `dist/make-installer.sh` builds `crew-<version>.sh`, a stub that verifies its payload checksum before unpacking and installs with no network, `curl` or `gh` (#98).
- `crew --version` prints the version and the install root it ran from — the root is how you settle which `crew` you ran when two are on PATH (#97)
- `crew help <command>` for every verb, rendered from the same table that dispatches it, so the help cannot describe a command the code does not have (#97)
- A typo'd command now suggests the nearest verb instead of only failing (#97)
- `crew versions`, `crew use`, and `crew uninstall` manage side-by-side host installs while reporting engine skew and protecting unattended fleets (#96)
- `install.sh` installs `crew` into a versioned layout (`versions/<v>`, a `current` symlink, `crew` on `PATH`), per-user with root refused — re-runs converge, a new version flips the default and reports engine skew (#95)
- `cli/crew` resolves its root through the `current` symlink so it runs the same from a checkout or an install (#95)
- crew adopts heavy-duty/ceremony's release and labels flow: tagged releases through both doors, a managed label taxonomy with per-scope `scope:*` labels, a `VERSION` a second fleet can pin, and the `.ceremony/` doctrine mirror verified on every PR (#84)

### Changed

- `fleet-floor` — the deck station in front of each unit belongs to its room now, instead of one undesigned plank drawn three times (#174)
- `fleet-floor` — a welding bench with a vise and a drawer chest, an inspection bench with a lens and a specimen, and a plotting table on a pedestal with a top tilted towards the camera (#174)
- `fleet-floor` — five polish passes over those stations: silhouette and value, construction, material and wear, light, and state (#174)

- `fleet-floor` — the deck station moved into the near plane, in front of the unit instead of beside it at the same depth, and is drawn in the top face's own perspective (#174)

- `fleet-floor` — ten loops on the near plane: a waist-height worktop that occludes the light behind it, the faces cut for the full height, an overhung apron, and per-room top materials (#174)
- `fleet-floor` — the near plane grows company and state: a companion prop per room (`LAYOUT.nearSide`), the unit's vendor colour on the back arris, the beacon's pulse on the offline station, motion while working, and a god-view crop that keeps the toe in frame (#174)
- `fleet-floor` — five loops on the residents: codex stands tall enough to use the bench, offline kimi sags to parking altitude instead of vanishing behind it and catches the beacon, and the near plane gains a left side and its wiring (#174)
- `fleet-floor` — five loops on the light, each crossing every room and robot: the unit shades the bench, the room's lamp lands on the unit, the worktop reflects who stands at it, shadows take the floor's colour, and near dust drifts in front of the subject (#174)
- `fleet-floor` — the god-view cell renders the real room instead of a second copy of one, so a room fix reaches the console, the grid and the map at once; the fleet view drops from ~92ms/frame to vsync as a side effect (#142)
- Vendor ceremony 0.4.0 doctrine, templates, workflows, and release guards. (#140)
- `shared-ci` does not run while a PR is a draft, and runs at the head the moment the PR is marked ready for review — the gate reads the event payload's draft bit, never a label (#136)
- The engine requests and re-requests the review panel, keyed off the session's round-answered signal rather than a builder session performing the request; `state:bots-reviewing` is set in the same act, and the reconciler stays authoritative (#133).
- The session no longer requests reviewers: it answers the round and posts the round-answered signal, and keeps only the argued-exception request under a red head genuinely outside the PR (#133).
- The labels board sweep runs hourly and ignores issue label and assignment churn while retaining immediate queue transitions (#131)
- The `state:addressing` write is optimistic and best-effort; the reconciler stays authoritative and corrects any write it would refuse (#130).
- Hosts ship crew engines directly to boxes, removing box-side crew repository access from hire and upgrade (#99)
- A bad invocation exits **2**; a real failure still exits **1**. Both used to be `1`, so a caller could not tell "you typo'd" from "the fleet is broken" — the boundary is the invocation versus the world, with the roster and profiles counting as configuration and boxes as state (#97)
- `crew status <box>` fails with exit 1 when the named box does not exist, rather than printing `(unreachable)` and succeeding. A box that exists but is merely stopped is unchanged (#97)
- A value-taking flag with no value (`crew new --agent`, `crew floor --port`, …) exits 2 instead of dying through Bash's own unbound-variable handler at 1 (#97)
- `crew up` and `crew hire-all` refuse an unrecognised flag instead of silently ignoring it — `crew hire-all --dry-run` used to hire the whole fleet while reading like a rehearsal (#97)
- An argument beyond a verb's synopsis is refused instead of silently ignored — `crew help hire unexpected` used to print hire's help and exit 0 (#97)
- A malformed `--ref` exits 2 and is refused at parse time rather than per box, so `crew hire-all --ref -bad` can no longer exit 0 against an empty roster (#97)
- handoff no longer spends an agent session or a repository clone: the engine requests the human's review, sets `state:needs-human`, and posts a factual handoff comment (approvals at the current head, the head SHA, and a pointer to the PR body's Round log) itself (#91)
- the closing prose it used to reconstruct at the end now lives in the PR body's `## Round log`, mirrored there mechanically from each whole-round reply — so no model is spent at handoff (#91)

### Fixed

- fleet-floor: the browser walk asserts the engine version by **shape** on a real fleet — some box renders a semver, and none renders a raw `crew@…` stamp or an unparseable `unknown` (#202).
- fleet-floor: the walk's exact-value engine check moved under the fixture gate. Pinned to the stub's `crew@0.4.1 (deadbee)` but gated on `LIVE` alone, it failed by construction on every real-host drill and read as an app defect (#202).
- fleet-floor: a box whose crontab holds no live `tick.sh` line now reads **disarmed** instead of `SILENT`. SILENT is an alarm meaning "this box should be ticking and is not", and spending it on a box nobody armed is how the drill's floor-vs-CLI agreement check skipped five consecutive runs (#189).
- `crew status` can answer "is this box armed?" at all, from the same crontab patterns `probe.sh` uses, so the CLI and the console stop holding private truths about it. A paused box is told to resume; an unarmed one is told to hire (#189).
- fleet-floor: `wake-silent` no longer sends a resume to boxes that have no commented crontab line to restore, which reported a failed row for every unarmed box in the fleet (#189).
- `pause` and `resume` no longer report a zero crontab count as a refused command; a box with no armed `tick.sh` line answers `nothing to pause` (#188).
- The drill exercises the console's control verbs against a tick line it arms itself, and leaves the box disarmed on every exit path (#188).
- The operator-config rehearsal now completes against boxes without a crew checkout. (#187)
- The installer drill hires its box as the agent and roles that box already carries, instead of a hard-coded `claude reviewer` that re-roled the box the later drill phases share (#180).
- A review re-request at an unchanged head is serviced instead of silently skipped: the reviewer now also asks whether the request postdates its own verdict, the same test `rereq_decision` makes before waking it (#178).
- An approval is of a tree, not only of a commit — an issue amendment or a ruling can change the right verdict while the head stands still (#178).
- The release drill installs through `crew hire` rather than calling `install.sh` directly, so it exercises the staging the fleet actually performs instead of a path no operator takes (#177).
- `crew hire` no longer exits silently on a box that has never been hired: `box_registry` and `production_registry` pipe into an assignment under `set -euo pipefail`, so an absent or all-comment registry killed crew with no message — including on a second operator's first `crew up` (#176).
- Builder handoff queries respect GitHub's page limit and reject GraphQL error bodies before acting (#155)
- Builder duty reserves its active slot for any open authored PR and makes issue claims race-safe. (#152)
- A re-request over a standing block wakes a real re-review even where `AUTO_APPROVE_REREQUEST=0`; the flag now governs only the approval (#151)
- Builder wakes preserve current-head change requests after later review comments. (#147)
- Duty check state now uses the latest run of each check name, ignoring superseded same-head cancellations (#146).
- `fleet-floor` — the offline alert lands on the unit for all four vendors, in both views: it was pinned to the sprite's bounding box in the grid and to the visor in the room, and neither is the head of a spider or a drone (#142)
- `fleet-floor` — a powered-down kimi is no longer cut in half by the bench it settled behind (#142)
- `fleet-floor` — the builder's conveyor no longer runs ten pixels through the workbench top (#142)
- The review duty no longer auto-approves over a standing request-changes — a re-request queues a real review round and admits that round's verdict, while a bare re-post is still refused (#114)
- Engine stamps use the crew version across installed and checkout-based trees, with an optional Git SHA retained only as provenance (#94)
- a fleet-wide `start-all`/`stop-all` no longer fails the whole fleet over a roster box `crew up` has not created yet — an absent row is inventory drift, and 500 is reserved for a box that was there and refused (#77)
