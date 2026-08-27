# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/actions.sh — the suite for fleet-floor/server/floor/actions.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the seven members
# of this window that edit the collector still queue behind one test file.
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

# ===========================================================================
# #486 — the one box state that needs stopping could not be stopped. `box
# down` is `incus stop` with no force and no timeout, so against a guest that
# cannot schedule its own shutdown every graceful verb runs out the floor's
# own ACTION_TIMEOUT_S and reports failure. stub-box's `wedged` arm now hangs
# on `down` the way that guest does, which is why these cases can exist at
# all: until it did, stopping always worked here.
#
# ff-wedged is borrowed and PUT BACK. A 27th fixture row is the tidier shape
# and test/cli.sh:1885 records why it is refused — three suites hardcode the
# fixture's 26 boxes and the browser scroll walk has been destabilised by
# fleet size before. So this block ends by restoring the box AND waiting for
# the console to call it unreachable again, because floor/ping.sh reads
# exactly that and reading it is not this suite's to break.
# ===========================================================================
echo "== force stop (#486)"

# calls_since MARK — the stub's own call log from line MARK on. Every case
# below asks what the HOST was told to do, not what the reply said: "restart
# force-stops an unreachable box" is a claim about argv, and a 200 with a
# per-box `ok` is equally true of a graceful stop that happened to succeed.
fs_mark()        { wc -l < "$FLOOR_CALLS"; }
fs_calls_since() { tail -n "+$(( $1 + 1 ))" "$FLOOR_CALLS"; }

# The predicate the collector escalates on is the ping tier's wedge rule, so
# wait for the tier to have reached it rather than assuming the suites sourced
# before this one took long enough. Without this the whole block would pass or
# fail on how fast the machine is.
FS_DL=$(( $(date +%s) + 60 ))
while [ "$(uf ff-wedged 'u["note"].startswith("UNREACHABLE")')" != "True" ] \
      && [ "$(date +%s)" -lt "$FS_DL" ]; do sleep 1; done
t "force: the fixture's wedged box is unreachable to the collector" True \
  "$(uf ff-wedged 'u["note"].startswith("UNREACHABLE")')"

# --- D3: restart on an UNREACHABLE box force-stops, then starts -------------
# MUST FAIL: the action timing out where force was available. A restart that
# still reached for `box down` here would hang the full action timeout and end
# with the box neither stopped nor started.
FS_M=$(fs_mark)
FS_T0=$(date +%s)
FS_R="$(api POST /api/command '{"action":"restart","box":"ff-wedged","mode":"force"}')"
FS_EL=$(( $(date +%s) - FS_T0 ))
FS_SEEN="$(fs_calls_since "$FS_M")"
t "force: restart on an unreachable box succeeds" 200 "$(printf '%s' "$FS_R" | tail -1)"
# Anchored at the line start, because every line in $FLOOR_CALLS is one
# stub-box invocation's whole argv and an `exec` line carries a page-long
# script: an unanchored "incus " would eventually match somebody's comment.
# A here-string and not `printf | grep -q`, per #449 — this suite sets
# pipefail and grep -q exits on the first match, so the producer takes
# SIGPIPE and reds the assertion.
if grep -q '^incus ff-wedged -- stop --force$' <<<"$FS_SEEN"; then
  ok "force: restart fires the ruled passthrough"
else fail "force: restart fires the ruled passthrough" "$FS_SEEN"; fi
if grep -q '^down ff-wedged$' <<<"$FS_SEEN"; then
  fail "force: restart does not try the graceful stop first" "$FS_SEEN"
else ok "force: restart does not try the graceful stop first"; fi
if grep -q '^start ff-wedged$' <<<"$FS_SEEN"; then
  ok "force: restart starts the box afterwards"
else fail "force: restart starts the box afterwards" "$FS_SEEN"; fi
t "force: restart ends with the box running" running \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"
if [ "$FS_EL" -lt "${FLOOR_TEST_ACTION_TIMEOUT:-8}" ]; then
  ok "force: restart lands inside the action timeout"
else
  fail "force: restart lands inside the action timeout" "${FS_EL}s"
fi
# The record, not the outcome: which path a two-step lifecycle action took is
# the thing an operator reads afterwards, and "it worked" does not carry it.
t "force: the reply records which path it took" force-stop \
  "$(printf '%s' "$FS_R" | sed '$d' | jqf "d['results'][0].get('step','')")"

