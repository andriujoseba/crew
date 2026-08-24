# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/actions.sh — the suite for fleet-floor/server/floor/actions.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the twelve members
# that edit these files still queue behind one test file.
#
# Subject: POST /api/command — every operator verb, what it reports when it
# had nothing to do, and the two races that put one operator's prompt in
# another's session.

echo "== control"
t "cmd: pause ok"     200 "$(status POST /api/command '{"action":"pause","box":"ff-working"}')"
t "cmd: pause applied" paused "$(cat "$FLOOR_STATE/ff-working.cron" 2>/dev/null)"
t "cmd: resume ok"    200 "$(status POST /api/command '{"action":"resume","box":"ff-working"}')"
t "cmd: resume applied" resumed "$(cat "$FLOOR_STATE/ff-working.cron" 2>/dev/null)"
# The verb says what it DID, so the console can tell a control that took effect
# from one that had nothing to do. Asserted on the per-box `out` the page and
# the drill both read, not on the status code alone — the status code is what
# was already wrong.
case "$(body POST /api/command '{"action":"pause","box":"ff-working"}')" in
  *"paused 1"*) ok "cmd: pause reports what it did" ;;
  *) fail "cmd: pause reports what it did" "$(body POST /api/command '{"action":"pause","box":"ff-working"}')" ;;
esac
status POST /api/command '{"action":"resume","box":"ff-working"}' >/dev/null

# #188 — a box with no armed tick.sh line has NOTHING to pause, and that is a
# success. It answered 500 "command refused", because PAUSE_SH ended on a
# `grep -c` and `grep -c` exits 1 on a zero count. Every drill box is in
# exactly this state by design (drill/rehearsal.sh disarms before any tick),
# which is why the whole control block on a real host was red.
t "cmd: pause on a disarmed box is not a refusal" 200 \
  "$(status POST /api/command '{"action":"pause","box":"ff-disarmed"}')"
case "$(body POST /api/command '{"action":"pause","box":"ff-disarmed"}')" in
  *"nothing to pause"*) ok "cmd: pause on a disarmed box says nothing to pause" ;;
  *) fail "cmd: pause on a disarmed box says nothing to pause" \
          "$(body POST /api/command '{"action":"pause","box":"ff-disarmed"}')" ;;
esac
# And it must not have invented a state change to report success with.
t "cmd: pause on a disarmed box changes nothing" "" \
  "$(cat "$FLOOR_STATE/ff-disarmed.cron" 2>/dev/null)"
# The same rule on the other verb: ff-working was resumed above, so there is no
# commented line left for RESUME_SH to restore.
t "cmd: resume with nothing paused is not a refusal" 200 \
  "$(status POST /api/command '{"action":"resume","box":"ff-working"}')"
case "$(body POST /api/command '{"action":"resume","box":"ff-working"}')" in
  *"nothing to resume"*) ok "cmd: resume with nothing paused says so" ;;
  *) fail "cmd: resume with nothing paused says so" \
          "$(body POST /api/command '{"action":"resume","box":"ff-working"}')" ;;
esac

t "cmd: power-off ok" 200 "$(status POST /api/command '{"action":"power-off","box":"ff-idle"}')"
t "cmd: power-off applied" stopped "$(cat "$FLOOR_STATE/ff-idle.state" 2>/dev/null)"
t "cmd: power-on ok"  200 "$(status POST /api/command '{"action":"power-on","box":"ff-idle"}')"
t "cmd: power-on applied" running "$(cat "$FLOOR_STATE/ff-idle.state" 2>/dev/null)"
t "cmd: restart ok"   200 "$(status POST /api/command '{"action":"restart","box":"ff-idle"}')"
t "cmd: restart ends running" running "$(cat "$FLOOR_STATE/ff-idle.state" 2>/dev/null)"

