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
fleet-floor/test/run.sh                 # collector + page, no fleet needed
fleet-floor/test/run.sh --no-browser    # collector only
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
  working fleet member is worse than no drill.

The page half (`test/browser.js`) needs `playwright-core` and a Chrome —
`npm i playwright-core`, and `PW_CHROME` to point at one. It asserts the
things a screenshot cannot: that a control targeted the box the operator was
looking at, that hostile log text stayed text, that a down box states its
reason, that the log viewer is not a blockable popup. `test/stale.js` kills
the collector under a live page and checks the page admits it rather than
serving a frozen fleet that looks calm. When the driver or browser is missing
these **skip loudly** — a silently-skipped UI test reads exactly like a
passing one.

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
  test/run.sh       # collector + page suite, against a stub box CLI
  test/cases.sh     # the assertions, grouped by the round that found them
  test/stub-box     # fake `box`, driven by test/fixtures/fleet.txt
  test/browser.js   # playwright-core walk of the real page
  test/stale.js     # kills the collector, checks the page says so
```