# --- D3, the other half: a REACHABLE box restarts exactly as before ---------
# MUST FAIL: force firing on a reachable box. Asserted on argv for the same
# reason as above — both paths end with the box running, so an outcome check
# cannot tell them apart.
FS_M=$(fs_mark)
t "force: restart on a reachable box succeeds" 200 \
  "$(status POST /api/command '{"action":"restart","box":"ff-idle"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
if grep -q '^incus ' <<<"$FS_SEEN"; then
  fail "force: a reachable box is never force-stopped" "$FS_SEEN"
else ok "force: a reachable box is never force-stopped"; fi
if grep -q '^down ff-idle$' <<<"$FS_SEEN"; then
  ok "force: a reachable box still gets the graceful stop"
else fail "force: a reachable box still gets the graceful stop" "$FS_SEEN"; fi
# Both halves of the restart, on both paths. The unreachable case asserts its
# `start` and this one did not — an asymmetry that would have let a graceful
# path which stopped the box and never started it pass here.
if grep -q '^start ff-idle$' <<<"$FS_SEEN"; then
  ok "force: a reachable box is started again afterwards"
else fail "force: a reachable box is started again afterwards" "$FS_SEEN"; fi

# --- D1/D4: the confirmed path and the executed path are ONE decision -------
# The round-1 fix put the wedge rule in one place and served it. That is still
# one rule evaluated at TWO TIMES: the page confirms from a fleet snapshot up
# to one poll old, and the collector re-reads the ping map when the POST
# lands. A box crossing the boundary in between let an operator confirm the
# gentle sentence over a host that then ran `stop --force` — D1's silent
# escalation through time-of-check/time-of-use rather than a duplicated
# constant, and no assertion in this suite could see it, because every case
# above posts and executes at the same instant.
#
# So the confirmed mode travels with the request and a disagreement REFUSES.
# The transition is driven here by posting the mode the OTHER path would have
# authorised — which is exactly what a stale page sends, and is the only way
# to hold the two verdicts apart in one process without sleeping through a
# poll interval and hoping.
#
# MUST FAIL, and it is the whole point of the block: a refusal that still
# touched the host. `409` alone is equally true of a collector that refused
# after stopping the box, so every case asks $FLOOR_CALLS what the host was
# told to do. Patterns are anchored per box rather than asserting the log is
# empty: the refusal asks for a fleet refresh on purpose, so the poller's own
# calls land in this window and an emptiness check would read them as fired.
echo "== restart mode (#486 round 2)"

# 1. A GENTLE confirmation over a box that has gone wedged. The destructive
#    direction: this is the one that must never authorise a kill.
FS_M=$(fs_mark)
FS_X="$(api POST /api/command '{"action":"restart","box":"ff-wedged","mode":"graceful"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "mode: a graceful confirmation over a wedged box is refused" 409 \
  "$(printf '%s' "$FS_X" | tail -1)"
t "mode: ...and says which way the box moved" force \
  "$(printf '%s' "$FS_X" | sed '$d' | jqf "d.get('verdict','')")"
t "mode: ...and what was confirmed against it" graceful \
  "$(printf '%s' "$FS_X" | sed '$d' | jqf "d.get('confirmed','')")"
# REFUSED is not FAILED: the page renders them differently because nothing ran.
t "mode: ...and marks itself refused rather than failed" True \
  "$(printf '%s' "$FS_X" | sed '$d' | jqf "d.get('refused',False)")"
case "$FS_X" in
  *"confirm again"*) ok "mode: ...and tells the operator what to do next" ;;
  *) fail "mode: ...and tells the operator what to do next" "$FS_X" ;;
esac
if grep -qE '^(down|start) ff-wedged$|^incus ff-wedged ' <<<"$FS_SEEN"; then
  fail "mode: a refused restart fires NOTHING at the host" "$FS_SEEN"
else ok "mode: a refused restart fires NOTHING at the host"; fi
t "mode: ...and the box is left exactly as it was" running \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"

# 2. The same rule the other way. Harmless in outcome — a gentler path than
#    the operator authorised — but an operator told "any running session is
#    lost" who got something else still met a console that does not do what it
#    says, and one predicate with two behaviours is what this issue is about.
FS_M=$(fs_mark)
FS_X="$(api POST /api/command '{"action":"restart","box":"ff-idle","mode":"force"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "mode: a force confirmation over a box that answers is refused too" 409 \
  "$(printf '%s' "$FS_X" | tail -1)"
