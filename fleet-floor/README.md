# Fleet Floor

A live-ops view of the `heavy-duty/crew` fleet. Two levels in one self-contained,
dependency-free `index.html` — no build tools, no network, no external assets:

- **God-view floor** — a scrollable grid of the fleet, one **cell per box**. Each
  cell is a cinematic mini-room showing its robot (the vendor), role (builder /
  reviewer / triage, read from the room + light), state, and queue. Up top: live
  counts, **state/role filters**, and fleet **time metrics**; along the bottom:
  **active operations**, and a **fleet activity** stream.
- **Agent console** — click any unit to zoom into its full room. The robot is
  framed by an operator console: identity, vitals (box health, uptime, cron, repo),
  work queue, **access** links, a live **current-session** timer, **time metrics**,
  and **session history** — plus a message box and Pause / Restart / Power controls.

The four vendors render as distinct units — **claude** an armored humanoid,
**codex** a 6-legged spider, **grok** a floating astronaut, **kimi** a hovering
screen-face drone — each with idle / working / offline states.

## Run it

Two modes, and the page picks between them itself at load.

### LIVE — the real fleet, on `IP:PORT`

```sh
crew floor                       # → http://<host-ip>:8420/, prints the password
crew floor --port 9000 --user dan --pass hunter2
crew floor --local               # loopback only
```

Run it **on the box host**. It serves the page and polls every roster box every
60s, and the badge turns green **LIVE**. Because the page can power-cycle boxes
and start sessions, HTTP Basic auth is mandatory — without `--pass` one is
generated and printed once at startup.

### DEMO — no host, no fleet

```sh
open fleet-floor/index.html      # or double-click it
```

Opened from disk there is no collector to talk to, so the page stays on the
placeholder fleet, badged **DEMO DATA**, with the operator actions shown but
disabled. This is what the prototype always was, and it still works with no
network and no dependencies.

`index.html` is committed pre-built. To regenerate it from `src/`:

```sh
fleet-floor/build.sh             # concatenates src/{style.css,body.html,app.js}
```

## How live mode works (#38 / #39)

Both issues proposed a box-initiated collector — the box POSTs telemetry and
long-polls for commands — because the boxes have **no inbound network path**.
That is true of the network and beside the point: the operator host already
holds a control channel into every box, **`box exec`**, which is how `crew
status`, `crew hire` and `crew upgrade` have always worked. So the direction is
inverted, and nothing runs box-side at all:

```
host  --box exec-->  box     read duty evidence      (#38 telemetry)
host  --box exec-->  box     fire operator action    (#39 control)
```

### Three tiers, not one poll

The evidence poll used to answer every health question at one cadence, and one
of them over the network. They are now separated by what they cost:

| tier | how | network | cadence |
|---|---|---|---|
| **ping** | `box exec <box> -- true` | none | 10s |
| **evidence** | `probe.sh` — duty.log, cron, uptime, repos, lock age | none | 60s |
| **credentials** | markers the duty engine writes | **none** | read with evidence |

**The ping is an exec, not a socket.** A listening port is answered by the
guest *kernel*, so it stays green through a userspace that can no longer fork;
an exec needs the incus agent, a fork, an exec and a disk read, and fails
exactly when the box is wedged. It runs on its own thread with its own lock —
sharing the poll lock would queue every ping behind a 45s probe and the fast
tier would run at the slow tier's cadence — and is overlaid onto the snapshot
at read time, so it is never served up to a minute stale. Three consecutive
misses declare a box unreachable; one dropped ping is scheduler noise.

**Credentials are reported, never polled.** `gh auth status` inside every box
on every poll was ~7,000 api.github.com requests a day to re-derive a fact
that changes when a token expires, and at ~450ms it was the slowest thing in a
probe whose every other read is local. The duty engine already calls GitHub
every tick, so it learns for free: `gh_identity` harvests
`Github-Authentication-Token-Expiration` from the `gh api user` call the tick
was making anyway, and records a rejection when one actually happens — which
is a stronger claim than `gh auth status`, since that only proves the token
authenticates against `GET /`. Vendor credentials are read from the local
store by the agent profile's `bot_cli_present`, which returns **three** values
— 0 logged in, 1 definitely not, 2 cannot tell locally — and only 1 raises an
alert, because a false "your token is dead" at 3am costs more than a missed
one. Each vendor is a different problem:

| agent | credential store | relogin date knowable locally? |
|---|---|---|
| claude | `~/.claude/.credentials.json` | **yes** — `refreshTokenExpiresAt` |
| kimi | `$KIMI_CODE_HOME/credentials/kimi-code.json` | **yes** — the `exp` claim of the refresh JWT |
| codex | `${CODEX_HOME}/auth.json`, *or the desktop keyring* | no — refresh token is opaque |
| grok | `$GROK_HOME/auth.json` (a map of issuer::client slots) | no — refresh token is opaque |

The recurring trap is reading the wrong expiry. Every one of these files
carries a short-lived ACCESS token expiry — `expiresAt`, `expires_at` — that
the CLI refreshes silently, on the order of hours. A countdown to any of them
would fire several times a day on a box that is working perfectly. Only the
refresh credential answers "when must a human log in again", and two of the
four vendors do not expose it locally at all. Those two report **no expiry**
rather than a wrong one.

The third state earns its keep in the same place: codex can hold its
credential in the desktop keyring and grok can authenticate from
`XAI_API_KEY`, so on those boxes a missing `auth.json` is normal and is
reported as `2` — never as a logout. `bot_cli_probe`, which may use the
network, stays for the boot gate and `crew hire`, where a human is present and
one round-trip buys certainty.

`::gh`/`::vendor` therefore have no `ok` value. They are `flowing` (the engine
is talking to the service and has not been rejected), `missing`, or `unknown`
(no engine has run, so nothing is known). `crew status` reads the same
markers — `rehearsal-app.sh` asserts the two agree, and that only holds while
neither has a private source.

**The stuck lock.** `duty.sh` has always written `.duty.lock.since` and nothing
ever read it. A session hung on a vendor call keeps cron ticking, so duty.log
stays fresh, SILENT is satisfied, and the box renders green while doing
nothing. It is now reported as **STUCK** past two tick boundaries — roughly 20
minutes before `run_session`'s own timeout resolves it.

