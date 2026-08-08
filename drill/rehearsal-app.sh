#!/usr/bin/env bash
# drill/rehearsal-app.sh — rehearse the fleet app (`crew floor`) against the
# REAL boxes on this host.
#
#   drill/rehearsal-app.sh [--boxes "a b c"] [--port <n>] [--no-browser]
#                          [--allow-control] [--shots <dir>]
#                          [--roster <path> | --drill-roles "triage builder ..."]
#
# --drill-roles builds the roster from the `crew-drill-<role>` convention that
# rehearsal.sh already owns, so it cannot drift from the boxes a drill actually
# uses; prefer it. --roster is for anything else (`*.roster.local` is
# gitignored, so such a file has a home next to the drill).
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
# shellcheck source=drill/agreement.sh disable=SC1091
source "$HERE/agreement.sh"

BOXES=""
PORT=8792
BROWSER=1
ALLOW_CONTROL=0
USER=drill
PASSWD="drill-$$-$RANDOM"
ROSTER="$ROOT/examples/fleet.roster"
# Whether --roster was NAMED, rather than comparing against the default path:
# the default must appear exactly once in this file (asserted in CI), and
# `--roster <the default>` is a legitimate thing to type.
ROSTER_EXPLICIT=0
DRILL_ROLES=""
DRILL_AGENT="${DRILL_AGENT:-claude}"
GENERATED_ROSTER=""
# Screenshots outlive the run by default. browser.js's own header calls them
# "for humans", and the drill used to write them into $TMP and then `rm -rf` it
# on teardown — so every one was destroyed at exit, which makes taking them
# pointless. Override with --shots.
SHOTS="${SHOTS:-$ROOT/.drill-shots}"

while [ $# -gt 0 ]; do
  case "$1" in
    --boxes)         BOXES="$2"; shift 2 ;;
    --port)          PORT="$2"; shift 2 ;;
    --roster)        ROSTER="$2"; ROSTER_EXPLICIT=1; shift 2 ;;
    --drill-roles)   DRILL_ROLES="$2"; shift 2 ;;
    --agent)         DRILL_AGENT="$2"; shift 2 ;;
    --shots)         SHOTS="$2"; shift 2 ;;
    --no-browser)    BROWSER=0; shift ;;
    --allow-control) ALLOW_CONTROL=1; shift ;;
    *) echo "usage: drill/rehearsal-app.sh [--boxes \"a b c\"] [--port <n>] [--no-browser] [--allow-control]"
       echo "         [--roster <path> | --drill-roles \"triage builder reviewer\"] [--shots <dir>]"; exit 1 ;;
  esac
done

# --drill-roles generates the roster from the convention rehearsal.sh ALREADY
# owns (BOX_NAME="crew-drill-$ROLE"). Hand-maintaining a file that restates that
# convention is #35's complaint in miniature — one fact under two keys — and a
# drill roster naming a box the drill does not actually use is exactly the
# silent mismatch #50 exists to catch. Generated, it cannot drift.
if [ -n "$DRILL_ROLES" ]; then
  [ "$ROSTER_EXPLICIT" -eq 0 ] \
    || { echo "drill/rehearsal-app.sh: --roster and --drill-roles are alternatives, not both"; exit 1; }
  # The agent column is LOAD-BEARING, not a label: floor.py hands it to
  # probe.sh to choose shared/conf/agents/<agent>.conf, and `crew status` hands
  # it to vendor_probe. Generating it wrong means probing every drill box with
  # the wrong vendor profile — and because both readers share the one wrong
  # file, their agreement assertions still pass. Consistent, wrong data.
  #
  # So it is validated here rather than trusted: a roster naming an agent with
  # no profile would fail as "vendor missing" on every box, which is the same
  # symptom as a logged-out fleet and nothing like the same cause.
  [ -f "$ROOT/shared/conf/agents/$DRILL_AGENT.conf" ] \
    || { echo "drill/rehearsal-app.sh: unknown agent '$DRILL_AGENT' — see shared/conf/agents/"; exit 1; }
  ROSTER="$(mktemp)"; GENERATED_ROSTER="$ROSTER"
  for _role in $DRILL_ROLES; do
    case "$_role" in
      triage|builder|reviewer) printf '%s %s %s\n' "crew-drill-$_role" "$DRILL_AGENT" "$_role" >>"$ROSTER" ;;
      *) echo "drill/rehearsal-app.sh: unknown role '$_role' (triage, builder or reviewer)"; exit 1 ;;
    esac
  done
fi

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

# The 0.1.2 operator surfaces (#420) are asserted by functions over the inputs
# they read, sourced from beside this file. Sourced rather than inlined so
# shared/test/run.sh can drive them with a staged wrong answer and prove each
# one reds — an assertion reachable only from a drill host is one nobody has
# checked. Sourced HERE, after ok/fail/skip/t and roster_rows and before jqf,
# which is fine: bash resolves the callees at call time, and every call is far
# below.
# shellcheck source=drill/rehearsal-app-surfaces.sh disable=SC1091
source "$HERE/rehearsal-app-surfaces.sh"

