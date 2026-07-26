#!/usr/bin/env python3
"""floor.py — the fleet-floor collector, served from the operator host.

Closes #38 (telemetry) and #39 (operator control) WITHOUT a box-side agent.

The issues both proposed a box-initiated collector — box POSTs /report, box
long-polls /prompts — because the boxes have no inbound network path. That is
true of the network and irrelevant here: the operator host already holds a
control channel into every box, `box exec`, and that is how `crew status`,
`crew hire` and `crew upgrade` have always worked. So the direction inverts:

    host --box exec--> box     read duty evidence   (#38)
    host --box exec--> box     fire operator action (#39)

Nothing is installed in a box, no box egress is required, no collector client
runs on the guest, and a box that is stopped or wedged simply fails its probe
and is reported SILENT instead of hanging a queue nobody drains.

Because the page can now do things — restart boxes, cut power, start model
sessions — the server refuses to serve without HTTP Basic auth.

Stdlib only, no build step: the crew CLI is bash and this host is not
guaranteed a package manager, let alone a virtualenv.
"""

import base64
import hmac
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
CREW_ROOT = os.path.dirname(os.path.dirname(HERE))
INDEX = os.path.join(CREW_ROOT, "fleet-floor", "index.html")
PROBE = os.path.join(HERE, "probe.sh")
AGENTS_DIR = os.path.join(CREW_ROOT, "shared", "conf", "agents")
# Overridable so a test (or an operator running a floor over an alternate
# fleet) never has to mutate the tracked roster in place. The suite used to
# swap this file and restore it on exit, which meant any killed run left the
# real fleet.roster clobbered in the working tree.
ROSTER = os.environ.get("CREW_FLOOR_ROSTER") or os.path.join(CREW_ROOT, "fleet.roster")

# A tick is 5 minutes; the engine's own death rule is "no evidence for two tick
# boundaries", so the floor uses the same number rather than inventing one.
TICK_S = 300
SILENT_AFTER_S = 2 * TICK_S

# box exec into a wedged box can block forever; every probe is capped so one
# sick box cannot stall the whole poll. Overridable so the test suite can
# exercise a wedged box without waiting the production timeout for it.
PROBE_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_PROBE_TIMEOUT", "45"))
ACTION_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_ACTION_TIMEOUT", "120"))


def log(msg):
    print("%s floor: %s" % (datetime.now(timezone.utc).strftime("%H:%M:%S"), msg),
          flush=True)


def run(argv, timeout, stdin_data=None):
    """Run a host command. Returns (rc, stdout, stderr) and never raises.

    The timeout is enforced against the whole PROCESS GROUP, not just the
    child. `box exec` runs a shell inside the box; if anything it spawned
    outlives the kill while still holding the stdout pipe, communicate() waits
    for EOF on that pipe and blocks long past the deadline — which is exactly
    the hang the timeout exists to prevent, and it only shows up against the
    kind of wedged box the timeout was written for. start_new_session puts the
    child in its own group so killpg can take the whole tree down.
    """
    try:
        p = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError as e:
        return 127, "", str(e)
    except Exception as e:                                  # noqa: BLE001
        return 1, "", str(e)

    try:
        out, err = p.communicate(
            stdin_data.encode() if stdin_data is not None else None, timeout=timeout)
        return (p.returncode,
                out.decode("utf-8", "replace"),
                err.decode("utf-8", "replace"))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            p.kill()
        try:
            p.communicate(timeout=5)
        except Exception:                                   # noqa: BLE001
            pass
        return 124, "", "timed out after %ss" % timeout
    except Exception as e:                                  # noqa: BLE001
        try:
            p.kill()
        except Exception:                                   # noqa: BLE001
            pass
        return 1, "", str(e)


# --------------------------------------------------------------------------
# roster + box inventory
# --------------------------------------------------------------------------

def read_roster():
    """<name> <agent> <role> [<from>] — the same reader crew's bash uses."""
    out = []
    try:
        with open(ROSTER) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) >= 3:
                    out.append({"box": parts[0], "agent": parts[1], "room": parts[2]})
    except OSError as e:
        log("cannot read roster: %s" % e)
    return out


