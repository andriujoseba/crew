# shellcheck shell=bash  # sourced by run.sh, so it has no shebang of its own
# fleet-floor/test/cases.sh — sourced by run.sh, which provides ok/fail/t/api/
# body/status/unit/uf and a running collector on $PORT backed by stub-box.
#
# Grouped by the loop that added them. Each group exists because something was
# actually wrong, or because a state was renderable in production that nothing
# here could reach — the header on each says which.

# ===========================================================================
# LOOP 1 — the shape the collector must produce, and the states it must not
# collapse. A fleet where every box is healthy would pass a broken renderer.
# ===========================================================================
echo "== telemetry"
t "fleet: every roster box present"  15 "$(body GET /api/fleet | jqf "len(d['units'])")"
t "fleet: reports live"            True "$(body GET /api/fleet | jqf "d['live']")"

t "state: open session -> working" working  "$(uf ff-working "u['state']")"
t "state: no open session -> idle" idle     "$(uf ff-idle    "u['state']")"
t "state: cron silent -> offline"  offline  "$(uf ff-silent  "u['state']")"
t "state: paused -> offline"       offline  "$(uf ff-paused  "u['state']")"
t "state: stopped -> offline"      offline  "$(uf ff-stopped "u['state']")"
t "state: unreachable -> offline"  offline  "$(uf ff-unreach "u['state']")"

# A box that is down must say WHY. "offline" with no reason is the failure
# mode that makes a fleet console useless during an incident.
for b in ff-silent ff-paused ff-stopped ff-unreach ff-nothired; do
  n="$(uf "$b" "u['note']")"
  if [ -n "$n" ] && [ "$n" != "None" ]; then ok "note: $b explains itself"
  else fail "note: $b explains itself" "note was empty"; fi
done
case "$(uf ff-stopped "u['note']")" in *"crew up"*) ok "note: stopped names the fix" ;;
  *) fail "note: stopped names the fix" "$(uf ff-stopped "u['note']")" ;; esac
case "$(uf ff-nothired "u['note']")" in *"crew hire"*) ok "note: unhired names the fix" ;;
  *) fail "note: unhired names the fix" "$(uf ff-nothired "u['note']")" ;; esac

# A box absent from `box list` is not created yet — it must still appear on the
# floor, or a half-built fleet looks complete.
t "absent box still rendered"  offline "$(uf ff-absent "u['state']")"
case "$(uf ff-absent "u['note']")" in *"crew new"*) ok "note: absent names the fix" ;;
  *) fail "note: absent names the fix" "$(uf ff-absent "u['note']")" ;; esac

echo "== sessions, queue, metrics"
t "sessions: parsed"          1    "$(uf ff-working "len(u['sessions'])")"
t "sessions: rc carried"      0    "$(uf ff-working "u['sessions'][0]['rc']")"
t "sessions: outcome carried" ok   "$(uf ff-working "u['sessions'][0]['out']")"
t "current: open session key" board "$(uf ff-working "u['cur']['key']")"
t "queue: from last tick"     1    "$(uf ff-working "len(u['queue'])")"
t "queue: repo parsed"        heavy-duty/ceremony "$(uf ff-working "u['queue'][0]['repo']")"
t "metrics: success%"         100  "$(uf ff-working "u['success']")"
t "metrics: failing box"      0    "$(uf ff-failing "u['success']")"
t "spark: always 22 buckets"  22   "$(uf ff-working "len(u['spark'])")"
t "vendor probe surfaced"     missing "$(uf ff-noauth "u['vendor']")"

# A box hired seconds ago has NO sessions. This class of bug shipped once
# (`d.sessions[0].rc` on an empty history), so it gets a permanent test.
t "fresh box: no sessions"   0 "$(uf ff-fresh "len(u['sessions'])")"
t "fresh box: no crash"      idle "$(uf ff-fresh "u['state']")"
t "fresh box: zero metrics"  0 "$(uf ff-fresh "u['success']")"
t "fresh box: null cur"      True "$(uf ff-fresh "u['cur'] is None")"

echo "== auth"
t "401: fleet without creds"  401 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/fleet")"
t "401: page without creds"   401 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
t "401: command without creds" 401 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "http://127.0.0.1:$PORT/api/command")"
t "401: logs without creds"   401 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/logs?box=ff-working")"
t "401: wrong password"       401 "$(curl -s -o /dev/null -w '%{http_code}' -u "$USER:wrong" "http://127.0.0.1:$PORT/api/fleet")"
t "200: page with creds"      200 "$(status GET /)"