- **Telemetry** — [`server/probe.sh`](server/probe.sh) is piped into each box and
  reads what the duty engine already writes: `duty/VERSION`, `duty.log` (the
  `SESSION START/END` lines and each tick's wake reasons), `repos.txt`, cron,
  uptime, `gh auth status` and the agent profile's own `bot_cli_probe`. The
  queue chips are the work the **last tick actually detected**, not a
  placeholder list. A box is **SILENT** when it has not logged a line for two
  tick boundaries — the same death rule the engine uses.
- **Control** — every action is applied by the host: pause/resume comment and
  restore the box's crontab line, power/restart are `box down`/`box start`, and
  a message starts a real one-shot session of that box's own vendor CLI, logged
  to `duty/logs/` and marked in `duty.log` like any other session. The prompt
  travels as **stdin bytes** and is read from a file inside the box, so it never
  enters a shell command line.
- **Nothing is installed in a box**, no box egress is needed, and a box that is
  stopped or wedged fails its probe and is reported — rather than silently
  queueing commands nobody drains.

The collector is [`server/floor.py`](server/floor.py) — Python **stdlib only**,
no build step, no dependencies.

| route | method | purpose |
|---|---|---|
| `/` | GET | the page |
| `/api/fleet` | GET | latest telemetry snapshot |
| `/api/command` | POST | `message`, `pause`, `resume`, `restart`, `power-on/off`, `start-all`, `stop-all`, `wake-silent` |
| `/api/logs` | GET | tail `duty.log` or one session log |
| `/healthz` | GET | liveness |

**Two things the page still cannot do.** "Open box terminal" copies `box shell
<name>` for you — a browser cannot attach a shell. And a box that is not running
cannot be messaged; the request is refused rather than queued.

## Tests

```sh
fleet-floor/test/run.sh                 # collector + box-side + CLI + page, no fleet needed
fleet-floor/test/run.sh --no-browser    # everything except the page
drill/rehearsal-app.sh                  # the same, against this host's REAL boxes
drill/rehearsal-all.sh                  # three roles, then the app
```

Two halves, because neither can do the other's job:

- **`fleet-floor/test/run.sh`** drives the collector against a stub `box` CLI
  (`test/stub-box`, shaped by `test/fixtures/fleet.txt`). That is the only way
  to reach the states that matter and that no real host has on demand: a
  **wedged** box whose `box exec` never returns, an **unreachable** one, one
  whose cron went **silent**, one **paused**, one **hired seconds ago with no
  sessions**, one **not created at all**, and one whose `duty.log` is
  **corrupt** or contains **markup**. A fleet of healthy boxes would pass a
  badly broken renderer.
- **`drill/rehearsal-app.sh`** proves what the stub cannot fake: that `box
  exec` into a real box yields the evidence the floor claims to read, that the
  floor and `crew status` **agree** about every box (they share `probe.sh`'s
  sources, so a disagreement means one is lying to an operator), and — with
  `--allow-control --boxes <name>` — that pause/resume really moves the box's
  crontab. It is **read-only by default**; a drill that quietly power-cycles a
  working fleet member is worse than no drill. It also runs the page walk in
  read-only mode and **proves** it stayed read-only, by putting a logging
  wrapper ahead of the real `box` on `PATH` and checking that not one mutating
  call was made. That assertion lives here rather than in CI because it is
  about not mutating a *real* fleet, and this is the only place there is one —
  in CI it cost a second full walk to make a weaker claim.

`test/boxside.sh` is what stops the rest being circular: every other collector
assertion runs against `stub-box`, which *imitates* what `probe.sh` emits, so a
real bug in `probe.sh` or in the operator-message script would sail straight
through. Neither needs a box to run, so both are executed for real and their
output fed to the actual parser — including the message script's quoting, which
must deliver an operator's prompt as **one argv element, byte-identical**,
metacharacters and all.

The page half (`test/browser.js`) needs `playwright-core` and a Chrome —
`npm i playwright-core`, and `PW_CHROME` to point at one. It asserts the
things a screenshot cannot: that a control targeted the box the operator was
looking at, that hostile log text stayed text, that a down box states its
reason, that the log viewer is not a blockable popup. `test/stale.js` kills
the collector under a live page and checks the page admits it rather than
serving a frozen fleet that looks calm; `test/churn.js` and
`test/transition.js` cover the other two ways what is on screen stops being
true — the box leaves the roster, or goes down — while someone is standing in
its console. When the driver or browser is missing these **skip loudly** — a
silently-skipped UI test reads exactly like a passing one — and in CI they do
not skip at all: `FLOOR_TEST_REQUIRE_BROWSER=1` makes a missing browser a
failure, because on the merge gate a skip and a pass are indistinguishable.

The walk runs against two very different fleets, so it is told which it is
looking at. `FLOOR_TEST_FIXTURE=1` (set by `test/run.sh`, **never** by the
drill) says the fleet is `fixtures/roster.txt`, whose contents are guaranteed:
a box with hostile log text, a box inside its first session, several offline.
There the walk *demands* those boxes and fails loudly if it cannot reach one,
because the checks that depend on them would otherwise vanish in silence. A
real fleet has no such boxes and, when healthy, nothing offline at all — so
without the flag the walk asserts only what any fleet must satisfy. `cli.sh`
asserts both halves: `run.sh` sets it, the drill does not.

## Files

```
fleet-floor/
  index.html        # built, self-contained — this is what runs
  build.sh          # sh concatenator, no deps
  src/style.css     # command-center + cinematic-room styles
  src/body.html     # DOM: canvas, fleet bar, ops bar, agent rails, console
  src/app.js        # canvas render engine (robots/rooms/states), floor, console,
                    #   the live/demo switch, and the demo feed
  server/floor.py   # the collector: serves the page, polls the fleet, applies actions
  server/probe.sh   # read-only duty evidence reader, run inside a box via box exec
  test/run.sh       # collector + box-side + CLI + page, against a stub box CLI
  test/cases.sh     # collector assertions, grouped by the round that found them
  test/boxside.sh   # runs probe.sh and the message script FOR REAL
  test/cli.sh       # `crew floor` argument handling and the auth decision
  test/stub-box     # fake `box`, driven by test/fixtures/fleet.txt
  test/browser.js   # playwright-core walk of the real page
  test/stale.js     # kills the collector, checks the page says so
  test/churn.js     # removes a box from the roster under an open console
  test/transition.js# takes a box down under an open console
```
