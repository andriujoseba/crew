#!/usr/bin/env bash
# drill/rehearsal-app.sh — rehearse the fleet app (`crew floor`) against the
# REAL boxes on this host.
#
#   drill/rehearsal-app.sh [--boxes "a b c"] [--port <n>] [--no-browser]
#                          [--allow-control]
#
# The other half of this coverage lives in fleet-floor/test/run.sh, which
# drives the same collector against a stub `box` CLI and can therefore reach
# states no real host has on demand (wedged, unreachable, corrupt log). What
# only a real host can prove is the part that stub cannot fake: that
# `box exec` into an actual box yields the duty evidence the floor claims to
# read, and that a control really moves the box.
#
# READ-ONLY BY DEFAULT. The app can power-cycle boxes and start model
# sessions, so the control half runs only with --allow-control, and even then
# only against boxes named with --boxes. A drill that silently power-cycles a
# working fleet member is worse than no drill (heavy-duty/crew#26 is the
# precedent: a drill that wrote to real repos because nothing narrowed it).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

BOXES=""
PORT=8792
BROWSER=1
ALLOW_CONTROL=0
USER=drill
PASSWD="drill-$$-$RANDOM"

while [ $# -gt 0 ]; do
  case "$1" in
    --boxes)         BOXES="$2"; shift 2 ;;
    --port)          PORT="$2"; shift 2 ;;
    --no-browser)    BROWSER=0; shift ;;
    --allow-control) ALLOW_CONTROL=1; shift ;;
    *) echo "usage: drill/rehearsal-app.sh [--boxes \"a b c\"] [--port <n>] [--no-browser] [--allow-control]"; exit 1 ;;
  esac
done

PASS=0 SKIP=0
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
skip() { echo "skip $1${2:+  — $2}"; SKIP=$((SKIP + 1)); }
t()    { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

command -v box     >/dev/null || { echo "drill/rehearsal-app.sh runs on a box HOST — no 'box' on PATH"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

TMP="$(mktemp -d)"
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Two branches, not an unquoted ${3:+...} expansion — that would split the
# header on spaces and send garbage.
api() {
  if [ -n "${3:-}" ]; then
    curl -s -u "$USER:$PASSWD" -X "$1" -H 'Content-Type: application/json' -d "$3" \
      -w '\n%{http_code}' "http://127.0.0.1:$PORT$2"
  else
    curl -s -u "$USER:$PASSWD" -X "$1" -w '\n%{http_code}' "http://127.0.0.1:$PORT$2"
  fi
}
status() { api "$@" | tail -1; }
body()   { api "$@" | sed '$d'; }
jqf()    { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

echo "== app rehearsal (real boxes, host $(hostname))"
echo

# ---- collector -----------------------------------------------------------
CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$PORT" \
CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 \
  python3 "$ROOT/fleet-floor/server/floor.py" >"$TMP/floor.log" 2>&1 &
SRV=$!

up=0
for _ in $(seq 1 60); do
  curl -fsS -u "$USER:$PASSWD" "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && { up=1; break; }
  kill -0 "$SRV" 2>/dev/null || break
  sleep 0.5
done
if [ "$up" -ne 1 ]; then
  fail "collector starts" "$(tail -3 "$TMP/floor.log")"
  echo "== app rehearsal summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
  exit 1
fi
ok "collector starts"

# A real fleet poll is one `box exec` per box; give it room before asserting.
for _ in $(seq 1 120); do
  [ "$(body GET /api/fleet | jqf "len(d['units'])")" != "0" ] && break
  sleep 1
done

UNITS="$(body GET /api/fleet | jqf "len(d['units'])")"
ROSTER_N="$(grep -cvE '^[[:space:]]*(#|$)' "$ROOT/fleet.roster")"
t "fleet: every roster box reported" "$ROSTER_N" "$UNITS"

# ---- the floor must agree with the CLI -----------------------------------
# This is the assertion the stub cannot make: two independent readers of the
# same boxes must not disagree. `crew status` and the floor share probe.sh's
# source of truth (VERSION, duty.log, the agent profile's bot_cli_probe), so
# if they diverge, one of them is lying to an operator.
echo
echo "== floor vs crew status"
"$ROOT/cli/crew" status > "$TMP/status.txt" 2>&1 || true
while read -r name _agent _role _from; do
  [ -z "$name" ] && continue
  floor_state="$(body GET /api/fleet | python3 -c "
import json,sys
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$name']
print(u[0]['state'] if u else 'MISSING')")"
  if [ "$floor_state" = "MISSING" ]; then
    fail "floor reports $name" "not in /api/fleet"
    continue
  fi
  cli_line="$(grep -E "^$name " "$TMP/status.txt" | head -1)"
  case "$cli_line" in
    *stopped*|*"NOT CREATED"*)
      t "agree: $name is down" offline "$floor_state" ;;
    "")
      skip "agree: $name" "crew status printed no row" ;;
    *)
      # The CLI shows it up; the floor may legitimately call it working or
      # idle, but must not call it offline.
      if [ "$floor_state" = "offline" ]; then
        fail "agree: $name is up" "crew status shows it up, floor says offline"
      else ok "agree: $name is up"; fi ;;
  esac
done < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/fleet.roster")

# ---- evidence actually came from the boxes -------------------------------
echo
echo "== evidence is real"
HIRED="$(body GET /api/fleet | jqf "sum(1 for u in d['units'] if u['engine'])")"
if [ "$HIRED" -gt 0 ]; then
  ok "at least one box reports an engine version ($HIRED)"
  # A hired, ticking box must produce a cron heartbeat the floor can age.
  CRON_SEEN="$(body GET /api/fleet | jqf "sum(1 for u in d['units'] if u['cron']['last'])")"
  if [ "$CRON_SEEN" -gt 0 ]; then ok "cron heartbeat parsed from duty.log ($CRON_SEEN boxes)"
  else skip "cron heartbeat parsed" "no box has ticked yet"; fi
  SESS="$(body GET /api/fleet | jqf "sum(len(u['sessions']) for u in d['units'])")"
  if [ "$SESS" -gt 0 ]; then ok "session history parsed ($SESS sessions)"
  else skip "session history parsed" "no sessions in any duty.log yet"; fi
else
  skip "engine version reported" "no box on this host is hired"
fi

# Auth is not optional on a page that can power-cycle boxes.
echo
echo "== auth"
t "401: fleet without creds" 401 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/fleet")"
t "401: command without creds" 401 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "http://127.0.0.1:$PORT/api/command")"
t "405: PUT is rejected"     405 "$(status PUT /api/fleet)"

# ---- controls (opt-in, narrowed) -----------------------------------------
echo
echo "== control"
if [ "$ALLOW_CONTROL" -ne 1 ]; then
  skip "control verbs" "read-only run — pass --allow-control --boxes \"<name>\" to exercise them"
elif [ -z "$BOXES" ]; then
  skip "control verbs" "--allow-control needs --boxes to name what may be touched"
else
  for b in $BOXES; do
    grep -qE "^$b " "$ROOT/fleet.roster" || { fail "control $b" "not in fleet.roster"; continue; }

    # pause/resume is the reversible one, so it is what the drill uses. The
    # assertion is the EFFECT: the box's own crontab, read back over box exec.
    if [ "$(status POST /api/command "{\"action\":\"pause\",\"box\":\"$b\"}")" = "200" ]; then
      if box exec "$b" -- bash -lc "crontab -l 2>/dev/null | grep -q '^#CREW-FLOOR-PAUSED'" >/dev/null 2>&1; then
        ok "pause $b: crontab line is commented"
      else
        fail "pause $b: crontab line is commented" "no #CREW-FLOOR-PAUSED line in the box"
      fi
    else
      fail "pause $b" "command refused"
    fi

    if [ "$(status POST /api/command "{\"action\":\"resume\",\"box\":\"$b\"}")" = "200" ]; then
      if box exec "$b" -- bash -lc "crontab -l 2>/dev/null | grep -qE '^[^#].*tick\.sh'" >/dev/null 2>&1; then
        ok "resume $b: crontab line is live again"
      else
        fail "resume $b: crontab line is live again" "no active tick.sh line after resume"
      fi
    else
      fail "resume $b" "command refused"
    fi

    # Leaving a drill box paused would silently take a fleet member off duty.
    # if-block, never `A && fail || ok`: that shape is how crew#25 shipped a
    # check whose result depended on the exit status of its own reporting.
    if box exec "$b" -- bash -lc "crontab -l 2>/dev/null | grep -q '^#CREW-FLOOR-PAUSED'" >/dev/null 2>&1; then
      fail "teardown $b: left armed" "box is still paused"
    else
      ok "teardown $b: left armed"
    fi
  done
fi

# ---- page ----------------------------------------------------------------
if [ "$BROWSER" -eq 1 ]; then
  echo
  echo "== page"
  if node -e "require('playwright-core')" >/dev/null 2>&1; then
    if node "$ROOT/fleet-floor/test/browser.js" "http://127.0.0.1:$PORT/" "$TMP/shots" "$USER" "$PASSWD"; then
      ok "browser walk against the real fleet"
    else
      fail "browser walk against the real fleet" "see output above"
    fi
  else
    skip "browser walk" "playwright-core not installed (npm i playwright-core)"
  fi
fi

echo
echo "== app rehearsal summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILS[@]}"
  exit 1
fi
exit 0