command -v box     >/dev/null || { echo "drill/rehearsal-app.sh runs on a box HOST — no 'box' on PATH"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

TMP="$(mktemp -d)"
SRV=""
# Boxes this run ARMED, so teardown can disarm them on every exit path.
#
# The control block arms the box's own tick line before exercising the verbs
# (#188). It has to: drill/rehearsal.sh disarms cron before any tick and aborts
# the run if it cannot, so every drill box is guaranteed to have no armed
# `tick.sh` line for its whole run — `pause` had nothing to comment out, and a
# block that skipped the arm could only ever assert that the transport was
# reachable. Disarming afterwards therefore RESTORES the state the drill
# guarantees rather than destroying one.
ARMED_BY_DRILL=""

# Arm and disarm the box's own tick line, and read the crontab back.
#
# Temp file then `crontab <file>`, the same shape rehearsal-safety.sh's
# rehearsal_disarm_cron uses and for the same reason: a pipeline into
# `crontab -` whose head dies halfway installs an EMPTY crontab.
# shellcheck disable=SC2016,SC2317  # $HOME and $tmp are the BOX's, expanded by
# the shell inside it; and the function is called from the control block and
# from cleanup(), neither of which shellcheck treats as a call site.
drill_arm_cron() {
  box exec "$1" -- bash -lc '
    tmp=$(mktemp)
    { crontab -l 2>/dev/null | grep -vF "$HOME/duty/bin/tick.sh"
      echo "*/5 * * * * $HOME/duty/bin/tick.sh"; } > "$tmp"
    crontab "$tmp"; rc=$?
    rm -f "$tmp"; exit "$rc"' >/dev/null 2>&1
}
# shellcheck disable=SC2016,SC2317
drill_disarm_cron() {
  box exec "$1" -- bash -lc '
    tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -vF "$HOME/duty/bin/tick.sh" > "$tmp" || true
    crontab "$tmp"; rc=$?
    rm -f "$tmp"; exit "$rc"' >/dev/null 2>&1
}
# shellcheck disable=SC2317
drill_cron_armed()  { box exec "$1" -- bash -lc "crontab -l 2>/dev/null | grep -qE '^[^#].*tick\.sh'" >/dev/null 2>&1; }
# shellcheck disable=SC2317
drill_cron_paused() { box exec "$1" -- bash -lc "crontab -l 2>/dev/null | grep -q '^#CREW-FLOOR-PAUSED'" >/dev/null 2>&1; }
# Any tick.sh line at all, commented or live — the same fact rehearsal.sh's own
# teardown check asserts, and the one that says "disarmed" without ambiguity.
# shellcheck disable=SC2016,SC2317
drill_cron_present() { box exec "$1" -- bash -lc 'crontab -l 2>/dev/null | grep -qF "$HOME/duty/bin/tick.sh"' >/dev/null 2>&1; }

# shellcheck disable=SC2317  # invoked by the traps below, which shellcheck
# does not treat as a call site.
cleanup() {
  local rc=$? b
  # Best-effort repair FIRST: bailing out with a box's tick line still armed
  # leaves it ticking against whatever registry teardown restores, which is
  # worse than the failure that caused the bail. Unconditional, on every exit
  # path — a run that dies between the arm and the pause must still disarm, and
  # this reaches the box directly rather than through the collector, so it works
  # after the server is gone as well as before.
  for b in $ARMED_BY_DRILL; do
    if drill_disarm_cron "$b"; then
      echo "teardown: disarmed $b"
    else
      echo "teardown: WARNING — could not disarm $b; run: box exec $b -- bash -lc 'crontab -l | grep -vF \"\$HOME/duty/bin/tick.sh\" | crontab -'" >&2
    fi
  done
  if [ -n "$SRV" ]; then
    kill "$SRV" 2>/dev/null
  fi
  rm -rf -- "$TMP"
  # The GENERATED roster only — never a roster the operator named. $SHOTS is
  # deliberately kept: it is the run's only human-readable artifact.
  [ -n "$GENERATED_ROSTER" ] && rm -f -- "$GENERATED_ROSTER"
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

# ctl ACTION BOX — one call, both facts: CTL_CODE and CTL_OUT, what the BOX
# said. `command refused` was the whole diagnosis this drill ever produced for
# a failing control, and it was wrong — nothing was refusing (#188). The reason
# travels in the response's per-box `out`, so read it rather than narrating a
# guess. Deliberately one request: re-issuing the command to fetch its reason
# would be a second control action on a real box.
CTL_CODE="" CTL_OUT=""
ctl() {
  local raw
  raw="$(api POST /api/command "{\"action\":\"$1\",\"box\":\"$2\"}")"
  CTL_CODE="$(printf '%s\n' "$raw" | tail -1)"
  CTL_OUT="$(printf '%s\n' "$raw" | sed '$d' \
    | jqf "'; '.join((r.get('out') or '') for r in (d.get('results') or [])) or d.get('error') or ''")"
}

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
# The LAUNCHER owns the version string, not the server: floor.py's
# FLOOR_VERSION is `os.environ.get("CREW_FLOOR_VERSION", "version unavailable")`
# on purpose, so the page never makes a second attempt to find and interpret
# VERSION (server/floor.py). `crew floor` passes `crew --version`; a drill that
# starts floor.py directly and omits it serves the placeholder — and then #347's
# whole surface is untestable here, because the header has nothing real to name.
# So the drill launches the collector the way the operator's launcher does.
#
# The assertion that follows is NOT against this string: it is against the
# tree's own VERSION file, which is the fact an operator is reading the header
# for. A drill comparing a value it exported to itself asserts its own fixture,
# which is #50's defect in one line.
HOST_VERSION="$("$ROOT/cli/crew" --version)"
CREW_VERSION_FILE="$(head -1 "$ROOT/VERSION" 2>/dev/null | tr -d '\r\n')"
CREW_FLOOR_PASS="$PASSWD" CREW_FLOOR_USER="$USER" CREW_FLOOR_PORT="$PORT" \
CREW_FLOOR_BIND=127.0.0.1 CREW_FLOOR_INTERVAL=3600 \
CREW_FLOOR_VERSION="$HOST_VERSION" \
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
  agreement="$(agreement_case "$floor_state" "$cli_line" "${note:-}" "${dis:-False}")"
  case "$agreement" in
    down)
      AGREE_N=$((AGREE_N + 1))
      t "agree: $name is down" offline "$floor_state" ;;
    missing)
      # Still a skip: ONE box absent from the output is an absent box. The
      # every-box case is caught once, above, before this loop runs.
      skip "agree: $name" "crew status printed no row" ;;
    up)
      AGREE_N=$((AGREE_N + 1))
      ok "agree: $name is up" ;;
    *)
      if [ "$floor_state" = "offline" ]; then
        note="$(body GET /api/fleet | python3 -c "