echo "== control"
t "cmd: pause ok"     200 "$(status POST /api/command '{"action":"pause","box":"ff-working"}')"
t "cmd: pause applied" paused "$(cat "$FLOOR_STATE/ff-working.cron" 2>/dev/null)"
t "cmd: resume ok"    200 "$(status POST /api/command '{"action":"resume","box":"ff-working"}')"
t "cmd: resume applied" resumed "$(cat "$FLOOR_STATE/ff-working.cron" 2>/dev/null)"

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
t "message: prompt delivered via stdin" "$INJECT" "$(cat "$FLOOR_STATE/ff-working.prompt" 2>/dev/null)"

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

echo "== logs endpoint"
t "logs: default tail"        200 "$(status GET '/api/logs?box=ff-working')"
t "logs: unknown box refused" 400 "$(status GET '/api/logs?box=evil')"
t "logs: traversal refused"   400 "$(status GET '/api/logs?box=ff-working&file=../../.ssh/id_rsa')"
t "logs: metachars refused"   400 "$(status GET '/api/logs?box=ff-working&file=x;id')"
t "logs: absolute path refused" 400 "$(status GET '/api/logs?box=ff-working&file=/etc/passwd')"

echo "== routing"
t "404: unknown path"  404 "$(status GET /nope)"
t "404: unknown post"  404 "$(status POST /api/nope '{}')"
t "204: favicon"       204 "$(status GET /favicon.ico)"
t "200: healthz"       200 "$(status GET /healthz)"

# ===========================================================================
# LOOP 4 — the collector's hard edges. A wedged box (box exec that never
# answers) is the one that matters most: it is indistinguishable from a
# healthy one until the timeout fires, and if it stalls the poll then ONE sick
# box blanks the whole console.
# ===========================================================================
echo "== resilience"
t "wedged box does not stall the fleet" 15 "$(body GET /api/fleet | jqf "len(d['units'])")"
t "wedged box -> offline"          offline "$(uf ff-wedged "u['state']")"
case "$(uf ff-wedged "u['note']")" in *timed\ out*|*unreachable*) ok "wedged box says it timed out" ;;
  *) fail "wedged box says it timed out" "$(uf ff-wedged "u['note']")" ;; esac
# The healthy boxes in the same poll must be unaffected — the probe threads
# are what make that true, and a regression to a serial poll would show here.
t "healthy box survives a wedged peer" working "$(uf ff-working "u['state']")"

# A duty.log full of junk must not take the collector down. The floor is the
# thing you look at WHEN things are broken; it cannot be fragile about it.
t "garbage log: still rendered"  True "$(uf ff-garbage "u['box']=='ff-garbage'")"
t "garbage log: no crash"        True "$(uf ff-garbage "u['state'] in ('idle','working','offline')")"
t "garbage log: metrics sane"    True "$(uf ff-garbage "isinstance(u['success'],int) and 0<=u['success']<=100")"

echo "== http hygiene"
t "413: oversized body refused" 413 "$(python3 - <<'PY'
import urllib.request,base64,os,json
big=json.dumps({"action":"message","box":"ff-working","prompt":"x"*100000})
req=urllib.request.Request(f"http://127.0.0.1:{os.environ['PORT']}/api/command",data=big.encode(),method="POST")
req.add_header("Authorization","Basic "+base64.b64encode(f"{os.environ['USER']}:{os.environ['PASSWD']}".encode()).decode())
req.add_header("Content-Type","application/json")
try:
    print(urllib.request.urlopen(req,timeout=10).status)
except urllib.error.HTTPError as e:
    print(e.code)
PY
)"
t "401: malformed auth header" 401 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' "http://127.0.0.1:$PORT/api/fleet")"
t "401: empty auth header"     401 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization:' "http://127.0.0.1:$PORT/api/fleet")"
t "401: basic with junk b64"   401 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Basic !!!!' "http://127.0.0.1:$PORT/api/fleet")"
# A write verb on a read route must not be treated as the read.
t "405: PUT is rejected"        405 "$(status PUT /api/fleet)"
t "405: DELETE is rejected"     405 "$(status DELETE /api/command)"
t "404: GET on /api/command"    404 "$(status GET /api/command)"
# An unimplemented method must still hit the auth gate, not answer from inside
# the server's own request loop before any check runs.
t "401: PUT without creds"     401 "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$PORT/api/fleet")"
t "401: DELETE without creds"  401 "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "http://127.0.0.1:$PORT/api/command")"

echo "== concurrency"
# Fired from python, not backgrounded subshells: a `( ... ) &` in bash inherits
# the parent's EXIT trap, so the first one to finish runs cleanup(), kills the
# collector and deletes $TMP out from under the rest of the suite. That cost a
# debugging cycle; it is not worth re-learning.
CONC="$(python3 - <<'PY_CONC'
import base64, json, os, threading, urllib.request, urllib.error
port, user, pw = os.environ["PORT"], os.environ["USER"], os.environ["PASSWD"]
auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
codes = []
lock = threading.Lock()

