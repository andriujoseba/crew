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
t "fleet: every roster box present"  24 "$(body GET /api/fleet | jqf "len(d['units'])")"
t "fleet: reports live"            True "$(body GET /api/fleet | jqf "d['live']")"

t "state: open session -> working" working  "$(uf ff-working "u['state']")"
t "state: no open session -> idle" idle     "$(uf ff-idle    "u['state']")"
t "state: cron silent -> offline"  offline  "$(uf ff-silent  "u['state']")"
t "clock: three-hours-behind healthy box is not silent" False "$(uf ff-skew-behind "u['state'] == 'offline'")"
t "clock: three-hours-ahead healthy box is not silent"  False "$(uf ff-skew-ahead  "u['state'] == 'offline'")"
t "clock: cron age comes from box-side tickage" 110 "$(uf ff-skew-behind "u['cron']['age']")"
t "clock: session age survives negative skew" 10 "$(uf ff-skew-behind "u['sessions'][0]['ago']")"
t "clock: session age survives positive skew" 10 "$(uf ff-skew-ahead "u['sessions'][0]['ago']")"
t "clock: negative-skew session lands in newest spark bucket" 1.0 "$(uf ff-skew-behind "u['spark'][21]")"
t "clock: positive-skew session lands in newest spark bucket" 1.0 "$(uf ff-skew-ahead "u['spark'][21]")"
t "clock: displayed last tick is on host timeline" True "$(uf ff-skew-behind "__import__('time').time() - __import__('datetime').datetime.strptime(u['cron']['last'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=__import__('datetime').timezone.utc).timestamp() < 120")"
t "clock: skewed stopped box behind is silent" offline "$(uf ff-skew-silent-behind "u['state']")"
t "clock: skewed stopped box ahead is silent" offline "$(uf ff-skew-silent-ahead "u['state']")"
t "clock: invalid tickage never invents cron freshness" False "$(uf ff-invalid-age "u['cron']['ok']")"
t "clock: invalid tickage leaves cron age unknown" None "$(uf ff-invalid-age "u['cron']['age']")"
t "clock: missing tickage never invents cron freshness" False "$(uf ff-missing-age "u['cron']['ok']")"
t "clock: missing tickage leaves cron age unknown" None "$(uf ff-missing-age "u['cron']['age']")"
case "$(uf ff-missing-age "u['note']")" in *unknown*) ok "clock: missing tickage renders unknown, not SILENT" ;;
  *) fail "clock: missing tickage renders unknown, not SILENT" "$(uf ff-missing-age "u['note']")" ;; esac
# Execute the same classifier sourced by the real-host drill. A Floor state
# assertion alone cannot prove that the comparison increments instead of skips.
# shellcheck source=drill/agreement.sh disable=SC1091
source "$FLOOR/../drill/agreement.sh"
t "agreement: skewed box reaches the real up-comparison branch" up \
  "$(agreement_case "$(uf ff-skew-behind "u['state']")" 'ff-skew-behind running' '' False)"
if awk '/^def build_unit/,/^def fmt_dur/' "$FLOOR/server/floor.py" | grep -q 'now - last_ts'; then
  fail "clock: unit building never mixes host now with a box timestamp" \
       "found the skew-sensitive subtraction 'now - last_ts'"
else
  ok "clock: unit building never mixes host now with a box timestamp"
fi
t "state: paused -> offline"       offline  "$(uf ff-paused  "u['state']")"
t "state: stopped -> offline"      offline  "$(uf ff-stopped "u['state']")"
t "state: unreachable -> offline"  offline  "$(uf ff-unreach "u['state']")"
t "state: disarmed -> offline"     offline  "$(uf ff-disarmed "u['state']")"

# ---------------------------------------------------------------------------
# #189 — DISARMED is not SILENT. probe.sh has always emitted ::cron; nothing
# consumed it on a box that had ever ticked, so a box whose crontab holds no
# live tick.sh line fell through to "SILENT — no tick for 66m". SILENT is an
# alarm meaning "this box should be ticking and is not"; spending it on a box
# nobody armed is how the drill's floor-vs-CLI agreement check skipped five
# consecutive runs, and how an operator learns to ignore the word.
# ---------------------------------------------------------------------------
t "wire: disarmed box carries the flag"  True  "$(uf ff-disarmed "u['disarmed']")"
t "wire: an armed box does not"         False  "$(uf ff-silent   "u['disarmed']")"
# Pausing comments the line out, so a paused box IS disarmed. Kept as two
# values rather than one tri-state: a caller asking "can this box tick at all"
# must not have to know that paused implies disarmed.
t "wire: paused implies disarmed"        True  "$(uf ff-paused   "u['disarmed']")"
case "$(uf ff-disarmed "u['note']")" in
  *SILENT*) fail "note: disarmed is not reported as SILENT" "$(uf ff-disarmed "u['note']")" ;;
  *disarmed*"crew hire"*) ok "note: disarmed names crew hire, not SILENT" ;;
  *) fail "note: disarmed names crew hire, not SILENT" "$(uf ff-disarmed "u['note']")" ;;
