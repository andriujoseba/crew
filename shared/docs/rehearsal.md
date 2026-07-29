# Duty-engine rehearsal — runbook for a fresh box and a fresh session

> Automated form: `drill/rehearsal.sh` (run on the box HOST from a crew
> checkout) executes everything below mechanically — phase 1 always,
> phase 2 automatically once the operator has logged the drill box in —
> printing ok/FAIL per check. This document remains the explainer for what
> each check means, and the manual path when no host is at hand.
> It accepts `--agent <name>` and defaults to `claude`; available agents are
> the profiles under `shared/conf/agents/`.
>
> **One box, one role.** `--role triage|builder|reviewer` (default
> `reviewer`) selects both the installed role and the box
> (`crew-drill-<role>`). `drill/rehearsal-all.sh` runs all three in
> sequence. The fleet deploys single-role boxes (`fleet.roster`) and
> `duty.sh` gates every module on `has_role`, so a single box carrying all
> three would exercise a composite path nobody runs — and would hide the
> class of defect that let a reviewer box quietly run triage sweeps for an
> entire rehearsal (`heavy-duty/crew#28`).
>
> The three boxes may share ONE GitHub identity. That is safe **only**
> because `repos.txt` is now the scope for every module and each role gets
> its own sandbox: disjoint registries, disjoint work. Under the previous
> org-wide review sweep all three would have raced for the same verdicts.
>
> **Which boxes a drill looks at — never `fleet.roster`.** `crew hire`'s
> registry guard keys on roster *membership*, so a drill box listed in the
> tracked `fleet.roster` counts as a fleet member to every safety check —
> which is how three leftover drill boxes came to be armed against the
> production registry (`heavy-duty/crew#51`). So `drill/rehearsal-app.sh`
> takes its own:
>
> ```sh
> drill/rehearsal-app.sh --drill-roles "triage builder reviewer"  # generated
> drill/rehearsal-app.sh --roster ~/mine.roster.local             # hand-written
> ```
>
> `--drill-roles` builds the list from the `crew-drill-<role>` convention
> `rehearsal.sh` already owns, so it cannot drift from the boxes the drill
> actually uses; prefer it. `--roster` is for anything else, and
> `*.roster.local` is gitignored so such a file has a home. Both feed the
> SAME path to all three readers — the collector (`CREW_FLOOR_ROSTER`), the
> `crew status` it compares against (`CREW_ROSTER`), and its own counts.
> `rehearsal-all.sh` passes `--drill-roles` for the roles it just ran.
>
> **Operator-config registry drill.** `rehearsal-all.sh` also runs
> `drill/rehearsal-config.sh` once against the first drill box it installed.
> The script builds a temporary fleet definition with `crew init`, asserts
> `CONFIG_IS_OPERATOR=1`, and drives real `crew upgrade` calls through the
> divergence veto, both no-provenance migration outcomes, ordinary
> convergence, examples-fallback non-convergence, and incomplete-trio
> refusal. It backs up both `repos.txt` and its provenance record before the
> first mutation, restores both on EXIT/INT/TERM, and prints the restoration
> receipt. `--no-config-drill` is an explicit escape hatch for a role-only
> run; such a run does not cover the operator registry contract.
>
> **The browser walk** needs `playwright-core` *and* a browser —
> `playwright-core` deliberately ships without one. The drill probes the
> usual Chrome/Chromium paths and skips with a named reason if it finds
> none; `PW_CHROME=/path/to/chrome` overrides. Screenshots land in
> `.drill-shots/` (`--shots <dir>`) and outlive the run. To watch it drive:
> `FLOOR_TEST_HEADED=1`, optionally with `FLOOR_TEST_SLOWMO=250`.