def hit():
    body = json.dumps({"action": "pause", "box": "ff-idle"}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/command", data=body, method="POST")
    req.add_header("Authorization", auth)
    req.add_header("Content-Type", "application/json")
    try:
        c = urllib.request.urlopen(req, timeout=30).status
    except urllib.error.HTTPError as e:
        c = e.code
    except Exception:
        c = 0
    with lock:
        codes.append(c)

ts = [threading.Thread(target=hit) for _ in range(5)]
[t.start() for t in ts]
[t.join(60) for t in ts]
print(sum(1 for c in codes if c == 200))
PY_CONC
)"
t "5 concurrent commands all answered 200" 5 "$CONC"
t "fleet still served during load" 200 "$(status GET /api/fleet)"
# The coalescing refresh must not have left a poll wedged behind it.
t "fleet still complete after load" 15 "$(body GET /api/fleet | jqf "len(d['units'])")"

# ===========================================================================
# LOOP 5 — what the page does when the COLLECTOR is the thing that broke.
# The browser side of this is test/stale.js; these are the collector-side
# facts it depends on.
# ===========================================================================
echo "== snapshot honesty"
# The page decides staleness from this, so it has to be there and it has to be
# a real timestamp.
case "$(body GET /api/fleet | jqf "d['generated']")" in
  20[0-9][0-9]-[0-9][0-9]-*T*Z) ok "fleet: snapshot carries a generated stamp" ;;
  *) fail "fleet: snapshot carries a generated stamp" "$(body GET /api/fleet | jqf "d['generated']")" ;;
esac
t "fleet: snapshot advertises the poll interval" True \
  "$(body GET /api/fleet | jqf "isinstance(d.get('interval'),int) and d['interval']>0")"
# Every unit must be JSON-serialisable and complete — a missing key is a
# TypeError in the page, several panels deep, long after the poll that caused it.
t "fleet: every unit has the full shape" True "$(body GET /api/fleet | jqf "
all(set(('box','agent','room','state','engine','gh','vendor','queue','sessions',
         'cur','spark','up','repo','repos','logs','longest','avg','success',
         'today','paused','cron','note')) <= set(u) for u in d['units'])")"
t "fleet: cron sub-shape complete" True "$(body GET /api/fleet | jqf "
all(set(('ok','last','age')) <= set(u['cron']) for u in d['units'])")"

# ===========================================================================
# ROUND 10 — the two bugs the review panel found that 136 checks did not, and
# the fixture flaw that let them through. Both trace to ONE root cause: the
# stub emitted BARE repo names ("ceremony") where repos.txt and duty.log both
# carry a full owner/repo ("heavy-duty/ceremony"), so the assertions were
# written against data production never produces.
# ===========================================================================
echo "== real data shapes"
t "repos are full owner/repo" True "$(uf ff-working "all('/' in r for r in u['repos'])")"
t "queue repo is a full owner/repo" True "$(uf ff-working "'/' in u['queue'][0]['repo']")"
t "unit repo is a full owner/repo"  True "$(uf ff-working "'/' in u['repo']")"

# A box inside its FIRST session: cur is set, sessions is empty. floor.py sets
# state=working whenever cur exists, so this is ordinary live telemetry — and
# it is the state that crashed the room's diagnostic hologram.
t "first-run box: is working"        working "$(uf ff-firstrun "u['state']")"
t "first-run box: has an open session" True  "$(uf ff-firstrun "u['cur'] is not None")"
t "first-run box: has NO history"       0    "$(uf ff-firstrun "len(u['sessions'])")"

# `wake-silent` on a fleet with nothing silent must not read as a failure.
# Wake everything first, so the second call genuinely has nothing to do.
status POST /api/command '{"action":"start-all"}' >/dev/null
WS_BODY="$(body POST /api/command '{"action":"wake-silent"}')"
WS_CODE="$(status POST /api/command '{"action":"wake-silent"}')"
if [ "$WS_CODE" = "200" ] || printf '%s' "$WS_BODY" | grep -q '"results"'; then
  ok "wake-silent always reports per-box results"
else
  fail "wake-silent always reports per-box results" "$WS_CODE $WS_BODY"
fi

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
  _got="$(sed -n 's/^PROMPT=\[\(.*\)\]$/\1/p' "$_log")"
  [ "$_got" = "$_staged" ] || CM_BAD="$CM_BAD token=$_tok:staged[$_staged]!=delivered[$_got]"
done
if [ -z "$CM_BAD" ] && [ "$CM_STAGED" -eq 5 ]; then
  ok "each token's session ran exactly that token's prompt (1:1)"
else
  fail "each token's session ran exactly that token's prompt (1:1)" "${CM_BAD:-no tokens staged}"
fi
