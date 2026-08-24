"""floor — the fleet-floor collector, split on the sections it already drew.

`floor.py` beside this package is still the entry point and still the whole
public door: `python3 fleet-floor/server/floor.py`, which is what `crew floor`
execs. This package holds what that file used to hold, one module per section
(#508):

    ping     the liveness tier: log, run, the ping script and its parser
    roster   where the fleet is defined, and what boxes exist
    units    duty.log -> the record the page renders
    fleet    the snapshot, refreshed by one background thread
    actions  operator control: the box-side scripts and do_command
    alerts   out-of-band notice when a box goes dark (#481)
    server   HTTP: the handler, serve() and main()

This file carries only what the move itself breaks — the paths, which were
anchored on the old file's own directory and are now anchored on this
package's parent so they resolve to exactly what they resolved to before —
plus the two-boundary time rule, which units and ping both derive from.

Below those, and nothing to do with the split's shape, is the compatibility
block: `import floor` off `fleet-floor/server` answers exactly as the
pre-split module did, because D4 says every import path behaves as it did
today and the module WAS the import path. See the note above it.
"""

import os

# One level further up than the pre-split HERE, because this file is one
# directory deeper: `<...>/fleet-floor/server/floor/__init__.py`. HERE and
# CREW_ROOT resolve to exactly what they resolved to in floor.py.
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CREW_ROOT = os.path.dirname(os.path.dirname(HERE))
# INDEX is the app, not the fleet: it keeps resolving from the checkout even
# though the fleet definition (roster.py) no longer does (#75).
INDEX = os.path.join(CREW_ROOT, "fleet-floor", "index.html")
PROBE = os.path.join(HERE, "probe.sh")
AGENTS_DIR = os.path.join(CREW_ROOT, "shared", "conf", "agents")
FLOOR_ENVELOPE = os.path.join(CREW_ROOT, "shared", "prompts",
                              "fragment-floor-envelope.txt")

# A tick is 5 minutes; the engine's own death rule is "no evidence for two tick
# boundaries", so the floor uses the same number rather than inventing one.
TICK_S = 300
SILENT_AFTER_S = 2 * TICK_S


# --- the pre-split `import floor`, restored (#508 D4) ------------------------
#
# Everything above is the split. Everything below exists so the split is not
# VISIBLE to a caller that never asked for it: put `fleet-floor/server` on
# sys.path, `import floor`, and you get what you got at 394bdad. Two halves,
# and the second is the one easy to forget:
#
#   the names   the 25 definitions and 35 constants the module defined, all
#               of them, reachable at the same attribute path as before
#   the refusal the module RESOLVED THE FLEET DEFINITION AT IMPORT — an
#               invalid CREW_CONFIG_DIR exited the importing process rather
#               than handing back a half-usable module. Re-exporting only the
#               names would leave a door that used to refuse now opening,
#               which is the divergence that would bite hardest.
#
# THE ORDER OF THESE IMPORTS IS LOAD-BEARING, and it is the same rule the
# pre-split file got for free from its line numbers: `roster` FIRST, so the
# fleet definition resolves before any module parses its own CREW_FLOOR_*
# configuration. Reverse it and an invalid CREW_FLOOR_PROBE_TIMEOUT answers
# ahead of the refusal for an invalid CREW_CONFIG_DIR. Both entry doors reach
# the package through this file, so this is where that order now lives —
# fleet-floor/test/floor/init.sh drives every row of it against a mutation.
#
# THE SURFACE IS FROZEN AT 394bdad. It is a compatibility claim about one
# specific tree, so a later member adding a name to ping.py or filling in
# alerts.py (#481) has no reason to touch this list, and this file does not
# become the queue #508 exists to break. Names are grouped by the module they
# moved to, in that import order.
from floor.roster import (CONFIG_DIR, CONFIG_IS_OPERATOR,  # noqa: E402,F401
                          FLOOR_VERSION, ROSTER, agent_conf_path, box_states,
                          fleet_config_dir, read_roster,
                          require_operator_config)
from floor.ping import (LOG_LOCK, PING_FAILS_TO_WEDGE,  # noqa: E402,F401
                        PING_INTERVAL_S, PING_SH, PING_STALE_AFTER_S,
                        PING_TIMEOUT_S, PROBE_TIMEOUT_S, STUCK_AFTER_S, log,
                        parse_ping, ping_box, probe_box, run)
from floor.units import (RE_ANY_TS, RE_BUILD_DUTY, RE_END,  # noqa: E402,F401
                         RE_MENTION, RE_QUEUE, RE_RESUME, RE_REVIEW_BATCH,
                         RE_START, RE_TRIAGE, TS, build_unit, derive_queue,
                         derive_sessions, fmt_dur, last_tick_block,
                         parse_probe, parse_ts, spark_24h, unit_defaults)
from floor.fleet import Fleet  # noqa: E402,F401
from floor.actions import (ACTION_TIMEOUT_S, ACTION_WORKERS,  # noqa: E402,F401
                           MESSAGE_SH, PAUSE_SH, RESUME_SH, do_command,
                           floor_message_prompt)
from floor.server import Handler, main, serve  # noqa: E402,F401