import json,sys
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$name']
print((u[0].get('note') or '') if u else '')")"
        # Read the FLAG, not the prose. The note is written for an operator and
        # will be reworded; a check that greps English breaks when it improves.
        dis="$(body GET /api/fleet | python3 -c "
import json,sys
d=json.load(sys.stdin)
u=[x for x in d['units'] if x['box']=='$name']
print(bool(u and u[0].get('disarmed')))")"
        agreement="$(agreement_case "$floor_state" "$cli_line" "$note" "$dis")"
        if [ "$agreement" = "disarmed" ]; then
          # NOT a skip any more (#189). Both readers now answer "is this box
          # armed?" from the same crontab patterns, so this is a real
          # comparison — and making one is the entire point of this block,
          # which asserted nothing at all for five consecutive runs (#50).
          #
          # This is also the ONLY branch a drill box can reach: the drill
          # disarms cron before any tick and refuses to continue if it cannot
          # (drill/rehearsal.sh). Every previous run landed here and skipped.
          AGREE_N=$((AGREE_N + 1))
          ok "agree: $name is not armed, and both readers say so"
        elif [ "$agreement" = "disarmed-mismatch" ]; then
          AGREE_N=$((AGREE_N + 1))
          fail "agree: $name is not armed, and both readers say so" \
               "floor reports disarmed; crew status does not: '$cli_line'"
        else
          case "$agreement" in
            skip)
              skip "agree: $name" "crew status shows it up; floor says offline because: $note" ;;
            up-mismatch)
              AGREE_N=$((AGREE_N + 1))
              fail "agree: $name is up" "crew status shows it up, floor says offline with no reason (note: '${note:-none}')" ;;
          esac
        fi
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

# ---- the operator's view this window shipped (#420) -----------------------
# Six 0.1.2 changes landed in the view an operator opens to decide the fleet is
# healthy, and this leg read none of them. They are asserted HERE, on the same
# grounds :453 already states for the ping tier: every one is a read of a REAL
# box's state. stub-box can answer `modified`, or decline to answer at all; it
# cannot demonstrate that a real guest produces the answer the floor prints.
#
# Each assertion is made against the BOX's own answer wherever the box has one,
# never against a constant here — a drill comparing a value it exported to
# itself asserts its own fixture (#50).
echo
echo "== the operator's view (0.1.2 floor surfaces)"

# ONE snapshot for this whole section. Several assertions below read more than
# one field per box and cross-check two of them against the box itself;
# re-polling between reads lets a state change straddle a comparison and
# manufacture a disagreement neither reader ever held.
FLEET_JSON="$TMP/fleet-surfaces.json"
body GET /api/fleet > "$FLEET_JSON"

