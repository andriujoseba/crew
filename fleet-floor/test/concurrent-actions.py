#!/usr/bin/env python3
"""Regression for #44: one slow box must not serialize a fleet-wide action."""

import os
import sys
import threading
import time


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server"))
# The module UNDER TEST, not the package: do_command reads `run`, `read_roster`
# and `box_states` as its own globals, so the stubs below have to land there.
# Rebinding them on the package would leave the real ones in place and this
# regression would drive a real `box` (#508).
from floor import actions as floor            # noqa: E402  (sys.path first)
from floor import ping                        # noqa: E402  (log lives here)
REAL_LOG = ping.log
floor.log = lambda _message: None

BOXES = ["box-a", "box-b", "box-c"]


class Fleet:
    def __init__(self):
        self.refreshes = 0

    def get(self):
        # Offline and ARMED — the silent box wake-silent exists to act on.
        # Both flags are spelled out because do_command reads them to decide
        # whether a box can be woken at all: a disarmed box has no commented
        # crontab line to restore, and is skipped (#189).
        return {"units": [{"box": name, "state": "offline",
                           "paused": False, "disarmed": False}
                          for name in BOXES]}

    def request_refresh(self):
        self.refreshes += 1


def exercise(action, states, failures=()):
    active = 0
    peak = 0
    lock = threading.Lock()

    floor.read_roster = lambda: [
        {"box": name, "agent": "claude", "room": "builder"} for name in BOXES
    ]
    if isinstance(states, str):
        states = {name: states for name in BOXES}
    floor.box_states = lambda: states

    def slow_run(argv, _timeout, _stdin_data=None):
        nonlocal active, peak
        name = argv[2]
        with lock:
            active += 1
            peak = max(peak, active)
        # Finish in reverse roster order. The API must still report roster order.
        time.sleep({"box-a": 0.15, "box-b": 0.10, "box-c": 0.05}[name])
        with lock:
            active -= 1
        if name in failures:
            return 1, "", "fixture failure"
        return 0, "ok", ""

    floor.run = slow_run
    fleet = Fleet()
    status, payload = floor.do_command(fleet, {"action": action})

    # A not-created box (state None) is inventory drift, excluded from the
    # verdict — only a box that was there and refused makes the action 500 (#77).
    expected_status = 500 if failures else 200
    assert status == expected_status, (action, status, payload)
    assert peak == len(BOXES), (action, "peak concurrency", peak)
    assert [result["box"] for result in payload["results"]] == BOXES, payload
    # `is False` (a refusal), not falsy — an absent box carries `ok:None` and
    # must not be counted a failure here, matching the strict client filter.
    assert [
        result["box"] for result in payload["results"] if result["ok"] is False
    ] == list(failures), payload
    assert fleet.refreshes == 1, (action, "refreshes", fleet.refreshes)


exercise("start-all", "stopped")
exercise("stop-all", "running", failures=("box-b",))
exercise("wake-silent", "running")


# Precomputed and real results share one ordered list. Only box-c needs work,
# while box-a is absent and box-b is already running. Nothing refused, so the
# absent box does not make the action fail: 200, box-a carries ok:None (#77).
floor.read_roster = lambda: [
    {"box": name, "agent": "claude", "room": "builder"} for name in BOXES
]
floor.box_states = lambda: {"box-a": None, "box-b": "running", "box-c": "stopped"}
floor.run = lambda _argv, _timeout, _stdin_data=None: (0, "started", "")
mixed_fleet = Fleet()
status, payload = floor.do_command(mixed_fleet, {"action": "start-all"})
assert status == 200, (status, payload)
assert [result["box"] for result in payload["results"]] == BOXES, payload
assert [result["ok"] for result in payload["results"]] == [None, True, True], payload
assert [result["out"] for result in payload["results"]] == [
    "not created", "already running", "started"
], payload


