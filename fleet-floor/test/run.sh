#!/usr/bin/env bash
# fleet-floor/test/run.sh — test the collector and the page with no fleet.
#
#   fleet-floor/test/run.sh [--no-browser]
#
# A stub `box` CLI (test/stub-box) stands in for Incus, driven by
# test/fixtures/fleet.txt, so every box state the floor must render — running,
# stopped, unreachable, wedged, cron-silent, paused, freshly hired with no
# sessions, unauthenticated, and a box whose log is hostile or corrupt — is
# reachable here instead of only on a real host. The drill covers the other
# half (drill/rehearsal-app.sh: the same assertions against real boxes).
#
# The browser half needs playwright-core; it is SKIPPED, loudly, when absent,
# because a silently-skipped UI test reads exactly like a passing one.
# The directive below makes `source "$HERE/cases.sh"` resolve for shellcheck,
# so it can see that the helpers defined here ARE called (from cases.sh) and
# stops reporting every one of them as unreachable.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOOR="$(dirname "$HERE")"

BROWSER=1
[ "${1:-}" = "--no-browser" ] && BROWSER=0

PASS=0 SKIP=0
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
skip() { echo "skip $1${2:+  — $2}"; SKIP=$((SKIP + 1)); }
# t NAME EXPECTED ACTUAL — the fixture-test idiom from shared/test/run.sh
t() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

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
  [ -n "${SRV2:-}" ] && kill "$SRV2" 2>/dev/null
  [ -n "${SRV3:-}" ] && kill "$SRV3" 2>/dev/null
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

# ---- browser -------------------------------------------------------------
if [ "$BROWSER" -eq 1 ]; then
  echo
  echo "== page"
  # Both halves must be present: the driver, and a browser for it to drive.
  # PW_CHROME lets CI point at the runner's preinstalled Chrome instead of
  # downloading one.
  CHROME_BIN="${PW_CHROME:-$HOME/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome}"
  if ! command -v node >/dev/null; then
    skip "browser walk" "node not installed"
  elif ! (cd "$HERE" && node -e "require('playwright-core')") >/dev/null 2>&1; then
    skip "browser walk" "playwright-core not installed (npm i playwright-core)"
  elif [ ! -x "$CHROME_BIN" ]; then
    skip "browser walk" "no browser at $CHROME_BIN (set PW_CHROME)"
  else
    export PW_CHROME="$CHROME_BIN"
    if node "$HERE/browser.js" "http://127.0.0.1:$PORT/" "$TMP/shots" "$USER" "$PASSWD"; then
      ok "browser walk"
    else
      fail "browser walk" "see output above"
    fi
    # DEMO is a shipped mode, not a fallback: `open index.html` must still work
    # with no collector, no network and every control visibly disabled.
    if node "$HERE/browser.js" "file://$FLOOR/index.html" "$TMP/shots-demo"; then
      ok "browser walk (DEMO mode)"
    else
      fail "browser walk (DEMO mode)" "see output above"
    fi

    # Killed collector, on its own throwaway instance so the walk above keeps
    # the one it was using.
    echo
    echo "== collector death"
    SPORT=$((PORT + 1))
    CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$SPORT" \
    CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 \
    CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
      python3 "$FLOOR/server/floor.py" >"$TMP/server2.log" 2>&1 &
    SRV2=$!
    # Wait for its FIRST POLL, not just the socket: a page that loads against a
    # collector with no snapshot yet sees an empty fleet, and the stale test
    # would then be asserting against a page that never went live.
    for _ in $(seq 1 120); do
      curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$SPORT/api/fleet" 2>/dev/null \
        | grep -q '"box"' && break
      sleep 0.5
    done
    if node "$HERE/stale.js" "http://127.0.0.1:$SPORT/" "$SRV2" "$USER" "$PASSWD"; then
      ok "page reports a dead collector"
    else
      fail "page reports a dead collector" "see output above"
    fi
    kill "$SRV2" 2>/dev/null

    # The roster changing under an open console. Its own collector: this one
    # polls fast and owns a scratch roster the test is allowed to edit.
    echo
    echo "== roster churn"
    CPORT=$((PORT + 2))
    cp "$HERE/fixtures/roster.txt" "$TMP/churn-roster.txt"
    CREW_FLOOR_ROSTER="$TMP/churn-roster.txt" \
    CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$CPORT" \
    CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=6 \
    CREW_FLOOR_PROBE_TIMEOUT="${FLOOR_TEST_PROBE_TIMEOUT:-6}" \
      python3 "$FLOOR/server/floor.py" >"$TMP/server3.log" 2>&1 &
    SRV3=$!
    for _ in $(seq 1 120); do
      curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$CPORT/api/fleet" 2>/dev/null \
        | grep -q '"box"' && break
      sleep 0.5
    done
    if SHOT_DIR="$TMP" node "$HERE/churn.js" "http://127.0.0.1:$CPORT/" \
         "$TMP/churn-roster.txt" "$USER" "$PASSWD"; then
      ok "roster churn"
    else
      fail "roster churn" "see output above"
    fi

    # A box changing STATE under an open console. Shares the fast-polling
    # collector above: every other page test enters a console and leaves within
    # one poll, so the live-update path is otherwise untested.
    echo
    echo "== state transition"
    if SHOT_DIR="$TMP" node "$HERE/transition.js" "http://127.0.0.1:$CPORT/" "$USER" "$PASSWD"; then
      ok "state transition under an open console"
    else
      fail "state transition under an open console" "see output above"
    fi
    kill "$SRV3" 2>/dev/null
  fi
fi

echo
echo "== summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILS[@]}"
  exit 1
fi
exit 0