esac
# The alarm must survive: an armed box that stopped ticking is still SILENT.
case "$(uf ff-silent "u['note']")" in *SILENT*) ok "note: an armed box that stopped is still SILENT" ;;
  *) fail "note: an armed box that stopped is still SILENT" "$(uf ff-silent "u['note']")" ;; esac
# Paused wins the note over disarmed: both are true, and "the operator did
# this, here is how to undo it" is the more useful sentence.
case "$(uf ff-paused "u['note']")" in *paused*) ok "note: paused outranks disarmed" ;;
  *) fail "note: paused outranks disarmed" "$(uf ff-paused "u['note']")" ;; esac

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
t "wedged box does not stall the fleet" 24 "$(body GET /api/fleet | jqf "len(d['units'])")"
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
t "fleet still complete after load" 24 "$(body GET /api/fleet | jqf "len(d['units'])")"

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
         'today','paused','disarmed','cron','note')) <= set(u) for u in d['units'])")"
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

# --- the ping tier, the stuck lock, and flow-reported credentials ----------
# Round: the 60s evidence poll answered three questions at one cadence, one of
# them over the network. These assert the three now arrive separately.

# The ping tier runs on its own thread and overlays the snapshot at read time,
# so a healthy box reports a round-trip without the evidence poll re-running.
# A wedged box fails BOTH tiers, and the two facts must not overwrite each
# other. The probe's "timed out after Ns" is the diagnostic one; the ping count
# is the timely one. Replacing the first with the second made the note depend
# on how many misses had accumulated, so CI and a laptop disagreed about the
# same fleet.
CS_WDL=$(( $(date +%s) + 40 ))
while [ "$(uf ff-wedged 'u["ping"] is not None and not u["ping"]["ok"]')" != "True" ] \
      && [ "$(date +%s)" -lt "$CS_WDL" ]; do sleep 1; done
t "wedged: the probe's reason survives the ping overlay" True \
  "$(uf ff-wedged '"timed out" in u["note"] or "unreachable" in u["note"].lower()')"
t "wedged: the ping fact is added too" True \
  "$(uf ff-wedged '"UNREACHABLE" in u["note"] or "timed out" in u["note"]')"

t "ping: a healthy box reports a round-trip" True "$(uf ff-working 'u["ping"] is not None and u["ping"]["ok"]')"

# THE sharp edge of carrying a passenger. `.duty.lock.since` is absent whenever
# no duty run is in flight — the normal state of a healthy idle box — and `cat`
# on a missing file exits 1. Without the explicit `exit 0`, every healthy box
# would fail three pings and render UNREACHABLE. This is the assertion that
# would have caught it, so it is checked across the WHOLE fleet rather than on
# one box.
t "ping: boxes with no lock file still ping ok" "" \
  "$(body GET /api/fleet | jqf "','.join(u['box'] for u in d['units'] if u.get('ping') and not u['ping']['ok'] and u['box'] not in ('ff-unreach','ff-wedged'))")"

# The passenger's payoff: STUCK is now seen on the 10s ping clock instead of
# waiting up to a full 60s evidence poll.
t "ping: a stuck lock is caught by the heartbeat" True "$(uf ff-stuck 'u["lock"]["stuck"]')"

# The last hop: collected -> used server-side -> SERVED. The passenger drove
# the STUCK escalation while never reaching the wire, so rehearsal-app.sh read
# ping.uptime/ping.lockheld and got None on every real host. boxside proves the
# script emits it and that parse_ping reads it; only this proves an operator
# (or the drill) can see it.
t "ping: the passenger is served, not just used" True \
  "$(uf ff-working 'u["ping"] is not None and "uptime" in u["ping"] and "lockheld" in u["ping"]')"