# An absent box must not MASK a real refusal: box-a is not created, box-b was
# there and refused, box-c started. The action is 500 (a box refused), box-a
# still travels as ok:None and box-b as the named failure (#77).
floor.read_roster = lambda: [
    {"box": name, "agent": "claude", "room": "builder"} for name in BOXES
]
floor.box_states = lambda: {"box-a": None, "box-b": "stopped", "box-c": "stopped"}
floor.run = lambda argv, _timeout, _stdin_data=None: (
    (1, "", "refused") if argv[2] == "box-b" else (0, "started", "")
)
drift_and_refusal = Fleet()
status, payload = floor.do_command(drift_and_refusal, {"action": "start-all"})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == BOXES, payload
assert [result["ok"] for result in payload["results"]] == [None, False, True], payload
assert [result["out"] for result in payload["results"]] == [
    "not created", "refused", "started"
], payload


# A growing roster must not create one host subprocess per member. Results
# remain in roster order even though only eight calls may run at once.
MANY_BOXES = ["box-%02d" % n for n in range(19)]
floor.read_roster = lambda: [
    {"box": name, "agent": "claude", "room": "builder"} for name in MANY_BOXES
]
floor.box_states = lambda: {name: "stopped" for name in MANY_BOXES}
many_active = 0
many_peak = 0
many_lock = threading.Lock()


def bounded_run(argv, _timeout, _stdin_data=None):
    global many_active, many_peak
    with many_lock:
        many_active += 1
        many_peak = max(many_peak, many_active)
    time.sleep(0.03)
    with many_lock:
        many_active -= 1
    return 0, argv[2], ""


floor.run = bounded_run
many_fleet = Fleet()
status, payload = floor.do_command(many_fleet, {"action": "start-all"})
assert status == 200, (status, payload)
assert many_peak == floor.ACTION_WORKERS == 8, ("action worker peak", many_peak)
assert [result["box"] for result in payload["results"]] == MANY_BOXES, payload

# --- #44's actual scenario: a wedged box must not cost the fleet N timeouts --
#
# #68 made the per-box work concurrent and the fixture above proves the
# concurrency — but every stub up to here DISCARDS the timeout it is handed,
# so nothing asserted the property #44 was filed about: a box that never
# answers is capped at ACTION_TIMEOUT_S, and its healthy siblings return on
# time regardless. On incus 6.0.4 the hang is the COMMON case, not the rare
# one — danmt's real-host probe measured rc=124 after the full 150s, refuting
# "a dead agent makes box exec fail fast".
#
# What is under test is that the FAN-OUT preserves the per-box cap, not that
# subprocess honours timeouts. So the stub simulates run()'s timeout contract
# — sleep to the deadline, then (124, "", "timed out after Ns") — and the real
# run() is not involved. Injecting a small ACTION_TIMEOUT_S keeps it fast:
# one() binds its default from the module global each time do_command runs, so
# setting it here is what the fan-out actually uses.
TIMEOUT_S = 0.3
REAL_ACTION_TIMEOUT_S = floor.ACTION_TIMEOUT_S
floor.ACTION_TIMEOUT_S = TIMEOUT_S

seen_timeouts = []
wedged_boxes = set()


def wedging_run(argv, timeout, _stdin_data=None):
    seen_timeouts.append(timeout)
    name = argv[2]
    if name in wedged_boxes:
        # Sleep the INJECTED deadline, never the one passed in. If the cap
        # regresses, `timeout` is the fleet's real 120s and sleeping it would
        # HANG this suite instead of failing it — and a hanging test is worse
        # than a failing one: it burns the job's whole timeout and reports
        # nothing useful. Measured while writing this, on the exact regression
        # below (one() defaulted to 999): sleeping the passed timeout hung past
        # two minutes; sleeping the injected one fails in 0.3s, on the `out`
        # text, before the seen_timeouts assertion is even reached.
        time.sleep(TIMEOUT_S)               # it never answers
        return 124, "", "timed out after %ss" % timeout
    return 0, "started", ""


def timed_action(boxes, wedged, states):
    """Run start-all over `boxes` with `wedged` hung, returning (elapsed, payload)."""
    global wedged_boxes
    wedged_boxes = set(wedged)
    del seen_timeouts[:]
    floor.read_roster = lambda: [
        {"box": name, "agent": "claude", "room": "builder"} for name in boxes
    ]
    floor.box_states = lambda: states
    floor.run = wedging_run
    started = time.monotonic()
    status, payload = floor.do_command(Fleet(), {"action": "start-all"})
    return time.monotonic() - started, status, payload


