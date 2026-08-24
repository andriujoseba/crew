#!/usr/bin/env python3
"""floor.py — the fleet-floor collector, served from the operator host.

Closes #38 (telemetry) and #39 (operator control) WITHOUT a box-side agent.

The issues both proposed a box-initiated collector — box POSTs /report, box
long-polls /prompts — because the boxes have no inbound network path. That is
true of the network and irrelevant here: the operator host already holds a
control channel into every box, `box exec`, and that is how `crew status`,
`crew hire` and `crew upgrade` have always worked. So the direction inverts:

    host --box exec--> box     read duty evidence   (#38)
    host --box exec--> box     fire operator action (#39)

Nothing is installed in a box, no box egress is required, no collector client
runs on the guest, and a box that is stopped or wedged simply fails its probe
and is reported SILENT instead of hanging a queue nobody drains.

Because the page can now do things — restart boxes, cut power, start model
sessions — the server refuses to serve without HTTP Basic auth.

Stdlib only, no build step: the crew CLI is bash and this host is not
guaranteed a package manager, let alone a virtualenv.

The file itself is now the entry point and nothing else. What it held lives in
the `floor` package beside it, one module per section it already drew (#508);
`floor/__init__.py` is the map. Every door is unchanged: `crew floor` execs
this path, `python3 fleet-floor/server/floor.py` serves, and the refusals fire
in the same order — the fleet definition resolves at import, then main()
checks the operator config, then the password.

That includes the door this file is not: `import floor` off this directory
still answers with the whole collector surface and still refuses at import,
because `floor/__init__.py` restores it (#508 D4).
"""

import os
import sys

# Running this file directly already puts its own directory on sys.path, which
# is what makes `floor` importable. Being COPIED somewhere and run, or read
# through runpy, does not always — so say it here rather than leaving every
# caller to arrange it.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# The fleet definition resolves FIRST, before anything parses its own
# CREW_FLOOR_* configuration — this file used to hold both and ran them in
# that order by line number (:116 against :175). That order is NOT arranged
# here: importing any floor.* name runs floor/__init__.py, whose compatibility
# block imports floor.roster ahead of the parsing modules, so both entry doors
# get it from the same place. An `import floor.roster` on this line would be
# inert, which is measured rather than assumed — deleting it changes none of
# the three refusal-order rows in fleet-floor/test/cli.sh, and reversing
# __init__.py's block reds them. The carrier is asserted where it lives.
from floor.server import main  # noqa: E402  (the sys.path line must precede it)

if __name__ == "__main__":
    main()
