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
echo "crew@0.2.0 (deadbee)" > "$BS_H/duty/VERSION"
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
t "probe.sh: full engine stamp carried through" "crew@0.2.0 (deadbee)" "$(bs_get ENGINE)"
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
bot_session_acted() { return 1; }
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
# The prompt path carries the collector's per-request token now, so the
# standalone run has to mint one the same way and write to the matching name.
BS_TOK="boxsidetest$$"

BS_SH="$BS_TMP/message.sh"
BS_SERVER="$BS_FLOOR/server" BS_TOK="$BS_TOK" BS_PROMPT="$BS_PROMPT" \
  BS_PROMPT_FILE="$BS_M/duty/.floor-prompt.$BS_TOK" \
  python3 - "$BS_SH" "$BS_TMP/expected-floor-prompt" <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
prompt = floor.floor_message_prompt(os.environ["BS_PROMPT"])
open(sys.argv[1], "w").write(floor.MESSAGE_SH.replace("__TOK__", os.environ["BS_TOK"]))
open(sys.argv[2], "w").write(prompt)
open(os.environ["BS_PROMPT_FILE"], "w").write(prompt)
PY

HOME="$BS_M" DUTY_DIR="$BS_M/duty" PATH="$BS_M/bin:$PATH" \
  bash "$BS_SH" < "$BS_TMP/agent.conf" >/dev/null 2>&1
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

# The log name carries the per-request token now (…-operator-floor-<tok>.log),
# which is what stops two same-second sessions overwriting each other.
BS_LOG="$(cat "$BS_M"/duty/logs/*operator-floor*.log 2>/dev/null)"
t "message: prompt arrives as ONE argv element" "ARGC=3" "$(printf '%s\n' "$BS_LOG" | sed -n 's/^\(ARGC=[0-9]*\)$/\1/p')"
t "message: envelope precedes operator text byte-identically" \
  "$(cat "$BS_TMP/expected-floor-prompt")" \
  "$(printf '%s\n' "$BS_LOG" | sed '1s/^LAST=//')"

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
print("ACTED=%s" % (sess[0]["acted"] if sess else ""))
print("REPLY=%s" % (sess[0]["reply"] if sess else ""))
PY
t "message: its markers parse back as a session" 1 "$(sed -n 's/^N=//p' "$BS_TMP/msg.parsed")"
t "message: session kind is 'operator'" operator "$(sed -n 's/^KIND=//p' "$BS_TMP/msg.parsed")"
t "message: successful no-action session parses as no-op" no "$(sed -n 's/^ACTED=//p' "$BS_TMP/msg.parsed")"
t "message: final reply tail parses for the floor" "$BS_PROMPT" "$(sed -n 's/^REPLY=//p' "$BS_TMP/msg.parsed")"

# The envelope is a required shipped input, not an optional hint. If packaging
# or a later refactor drops it, fail before launching a raw operator message.
BS_SERVER="$BS_FLOOR/server" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
floor.FLOOR_ENVELOPE = "/definitely/missing/fragment-floor-envelope.txt"
try:
    floor.floor_message_prompt("operator text")
except RuntimeError as exc:
    if "floor message envelope unavailable" in str(exc):
        raise SystemExit(0)
raise SystemExit("missing envelope did not fail loudly")
PY
t "message: missing envelope fails loudly" 0 "$?"

if grep -Fq 'model_reasoning_effort="medium"' "$BS_ROOT/shared/conf/agents/codex.conf"; then
  ok "message: codex profile pins medium reasoning effort"
else
  fail "message: codex profile pins medium reasoning effort" "pin missing"
fi

# A profile without the optional action hook must stay honest: successful is
# not evidence of action, and absence of a classifier is never a false no-op.
sed '/^bot_session_acted()/d' "$BS_TMP/agent.conf" > "$BS_TMP/agent-hookless.conf"
: > "$BS_M/duty/duty.log"
cp "$BS_TMP/expected-floor-prompt" "$BS_M/duty/.floor-prompt.$BS_TOK"
HOME="$BS_M" DUTY_DIR="$BS_M/duty" PATH="$BS_M/bin:$PATH" \
  bash "$BS_SH" < "$BS_TMP/agent-hookless.conf" >/dev/null 2>&1
