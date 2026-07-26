#!/usr/bin/env bash
# fleet-floor/test/boxside.sh — actually RUN the two scripts that normally only
# ever execute inside a box, and check the collector can read what they emit.
#
# Sourced by test/run.sh (which provides ok/fail/t); runnable on its own too.
#
# Why this exists: everything else in the suite drives the collector against
# test/stub-box, which INTERCEPTS `box exec` and answers with what probe.sh is
# believed to produce. That makes 90-odd collector assertions circular — they
# validate the parser against an imitation, and a real bug in probe.sh or in
# the message script would sail straight through. Neither script needs a box to
# run: probe.sh reads files and asks `crontab`/`gh`, and the message script
# needs only a shell and a fake vendor CLI. So they are run for real here, and
# their output is fed to the REAL parser.
#
# The message script is the sharpest edge in the whole change: a nested
# `nohup setsid bash -c '...'` carrying an operator-supplied prompt. If its
# quoting is wrong, the prompt is mangled or — worse — executed.
set -uo pipefail

BS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BS_FLOOR="$(dirname "$BS_HERE")"
BS_ROOT="$(dirname "$BS_FLOOR")"

# Standalone mode: provide the reporters test/run.sh would have given us.
if ! declare -F ok >/dev/null; then
  PASS=0 SKIP=0
  declare -a FAILS=()
  ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
  fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
  skip() { echo "skip $1${2:+  — $2}"; SKIP=$((SKIP + 1)); }
  t()    { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
  BS_STANDALONE=1
fi

BS_TMP="$(mktemp -d)"
# No EXIT trap here: sourced into run.sh, one would fire at ITS exit and, worse,
# a backgrounded subshell would inherit it. The caller's cleanup owns lifetime;
# standalone mode cleans up at the bottom.

echo
echo "== box-side scripts, executed for real"

# --------------------------------------------------------------------------
# probe.sh
# --------------------------------------------------------------------------
BS_H="$BS_TMP/probehome"
mkdir -p "$BS_H/duty/logs"
echo "crew@deadbee" > "$BS_H/duty/VERSION"
printf '# comment\nheavy-duty/ceremony\nheavy-duty/rig\n' > "$BS_H/duty/repos.txt"
BS_NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
  echo "$BS_NOW duty run start"
  echo "$BS_NOW heavy-duty/rig: build duty (ready unclaimed=1, whole rounds owed=0)"
  echo "$BS_NOW SESSION START kind=build key=rig#12 timeout=7200s log=/x/a.log"
  echo "$BS_NOW SESSION END kind=build key=rig#12 rc=0 dur=55s outcome=ok"
} > "$BS_H/duty/duty.log"
touch "$BS_H/duty/logs/20260726T090000Z-build-rig_12.log"

HOME="$BS_H" DUTY_DIR="$BS_H/duty" \
  bash "$BS_FLOOR/server/probe.sh" < "$BS_ROOT/shared/conf/agents/claude.conf" \
  > "$BS_TMP/probe.out" 2>"$BS_TMP/probe.err"
t "probe.sh exits 0" 0 "$?"

# The contract that matters is not the text — it is that floor.py's own parser
# gets every key it later reads. A missing key is a TypeError several panels
# deep, long after the poll that caused it.
BS_SERVER="$BS_FLOOR/server" python3 - "$BS_TMP/probe.out" > "$BS_TMP/probe.parsed" 2>&1 <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
meta, lines = floor.parse_probe(open(sys.argv[1]).read())
need = ("engine", "uptime", "now", "gh", "vendor", "cron", "paused", "repos", "sessionlogs")
print("MISSING=%s" % ",".join(k for k in need if k not in meta))
print("ENGINE=%s" % meta.get("engine", ""))
print("UPTIME_OK=%s" % str(meta.get("uptime", "").isdigit()))
print("REPOS=%d" % len(meta.get("repos", "").split()))
print("LOGLINES=%d" % len(lines))
sess, cur = floor.derive_sessions(lines, time.time())
print("SESSIONS=%d" % len(sess))
print("SESSKEY=%s" % (sess[0]["key"] if sess else ""))
print("QUEUE=%d" % len(floor.derive_queue(lines)))
PY
bs_get() { sed -n "s/^$1=//p" "$BS_TMP/probe.parsed"; }
t "probe.sh: parser gets every key it reads" "" "$(bs_get MISSING)"
t "probe.sh: engine version read"  "crew@deadbee" "$(bs_get ENGINE)"
t "probe.sh: uptime is a number"   True "$(bs_get UPTIME_OK)"
t "probe.sh: repos.txt comments stripped" 2 "$(bs_get REPOS)"
t "probe.sh: log section delimited" 4 "$(bs_get LOGLINES)"
t "probe.sh: sessions parse from real output" 1 "$(bs_get SESSIONS)"
t "probe.sh: session key intact" "rig#12" "$(bs_get SESSKEY)"
t "probe.sh: queue derived from real output" 1 "$(bs_get QUEUE)"

