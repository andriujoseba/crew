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


def exercise(action, state):
    active = 0
    peak = 0
    lock = threading.Lock()

    floor.read_roster = lambda: [
        {"box": name, "agent": "claude", "role": "builder"} for name in BOXES
    ]
    floor.box_states = lambda: {name: state for name in BOXES}

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
        return 0, "ok", ""

    floor.run = slow_run
    fleet = Fleet()
    status, payload = floor.do_command(fleet, {"action": action})

    assert status == 200, (action, status, payload)
    assert peak == len(BOXES), (action, "peak concurrency", peak)
    assert [result["box"] for result in payload["results"]] == BOXES, payload
    assert fleet.refreshes == 1, (action, "refreshes", fleet.refreshes)


exercise("start-all", "stopped")
exercise("stop-all", "running")
exercise("wake-silent", "running")
print("concurrent fleet actions: ok")