for _ in $(seq 1 40); do
  grep -q 'SESSION END kind=operator' "$BS_M/duty/duty.log" 2>/dev/null && break
  sleep 0.25
done
if grep -q 'SESSION END kind=operator key=floor rc=0 .* outcome=ok acted=unknown ' "$BS_M/duty/duty.log"; then
  ok "message: hookless profile records acted=unknown"
else
  fail "message: hookless profile records acted=unknown" "$(cat "$BS_M/duty/duty.log")"
fi

# A failing vendor CLI must be recorded as FAILED with its real rc, not swallowed.
cat > "$BS_M/bin/fake-cli" <<'EOF'
#!/usr/bin/env bash
echo boom >&2; exit 3
EOF
chmod +x "$BS_M/bin/fake-cli"
: > "$BS_M/duty/duty.log"
# MESSAGE_SH consumes the prompt file (rm after read), so the second run needs
# its own — which is the point of the per-request path.
cp "$BS_TMP/expected-floor-prompt" "$BS_M/duty/.floor-prompt.$BS_TOK"
HOME="$BS_M" DUTY_DIR="$BS_M/duty" PATH="$BS_M/bin:$PATH" \
  bash "$BS_SH" < "$BS_TMP/agent.conf" >/dev/null 2>&1
for _ in $(seq 1 40); do
  grep -q 'SESSION END kind=operator' "$BS_M/duty/duty.log" 2>/dev/null && break
  sleep 0.25
done
if grep -q 'SESSION END kind=operator key=floor rc=3 .* outcome=FAILED' "$BS_M/duty/duty.log"; then
  ok "message: a failed session is recorded FAILED with its rc"
else
  fail "message: a failed session is recorded FAILED with its rc" "$(cat "$BS_M/duty/duty.log")"
fi

# --------------------------------------------------------------------------
# PAUSE_SH / RESUME_SH — run for real against a real crontab(1) stand-in.
#
# This is the pair #188 was about, and it is exactly the circularity this file
# exists to break: every other assertion about pause and resume is made against
# test/stub-box's imitation of them, so the bug — `grep -c` exits 1 on a zero
# count, and it was the last command, so the count WAS the verdict — could not
# be seen from the collector side at all. Here the scripts run, against a
# crontab whose contents the test controls, and the exit status is read.
# --------------------------------------------------------------------------
BS_C="$BS_TMP/cronbin"; mkdir -p "$BS_C"
BS_CRON="$BS_TMP/crontab.state"
# Only the two forms floor.py's scripts use: `-l` to read, `-` to replace from
# stdin. Anything else is a script doing something this stand-in has not been
# shown to model, and must fail loudly rather than be quietly accepted.
# `-l` with no crontab exits 1 the way cron(8)'s does — that is the real
# zero-line case, and swallowing it here would fake the bug away.
#
# The install is ATOMIC (temp file, then rename), like the real crontab(1),
# which stages into the spool and renames. Truncating in place would be a
# stand-in bug rather than a script bug, but it is the one that bites hardest
# if the scripts ever go back to piping a live read into a live write
# (`crontab -l | sed | crontab -`, both ends open at once): a `cat > $STATE`
# empties the file the reader at the head of the same pipeline is still
# reading, and the box loses its crontab. The scripts snapshot the crontab
# first and write from the snapshot, so they do not do that today.
cat > "$BS_C/crontab" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -l) [ -s "$CRONTAB_STATE" ] || { echo "no crontab for tester" >&2; exit 1; }
      cat "$CRONTAB_STATE" ;;
  -)  if [ "${CRONTAB_RO:-0}" = 1 ]; then cat >/dev/null; echo "crontab: installing new crontab: permission denied" >&2; exit 1; fi
      tmp="$(mktemp)"; cat > "$tmp"; mv -f "$tmp" "$CRONTAB_STATE" ;;
  *)  echo "crontab: unsupported argument ${1:-}" >&2; exit 1 ;;