def box_states():
    """name -> incus state, in ONE call rather than one per box."""
    rc, out, _ = run(["box", "list", "--json"], 20)
    states = {}
    if rc == 0:
        try:
            for b in json.loads(out):
                n = b.get("name")
                s = (b.get("state") or b.get("status") or "?")
                if isinstance(s, dict):
                    s = s.get("status", "?")
                if n:
                    states[n] = str(s).lower()
        except (ValueError, AttributeError, TypeError):
            pass
    return states


# --------------------------------------------------------------------------
# duty.log -> telemetry  (#38)
# --------------------------------------------------------------------------

TS = r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"
RE_START = re.compile(TS + r" SESSION START kind=(\S+) key=(\S+)")
RE_END = re.compile(TS + r" SESSION END kind=(\S+) key=(\S+) rc=(\d+) dur=(\d+)s outcome=(\S+)")
RE_ANY_TS = re.compile("^" + TS + r" ")

# Wake lines the duty modules already write. The queue shown on the floor is
# derived from these — it is real detected work, not a placeholder list. Each
# pattern yields (repo, key) pairs for the most recent completed tick.
RE_QUEUE = [
    re.compile(TS + r" attention: (\S+?)#(\d+) — launching pickup session"),
    re.compile(TS + r" review: (\S+?)#(\d+) head moved during dedup"),
]
RE_REVIEW_BATCH = re.compile(TS + r" review: (\S+) needs verdicts on: (.+)$")
RE_BUILD_DUTY = re.compile(TS + r" (\S+): build duty \(ready unclaimed=(\d+), whole rounds owed=(\d+)\)")
RE_TRIAGE = re.compile(TS + r" (\S+): signals:(\S+) launching triage session")
RE_MENTION = re.compile(TS + r" (\S+): (\d+) unread mention")
RE_RESUME = re.compile(TS + r" (\S+): resume duty")


