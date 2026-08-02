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
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
CREW_ROOT = os.path.dirname(os.path.dirname(HERE))
# INDEX is the app, not the fleet: it keeps resolving from the checkout even
# though the fleet definition below no longer does (#75).
INDEX = os.path.join(CREW_ROOT, "fleet-floor", "index.html")
PROBE = os.path.join(HERE, "probe.sh")
AGENTS_DIR = os.path.join(CREW_ROOT, "shared", "conf", "agents")
FLOOR_ENVELOPE = os.path.join(CREW_ROOT, "shared", "prompts",
                              "fragment-floor-envelope.txt")


def floor_message_prompt(operator_text):
    """Wrap an operator message in the shared one-shot environment contract."""
    try:
        with open(FLOOR_ENVELOPE, encoding="utf-8") as src:
            envelope = src.read()
    except OSError as exc:
        raise RuntimeError("floor message envelope unavailable: %s" % exc) from exc
    if not envelope:
        raise RuntimeError("floor message envelope is empty: %s" % FLOOR_ENVELOPE)
    return envelope + operator_text


def fleet_config_dir():
    """The same directory-atomic fleet selection cli/crew makes (#74/#75).

    One config dir serves both readers: the fleet the CLI drives and the
    fleet this console renders must be the same fleet, resolved the same
    way, or the two lie to the operator in different directions.
    CREW_CONFIG_DIR selects explicitly and an invalid or incomplete one is
    an error, exactly as the CLI refuses it; otherwise the first of the XDG
    config dir, the working directory and the shipped examples/ carrying
    fleet.roster wins. Returns (dir, is_operator) — examples/ is the
    compatibility fallback, not an operator definition.
    """
    examples = os.path.join(CREW_ROOT, "examples")

    def is_fleet(d):
        return os.path.isfile(os.path.join(d, "fleet.roster"))

    explicit = os.environ.get("CREW_CONFIG_DIR")
    if explicit is not None:
        if not explicit or not os.path.isdir(explicit) or not is_fleet(explicit):
            sys.exit("crew floor: CREW_CONFIG_DIR '%s' is not a fleet definition "
                     "(fleet.roster is required)" % explicit)
        chosen, operator = os.path.abspath(explicit), True
    else:
        xdg = os.environ.get("XDG_CONFIG_HOME")
        xdg_dir = (os.path.join(xdg, "crew") if xdg
                   else os.path.join(os.path.expanduser("~"), ".config", "crew"))
        chosen, operator = None, False
        for candidate in (xdg_dir, os.getcwd(), examples):
            if os.path.isdir(candidate) and is_fleet(candidate):
                chosen = os.path.abspath(candidate)
                operator = chosen != os.path.abspath(examples)
                break
        if chosen is None:
            sys.exit("crew floor: no fleet definition found (fleet.roster is required)")
    # Unconditional, because the property is that the check does not care who
    # wrote the directory: under `if operator:` the LEAST trusted definition
    # got the LEAST verification, and an incomplete fallback reported its
    # incompleteness in the CLI and not here. #216 item 4 made the CLI's
    # unconditional; this is the console's half (#244). It runs at resolution,
    # i.e. BEFORE the operator-config refusal in main(), so an incomplete
    # directory reports incomplete in both processes whoever owns it — the
    # same order the CLI has.
    missing = [f for f in ("fleet.conf", "repos.txt")
               if not os.path.isfile(os.path.join(chosen, f))]
    if missing:
        sys.exit("crew floor: fleet definition '%s' is incomplete; missing: %s"
                 % (chosen, " ".join(missing)))
    return chosen, operator


CONFIG_DIR, CONFIG_IS_OPERATOR = fleet_config_dir()


def require_operator_config():
    """The console refuses under the examples fallback, exactly as cli/crew's
    mutating verbs do (#216/#244).

    Both processes must refuse the same fleet the same way. `crew floor` is
    the door an operator uses, but floor.py is invoked directly too — by this
    repo's own suites and by anyone starting the server by hand — so a check
    only in cmd_floor is a door with a hinge side.

    Called from main() rather than at import: refusing at module level would
    also refuse in-process READERS that never bind a port (the CLI/console
    resolution-parity assertions, the box-side parser tests), and what this
    refuses is serving the console, not reading floor.py's answers. The words
    are the CLI's, so an operator who hits it from either direction gets one
    message and one instruction.
    """
    if CONFIG_IS_OPERATOR:
        return
    sys.exit("""crew floor: refuses under the shipped example fleet definition at %s.
  Nobody configured this host, so there is nothing here to create or arm: the
  examples are a scaffold to read, not a fleet to run. Scaffold your own —
    crew init
  then edit the generated files (repos.txt ships EMPTY: name your repos) and
  run again. 'crew status', 'crew profiles' and 'crew up --dry-run' keep
  working here, which is how you inspect a host in this state.""" % CONFIG_DIR)


def agent_conf_path(agent):
    """The resolved profile path — the same answer cli/crew's agent_conf
    gives: an operator agents/ file wins over the same-named shipped
    profile, the shipped set is the fallback (#75)."""
    if CONFIG_IS_OPERATOR:
        op = os.path.join(CONFIG_DIR, "agents", "%s.conf" % agent)
        if os.path.isfile(op):
            return op
    return os.path.join(AGENTS_DIR, "%s.conf" % agent)