t "mode: ...naming the verdict that now holds" graceful \
  "$(printf '%s' "$FS_X" | sed '$d' | jqf "d.get('verdict','')")"
if grep -qE '^(down|start) ff-idle$|^incus ff-idle ' <<<"$FS_SEEN"; then
  fail "mode: the harmless direction fires nothing either" "$FS_SEEN"
else ok "mode: the harmless direction fires nothing either"; fi

# 3. A request that names NO mode means graceful — a bare restart's meaning
#    before this issue existed. So the old request shape keeps its old
#    semantics and cannot become a kill by arriving at the wrong moment: the
#    escalation is reachable only from a client that showed a human the word.
FS_M=$(fs_mark)
t "mode: a restart naming no mode never escalates" 409 \
  "$(status POST /api/command '{"action":"restart","box":"ff-wedged"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
if grep -q '^incus ff-wedged ' <<<"$FS_SEEN"; then
  fail "mode: ...and did not kill the guest on the way" "$FS_SEEN"
else ok "mode: ...and did not kill the guest on the way"; fi
t "mode: an unknown mode is refused as a bad request" 400 \
  "$(status POST /api/command '{"action":"restart","box":"ff-idle","mode":"kill"}')"

# 4. Agreement still executes, on both paths, with the argv unchanged. Without
#    these the block above is satisfied by a collector that refuses everything.
FS_M=$(fs_mark)
t "mode: an agreeing graceful confirmation still restarts" 200 \
  "$(status POST /api/command '{"action":"restart","box":"ff-idle","mode":"graceful"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
if grep -q '^down ff-idle$' <<<"$FS_SEEN" && grep -q '^start ff-idle$' <<<"$FS_SEEN"; then
  ok "mode: ...with today's argv, both halves"
else fail "mode: ...with today's argv, both halves" "$FS_SEEN"; fi
if grep -q '^incus ' <<<"$FS_SEEN"; then
  fail "mode: ...and no escalation on the agreeing gentle path" "$FS_SEEN"
else ok "mode: ...and no escalation on the agreeing gentle path"; fi

# --- D1: a graceful stop never escalates on its own -------------------------
# MUST FAIL: a graceful stop silently succeeding against the hanging arm. This
# is the case the old stub could not express — `down` always wrote `stopped`
# and answered 0, so the floor reported success for a box it had not stopped.
FS_M=$(fs_mark)
FS_OFF="$(api POST /api/command '{"action":"power-off","box":"ff-wedged"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "force: a graceful stop against a wedged guest is reported failed" 500 \
  "$(printf '%s' "$FS_OFF" | tail -1)"
case "$FS_OFF" in
  *"timed out"*) ok "force: ...and the failure names the timeout" ;;
  *) fail "force: ...and the failure names the timeout" "$FS_OFF" ;;
esac
if grep -q '^incus ' <<<"$FS_SEEN"; then
  fail "force: a graceful stop never escalates to force" "$FS_SEEN"
else ok "force: a graceful stop never escalates to force"; fi
t "force: a hung stop does not claim the box stopped" running \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"

# --- D1/D2: force-stop is its own verb, and it works -----------------------
FS_M=$(fs_mark)
FS_T0=$(date +%s)
FS_F="$(api POST /api/command '{"action":"force-stop","box":"ff-wedged"}')"
FS_EL=$(( $(date +%s) - FS_T0 ))
FS_SEEN="$(fs_calls_since "$FS_M")"
t "force: force-stop succeeds where the graceful stop hung" 200 \
  "$(printf '%s' "$FS_F" | tail -1)"
t "force: the wedged guest is actually stopped" stopped \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"
if grep -q '^incus ff-wedged -- stop --force$' <<<"$FS_SEEN"; then
  ok "force: it fires exactly the ruled command"
else fail "force: it fires exactly the ruled command" "$FS_SEEN"; fi
if [ "$FS_EL" -lt "${FLOOR_TEST_ACTION_TIMEOUT:-8}" ]; then
  ok "force: a wedged box is stopped inside the action timeout"
else
  fail "force: a wedged box is stopped inside the action timeout" "${FS_EL}s"
fi
t "force: force-stop records its path too" force-stop \
  "$(printf '%s' "$FS_F" | sed '$d' | jqf "d['results'][0].get('step','')")"
