# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/ping.sh — the suite for fleet-floor/server/floor/ping.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the twelve members
# that edit these files still queue behind one test file.
#
# Subject: the fast tier — the heartbeat, its lock-age passenger, and the
# credential ageing that reads the same boundary the SILENT rule does.

# --- the ping tier, the stuck lock, and flow-reported credentials ----------
# Round: the 60s evidence poll answered three questions at one cadence, one of
# them over the network. These assert the three now arrive separately.

# The ping tier runs on its own thread and overlays the snapshot at read time,
# so a healthy box reports a round-trip without the evidence poll re-running.
# A wedged box fails BOTH tiers, and the two facts must not overwrite each
# other. The probe's "timed out after Ns" is the diagnostic one; the ping count
# is the timely one. Replacing the first with the second made the note depend
# on how many misses had accumulated, so CI and a laptop disagreed about the
# same fleet.
CS_WDL=$(( $(date +%s) + 40 ))
while [ "$(uf ff-wedged 'u["ping"] is not None and not u["ping"]["ok"]')" != "True" ] \
      && [ "$(date +%s)" -lt "$CS_WDL" ]; do sleep 1; done
t "wedged: the probe's reason survives the ping overlay" True \
  "$(uf ff-wedged '"timed out" in u["note"] or "unreachable" in u["note"].lower()')"
t "wedged: the ping fact is added too" True \
  "$(uf ff-wedged '"UNREACHABLE" in u["note"] or "timed out" in u["note"]')"

t "ping: a healthy box reports a round-trip" True "$(uf ff-working 'u["ping"] is not None and u["ping"]["ok"]')"

# THE sharp edge of carrying a passenger. `.duty.lock.since` is absent whenever
# no duty run is in flight — the normal state of a healthy idle box — and `cat`
# on a missing file exits 1. Without the explicit `exit 0`, every healthy box
# would fail three pings and render UNREACHABLE. This is the assertion that
# would have caught it, so it is checked across the WHOLE fleet rather than on
# one box.
t "ping: boxes with no lock file still ping ok" "" \
  "$(body GET /api/fleet | jqf "','.join(u['box'] for u in d['units'] if u.get('ping') and not u['ping']['ok'] and u['box'] not in ('ff-unreach','ff-wedged'))")"

# The passenger's payoff: STUCK is now seen on the 10s ping clock instead of
# waiting up to a full 60s evidence poll.
t "ping: a stuck lock is caught by the heartbeat" True "$(uf ff-stuck 'u["lock"]["stuck"]')"

# The last hop: collected -> used server-side -> SERVED. The passenger drove
# the STUCK escalation while never reaching the wire, so rehearsal-app.sh read
# ping.uptime/ping.lockheld and got None on every real host. boxside proves the
# script emits it and that parse_ping reads it; only this proves an operator
# (or the drill) can see it.
t "ping: the passenger is served, not just used" True \
  "$(uf ff-working 'u["ping"] is not None and "uptime" in u["ping"] and "lockheld" in u["ping"]')"
t "ping: the served uptime is real"   True "$(uf ff-working 'isinstance(u["ping"]["uptime"], int)')"
t "ping: the served lock age is real" 2820 "$(uf ff-stuck 'u["ping"]["lockheld"]')"
# A run that started moments ago must be served as a small age and NOT stuck —
# the raw-timestamp bug marked exactly this case STUCK for 495881h.
t "ping: a fresh run is served as a small age" 12 "$(uf ff-working 'u["ping"]["lockheld"]')"
t "ping: ...and is not escalated"          False "$(uf ff-working 'u["lock"]["stuck"]')"
# ...and it only ever escalates. A ping that read nothing must not clear or
# contradict what the evidence tier concluded.
t "ping: a healthy box is not marked stuck by its passenger" False "$(uf ff-working 'u["lock"]["stuck"]')"
t "ping: the round-trip is measured, not asserted" True "$(uf ff-working 'isinstance(u["ping"]["ms"], int)')"

# The state a ping exists to catch. `unreachable` fails its exec, so after
# FLOOR_TEST_PING_FAILS consecutive misses the overlay must override whatever
# the last evidence poll concluded — a session that was running cannot be
# progressing inside a guest that no longer answers.
CS_DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(uf ff-unreach 'u["ping"] is not None and not u["ping"]["ok"]')" != "True" ] \
      && [ "$(date +%s)" -lt "$CS_DEADLINE" ]; do sleep 1; done