You are validating the shared duty engine (crew PR #16) on a box that has
never run it. You have no context beyond this repo: read `shared/README.md`
first (architecture + provenance), then run the phases below IN ORDER.
Everything before "Phase 2" needs NO credentials — that is the point: the
engine must behave correctly, loudly, and harmlessly on a creds-free box.

The engine has passed static verification (shellcheck, 27 fixture tests,
three adversarial reviews) but before this rehearsal it has NEVER executed
a real tick. Assume bugs. Anything you find goes to the PR (Phase 3), with
logs, as a finding — never silently worked around.

## Phase 0 — acquire the exact tree, then run static checks

```sh
git clone https://github.com/dan-claude-bot/crew ~/crew-host
cd ~/crew-host
git checkout crew/shared-duty
drill/rehearsal.sh
```

The default invocation fetches `crew/shared-duty` from
`https://github.com/dan-claude-bot/crew.git` on the host, creates a Git bundle,
and streams that bundle into the box. The box needs no GitHub credentials and
receives a real `.git` tree at the exact reported SHA. Override acquisition
explicitly when needed:

```sh
drill/rehearsal.sh --remote <git-url> --ref <git-ref>
drill/rehearsal.sh --tree "$PWD"     # bundle this checkout's exact HEAD
```

Phase 0 aborts before any fixture or installer check if the remote/ref cannot
resolve, if a supplied tree is not a Git checkout, or if `shared/install.sh`
or `shared/test/run.sh` is absent. It never continues from a stale `~/crew`.
Once acquired, these are the static checks run inside the box:

```sh
shared/test/run.sh                   # must end: failed 0
command -v shellcheck && shellcheck -x shared/bin/*.sh shared/lib/*.sh \
  shared/install.sh cli/crew shared/conf/fleet.defaults.conf examples/fleet.conf \
  shared/conf/agents/*.conf shared/conf/roles/*.conf
```

## Phase 1 — pre-auth engine validation (no logins anywhere)

Install as the default claude reviewer. The agent CLI may be absent in this
phase: its profile's auth probe then returns non-zero, which is the expected
unauthenticated result, and no session can launch:

```sh
shared/install.sh --agent claude --role reviewer
```

To rehearse another supported runtime, pass the same agent consistently:
`drill/rehearsal.sh --agent grok` derives the `grok-box` template, installer
agent, assertions, auth probe, and login hint from the grok profile.

Verify, and record the output of each check:

1. `cat ~/duty/VERSION` — `crew@<sha>` matching `git rev-parse --short HEAD`.
2. `cat ~/duty/conf/instance.conf` — `BOT_AGENT=claude`, and `BOT_ROLES`
   equal to the `--role` under test (or the agent selected with `--agent`).
3. `crontab -l` — no duty tick line. The rehearsal never arms cron.
4. After each explicit `~/duty/bin/tick.sh`, `~/duty/duty.log` gains evidence:
   `duty run start` → a WARN that the login cannot be resolved →
   `duty run end`. EVERY invoked tick must produce lines; silence after
   invocation is a finding (that is the tick evidence contract).
5. `~/duty/boot-check.log` — one boot block; `cli probe: FAILED` is
   CORRECT here; `~/duty/.boot-id` must NOT exist (marker only on
   verified auth).
6. Lock behavior: run `~/duty/bin/duty.sh` by hand twice —
   idle: it runs; concurrently with itself or a tick: the second prints
   "a tick already holds …" and exits 199.
7. Idempotence: rerun `shared/install.sh` **with the same
   `--agent`/`--role`** — it must keep the instance config and remain
   disarmed. `shared/install.sh --agent claude --role nosuchrole` must
   refuse.

   > Standing fleet installs resolve agent/role from the host-staged
   > `~/duty/fleet.roster` by box
   > name. This drill box is off-roster and is therefore reinstalled with its
   > explicit `--agent`/`--role`; a borrowed gh login cannot widen its role.

Repeat an explicit tick if needed. Expected steady state: three evidence lines
per tick, no growth in error variety, no session logs in `~/duty/logs/`, and
no board writes anywhere.
If the box is already authenticated when phase 1 begins, the rehearsal prints
three explicit `skip` rows for the unauthenticated WARN, boot-marker, and
no-session assertions. The summary counts those skips. A shorter authenticated
run is therefore visible as reduced coverage, never silently greener.

## Phase 2 — authenticated ticks (operator required)

STOP until the operator has decided the identity (one box per identity is
a fleet invariant). For the default claude runtime this includes the singleton
triage identity as well as builder/reviewer identities: never borrow any live
identity until its other box's cron is DISARMED. The same rule applies to every
agent. A throwaway test identity reuses Phase 1's explicit instance.conf;
login no longer selects a role. The operator performs `gh auth login` and the selected
agent profile's `AGENT_LOGIN_HINT`; you never handle credentials.

Authentication creates two independent hazards. First, another live box must
not run the same identity. Second, a normal engine registry points at production
repositories, so a drill tick can make legitimate-looking production writes.
The automated rehearsal therefore saves `repos.txt`, points it at nothing
before the first authenticated tick, replaces it with the sandbox alone before
phase 2, verifies that narrowing fail-closed, and restores the original on exit
or interruption.

The rehearsal deliberately does **not** arm cron. Every drill tick is explicit;
the old scheduled-boundary check was not worth creating an autonomous agent
that could outlive the invoking shell. On every exit the cleanup path removes
any duty tick left by an older run and restores the registry. If the shell or
box is in doubt, `box down <box>` is the reliable stop: `pkill` routed through
`box exec` is unprivileged and may be unable to signal an already-running
session.

The loops below are gated on `has_role`, so each box proves only its own.
`drill/rehearsal-all.sh` covers all three; a single `--role` run leaves the
other two loops **unproven, not passing** — read the per-role summaries, not
just the driver's final line.

| role | fixture the drill creates | what must happen |
|---|---|---|
| triage | an open issue carrying **no** queue label (a "stray") | a ruling comment, and the issue lands in exactly one of ready/claimed/blocked/epic; a re-tick adds no second ruling |
| builder | an issue labelled `ready` and **unassigned** | a `build/*` PR authored by the identity, referencing the issue; the issue leaves `ready`; a re-tick opens no duplicate |
| reviewer | a PR with the identity as requested reviewer | `🔎 reviewing head <sha>`, a verdict pinned to that head, dedup on re-tick, a re-request queuing a real re-review with the auto-approval off, re-request auto-approve with it on, and the one-shot gates |

> The builder fixture must be **unassigned**. `ready` + assigned is
> deliberately not pickable — an assignee means mid-claim, and counting
> those launched sessions with nothing to do. An assigned fixture makes the
> builder correctly ignore it, and the drill would then blame the engine
> for the fixture's mistake.

1. First authenticated tick: boot gate passes, `~/duty/.boot-id` appears,
   the login-resolution WARN disappears, review sweep logs
   `review: no outstanding review requests anywhere` (if true).
2. Attention drill: have the operator assign a test issue to the identity
   and add the `attention` label. Next tick: pickup session launches
   (`SESSION START kind=attention`), posts `📌 picked up`, REMOVES the
   label, then acts. Verify the session log in `~/duty/logs/`, and that
   the next tick logs `attention: none`.
3. Review drill: a scratch PR in a sandbox repo with a review request to
   the identity. Expect in order: candidate in the sweep log; the
   `🔎 reviewing head <full-sha>` comment posted exactly once (via
   post-once.sh); a verdict submitted via submit-verdict.sh pinned to that
   head; next tick adds no second announce and no second verdict. (It logs
   no `already covers head` skip either — `requested_reviewers` self-clears
   on submit, so a reviewed PR is not a candidate at all.)
4. Re-request rule, auto-approval OFF: append `AUTO_APPROVE_REREQUEST=0` to
   the box's `instance.conf` and re-request at the UNCHANGED head. Next
   tick must queue a **real** re-review — the verdict count grows — and it
   must NOT be the supersede path (no `re-request rule` in the body). The
   flag disables the auto-APPROVAL and nothing else (#151); it is not a
   switch for consulting the re-request. Remove the line afterwards.
5. Re-request drill: re-request review at the UNCHANGED head. Next tick
   must auto-approve through the gate (`--supersede-own`), log it, and the
   tick after must be quiet again.
6. Gate abuse: run `~/duty/bin/submit-verdict.sh` by hand with the same
   args as the landed verdict — must exit 0 "already present" WITHOUT a
   second review appearing on the PR. A short SHA must be refused.
7. Timeout: nothing to force here, but confirm every SESSION END line
   carries rc= and dur=.
8. Teardown: `repos.txt` is restored to its pre-drill contents and
   `crontab -l` contains no duty tick.

## Phase 3 — report

Comment on crew PR #16: which phases ran, every deviation from the
expectations above (with the duty.log/session-log excerpts), and what you
changed. Fixes go on the PR branch with the finding as provenance — the
same standard as everything already in it. If all of Phase 1 and 2 pass,
say so explicitly: that is the evidence the staged rollout
(`shared/docs/single-role.md`, migration order) is cleared to start.