esac
EOF
chmod +x "$BS_C/crontab"

BS_SERVER="$BS_FLOOR/server" BS_OUT="$BS_TMP" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["BS_SERVER"])
import floor
out = os.environ["BS_OUT"]
open(os.path.join(out, "pause.sh"), "w").write(floor.PAUSE_SH)
open(os.path.join(out, "resume.sh"), "w").write(floor.RESUME_SH)
PY

# bs_ctl <pause|resume> -> writes $BS_TMP/ctl.out and $BS_TMP/ctl.err, echoes rc
bs_ctl() {
  local rc=0
  PATH="$BS_C:$PATH" CRONTAB_STATE="$BS_CRON" CRONTAB_RO="${BS_RO:-0}" \
    bash "$BS_TMP/$1.sh" >"$BS_TMP/ctl.out" 2>"$BS_TMP/ctl.err" || rc=$?
  echo "$rc"
}
bs_armed()  { grep -cE '^[^#].*tick\.sh' "$BS_CRON" 2>/dev/null || true; }
bs_paused() { grep -c '^#CREW-FLOOR-PAUSED' "$BS_CRON" 2>/dev/null || true; }

# shellcheck disable=SC2016  # a crontab line is stored unexpanded; $HOME is cron's
printf '*/5 * * * * $HOME/duty/bin/tick.sh\n17 2 * * * unrelated-job\n' > "$BS_CRON"
t "pause: exits 0 on an armed box"      0 "$(bs_ctl pause)"
t "pause: comments the tick line out"   1 "$(bs_paused)"
t "pause: no live tick line remains"    0 "$(bs_armed)"
t "pause: says what it did"    "paused 1" "$(cat "$BS_TMP/ctl.out")"
# The unrelated line is somebody else's job. A control that quietly rewrote it
# would be a far worse bug than the one being fixed.
t "pause: leaves unrelated crontab lines alone" 1 "$(grep -c '^17 2 \* \* \* unrelated-job$' "$BS_CRON")"

t "resume: exits 0"                     0 "$(bs_ctl resume)"
t "resume: restores the live line"      1 "$(bs_armed)"
t "resume: no commented line remains"   0 "$(bs_paused)"
t "resume: says what it did"  "resumed 1" "$(cat "$BS_TMP/ctl.out")"

# #188 itself. Every drill box is in this state for its whole run — cron is
# disarmed before any tick — so this path is the one the drill always took, and
# it used to exit 1 and be rendered "command refused".
printf '17 2 * * * unrelated-job\n' > "$BS_CRON"
t "pause: a box with no armed line exits 0"  0 "$(bs_ctl pause)"
case "$(cat "$BS_TMP/ctl.out")" in
  "nothing to pause"*) ok "pause: a box with no armed line says nothing to pause" ;;
  *) fail "pause: a box with no armed line says nothing to pause" "$(cat "$BS_TMP/ctl.out")" ;;
esac
t "pause: nothing to pause changes nothing" "17 2 * * * unrelated-job" "$(cat "$BS_CRON")"

t "resume: nothing paused exits 0"  0 "$(bs_ctl resume)"
case "$(cat "$BS_TMP/ctl.out")" in
  "nothing to resume"*) ok "resume: nothing paused says so" ;;
  *) fail "resume: nothing paused says so" "$(cat "$BS_TMP/ctl.out")" ;;
esac

# The count is what THIS call moved, not the post-state total. A box carrying
# a `#CREW-FLOOR-PAUSED` line from an earlier pause AND one armed line pauses
# exactly one line; reporting the total would say `paused 2`. Nothing in the
# fleet produces this crontab today — a second pause short-circuits to
# `nothing to pause` — which is why it is asserted here rather than left to a
# scenario that cannot reach it (kimi, round 1).
# shellcheck disable=SC2016
printf '#CREW-FLOOR-PAUSED */5 * * * * $HOME/duty/bin/tick.sh\n*/5 * * * * $HOME/duty/bin/other-tick.sh\n' > "$BS_CRON"
t "pause: a pre-paused line is not counted as this call's work" 0 "$(bs_ctl pause)"
t "pause: counts only the lines it commented"        "paused 1" "$(cat "$BS_TMP/ctl.out")"
t "pause: the pre-existing marker is left as it was"          2 "$(bs_paused)"

