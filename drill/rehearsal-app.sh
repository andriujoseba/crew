#!/usr/bin/env bash
# drill/rehearsal-app.sh — rehearse the fleet app (`crew floor`) against the
# REAL boxes on this host.
#
#   drill/rehearsal-app.sh [--boxes "a b c"] [--port <n>] [--no-browser]
#                          [--allow-control] [--roster <path>]
#
# --roster points the drill at a roster other than fleet.roster, and feeds the
# SAME file to all three readers: the collector it starts (CREW_FLOOR_ROSTER),
# the `crew status` it compares against (CREW_ROSTER), and its own counts. The
# agreement assertion is meaningless unless all three read one list.
#
# It exists because the alternative is editing the tracked fleet.roster to run
# a drill, and that is not a hygiene point: `crew hire`'s registry guard keys
# on roster membership, so a drill box listed in fleet.roster is a fleet member
# as far as every safety check is concerned — which is how a leftover drill box
# came to be armed against the production registry (#51).
#
# The other half of this coverage lives in fleet-floor/test/run.sh, which
# drives the same collector against a stub `box` CLI and can therefore reach
# states no real host has on demand (wedged, unreachable, corrupt log). What
# only a real host can prove is the part that stub cannot fake: that
# `box exec` into an actual box yields the duty evidence the floor claims to
# read, and that a control really moves the box.
#
# READ-ONLY BY DEFAULT, and the browser walk is read-only ALWAYS — even under
# --allow-control. test/browser.js clicks Pause and Wake for real and picks its
# targets by screen position, so it can never be bound to --boxes; its
# `wake-silent` click is fleet-wide and cannot be narrowed at all. Gating it on
# --allow-control merely moved the hazard onto the opt-in path, where this
# file's own guarantee — opt-in controls touch ONLY named boxes — was still
# broken. Controls are exercised solely by the narrowed block below: every name
# validated against the roster in use, reversible verbs only, repaired on
# teardown.
# A drill that silently power-cycles a working fleet member is worse than no
# drill (heavy-duty/crew#26: a drill that wrote to real repos because nothing
# narrowed it).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

BOXES=""
PORT=8792
BROWSER=1
ALLOW_CONTROL=0
USER=drill
PASSWD="drill-$$-$RANDOM"
ROSTER="$ROOT/fleet.roster"

while [ $# -gt 0 ]; do
  case "$1" in
    --boxes)         BOXES="$2"; shift 2 ;;
    --port)          PORT="$2"; shift 2 ;;
    --roster)        ROSTER="$2"; shift 2 ;;
    --no-browser)    BROWSER=0; shift ;;
    --allow-control) ALLOW_CONTROL=1; shift ;;
    *) echo "usage: drill/rehearsal-app.sh [--boxes \"a b c\"] [--port <n>] [--roster <path>] [--no-browser] [--allow-control]"; exit 1 ;;
  esac
done