# CREW_FLOOR_ROSTER stays the explicit override AHEAD of the config-dir
# search, so a test (or an operator running a floor over an alternate fleet)
# never has to mutate a tracked roster in place. The suite used to swap the
# file and restore it on exit, which meant any killed run left the shipped
# example roster clobbered in the working tree.
ROSTER = os.environ.get("CREW_FLOOR_ROSTER") or os.path.join(CONFIG_DIR, "fleet.roster")

# A tick is 5 minutes; the engine's own death rule is "no evidence for two tick
# boundaries", so the floor uses the same number rather than inventing one.
TICK_S = 300
SILENT_AFTER_S = 2 * TICK_S

# box exec into a wedged box can block forever; every probe is capped so one
# sick box cannot stall the whole poll. Overridable so the test suite can
# exercise a wedged box without waiting the production timeout for it.
PROBE_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_PROBE_TIMEOUT", "45"))
ACTION_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_ACTION_TIMEOUT", "120"))
# Fleet-wide controls share the host with evidence and heartbeat fan-outs.
# Eight is a no-op for today's seven-member roster and a hard ceiling as the
# single-role fleet grows.
ACTION_WORKERS = 8

# --- the ping tier ---------------------------------------------------------
#
# The evidence probe answers "what has this box been doing"; it reads ~600 log
# lines and cannot run often. "Is this box still answering" is a different and
# much cheaper question, and tying it to the evidence poll meant the fastest
# possible detection of a wedged guest was one full probe interval.
#
# `box exec <box> -- true` is the whole ping. Deliberately an EXEC and not a
# socket: a listening port is answered by the guest kernel, so it stays green
# through a userspace that can no longer fork. This round-trip needs the incus
# agent alive, a fork, an exec and a binary read off disk — it fails when the
# box is wedged, which is the entire point.
# Measured on the drill host: ~97ms wall, ~47ms host CPU per ping, and that
# 47ms is a FLOOR — `time` accounts only for children of the calling shell, so
# it excludes incusd's handling and the in-guest fork. At 10s across 7 boxes
# that is ~3% of a core. 1s would be ~33% for detection nothing downstream can
# act on.
#
# Two things this knob does NOT do, both of which make a smaller number a lie:
#   · values below 2 are silently ignored — ping_loop's sleep has a max(2, ...)
#     floor, so setting 1 buys nothing
#   · one wedged box paces the whole fleet — ping_once blocks until every
#     thread joins, up to PING_TIMEOUT_S + 5, so the configured interval is a
#     BEST case that degrades exactly when something is unhealthy
#
# The 97ms-normal against a 5000ms timeout is a 50x margin, and that is what
# makes PING_FAILS_TO_WEDGE=3 a wedge detector rather than a jitter detector.
PING_INTERVAL_S = int(os.environ.get("CREW_FLOOR_PING_INTERVAL", "10"))
# Tight on purpose. A healthy round-trip is ~100ms; anything past a couple of
# seconds is already the pathology, and a long timeout here would just
# reintroduce the interval it was meant to beat.
PING_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_PING_TIMEOUT", "5"))
# One dropped ping is a scheduler hiccup, not a wedge. Three consecutive
# misses (~30s) is a box that has stopped answering.
PING_FAILS_TO_WEDGE = int(os.environ.get("CREW_FLOOR_PING_FAILS", "3"))
# A round that cannot run (a failed `box list`) leaves the previous heartbeats
# published rather than wiping their miss counters. That is right, but a
# SUSTAINED host-level failure then leaves the last round's `ok: True` on
# screen forever — trading "counters reset" for "stale green", and stale green
# on a liveness widget is the failure this tier was added to prevent. Past this
# age a heartbeat is reported as unknown rather than believed. Generous enough
# that ordinary jitter never trips it: several rounds AND the wedge threshold.
PING_STALE_AFTER_S = int(os.environ.get(
    "CREW_FLOOR_PING_STALE_AFTER", str(PING_INTERVAL_S * (PING_FAILS_TO_WEDGE + 2))))

# A duty run holding its lock this long is reported as stuck. Two tick
# boundaries, the same number the SILENT rule uses — past it, tick.sh is
# logging "previous run still holds the lock" every 5 minutes and the box looks
# perfectly healthy while doing nothing. run_session's own ceiling is 1800s, so
# this surfaces the wedge ~20 minutes before the timeout resolves it.
STUCK_AFTER_S = int(os.environ.get("CREW_FLOOR_STUCK_AFTER", str(SILENT_AFTER_S)))


LOG_LOCK = threading.Lock()


def log(msg):
    line = "%s floor: %s\n" % (
        datetime.now(timezone.utc).strftime("%H:%M:%S"), msg)
    # Fleet-wide actions finish on worker threads. Keep the complete human
    # evidence line together even when several boxes return simultaneously.
    with LOG_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()


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


def box_states(strict=False):
    """name -> incus state, in ONE call rather than one per box.

    With strict=True returns (states, ok). An empty dict is ambiguous — it
    means "this host has no boxes" AND "the question could not be asked" — and
    callers that act on absence need to tell those apart. The ping tier does:
    treating a failed `box list` as "no boxes are running" switches the fast
    tier off and wipes its miss counters, in the fail-open direction, on the
    one signal whose job is noticing that something stopped answering.
    """
    rc, out, _ = run(["box", "list", "--json"], 20)
    states = {}
    ok = rc == 0
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
            ok = False
    return (states, ok) if strict else states


# --------------------------------------------------------------------------
# duty.log -> telemetry  (#38)
# --------------------------------------------------------------------------