# Symmetric on the way back: resume moves both commented lines, and says 2 —
# the number it uncommented, not the number of live lines it can see after.
t "resume: exits 0 with two paused lines"    0 "$(bs_ctl resume)"
t "resume: counts only the lines it restored" "resumed 2" "$(cat "$BS_TMP/ctl.out")"
t "resume: both lines are live"              2 "$(bs_armed)"

# A live tick line that was never paused must not be counted by resume either.
# shellcheck disable=SC2016
printf '#CREW-FLOOR-PAUSED */5 * * * * $HOME/duty/bin/tick.sh\n7 * * * * $HOME/duty/bin/other-tick.sh\n' > "$BS_CRON"
t "resume: exits 0 alongside an already-live line"  0 "$(bs_ctl resume)"
t "resume: an already-live line is not this call's" "resumed 1" "$(cat "$BS_TMP/ctl.out")"

# No crontab AT ALL: `crontab -l` exits 1, which is the shape that made the
# zero count indistinguishable from a broken box in the first place.
: > "$BS_CRON"
t "pause: no crontab at all is still not a failure" 0 "$(bs_ctl pause)"

# ...and a write that genuinely fails must redden the row and SAY why, which is
# the whole point of not spending the exit status on a count.
# shellcheck disable=SC2016
printf '*/5 * * * * $HOME/duty/bin/tick.sh\n' > "$BS_CRON"
BS_RO=1
t "pause: a refused crontab write exits non-zero" 1 "$(bs_ctl pause)"
case "$(cat "$BS_TMP/ctl.err")" in
  *"crontab write failed"*) ok "pause: a refused write states its reason" ;;
  *) fail "pause: a refused write states its reason" "$(cat "$BS_TMP/ctl.err")" ;;
esac
BS_RO=0

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

# --------------------------------------------------------------------------
# The flow-reported signals. These exist BECAUSE the probe no longer tests a
# credential or shells out to anything: every one is a file the duty engine
# writes and probe.sh only reads. stub-box imitates all four, so without these
# assertions the collector would be verified entirely against the imitation —
# and `emit_probe` claiming `::gh flowing` proves nothing about whether the
# real script ever emits it.
# --------------------------------------------------------------------------

# The healthy shape: engine present, no failure recorded.
BS_FLOW="$BS_TMP/flow"; mkdir -p "$BS_FLOW/duty"
echo "crew@0.4.1 (feedbee)" > "$BS_FLOW/duty/VERSION"
echo "$BS_NOW duty run start" > "$BS_FLOW/duty/duty.log"
bs_probe "$BS_FLOW" >/dev/null
t "flow: no failure recorded -> gh nofail"     nofail "$(bs_key gh)"
t "flow: no failure recorded -> vendor nofail" nofail "$(bs_key vendor)"
# The box reports the AGE and the host applies the rule — so the threshold
# lives once, in floor.py, instead of a third time inside the box in bash.
BS_AGE="$(bs_key tickage)"
if [ -n "$BS_AGE" ] && [ "$BS_AGE" -ge 0 ] && [ "$BS_AGE" -lt 120 ]; then
  ok "flow: a fresh tick is reported as an age ($BS_AGE s)"
else fail "flow: a fresh tick is reported as an age" "got '$BS_AGE'"; fi

# THE finding this state exists for. VERSION is written once by install.sh and
# never touched again, so it proves the engine was INSTALLED, not that it has
# RUN. A box hired last month, cron since disarmed, token expired last week
# records no rejection because nothing runs to be rejected — and reported
# `flowing`, the exact "logged-out box renders green" failure the value was
# introduced to prevent.
printf '%s duty run start\n' "$(date -u -d '@'"$(( $(date +%s) - 4000 ))" '+%Y-%m-%dT%H:%M:%SZ')" \
  > "$BS_FLOW/duty/duty.log"
