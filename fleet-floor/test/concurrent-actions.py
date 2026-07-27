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

    expected_status = 500 if failures or None in states.values() else 200
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
# while box-a is absent and box-b is already running.
floor.read_roster = lambda: [
    {"box": name, "agent": "claude", "room": "builder"} for name in BOXES
]
floor.box_states = lambda: {"box-a": None, "box-b": "running", "box-c": "stopped"}
floor.run = lambda _argv, _timeout, _stdin_data=None: (0, "started", "")
mixed_fleet = Fleet()
status, payload = floor.do_command(mixed_fleet, {"action": "start-all"})
assert status == 500, (status, payload)
assert [result["box"] for result in payload["results"]] == BOXES, payload
assert [result["ok"] for result in payload["results"]] == [False, True, True], payload
assert [result["out"] for result in payload["results"]] == [
    "not created", "already running", "started"
], payload
print("concurrent fleet actions: ok")
