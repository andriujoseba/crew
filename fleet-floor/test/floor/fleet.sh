# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/fleet.sh — the suite for fleet-floor/server/floor/fleet.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the seven members
# of this window that edit the collector still queue behind one test file.
#
# Subject: the snapshot the two tiers publish into — the poller's strict
# inventory read, one sick box not stalling the rest, and the shape the
# page decides staleness from.

# ...and the poller is the caller that has to ask strictly, or the branch above
# is unreachable in production. Static, in the idiom this suite already uses
# for the guards it cannot reach through HTTP: deleting the strict read is what
# would silently empty a real floor.
if grep -Fq 'states, states_ok = box_states(strict=True)' "$FLOOR/server/floor/fleet.py" &&
   grep -Fq 'inventory_ok=states_ok' "$FLOOR/server/floor/fleet.py"; then
  ok "hired: the poller reads the inventory strictly and passes the verdict on"
else
  fail "hired: the poller reads the inventory strictly and passes the verdict on" \
       "a failed box list would empty the floor"
fi

# ===========================================================================
# LOOP 4 — the collector's hard edges. A wedged box (box exec that never
# answers) is the one that matters most: it is indistinguishable from a
# healthy one until the timeout fires, and if it stalls the poll then ONE sick
# box blanks the whole console.
# ===========================================================================
echo "== resilience"
t "wedged box does not stall the fleet" 30 "$(body GET /api/fleet | jqf "len(d['units'])")"
t "wedged box -> offline"          offline "$(uf ff-wedged "u['state']")"
case "$(uf ff-wedged "u['note']")" in *timed\ out*|*unreachable*) ok "wedged box says it timed out" ;;
  *) fail "wedged box says it timed out" "$(uf ff-wedged "u['note']")" ;; esac
# The healthy boxes in the same poll must be unaffected — the probe threads
# are what make that true, and a regression to a serial poll would show here.
t "healthy box survives a wedged peer" working "$(uf ff-working "u['state']")"


# ===========================================================================
# LOOP 5 — what the page does when the COLLECTOR is the thing that broke.
# The browser side of this is test/stale.js; these are the collector-side
# facts it depends on.
# ===========================================================================
echo "== snapshot honesty"
# The page decides staleness from this, so it has to be there and it has to be
# a real timestamp.
case "$(body GET /api/fleet | jqf "d['generated']")" in
  20[0-9][0-9]-[0-9][0-9]-*T*Z) ok "fleet: snapshot carries a generated stamp" ;;
  *) fail "fleet: snapshot carries a generated stamp" "$(body GET /api/fleet | jqf "d['generated']")" ;;
esac
t "fleet: snapshot advertises the poll interval" True \
  "$(body GET /api/fleet | jqf "isinstance(d.get('interval'),int) and d['interval']>0")"
# Every unit must be JSON-serialisable and complete — a missing key is a
# TypeError in the page, several panels deep, long after the poll that caused it.
t "fleet: every unit has the full shape" True "$(body GET /api/fleet | jqf "
all(set(('box','agent','room','state','engine','integrity','gh','vendor','queue','sessions',
         'cur','spark','up','repo','repos','logs','longest','avg','success',
         'today','paused','disarmed','cron','note','hired')) <= set(u) for u in d['units'])")"
t "fleet: cron sub-shape complete" True "$(body GET /api/fleet | jqf "
all(set(('ok','last','age')) <= set(u['cron']) for u in d['units'])")"


# ===========================================================================
# #486 — ONE WEDGE RULE, decided here and SERVED. The page used to re-derive
# it from the miss count against a 3 of its own while this module wedges at
# CREW_FLOOR_PING_FAILS, so at this suite's own threshold of 2 the collector
# force-stopped a guest whose restart confirmation still promised a graceful
# stop. These assert the rule at a NON-DEFAULT threshold — the drift is
# invisible at 3, which is exactly why it survived the first build.
# ===========================================================================
echo "== the wedge rule (#486)"

