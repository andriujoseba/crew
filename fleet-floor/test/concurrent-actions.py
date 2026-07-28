#!/usr/bin/env python3
"""Regression for #44: one slow box must not serialize a fleet-wide action."""

import importlib.util
import os
import threading
import time


HERE = os.path.dirname(os.path.abspath(__file__))
FLOOR_PATH = os.path.join(os.path.dirname(HERE), "server", "floor.py")
SPEC = importlib.util.spec_from_file_location("crew_floor", FLOOR_PATH)
floor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(floor)
REAL_LOG = floor.log
floor.log = lambda _message: None

BOXES = ["box-a", "box-b", "box-c"]


class Fleet:
    def __init__(self):
        self.refreshes = 0

    def get(self):
        return {"units": [{"box": name, "state": "offline"} for name in BOXES]}

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
    assert [result["box"] for result in payload["results"] if not result["ok"]] == (
        list(failures)
    ), payload
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
real_stdout = floor.sys.stdout
floor.sys.stdout = stream
floor.log = REAL_LOG
threads = [
    threading.Thread(target=floor.log, args=("box-%02d complete" % n,))
    for n in range(24)
]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
floor.sys.stdout = real_stdout
assert stream.peak == 1, ("overlapping log writes", stream.peak)
assert len(stream.writes) == len(threads), ("torn log writes", stream.writes)
assert all(line.endswith(" complete\n") for line in stream.writes), stream.writes

print("concurrent fleet actions: ok")