# Named before anything starts. A missing roster otherwise surfaces as a
# collector with zero units and a drill that skips every comparison — which is
# the failure mode #50 exists to stop being invisible.
[ -f "$ROSTER" ] || { echo "drill/rehearsal-app.sh: no roster at '$ROSTER'"; exit 1; }
# One reader for the roster, used by the counts, the agreement loop and the
# control allowlist alike.
roster_rows() { grep -vE '^[[:space:]]*(#|$)' "$ROSTER"; }
export CREW_FLOOR_ROSTER="$ROSTER"
export CREW_ROSTER="$ROSTER"

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
# shellcheck disable=SC2317  # invoked by the traps below, which shellcheck
# does not treat as a call site.
# Boxes this run paused, so teardown can put them back even on a failure path.
PAUSED_BY_DRILL=""
# shellcheck disable=SC2317  # invoked by the traps below, which shellcheck
# does not treat as a call site.
cleanup() {
  local rc=$? b
  # Best-effort repair FIRST, while the collector is still up: bailing out
  # with a real fleet member's crontab left commented takes it off duty
  # silently, which is worse than the failure that caused the bail.
  for b in $PAUSED_BY_DRILL; do
    if [ "$(status POST /api/command "{\"action\":\"resume\",\"box\":\"$b\"}" 2>/dev/null)" = "200" ]; then
      echo "teardown: resumed $b"
    else
      echo "teardown: WARNING — could not resume $b; run: box exec $b -- bash -lc \"crontab -l | sed -E 's|^#CREW-FLOOR-PAUSED ||' | crontab -\"" >&2
    fi
  done
  if [ -n "$SRV" ]; then
    kill "$SRV" 2>/dev/null
  fi
  rm -rf -- "$TMP"
  return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
echo "   roster: $ROSTER ($(roster_rows | grep -c . || true) boxes)"
echo

# ---- a `box` that keeps a receipt ----------------------------------------
# The collector shells out to `box` by NAME, so putting a logging wrapper ahead
# of it on PATH records every call it makes without changing a line of the
# collector. This is what lets the read-only assertion below be made about the
# REAL fleet rather than about a stub's imitation of one: a flag that suppresses
# controls is only worth what the calls actually show.
#
# Resolve the real binary BEFORE the PATH change, or the wrapper execs itself.
REAL_BOX="$(command -v box)"
mkdir -p "$TMP/bin"
BOX_CALLS="$TMP/box-calls.log"
: > "$BOX_CALLS"
# Same one-line-per-invocation shape as the stub's log, so the same patterns
# read both. The wrapper must be transparent: it logs, then hands over with
# exec, preserving argv, stdin, stdout and the exit status exactly.
cat > "$TMP/bin/box" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BOX_CALLS"
exec "$REAL_BOX" "\$@"
SHIM
chmod +x "$TMP/bin/box"
export PATH="$TMP/bin:$PATH"

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
ROSTER_N="$(roster_rows | grep -c . || true)"
t "fleet: every roster box reported" "$ROSTER_N" "$UNITS"

# ---- the floor must agree with the CLI -----------------------------------
# This is the assertion the stub cannot make: two independent readers of the
# same boxes must not disagree. `crew status` and the floor share probe.sh's
# source of truth (VERSION, duty.log, the agent profile's bot_cli_probe), so
# if they diverge, one of them is lying to an operator.
#
# On the first real-host run this block never executed its assertion ONCE, in
# three runs for three different reasons, and reported `0 failed` every time
# (#50). Two real `crew` bugs were sitting directly underneath it; neither was
# found by an assertion — both were found by a human reading the skip lines and
# asking why. An assertion that only checks what it looked at cannot see what
# it never looked at, so the four guards below check the block itself:
#
#   1. the CLI's exit code, which was `|| true`d away (it was 5 — jq's
#      runtime-error code, and the whole diagnosis)
#   2. zero rows from a NON-EMPTY roster, which was scored as N per-box skips.
#      One box missing from the output is an absent box; EVERY box missing is a
#      broken CLI, and only the second must fail loudly, once.
#   3. a row count that disagrees with the roster count — the one-row-rc=0
#      state would otherwise still pass as "one comparison, two skips"
#   4. that at least one REAL comparison happened. The per-box skip branches
#      are individually correct (a cron-silent box genuinely differs from what
#      the CLI reports), so all three runs landed every box in some correct
#      branch and the block as a whole still proved nothing.
#
# run.sh's browser walk already has floor (4): a walk exiting 0 must report a
# count above a threshold. The agreement check is the more important assertion
# and had no equivalent.
echo
echo "== floor vs crew status"
CLI_RC=0
"$ROOT/cli/crew" status > "$TMP/status.txt" 2>&1 || CLI_RC=$?
if [ "$CLI_RC" -eq 0 ]; then
  ok "crew status exits 0"
else
  fail "crew status exits 0" "rc=$CLI_RC — $(head -3 "$TMP/status.txt" | tr '\n' ' ')"
fi

# Rows the CLI actually printed for roster members, counted the same way the
# loop below reads them.
CLI_ROWS=0
while read -r name _agent _role _from; do
  [ -z "$name" ] && continue
  grep -qE "^$name " "$TMP/status.txt" && CLI_ROWS=$((CLI_ROWS + 1))
done < <(roster_rows)

AGREE_N=0
if [ "$ROSTER_N" -gt 0 ] && [ "$CLI_ROWS" -eq 0 ]; then
  # ONE failure, not one per box: the roster is not empty, so this is the CLI
  # being broken, and saying it N times as "skip" is how it stayed invisible.
  fail "crew status produced no rows" \
       "the agreement check did not run — $ROSTER_N boxes on the roster, 0 rows printed"
elif [ "$CLI_ROWS" -ne "$ROSTER_N" ]; then
  fail "crew status prints one row per roster box" \
       "roster has $ROSTER_N, crew status printed $CLI_ROWS — the agreement check is only partial"
fi

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
  # An unusable answer is never a pass: an empty floor_state from a transient
  # API hiccup used to fall through to the "is up" branch and be recorded ok.
  case "$floor_state" in
    working|idle|offline) ;;
    *) fail "agree: $name" "floor returned no usable state (got '$floor_state')"; continue ;;
  esac
  cli_line="$(grep -E "^$name " "$TMP/status.txt" | head -1)"
  case "$cli_line" in
    *stopped*|*"NOT CREATED"*)
      AGREE_N=$((AGREE_N + 1))
      t "agree: $name is down" offline "$floor_state" ;;
    "")
      # Still a skip: ONE box absent from the output is an absent box. The
      # every-box case is caught once, above, before this loop runs.
      skip "agree: $name" "crew status printed no row" ;;
    *)
      # The CLI showing a box up does NOT mean the floor must call it up: a
      # paused box and a cron-silent one are offline on the floor BY DESIGN,
      # and both are ordinary states on a real fleet. Only disagree when the
      # floor reports offline with no reason for it.
      if [ "$floor_state" != "offline" ]; then
        AGREE_N=$((AGREE_N + 1))
        ok "agree: $name is up"
      else
        note="$(body GET /api/fleet | python3 -c "
