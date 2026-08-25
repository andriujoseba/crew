"""The telemetry snapshot both tiers publish into."""

import threading
import time
from datetime import datetime, timezone

from floor.alerts import ReachabilityAlerts
from floor.ping import (PING_FAILS_TO_WEDGE, PING_INTERVAL_S,
                        PING_STALE_AFTER_S, PING_TIMEOUT_S, PROBE_TIMEOUT_S,
                        STUCK_AFTER_S, log, ping_box)
from floor.roster import FLOOR_VERSION, agent_conf_path, box_states, read_roster
from floor.units import build_unit, fmt_dur, unit_defaults

# --------------------------------------------------------------------------
# poller
# --------------------------------------------------------------------------

class Fleet:
    """The telemetry snapshot, refreshed by one background thread."""

    def __init__(self, interval, alert_command=""):
        self.interval = interval
        self.lock = threading.Lock()
        self.snapshot = {"live": True, "generated": None, "version": FLOOR_VERSION,
                         "units": [], "polling": True}
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
        self.alerts = ReachabilityAlerts(alert_command, PING_FAILS_TO_WEDGE)

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
        # strict, because since #204 absence HIDES a console: an empty dict has
        # always been ambiguous between "this host has no boxes" and "the
        # question could not be asked", and the poller is now a caller that
        # acts on absence. The ping tier already reads it this way; see
        # box_states' docstring for the argument.
        states, states_ok = box_states(strict=True)
        now = time.time()

        units = [None] * len(roster)
        threads = []

        def work(i, unit):
            try:
                units[i] = build_unit(unit, states.get(unit["box"]),
                                      self.agent_conf(unit["agent"]), now,
                                      inventory_ok=states_ok)
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
            "version": FLOOR_VERSION,
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
                # Kept across the whole failed run so both alert edges can say
                # how long the box was unreachable without estimating from a
                # poll count whose cadence stretches under a wedged guest.
                "down_since": None if ok else prev.get("down_since", now),
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
                with self.lock:
                    units = list(self.snapshot.get("units", []))
                self.alerts.observe(res, read_roster(), units)
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