# Every box read this section makes is CAPPED, for the reason floor.py caps its
# own probes (server/floor.py's PROBE_TIMEOUT_S): `box exec` into a wedged box
# can block forever, and one sick box must not stall the leg — an uncapped read
# here would hang the whole drill where the collector under it merely reports a
# timeout. Same default and same override as the collector's, so the drill and
# the floor wait the same amount of time for the same box.
BOX_READ_TIMEOUT="${CREW_FLOOR_PROBE_TIMEOUT:-45}"
#
# `</dev/null` is LOAD-BEARING, and it was found by running this leg rather
# than by reading it. Every caller below sits inside `while read … done <
# <(roster_rows)`, and `box exec` inherits that loop's stdin and DRAINS it — so
# the loop ran exactly once, for the first roster box, and the remaining boxes
# were never asked at all. Silently: the fingerprint carried one `cron` line
# instead of five and compared equal to itself, the integrity comparison
# reported agreement over one box while claiming the fleet, and #345's log
# collection read one duty.log. That is the same defect codex-bot named in the
# dry-run verdict — a claim wider than the read behind it — one layer further
# down, and it makes "every roster box's crontab" true rather than aspirational.
box_read() { timeout "$BOX_READ_TIMEOUT" box exec "$@" </dev/null; }

# The box's own answer to the integrity question, asked over its own transport.
# `--state` prints ONE bare word — absent, unverified, current or modified
# (shared/bin/engine-manifest.sh's state()) — and probe.sh takes it with the
# same `head -1`, so the two readers ask for the same thing the same way.
#
# The answer is fenced by a marker on BOTH sides of the transport, for the
# reason the `no build duty` read below states: `bash -lc` is a LOGIN shell, so
# a profile that echoes anything puts its line ahead of the verdict, and an
# unfenced `head -1` would then report a banner as the box's integrity. Fenced,
# a talkative box can only make the answer absent, never wrong.
# shellcheck disable=SC2016  # $DUTY_DIR and $HOME are the BOX's, expanded there
box_integrity() {
  box_read "$1" -- bash -lc 'd="${DUTY_DIR:-$HOME/duty}"
    [ -x "$d/bin/engine-manifest.sh" ] || exit 9
    "$d/bin/engine-manifest.sh" --state 2>/dev/null | head -1 | sed "s/^/::state /"' 2>/dev/null \
    | sed -n 's/^::state //p' | head -1 | tr -d '\r\n'
}

app_surface_version    "$FLEET_JSON" "$HOST_VERSION" "$CREW_VERSION_FILE"
app_surface_integrity  "$FLEET_JSON"
# Publishes SURF_NOT_DEPLOYED and SURF_DRAWN, which the page half re-asserts as
# the two numbers the unit and hired tiles render.
app_surface_not_deployed "$FLEET_JSON" "$ROSTER_N"

# ---- the ping tier, against boxes that really answer ----------------------
# stub-box can fake a probe's OUTPUT; it cannot demonstrate that `box exec
# <box> -- true` is a real round-trip into a running guest, which is the whole
# claim the heartbeat rests on. Only a real host has one.
echo
echo "== heartbeat"
PINGED="$(body GET /api/fleet | jqf "sum(1 for u in d['units'] if u.get('ping') and u['ping']['ok'])")"
RUNNING="$(body GET /api/fleet | jqf "sum(1 for u in d['units'] if not (u['note'] or '').startswith(('stopped','not created')))")"
if [ "$RUNNING" -gt 0 ]; then
  t "every running box answers its heartbeat" "$RUNNING" "$PINGED"
  # A real exec round-trip is milliseconds. A plausible-looking 0 would mean
  # the field is being defaulted rather than measured.
  SLOWEST="$(body GET /api/fleet | jqf "max([u['ping']['ms'] for u in d['units'] if u.get('ping') and u['ping']['ok']] or [0])")"
  if [ "$SLOWEST" -gt 0 ] && [ "$SLOWEST" -lt 5000 ]; then
    ok "heartbeat round-trips are real and fast (slowest ${SLOWEST}ms)"
  else
    fail "heartbeat round-trips are real and fast" "slowest=${SLOWEST}ms"
  fi
  # The point of the tier: it must beat the evidence poll, not merely exist.
  # A ping older than the evidence snapshot means the thread is not running.
  STALE="$(body GET /api/fleet | jqf "','.join(u['box'] for u in d['units'] if u.get('ping') and u['ping']['age'] > d['interval'])")"
  t "heartbeats are fresher than the evidence poll" "" "$STALE"
else
  skip "heartbeat" "no running box on this host"
fi

# The ping carries a passenger — /proc/uptime and .duty.lock.since — read by a
# NON-LOGIN `sh -c` inside the guest. probe.sh runs under `bash -lc`, so it has
# never depended on what a non-login exec puts in the environment, and $HOME is
# exactly what `${DUTY_DIR:-$HOME/duty}` needs. If a real box does not set it
# the way this assumes, the passenger silently reads nothing forever and STUCK
# quietly reverts to the 60s tier — a feature that no-ops in production while
# every stub test passes. Only a real guest can settle it.
UPS="$(body GET /api/fleet | jqf "sum(1 for u in d['units'] if u.get('ping') and u['ping']['ok'] and u['ping'].get('uptime'))")"
if [ "$PINGED" -gt 0 ]; then
  t "the ping's passenger reads the real guest" "$PINGED" "$UPS"