# --------------------------------------------------------------------------
# the message script — the operator prompt must survive as ONE argv element
# --------------------------------------------------------------------------
BS_M="$BS_TMP/msghome"
mkdir -p "$BS_M/duty/logs" "$BS_M/bin"
cat > "$BS_TMP/agent.conf" <<'EOF'
BOT_PATH_PREPEND="$HOME/.local/bin"
BOT_CLI_CMD=(fake-cli --flag -p)
bot_cli_probe() { true; }
EOF
cat > "$BS_M/bin/fake-cli" <<'EOF'
#!/usr/bin/env bash
printf 'ARGC=%s\n' "$#"
printf 'LAST=%s\n' "${*: -1}"
EOF
chmod +x "$BS_M/bin/fake-cli"

# Every metacharacter an operator might type, plus non-ASCII. Single-quoted on
# purpose: the payload must reach the box LITERAL, so bash must not expand it
# here — expanding it would make the test send something tamer than it claims.
# shellcheck disable=SC2016
BS_PROMPT='check PR #40 "now"; rm -rf /tmp/floor-boxside-pwned; $(id) `whoami` & | ; é'
printf '%s\n' "$BS_PROMPT" > "$BS_M/duty/.floor-prompt"

BS_SH="$BS_TMP/message.sh"
BS_SERVER="$BS_FLOOR/server" python3 - "$BS_SH" <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
open(sys.argv[1], "w").write(floor.MESSAGE_SH)
PY

HOME="$BS_M" PATH="$BS_M/bin:$PATH" bash "$BS_SH" < "$BS_TMP/agent.conf" >/dev/null 2>&1
t "message: script exits 0" 0 "$?"

# The session is detached on purpose, so wait for its END marker rather than
# racing it.
for _ in $(seq 1 40); do
  grep -q 'SESSION END kind=operator' "$BS_M/duty/duty.log" 2>/dev/null && break
  sleep 0.25
done

if [ -e /tmp/floor-boxside-pwned ]; then
  fail "message: prompt cannot execute" "/tmp/floor-boxside-pwned was created"
  rm -f /tmp/floor-boxside-pwned
else
  ok "message: prompt cannot execute"
fi

BS_LOG="$(cat "$BS_M"/duty/logs/*operator-floor.log 2>/dev/null)"
t "message: prompt arrives as ONE argv element" "ARGC=3" "$(printf '%s\n' "$BS_LOG" | sed -n 's/^\(ARGC=[0-9]*\)$/\1/p')"
t "message: prompt arrives byte-identical" "$BS_PROMPT" "$(printf '%s\n' "$BS_LOG" | sed -n 's/^LAST=//p')"

if grep -q 'SESSION START kind=operator key=floor' "$BS_M/duty/duty.log"; then
  ok "message: writes a SESSION START marker"
else
  fail "message: writes a SESSION START marker" "$(cat "$BS_M/duty/duty.log")"
fi
if grep -q 'SESSION END kind=operator key=floor rc=0 .* outcome=ok' "$BS_M/duty/duty.log"; then
  ok "message: writes a SESSION END marker with rc"
else
  fail "message: writes a SESSION END marker with rc" "$(cat "$BS_M/duty/duty.log")"
fi

# An operator session must show up in the console's history like any other, so
# the markers it writes have to survive the collector's own parser.
BS_SERVER="$BS_FLOOR/server" python3 - "$BS_M/duty/duty.log" > "$BS_TMP/msg.parsed" 2>&1 <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
sess, cur = floor.derive_sessions(open(sys.argv[1]).read().splitlines(), time.time())
print("N=%d" % len(sess))
print("KIND=%s" % (sess[0]["kind"] if sess else ""))
print("OUT=%s" % (sess[0]["out"] if sess else ""))
PY
t "message: its markers parse back as a session" 1 "$(sed -n 's/^N=//p' "$BS_TMP/msg.parsed")"
t "message: session kind is 'operator'" operator "$(sed -n 's/^KIND=//p' "$BS_TMP/msg.parsed")"

# A failing vendor CLI must be recorded as FAILED with its real rc, not swallowed.
cat > "$BS_M/bin/fake-cli" <<'EOF'
#!/usr/bin/env bash
echo boom >&2; exit 3
EOF
chmod +x "$BS_M/bin/fake-cli"
: > "$BS_M/duty/duty.log"
HOME="$BS_M" PATH="$BS_M/bin:$PATH" bash "$BS_SH" < "$BS_TMP/agent.conf" >/dev/null 2>&1
for _ in $(seq 1 40); do
  grep -q 'SESSION END kind=operator' "$BS_M/duty/duty.log" 2>/dev/null && break
  sleep 0.25