# The prompt must reach the box as stdin bytes, never as part of a command
# line. This is the one that must never regress.
# The payload goes to python through the ENVIRONMENT, never through a
# double-quoted bash string: interpolating it would let bash expand $(id) and
# the backticks here, and the test would then be sending something tamer than
# it claims to.
# The quotes and backticks are the POINT: this must stay a literal payload all
# the way into the box, so bash must not expand or re-quote any of it here.
# shellcheck disable=SC2016,SC2089,SC2090
INJECT='hi"; touch /tmp/floor-pwned; echo "$(id)`whoami`'
# shellcheck disable=SC2090
export INJECT
status POST /api/command "$(python3 -c 'import json,os
print(json.dumps({"action":"message","box":"ff-working","prompt":os.environ["INJECT"]}))')" >/dev/null
if [ -e /tmp/floor-pwned ]; then fail "message: prompt cannot inject" "/tmp/floor-pwned was created"; rm -f /tmp/floor-pwned
else ok "message: prompt cannot inject"; fi
if grep -q 'floor-pwned' "$FLOOR_CALLS"; then fail "message: prompt never in argv" "found in call log"
else ok "message: prompt never in argv"; fi
t "message: envelope and prompt delivered via stdin" \
  "$(cat "$FLOOR/../shared/prompts/fragment-floor-envelope.txt")
$INJECT" \
  "$(cat "$FLOOR_STATE/ff-working.prompt" 2>/dev/null)"

t "cmd: unknown box refused"    400 "$(status POST /api/command '{"action":"pause","box":"nope"}')"
t "cmd: unknown action refused" 400 "$(status POST /api/command '{"action":"rm -rf","box":"ff-working"}')"
t "cmd: empty prompt refused"   400 "$(status POST /api/command '{"action":"message","box":"ff-working","prompt":"   "}')"
t "cmd: bad json refused"       400 "$(status POST /api/command '{oops')"
# A control aimed at a box that cannot run it must be REPORTED, not swallowed.
t "cmd: unreachable box -> 500"  500 "$(status POST /api/command '{"action":"pause","box":"ff-unreach"}')"
case "$(body POST /api/command '{"action":"pause","box":"ff-unreach"}')" in
  *"not running"*) ok "cmd: failure carries the reason" ;;
  *) fail "cmd: failure carries the reason" "$(body POST /api/command '{"action":"pause","box":"ff-unreach"}')" ;;
esac

# `wake-silent` on a fleet with nothing silent must not read as a failure.
# Wake everything first, so the second call genuinely has nothing to do.
status POST /api/command '{"action":"start-all"}' >/dev/null
WS_BODY="$(body POST /api/command '{"action":"wake-silent"}')"
WS_CODE="$(status POST /api/command '{"action":"wake-silent"}')"
if [ "$WS_CODE" = "200" ] || grep -q '"results"' <<<"$WS_BODY"; then
  ok "wake-silent always reports per-box results"
else
  fail "wake-silent always reports per-box results" "$WS_CODE $WS_BODY"
fi

# #189 — wake-silent must not try to wake a box it CANNOT wake. A disarmed box
# has no commented crontab line for RESUME_SH to restore, so the call did
# nothing and then reported a failed row, because `grep -c` exits 1 on a zero
# count (#188). Arming is `crew hire`, on the host — not a console action.
#
# The `not paused` half of the guard is the load-bearing half: pausing zeroes
# the cron count too, so a paused box is disarmed, and it is exactly the box
# this action exists to wake. Guard on `disarmed` alone and wake-silent stops
# doing the one thing it is for.
rm -f "$FLOOR_STATE/ff-disarmed.cron" "$FLOOR_STATE/ff-paused.cron"
status POST /api/command '{"action":"pause","box":"ff-paused"}' >/dev/null
# request_refresh polls in a BACKGROUND thread, so the snapshot wake-silent
# reads is NOT updated by the time the pause call returns — and wake-silent
# decides entirely from that snapshot. Wait for the fact to arrive rather than
# sleeping a guessed interval; the test server polls on a 3600s cycle, so a
# guess would have to be luck.
for _ in $(seq 1 60); do
  [ "$(uf ff-paused "u['paused']")" = "True" ] && break
  sleep 0.5
done
status POST /api/command '{"action":"wake-silent"}' >/dev/null
t "wake-silent: resumes a PAUSED box"   resumed "$(cat "$FLOOR_STATE/ff-paused.cron" 2>/dev/null)"
t "wake-silent: leaves a DISARMED box alone" "" "$(cat "$FLOOR_STATE/ff-disarmed.cron" 2>/dev/null)"