else
  skip "the ping's passenger reads the real guest" "no box answered a ping"
fi
# And the two tiers must not disagree about the same file. A box with a run in
# flight is reported by BOTH probe.sh (::lockheld, bash -lc) and the ping
# (non-login sh) — if $HOME differs between them, this is where it shows.
DISAGREE="$(body GET /api/fleet | jqf "','.join(u['box'] for u in d['units'] if u.get('ping') and u['ping']['ok'] and u['lock']['held'] and u['ping'].get('lockheld') is None)")"
t "ping and probe agree about the duty lock" "" "$DISAGREE"

# ---- credentials are READ, never probed -----------------------------------
# The drill is the only place a real `gh` and a real vendor CLI exist, so it is
# the only place that can prove the probe stopped calling them. A reintroduced
# `gh auth status` would cost ~450ms per box per poll and pass every stub test.
echo
echo "== credentials come from the flow"
PROBE_MS="$( { TIMEFORMAT=%R; time box exec "$(body GET /api/fleet | jqf "d['units'][0]['box']")" -- \
  bash -lc "$(cat "$ROOT/fleet-floor/server/probe.sh")" >/dev/null 2>&1 </dev/null; } 2>&1 )"
PROBE_MS="${PROBE_MS%.*}"
if [ -n "$PROBE_MS" ] && [ "$PROBE_MS" -le 3 ]; then
  ok "a real probe costs ${PROBE_MS}s — no network auth call in it"
else
  fail "a real probe makes no network auth call" \
       "took ${PROBE_MS}s; gh auth status alone is ~0.45s per box"
fi
# `ok` was the value that meant "just verified". Nothing may report it again.
OKS="$(body GET /api/fleet | jqf "','.join(u['box'] for u in d['units'] if u['gh']=='ok' or u['vendor']=='ok')")"
t "no box reports the retired 'ok' credential state" "" "$OKS"
# Every box must answer the boolean. `unknown` on a hired box means the engine
# has run without ever recording a credential state, which is the one outcome
# that would leave an operator with nothing to act on.
# `stale` counts: a paused or disarmed box genuinely cannot know, and saying so
# is the actionable answer, not the blank one. Only `unknown` on a box that HAS
# an engine would be the nothing-to-act-on outcome this is guarding against.
# `waiting` counts for the same reason and is the case this drill meets most
# often: every drill box is hired and disarmed before it can tick, so it has no
# duty.log to age (#265). It names a state and the action it implies — wait one
# tick boundary — which is precisely what `unknown` on a hired box cannot do,
# and why widening this set must not stop it biting on `unknown`.
BLANK="$(body GET /api/fleet | jqf "','.join(u['box'] for u in d['units'] if u['engine'] and u['gh'] not in ('flowing','waiting','stale','missing'))")"
t "every hired box reports a gh credential state" "" "$BLANK"

# ---- the operator's view in the CLI (0.1.2 surfaces, #420) -----------------
# The other half of the same window: two `crew` reads and one duty.log line an
# operator acts on, none of them asserted anywhere a real box exists. All three
# are READS — nothing here needs --allow-control, and the fingerprint below is
# what proves the dry run kept that promise.
echo
echo "== the operator's view (0.1.2 CLI surfaces)"

# The fleet as three facts: the roster it read, the boxes that exist, and every
# roster box's crontab. Taken before and after the dry run, so #218's "touches
# nothing" is asserted against the FLEET and not against the command's own
# account of itself.
#
# `crontab -l` is a read, and the read-only receipt guard below deliberately
# does not match it — probe.sh reads the crontab on every poll, so matching it
# would red every read-only walk there has ever been.
# shellcheck disable=SC2016  # the crontab belongs to the BOX, read inside it
# Every line is `<key> <value>`, and the value is the literal `UNREADABLE` when
# the component did not answer. That marker is the whole repair codex-bot asked
# for: a failed `box_read` used to be piped straight into sha256sum, so an
# unreachable box and a timed-out box both fingerprinted as the hash of the
# empty string and compared EQUAL to each other — "unchanged" over two reads
# that never happened. The distinction is available and was being thrown away:
# the inner `crontab -l 2>/dev/null || true` returns 0 for a box that genuinely
# has no crontab, so only a transport failure trips the else.
fleet_fingerprint() {
  local b cron_out
  if [ -r "$ROSTER" ]; then
    sha256sum "$ROSTER" | awk '{print "roster " $1}'
  else
    echo "roster UNREADABLE"
  fi
  box list --json 2>/dev/null | python3 -c \
    "import json,sys;print('boxes ' + (','.join(sorted(str(b.get('name','')) + ':' + str(b.get('status','')) for b in json.load(sys.stdin))) or 'none'))" \
    2>/dev/null || echo "boxes UNREADABLE"
  while read -r b _agent _role _from; do
    [ -z "$b" ] && continue
    if cron_out="$(box_read "$b" -- bash -lc 'crontab -l 2>/dev/null || true' 2>/dev/null)"; then
      printf 'cron %s %s\n' "$b" "$(printf '%s' "$cron_out" | sha256sum | awk '{print $1}')"
    else
      printf 'cron %s UNREADABLE\n' "$b"
    fi
  done < <(roster_rows)
}
fleet_fingerprint > "$TMP/fleet-before.fp"
DRY_RC=0
"$ROOT/cli/crew" up --dry-run > "$TMP/up-dry.txt" 2>&1 || DRY_RC=$?
fleet_fingerprint > "$TMP/fleet-after.fp"
app_surface_dry_run "$TMP/up-dry.txt" "$TMP/fleet-before.fp" "$TMP/fleet-after.fp" "$DRY_RC"