done
if grep -q 'SESSION END kind=operator key=floor rc=3 .* outcome=FAILED' "$BS_M/duty/duty.log"; then
  ok "message: a failed session is recorded FAILED with its rc"
else
  fail "message: a failed session is recorded FAILED with its rc" "$(cat "$BS_M/duty/duty.log")"
fi

rm -rf "$BS_TMP"

# --------------------------------------------------------------------------
# probe.sh in DEGRADED boxes. These are the shapes a real fleet actually has
# during setup and after failures, and probe.sh runs with `set -u` only (never
# -e) precisely so it reports them instead of returning nothing.
# --------------------------------------------------------------------------
bs_probe() {  # bs_probe <home> -> writes $BS_TMP/deg.out, echoes rc
  local h="$1" rc=0
  HOME="$h" DUTY_DIR="$h/duty" \
    bash "$BS_FLOOR/server/probe.sh" < "$BS_ROOT/shared/conf/agents/claude.conf" \
    > "$BS_TMP/deg.out" 2>"$BS_TMP/deg.err" || rc=$?
  echo "$rc"
}
bs_key() { sed -n "s/^::$1 //p" "$BS_TMP/deg.out" | head -1; }
bs_has() { grep -q "^::$1" "$BS_TMP/deg.out"; }

# A box created but never hired: no ~/duty at all.
BS_BARE="$BS_TMP/bare"; mkdir -p "$BS_BARE"
t "degraded: no duty dir -> still exits 0" 0 "$(bs_probe "$BS_BARE")"
t "degraded: no duty dir -> empty engine" "" "$(bs_key engine)"
if bs_has logstart && bs_has logend; then ok "degraded: no duty dir -> log section still delimited"
else fail "degraded: no duty dir -> log section still delimited" "$(cat "$BS_TMP/deg.out")"; fi
if bs_has uptime; then ok "degraded: no duty dir -> uptime still reported"
else fail "degraded: no duty dir -> uptime still reported" "missing"; fi

# duty.log with CRLF line endings — probe.sh strips \r so the parser's
# anchored timestamp regex still matches.
BS_CRLF="$BS_TMP/crlf"; mkdir -p "$BS_CRLF/duty"
printf '%s duty run start\r\n%s SESSION END kind=build key=x#1 rc=0 dur=9s outcome=ok\r\n' \
  "$BS_NOW" "$BS_NOW" > "$BS_CRLF/duty/duty.log"
bs_probe "$BS_CRLF" >/dev/null
if grep -q $'\r' "$BS_TMP/deg.out"; then
  fail "degraded: CRLF stripped from duty.log" "carriage returns survived into the record"
else ok "degraded: CRLF stripped from duty.log"; fi
BS_SERVER="$BS_FLOOR/server" python3 - "$BS_TMP/deg.out" > "$BS_TMP/crlf.parsed" 2>&1 <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
meta, lines = floor.parse_probe(open(sys.argv[1]).read())
sess, _ = floor.derive_sessions(lines, time.time())
print("N=%d" % len(sess))
PY
t "degraded: CRLF log still parses a session" 1 "$(sed -n 's/^N=//p' "$BS_TMP/crlf.parsed")"

# An unreadable duty.log (wrong owner/mode after a botched restore).
BS_UNREAD="$BS_TMP/unread"; mkdir -p "$BS_UNREAD/duty"
echo "$BS_NOW duty run start" > "$BS_UNREAD/duty/duty.log"
chmod 000 "$BS_UNREAD/duty/duty.log"
t "degraded: unreadable duty.log -> still exits 0" 0 "$(bs_probe "$BS_UNREAD")"
if bs_has logend; then ok "degraded: unreadable duty.log -> record stays well-formed"
else fail "degraded: unreadable duty.log -> record stays well-formed" "$(cat "$BS_TMP/deg.out")"; fi
chmod 644 "$BS_UNREAD/duty/duty.log"

# A big duty.log: the probe must bound what it ships, or every poll drags
# megabytes per box across box exec.
BS_BIG="$BS_TMP/big"; mkdir -p "$BS_BIG/duty"
awk -v n="$BS_NOW" 'BEGIN{for(i=0;i<8000;i++) print n" filler line "i}' > "$BS_BIG/duty/duty.log"
bs_probe "$BS_BIG" >/dev/null
BS_LINES="$(sed -n '/^::logstart$/,/^::logend$/p' "$BS_TMP/deg.out" | sed '1d;$d' | wc -l)"
if [ "$BS_LINES" -le 600 ]; then ok "degraded: big duty.log is capped at 600 lines ($BS_LINES)"
else fail "degraded: big duty.log is capped at 600 lines" "shipped $BS_LINES"; fi

if [ -n "${BS_STANDALONE:-}" ]; then
  echo
  echo "== box-side summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
  [ "${#FAILS[@]}" -gt 0 ] && exit 1
  exit 0
fi