import json,sys
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$name']
print((u[0].get('note') or '') if u else '')")"
        case "$note" in
          *paused*|*SILENT*|*"not hired"*|*"no cron"*)
            skip "agree: $name" "crew status shows it up; floor says offline because: $note" ;;
          *)
            AGREE_N=$((AGREE_N + 1))
            fail "agree: $name is up" "crew status shows it up, floor says offline with no reason (note: '${note:-none}')" ;;
        esac
      fi ;;
  esac
done < <(roster_rows)

# The block as a whole must have DONE something. Every per-box branch above is
# individually correct, which is exactly why all three of the first real-host
# runs landed every box in one of them and still compared nothing.
if [ "$AGREE_N" -gt 0 ]; then
  ok "the agreement check ran ($AGREE_N of $ROSTER_N boxes yielded a floor-vs-CLI comparison)"
else
  fail "the agreement check ran" \
       "0 of $ROSTER_N boxes yielded a floor-vs-CLI comparison — this block asserted nothing"
fi

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
    roster_rows | grep -qE "^$b " || { fail "control $b" "not in $ROSTER"; continue; }

    # pause/resume is the reversible one, so it is what the drill uses. The
    # assertion is the EFFECT: the box's own crontab, read back over box exec.
    if [ "$(status POST /api/command "{\"action\":\"pause\",\"box\":\"$b\"}")" = "200" ]; then
      PAUSED_BY_DRILL="$PAUSED_BY_DRILL $b"
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
    # ALWAYS read-only — including under --allow-control. Gating it on that
    # flag only moved the hazard: --allow-control without --boxes skips the
    # narrowed control block below, yet the walk would still pause whichever
    # unit is on screen, and its `wake-silent` click is FLEET-WIDE, which
    # --boxes cannot constrain even in principle. So the opt-in path broke this
    # file's own guarantee that controls touch only named boxes.
    #
    # browser.js picks its targets by screen position, not by name; there is no
    # honest way to bind that to an allowlist. Controls on a real host are
    # covered by the narrowed block below, which validates each name against
    # fleet.roster, uses the reversible verbs only, and repairs on teardown.
    # The browser walk's job here is to prove the page renders REAL data.
    echo "   (browser walk: read-only — controls are covered by the narrowed block)"
    # Slice the receipt from here, so the drill's own control block above is not
    # counted against the walk.
    RO_FROM=$(( $(wc -l < "$BOX_CALLS") + 1 ))
    # NOT FLOOR_TEST_FIXTURE: this is a real fleet. The walk's fixture-only
    # demands (a hostile-log box, a box in its first session, something offline)
    # are guarantees of test/fixtures/roster.txt, not of a healthy host.
    if FLOOR_TEST_READONLY=1 \
       node "$ROOT/fleet-floor/test/browser.js" "http://127.0.0.1:$PORT/" "$TMP/shots" "$USER" "$PASSWD" \
       2>&1 | tee "$TMP/walk.out"; then
      ok "browser walk against the real fleet (read-only)"
    else
      fail "browser walk against the real fleet (read-only)" "see output above"
    fi
    # A walk that exits 0 must have asserted something. Deliberately NOT a
    # numeric floor like the stub suite's: how many checks a real fleet reaches
    # depends on that fleet (a repo link needs a box with a repo, a reason
    # string needs something offline), and inventing a number for a host I
    # cannot measure is how the walk came to be unpassable here in the first
    # place. Assert only what is certain -- it reported a count -- and print it,
    # so an operator watching the drill can see coverage drop over time.
    WALK_N="$(sed -n 's/.*-- browser: \([0-9]*\) ok.*/\1/p' "$TMP/walk.out" | tail -1)"
    if [ -n "$WALK_N" ]; then
      ok "browser walk reported its assertion count (${WALK_N} checks on this fleet)"
    else
      fail "browser walk reported its assertion count" "no '-- browser: N ok' line — it exited without a summary"
    fi

    # ---- the read-only walk must have touched NOTHING --------------------
    # This assertion used to live in fleet-floor/test/run.sh, where it cost CI
    # a second full walk (~3 min) to prove a property about a fleet CI does not
    # have. It belongs here: the invariant is "the drill does not mutate a real
    # fleet", and this is the only place there is a real fleet to not mutate.
    #
    # kimi-bot found that this script once ran the walk unguarded, so a
    # "read-only" drill was pausing live members and starting stopped ones. The
    # mode exists now; what makes it trustworthy is reading the calls, not the
    # flag. A flag I merely believe in is exactly how that bug shipped.
    RO_NEW="$TMP/ro-calls.log"
    tail -n "+$RO_FROM" "$BOX_CALLS" > "$RO_NEW" 2>/dev/null || : > "$RO_NEW"
    # Nothing that changes a box may appear: no lifecycle verb, no crontab edit,
    # no session launch. `grep -c` PRINTS 0 and EXITS 1 on no match, so `|| echo
    # 0` would append a second line and break the compare; `|| true` is correct.
    RO_PAT='^(down|start) |\| crontab -|BOT_CLI_CMD|floor-prompt'
    RO_BAD=$(grep -cE "$RO_PAT" "$RO_NEW" || true)
    t "read-only walk issued no control command to a real box" 0 "${RO_BAD:-0}"
    if [ "${RO_BAD:-0}" -ne 0 ]; then
      echo "  offending calls:"; grep -nE "$RO_PAT" "$RO_NEW" | head -5
    fi
    # ...and it must still have done its job. Without this, a read-only mode
    # that silently did NOTHING would pass the check above perfectly.
    RO_PROBES=$(grep -c 'logstart' "$RO_NEW" || true)
    if [ "${RO_PROBES:-0}" -gt 0 ]; then
      ok "read-only walk still exercised the real fleet (${RO_PROBES} probes)"
    else
      fail "read-only walk still exercised the real fleet" "no probes seen — the walk did nothing"
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
