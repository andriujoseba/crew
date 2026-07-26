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
```
