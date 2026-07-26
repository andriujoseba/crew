#!/usr/bin/env bash
# fleet-floor/test/run.sh — test the collector and the page with no fleet.
#
#   fleet-floor/test/run.sh
#
# A stub `box` CLI (test/stub-box) stands in for Incus, driven by
# test/fixtures/fleet.txt, so every box state the floor must render — running,
# stopped, unreachable, wedged, cron-silent, paused, freshly hired with no
# sessions, unauthenticated, and a box whose log is hostile or corrupt — is
# reachable here instead of only on a real host. The drill covers the other
# half (drill/rehearsal-app.sh: the same assertions against real boxes).
#
# Deterministic by construction: no browser, no wall-clock waits on rendering.
# The page-level walk lives in its own PR — it needs a real browser and its
# assertions turn on canvas timing, which made it the wrong thing to gate this
# one on.
# The directive below makes `source "$HERE/cases.sh"` resolve for shellcheck,
# so it can see that the helpers defined here ARE called (from cases.sh) and
# stops reporting every one of them as unreachable.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOOR="$(dirname "$HERE")"

PASS=0
SKIP=0   # kept in the summary line so the format matches shared/test/run.sh
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
# t NAME EXPECTED ACTUAL — the fixture-test idiom from shared/test/run.sh
t() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

# A busy port surfaced as a python traceback from deep inside socketserver,
# which reads like the collector is broken rather than like another copy of
# this suite is already running. Say so plainly, and name the way out.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 3>&-; return 0; }; return 1; }
if port_busy "${FLOOR_TEST_PORT:-8791}"; then
  echo "port ${FLOOR_TEST_PORT:-8791} is already in use — another run of this suite is probably still going." >&2
  echo "  re-run with a different base:  FLOOR_TEST_PORT=8891 $0 $*" >&2
  exit 1
fi

TMP="$(mktemp -d)"
PORT="${FLOOR_TEST_PORT:-8791}"
USER=operator
PASSWD="test-$$"

export FLOOR_FIXTURE="$HERE/fixtures/fleet.txt"
export FLOOR_CALLS="$TMP/box-calls.log"
export FLOOR_STATE="$TMP/state"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$FLOOR_STATE"
ln -sf "$HERE/stub-box" "$TMP/bin/box"
: > "$FLOOR_CALLS"

# The fixture fleet is handed to the collector by env, NOT by swapping the
# tracked fleet.roster and restoring it on exit: any killed run then left the
# real roster clobbered in the working tree, one `git add -A` away from being
# committed.
export CREW_FLOOR_ROSTER="$HERE/fixtures/roster.txt"
# shellcheck disable=SC2317  # invoked by the traps below, which shellcheck
# does not treat as a call site.
cleanup() {
  [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

api() {  # api METHOD PATH [BODY] -> "<status>\n<body>"
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -s -u "$USER:$PASSWD" -X "$m" -H 'Content-Type: application/json' \
      -d "$b" -w '\n%{http_code}' "http://127.0.0.1:$PORT$p"
  else
    curl -s -u "$USER:$PASSWD" -X "$m" -w '\n%{http_code}' "http://127.0.0.1:$PORT$p"
  fi
}
status() { api "$@" | tail -1; }
body()   { api "$@" | sed '$d'; }
jqf()    { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }
unit()   { body GET /api/fleet | python3 -c "
import json,sys
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$1']
print(json.dumps(u[0]) if u else '{}')"; }
uf()     { unit "$1" | python3 -c "import json,sys;u=json.load(sys.stdin);print($2)" 2>/dev/null; }

echo "== collector"
CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$PORT" \
CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 \
CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
CREW_FLOOR_ACTION_TIMEOUT="${FLOOR_TEST_ACTION_TIMEOUT:-8}" \
  python3 "$FLOOR/server/floor.py" >"$TMP/server.log" 2>&1 &
SRV=$!

for _ in $(seq 1 60); do
  curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  kill -0 "$SRV" 2>/dev/null || { echo "collector died:"; cat "$TMP/server.log"; exit 1; }
  sleep 0.5
done
# The first poll must finish before any fleet assertion, or every one of them
# races the collector's startup and fails intermittently.
for _ in $(seq 1 80); do
  [ "$(body GET /api/fleet | jqf "len(d['units'])")" != "0" ] && break
  sleep 0.5
done

export PORT USER PASSWD TMP
# shellcheck source=cases.sh
source "$HERE/cases.sh"
# The two scripts that normally only run inside a box, executed for real —
# without this the collector assertions above are circular (they validate the
# parser against stub-box's imitation of probe.sh, not against probe.sh).
# shellcheck source=boxside.sh
source "$HERE/boxside.sh"
# `crew floor` itself: the only part an operator types, and where the auth
# decision is made.
# shellcheck source=cli.sh
source "$HERE/cli.sh"

echo
echo "== summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILS[@]}"
  exit 1
fi
exit 0