# --- #308: a box that does not ANSWER is unknown, never never-hired ---------
SILENT_BOX="$(app_surface_silent_box "$FLEET_JSON")"
if [ -z "$SILENT_BOX" ]; then
  skip "crew status <box>: an unanswered probe reads unknown, not never-hired" \
       "every box on this fleet answered its probe — no stopped or unreachable box to ask about"
else
  ST_RC=0
  "$ROOT/cli/crew" status "$SILENT_BOX" > "$TMP/status-one.txt" 2>&1 || ST_RC=$?
  app_surface_status_unknown "$SILENT_BOX" "$TMP/status-one.txt" "$ST_RC"
fi

# --- #345: `no build duty` names a cause and a count -----------------------
# The phrase is required on BOTH sides of the transport: the box greps its own
# log, and the host keeps only the lines that carry the phrase. A login shell
# inside a guest may print a banner, an MOTD or a warning of its own, and a line
# this assertion never claimed anything about must not be able to fail it.
NBD_LINES="$TMP/no-build-duty.txt"
: > "$NBD_LINES"
while read -r name _agent _role _from; do
  [ -z "$name" ] && continue
  # shellcheck disable=SC2016  # $DUTY_DIR and $HOME are the BOX's
  box_read "$name" -- bash -lc 'd="${DUTY_DIR:-$HOME/duty}"
    grep -h "no build duty" "$d/duty.log" 2>/dev/null | tail -20' 2>/dev/null \
    | grep -F 'no build duty' | sed "s/^/$name /" >> "$NBD_LINES" || true