t "force: an unknown box is still refused" 400 \
  "$(status POST /api/command '{"action":"force-stop","box":"nope"}')"

# The stub's refusal, driven directly. Every argv assertion above leans on the
# unmatched arm — "it fires exactly the ruled passthrough and not a near
# neighbour" is only true because anything else exits 2.
#
# `incus ff-idle stop stop --force` is the argv that makes the point, and it
# is chosen rather than any old malformed call: an arm that shifted three
# without checking WHERE the separator is reads this as `stop --force` and
# quietly force-stops the box, so the case that is supposed to be refused
# succeeds instead. A shorter malformed call exits 2 under both spellings and
# would assert nothing. Both the log and the state dir are pointed elsewhere,
# so a probe that IS silently reinterpreted cannot mutate the fleet the cases
# above read.
FS_PROBE_ENV=(FLOOR_CALLS=/dev/null FLOOR_STATE="$TMP/stub-probe")
if env "${FS_PROBE_ENV[@]}" "$HERE/stub-box" incus ff-idle stop stop --force >/dev/null 2>&1; then
  fail "force: the stub refuses a passthrough with the separator misplaced" \
       "shifted past it blind and reinterpreted the call as the ruled one"
else
  ok "force: the stub refuses a passthrough with the separator misplaced"
fi
t "force: ...and did not stop the box on the way" "" \
  "$(cat "$TMP/stub-probe/ff-idle.state" 2>/dev/null)"
if env "${FS_PROBE_ENV[@]}" "$HERE/stub-box" incus ff-idle -- restart >/dev/null 2>&1; then
  fail "force: the stub refuses an incus verb it does not model" "exit 0"
else
  ok "force: the stub refuses an incus verb it does not model"
fi

# ===========================================================================
# #487 D2/D4 — `restart` appended its stop result and never read it, so a stop
# that failed was followed by `box start` on the next line and the box was
# started anyway. Reached here on the GRACEFUL path, which is the one this
# fixture can express: the block above left ff-wedged stopped, the ping tier
# skips a stopped box and REPLACES its map wholesale, so within one round the
# box has no published heartbeat at all — and unmeasured is not wedged
# (fleet.wedged), so the collector's verdict is `graceful` and a bare restart
# agrees with it. stub-box's `down` arm keys on the SCENARIO, so it hangs there
# exactly as it does on a running wedged guest, which is the failure under
# test. The force half is driven at branch level in test/concurrent-actions.py,
# where a force stop can be made to fail at all.
#
# MUST FAIL: `box start` appearing in the call log. The reply is not where this
# is asserted — "restart reported a failure" is equally true of a restart that
# failed, started the box anyway and mentioned the stop afterwards, which is
# the defect exactly.
# ===========================================================================
echo "== restart reads its own stop (#487)"

FS_DL=$(( $(date +%s) + 60 ))
while [ "$(uf ff-wedged 'u["ping"]')" != "None" ] && [ "$(date +%s)" -lt "$FS_DL" ]; do
  sleep 1
done
t "stop: the stopped box's heartbeat is dropped, not left stale" None \
  "$(uf ff-wedged 'u["ping"]')"
t "stop: ...so the collector's verdict is the graceful path" stopped \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"

FS_M=$(fs_mark)
FS_RR="$(api POST /api/command '{"action":"restart","box":"ff-wedged"}')"
FS_SEEN="$(fs_calls_since "$FS_M")"
t "stop: a restart whose stop failed is reported failed" 500 \
  "$(printf '%s' "$FS_RR" | tail -1)"
if grep -q '^down ff-wedged$' <<<"$FS_SEEN"; then
  ok "stop: the graceful stop was attempted"
else fail "stop: the graceful stop was attempted" "$FS_SEEN"; fi
if grep -q '^start ff-wedged$' <<<"$FS_SEEN"; then
  fail "stop: a failed stop does not start the box" "$FS_SEEN"
else ok "stop: a failed stop does not start the box"; fi
t "stop: ...and the box is left as the failed stop found it" stopped \
  "$(cat "$FLOOR_STATE/ff-wedged.state" 2>/dev/null)"
# The record, not just the outcome: a start that did not run is a third state
# beside ran-and-worked and ran-and-failed, and the reply says which (#487 D4).
t "stop: the reply records the start that never ran" start \
  "$(printf '%s' "$FS_RR" | sed '$d' | jqf "d['results'][1].get('step','')")"
