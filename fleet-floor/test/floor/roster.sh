# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/roster.sh — the suite for fleet-floor/server/floor/roster.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the seven members
# of this window that edit the collector still queue behind one test file.
#
# Subject: where the fleet is DEFINED and what boxes exist — read_roster's
# answer, and box_states' strict one.
#
# The module's resolution half — fleet_config_dir, agent_conf_path and the
# refusals — is covered in ../cli.sh, against that suite's own operator
# fixture. It did not move here: it would have dragged the fixture with it,
# and this split is a relocation (#508 D5).

t "fleet: every roster box present"  30 "$(body GET /api/fleet | jqf "len(d['units'])")"

# ABSENCE MUST BE MEASURED BEFORE IT CAN HIDE A CONSOLE. `box list` failing
# makes every box read absent — the ambiguity box_states' docstring is about —
# and the grid filter would then turn a broken inventory into an empty floor
# claiming nobody was ever hired. That is hiding on SILENCE, the one thing
# #204's discriminator rule forbids. Called directly rather than through a
# collector: the branch returns before it probes anything, so a fifth server
# would cost CI a minute to assert what one import asserts here.
FF_INV="$(python3 - "$FLOOR/server" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from floor.units import build_unit
unit = {"box": "ff-x", "agent": "claude", "room": "builder"}
asked = build_unit(dict(unit), None, "", 0, inventory_ok=True)
silent = build_unit(dict(unit), None, "", 0, inventory_ok=False)
print("%s|%s|%s" % (asked["hired"], silent["hired"],
                    "named" if "inventory" in silent["note"] else silent["note"]))
PY
)"
t "hired: a measured absence hides the console, an unreadable inventory does not" \
  "no|unknown|named" "$FF_INV"