done < <(roster_rows)
app_surface_no_build_duty "$NBD_LINES"

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
    control_roster_rows="$(roster_rows)"
    grep -qE "^$b " <<<"$control_roster_rows" || { fail "control $b" "not in $ROSTER"; continue; }

    # ARM FIRST, and record the intent BEFORE acting so a half-applied arm is
    # still disarmed by the trap. Every drill box is disarmed for its whole run
    # by construction, so without this the verbs act on nothing and the block
    # asserts the transport rather than the control (#188). The armed window is
    # about a second against a 5-minute boundary, and the box carries the
    # drill's SANDBOX registry throughout, so even a tick that did fire would
    # act on drill sandbox repos — the harm #26 exists to prevent.
    ARMED_BY_DRILL="$ARMED_BY_DRILL $b"
    if drill_arm_cron "$b" && drill_cron_armed "$b"; then
      ok "arm $b: the tick line is live, so the verbs have something to act on"
    else
      fail "arm $b: the tick line is live" "cannot arm the crontab; the verbs would assert nothing"
      continue
    fi

    # pause/resume is the reversible one, so it is what the drill uses. The
    # assertion is the EFFECT: the box's own crontab, read back over box exec.
    ctl pause "$b"
    if [ "$CTL_CODE" = "200" ]; then
      if drill_cron_paused "$b"; then
        ok "pause $b: crontab line is commented (${CTL_OUT:-no detail})"
      else
        fail "pause $b: crontab line is commented" \
             "no #CREW-FLOOR-PAUSED line in the box; the call said: ${CTL_OUT:-nothing}"
      fi
    else
      fail "pause $b" "HTTP $CTL_CODE — ${CTL_OUT:-no reason in the response}"
    fi

    ctl resume "$b"
    if [ "$CTL_CODE" = "200" ]; then
      if drill_cron_armed "$b"; then
        ok "resume $b: crontab line is live again (${CTL_OUT:-no detail})"
      else
        fail "resume $b: crontab line is live again" \
             "no active tick.sh line after resume; the call said: ${CTL_OUT:-nothing}"
      fi
    else
      fail "resume $b" "HTTP $CTL_CODE — ${CTL_OUT:-no reason in the response}"
    fi

    # Disarm here as well as in the trap. The trap is the guarantee; this is
    # what lets the assertions below be about the drill's own sequence rather
    # than about the net that catches its failures.
    if ! drill_disarm_cron "$b"; then
      fail "disarm $b" "could not disarm the tick line — see the teardown warning"
    fi

    # The third outcome, on real hardware: a box with nothing armed must answer
    # 200 and say so. This is the exact state every drill box was in for its
    # whole run, and the exact call that was reported as `command refused` —
    # `grep -c` exits 1 on a zero count and was the script's last command, so a
    # count of zero became the verdict (#188).
    ctl pause "$b"
    case "$CTL_CODE/$CTL_OUT" in
      200/*"nothing to pause"*)
        ok "pause $b with nothing armed: success, and it says nothing to pause" ;;
      *)
        fail "pause $b with nothing armed: success, and it says nothing to pause" \
             "HTTP $CTL_CODE — ${CTL_OUT:-no reason in the response}" ;;
    esac

    # Replaces a check that looked only for the ABSENCE of a pause marker: it
    # passed on a box that was not armed at all, which is every drill box, so
    # `left armed` was vacuous — it could not have failed. Assert the state the
    # drill actually guarantees, the same fact rehearsal.sh:545 asserts.
    # if-block, never `A && fail || ok`: that shape is how crew#25 shipped a
    # check whose result depended on the exit status of its own reporting.
    if drill_cron_present "$b"; then
      fail "teardown $b: left disarmed" "a tick.sh line is still in the crontab"
    else
      ok "teardown $b: left disarmed"
    fi
  done
fi

# ---- page ----------------------------------------------------------------
if [ "$BROWSER" -eq 1 ]; then
  echo
  echo "== page"
  # TWO preconditions, not one. The module check alone was wrong in a way that
  # cost a real session: playwright-core deliberately ships WITHOUT browsers, so
  # `npm i playwright-core` flipped this branch from a clean skip to a run that
  # died on `no chromium at ~/.cache/ms-playwright/...` — and produced THREE
  # failures, one of which ("read-only walk still exercised the real fleet")
  # points at the wrong subsystem entirely. One missing dependency should not
  # read as a broken floor.
  #
  # And the browser was sitting right there: browser.js only consults PW_CHROME,
  # so a system Chrome is invisible to it unless the operator happens to know
  # that variable. The CI workflow already does this exact probe six lines of
  # shell away; doing it here too makes PW_CHROME an override rather than
  # required knowledge. Google Chrome is preferred over Chromium, same order
  # as CI.
  if [ -z "${PW_CHROME:-}" ]; then
    for _cand in /usr/bin/google-chrome /usr/bin/google-chrome-stable \
                 /opt/google/chrome/chrome /usr/bin/chromium-browser /usr/bin/chromium; do
      if [ -x "$_cand" ]; then PW_CHROME="$_cand"; export PW_CHROME; break; fi
    done
  fi
  if ! node -e "require('playwright-core')" >/dev/null 2>&1; then
    skip "browser walk" "playwright-core not installed (npm i --no-save playwright-core)"
    app_surface_page_skips "playwright-core not installed"
  elif [ -z "${PW_CHROME:-}" ] || [ ! -x "${PW_CHROME:-}" ]; then
    # Named as its own skip: a missing BROWSER is a different repair from a
    # missing module, and the message has to say which one is missing.
    skip "browser walk" "no browser found — install Chrome/Chromium, or set PW_CHROME=/path/to/chrome"
    app_surface_page_skips "no browser found"
  else
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
    echo "   browser: $PW_CHROME"
    echo "   shots:   $SHOTS"
    # Slice the receipt from here, so the drill's own control block above is not
    # counted against the walk.
    RO_FROM=$(( $(wc -l < "$BOX_CALLS") + 1 ))
    # NOT FLOOR_TEST_FIXTURE: this is a real fleet. The walk's fixture-only
    # demands (a hostile-log box, a box in its first session, something offline)
    # are guarantees of test/fixtures/roster.txt, not of a healthy host.
    # FLOOR_TEST_VERSION is the walk's expected header string, the same pairing
    # fleet-floor/test/run.sh makes with CREW_FLOOR_VERSION: the walk asserts the
    # page did not drop or hardcode what the launcher passed. Unset, that
    # assertion compares against `undefined` and can never pass, which is why
    # #347's rendered half has been unreachable from this leg. It is not
    # circular — the drill's own assertion above pins the same string to this
    # tree's VERSION file, so a wrong version fails there.
    if FLOOR_TEST_READONLY=1 FLOOR_TEST_VERSION="$HOST_VERSION" \
       node "$ROOT/fleet-floor/test/browser.js" "http://127.0.0.1:$PORT/" "$SHOTS" "$USER" "$PASSWD" \
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

    # ---- the 0.1.2 surfaces, on the PAGE -------------------------------
    # Two of the four are already asserted by the walk on a live fleet, so they
    # are read out of its output rather than re-implemented here: duplicating
    # the canvas paint interception would put a second copy of the hardest part
    # of browser.js in drill/, and the copy would be the one that rots.
    app_surface_walk_asserted "page: the header renders the serving host's version (#347)" \
                              "floor: the canvas header paints the serving host version" \
                              "$TMP/walk.out"
    app_surface_walk_asserted "page: the engine tile renders its integrity verdict (#190)" \
                              "render: the engine tile carries its integrity verdict" \
                              "$TMP/walk.out"


    # #312 and #204's page halves have no live-fleet assertion in the walk —
    # browser.js pins the filter split to three named fixture boxes under
    # FLOOR_TEST_FIXTURE, which a real host does not have and must not be asked
    # for. So the drill reads the shipped predicate itself: FLOORDEV.matched()
    # reports the set the state chip leaves undimmed, which is the page's own
    # classification rather than a reconstruction of it.
    #
    # Read-only by construction: this clicks the two filter chips, which paint a
    # canvas scrim. It issues no request to /api/command and appears in the
    # receipt slice checked below alongside the walk.
    #
    # The reader is `drill/rehearsal-page-read.js`, IN THE TREE. It was a
    # heredoc into "$TMP" and it could never have passed: node resolves a
    # require from the script's own directory upward, so playwright-core at
    # $ROOT/node_modules — where this repo says to install it — is unreachable
    # from /tmp, and the failure lands as two hard FAILs rather than a skip.
    # The precondition above cannot catch it because `node -e` resolves from
    # the cwd instead. Beside the file it is run with, resolution is ordinary.
    if node "$ROOT/drill/rehearsal-page-read.js" "http://127.0.0.1:$PORT/" "$USER" "$PASSWD" \
         > "$TMP/page-read.json" 2>"$TMP/page-read.err"; then
      app_surface_page_groups "$TMP/page-read.json" "$TMP/status.txt" \
                              "$ROSTER_N" "$SURF_NOT_DEPLOYED" "$SURF_DRAWN" "$FLEET_JSON"
    else
      fail "page: the state filter separates disarmed from silent (#312)" \
           "the page reader did not complete: $(tr '\n' ' ' < "$TMP/page-read.err" | head -c 150)"
      fail "page: the unit tile counts the declared roster and the hired tile the consoles (#204)" \
           "the page reader did not complete — see above"
      fail "page: an all-undeployed floor names the repair verb (#204)" \
           "the page reader did not complete — see above"
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
    # `crontab "$tmp"` is the drill's own arm/disarm shape (#188). It is
    # outside this slice by construction — those calls happen in the control
    # block above and in cleanup below — but a mutation shape the guard cannot
    # see is a hole in it, and the guard's whole value is that it reads the
    # calls rather than trusting the flag. Plain `crontab ` is deliberately not
    # matched: probe.sh reads the crontab on every poll, and matching that
    # would red every read-only walk there has ever been.
    # shellcheck disable=SC2016  # a literal fragment of the calls being matched
    RO_PAT='^(down|start) |\| crontab -|crontab "\$tmp"|BOT_CLI_CMD|floor-prompt'
    RO_BAD=$(grep -cE "$RO_PAT" "$RO_NEW" || true)
    t "read-only walk issued no control command to a real box" 0 "${RO_BAD:-0}"
    if [ "${RO_BAD:-0}" -ne 0 ]; then
      echo "  offending calls:"; grep -nE "$RO_PAT" "$RO_NEW" | head -5
    fi
    # ...and the receipt it read must be a REAL one. Without the wrapper on
    # PATH there is nothing recorded, and "issued no control command" would
    # pass against an empty file forever. THAT is the vacuity worth guarding.
    #
    # This used to count `logstart` probes inside the walk's slice of the
    # receipt, which could never be greater than zero: the collector runs at
    # CREW_FLOOR_INTERVAL=3600 here, so it polls the boxes ONCE, at startup,
    # long before RO_FROM is taken — and the walk reads its cached answer over
    # HTTP without touching the box layer at all. So the check measured
    # something structurally impossible and failed a walk that had just made 15
    # assertions against a live fleet. Same defect as #50, inverted: a premise
    # that does not hold, stated as a verdict.
    #
    # The walk's own non-vacuity is already asserted, correctly, by WALK_N
    # above — its reported assertion count is evidence the drill can actually
    # observe. This checks the other half: that the receipt mechanism is live.
    ALL_CALLS=$(grep -c . "$BOX_CALLS" || true)
    if [ "${ALL_CALLS:-0}" -gt 0 ]; then
      ok "the box-call receipt is real (${ALL_CALLS} calls recorded this run)"
    else
      fail "the box-call receipt is real" \
           "nothing recorded — the logging wrapper is not on PATH, so the no-control check above proves nothing"
    fi
  fi
else
  app_surface_page_skips "--no-browser"
fi

echo
echo "== app rehearsal summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILS[@]}"
  exit 1
fi
exit 0