# ===========================================================================
# ROUND 11 — codex-bot: two rapid messages to ONE box could interleave, and a
# session would run the OTHER request's prompt. Production bug, not a test
# one. The earlier concurrency case sent only `pause`, and the box-side test
# sent one message at a time, so neither could reach it.
# ===========================================================================
echo "== concurrent messages keep their own bytes"
# Isolate this round: an earlier sequential message test left its own prompt
# file and log behind, which is why an aggregate count once read 6-for-5.
CM_HOME="$FLOOR_STATE/ff-working.home"
rm -f "$FLOOR_STATE"/ff-working.prompt.* 2>/dev/null
rm -f "$CM_HOME"/duty/logs/*operator-floor* 2>/dev/null

CM_OUT="$(python3 - <<'PY_CM'
import base64, json, os, threading, urllib.request, urllib.error
port, user, pw = os.environ["PORT"], os.environ["USER"], os.environ["PASSWD"]
auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
# Distinct, individually identifiable payloads to the SAME box at once.
prompts = [f"PROMPT-{i}-" + ("x" * (20 + i)) for i in range(5)]
codes = []
lock = threading.Lock()

def hit(p):
    body = json.dumps({"action": "message", "box": "ff-working", "prompt": p}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/command", data=body, method="POST")
    req.add_header("Authorization", auth)
    req.add_header("Content-Type", "application/json")
    try:
        c = urllib.request.urlopen(req, timeout=60).status
    except urllib.error.HTTPError as e:
        c = e.code
    except Exception:
        c = 0
    with lock:
        codes.append(c)

ts = [threading.Thread(target=hit, args=(p,)) for p in prompts]
[t.start() for t in ts]
[t.join(90) for t in ts]
print(sum(1 for c in codes if c == 200))
PY_CM
)"
t "5 concurrent messages all accepted" 5 "$CM_OUT"

# Wait for the detached sessions to land their logs.
for _ in $(seq 1 40); do
  [ "$(find "$CM_HOME/duty/logs" -name '*operator-floor*' 2>/dev/null | wc -l)" -ge 5 ] && break
  sleep 0.5
done

# EXACTLY five, not "at least": a stray log means the population under test is
# not the one this case created.
CM_LOGS=$(find "$CM_HOME/duty/logs" -name '*operator-floor*' 2>/dev/null | wc -l)
t "exactly five session logs" 5 "$CM_LOGS"

CM_STAGED=0
for f in "$FLOOR_STATE"/ff-working.prompt.*; do
  case "$f" in *'*') continue ;; esac
  [ -f "$f" ] && CM_STAGED=$((CM_STAGED + 1))
done
t "each message staged its own prompt file" 5 "$CM_STAGED"

# The decisive check, PER TOKEN. Comparing the SET of prompts staged against
# the SET delivered is not the property claimed: if session A runs B's prompt
# and B runs A's — the exact cross-request swap this case exists for — the two
# sets are identical and every aggregate assertion passes. Correlate instead:
# each staged token must have exactly one log bearing THAT token, carrying
# THAT token's bytes.
CM_BAD=""
for f in "$FLOOR_STATE"/ff-working.prompt.*; do
  case "$f" in *'*') continue ;; esac
  [ -f "$f" ] || continue
  _tok="${f##*.}"
  _staged="$(cat "$f")"
  _n=$(find "$CM_HOME/duty/logs" -name "*operator-floor-$_tok.log" 2>/dev/null | wc -l)
  if [ "$_n" -ne 1 ]; then
    CM_BAD="$CM_BAD token=$_tok:logs=$_n"
    continue
  fi
  _log=$(find "$CM_HOME/duty/logs" -name "*operator-floor-$_tok.log" 2>/dev/null | head -1)
  _got="$(sed '1s/^PROMPT=\[//; $s/]$//' "$_log")"
  [ "$_got" = "$_staged" ] || CM_BAD="$CM_BAD token=$_tok:staged[$_staged]!=delivered[$_got]"
done
if [ -z "$CM_BAD" ] && [ "$CM_STAGED" -eq 5 ]; then
  ok "each token's session ran exactly that token's prompt (1:1)"
else
  fail "each token's session ran exactly that token's prompt (1:1)" "${CM_BAD:-no tokens staged}"
fi
