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

```sh
open fleet-floor/index.html      # or double-click it
```

`index.html` is committed pre-built. To regenerate it from `src/`:

```sh
fleet-floor/build.sh             # concatenates src/{style.css,body.html,app.js}
```

## Data status — DEMO (see the badge)

The **roster is real**: the 7 boxes are embedded from [`fleet.roster`](../fleet.roster).
**Everything else is placeholder** — per-box state, current session, queue, sessions,
metrics and the activity stream are generated client-side (`app.js`, `LIVE=false`,
`genData()`), and the UI is badged **DEMO DATA**. Operator actions (message, pause,
restart, power on/off, start/stop/wake, open box, raw logs) are **shown but disabled**
(`.woff`) for the same reason.

Wiring it to the real fleet is tracked here:

- **#38** — live telemetry feed (states, sessions, queue, metrics, activity).
- **#39** — operator control channel for the agent/fleet actions.

Both must keep the boxes' "no inbound path" isolation — the box always initiates.
Flip `LIVE=true` and replace `genData()`/`ROSTER` with the feed once #38/#39 land.

## Files

```
fleet-floor/
  index.html        # built, self-contained — this is what runs
  build.sh          # sh concatenator, no deps
  src/style.css     # command-center + cinematic-room styles
  src/body.html     # DOM: canvas, fleet bar, ops bar, agent rails, console
  src/app.js        # canvas render engine (robots/rooms/states), floor, console, mock feed
```