# ff_wedged THRESHOLD FAILS fresh|stale ok|no — wedged() itself, under an
# operator's chosen CREW_FLOOR_PING_FAILS. A child process per call because
# ping.py reads the environment at import, which is the same thing that makes
# the threshold unknowable to a constant written into the page.
#
# `stale` is taken from the module rather than written here as a number: the
# stale window is derived from the threshold, so a literal would be wrong for
# some of the very thresholds these cases exist to vary.
ff_wedged() {
  CREW_FLOOR_PING_FAILS="$1" FF_SRV="$FLOOR/server" FF_PING="$2 $3 $4" python3 - <<'PY'
import os
import sys
import time
sys.path.insert(0, os.environ["FF_SRV"])
from floor.fleet import wedged
from floor.ping import PING_STALE_AFTER_S
fails, age, ok = os.environ["FF_PING"].split()
now = time.time()
print(wedged({"ok": ok == "ok", "fails": int(fails), "err": "",
              "ts": now - (0 if age == "fresh" else PING_STALE_AFTER_S + 1)},
             now))
PY
}
# THE case the round turned on: two misses, at a floor configured for two.
# The page's old constant said "still fine" here while the collector killed
# the guest.
t "wedge: two misses at a threshold of two is wedged" True "$(ff_wedged 2 2 fresh no)"
# The same ping, at the 3 the page used to bake in — proving the verdict
# tracks the operator's setting and not a number written anywhere in crew.
t "wedge: the same ping at a threshold of three is not" False "$(ff_wedged 3 2 fresh no)"
t "wedge: a threshold of one wedges on the first miss" True "$(ff_wedged 1 1 fresh no)"
# A box that ANSWERED is never wedged, however the counter got there.
t "wedge: a box that answers is never wedged" False "$(ff_wedged 2 9 fresh ok)"
# Unmeasured is not unreachable. The cost of being wrong in this direction is
# a killed session, against a graceful restart that merely times out.
t "wedge: a stale ping is unmeasured, not wedged" False "$(ff_wedged 2 9 stale no)"

# ...and the verdict is SERVED, so no reader has to recombine the evidence.
# The collector under this suite runs at CREW_FLOOR_PING_FAILS=2 (run.sh), so
# these are read at a non-default threshold too.
#
# This suite is sourced fourth, well before the tier has had its two rounds,
# so wait for the fact rather than for the machine to be fast enough — the
# same deadline idiom floor/ping.sh uses on the same box.
FF_WD=$(( $(date +%s) + 60 ))
while [ "$(uf ff-wedged 'u["ping"] is not None and u["ping"]["wedged"]')" != "True" ] \
      && [ "$(date +%s)" -lt "$FF_WD" ]; do sleep 1; done
t "wedge: the verdict reaches the wire" True "$(uf ff-wedged 'u["ping"]["wedged"] is True')"
t "wedge: a healthy box is served not-wedged" False "$(uf ff-working 'u["ping"]["wedged"]')"
# Served BESIDE the evidence, not instead of it: an operator reading the
# payload still sees why, and the page still has nothing to recombine.
t "wedge: the evidence is served beside the verdict" True \
  "$(uf ff-wedged 'isinstance(u["ping"]["fails"], int) and "stale" in u["ping"]')"
# The seam the whole fix rests on: the thing served, the thing the page paints
# and the thing restart escalates on must be ONE call. Pinned at the source
# because a payload assertion cannot see whether the value came from wedged()
# or from a second spelling that happens to agree today.
if grep -q '"wedged": wedged(p, now)' "$FLOOR/server/floor/fleet.py"; then
  ok "wedge: the served verdict is wedged() itself"
else
  fail "wedge: the served verdict is wedged() itself" \
       "Fleet.get publishes something other than the rule the control asks"
fi
if grep -q 'return wedged(p, time.time())' "$FLOOR/server/floor/fleet.py"; then
  ok "wedge: the control escalates on the same call"
else
  fail "wedge: the control escalates on the same call" \
       "box_unreachable does not ask wedged()"