t "ping: an unreachable box is caught by the heartbeat" True \
  "$(uf ff-unreach 'u["ping"] is not None and not u["ping"]["ok"]')"
t "ping: consecutive misses are counted, not just the last one" True \
  "$(uf ff-unreach 'u["ping"]["fails"] >= 1')"

# A box that is stopped or was never created must NOT be pinged: `box exec`
# into it fails for a reason the operator already knows, and counting that as
# a wedge paints every deliberately-down box red.
#
# Asserted over whatever the fleet looks like RIGHT NOW rather than against
# ff-stopped by name: the control cases above run start-all, so by this point
# the fixture's stopped box is running, and a by-name check here passed or
# failed on test ordering rather than on behaviour.
t "ping: stopped and absent boxes are skipped, not counted as wedged" "" \
  "$(body GET /api/fleet | jqf "','.join(u['box'] for u in d['units'] if (u['note'].startswith('stopped') or u['note'].startswith('not created')) and u['ping'] is not None)")"

# The wedge the SILENT rule cannot see: cron ticking, duty.log fresh, lock held
# for 47 minutes. It stays `working` — it genuinely is — and says so loudly.
t "stuck: a long-held lock is flagged"        True    "$(uf ff-stuck 'u["lock"]["stuck"]')"
t "stuck: the box is still reported working"  working "$(uf ff-stuck 'u["state"]')"
t "stuck: the note names the duration"        True    "$(uf ff-stuck '"STUCK" in u["note"]')"
t "stuck: a healthy box is not stuck"         False   "$(uf ff-working 'u["lock"]["stuck"]')"

# Credentials are read, never tested. `flowing` is a third value: it means the
# engine has been talking to the service and has not been rejected — NOT that
# anything just verified a token.
t "creds: a healthy box reports flowing"  flowing "$(uf ff-working 'u["gh"]')"
t "creds: no box ever reports ok"         True    "$(uf ff-working 'u["gh"] != "ok"')"
t "creds: a rejection is reported missing" missing "$(uf ff-noauth 'u["gh"]')"
t "creds: the rejection carries its reason" True  "$(uf ff-noauth 'any("gh:" in a for a in u["authfail"])')"
t "creds: an unhired box knows nothing"   unknown "$(uf ff-nothired 'u["gh"]')"
# The fourth state: installed, not ticking, therefore nothing established.
# Reporting `flowing` here would call a disarmed box with a dead token healthy.
t "creds: a box that stopped ticking is stale, not flowing" stale "$(uf ff-silent 'u["gh"]')"
# The fifth (#265). `stale` means "we heard from this box and no longer do";
# nobody has heard from a never-ticked one at all, and the operator's action
# differs — wait a tick boundary, versus go find out what broke.
t "creds: a never-ticked box is waiting, not stale"  waiting "$(uf ff-neverticked 'u["gh"]')"
t "creds: waiting applies to both services"          waiting "$(uf ff-neverticked 'u["vendor"]')"
# THE REGRESSION THAT MATTERS MORE THAN THE FIX. A verdict keyed on tickage
# alone, or on "no log lines", would launder a genuinely silent box — one whose
# credentials may be dead — behind a reassuring word. ff-silent above holds the
# floor half of that line and must never be relaxed; these two hold the
# boundaries the new branch could have swallowed on its way in.
t "creds: a never-ticked box is still hired"        True "$(uf ff-neverticked 'bool(u["engine"])')"
t "creds: an unhired box is untouched by waiting"   unknown "$(uf ff-nothired 'u["gh"]')"
# `waiting` is a credential verdict and nothing more: it must not leak into the
# colour rule as a green, and it must not make a box read healthy elsewhere.
t "creds: a waiting box is not flowing"             False "$(uf ff-neverticked 'u["gh"] == "flowing"')"
# The flowing-requires-a-recent-tick COUPLING is asserted in boxside.sh, where
# the real probe.sh runs against a duty.log this suite controls. It cannot be
# asserted here: stub-box picks its credential value from the scenario name,
# independently of the log it emits, so a fleet-wide check would be measuring
# the stub's internal consistency rather than the probe's rule. (`ff-fresh`
# has no timestamped line at all, and a PAUSED box legitimately reports
# flowing — its engine ran recently, an operator then stopped it.)