# The whole roster wedged — the #44 shape exactly. Serialized this costs
# len(BOXES) timeouts; concurrent it costs one. The roster is sized to
# ACTION_WORKERS so the bound also pins the POOL: a max_workers lowered below
# the roster puts a wedged box in a later batch and the action is back to
# N/pool timeouts, which is regression path 1 in #79 and leaves every other
# assertion in this file green.
ALL_WEDGED = ["wedge-%d" % n for n in range(floor.ACTION_WORKERS)]
elapsed, status, payload = timed_action(
    ALL_WEDGED, ALL_WEDGED, {name: "stopped" for name in ALL_WEDGED})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == ALL_WEDGED, payload
assert all(result["ok"] is False for result in payload["results"]), payload
assert all(
    result["out"] == "timed out after %ss" % TIMEOUT_S
    for result in payload["results"]
), payload
# Generously bounded: serialized would be 8 x 0.3 = 2.4s, so 3x one timeout
# discriminates by a factor of 2.6 while tolerating a slow, loaded runner.
assert elapsed < TIMEOUT_S * 3, ("wedged fleet paid more than one timeout", elapsed)

# One wedged box among healthy ones: the timeout is attributed to THAT box and
# the others still carry their real results.
MIXED = ["fast-a", "hung-b", "fast-c"]
elapsed, status, payload = timed_action(
    MIXED, ["hung-b"], {name: "stopped" for name in MIXED})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == MIXED, payload
assert [result["ok"] for result in payload["results"]] == [True, False, True], payload
assert [result["out"] for result in payload["results"]] == [
    "started", "timed out after %ss" % TIMEOUT_S, "started"
], payload
assert elapsed < TIMEOUT_S * 3, ("one wedged box serialized the fleet", elapsed)

# Every call got the fleet's cap. This is regression path 2 in #79: someone
# changes one()'s default, or a future caller passes a per-action timeout, and
# the cap silently stops applying to the fan-out — with every assertion above
# still green, because they only observe the CONTRACT the stub honours.
assert set(seen_timeouts) == {TIMEOUT_S}, ("uncapped call", seen_timeouts)

# The mixed done/one path WITH concurrency in play — precomputed results and
# real work in one ordered list, one of the real ones wedged. It was exercised
# once above with an instant stub, so the interleaving was covered for ordering
# and never with a box that does not answer.
DRIFT = ["absent-a", "running-b", "hung-c", "fast-d"]
elapsed, status, payload = timed_action(
    DRIFT, ["hung-c"],
    {"absent-a": None, "running-b": "running", "hung-c": "stopped", "fast-d": "stopped"})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == DRIFT, payload
assert [result["ok"] for result in payload["results"]] == [None, True, False, True], payload
assert [result["out"] for result in payload["results"]] == [
    "not created", "already running", "timed out after %ss" % TIMEOUT_S, "started"
], payload
assert elapsed < TIMEOUT_S * 3, ("precomputed results serialized behind a hang", elapsed)

floor.ACTION_TIMEOUT_S = REAL_ACTION_TIMEOUT_S

# log() is called by those workers. A deliberately slow stream makes
# overlapping writes deterministic: the old print(message, flush=True) path
# enters write concurrently and emits the newline as a second write.
class SlowStream:
    def __init__(self):
        self.active = 0
        self.peak = 0
        self.writes = []
        self.lock = threading.Lock()

    def write(self, text):
        with self.lock:
            self.active += 1
            self.peak = max(self.peak, self.active)
        time.sleep(0.003)
        self.writes.append(text)
        with self.lock:
            self.active -= 1

    def flush(self):
        return None


stream = SlowStream()
# ping's `sys`, because that is the module log() resolves the stream through.
real_stdout = ping.sys.stdout
ping.sys.stdout = stream
threads = [
    threading.Thread(target=REAL_LOG, args=("box-%02d complete" % n,))
    for n in range(24)
]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
ping.sys.stdout = real_stdout
assert stream.peak == 1, ("overlapping log writes", stream.peak)
assert len(stream.writes) == len(threads), ("torn log writes", stream.writes)
assert all(line.endswith(" complete\n") for line in stream.writes), stream.writes

print("concurrent fleet actions: ok")