fi
# The page holds NO threshold. Asserted on all three copies — the source and
# both generated pages — as an absence, because absence is what has to hold:
# any comparison of the served miss count against a number is the bug this
# round fixed, whatever it is spelled.
FF_PAGE_THRESH="$(grep -n 'ping\.fails *>' "$FLOOR/src/app.js" "$FLOOR/index.html" \
                       "$FLOOR/dev/whiteboard.html" || true)"
t "wedge: no page-side threshold survives anywhere" "" "$FF_PAGE_THRESH"

# --- source invariants for the two fail-open paths ------------------------
# Both are conditions a stub fleet cannot stage — a `box list` that fails only
# sometimes, and a ping thread that outlives its join — so they are pinned at
# the source, the way this repo already pins `box exec`'s stdin redirect.

# The ping tier must ask box_states whether it could ANSWER, not merely what it
# returned: an empty dict means both "no boxes" and "could not ask", and
# treating the second as the first empties the roster, issues zero pings, and
# clears every consecutive-miss counter — fail-open, on the signal whose job is
# noticing that something stopped answering.
CS_SRC="$FLOOR/server/floor/fleet.py"
if grep -q 'box_states(strict=True)' "$CS_SRC"; then
  ok "ping: distinguishes a failed box list from an empty fleet"
else
  fail "ping: distinguishes a failed box list from an empty fleet" \
       "ping_once does not use box_states(strict=True)"
fi

# The published snapshot must be a COPY. join() with a timeout returns whether
# or not the thread finished, and these are daemons, so a ping still blocked in
# communicate() against a wedged box will later write into whatever dict the
# closure holds. If that dict is the live one, the late writer sets fails back
# to 0 from a stale prev and masks the wedge that made it late.
ping_once_source="$(awk '/def ping_once/,/return published/' "$CS_SRC")"
if grep -q 'published = dict(results)' <<<"$ping_once_source"; then
  ok "ping: publishes a copy, so a late thread lands on an orphan"
else
  fail "ping: publishes a copy, so a late thread lands on an orphan" \
       "ping_once publishes the same dict its threads still hold"
fi

# `flowing` must never be derivable from VERSION alone — VERSION records that
# the engine was installed, not that it has run. The rule now lives on the
# HOST: probe.sh reports `nofail` plus ::tickage and floor.py ages the pair,
# so the threshold is not copied into the box in a second language.
# `waiting` joins the forbidden list for the same reason (#265): the box knows
# its own tick age is absent and could "helpfully" name the state itself, and
# that is the same third copy of the rule wearing a friendlier word.
credential_probe_source="$(awk '/^for svc in gh vendor/,/^done/' "$FLOOR/server/probe.sh")"
if grep -q 'flowing\|waiting\|stale' <<<"$credential_probe_source"; then
  fail "creds: the box reports a fact, not a verdict" \
       "probe.sh decides flowing/waiting/stale itself — that is a third copy of the host's rule"
else
  ok "creds: the box reports a fact, not a verdict"
fi
if grep -q 'fresh = 0 <= tick_age < SILENT_AFTER_S' "$FLOOR/server/floor/units.py"; then
  ok "creds: the host ages nofail with the same rule it calls SILENT"
else
  fail "creds: the host ages nofail with the same rule it calls SILENT" \
       "floor.py does not derive freshness from SILENT_AFTER_S"
fi
# The never-ticked half of the same rule. Pinned at the source because the
# behavioural assertions above can only see the verdict the floor produced —
# they cannot see whether it came from the boundary the CLI also uses, and a
# reader that agreed by coincidence is what shared/test's cross-reader
# invariant exists to refuse.
if grep -q 'never_ticked = tick_age < 0' "$FLOOR/server/floor/units.py"; then
  ok "creds: the host names the never-ticked case rather than falling through"
else
  fail "creds: the host names the never-ticked case rather than falling through" \
       "floor.py has no never_ticked predicate — a never-ticked box ages to stale"
fi

# ===========================================================================
