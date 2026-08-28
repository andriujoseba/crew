# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/alerts.sh — reachability alert transitions (#481).

echo "== reachability alerts"

# The evidence poll carries box-side events through the same configured host
# channel. Repeated polls see the durable spool again but must not resend it.
for _ in $(seq 1 80); do
  grep -q 'ff-idle (reviewer) WARN: operating limit:' "$FLOOR_ALERT_LOG" && break
  sleep 0.25
done
t "alerts: a carried operating-limit event reaches the host channel" 1 \
  "$(grep -c 'ff-idle (reviewer) WARN: operating limit:' "$FLOOR_ALERT_LOG" || true)"
case "$(grep 'ff-idle (reviewer) WARN: operating limit:' "$FLOOR_ALERT_LOG" | head -1)" in
  *'heavy-duty/crew#482'*'measured=90 limit=100'*'cause=fixture-payload'*)
    ok "alerts: the event preserves repo, PR, measurement, limit, and cause" ;;
  *)
    fail "alerts: the event preserves repo, PR, measurement, limit, and cause" \
      "$(grep 'ff-idle' "$FLOOR_ALERT_LOG" || true)" ;;
esac

# The main collector is configured through its real fleet.conf and drives the
# real ff-wedged stub. By the time this module runs, many heartbeat rounds have
# crossed the threshold; there must still be exactly one alert for that edge.
for _ in $(seq 1 80); do
  grep -q 'ff-wedged (builder) unreachable' "$FLOOR_ALERT_LOG" && break
  sleep 0.25
done
t "alerts: a wedged roster box emits one unreachable edge" 1 \
  "$(grep -c 'ff-wedged (builder) unreachable' "$FLOOR_ALERT_LOG" || true)"

case "$(grep 'ff-wedged (builder) unreachable' "$FLOOR_ALERT_LOG" | head -1)" in
  *'unreachable for '*'last observed tick '*)
    ok "alerts: unreachable names box, role, duration, and last tick" ;;
  *)
    fail "alerts: unreachable names box, role, duration, and last tick" \
      "$(grep 'ff-wedged' "$FLOOR_ALERT_LOG" || true)" ;;
esac

# Ten explicit observations of the same down state exercise the state holder
# without paying ten real ping timeouts. This uses the production class and a
# real command sink; replacing edge state with per-poll delivery makes it ten.
FF_ALERT_UNIT_LOG="$TMP/reachability-alerts-unit.log"
export FF_ALERT_UNIT_LOG
: >"$FF_ALERT_UNIT_LOG"
FF_SRV="$FLOOR/server" python3 - <<'PY'
import os, shlex, sys
sys.path.insert(0, os.environ["FF_SRV"])
from floor.alerts import ReachabilityAlerts

sink = "tee -a %s" % shlex.quote(os.environ["FF_ALERT_UNIT_LOG"])
alerts = ReachabilityAlerts(sink, 2)
roster = [{"box": "ff-wedged", "room": "builder"}]
units = [{"box": "ff-wedged", "room": "builder",
          "cron": {"last": "2026-08-25T16:00:00Z"}}]
for i in range(10):
    alerts.observe({"ff-wedged": {
        "ok": False, "fails": 2 + i, "ts": 100 + i,
        "down_since": 90,
    }}, roster, units)
alerts.observe({"ff-wedged": {
    "ok": True, "fails": 0, "ts": 120, "down_since": None,
}}, roster, units)
events = [{"box": "ff-limits", "room": "builder", "floor_events": [{
    "id": "a" * 64,
    "message": "ERROR: operating limit: heavy-duty/crew#482 measured=110 limit=100",
}]}]
for _ in range(10):
    alerts.observe_floor_events(events)
alerts.observe_floor_events([{"box": "ff-limits-peer", "room": "reviewer",
                              "floor_events": events[0]["floor_events"]}])
PY
t "alerts: ten down polls emit one alert" 1 \
  "$(grep -c 'unreachable for' "$FF_ALERT_UNIT_LOG" || true)"