bs_probe "$BS_FLOW" >/dev/null
BS_OLD="$(bs_key tickage)"
if [ -n "$BS_OLD" ] && [ "$BS_OLD" -gt 600 ]; then
  ok "flow: a long-dead engine reports an age past the death rule ($BS_OLD s)"
else fail "flow: a long-dead engine reports an age past the death rule" "got '$BS_OLD'"; fi
# The BOX still says nofail — it does not decide. floor.py ages this into
# `stale`, and cases.sh asserts that it does.
t "flow: the box reports a fact, not a verdict" nofail "$(bs_key gh)"
# A recorded rejection still outranks staleness: it is a fact, not an absence.
echo "$BS_NOW 401 Bad credentials" > "$BS_FLOW/duty/.auth-fail.gh"
bs_probe "$BS_FLOW" >/dev/null
t "flow: a rejection outranks everything" missing "$(bs_key gh)"
rm -f "$BS_FLOW/duty/.auth-fail.gh"
printf '%s duty run start\n' "$BS_NOW" > "$BS_FLOW/duty/duty.log"
bs_probe "$BS_FLOW" >/dev/null
if bs_has authfail; then fail "flow: healthy box emits no authfail" "$(bs_key authfail-gh)"
else ok "flow: healthy box emits no authfail"; fi

# No engine: nothing has run, so nothing is KNOWN. The distinction from
# `flowing` is the whole point — a box that has never ticked cannot have a
# working credential inferred from the absence of a failure.
BS_NOENG="$BS_TMP/noeng"; mkdir -p "$BS_NOENG/duty"
bs_probe "$BS_NOENG" >/dev/null
t "flow: no engine -> gh unknown, never flowing"     unknown "$(bs_key gh)"
t "flow: no engine -> vendor unknown, never flowing" unknown "$(bs_key vendor)"

# A recorded gh rejection.
echo "$BS_NOW 401 Bad credentials" > "$BS_FLOW/duty/.auth-fail.gh"
bs_probe "$BS_FLOW" >/dev/null
t "flow: gh rejection -> gh missing" missing "$(bs_key gh)"
if [ -n "$(bs_key authfail-gh)" ]; then ok "flow: gh rejection -> reason carried to the operator"
else fail "flow: gh rejection -> reason carried to the operator" "empty"; fi
# The marker names ONE service; the other must not be condemned with it.
t "flow: a gh rejection does not mark the vendor missing" nofail "$(bs_key vendor)"
rm -f "$BS_FLOW/duty/.auth-fail.gh"

# lockheld: a duty run in flight, and the half-written file that a probe
# landing mid-`date +%s >` will read. A bogus age here would render as a
# 56-year-old session and read as a catastrophic wedge.
printf '%s' "$(( $(date +%s) - 2820 ))" > "$BS_FLOW/duty/.duty.lock.since"
bs_probe "$BS_FLOW" >/dev/null
BS_HELD="$(bs_key lockheld)"
if [ "${BS_HELD:-0}" -ge 2815 ] && [ "${BS_HELD:-0}" -le 2830 ]; then
  ok "flow: lockheld is the age of the run in flight ($BS_HELD s)"
else fail "flow: lockheld is the age of the run in flight" "got '$BS_HELD'"; fi
echo "not-a-number" > "$BS_FLOW/duty/.duty.lock.since"
bs_probe "$BS_FLOW" >/dev/null
if bs_has lockheld; then fail "flow: a corrupt lock stamp emits nothing" "$(bs_key lockheld)"
else ok "flow: a corrupt lock stamp emits nothing"; fi
: > "$BS_FLOW/duty/.duty.lock.since"
bs_probe "$BS_FLOW" >/dev/null
if bs_has lockheld; then fail "flow: an empty lock stamp emits nothing" "$(bs_key lockheld)"
else ok "flow: an empty lock stamp emits nothing"; fi
rm -f "$BS_FLOW/duty/.duty.lock.since"