TS = r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"
RE_START = re.compile(TS + r" SESSION START kind=(\S+) key=(\S+)")
RE_END = re.compile(TS + r" SESSION END kind=(\S+) key=(\S+) rc=(\d+) dur=(\d+)s outcome=(\S+)"
                    r"(?: acted=(yes|no|unknown) reply_tail=(\S*))?")
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
            try:
                reply = base64.b64decode(m.group(8) or "", validate=True).decode("utf-8", "replace")
            except (ValueError, TypeError):
                reply = ""
            done.append({
                "ts": parse_ts(m.group(1)), "kind": m.group(2), "key": m.group(3),
                "rc": int(m.group(4)), "dur": int(m.group(5)), "out": m.group(6),
                "acted": m.group(7) or "unknown", "reply": reply,
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


# The ping already pays for a host-side process start (~47ms of the ~97ms);
# what runs INSIDE the guest is nearly free by comparison. So it reads two
# files on the way past, and STUCK detection moves from the 60s evidence tier
# to this one — a hung duty session is now seen ~6x sooner, for no extra cost.
#
# It emits the lock's AGE, never its raw contents. duty.sh writes an ABSOLUTE
# unix stamp (`date +%s`), and every consumer wants elapsed seconds — probe.sh
# has always converted. The first cut of this passenger shipped the stamp raw,
# so the overlay compared ~1.7e9 against STUCK_AFTER_S and a duty run that had
# started THAT SECOND rendered "STUCK — held the lock for 495881h". A false
# positive on every live tick, and the tests missed it twice over: stub-box
# answered with an already-computed age, and the real-shell test only asserted
# the field was non-empty. Both now assert it is an AGE.
#
# A non-numeric or future stamp emits nothing rather than a bogus number: a
# torn read (duty.sh writes this file at the top of every run) must never
# manufacture a wedge.
#
# `exit 0` is load-bearing and is this change's sharp edge. `.duty.lock.since`
# is ABSENT whenever no duty run is in flight, which is the normal state of a
# healthy idle box; `cat` on a missing file exits 1, so without the explicit
# exit every healthy box would fail three pings and render UNREACHABLE. The
# `[ -r ]` guard makes that impossible independently, and a test asserts a box
# with no lock file still pings ok.
#
# rc semantics are unchanged, and that is the point: a non-zero rc still means
# "could not run anything in the guest", which is the entire liveness claim.
# The parsed output is a PASSENGER — malformed, empty or absent output never
# turns into a failed ping, because the one tier that must never lie now has a
# parser attached to it. Everything it reads degrades to None.
PING_SH = (
    'printf "u %s\n" "$(cut -d. -f1 /proc/uptime 2>/dev/null)"; '
    's=""; d="${DUTY_DIR:-$HOME/duty}"; '
    'if [ -r "$d/.duty.lock.since" ]; then '
    'v="$(cat "$d/.duty.lock.since" 2>/dev/null)"; '
    'case "$v" in \'\'|*[!0-9]*) : ;; '
    '*) a=$(( $(date +%s) - v )); [ "$a" -ge 0 ] && s="$a" ;; '
    'esac; fi; '
    'printf "l %s\n" "$s"; '
    'exit 0'
)


def parse_ping(out):
    """The passenger facts, or None each. NEVER raises and never signals."""
    facts = {"uptime": None, "lockheld": None}
    for line in (out or "").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        key, val = parts
        if key not in ("u", "l"):
            continue
        try:
            n = int(val.strip())
        except (TypeError, ValueError):
            continue
        if key == "u":
            facts["uptime"] = n
        elif n >= 0:
            facts["lockheld"] = n
    return facts


def ping_box(name):
    """Is this box answering? Returns (ok, milliseconds, error, facts).

    The cheapest `box exec` that still proves a fork: no stdin, no script piped
    in, one tiny shell in the guest. Never raises — an unreachable box is a
    datum, like everywhere else in this file.
    """
    t0 = time.time()
    rc, out, err = run(["box", "exec", name, "--", "sh", "-c", PING_SH],
                       PING_TIMEOUT_S)
    ms = int((time.time() - t0) * 1000)
    if rc == 0:
        return True, ms, "", parse_ping(out)
    if rc == 124:
        return False, ms, "no answer in %ss" % PING_TIMEOUT_S, {}
    return False, ms, (err.strip().splitlines() or ["box exec rc %d" % rc])[-1], {}


def probe_box(unit, agent_conf):
    """One box's evidence, via `box exec`. Never raises — failure is a datum."""
    with open(PROBE) as f:
        script = f.read()
    rc, out, err = run(["box", "exec", unit["box"], "--", "bash", "-lc", script],
                       PROBE_TIMEOUT_S, stdin_data=agent_conf)
    if rc != 0:
        return None, (err.strip().splitlines() or ["box exec failed (rc %d)" % rc])[-1]
    return out, None


def unit_defaults():
    """Every key a unit record carries, at its "nothing known yet" value.

    ONE definition, because there are two producers — build_unit below and the
    poller's probe-error path — and they used to spell the same dict out by
    hand. They drifted the moment a key was added: the error path shipped
    without `disarmed`, so a single box that threw during its probe made
    `wake-silent` raise KeyError for the WHOLE fleet, and the poll log with it.
    (It was also already missing `agent_actual`.)

    A hand-copied second skeleton is the same defect this PR is about — two
    readers holding private copies of one fact — one layer down. Adding the
    missing key would have fixed today's instance and left the next one.
    """
    return {
        "state": "offline", "engine": "", "gh": "unknown", "vendor": "unknown",
        "queue": [], "sessions": [], "cur": None, "spark": [0.0] * 22,
        "up": {"h": 0, "m": 0}, "repo": "", "repos": [], "logs": [],
        "longest": 0, "avg": 0, "success": 0, "today": 0,
        "paused": False, "disarmed": False,
        "cron": {"ok": False, "last": None, "age": None},
        "lock": {"held": None, "stuck": False},
        "authfail": [], "ping": None,
        "note": "", "agent_actual": "",
    }


def build_unit(unit, state, agent_conf, now):
    """Roster entry + live probe -> the record the page renders."""
    u = dict(unit)
    u.update(unit_defaults())

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
    # DISARMED — no live `tick.sh` line in the crontab at all, which is a
    # different fact from "armed and not ticking" and needs a different action.
    # probe.sh has always emitted ::cron; nothing consumed it except a note on
    # the one path where a box has no log history whatsoever, so a box with
    # ticks behind it and cron since removed fell straight through to SILENT.
    #
    # `paused` is the same fact with a cause attached — the console's own Pause
    # comments the line out — so a paused box is BOTH, and `paused` wins the
    # note because "the operator did this, here is how to undo it" is the more
    # useful sentence. Kept as separate wire values rather than one tri-state:
    # a caller that means "can this box tick at all" must not have to know that
    # `paused` implies `disarmed`.
    u["disarmed"] = meta.get("cron", "0") == "0"
    # Both services, same shape. gh and the agent CLI fail independently and
    # are fixed by different commands, so they are never merged into one
    # "auth is bad" flag — the operator needs to know WHICH login to redo.
    # `nofail` means the box found no rejection; whether that amounts to
    # `flowing` depends on the engine having actually RUN recently, and that
    # threshold is SILENT_AFTER_S — the same one the SILENT rule uses, derived
    # once from TICK_S. The box deliberately ships ::tickage rather than a
    # verdict so this number exists in exactly one place.
    try:
        tick_age = int(meta.get("tickage") or -1)
    except (TypeError, ValueError):
        tick_age = -1
    fresh = 0 <= tick_age < SILENT_AFTER_S
    # WAITING — no tick has ever been observed, so there is no age to compare
    # against any threshold. `stale` is the wrong word here and it is wrong in
    # a costly direction: it means "we used to hear from this box and no longer
    # do", which is why the page renders it amber `~`. A box hired sixty seconds
    # ago has not stopped ticking; nobody has heard from it AT ALL. Telling an
    # operator their minute-old hire is stale, on a row whose every other column
    # says it is fine, is the same conflation #221 and #224 fix at the two
    # neighbouring call sites (#265).
    #
    # Not `unknown`: that value is reserved for a box with no engine, and
    # rehearsal-app.sh asserts no HIRED box ever reports it, on the grounds that
    # it leaves the operator nothing to act on. A never-ticked box is actionable
    # — the action is to wait one tick boundary — so it gets its own word.
    never_ticked = tick_age < 0
    for svc in ("gh", "vendor"):
        fail = meta.get("authfail-%s" % svc, "")
        if fail:
            u["authfail"].append("%s: %s" % (svc, fail))
        if u[svc] == "nofail":
            if never_ticked:
                u[svc] = "waiting"
            else:
                u[svc] = "flowing" if fresh else "stale"

    # A duty run is in flight and has held the lock this long. Absent means no
    # run is in flight — the common case between ticks, and not a fault.
    try:
        held = int(meta["lockheld"])
    except (KeyError, ValueError, TypeError):
        held = None
    if held is not None and held >= 0:
        u["lock"] = {"held": held, "stuck": held > STUCK_AFTER_S}
    u["repos"] = [r for r in meta.get("repos", "").split() if r]
    u["logs"] = [f for f in meta.get("sessionlogs", "").split() if f]
    try:
        up = int(meta.get("uptime") or 0)
        u["up"] = {"h": up // 3600, "m": (up % 3600) // 60}
    except ValueError:
        pass

    if not u["engine"]:
        u["note"] = "not hired — crew hire %s" % unit["box"]

    # The roster DECLARES an agent; the box knows what it actually is. Those are
    # two different facts and were never compared, so a roster that named the
    # wrong agent made this page probe with the wrong vendor profile and report
    # the box auth-unhealthy — while every cross-reader assertion stayed green,
    # because `crew status` reads the same wrong column. Consistent, wrong data
    # is worse than an obvious error, and it is what let a generated drill
    # roster pin every box to "claude" without anything noticing.
    #
    # Ranked below "not hired" (no engine means no instance.conf to disagree
    # with) and above cron/paused/SILENT: a wrong profile invalidates the vendor
    # reading itself, so it is the thing to say first.
    u["agent_actual"] = meta.get("agent", "")
    if u["agent_actual"] and u["agent_actual"] != unit.get("agent"):
        u["note"] = u["note"] or (
            "roster says %s, box is installed as %s — the vendor probe is running "
            "the wrong profile" % (unit.get("agent"), u["agent_actual"]))

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
    u["sessions"] = [{k: s[k] for k in ("ago", "kind", "key", "rc", "dur", "out", "acted", "reply")}
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
    elif u["disarmed"]:
        # Disarmed OUTSIDE the console: `crew hire` before it arms, a box
        # disarmed by hand, and every drill box by design (drill/rehearsal.sh
        # disarms before any tick and aborts the run if it cannot). Ranked above
        # SILENT because it is the more specific claim and the actionable one:
        # SILENT says "this box should be ticking and is not", which is a real
        # alarm, and it must not be spent on a box nobody armed. Resume cannot
        # fix this — there is no commented line to uncomment — so the note names
        # the command that can.
        u["state"] = "offline"
        u["note"] = u["note"] or "disarmed — no cron line; crew hire %s arms it" % unit["box"]
    elif last_ts and not u["cron"]["ok"]:
        u["state"] = "offline"
        u["note"] = u["note"] or "SILENT — no tick for %s" % fmt_dur(u["cron"]["age"])
    elif u["authfail"]:
        # Ticking, answering, and unable to do any work — the engine tried and
        # was rejected. Not "offline": the box is fine and every control still
        # works, which is exactly why this needs saying out loud rather than
        # being inferred from a queue that quietly stopped moving.
        u["state"] = "idle"
        u["note"] = "AUTH BLOCKED — %s" % "; ".join(u["authfail"])
    elif u["lock"]["stuck"]:
        # Still "working": the box is alive, cron is ticking, and a session
        # genuinely is running — every one of those is true and none of them is
        # the point. The note OVERRIDES rather than defers, because a run stuck
        # past two tick boundaries is the most important thing about this box,
        # and the notes it would defer to describe a healthy one.
        u["state"] = "working"
        u["note"] = "STUCK — duty run has held the lock for %s" % fmt_dur(u["lock"]["held"])
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
        # The ping tier keeps its OWN lock. Sharing _poll_lock would queue
        # every ping behind a 45s evidence probe, so the fast signal would run
        # at the slow tier's cadence — precisely the coupling it exists to
        # break. The two tiers touch no shared mutable state but self.pings.
        self._ping_lock = threading.Lock()
        self.pings = {}                      # box -> {ok, ms, ts, fails, err}
        self._last_fails = {}                # previous round, for transition logging

    def agent_conf(self, agent):
        if agent not in self._confs:
            try:
                with open(agent_conf_path(agent)) as f:
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
                u.update(unit_defaults())
                u["note"] = "probe error: %s" % e
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
            "ping_interval": PING_INTERVAL_S,
            "units": [u for u in units if u],
            "polling": True,
        }
        with self.lock:
            self.snapshot = snap
        return snap

    # --- the ping tier -----------------------------------------------------

    def ping_once(self):
        """One `box exec -- true` per running roster box, concurrently.

        Boxes that are stopped or absent are skipped, not pinged: `box exec`
        into a stopped box fails for a reason the operator already knows, and
        counting that as a wedge would make every deliberately-down box red.

        Returns None when the round could not be run at all.
        """
        states, states_ok = box_states(strict=True)
        if not states_ok:
            # `box list` failed, so every state reads None, every box looks
            # absent, and the roster empties. Publishing that would issue zero
            # pings AND reset every consecutive-miss counter — a transient
            # hiccup on the host silently switching off the tier that detects
            # boxes not answering, and clearing the evidence it had gathered.
            # Skip the round instead: the previous pings stay published and
            # keep ageing, which is visible, rather than vanishing, which is
            # not.
            return None
        roster = [u for u in read_roster()
                  if states.get(u["box"]) not in (None, "stopped")]
        now = time.time()
        results = {}
        # Read the previous round ONCE, under the lock, instead of each thread
        # reaching into self.pings while another round may be replacing it.
        with self._ping_lock:
            prev_round = dict(self.pings)

        def work(name):
            ok, ms, err, facts = ping_box(name)
            prev = prev_round.get(name) or {}
            results[name] = {
                "ok": ok, "ms": ms, "ts": now, "err": err,
                "lockheld": facts.get("lockheld"), "uptime": facts.get("uptime"),
                # Consecutive misses, not a rate: one dropped ping is noise,
                # a run of them is a wedge. Reset on any success.
                "fails": 0 if ok else int(prev.get("fails", 0)) + 1,
            }

        threads = [threading.Thread(target=work, args=(u["box"],), daemon=True)
                   for u in roster]
        for t in threads:
            t.start()
        for t in threads:
            t.join(PING_TIMEOUT_S + 5)

        with self._ping_lock:
            # A COPY. join() with a timeout returns whether or not the thread
            # finished and these are daemons, so a ping still blocked inside
            # communicate() (which run()'s docstring warns can outlive its
            # deadline against a wedged box) will eventually execute
            # `results[name] = ...`. Publishing `results` itself would let that
            # late writer mutate the live snapshot outside this lock and set
            # fails back to 0 from a stale `prev` — masking the very wedge that
            # made it late. It lands on an orphan instead.
            published = dict(results)
            # Replace wholesale rather than update(): a box that left the
            # roster (or went down) must lose its stale ping, not keep the
            # last one it ever answered forever.
            self.pings = published
        return published

    def ping_loop(self):
        while True:
            t0 = time.time()
            try:
                res = self.ping_once()
                if res is None:
                    log("ping: skipped a round — `box list` failed; "
                        "previous heartbeats left in place")
                    time.sleep(max(2, PING_INTERVAL_S - (time.time() - t0)))
                    continue
                # Only log transitions. At a 10s cadence a line per round is
                # 8,640 lines a day of "everything is fine", which is how an
                # operator learns to stop reading the log.
                for name, p in sorted(res.items()):
                    if not p["ok"] and p["fails"] == PING_FAILS_TO_WEDGE:
                        log("ping: %s stopped answering (%s)" % (name, p["err"]))
                    elif p["ok"] and (self._last_fails.get(name, 0)
                                      >= PING_FAILS_TO_WEDGE):
                        log("ping: %s is answering again (%dms)" % (name, p["ms"]))
                self._last_fails = {n: p["fails"] for n, p in res.items()}
            except Exception as e:                          # noqa: BLE001
                log("ping round failed: %s" % e)
            time.sleep(max(2, PING_INTERVAL_S - (time.time() - t0)))

    def get(self):
        """The evidence snapshot, with the fresher ping tier laid over it.

        The overlay happens at read time, not at poll time: pings land every
        ~10s and the evidence snapshot is rebuilt every ~60s, so merging at
        poll time would serve ping data up to a minute stale — which is the
        whole thing this tier exists to avoid.
        """
        with self.lock:
            snap = self.snapshot
        with self._ping_lock:
            pings = self.pings
        if not pings:
            return snap

        now = time.time()
        units = []
        for u in snap.get("units", []):
            p = pings.get(u["box"])
            if p is None:
                units.append(u)
                continue
            u = dict(u)
            age = int(now - p["ts"])
            # `stale` is a THIRD answer, never folded into ok/not-ok: the tier
            # has not run recently enough for either to be a claim about now.
            stale = age > PING_STALE_AFTER_S
            # SERVED, not merely used server-side. These drove the STUCK
            # escalation while never reaching the wire, so the drill this PR
            # adds read ping.uptime / ping.lockheld and got None on every real
            # host — an assertion that could only fail, for a reason nobody
            # would trace to a missing dict key. Publishing them also makes the
            # fast tier's own reading visible to an operator.
            u["ping"] = {"ok": p["ok"], "ms": p["ms"], "age": age,
                         "fails": p["fails"], "stale": stale,
                         "lockheld": p.get("lockheld"), "uptime": p.get("uptime")}
            # The passenger: a lock age read on the ping's own 10s clock,
            # rather than waiting up to 60s for the next evidence poll. This
            # is the wedge the SILENT rule cannot see — cron ticking, duty.log
            # fresh, nothing moving — and it was the slowest thing on the
            # console to notice.
            #
            # Only ever ESCALATES. A ping that read nothing (no lock file, an
            # unparseable line, a guest where $HOME is not what we assumed)
            # leaves whatever the evidence poll concluded untouched: the
            # passenger may report a wedge sooner, never clear one, and never
            # contradict the tier that reads the file properly.
            held = p.get("lockheld")
            if not stale and p["ok"] and isinstance(held, int) and held > STUCK_AFTER_S:
                if not u["lock"]["stuck"]:
                    u["lock"] = {"held": held, "stuck": True}
                    u["state"] = "working"
                    stuck_note = ("STUCK — duty run has held the lock for %s"
                                  % fmt_dur(held))
                    # Composed when a credential is already broken: both are
                    # true, they need different fixes, and replacing the note
                    # would hide which login to redo.
                    u["note"] = ("%s · %s" % (stuck_note, u["note"])
                                 if u["authfail"] and u["note"] else stuck_note)
            if stale:
                # Say so rather than rendering an old green as current. Not
                # `offline`: an unmeasurable box is not a dead one, and
                # claiming otherwise is the same overreach in the other
                # direction.
                u["note"] = u["note"] or (
                    "heartbeat has not run for %s — the collector cannot reach "
                    "`box list`" % fmt_dur(age))
                units.append(u)
                continue
            # A box that has missed PING_FAILS_TO_WEDGE pings in a row is
            # unreachable NOW, whatever the last evidence probe concluded up
            # to a minute ago. This overrides "working" on purpose: a session
            # that was running when we last looked cannot be progressing
            # inside a guest that no longer answers an exec.
            if not p["ok"] and p["fails"] >= PING_FAILS_TO_WEDGE:
                u["state"] = "offline"
                # PREPENDED to whatever the evidence poll concluded, never
                # substituted for it. A wedged box's probe note is
                # "unreachable: timed out after 45s", which says WHY far better
                # than a ping count can — and replacing it made the wedged
                # box's reason depend on whether the ping tier had accumulated
                # enough misses yet, so the same fleet described itself two
                # different ways depending on timing.
                ping_note = "UNREACHABLE — %d pings unanswered (%s)" % (
                    p["fails"], p["err"])
                u["note"] = ("%s · %s" % (ping_note, u["note"])
                             if u["note"] else ping_note)
            units.append(u)
        return dict(snap, units=units)

    def loop(self):
        while True:
            t0 = time.time()
            try:
                snap = self.poll_once()
                # SILENT is an alarm, so a box somebody deliberately stopped
                # does not spend one — the same rule the note ordering applies,
                # in the one number an operator reads without opening the page.
                # Counted separately rather than dropped: "3 units, 0 silent"
                # on a fleet that is entirely disarmed would be true and
                # useless.
                off = [u for u in snap["units"] if u["state"] == "offline"]
                stopped = sum(1 for u in off if u["paused"] or u["disarmed"])
                log("polled %d units (%d silent, %d paused/disarmed) in %.1fs"
                    % (len(snap["units"]), len(off) - stopped, stopped,
                       time.time() - t0))
            except Exception as e:                          # noqa: BLE001
                log("poll failed: %s" % e)
            time.sleep(max(5, self.interval - (time.time() - t0)))


# --------------------------------------------------------------------------
# operator control  (#39)
# --------------------------------------------------------------------------

# Fired into the box with `box exec`; the box initiates nothing.
#
# Each script states its own verdict on the last line and exits deliberately.
# It used to end on a bare `grep -c`, and `grep -c` exits 1 when it counts
# zero — so the count WAS the exit status, and a box with no armed `tick.sh`
# line reported the same rc 1 as a box that could not be reached. `in_box`
# read that as ok=False, `do_command` answered 500, and the console rendered
# it "command refused" (#188). Nothing was refusing: a count of zero was
# being reported as a failure, which is #176's shape — "nothing to do" and
# "it went wrong" collapsed into one status.
#
# Three outcomes, three answers: `paused N` (it took effect), `nothing to
# pause: ...` (rc 0, there was nothing armed), and a non-zero exit whose
# stderr says why. The counts travel as data on stdout; only a real failure
# is allowed to redden the row. Each write is checked on its own exit status
# rather than inferred from a later read, so a `crontab -` that refuses is
# named as the failure it is.
#
# N is the number of lines THIS call moved, not the number of lines now in
# the target state: a box carrying a `#CREW-FLOOR-PAUSED` line from an
# earlier pause, plus one armed line, pauses one line and says `paused 1`.
# Reporting the post-state total would say `paused 2` — an overcount on a
# control plane whose whole subject is saying what it actually did.
#
# That is also why the crontab is read ONCE, into `cron`, and the write is
# fed from that snapshot rather than from a second `crontab -l`: the counts
# and the text being rewritten are then the same crontab, so the delta check
# below means what it says. It costs one read rather than adding one.
PAUSE_SH = r"""
cron="$(crontab -l 2>/dev/null || true)"
armed="$(printf '%s\n' "$cron" | grep -cE '^[^#].*tick\.sh' || true)"
[ "$armed" -gt 0 ] || { echo "nothing to pause: no armed tick.sh line"; exit 0; }
was="$(printf '%s\n' "$cron" | grep -c '^#CREW-FLOOR-PAUSED' || true)"
printf '%s\n' "$cron" | sed -E 's|^([^#].*tick\.sh.*)$|#CREW-FLOOR-PAUSED \1|' | crontab - \
  || { echo "pause: crontab write failed" >&2; exit 1; }
now="$(crontab -l 2>/dev/null | grep -c '^#CREW-FLOOR-PAUSED' || true)"
[ "$(( now - was ))" -eq "$armed" ] \
  || { echo "pause: crontab write reported success, $(( now - was )) of $armed lines are commented" >&2; exit 1; }
echo "paused $armed"
"""

RESUME_SH = r"""
cron="$(crontab -l 2>/dev/null || true)"
paused="$(printf '%s\n' "$cron" | grep -c '^#CREW-FLOOR-PAUSED' || true)"
[ "$paused" -gt 0 ] || { echo "nothing to resume: no paused tick.sh line"; exit 0; }
was="$(printf '%s\n' "$cron" | grep -cE '^[^#].*tick\.sh' || true)"
printf '%s\n' "$cron" | sed -E 's|^#CREW-FLOOR-PAUSED ||' | crontab - \
  || { echo "resume: crontab write failed" >&2; exit 1; }
now="$(crontab -l 2>/dev/null | grep -cE '^[^#].*tick\.sh' || true)"
[ "$(( now - was ))" -eq "$paused" ] \
  || { echo "resume: crontab write reported success, $(( now - was )) of $paused lines are live" >&2; exit 1; }
echo "resumed $paused"
"""

# The operator's message becomes a real session of the box's own vendor CLI,
# detached so the HTTP request does not hold a model run open, and logged where
# every other session logs so it shows up in the console's history.
MESSAGE_SH = r"""
set -u
# Every path here is per-invocation. They used to be fixed names, and the
# server is threaded: two rapid messages to one box interleaved as
#   write prompt A -> launch A -> write prompt B -> A reads .floor-prompt
# and session A ran prompt B. An operator's instruction executed with someone
# else's text, on a real box. Same-second sessions also collided on the log
# name. __TOK__ is a uuid4 hex minted per request by the collector.
tok="__TOK__"
conf="/tmp/.crew-floor-agent.$tok.conf"
pf="${DUTY_DIR:-$HOME/duty}/.floor-prompt.$tok"
cat >"$conf"
# shellcheck disable=SC1090
source "$conf"
export PATH="${BOT_PATH_PREPEND:-$HOME/.local/bin}:$PATH"
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
mkdir -p "$DUTY_DIR/logs"
# Read ONCE, here, and hand the bytes to the detached shell as an argument.
# The re-read inside that shell was the race: it resolved the path long after
# this request had returned.
prompt="$(cat "$pf")"
rm -f "$pf"
[ -n "$prompt" ] || { echo "empty prompt"; rm -f "$conf"; exit 2; }
ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
slog="$DUTY_DIR/logs/$(date -u '+%Y%m%dT%H%M%SZ')-operator-floor-$tok.log"
# One O_APPEND write under 4K is atomic, so this cannot interleave with a
# tick's own line even though the operator session runs outside the duty flock.
printf '%s SESSION START kind=operator key=floor timeout=1800s log=%s\n' "$ts" "$slog" >>"$DUTY_DIR/duty.log"
nohup setsid bash -c '
  DUTY_DIR="'"$DUTY_DIR"'"; slog="'"$slog"'"; conf="'"$conf"'"
  start=$SECONDS; rc=0
  source "$conf"; rm -f "$conf"
  export PATH="${BOT_PATH_PREPEND:-$HOME/.local/bin}:$PATH"
  cd "$HOME"
  timeout -k 60 1800 "${BOT_CLI_CMD[@]}" "$1" </dev/null >"$slog" 2>&1 || rc=$?
  dur=$((SECONDS - start)); v=ok; acted=unknown
  [ "$rc" -eq 124 ] && v=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && v=FAILED
  if declare -F bot_session_acted >/dev/null 2>&1; then
    bot_session_acted "$slog" && arc=0 || arc=$?
    case "$arc" in 0) acted=yes;; 1) acted=no;; esac
  fi
  reply_tail="$(awk '\''NF { line=$0 } END { printf "%s", substr(line, 1, 200) }'\'' "$slog" 2>/dev/null | base64 | tr -d '\''\n'\'')"
  printf "%s SESSION END kind=operator key=floor rc=%s dur=%ss outcome=%s acted=%s reply_tail=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$dur" "$v" "$acted" "$reply_tail" >>"$DUTY_DIR/duty.log"
' _ "$prompt" </dev/null >/dev/null 2>&1 &
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

    def concurrently(tasks):
        """Run per-box calls together and return results in submission order."""
        if not tasks:
            return []
        with ThreadPoolExecutor(max_workers=min(len(tasks), ACTION_WORKERS)) as pool:
            futures = [pool.submit(fn, *args) for fn, args in tasks]
            return [future.result() for future in futures]

    def done(result):
        """Make an already-known per-box result fit a concurrent task list."""
        return result

    results = []

    if action == "message":
        prompt = str(body.get("prompt", "")).strip()
        if not prompt:
            return 400, {"ok": False, "error": "empty prompt"}
        if len(prompt) > 8000:
            return 400, {"ok": False, "error": "prompt too long"}
        try:
            prompt = floor_message_prompt(prompt)
        except RuntimeError as exc:
            return 500, {"ok": False, "error": str(exc)}
        # Two hops so the prompt is never interpolated into a shell string:
        # it travels as stdin bytes, and the session reads it from a file.
        # The filename carries a per-request token: with one fixed name, two
        # rapid messages to the same box raced and a session could run the
        # OTHER request's prompt.
        token = uuid.uuid4().hex
        w = one(box, ["box", "exec", box, "--", "bash", "-lc",
                      'mkdir -p "$HOME/duty" && cat > "$HOME/duty/.floor-prompt.%s"' % token],
                stdin_data=prompt)
        if not w["ok"]:
            results.append(w)
        else:
            results.append(in_box(box, MESSAGE_SH.replace("__TOK__", token),
                                  stdin_data=agent_conf_for(box)))

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
        tasks = []
        for name in roster:
            st = states.get(name)
            if st is None:
                # A roster line with no box yet is inventory drift, not a refusal:
                # `fleet.roster` is the TARGET fleet and deliberately names boxes
                # `crew up` has not created. `ok: None` keeps the box named in the
                # per-box detail while excluding it from the pass/fail verdict, so
                # the whole action does not read failed mid-migration (#77).
                tasks.append((done, ({"box": name, "ok": None, "out": "not created"},)))
                continue
            if (verb == "start") == (st == "stopped"):
                tasks.append((one, (name, ["box", verb, name])))
            else:
                tasks.append((done, ({"box": name, "ok": True,
                                      "out": "already %s" % st},)))
        results = concurrently(tasks)
    elif action == "wake-silent":
        # A silent box is one cron is not ticking for. Waking it means resuming
        # the crontab and, if it is stopped, starting it — not a model session.
        states = box_states()
        tasks = []
        for u in fleet.get()["units"]:
            if u["state"] != "offline":
                continue
            # A box that is disarmed WITHOUT being paused has no commented line
            # for RESUME_SH to restore, so waking it is not a thing this action
            # can do — arming is `crew hire`, on the host. It used to be sent
            # RESUME_SH anyway and reported as a failed row, which made
            # wake-silent read as broken on any fleet holding an unarmed box.
            #
            # The `not paused` half is load-bearing: pausing comments the line
            # out, so a paused box reports cron=0 and is disarmed too — and it
            # is exactly the box this action exists to wake.
            if u["disarmed"] and not u["paused"]:
                continue
            name = u["box"]
            if states.get(name) == "stopped":
                tasks.append((one, (name, ["box", "start", name])))
            elif states.get(name) is not None:
                tasks.append((in_box, (name, RESUME_SH)))
        results = concurrently(tasks)
    else:
        return 400, {"ok": False, "error": "unknown action %r" % action}

    # An action with nothing to do is not a failure: `wake-silent` on a fleet
    # with no silent boxes had `results == []`, which read as ok=False and 500.
    # Only `message`-class actions, which must produce a result, stay strict.
    # An action that did everything it COULD is not a failure either: a row with
    # `ok is None` (a not-yet-created box) is inventory drift, not a refusal, so
    # it is excluded from the verdict — 500 is reserved for a box that was there
    # and refused. All rows still travel in `results`, absent ones included.
    ok = all(r["ok"] for r in results if r["ok"] is not None)
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
    if PING_INTERVAL_S > 0:
        threading.Thread(target=fleet.ping_loop, daemon=True).start()

    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    log("serving fleet-floor on http://%s:%d/ (evidence every %ds, ping every %ds)"
        % (bind, port, interval, PING_INTERVAL_S))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        httpd.shutdown()


def main():
    # First, and before the auth and index preconditions below: an
    # unconfigured host must get the config answer, not a missing-password or
    # missing-build one — the same order cmd_floor uses.
    require_operator_config()
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