t "stop: ...as not-attempted rather than as a second failure" None \
  "$(printf '%s' "$FS_RR" | sed '$d' | jqf "d['results'][1]['ok']")"
case "$FS_RR" in
  *"not started"*) ok "stop: ...and says so in words the page renders" ;;
  *) fail "stop: ...and says so in words the page renders" "$FS_RR" ;;
esac

# Put ff-wedged back the way this suite found it, and prove it is back: the
# ping tier skips a stopped box, so leaving it down would empty its heartbeat
# and floor/ping.sh — which waits on exactly that fact — would spend its
# timeout and then fail for a reason nobody would trace to this block.
status POST /api/command '{"action":"power-on","box":"ff-wedged"}' >/dev/null
FS_DL=$(( $(date +%s) + 60 ))
while [ "$(uf ff-wedged 'u["note"].startswith("UNREACHABLE")')" != "True" ] \
      && [ "$(date +%s)" -lt "$FS_DL" ]; do sleep 1; done
t "force: the fixture box is restored for the suites that read it" True \
  "$(uf ff-wedged 'u["note"].startswith("UNREACHABLE")')"

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
FS_M=$(fs_mark)
WS_T0=$(date +%s)
WS_R="$(api POST /api/command '{"action":"wake-silent"}')"
WS_EL=$(( $(date +%s) - WS_T0 ))
FS_SEEN="$(fs_calls_since "$FS_M")"
t "wake-silent: resumes a PAUSED box"   resumed "$(cat "$FLOOR_STATE/ff-paused.cron" 2>/dev/null)"
t "wake-silent: leaves a DISARMED box alone" "" "$(cat "$FLOOR_STATE/ff-disarmed.cron" 2>/dev/null)"

# #487 D3/D4 — the wake went to every box incus did not call `stopped`, which
# includes the wedged one: RESUME_SH down a channel that cannot execute
# anything, blocking the whole ACTION_TIMEOUT_S to report a timeout for a fact
# the collector had already published as ping.wedged.
#
# MUST FAIL: an `exec` at ff-wedged in the call log. Asserted on argv, because
# a failed row for that box is what the OLD behaviour produced too — the
# difference is entirely in whether the wake was sent.
if grep -q '^exec ff-wedged ' <<<"$FS_SEEN"; then
  fail "wake-silent: a wedged box is not sent a wake" "$FS_SEEN"
else ok "wake-silent: a wedged box is not sent a wake"; fi
# It is REPORTED, not skipped. A disarmed box drops out of the wake set with no
# row at all (#189) because nothing is wrong with it; a wedged one is the
# incident this console exists to surface, so it carries a row that names the
# lever that can still reach it.
ws_field() {  # ws_field KEY — one field of ff-wedged's row in the reply above
  printf '%s' "$WS_R" | sed '$d' | jqf \
    "[r for r in d['results'] if r['box']=='ff-wedged'][0].get('$1','')"
}
t "wake-silent: ...it is escalated rather than dropped" escalate "$(ws_field step)"
t "wake-silent: ...and a box it could not wake is not a success" False "$(ws_field ok)"
case "$(ws_field out)" in
  *"Restart it"*) ok "wake-silent: ...naming the lever that can still reach it" ;;
  *) fail "wake-silent: ...naming the lever that can still reach it" "$(ws_field out)" ;;
esac
# The cost, which is the half an operator feels: two unreachable boxes in this
# fixture each spent a full action timeout before this change.
if [ "$WS_EL" -lt "${FLOOR_TEST_ACTION_TIMEOUT:-8}" ]; then
  ok "wake-silent: a wedged box costs no action timeout"
else
  fail "wake-silent: a wedged box costs no action timeout" "${WS_EL}s"
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
  _got="$(sed '1s/^PROMPT=\[//; $s/]$//' "$_log")"
  [ "$_got" = "$_staged" ] || CM_BAD="$CM_BAD token=$_tok:staged[$_staged]!=delivered[$_got]"
done
if [ -z "$CM_BAD" ] && [ "$CM_STAGED" -eq 5 ]; then
  ok "each token's session ran exactly that token's prompt (1:1)"
else
  fail "each token's session ran exactly that token's prompt (1:1)" "${CM_BAD:-no tokens staged}"
fi