def parse_ts(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return 0.0


def parse_probe(text):
    """Split the probe's `::key value` record from its delimited log section."""
    meta, loglines, in_log = {}, [], False
    for line in text.splitlines():
        if line == "::logstart":
            in_log = True
            continue
        if line == "::logend":
            in_log = False
            continue
        if in_log:
            loglines.append(line)
        elif line.startswith("::"):
            k, _, v = line[2:].partition(" ")
            meta[k] = v.strip()
    return meta, loglines


def last_tick_block(loglines):
    """Lines of the most recent `duty run start` block — the current work set."""
    start = None
    for i in range(len(loglines) - 1, -1, -1):
        if " duty run start" in loglines[i]:
            start = i
            break
    return loglines[start:] if start is not None else loglines[-40:]


def derive_queue(loglines):
    """Work the last tick actually detected, as {repo,key} chips."""
    q, seen = [], set()

    def add(repo, key):
        k = (repo, str(key))
        if k not in seen:
            seen.add(k)
            q.append({"repo": repo, "key": str(key)})

    for line in last_tick_block(loglines):
        for rx in RE_QUEUE:
            m = rx.search(line)
            if m:
                add(m.group(2), m.group(3))
        m = RE_REVIEW_BATCH.search(line)
        if m:
            for num in re.findall(r"#?(\d+)", m.group(3)):
                add(m.group(2), num)
        m = RE_BUILD_DUTY.search(line)
        if m:
            ready, owed = int(m.group(3)), int(m.group(4))
            for n in range(ready):
                add(m.group(2), "ready %d" % (n + 1))
            for n in range(owed):
                add(m.group(2), "round %d" % (n + 1))
        m = RE_TRIAGE.search(line)
        if m:
            add(m.group(2), m.group(3))
        m = RE_MENTION.search(line)
        if m:
            add(m.group(2), "%s mention" % m.group(3))
        m = RE_RESUME.search(line)
        if m:
            add(m.group(2), "resume")
    return q


def derive_sessions(loglines, now):
    """Finished sessions (newest first) and the open one, if any."""
    done, opens = [], []
    for line in loglines:
        m = RE_END.search(line)
        if m:
            done.append({
                "ts": parse_ts(m.group(1)), "kind": m.group(2), "key": m.group(3),
                "rc": int(m.group(4)), "dur": int(m.group(5)), "out": m.group(6),
            })
            if opens:
                opens.pop()
            continue
        m = RE_START.search(line)
        if m:
            opens.append({"ts": parse_ts(m.group(1)), "kind": m.group(2), "key": m.group(3)})

    done.sort(key=lambda s: s["ts"], reverse=True)
    for s in done:
        s["ago"] = max(0, int((now - s["ts"]) / 60))
    cur = None
    if opens:
        o = opens[-1]
        # A START with no END that predates the silence rule is a crashed or
        # killed session, not a running one — the box would have logged the END.
        if now - o["ts"] < 6 * 3600:
            cur = {"key": o["key"], "kind": o["kind"], "start": int(o["ts"])}
    return done, cur


def spark_24h(sessions, now):
    """22 buckets of session activity, matching the console's sparkline."""
    buckets = [0.0] * 22
    span = 24 * 3600.0
    for s in sessions:
        age = now - s["ts"]
        if 0 <= age < span:
            idx = 21 - int(age / span * 22)
            buckets[min(21, max(0, idx))] += 1
    peak = max(buckets) or 1.0
    return [round(0.06 + 0.94 * (b / peak), 3) for b in buckets]


def probe_box(unit, agent_conf):
    """One box's evidence, via `box exec`. Never raises — failure is a datum."""
    with open(PROBE) as f:
        script = f.read()
    rc, out, err = run(["box", "exec", unit["box"], "--", "bash", "-lc", script],
                       PROBE_TIMEOUT_S, stdin_data=agent_conf)
    if rc != 0:
        return None, (err.strip().splitlines() or ["box exec failed (rc %d)" % rc])[-1]
    return out, None


def build_unit(unit, state, agent_conf, now):
    """Roster entry + live probe -> the record the page renders."""
    u = dict(unit)
    u.update({
        "state": "offline", "engine": "", "gh": "unknown", "vendor": "unknown",
        "queue": [], "sessions": [], "cur": None, "spark": [0.0] * 22,
        "up": {"h": 0, "m": 0}, "repo": "", "repos": [], "logs": [],
        "longest": 0, "avg": 0, "success": 0, "today": 0,
        "paused": False, "cron": {"ok": False, "last": None, "age": None},
        "note": "",
    })

    if state is None:
        u["note"] = "not created — crew new %s" % unit["box"]
        return u
    if state == "stopped":
        u["note"] = "stopped — crew up starts it"
        return u

    raw, err = probe_box(unit, agent_conf)
    if raw is None:
        u["note"] = "unreachable: %s" % err
        return u

    meta, loglines = parse_probe(raw)
    u["engine"] = meta.get("engine", "")
    u["gh"] = meta.get("gh", "unknown")
    u["vendor"] = meta.get("vendor", "unknown")
    u["paused"] = meta.get("paused", "0") != "0"
    u["repos"] = [r for r in meta.get("repos", "").split() if r]
    u["logs"] = [f for f in meta.get("sessionlogs", "").split() if f]
    try:
        up = int(meta.get("uptime") or 0)
        u["up"] = {"h": up // 3600, "m": (up % 3600) // 60}
    except ValueError:
        pass

    if not u["engine"]:
        u["note"] = "not hired — crew hire %s" % unit["box"]

    # Cron liveness: tick.sh guarantees a line per boundary, so the newest
    # timestamped line IS the heartbeat.
    last_ts = 0.0
    for line in reversed(loglines):
        m = RE_ANY_TS.match(line)
        if m:
            last_ts = parse_ts(m.group(1))
            break
    if last_ts:
        age = int(now - last_ts)
        u["cron"] = {
            "ok": age < SILENT_AFTER_S and not u["paused"],
            "last": datetime.fromtimestamp(last_ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "age": age,
        }
    elif meta.get("cron", "0") == "0":
        u["note"] = u["note"] or "no cron armed — crew hire %s" % unit["box"]

    sessions, cur = derive_sessions(loglines, now)
    u["queue"] = derive_queue(loglines)
    u["cur"] = cur
    u["sessions"] = [{k: s[k] for k in ("ago", "kind", "key", "rc", "dur", "out")}
                     for s in sessions[:11]]
    u["spark"] = spark_24h(sessions, now)
    u["repo"] = (u["queue"][0]["repo"] if u["queue"]
                 else (u["repos"][0] if u["repos"] else ""))

    if sessions:
        durs = [s["dur"] for s in sessions]
        ok = sum(1 for s in sessions if s["rc"] == 0)
        u["longest"] = max(durs)
        u["avg"] = round(sum(durs) / len(durs))
        u["success"] = round(100 * ok / len(sessions))
        u["today"] = sum(1 for s in sessions if now - s["ts"] < 86400)

    # The state the floor colours by. Order matters: a paused or silent box is
    # reported SILENT even if a stale session line suggests work, because the
    # thing that would have ended that session is exactly what is not running.
    if u["paused"]:
        u["state"] = "offline"
        u["note"] = u["note"] or "paused by operator — resume from the console"
    elif last_ts and not u["cron"]["ok"]:
        u["state"] = "offline"
        u["note"] = u["note"] or "SILENT — no tick for %s" % fmt_dur(u["cron"]["age"])
    elif cur:
        u["state"] = "working"
    else:
        u["state"] = "idle"
    return u


def fmt_dur(s):
    if s is None:
        return "—"
    h, m = s // 3600, (s % 3600) // 60
    return "%dh %02dm" % (h, m) if h else ("%dm" % m if m else "%ds" % s)


# --------------------------------------------------------------------------
# poller
# --------------------------------------------------------------------------

class Fleet:
    """The telemetry snapshot, refreshed by one background thread."""

    def __init__(self, interval):
        self.interval = interval
        self.lock = threading.Lock()
        self.snapshot = {"live": True, "generated": None, "units": [], "polling": True}
        self._confs = {}
        # A poll is N concurrent `box exec` calls across the whole fleet. Every
        # control action wants a refresh afterwards, so without single-flight a
        # burst of clicks becomes a burst of full-fleet probe storms — and if
        # one box is wedged, each of those storms lasts the full timeout.
        self._poll_lock = threading.Lock()   # one poll at a time, ever
        self._flag_lock = threading.Lock()
        self._refreshing = False             # a refresh chain is running
        self._pending = False                # ...and another was asked for

    def agent_conf(self, agent):
        if agent not in self._confs:
            try:
                with open(os.path.join(AGENTS_DIR, "%s.conf" % agent)) as f:
                    self._confs[agent] = f.read()
            except OSError:
                self._confs[agent] = ""
        return self._confs[agent]

    def request_refresh(self):
        """Refresh after a control action, coalescing a burst into one poll.

        At most one poll runs and at most one more is queued: an operator who
        clicks five things gets the fleet re-read once after the last of them,
        not five overlapping fleet-wide probe storms.
        """
        def chain():
            while True:
                try:
                    self.poll_once()
                except Exception as e:                  # noqa: BLE001
                    log("refresh failed: %s" % e)
                with self._flag_lock:
                    if not self._pending:
                        self._refreshing = False
                        return
                    self._pending = False

        with self._flag_lock:
            if self._refreshing:
                self._pending = True
                return
            self._refreshing = True
        threading.Thread(target=chain, daemon=True).start()

    def poll_once(self):
        # Serialised against every other poll: the periodic loop and a
        # post-action refresh must never probe the fleet at the same time.
        with self._poll_lock:
            return self._poll_once_locked()

    def _poll_once_locked(self):
        roster = read_roster()
        states = box_states()
        now = time.time()

        units = [None] * len(roster)
        threads = []

        def work(i, unit):
            try:
                units[i] = build_unit(unit, states.get(unit["box"]),
                                      self.agent_conf(unit["agent"]), now)
            except Exception as e:                          # noqa: BLE001
                u = dict(unit)
                u.update({"state": "offline", "note": "probe error: %s" % e,
                          "queue": [], "sessions": [], "cur": None,
                          "spark": [0.0] * 22, "up": {"h": 0, "m": 0},
                          "repos": [], "logs": [], "longest": 0, "avg": 0,
                          "success": 0, "today": 0, "paused": False,
                          "cron": {"ok": False, "last": None, "age": None},
                          "engine": "", "gh": "unknown", "vendor": "unknown",
                          "repo": ""})
                units[i] = u

        # Boxes are probed concurrently: serially, seven `box exec` round-trips
        # would make the poll interval a function of fleet size.
        for i, unit in enumerate(roster):
            t = threading.Thread(target=work, args=(i, unit), daemon=True)
            t.start()
            threads.append(t)
        for t in threads:
            t.join(PROBE_TIMEOUT_S + 15)

        snap = {
            "live": True,
            "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "interval": self.interval,
            "units": [u for u in units if u],
            "polling": True,
        }
        with self.lock:
            self.snapshot = snap
        return snap

    def get(self):
        with self.lock:
            return self.snapshot

    def loop(self):
        while True:
            t0 = time.time()
            try:
                snap = self.poll_once()
                silent = sum(1 for u in snap["units"] if u["state"] == "offline")
                log("polled %d units (%d silent) in %.1fs"
                    % (len(snap["units"]), silent, time.time() - t0))
            except Exception as e:                          # noqa: BLE001
                log("poll failed: %s" % e)
            time.sleep(max(5, self.interval - (time.time() - t0)))


# --------------------------------------------------------------------------
# operator control  (#39)
# --------------------------------------------------------------------------

# Fired into the box with `box exec`; the box initiates nothing.
PAUSE_SH = r"""
crontab -l 2>/dev/null | sed -E 's|^([^#].*tick\.sh.*)$|#CREW-FLOOR-PAUSED \1|' | crontab -
crontab -l 2>/dev/null | grep -c CREW-FLOOR-PAUSED
"""

RESUME_SH = r"""
crontab -l 2>/dev/null | sed -E 's|^#CREW-FLOOR-PAUSED ||' | crontab -
crontab -l 2>/dev/null | grep -cE '^[^#].*tick\.sh'
"""

# The operator's message becomes a real session of the box's own vendor CLI,
# detached so the HTTP request does not hold a model run open, and logged where
# every other session logs so it shows up in the console's history.
MESSAGE_SH = r"""
set -u
conf=/tmp/.crew-floor-agent.conf
cat >"$conf"
# shellcheck disable=SC1090
source "$conf"
export PATH="${BOT_PATH_PREPEND:-$HOME/.local/bin}:$PATH"
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
mkdir -p "$DUTY_DIR/logs"
prompt="$(cat "$DUTY_DIR/.floor-prompt")"
[ -n "$prompt" ] || { echo "empty prompt"; exit 2; }
ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
slog="$DUTY_DIR/logs/$(date -u '+%Y%m%dT%H%M%SZ')-operator-floor.log"
# One O_APPEND write under 4K is atomic, so this cannot interleave with a
# tick's own line even though the operator session runs outside the duty flock.
printf '%s SESSION START kind=operator key=floor timeout=1800s log=%s\n' "$ts" "$slog" >>"$DUTY_DIR/duty.log"
nohup setsid bash -c '
  DUTY_DIR="'"$DUTY_DIR"'"; slog="'"$slog"'"; start=$SECONDS; rc=0
  source "'"$conf"'"
  export PATH="${BOT_PATH_PREPEND:-$HOME/.local/bin}:$PATH"
  cd "$HOME"
  timeout -k 60 1800 "${BOT_CLI_CMD[@]}" "$(cat "$DUTY_DIR/.floor-prompt")" \
    </dev/null >"$slog" 2>&1 || rc=$?
  dur=$((SECONDS - start)); v=ok
  [ "$rc" -eq 124 ] && v=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && v=FAILED
  printf "%s SESSION END kind=operator key=floor rc=%s dur=%ss outcome=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$dur" "$v" >>"$DUTY_DIR/duty.log"
' </dev/null >/dev/null 2>&1 &
echo "session started; log $slog"
"""


def do_command(fleet, body):
    """Apply one operator action. Returns (http_status, result dict)."""
    action = str(body.get("action", ""))
    box = str(body.get("box", ""))

    roster = {u["box"]: u for u in read_roster()}
    fleet_wide = {"start-all", "stop-all", "wake-silent"}

    if action not in fleet_wide:
        if box not in roster:
            return 400, {"ok": False, "error": "unknown box %r" % box}

    def one(name, argv, timeout=ACTION_TIMEOUT_S, stdin_data=None):
        rc, out, err = run(argv, timeout, stdin_data)
        ok = rc == 0
        log("%s %s -> rc %d" % (action, name, rc))
        return {"box": name, "ok": ok, "out": (out or err).strip()[-400:]}

    def in_box(name, script, stdin_data=None):
        return one(name, ["box", "exec", name, "--", "bash", "-lc", script],
                   stdin_data=stdin_data)

    def agent_conf_for(name):
        return fleet.agent_conf(roster[name]["agent"])

    results = []

    if action == "message":
        prompt = str(body.get("prompt", "")).strip()
        if not prompt:
            return 400, {"ok": False, "error": "empty prompt"}
        if len(prompt) > 8000:
            return 400, {"ok": False, "error": "prompt too long"}
        # Two hops so the prompt is never interpolated into a shell string:
        # it travels as stdin bytes, and the session reads it from a file.
        w = one(box, ["box", "exec", box, "--", "bash", "-lc",
                      'mkdir -p "$HOME/duty" && cat > "$HOME/duty/.floor-prompt"'],
                stdin_data=prompt)
        if not w["ok"]:
            results.append(w)
        else:
            results.append(in_box(box, MESSAGE_SH, stdin_data=agent_conf_for(box)))

    elif action == "pause":
        results.append(in_box(box, PAUSE_SH))
    elif action == "resume":
        results.append(in_box(box, RESUME_SH))
    elif action == "restart":
        r = one(box, ["box", "down", box])
        results.append(r)
        results.append(one(box, ["box", "start", box]))
    elif action == "power-off":
        results.append(one(box, ["box", "down", box]))
    elif action == "power-on":
        results.append(one(box, ["box", "start", box]))
    elif action in ("start-all", "stop-all"):
        verb = "start" if action == "start-all" else "down"
        states = box_states()
        for name in roster:
            st = states.get(name)
            if st is None:
                results.append({"box": name, "ok": False, "out": "not created"})
                continue
            if (verb == "start") == (st == "stopped"):
                results.append(one(name, ["box", verb, name]))
            else:
                results.append({"box": name, "ok": True, "out": "already %s" % st})
    elif action == "wake-silent":
        # A silent box is one cron is not ticking for. Waking it means resuming
        # the crontab and, if it is stopped, starting it — not a model session.
        states = box_states()
        for u in fleet.get()["units"]:
            if u["state"] != "offline":
                continue
            name = u["box"]
            if states.get(name) == "stopped":
                results.append(one(name, ["box", "start", name]))
            elif states.get(name) is not None:
                results.append(in_box(name, RESUME_SH))
    else:
        return 400, {"ok": False, "error": "unknown action %r" % action}

    ok = all(r["ok"] for r in results) if results else False
    # A control action changes exactly what the page is displaying, so refresh
    # rather than leaving the operator to guess whether it took. Coalesced, so
    # a burst of clicks cannot become a burst of fleet-wide probe storms.
    fleet.request_refresh()
    return (200 if ok else 500), {"ok": ok, "action": action, "results": results}


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "crew-floor"
    protocol_version = "HTTP/1.1"

    # Args injected by serve()
    fleet = None
    auth_token = None

    def log_message(self, fmt, *args):
        pass                                    # the poller's log() is the log

    # -- auth ---------------------------------------------------------------
    def authed(self):
        got = self.headers.get("Authorization", "")
        if not got.startswith("Basic "):
            return False
        return hmac.compare_digest(got[6:].strip(), self.auth_token)

    def deny(self):
        # Slow a guesser down. The server is threaded, so this costs the
        # attacker far more than it costs the operator who mistyped once.
        time.sleep(0.5)
        body = b"crew floor: authentication required\n"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="crew floor"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # -- helpers ------------------------------------------------------------
    def send_bytes(self, status, ctype, payload, cache=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        if not cache:
            self.send_header("Cache-Control", "no-store")
        # The page has control actions; keep it out of anything else's frame.
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(payload)

    def send_json(self, status, obj):
        self.send_bytes(status, "application/json; charset=utf-8",
                        json.dumps(obj).encode("utf-8"))

    # -- routes -------------------------------------------------------------
    def do_GET(self):
        if not self.authed():
            return self.deny()
        path = urlparse(self.path).path
        qs = parse_qs(urlparse(self.path).query)

        if path in ("/", "/index.html"):
            try:
                with open(INDEX, "rb") as f:
                    return self.send_bytes(200, "text/html; charset=utf-8", f.read())
            except OSError as e:
                return self.send_bytes(500, "text/plain; charset=utf-8",
                                       ("cannot read %s: %s\n" % (INDEX, e)).encode())

        if path == "/api/fleet":
            return self.send_json(200, self.fleet.get())

        if path == "/api/logs":
            return self.serve_log(qs)

        if path == "/healthz":
            return self.send_bytes(200, "text/plain; charset=utf-8", b"ok\n")

        # The page reports errors for a living; a 404 for the icon Chrome asks
        # for unprompted is noise in exactly the console an operator scans.
        if path == "/favicon.ico":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        return self.send_bytes(404, "text/plain; charset=utf-8", b"not found\n")

    def serve_log(self, qs):
        box = (qs.get("box") or [""])[0]
        name = (qs.get("file") or [""])[0]
        if box not in {u["box"] for u in read_roster()}:
            return self.send_bytes(400, "text/plain; charset=utf-8", b"unknown box\n")
        # The filename comes from the browser: allow only the shape run_session
        # generates, so no traversal or shell metacharacter can reach the box.
        if name and not re.fullmatch(r"[A-Za-z0-9._@#-]{1,120}", name):
            return self.send_bytes(400, "text/plain; charset=utf-8", b"bad log name\n")
        target = ('"$HOME/duty/logs/%s"' % name) if name else '"$HOME/duty/duty.log"'
        rc, out, err = run(["box", "exec", box, "--", "bash", "-lc",
                            "tail -n 500 %s 2>/dev/null" % target], 30)
        payload = out if rc == 0 else "unreadable: %s" % (err.strip() or "rc %d" % rc)
        return self.send_bytes(200, "text/plain; charset=utf-8",
                               payload.encode("utf-8", "replace"))

    # Without these, BaseHTTPRequestHandler answers 501 from inside its own
    # request loop — before do_*() and therefore before any auth check. An
    # unauthenticated caller should learn nothing but "authenticate", so every
    # method this server does not implement is routed through the same gate.
    def do_PUT(self):
        return self.deny() if not self.authed() else self.send_bytes(
            405, "text/plain; charset=utf-8", b"method not allowed\n")

    do_DELETE = do_PUT
    do_PATCH = do_PUT
    do_OPTIONS = do_PUT

    def do_HEAD(self):
        if not self.authed():
            return self.deny()
        self.send_bytes(405, "text/plain; charset=utf-8", b"")

    def do_POST(self):
        if not self.authed():
            return self.deny()
        path = urlparse(self.path).path
        if path != "/api/command":
            return self.send_bytes(404, "text/plain; charset=utf-8", b"not found\n")
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 64 * 1024:
                return self.send_json(413, {"ok": False, "error": "body too large"})
            body = json.loads(self.rfile.read(n).decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError) as e:
            return self.send_json(400, {"ok": False, "error": "bad JSON: %s" % e})
        status, result = do_command(self.fleet, body)
        return self.send_json(status, result)


def serve(bind, port, user, password, interval):
    if not os.path.exists(INDEX):
        sys.exit("crew floor: %s is missing — run fleet-floor/build.sh first" % INDEX)

    fleet = Fleet(interval)
    Handler.fleet = fleet
    Handler.auth_token = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()

    threading.Thread(target=fleet.loop, daemon=True).start()

    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    log("serving fleet-floor on http://%s:%d/ (poll every %ds)" % (bind, port, interval))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        httpd.shutdown()


def main():
    ap_port = int(os.environ.get("CREW_FLOOR_PORT", "8420"))
    ap_bind = os.environ.get("CREW_FLOOR_BIND", "0.0.0.0")
    ap_user = os.environ.get("CREW_FLOOR_USER", "operator")
    ap_pass = os.environ.get("CREW_FLOOR_PASS", "")
    ap_int = int(os.environ.get("CREW_FLOOR_INTERVAL", "60"))
    if not ap_pass:
        sys.exit("crew floor: CREW_FLOOR_PASS is unset — refusing to serve "
                 "operator controls without auth")
    serve(ap_bind, ap_port, ap_user, ap_pass, ap_int)


if __name__ == "__main__":
    main()
