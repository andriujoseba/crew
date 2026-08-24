# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/server.sh — the suite for fleet-floor/server/floor/server.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the twelve members
# that edit these files still queue behind one test file.
#
# Subject: the HTTP surface — the auth gate every route sits behind, the
# log endpoint's filename rules, routing, and the hygiene an
# unauthenticated caller must not get past.

echo "== auth"
t "401: fleet without creds"  401 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/fleet")"
t "401: page without creds"   401 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
t "401: command without creds" 401 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "http://127.0.0.1:$PORT/api/command")"
t "401: logs without creds"   401 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/logs?box=ff-working")"
t "401: wrong password"       401 "$(curl -s -o /dev/null -w '%{http_code}' -u "$USER:wrong" "http://127.0.0.1:$PORT/api/fleet")"
t "200: page with creds"      200 "$(status GET /)"


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
t "fleet still complete after load" 26 "$(body GET /api/fleet | jqf "len(d['units'])")"