# The probe must not have reacquired a network dependency. `gh` and the vendor
# CLIs are on the box's PATH, so a future edit calling either would pass every
# assertion above and quietly cost 450ms per box per poll again.
# Anchored to COMMAND POSITION, not to the word appearing anywhere: `gh` and
# `vendor` are also legitimate wire-key names in this file, and a bare word
# match condemned `for svc in gh vendor`. Comments are stripped first so the
# rationale above each check cannot trip the check.
BS_NETRE='(^|[;&|(]|\bif |\bthen |\belse )[[:space:]]*(gh|bot_cli_probe|claude|codex|kimi)([[:space:]]|$)'
if sed 's/#.*//' "$BS_FLOOR/server/probe.sh" | grep -qE "$BS_NETRE"; then
  fail "flow: probe.sh invokes no network command" \
       "$(sed 's/#.*//' "$BS_FLOOR/server/probe.sh" | grep -nE "$BS_NETRE")"
else ok "flow: probe.sh invokes no network command"; fi
# ...and the guard is worth nothing if it cannot see the thing it forbids.
if printf 'if gh auth status; then :; fi\n' | grep -qE "$BS_NETRE"; then
  ok "flow: the no-network guard detects a reintroduced gh call"
else fail "flow: the no-network guard detects a reintroduced gh call" "guard is blind"; fi

if [ -n "${BS_STANDALONE:-}" ]; then
  echo
  echo "== box-side summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
  [ "${#FAILS[@]}" -gt 0 ] && exit 1
  exit 0
fi

# --------------------------------------------------------------------------
# The PING script, EXECUTED FOR REAL.
#
# stub-box answers the ping by pattern-matching the command and always exits
# 0, so every collector assertion about it is circular: removing the `exit 0`
# from the real script changes nothing the stub can see. This is the only
# place the actual shell runs, and the case it must survive is the ORDINARY
# one — a healthy idle box has no .duty.lock.since, `cat` on a missing file
# exits 1, and a non-zero rc is what the ping tier reads as "this guest is
# dead". Get it wrong and a healthy fleet renders UNREACHABLE.
# --------------------------------------------------------------------------
BS_PING="$(BS_SERVER="$BS_FLOOR/server" python3 -c 'import os, sys; sys.path.insert(0, os.environ["BS_SERVER"]); import floor; sys.stdout.write(floor.PING_SH)')"
if [ -n "$BS_PING" ]; then ok "ping: the script could be extracted from floor.py"
else fail "ping: the script could be extracted from floor.py" "PING_SH is empty"; fi

bs_ping() {  # bs_ping <home> -> writes $BS_TMP/ping.out, echoes rc
  local rc=0
  HOME="$1" DUTY_DIR="$1/duty" sh -c "$BS_PING" \
    > "$BS_TMP/ping.out" 2>"$BS_TMP/ping.err" || rc=$?
  echo "$rc"
}
bs_ping_key() { sed -n "s/^$1 //p" "$BS_TMP/ping.out" | head -1; }

# The normal state of a healthy idle box: engine present, nothing in flight.
BS_PH="$BS_TMP/pinghome"; mkdir -p "$BS_PH/duty"
t "ping: an idle box with NO lock file exits 0" 0 "$(bs_ping "$BS_PH")"
t "ping: ...and reports an empty lock field"    "" "$(bs_ping_key l)"
if [ -n "$(bs_ping_key u)" ]; then ok "ping: uptime rides along"
else fail "ping: uptime rides along" "no u line: $(cat "$BS_TMP/ping.out")"; fi

# A run in flight. duty.sh writes an ABSOLUTE stamp (`date +%s`) and every
# consumer wants the AGE — asserting only that the field is non-empty is what
# let the raw stamp through, and ~1.7e9 compared against STUCK_AFTER_S marked
# every live duty run STUCK with a multi-year duration.
printf '%s' "$(( $(date +%s) - 2820 ))" > "$BS_PH/duty/.duty.lock.since"
t "ping: a run in flight exits 0" 0 "$(bs_ping "$BS_PH")"
BS_L="$(bs_ping_key l)"
if [ -n "$BS_L" ] && [ "$BS_L" -ge 2815 ] && [ "$BS_L" -le 2830 ]; then
  ok "ping: the lock rides along as an AGE, not a timestamp ($BS_L s)"
