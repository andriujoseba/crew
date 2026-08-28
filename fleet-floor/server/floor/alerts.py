"""Out-of-band reachability and engine notices emitted by the floor process.

The channel is an operator-configured host command. One UTF-8 message is
written to its stdin for each reachability edge; an empty command is a silent
no-op. Keeping the transport as a command lets an operator choose the service
without putting service credentials or a third-party client in crew.
"""

import os
import shlex
import subprocess

from floor.ping import log, run


ALERT_TIMEOUT_S = 15


def alert_command_from_config(config_dir):
    """Read FLEET_FLOOR_ALERT_CHANNEL from the trusted fleet.conf.

    fleet.conf is already a shell configuration file, so use the same shell
    semantics as the CLI instead of implementing a second, subtly different
    parser in Python. Configuration stdout is suppressed; only the requested
    value crosses the boundary.
    """
    path = os.path.join(config_dir, "fleet.conf")
    script = (
        'source "$1" >/dev/null || exit; '
        'printf "%s" "${FLEET_FLOOR_ALERT_CHANNEL:-}"'
    )
    try:
        proc = subprocess.run(
            ["bash", "-c", script, "crew-floor-config", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as exc:
        return "", "cannot read alert channel: %s" % exc
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        return "", "cannot read alert channel from %s%s" % (
            path, ": %s" % detail if detail else "")
    return proc.stdout.decode("utf-8", "replace").strip(), ""


def _duration(seconds):
    seconds = max(0, int(seconds))
    if seconds >= 3600:
        return "%dh %02dm" % (seconds // 3600, (seconds % 3600) // 60)
    if seconds >= 60:
        return "%dm %02ds" % (seconds // 60, seconds % 60)
    return "%ds" % seconds


class ReachabilityAlerts:
    """Hold the edge-triggered unreachable state and deliver its two edges."""

    def __init__(self, command, threshold):
        self.threshold = threshold
        self.unreachable = {}                 # box -> first failed ping time
        self.last_ticks = {}                  # box -> last observed tick string
        self.command_error = ""
        self.sent_events = set()
        self.dropped_events = {}
        try:
            self.command = shlex.split(command) if command else []
        except ValueError as exc:
            self.command = []
            self.command_error = "invalid alert channel: %s" % exc
            log(self.command_error)

    def _send(self, message):
        if not self.command:
            return False
        rc, _, err = run(self.command, ALERT_TIMEOUT_S, message + "\n")
        if rc != 0:
            log("alert channel failed (rc=%d): %s" %
                (rc, err.strip() or "no error text"))
            return False
        return True

    def observe_floor_events(self, units):
        """Deliver each durable box event once during this floor process."""
        current_events = set()
        for unit in sorted(units, key=lambda u: u.get("box", "")):
            box = unit.get("box", "")
            role = unit.get("room", "unknown")
            dropped = unit.get("limit_dropped")
            previous = self.dropped_events.get(box, 0)
            if dropped is None:
                pass
            elif dropped > previous:
                message = ("crew floor: %s (%s) lost %d operating-limit event(s); "
                           "cumulative dropped=%d" %
                           (box or "unknown", role, dropped - previous, dropped))
                if not self.command or self._send(message):
                    self.dropped_events[box] = dropped
            elif dropped < previous:
                self.dropped_events[box] = dropped
            for event in unit.get("floor_events", []):
                event_id = event.get("id", "")
                event_key = (box, event_id)
                current_events.add(event_key)
                if not event_id or event_key in self.sent_events:
                    continue
                message = ("crew floor: %s (%s) %s operating limit %s "
                           "measured=%s limit=%s subject=%s at %s; cause=%s" % (
                               box or "unknown", role, event.get("severity", ""),
                               event.get("name", ""), event.get("measured", ""),
                               event.get("limit", ""), event.get("subject", ""),
                               event.get("timestamp", ""), event.get("cause", "")))
                if self._send(message):
                    self.sent_events.add(event_key)
        self.sent_events.intersection_update(current_events)

    def observe(self, pings, roster, units):
        """Consume one complete ping round and emit only state transitions."""
        roles = {u["box"]: u.get("room", "unknown") for u in roster}
        contexts = {u["box"]: u for u in units}

        for name, ping in sorted(pings.items()):
            unit = contexts.get(name, {})
            last_tick = (unit.get("cron") or {}).get("last")
            if last_tick:
                self.last_ticks[name] = last_tick
            last_tick = self.last_ticks.get(name, "unknown")
            role = roles.get(name, unit.get("room", "unknown"))
            down = not ping["ok"] and ping["fails"] >= self.threshold
            was_down = name in self.unreachable

            if down and not was_down:
                since = ping.get("down_since") or ping["ts"]
                self.unreachable[name] = since
                self._send(
                    "crew floor: %s (%s) unreachable for %s; "
                    "last observed tick %s" %
                    (name, role, _duration(ping["ts"] - since), last_tick))
            elif ping["ok"] and was_down:
                since = self.unreachable.pop(name)
                self._send(
                    "crew floor: %s (%s) recovered after %s unreachable; "
                    "last observed tick %s" %
                    (name, role, _duration(ping["ts"] - since), last_tick))
