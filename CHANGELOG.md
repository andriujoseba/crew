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
release PR from the fragments in changelog.d/. -->

## 0.1.2 — 2026-08-10

### Added

- The rehearsal drills the triage hygiene slot's board audit: it reports
  `attention` on a pull request and on an unassigned issue, naming both with
  their class (#441).
- The rehearsal drills that the board audit never repairs — both flags stay
  set, the unassigned issue stays unassigned, and neither fixture draws a
  comment (#441).
- The rehearsal drills the audit's alert transitions by count: silent on a
  clean board, one `🚨` when the malformed set appears, none while it is
  unchanged, one `✅` when it clears (#441).
- `drill/rehearsal-all.sh` takes `--no-attention-audit-drill` and records the
  leg's outcome in the round summary (#441).
- The rehearsal drills what the builder attention wake does after its ack: a
  claim with no open PR and no build branch is dispatched to the normal duty
  tick, leaving no PR and no `build/<issue>-*` branch behind (#440).
- The rehearsal drills the timed-out pickup report — one `⏱️` comment naming a
  stable log link, that link resolving to a readable file, and the operator
  alert naming the immutable run log (#440).
- `drill/rehearsal-all.sh` takes `--no-attention-drill` and records the leg's
  outcome in the round summary (#440).
- The drill asserts the boot check's `cli probe` verdict is `ok` and that the
  boot block carries no `WARN`, for the agent the round was given (#427, #240).
- Release drills now trip, suppress, alert once, and recover a staged terminal session lane for the drilled agent (#424).
- The drill asserts the operator watch set is `repos.txt` ∪ `notify-repos.txt`,
  both halves reaching the operator on one notify tick (#423, #316).
- `drill/rehearsal-all.sh --no-notify-drill` opts out of the notifier-union
  leg (#423).
- The real-host rehearsal now proves dirty merged-branch worktrees are preserved remotely before removal and retained when preservation fails (#422).
- The install rehearsal now measures the installed tree on a real host: the first install, the upgrade and the offline artifact each carry none of the installer's excluded roots, by path, and stay within the shipped size bound (#365, #421).
- The drill record now carries each installed tree's measured size rather than a bare pass, and reads both the excluded roots and the bound from their shipped sources instead of spelling them (#365, #421).
- The app rehearsal now reads the floor surfaces this release shipped: the serving host's own version, and each engine's integrity verdict taken from the box's own answer (#420).
- The app rehearsal now asserts the roster boxes counted but not drawn, the repair verb a floor with nothing hired names, and the split between deliberately disarmed and genuinely silent boxes (#420).
- The app rehearsal now asserts `crew up --dry-run` changes nothing, that an unanswered engine probe reads `unknown` rather than never-hired, and that `no build duty` names a cause and a count (#420).
- The release rehearsal now proves the check-conclusion resume wake, malformed-signal warning and zero-action stop on consecutive real ticks. (#419).
- The builder drill now exercises draft return and the settled-head panel-request gate through a live fix round (#418).
- `.ceremony/RELEASES.md` joins the vendored doctrine mirror (#350).
- The fleet-floor header shows the serving host's exact crew version (#347).
- The triage hygiene slot reports `attention` flags on pull requests or unassigned issues without repairing them. (#303).
- `drill/teardown.sh` removes what a drill round created — its boxes and its
  public sandbox repositories — naming each with its creation date and asking
  once, and doing nothing on an already-clean host (#217).
- Teardown deletes only names that are exactly the drill's own and that no
  roster on the host claims; a fleet member is refused even where its name
  matches the drill pattern, and one bad name in a run deletes nothing (#217).
- A sandbox repository is deletable only when its owner is the host's own gh
  identity as well as its name being a drill name, so a drill-shaped
  repository under another account is refused (#217).
- Teardown tells "found nothing" from "could not look": what it cannot
  inspect — no gh identity, no box CLI, an unreadable `box list`, or a single
  repository lookup that fails for anything but a measured 404 — exits 2
  INCOMPLETE, naming it, instead of reporting a clean host (#217).
- Naming the same box or sandbox twice in one teardown deletes it once,
  instead of a second removal failing and reporting a box that *was* removed
  as a failure (#217).
- Each release publishes `crew-<version>.sh.sha256` beside the installer, which
  `sha256sum -c` verifies (#210).
- The floor's unit tile renders the engine's integrity verdict beside its
  version: `current`, `MODIFIED` or `unverified` (#159, #190).

### Changed

- The drill's boot-check failures quote the line they read and name the agent,
  instead of reporting only that the log was non-empty (#427).
- Release initialization now audits every window fragment against the real-host drill before the round runs (#425).
- The drill re-asserts `repos.txt` after writing `notify-repos.txt` and aborts
  the round if the work set widened (#423).
- `drill/teardown.sh` removes the per-role `crew-drill-<role>-notify` sandbox
  (#423).
- Builder sessions declare complete rounds without waiting for checks; the engine gates panel requests until the head settles (#402).
- Adopt ceremony `0.6.2`: every pin moves off `0.6.0`, across `release.yml`, `release-guards.yml`, `labels.yml` and `labels-sweep.yml` (#398).
- The vendored doctrine carries ceremony `0.6.1` and `0.6.2`: a round is declared answered as soon as its fixes are pushed, the pending-check wait belonging to whatever mediates the request (#398).
- `.ceremony/RELEASES.md` now says how a release window advances past a member that lands `post-merge` — triage splits the remainder, and the original's close is the release edge (#398).
- Every install channel ships only what an installed tree runs:
  `fleet-floor/dev/`, the page sources, the test suites, the drill and the
  repository's own furniture are no longer installed, leaving the tree under 2M
  whether it came from a checkout, the scp-able artifact, `gh` or `curl`
  (#365).
- Adopt ceremony `0.6.0`: every pin moves off `0.5.0`, across `release.yml`, `release-guards.yml`, `labels.yml` and `labels-sweep.yml` (#350).
- A changelog fragment entry must now end with its issue citation — one parenthesised group, then the final `.` — and the `changelog-armed` guard refuses anything else (ceremony#262, #350).
- The issue sweep now comments on undeclared collision edges, on an unblocked non-member during a standing release window, and on a `post-merge` item starved of wake evidence for 7 days (#350).
- The builder's `no build duty` line now names its cause: an empty board, a seen-ledger suppression with its count, or the slot held by an open PR — named, with the board's live ready count beside it (#345).
- `drill/rehearsal-all.sh` tears the round down when every leg passed; `--keep`
  retains it, and a round that failed or never reached phase 2 keeps its boxes
  and prints the teardown command (#217).
- A teardown that could not inspect part of the round gets its own
  `INCOMPLETE` row in the rehearsal summary and reds the round, rather than
  reporting `ok teardown (boxes and sandbox repos removed)` (#217).
- A rehearsal whose target box already exists refuses, naming the box, its
  creation date, and the two ways forward. `--reuse` keeps it and records that
  the pre-auth checks skip and why (#116, #217).
- The fleet floor draws a console only for boxes that are deployed: one never
  created or never hired is counted but not drawn, a stopped or unreachable one
  keeps its console, and a floor with none of them names `crew hire` (#204).
- The hygiene sweep pushes a dirty merged-branch worktree's uncommitted work —
  untracked files included — to a `wip/<branch>` ref before removing it, and
  removes it only once that push has landed (#168).
- The preservation is also recorded upstream, as a comment on the PR the
  worktree belonged to naming the remote, the ref and what it holds: the ref
  lives on a fork, which an org-level action can take away, and the comment
  cannot (#168).
- A push or a record that fails leaves the worktree and its work untouched,
  reported once as before (#168).
- The removal log names the ref, the remote and the `git fetch` that gets the
  work back (#168).
- The counts in that record list every preserved file, including files under a
  directory nobody had committed yet, and a worktree whose state cannot be read
  at all is kept rather than described as empty (#168).
- Staged content is preserved too: where the index holds a different version of
  a file than the working tree, it is kept as the commit below the `wip/` ref's
  tip, named in the record and reachable with `git checkout FETCH_HEAD^` (#168).
- A worktree whose only uncommitted work was staged and then reverted in the
  tree is now preserved and released, instead of being refused on every sweep
  forever (#168).
- Fix rounds return to draft when the panel closes a round without full approval (#139).

### Fixed

- The `pipefail`/`grep -q` guard now reads `cli/crew`, `install.sh`, `shared/install.sh`, `dist/*.sh` and `shared/lib/version-skew.sh`, so a regression in them can no longer pass with the suite green (#449).
- Remote-shell payloads are exempt from that guard by their shape rather than by filename (#449).
- Duty predicates now match completed producer output without `pipefail` race failures. (#447).
- Predicate checks no longer intermittently misread successful output under `pipefail` when `grep -q` exits early (#443).
- The rehearsal summary now reports the resume leg's own verdict instead of inferring it from the builder role's exit code (#435).
- The drill exits non-zero when teardown could not restore `repos.txt` or
  `notify-repos.txt`, including when the box stopped answering (#423).
- The drill's teardown reds when the pre-drill `repos.txt` backup the round
  made is gone, instead of reading a measured loss as "nothing was backed up"
  and vouching for a registry nobody compared (#423).
- The drill's notifier leg refuses to choose its second sandbox when the
  host's pre-drill work registry cannot be read, instead of checking the
  candidate against a watch set silently short of that half (#423).
- The drill's notifier leg tracks a handoff fixture from the moment its PR is
  created, and retries a close that failed, so neither a labelling failure nor
  a failed close leaves an open handoff PR occupying a later builder slot
  (#423).
- The drill skips the notifier leg when the configured operator chat is
  unreachable, instead of grading a valid bot token with an unusable chat as a
  leg failure (#423).
- The rehearsal round removes both the notifier leg's and the worktree-hygiene
  leg's per-round temporary files (#423, #422).
- The triage drill now proves post-merge issues remain untouched and launch no session (#417).
- Membership predicates no longer misread existing boxes, roster entries, drill sandboxes, or cron daemons under load (#411).
- Make reused-box install drills require a tick written after console removal (#408).
- Phase 0 stages the tracked source tree required by the repository fixture suite while excluding the unused fleet-floor development assets (#407).
- Guard every attributed builder-doctrine quotation in prompts against drift in either file (#406).
- Playwright dependencies installed at any repository depth are ignored, and the documented setup no longer creates package manifests (#405).
- Near-miss and post-threshold stranded resume lanes stop dispatching repeatedly after three zero-action attempts at one head (#403).
- Terminal agent failures stop their session lane after three attempts, alert the operator once, and resume automatically after recovery. (#388).
- Kimi sessions distinguish quota termination from transient failures and report whether they used tools. (#388).
- A builder session parked on a running check is now woken by that check finishing: the head's newest check conclusion joins the resume fingerprint (#384).
- A ready PR at a green head with no round-answered signal naming it is resumed on the next tick instead of the twelfth; pending and red heads still wait the full twelve (#384).
- A draft carrying a valid current-head signal at a green head with no panel requested is resumed rather than suppressed. The engine buys the session; the flip stays the builder's (#384).
- The resume prompt quotes ceremony `0.6.0`'s parked-resume sentence again, so it no longer attributes wording to `.ceremony/BUILDER.md` that the vendored doctrine does not contain (#363).
- `resume-prompt-quotes-the-doctrine` compares whitespace-normalised text, so a re-vendor that only rewraps the vendored prose can no longer red `main` while every word still agrees (#363).
- `shared-ci` runs on `.ceremony/**`, so a doctrine re-vendor is checked in its own PR instead of surfacing against the next unrelated merge (#363).
- Triage duty records post-session board state and suppresses unchanged unblockable leads instead of waking itself again. (#359).
- The triage engine's board scan counts `post-merge` as a queue label, so an
  issue in that state is no longer reported as a stray on every tick (#358).
- `blocker:unrequested` is no longer written while the head's checks are pending or failing, so a builder waiting out a run is not flagged for not requesting (#350).
- `blocker:unrequested` now waits for the head and the round's newest verdict to stand still, so a round still in motion is not flagged (#350).
- `drill/install-drill.sh` step 9 no longer reds on a box hired minutes
  earlier: with no tick history to diff, it waits one cron boundary plus grace
  for a tick to land after the console removal (#341).
- Step 9's failure names which of engine, cron or tick went missing and what
  was read for it, instead of printing the removal's transcript (#341).
- `fleet-floor/test/cli.sh` no longer reds on a release tree: the `crew up`
  post-skip assertion accepts the already-hired skip as well as the re-bake
  (#323).
- The same case's failure message now names the box that was expected past the
  skip, instead of claiming the roster loop stopped (#323).
- A round-answered signal posted with its marker slot unrendered is now detected:
  the engine warns naming the comment, and the PR becomes due for resume on the
  next tick instead of the twelfth (#319).
- Resume reads each ready PR's comments again, so a PR that signalled correctly
  is no longer counted as unsignalled (#314, #319).
- Operator notifications now cover every repository the fleet works in (#316).
- `notify-repos.txt` now adds cross-repo handoff targets instead of replacing the work registry (#316).
- Fleet Floor state filters now separate deliberately disarmed boxes from genuinely silent ones. (#312).
- `crew status <box>` now reports an unanswered engine probe as unknown instead of inferring that the box was never hired (#308).
- Builder attention wakes dispatch new builds to the normal duty tick and report timed-out pickups on the issue and operator channel (#301).
- Kimi boot checks now use the guarded non-interactive command and resolved credential home used by duty sessions (#240).
- `crew up --dry-run` now reports hires for new boxes and summarizes every planned fleet action. (#218).
- Every release publishes the scp-able installer `crew-<version>.sh` as an
  asset, whichever door cut it (#98, #210).
- The browser walk's `gh ✓` check runs only over armed, ticking boxes, and
  reports that it did not run where there are none (#190).

## 0.1.1 — 2026-08-03

### Added

- `shared/docs/rehearsal.md` names `--remote` / `CREW_DRILL_REMOTE` as the way to rehearse against a fork (#302).
- The duty engine converges git identity before the first duty of every tick, and runs no session on a box whose commits would name another droid (#294).

### Changed

- Fleet Floor: grok's anatomy rebuilt under the blind-verifier loop protocol — predator arms with articulated talons, one committed key light, hard-point optics, grounded digitigrade feet — plus a `FLOORDEV.renderSolo` dev hook for droid-only studio renders (#289).
- CONTRIBUTING: a changelog fragment carries one entry per distinct user-visible change, with the reader test that decides it (#268).
- CONTRIBUTING: names which changelog rules block a review and which ride an approval as a nit — bullet count is editorial (#268).
- Adopt ceremony 0.4.1 (crew#259): a new `labels-sweep.yml` caller carries the
  reconcile sweep, with the hourly cron and the bootstrap dispatch relocated
  out of `labels.yml`, which gains `actions: write` for its trigger dispatch
  (ceremony#209).
- Sweeps now run detached from PRs: a queue-displaced sweep can no longer land
  a cancelled `reconcile` check on a PR, or set `blocker:ci-red` off its own
  displaced run (ceremony#208).
- `crew new`, `create-all`, `hire`, `hire-all`, `up`, `down`, `upgrade` and `gold` refuse under the shipped example fleet definition, naming `crew init` (#216).
- `crew status`, `crew profiles` and `crew up --dry-run` still work there, and say they are reading the shipped examples (#216).
- `examples/repos.txt` ships empty, so `crew init` seeds a fleet aimed at nothing until the operator names a repo (#216).
- The `fleet.conf` / `repos.txt` completeness check runs on the shipped examples too, not only on operator definitions (#216).
- Fleet Floor: the fleet view is a conference call — a vertically scrolling grid of webcam tiles, one per box, each unit front-on in close-up over a static blurred role-colour backdrop (#209).
- Fleet Floor: each tile carries AR telemetry — uptime, idle over the last 24h, queue, signal, a heartbeat trace that flatlines with the box, the open session's timer, and a live caption naming the work item (#209).
- Note: both `#209` entries above describe work that shipped in `0.1.0`. Their fragment went unconsumed because `0.1.0`'s release PR merged twelve commits stale (#212), so this is the first section that could carry them; the published `0.1.0` section is left as it stands (#162).
- Fleet Floor: grok's unit is rebuilt as a grounded stalker — digitigrade stance with hard deck contacts, a built-in predator-mask face, and a slicked-back cable mane with state language (#206).
- Fleet Floor: grok keeps a purple spine-slit readout and a flight-lineage service record; the jetpack hover and its thruster wash are gone (#206).
- Note: both `#206` entries above describe work that shipped in `0.1.0`. Their fragment went unconsumed because `0.1.0`'s release PR merged twelve commits stale (#212), so this is the first section that could carry them; the published `0.1.0` section is left as it stands (#162).

### Fixed

- Resume dispatches only when a draft's head, a foreign comment or review, or its referenced issue has moved since the last resume — a parked draft no longer wakes a session every tick forever. The builder's own comments and reviews are excluded (#314).
- `shared/prompts/resume.txt` posts the resume marker only when the session is going to act on the draft (#314).
- A resume that makes no commit at one head three times running is suppressed until the head moves, with one WARN in `duty.log` naming the PR, the head and the count (#314).
- `shared/docs/rehearsal.md` clones `heavy-duty/crew` at `main`, the drill's own default, not a personal fork and its merged branch (#302).
- Author-specific review panels now keep each builder's paired reviewer identity out of crew's required roster. (#298)
- A box's git identity is derived from its gh credential, so commits are bylined by the account that pushed them instead of the account the box carried before an identity change (#294).
- `crew hire` and `crew upgrade` write the box's git identity when it is authenticated, and say plainly when there is no credential to copy yet (#294).
- The shipped `examples/notify-repos.txt` names the builder accounts' forks, so a `state:needs-human` PR pushed to one is swept instead of waiting for somebody to notice it (#294).
- A reviewer who requested changes is no longer re-requested forever at an unchanged head: one round-answered signal opens one round, and the verdicts answering it spend it (#286).
- A round-answered signal posted while a review round is still open now takes effect once that round closes, rather than requesting a reviewer mid-round (#286).
- Review requests and convergence use a repository's per-author panel when configured. (#285)
- `crew upgrade` now leaves operator-paused boxes paused. (#283)
- A hired box that has never ticked reports `waiting` for its `gh` and vendor
  credentials instead of `stale`, in `crew status` and on the fleet floor (#265)
- Builder ticks keep ready issues claimable after choosing one and repair ledgers that previously buried the queue. (#264)
- Session history distinguishes successful no-op runs and shows their final reply. (#256)
- Fleet-floor messages now carry the duty environment contract. (#255)
- Codex sessions use medium reasoning effort. (#255)
- A board signal created during a triage box's mention session wakes triage in the same tick, instead of waiting a full tick (#253).
- A mention session that clears the last board signal no longer launches a triage session on the pre-session reading (#253).
- Test suites ignore ambient crew and duty configuration. (#252)
- Round logs retain verdicts on their original head after GitHub re-points reviews during a base merge. (#249)
- `crew floor` refuses under the shipped example fleet definition, in the CLI and in `floor.py` alike: a console over a definition nobody wrote could arm cron, power-cycle boxes and start model sessions (#244).
- `floor.py`'s fleet-definition completeness check runs whoever owns the directory, matching the CLI (#244).
- Resume stranded unsignalled PRs and retry CI-red heads after their checks settle. (#243)
- Warn once when a PR waits for its round-answered signal. (#243)
- CI-red and attention fix rounds now receive the complete round protocol and finish with the answered-head signal. (#242)
- The kimi profile launches its CLI non-interactively (#240).
- The kimi profile resolves its credential home across `~/.kimi` and `~/.kimi-code` (#240).
- Scope labels now cover the full install channel and the engine's test gate. (#238)
- `crew status` prints the whole roster when a hired box has no duty log yet, instead of stopping at the first one (#224).
- That box's row reads `no ticks yet` (#224).
- Fleet overlap checks now skip and report unreadable GitHub event payloads without stopping crew commands. (#223)
- Installer completion messages now report the recorded source provenance. (#222)
- `crew status <box>` reads `no ticks yet` on a box hired minutes ago — the
  same words its table and the floor already use for that box — naming the duty
  log it waits for and the tick that writes it, instead of `(unreachable)`
  (#221).
- The same view on an un-hired box names the absent engine rather than the
  missing log (#221).
- `crew status`: an un-hired box whose tenant role never converged reads `INCOMPLETE` and its note names the bootstrap recovery instead of `crew hire` (#220).
- `crew hire`: refuses a box rig never converged, naming what is missing; `--force` overrides (#220).
- `crew hire-all` and `crew up`: skip such a box, name it in the summary, and exit non-zero, while still hiring every healthy box in the same run (#220).
- `crew status <box>`: reports the rig role marker and which rig converged the box (#220).
- `crew create-all` continues after box failures and reports created, existing, and failed boxes (#219).
- The fleet floor's page names a paused box PAUSED and a disarmed one DISARMED
  in the headline, the CRON vital, the big card, the status line, the
  alert-coloured `silent` counter and the stage counts, so SILENT is reserved
  for a box that should be ticking and is not (#203).
- Fleet Floor now measures box liveness and session recency without mixing host and guest clocks. (#181)
- The engine reports a dirty worktree it left behind once per worktree and dirt state, not on every tick (#167).
- That report names the branch the worktree holds and the `git worktree add` failure it will cause (#167).

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