else
  fail "ping: the lock rides along as an AGE, not a timestamp" \
       "got '$BS_L' — a raw stamp is ~1.7e9 and marks every live run STUCK"
fi

# THE regression. A run that started THIS SECOND must be unremarkable: age ~0,
# far below STUCK_AFTER_S. Asserted against floor.py's real threshold rather
# than a number written here, so the two cannot drift apart.
date +%s > "$BS_PH/duty/.duty.lock.since"
bs_ping "$BS_PH" >/dev/null
BS_FRESH="$(bs_ping_key l)"
BS_STUCK_AT="$(BS_SERVER="$BS_FLOOR/server" python3 -c 'import os, sys; sys.path.insert(0, os.environ["BS_SERVER"]); import floor; print(floor.STUCK_AFTER_S)')"
if [ -n "$BS_FRESH" ] && [ "$BS_FRESH" -ge 0 ] && [ "$BS_FRESH" -lt "$BS_STUCK_AT" ]; then
  ok "ping: a run that just started is NOT stuck ($BS_FRESH s < $BS_STUCK_AT)"
else
  fail "ping: a run that just started is NOT stuck" \
       "got '$BS_FRESH' against a $BS_STUCK_AT s threshold"
fi
# ...and an old one still escalates, or the guard above could pass by never
# reporting anything at all.
printf '%s' "$(( $(date +%s) - 4000 ))" > "$BS_PH/duty/.duty.lock.since"
bs_ping "$BS_PH" >/dev/null
BS_OLDL="$(bs_ping_key l)"
if [ -n "$BS_OLDL" ] && [ "$BS_OLDL" -gt "$BS_STUCK_AT" ]; then
  ok "ping: a genuinely old lock still crosses the threshold ($BS_OLDL s)"
else
  fail "ping: a genuinely old lock still crosses the threshold" "got '$BS_OLDL'"
fi

# A torn or skewed stamp must report NOTHING rather than a bogus age — duty.sh
# rewrites this file at the top of every run, so a probe can land mid-write.
echo "not-a-number" > "$BS_PH/duty/.duty.lock.since"
t "ping: a corrupt lock stamp exits 0" 0 "$(bs_ping "$BS_PH")"
t "ping: ...and reports no age"        "" "$(bs_ping_key l)"
printf '%s' "$(( $(date +%s) + 5000 ))" > "$BS_PH/duty/.duty.lock.since"
bs_ping "$BS_PH" >/dev/null
t "ping: a future stamp (clock skew) reports no age" "" "$(bs_ping_key l)"

# An unreadable lock file must not fail the ping: the passenger is optional,
# the liveness claim is not.
chmod 000 "$BS_PH/duty/.duty.lock.since"
t "ping: an unreadable lock file still exits 0" 0 "$(bs_ping "$BS_PH")"
chmod 644 "$BS_PH/duty/.duty.lock.since"
rm -f "$BS_PH/duty/.duty.lock.since"

# A created-but-never-hired box has no duty dir at all.
t "ping: a box with no duty dir exits 0" 0 "$(bs_ping "$BS_TMP/nosuchhome")"

# ...and floor.py must parse what the script REALLY emits, not what it is
# believed to emit — the circularity this file exists to break.
bs_ping "$BS_PH" >/dev/null
BS_PARSED="$(BS_SERVER="$BS_FLOOR/server" python3 -c 'import os, sys; sys.path.insert(0, os.environ["BS_SERVER"]); import floor; f = floor.parse_ping(open(sys.argv[1]).read()); print("uptime=%s lockheld=%s" % (f["uptime"] is not None, f["lockheld"]))' "$BS_TMP/ping.out")"
t "ping: floor.py parses the real script's output" "uptime=True lockheld=None" "$BS_PARSED"
