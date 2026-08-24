# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/init.sh — the suite for fleet-floor/server/floor/__init__.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2).
#
# Subject: the package root — and specifically the compatibility block, which
# is the only part of this split that is a PROMISE rather than a relocation.
#
# D4 says `crew floor` and EVERY IMPORT PATH behave exactly as today, and the
# pre-split module was an import path: put fleet-floor/server on sys.path,
# `import floor`, use the collector. The package shadows that module, so the
# promise has to be kept deliberately and asserted here or it rots the first
# time someone tidies an import.
#
# THESE CASES DRIVE THE OLD-STYLE IMPORTER ON PURPOSE. `import floor` with
# nothing after the dot is the whole point: every other suite in this tree
# reaches for `floor.<module>`, which is the NEW door and cannot see this
# break at all. Repointing the in-repo callers to submodules is exactly what
# hid it at 6eeb311.

# --- half one: the names -----------------------------------------------------
#
# The list below is the 394bdad surface, pinned. It is not derived from the
# package at runtime, which would assert only that floor equals itself; it is
# the 25 top-level definitions and 35 module constants the pre-split file
# defined, written out so the assertion has an outside reference.
#
# IT IS FROZEN, and that is what keeps this file out of the 0.1.3 window's
# way: it is a claim about ONE tree, so a member adding a name to ping.py or
# filling in alerts.py (#481) has no reason to touch it. Growing this list is
# always wrong — a name that did not exist at 394bdad cannot be something a
# pre-split caller depended on.
FF_INIT_SURFACE="HERE CREW_ROOT INDEX PROBE AGENTS_DIR FLOOR_ENVELOPE
CONFIG_DIR CONFIG_IS_OPERATOR ROSTER FLOOR_VERSION TICK_S SILENT_AFTER_S
PROBE_TIMEOUT_S ACTION_TIMEOUT_S ACTION_WORKERS PING_INTERVAL_S PING_TIMEOUT_S
PING_FAILS_TO_WEDGE PING_STALE_AFTER_S STUCK_AFTER_S LOG_LOCK TS RE_START
RE_END RE_ANY_TS RE_QUEUE RE_REVIEW_BATCH RE_BUILD_DUTY RE_TRIAGE RE_MENTION
RE_RESUME PING_SH PAUSE_SH RESUME_SH MESSAGE_SH floor_message_prompt
fleet_config_dir require_operator_config agent_conf_path log run read_roster
box_states parse_ts parse_probe last_tick_block derive_queue derive_sessions
spark_24h parse_ping ping_box probe_box unit_defaults build_unit fmt_dur Fleet
do_command Handler serve main"

FF_INIT_MISSING="$(FF_SRV="$FLOOR/server" FF_WANT="$FF_INIT_SURFACE" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["FF_SRV"])
import floor
print(",".join(n for n in os.environ["FF_WANT"].split() if not hasattr(floor, n)))
PY
)"
t "init: the pre-split \`import floor\` surface is whole" "" "$FF_INIT_MISSING"

# The count is asserted separately from the membership so a mangled list reds
# rather than silently checking fewer names than it claims to.
t "init: that surface is the 60 names 394bdad defined" \
  60 "$(printf '%s' "$FF_INIT_SURFACE" | wc -w | tr -d ' ')"

# --- half two: the refusal ---------------------------------------------------
#
# The half that is easy to forget, and the one that would bite hardest. At
# 394bdad `import floor` with an invalid CREW_CONFIG_DIR did not hand back a
# half-usable module — it refused and EXITED THE IMPORTING PROCESS. Restore
# only the names and a door that used to refuse now opens silently.
#
# Driven with a competing invalid timeout for the same reason ../cli.sh's
# refusal-order rows are: with only a bad CREW_CONFIG_DIR the refusal fires
# whatever the import order is.
FF_INIT_RC=0
FF_INIT_OUT="$( (cd "$FLOOR/server" && CREW_CONFIG_DIR=/definitely/missing \
  env -u CREW_FLOOR_ROSTER CREW_FLOOR_PROBE_TIMEOUT=bad python3 -c \
  'import sys; sys.path.insert(0, "."); import floor') 2>&1 )" || FF_INIT_RC=$?
if [ "$FF_INIT_RC" -eq 0 ]; then
  fail "init: a bare \`import floor\` still refuses an invalid definition" \
       "the import succeeded; at 394bdad it exited the importing process"
elif printf '%s' "$FF_INIT_OUT" | grep -q 'invalid literal for int'; then
  fail "init: a bare \`import floor\` still refuses an invalid definition" \
       "the timeout parsed first: $FF_INIT_OUT"
elif printf '%s' "$FF_INIT_OUT" | grep -q 'is not a fleet definition'; then
  ok "init: a bare \`import floor\` still refuses an invalid definition"
else
  fail "init: a bare \`import floor\` still refuses an invalid definition" \
       "neither answer: rc=$FF_INIT_RC $FF_INIT_OUT"
fi

# --- what the block does NOT restore, pinned so it stays declared ------------
#
# Reading the surface is restored. REBINDING it is not, and this row exists so
# that is a known limit rather than a surprise. At 394bdad the names were
# module globals, so `floor.FLOOR_ENVELOPE = ...` was seen by do_command in the
# same module; here do_command reads floor.actions' globals and an assignment
# on the package root is a different variable that nothing looks at.
#
# It is not closed on purpose. Forwarding writes from the package to whichever
# submodule owns each name needs a module-level __setattr__, which is the
# design change D5 forbids, for a seam whose only callers were in this test
# tree. Declared, asserted, and left alone — if it ever needs closing, this
# row is where the argument starts.
FF_INIT_REBIND="$(FF_SRV="$FLOOR/server" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["FF_SRV"])
import floor
floor.FLOOR_ENVELOPE = "/definitely/missing/fragment-floor-envelope.txt"
print("reached" if floor.actions.FLOOR_ENVELOPE.startswith("/definitely/missing")
      else "not-reached")
PY
)"
t "init: rebinding through the package root does not reach the module" \
  "not-reached" "$FF_INIT_REBIND"