t "ping: the served uptime is real"   True "$(uf ff-working 'isinstance(u["ping"]["uptime"], int)')"
t "ping: the served lock age is real" 2820 "$(uf ff-stuck 'u["ping"]["lockheld"]')"
# A run that started moments ago must be served as a small age and NOT stuck —
# the raw-timestamp bug marked exactly this case STUCK for 495881h.
t "ping: a fresh run is served as a small age" 12 "$(uf ff-working 'u["ping"]["lockheld"]')"
t "ping: ...and is not escalated"          False "$(uf ff-working 'u["lock"]["stuck"]')"
# ...and it only ever escalates. A ping that read nothing must not clear or
# contradict what the evidence tier concluded.
t "ping: a healthy box is not marked stuck by its passenger" False "$(uf ff-working 'u["lock"]["stuck"]')"
t "ping: the round-trip is measured, not asserted" True "$(uf ff-working 'isinstance(u["ping"]["ms"], int)')"

# The state a ping exists to catch. `unreachable` fails its exec, so after
# FLOOR_TEST_PING_FAILS consecutive misses the overlay must override whatever
# the last evidence poll concluded — a session that was running cannot be
# progressing inside a guest that no longer answers.
CS_DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(uf ff-unreach 'u["ping"] is not None and not u["ping"]["ok"]')" != "True" ] \
      && [ "$(date +%s)" -lt "$CS_DEADLINE" ]; do sleep 1; done
t "ping: an unreachable box is caught by the heartbeat" True \
  "$(uf ff-unreach 'u["ping"] is not None and not u["ping"]["ok"]')"
t "ping: consecutive misses are counted, not just the last one" True \
  "$(uf ff-unreach 'u["ping"]["fails"] >= 1')"

# A box that is stopped or was never created must NOT be pinged: `box exec`
# into it fails for a reason the operator already knows, and counting that as
# a wedge paints every deliberately-down box red.
#
# Asserted over whatever the fleet looks like RIGHT NOW rather than against
# ff-stopped by name: the control cases above run start-all, so by this point
# the fixture's stopped box is running, and a by-name check here passed or
# failed on test ordering rather than on behaviour.
t "ping: stopped and absent boxes are skipped, not counted as wedged" "" \
  "$(body GET /api/fleet | jqf "','.join(u['box'] for u in d['units'] if (u['note'].startswith('stopped') or u['note'].startswith('not created')) and u['ping'] is not None)")"

# The wedge the SILENT rule cannot see: cron ticking, duty.log fresh, lock held
# for 47 minutes. It stays `working` — it genuinely is — and says so loudly.
t "stuck: a long-held lock is flagged"        True    "$(uf ff-stuck 'u["lock"]["stuck"]')"
t "stuck: the box is still reported working"  working "$(uf ff-stuck 'u["state"]')"
t "stuck: the note names the duration"        True    "$(uf ff-stuck '"STUCK" in u["note"]')"
t "stuck: a healthy box is not stuck"         False   "$(uf ff-working 'u["lock"]["stuck"]')"

# Credentials are read, never tested. `flowing` is a third value: it means the
# engine has been talking to the service and has not been rejected — NOT that
# anything just verified a token.
t "creds: a healthy box reports flowing"  flowing "$(uf ff-working 'u["gh"]')"
t "creds: no box ever reports ok"         True    "$(uf ff-working 'u["gh"] != "ok"')"
t "creds: a rejection is reported missing" missing "$(uf ff-noauth 'u["gh"]')"
t "creds: the rejection carries its reason" True  "$(uf ff-noauth 'any("gh:" in a for a in u["authfail"])')"
t "creds: an unhired box knows nothing"   unknown "$(uf ff-nothired 'u["gh"]')"
# The fourth state: installed, not ticking, therefore nothing established.
# Reporting `flowing` here would call a disarmed box with a dead token healthy.
t "creds: a box that stopped ticking is stale, not flowing" stale "$(uf ff-silent 'u["gh"]')"
# The fifth (#265). `stale` means "we heard from this box and no longer do";
# nobody has heard from a never-ticked one at all, and the operator's action
# differs — wait a tick boundary, versus go find out what broke.
t "creds: a never-ticked box is waiting, not stale"  waiting "$(uf ff-neverticked 'u["gh"]')"
t "creds: waiting applies to both services"          waiting "$(uf ff-neverticked 'u["vendor"]')"
# THE REGRESSION THAT MATTERS MORE THAN THE FIX. A verdict keyed on tickage
# alone, or on "no log lines", would launder a genuinely silent box — one whose
# credentials may be dead — behind a reassuring word. ff-silent above holds the
# floor half of that line and must never be relaxed; these two hold the
# boundaries the new branch could have swallowed on its way in.
t "creds: a never-ticked box is still hired"        True "$(uf ff-neverticked 'bool(u["engine"])')"
t "creds: an unhired box is untouched by waiting"   unknown "$(uf ff-nothired 'u["gh"]')"
# `waiting` is a credential verdict and nothing more: it must not leak into the
# colour rule as a green, and it must not make a box read healthy elsewhere.
t "creds: a waiting box is not flowing"             False "$(uf ff-neverticked 'u["gh"] == "flowing"')"
# The flowing-requires-a-recent-tick COUPLING is asserted in boxside.sh, where
# the real probe.sh runs against a duty.log this suite controls. It cannot be
# asserted here: stub-box picks its credential value from the scenario name,
# independently of the log it emits, so a fleet-wide check would be measuring
# the stub's internal consistency rather than the probe's rule. (`ff-fresh`
# has no timestamped line at all, and a PAUSED box legitimately reports
# flowing — its engine ran recently, an operator then stopped it.)