t "alerts: recovery emits one alert" 1 \
  "$(grep -c 'recovered after' "$FF_ALERT_UNIT_LOG" || true)"
t "alerts: a durable event is delivered once across repeated polls" 1 \
  "$(grep -c 'ff-limits (builder) ERROR: operating limit:' "$FF_ALERT_UNIT_LOG" || true)"
t "alerts: the same event on a second box is still delivered" 1 \
  "$(grep -c 'ff-limits-peer (reviewer) ERROR: operating limit:' "$FF_ALERT_UNIT_LOG" || true)"

# No channel is the shipped default. Exercise both edges and require literal
# silence — no command attempt, warning, traceback, or log line.
FF_NO_CHANNEL="$(FF_SRV="$FLOOR/server" python3 - <<'PY' 2>&1
import os, sys
sys.path.insert(0, os.environ["FF_SRV"])
from floor.alerts import ReachabilityAlerts

alerts = ReachabilityAlerts("", 2)
roster = [{"box": "ff-wedged", "room": "builder"}]
units = [{"box": "ff-wedged", "cron": {"last": None}}]
alerts.observe({"ff-wedged": {
    "ok": False, "fails": 2, "ts": 10, "down_since": 0,
}}, roster, units)
alerts.observe({"ff-wedged": {
    "ok": True, "fails": 0, "ts": 20, "down_since": None,
}}, roster, units)
alerts.observe_floor_events([{"box": "ff-limits", "room": "builder",
                             "floor_events": [{"id": "b" * 64,
                                               "message": "WARN: limit"}]}])
PY
)"
t "alerts: an unconfigured channel is a silent no-op" "" "$FF_NO_CHANNEL"

# Return the real fixture to health, then to its declared wedged scenario.
# The first edge proves recovery. A post-recovery refresh records a concrete
# last tick before the second outage, so the next alert proves the actionable
# context is carried rather than merely printing the field name.
printf 'idle\n' >"$FLOOR_STATE/ff-wedged.scenario"
for _ in $(seq 1 80); do
  grep -q 'ff-wedged (builder) recovered' "$FLOOR_ALERT_LOG" && break
  sleep 0.25
done
t "alerts: the same box returning emits one recovery edge" 1 \
  "$(grep -c 'ff-wedged (builder) recovered' "$FLOOR_ALERT_LOG" || true)"

status POST /api/command '{"action":"power-on","box":"ff-wedged"}' >/dev/null
for _ in $(seq 1 80); do
  [ "$(uf ff-wedged 'u["cron"]["last"] is not None')" = "True" ] && break
  sleep 0.25
done
t "alerts: recovery refresh observes a concrete last tick" True \
  "$(uf ff-wedged 'u["cron"]["last"] is not None')"

FF_WEDGED_BEFORE="$(grep -c 'ff-wedged (builder) unreachable' "$FLOOR_ALERT_LOG" || true)"
rm -f "$FLOOR_STATE/ff-wedged.scenario"
for _ in $(seq 1 120); do
  FF_WEDGED_NOW="$(grep -c 'ff-wedged (builder) unreachable' "$FLOOR_ALERT_LOG" || true)"
  [ "$FF_WEDGED_NOW" -gt "$FF_WEDGED_BEFORE" ] && break
  sleep 0.25
done
t "alerts: a later outage emits one new unreachable edge" \
  "$((FF_WEDGED_BEFORE + 1))" \
  "$(grep -c 'ff-wedged (builder) unreachable' "$FLOOR_ALERT_LOG" || true)"
case "$(grep 'ff-wedged (builder) unreachable' "$FLOOR_ALERT_LOG" | tail -1)" in
  *'last observed tick 20'??-*)
    ok "alerts: the outage carries the last observed tick value" ;;
  *)
    fail "alerts: the outage carries the last observed tick value" \
      "$(grep 'ff-wedged (builder) unreachable' "$FLOOR_ALERT_LOG" | tail -1)" ;;
esac
