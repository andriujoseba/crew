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