# --- source invariants for the two fail-open paths ------------------------
# Both are conditions a stub fleet cannot stage — a `box list` that fails only
# sometimes, and a ping thread that outlives its join — so they are pinned at
# the source, the way this repo already pins `box exec`'s stdin redirect.

# The ping tier must ask box_states whether it could ANSWER, not merely what it
# returned: an empty dict means both "no boxes" and "could not ask", and
# treating the second as the first empties the roster, issues zero pings, and
# clears every consecutive-miss counter — fail-open, on the signal whose job is
# noticing that something stopped answering.
CS_SRC="$FLOOR/server/floor.py"
if grep -q 'box_states(strict=True)' "$CS_SRC"; then
  ok "ping: distinguishes a failed box list from an empty fleet"
else
  fail "ping: distinguishes a failed box list from an empty fleet" \
       "ping_once does not use box_states(strict=True)"
fi

# The published snapshot must be a COPY. join() with a timeout returns whether
# or not the thread finished, and these are daemons, so a ping still blocked in
# communicate() against a wedged box will later write into whatever dict the
# closure holds. If that dict is the live one, the late writer sets fails back
# to 0 from a stale prev and masks the wedge that made it late.
if awk '/def ping_once/,/return published/' "$CS_SRC" | grep -q 'published = dict(results)'; then
  ok "ping: publishes a copy, so a late thread lands on an orphan"
else
  fail "ping: publishes a copy, so a late thread lands on an orphan" \
       "ping_once publishes the same dict its threads still hold"
fi

# `flowing` must never be derivable from VERSION alone — VERSION records that
# the engine was installed, not that it has run. The rule now lives on the
# HOST: probe.sh reports `nofail` plus ::tickage and floor.py ages the pair,
# so the threshold is not copied into the box in a second language.
# `waiting` joins the forbidden list for the same reason (#265): the box knows
# its own tick age is absent and could "helpfully" name the state itself, and
# that is the same third copy of the rule wearing a friendlier word.
if awk '/^for svc in gh vendor/,/^done/' "$FLOOR/server/probe.sh" | grep -q 'flowing\|waiting\|stale'; then
  fail "creds: the box reports a fact, not a verdict" \
       "probe.sh decides flowing/waiting/stale itself — that is a third copy of the host's rule"
else
  ok "creds: the box reports a fact, not a verdict"
fi
if grep -q 'fresh = 0 <= tick_age < SILENT_AFTER_S' "$FLOOR/server/floor.py"; then
  ok "creds: the host ages nofail with the same rule it calls SILENT"
else
  fail "creds: the host ages nofail with the same rule it calls SILENT" \
       "floor.py does not derive freshness from SILENT_AFTER_S"
fi
# The never-ticked half of the same rule. Pinned at the source because the
# behavioural assertions above can only see the verdict the floor produced —
# they cannot see whether it came from the boundary the CLI also uses, and a
# reader that agreed by coincidence is what shared/test's cross-reader
# invariant exists to refuse.
if grep -q 'never_ticked = tick_age < 0' "$FLOOR/server/floor.py"; then
  ok "creds: the host names the never-ticked case rather than falling through"
else
  fail "creds: the host names the never-ticked case rather than falling through" \
       "floor.py has no never_ticked predicate — a never-ticked box ages to stale"
fi
