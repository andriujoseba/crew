# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/units.sh — the suite for fleet-floor/server/floor/units.py.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. One suite per module at the
# mirrored path (#508 D2): the source split buys nothing if the seven members
# of this window that edit the collector still queue behind one test file.
#
# Subject: the record build_unit produces from one probe — every state the
# page must not collapse, and the notes that make a dark box explainable.

# ===========================================================================
# LOOP 1 — the shape the collector must produce, and the states it must not
# collapse. A fleet where every box is healthy would pass a broken renderer.
# ===========================================================================
echo "== telemetry"

t "fleet: reports live"            True "$(body GET /api/fleet | jqf "d['live']")"
t "fleet: carries the serving host's exact version string" "$FLOOR_TEST_VERSION" \
  "$(body GET /api/fleet | jqf "d['version']")"

t "state: open session -> working" working  "$(uf ff-working "u['state']")"
t "state: no open session -> idle" idle     "$(uf ff-idle    "u['state']")"
t "state: breaker stop -> suppressed" suppressed "$(uf ff-suppressed "u['state']")"
t "suppressed: carries age and reason" True \
  "$(uf ff-suppressed "u['note'] == 'for 13m — draft resume breaker at heavy-duty/crew#561'")"
t "suppressed: remains distinct from idle" False \
  "$(uf ff-suppressed "u['state'] == 'idle'")"
t "suppressed overlap: SILENT remains offline" offline \
  "$(uf ff-supp-silent "u['state']")"
t "suppressed overlap: unknown tick age remains offline" offline \
  "$(uf ff-supp-unknown "u['state']")"
t "suppressed overlap: active session remains working" working \
  "$(uf ff-supp-working "u['state']")"
t "suppressed overlap: stuck run remains working" working \
  "$(uf ff-supp-stuck "u['state']")"
t "state: cron silent -> offline"  offline  "$(uf ff-silent  "u['state']")"
t "clock: three-hours-behind healthy box is not silent" False "$(uf ff-skew-behind "u['state'] == 'offline'")"
t "clock: three-hours-ahead healthy box is not silent"  False "$(uf ff-skew-ahead  "u['state'] == 'offline'")"
t "clock: cron age comes from box-side tickage" 110 "$(uf ff-skew-behind "u['cron']['age']")"
t "clock: negative host-minus-box delta is published within its measured uncertainty" True \
  "$(uf ff-skew-ahead "u['clock_delta'] < 0 and abs(u['clock_delta'] + 10800) <= u['clock_uncertainty']")"
t "clock: positive host-minus-box delta is published within its measured uncertainty" True \
  "$(uf ff-skew-behind "u['clock_delta'] > 0 and abs(u['clock_delta'] - 10800) <= u['clock_uncertainty']")"
t "clock: skew exceeds measured probe uncertainty" True \
  "$(uf ff-skew-behind "abs(u['clock_delta']) > u['clock_uncertainty'] >= 1")"
t "clock: session age survives negative skew within sampling uncertainty" True \
  "$(uf ff-skew-behind "abs(u['sessions'][0]['ago'] - 10) <= u['clock_uncertainty']")"
t "clock: session age survives positive skew within sampling uncertainty" True \
  "$(uf ff-skew-ahead "abs(u['sessions'][0]['ago'] - 10) <= u['clock_uncertainty']")"
t "clock: negative-skew session lands in newest spark bucket" 1.0 "$(uf ff-skew-behind "u['spark'][21]")"
t "clock: positive-skew session lands in newest spark bucket" 1.0 "$(uf ff-skew-ahead "u['spark'][21]")"
t "clock: displayed last tick is on host timeline" True "$(uf ff-skew-behind "__import__('time').time() - __import__('datetime').datetime.strptime(u['cron']['last'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=__import__('datetime').timezone.utc).timestamp() < 120")"
t "clock: skewed stopped box behind is silent" offline "$(uf ff-silent-behind "u['state']")"
t "clock: skewed stopped box ahead is silent" offline "$(uf ff-silent-ahead "u['state']")"
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
FF_DELAYED_SYNC="$(FF_SERVER="$FLOOR/server" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor import units

guest_now = 1756152000
probe = """::engine crew@0.4.1 (deadbee)
::agent claude
::now 2025-08-25T20:00:00Z
::tickage 30
::gh nofail
::vendor nofail
::cron 1
::paused 0
::logstart
2025-08-25T19:59:30Z duty run start
::logend
"""
samples = iter((guest_now - 3, guest_now + 3))
units.time.time = lambda: next(samples)
units.probe_box = lambda unit, agent_conf: (probe, "")
unit = units.build_unit(
    {"box": "delayed-sync", "agent": "claude", "room": "builder"},
    "running", {}, guest_now,
)
print("%s:%s:%s:%s:%s" % (
    unit["clock_delta"], unit["clock_uncertainty"],
    unit["cron"]["ok"], unit["disarmed"], unit["state"],
))
PY
)"
IFS=: read -r delayed_delta delayed_uncertainty delayed_tick delayed_disarmed delayed_state \
  <<<"$FF_DELAYED_SYNC"
t "clock: delayed synchronized probe measures no skew" 0 "$delayed_delta"
t "clock: delayed probe publishes interval-derived uncertainty" 4 "$delayed_uncertainty"
t "agreement: delayed synchronized production probe cannot qualify" does-not-qualify \
  "$(agreement_armed_skewed \
      "$(agreement_case "$delayed_state" 'delayed-sync idle' '' "$delayed_disarmed")" \
      "$delayed_disarmed" "$delayed_tick" "$delayed_delta" "$delayed_uncertainty")"
FF_EDGE_SYNC="$(FF_SERVER="$FLOOR/server" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor import units

guest_now = 1756152000
probe = """::engine crew@0.4.1 (deadbee)
::agent claude
::now 2025-08-25T20:00:00Z
::tickage 30
::gh nofail
::vendor nofail
::cron 1
::paused 0
::logstart
2025-08-25T19:59:30Z duty run start
::logend
"""
samples = iter((guest_now, guest_now + 8))
units.time.time = lambda: next(samples)
units.probe_box = lambda unit, agent_conf: (probe, "")
unit = units.build_unit(
    {"box": "edge-sync", "agent": "claude", "room": "builder"},
    "running", {}, guest_now,
)
print("%s:%s:%s:%s:%s" % (
    unit["clock_delta"], unit["clock_uncertainty"],
    unit["cron"]["ok"], unit["disarmed"], unit["state"],
))
PY
)"
IFS=: read -r edge_delta edge_uncertainty edge_tick edge_disarmed edge_state \
  <<<"$FF_EDGE_SYNC"
t "clock: interval-edge synchronized probe exposes midpoint displacement" 4 "$edge_delta"
t "clock: interval-edge uncertainty contains that displacement" 5 "$edge_uncertainty"
t "agreement: measured uncertainty rejects interval-edge synchronized probe" does-not-qualify \
  "$(agreement_armed_skewed \
      "$(agreement_case "$edge_state" 'edge-sync idle' '' "$edge_disarmed")" \
      "$edge_disarmed" "$edge_tick" "$edge_delta" "$edge_uncertainty")"
FF_BACKWARD_CLOCK="$(FF_SERVER="$FLOOR/server" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor import units

guest_now = 1756152000
probe = """::engine crew@0.4.1 (deadbee)
::agent claude
::now 2025-08-25T20:00:00Z
::tickage 30
::gh nofail
::vendor nofail
::cron 1
::paused 0
::logstart
2025-08-25T19:59:30Z duty run start
::logend
"""
samples = iter((guest_now + 100, guest_now + 2))
units.time.time = lambda: next(samples)
units.probe_box = lambda unit, agent_conf: (probe, "")
unit = units.build_unit(
    {"box": "backward-clock", "agent": "claude", "room": "builder"},
    "running", {}, guest_now,
)
print("%s:%s:%s:%s:%s" % (
    unit["clock_delta"], unit["clock_uncertainty"],
    unit["cron"]["ok"], unit["disarmed"], unit["state"],
))
PY
)"
IFS=: read -r backward_delta backward_uncertainty backward_tick backward_disarmed backward_state \
  <<<"$FF_BACKWARD_CLOCK"
t "clock: backward host step leaves delta unusable" None "$backward_delta"
t "clock: backward host step leaves uncertainty unusable" None "$backward_uncertainty"
t "agreement: asymmetric synchronized backstep cannot qualify" does-not-qualify \
  "$(agreement_armed_skewed \
      "$(agreement_case "$backward_state" 'backward-clock idle' '' "$backward_disarmed")" \
      "$backward_disarmed" "$backward_tick" "$backward_delta" "$backward_uncertainty")"
t "agreement: skewed box reaches the real up-comparison branch" up \
  "$(agreement_case "$(uf ff-skew-behind "u['state']")" 'ff-skew-behind running' '' False)"
t "agreement: armed fresh skew qualifies" qualifies \
  "$(agreement_armed_skewed up False True \
      "$(uf ff-skew-behind "u['clock_delta']")" "$(uf ff-skew-behind "u['clock_uncertainty']")")"
t "agreement: armed but never-ticked does not qualify" does-not-qualify \
  "$(agreement_armed_skewed up False "$(uf ff-neverticked "u['cron']['ok']")" 10800 2)"
t "agreement: armed fresh but synchronized does not qualify" does-not-qualify \
  "$(agreement_armed_skewed \
      "$(agreement_case "$(uf ff-idle "u['state']")" 'ff-idle idle' '' False)" \
      False "$(uf ff-idle "u['cron']['ok']")" \
      "$(uf ff-idle "u['clock_delta']")" "$(uf ff-idle "u['clock_uncertainty']")")"
t "agreement: disarmed does not qualify" does-not-qualify \
  "$(agreement_armed_skewed up True True 10800 2)"
t "agreement: silent does not qualify" does-not-qualify \
  "$(agreement_armed_skewed silent False True 10800 2)"
t "agreement: not-hired does not qualify" does-not-qualify \
  "$(agreement_armed_skewed not-hired False True 10800 2)"
t "agreement: down does not qualify" does-not-qualify \
  "$(agreement_armed_skewed down False True 10800 2)"
# Execute the same predicate-to-count transition as the live roster loop. The
# disarmed false-positive and qualifying false-negative are behavioral facts,
# while the one-call pin keeps a second private count path from returning.
t "agreement: qualifying evidence increments the live count" 1 \
  "$(agreement_armed_count 0 up False True 10800 2)"
t "agreement: disarmed evidence leaves the live count unchanged" 0 \
  "$(agreement_armed_count 0 up True True 10800 2)"
t "agreement: the live loop has one count decision" 1 \
  "$(grep -cE '^[[:space:]]*next_armed_count=.*agreement_armed_count' \
      "$FLOOR/../drill/rehearsal-app.sh")"
agreement_loop_source="$(awk '
  /^  # One unit is one measurement\./ { in_agreement_loop=1 }
  in_agreement_loop { print }
  in_agreement_loop && /^done < <\(roster_rows\)$/ { exit }
' "$FLOOR/../drill/rehearsal-app.sh")"
t "agreement: each member uses one fleet snapshot" 1 \
  "$(grep -cF 'body GET /api/fleet' <<<"$agreement_loop_source")"
t "agreement: an armed skewed comparison makes the round comparable" compared \
  "$(agreement_round_result 1)"
t "agreement: a disarmed-only round says it could not compare" could-not-compare \
  "$(agreement_round_result 0)"
t "agreement: matching SILENT readings are compared" silent \
  "$(agreement_case offline 'ff-silent offline host engine current stale stale SILENT — no tick' 'SILENT — no tick' False)"
t "agreement: a SILENT mismatch cannot skip" silent-mismatch \
  "$(agreement_case offline 'ff-silent suppressed host engine current stale stale breaker' 'SILENT — no tick' False)"
build_unit_source="$(awk '/^def build_unit/,/^def fmt_dur/' "$FLOOR/server/floor/units.py")"
if grep -q 'now - last_ts' <<<"$build_unit_source"; then
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

# A box absent from `box list` is not created yet — it must still be in
# /api/fleet, or a half-built fleet looks complete to every reader of the API.
# Since #204 it gets no CONSOLE, which is a page decision asserted in
# browser.js; the payload below is what keeps `crew status` and the drill's
# agreement check able to see it at all.
t "absent box still rendered"  offline "$(uf ff-absent "u['state']")"
case "$(uf ff-absent "u['note']")" in *"crew new"*) ok "note: absent names the fix" ;;
  *) fail "note: absent names the fix" "$(uf ff-absent "u['note']")" ;; esac

# ---------------------------------------------------------------------------
# hired — the console filter's discriminator (#204)
#
# The page draws a console for what is DEPLOYED, not for what the roster
# DECLARES, and it fires on this field alone. The field exists because the
# obvious test — `engine == ""` — is true of FOUR different boxes with TWO
# different answers, and inferring the filter from that silence is the #308
# defect one reader over. The collector already ranks the four apart with its
# own early returns, so it publishes the verdict and the page never re-derives
# it. All five shapes are pinned here: the two that hide a console, the two
# that must not, and the healthy one.
# ---------------------------------------------------------------------------
t "hired: a box with an engine says yes"        yes     "$(uf ff-working  "u['hired']")"
t "hired: an answered box with no engine says no" no    "$(uf ff-nothired "u['hired']")"
t "hired: a box that does not exist says no"    no      "$(uf ff-absent   "u['hired']")"
# The two that must stay UNKNOWN. A stopped box cannot be asked, and hiring is
# not undone by `crew down`; an unreachable box is the hired-and-gone-dark case,
# and hiding it is the failure this page exists to prevent. Either one grading
# as `no` silently drops a console the operator most needs.
t "hired: a stopped box cannot be measured"     unknown "$(uf ff-stopped  "u['hired']")"
t "hired: an unreachable box cannot be measured" unknown "$(uf ff-unreach  "u['hired']")"
# The whole payload, not a sample: `hired` is on every unit and is always one
# of the three words, so a box added to the fixture cannot arrive without it
# and a typo cannot reach the page as a value it will silently keep.
FF_HIRED="$(body GET /api/fleet | python3 -c "
import json,sys
u=json.load(sys.stdin)['units']
bad=[x['box'] for x in u if x.get('hired') not in ('yes','no','unknown')]
print(','.join(bad))")"
t "hired: every unit carries one of the three verdicts" "" "$FF_HIRED"
# THE criterion the filter must not break. Hiding a box is the PAGE's decision;
# dropping it from the payload would red the drill's floor-vs-CLI agreement
# check outright ("not in /api/fleet") and would disagree with `crew status`.
# The roster's full length is pinned by "fleet: every roster box present" in
# floor/roster.sh; what that assertion cannot see is WHICH boxes, so this
# names the two the page hides and asserts they are still served.
FF_UNHIRED="$(body GET /api/fleet | python3 -c "
import json,sys
u=json.load(sys.stdin)['units']
print(','.join(sorted(x['box'] for x in u if x['hired']=='no')))")"
t "wire: the payload still carries the boxes the page hides" \
  "ff-absent,ff-nothired" "$FF_UNHIRED"


echo "== sessions, queue, metrics"
FF_SESSION_EDGES="$(FF_SERVER="$FLOOR/server" python3 - <<'PY'
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.environ["FF_SERVER"])
from floor.units import derive_sessions

now = datetime(2026, 8, 27, 16, 0, tzinfo=timezone.utc).timestamp()
_, old = derive_sessions([
    "2026-08-27T08:00:00Z SESSION START kind=build key=crew#old",
], now)
_, paired = derive_sessions([
    "2026-08-27T14:00:00Z SESSION START kind=build key=crew#crashed",
    "2026-08-27T15:58:00Z SESSION START kind=review key=crew#done",
    "2026-08-27T15:59:00Z SESSION END kind=review key=crew#done rc=0 dur=60s outcome=ok",
], now)
print("old=%s paired=%s" % (old, paired["key"] if paired else None))
PY
)"
t "sessions: orphan older than six hours is not active" \
  "old=None paired=crew#crashed" "$FF_SESSION_EDGES"
t "sessions: parsed"          1    "$(uf ff-working "len(u['sessions'])")"
t "sessions: rc carried"      0    "$(uf ff-working "u['sessions'][0]['rc']")"
t "sessions: outcome carried" ok   "$(uf ff-working "u['sessions'][0]['out']")"
# #473 — the figure the page renders for the newest session per box, carried
# end to end through the real collector. ff-idle's newest session is written
# with the field; ff-working's is written without it, which is every line any
# box wrote before this and every session the engine could not measure.
t "sessions: peak_rss carried" 3588324 "$(uf ff-idle "u['sessions'][0]['peak']")"
t "sessions: a line with no peak_rss is None, never 0" None \
  "$(uf ff-working "u['sessions'][0]['peak']")"
t "sessions: a line with no peak_rss keeps every other field" "0|ok|1" \
  "$(uf ff-working "'%s|%s|%s' % (u['sessions'][0]['rc'], u['sessions'][0]['out'], len(u['sessions']))")"
t "sessions: reconstructed terminal is parsed and closes its start" \
  "1:None:None:died-with-box:None" \
  "$(FF_SERVER="$FLOOR/server" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor.units import derive_sessions

done, cur = derive_sessions([
    "2026-08-27T15:00:00Z SESSION START kind=review key=crew#lost",
    "2026-08-27T15:05:00Z SESSION END kind=review key=crew#lost rc=- dur=- outcome=died-with-box acted=unknown reply_tail= tier=unknown peak_rss=- started=2026-08-27T15:00:00Z",
], 1787843160)
print("%s:%s:%s:%s:%s" % (len(done), done[0]["rc"], done[0]["dur"], done[0]["out"], cur))
PY
)"
FF_RECONSTRUCTED_RENDER="$(node - "$FLOOR/src/app.js" <<'JS'
const fs=require('fs');
const src=fs.readFileSync(process.argv[2],'utf8');
function one(name){
  const m=src.match(new RegExp('function '+name+'\\([^}]+\\}'));
  if(!m)process.exit(2);
  return eval('('+m[0]+')');
}
function pad2(n){return (n<10?'0':'')+n;}
const fmtDur=one('fmtDur'),sessionRc=one('sessionRc'),sessionClass=one('sessionClass');
const lost={rc:null,dur:null,acted:'unknown'};
console.log([sessionRc(lost),fmtDur(lost.dur),sessionClass(lost)].join(':'));
JS
)"
t "sessions: reconstructed unknowns render as unknown failure, never zero success" \
  "-:—:cr" "$FF_RECONSTRUCTED_RENDER"
t "current: open session key" board "$(uf ff-working "u['cur']['key']")"
t "queue: from last tick"     1    "$(uf ff-working "len(u['queue'])")"
t "queue: repo parsed"        heavy-duty/ceremony "$(uf ff-working "u['queue'][0]['repo']")"

# #528 — the tick-wide mention batch has no repository. Its old line shape
# satisfied RE_MENTION and invented a repository named `fleet`, which then
# became the card's repository link. Exercise the parser directly so all four
# protocol shapes are explicit without teaching stub-box a one-issue scenario.
ff_queue_case() {
  FF_SERVER="$FLOOR/server" python3 - "$@" <<'PY'
import json
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor.units import derive_queue

print(json.dumps(derive_queue(sys.argv[1:]), separators=(",", ":"), sort_keys=True))
PY
}

FF_AGGREGATE="$(ff_queue_case \
  '2026-08-25T20:00:00Z duty run start' \
  '2026-08-25T20:00:01Z fleet: 4 unread mention(s) — launching one mention session')"
t "queue: aggregate mention is one repository-less item" \
  '[{"key":"4 mentions","repo":null}]' "$FF_AGGREGATE"

FF_LEGACY="$(ff_queue_case \
  '2026-08-25T20:00:00Z duty run start' \
  '2026-08-25T20:00:01Z heavy-duty/crew: 3 unread mention(s)')"
t "queue: legacy repository mention keeps its repository" \
  '[{"key":"3 mention","repo":"heavy-duty/crew"}]' "$FF_LEGACY"

FF_MIXED="$(ff_queue_case \
  '2026-08-25T20:00:00Z duty run start' \
  '2026-08-25T20:00:01Z fleet: 4 unread mention(s) — launching one mention session' \
  '2026-08-25T20:00:02Z heavy-duty/crew: 3 unread mention(s)')"
t "queue: aggregate and repository mentions stay distinct" \
  '[{"key":"4 mentions","repo":null},{"key":"3 mention","repo":"heavy-duty/crew"}]' "$FF_MIXED"

FF_REAL_FLEET="$(ff_queue_case \
  '2026-08-25T20:00:00Z duty run start' \
  '2026-08-25T20:00:01Z fleet: 2 unread mention(s)')"
t "queue: a real fleet repository is not the aggregate" \
  '[{"key":"2 mention","repo":"fleet"}]' "$FF_REAL_FLEET"

# #473 — every SESSION END shape this parser has ever been handed, exercised
# directly for the same reason the queue cases above are: the field is
# optional and its ABSENCE is the assertion, which a fixture box can only
# carry one of at a time.
ff_peak_case() {
  FF_SERVER="$FLOOR/server" python3 - "$@" <<'PY'
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor.units import derive_sessions

done, _ = derive_sessions(sys.argv[1:], 2000000000.0)
print("|".join("%s:%s:%s" % (s["kind"], s["rc"], s["peak"]) for s in done))
PY
}

# The pre-#469 line: no acted, no reply_tail, no tier, no peak. Criterion 4 —
# a duty.log written before any of this parses everywhere it is read.
t "peak: a pre-change line parses and reports no figure" "build:0:None" \
  "$(ff_peak_case '2026-08-26T10:00:00Z SESSION END kind=build key=o/r#1 rc=0 dur=90s outcome=ok')"
t "peak: today's line carries the figure" "build:0:3588324" \
  "$(ff_peak_case '2026-08-26T10:00:00Z SESSION END kind=build key=o/r#1 rc=0 dur=90s outcome=ok acted=yes reply_tail= tier=default peak_rss=3588324')"
# The engine omits the field where it got no reading, and the parser must not
# turn that into a zero: a box whose kernel reports no VmHWM would otherwise
# read as the cheapest box in the fleet.
t "peak: an unmeasured session is None, not 0" "build:0:None" \
  "$(ff_peak_case '2026-08-26T10:00:00Z SESSION END kind=build key=o/r#1 rc=0 dur=90s outcome=ok acted=yes reply_tail= tier=default')"
# A field that is not a figure is no figure. `peak_rss=-` is what the orphan
# reconciler writes for a session that died with its box; anything else in
# that position is a log this parser did not write and must not believe.
t "peak: a non-numeric field is refused" "build:0:None" \
  "$(ff_peak_case '2026-08-26T10:00:00Z SESSION END kind=build key=o/r#1 rc=0 dur=90s outcome=ok acted=yes reply_tail= tier=unknown peak_rss=-')"
t "peak: a garbage field is refused" "build:0:None" \
  "$(ff_peak_case '2026-08-26T10:00:00Z SESSION END kind=build key=o/r#1 rc=0 dur=90s outcome=ok peak_rss=12x9')"
# A whole token, never a suffix of one: the next field somebody appends here
# will be read by a pattern with no position to anchor on, so the name has to
# be the anchor.
t "peak: the field is a token, not a suffix of one" "build:0:None" \
  "$(ff_peak_case '2026-08-26T10:00:00Z SESSION END kind=build key=o/r#1 rc=0 dur=90s outcome=ok acted=yes reply_tail= tier=default parent_peak_rss=999')"

# Exercise the collector record, not only the page selector: configured repos
# must not replace crew as the last resort when every queue item lacks a repo.
FF_AGGREGATE_UNIT="$(FF_SERVER="$FLOOR/server" python3 - <<'PY'
import json
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor import units

probe = """::engine crew@0.4.1 (deadbee)
::agent claude
::tickage 30
::gh nofail
::vendor nofail
::cron 1
::paused 0
::repos heavy-duty/ceremony heavy-duty/box
::logstart
2026-08-25T20:00:00Z duty run start
2026-08-25T20:00:01Z fleet: 4 unread mention(s) — launching one mention session
::logend
"""
units.probe_box = lambda unit, agent_conf: (probe, "")
unit = units.build_unit(
    {"box": "ff-aggregate", "agent": "claude", "room": "builder"},
    "running", {}, 1756152002,
)
print(json.dumps(
    {"queue": unit["queue"], "repo": unit["repo"], "repos": unit["repos"]},
    separators=(",", ":"), sort_keys=True,
))
PY
)"
t "card: aggregate-only live unit keeps crew fallback with configured repos" \
  '{"queue":[{"key":"4 mentions","repo":null}],"repo":"crew","repos":["heavy-duty/ceremony","heavy-duty/box"]}' \
  "$FF_AGGREGATE_UNIT"

# An absent queue is a different state from a repository-less queue item. Keep
# the established configured-repository target, and keep no target at all when
# the box advertises no repositories.
FF_EMPTY_UNITS="$(FF_SERVER="$FLOOR/server" python3 - <<'PY'
import json
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor import units

probe_template = """::engine crew@0.4.1 (deadbee)
::agent claude
::tickage 30
::gh nofail
::vendor nofail
::cron 1
::paused 0
{repos}::logstart
2026-08-25T20:00:00Z duty run start
::logend
"""

def build(box, repos):
    probe = probe_template.format(repos=("::repos %s\n" % repos) if repos else "")
    units.probe_box = lambda unit, agent_conf: (probe, "")
    unit = units.build_unit(
        {"box": box, "agent": "claude", "room": "builder"},
        "running", {}, 1756152002,
    )
    return {"box": box, "queue": unit["queue"], "repo": unit["repo"], "repos": unit["repos"]}

print(json.dumps([
    build("ff-empty-configured", "heavy-duty/box heavy-duty/ceremony"),
    build("ff-empty-unconfigured", ""),
], separators=(",", ":"), sort_keys=True))
PY
)"
t "card: empty queues preserve configured and absent repository fallbacks" \
  '[{"box":"ff-empty-configured","queue":[],"repo":"heavy-duty/box","repos":["heavy-duty/box","heavy-duty/ceremony"]},{"box":"ff-empty-unconfigured","queue":[],"repo":"","repos":[]}]' \
  "$FF_EMPTY_UNITS"

# Execute the page's small selector in isolation. This pins what the card
# opens without coupling the assertion to generated index.html or requiring a
# browser: a repository-less first item yields the next repository, then crew.
FF_QUEUE_REPO_SOURCE="$(sed -n '/^function queueRepo(/,/^}/p' "$FLOOR/src/app.js")"
FF_QUEUE_REPO_RESULT="$(node - "$FF_QUEUE_REPO_SOURCE" <<'JS'
const source = process.argv[2];
if (!source) process.exit(2);
eval(source);
console.log([
  queueRepo([{repo:null,key:"4 mentions"},{repo:"heavy-duty/crew",key:"3 mentions"}], "crew"),
  queueRepo([{repo:null,key:"4 mentions"}], "crew")
].join(","));
JS
)"
t "card: repository-less queue items cannot become repository targets" \
  'heavy-duty/crew,crew' "$FF_QUEUE_REPO_RESULT"

# Exercise the selector through the live-data adapter, where the collector's
# empty fallback must stay empty while real queue targets still take priority.
FF_LIVE_DATA_SOURCE="$(sed -n \
  -e '/^function kindOf(/p' \
  -e '/^function queueRepo(/,/^}/p' \
  -e '/^function emptyData(/p' \
  -e '/^function liveData(/,/^}/p' \
  "$FLOOR/src/app.js")"
FF_LIVE_DATA_RESULT="$(node - "$FF_LIVE_DATA_SOURCE" <<'JS'
const source = process.argv[2];
if (!source) process.exit(2);
eval(source);
console.log([
  liveData({room:"builder",box:"offline",queue:[],repo:""}).repo,
  liveData({room:"builder",box:"idle",queue:[],repo:"heavy-duty/box"}).repo,
  liveData({room:"builder",box:"aggregate",queue:[{repo:null,key:"4 mentions"}],repo:"crew"}).repo,
  liveData({room:"builder",box:"mixed",queue:[{repo:null,key:"4 mentions"},{repo:"heavy-duty/crew",key:"3 mentions"}],repo:"crew"}).repo
].join("|"));
JS
)"
t "card: live data preserves empty, aggregate, and repository targets" \
  '|heavy-duty/box|crew|heavy-duty/crew' "$FF_LIVE_DATA_RESULT"

# The queue item remains visible, but absence is not a printable repository.
FF_QUEUE_CHIP_SOURCE="$(sed -n '/^function queueChip(/,/^}/p' "$FLOOR/src/app.js")"
FF_QUEUE_CHIP_RESULT="$(node - "$FF_QUEUE_CHIP_SOURCE" <<'JS'
const source = process.argv[2];
if (!source) process.exit(2);
const REPOC = {"heavy-duty/crew":"#123456"};
function esc(s) { return String(s); }
eval(source);
console.log([
  queueChip({repo:null,key:"4 mentions"}),
  queueChip({repo:"heavy-duty/crew",key:"3 mentions"})
].join("\n"));
JS
)"
t "queue chip: repository-less items render their key without null" \
  $'<span class="qc" style="border-color:#3a4a60">4 mentions</span>\n<span class="qc" style="border-color:#123456">heavy-duty/crew 3 mentions</span>' \
  "$FF_QUEUE_CHIP_RESULT"
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


# A duty.log full of junk must not take the collector down. The floor is the
# thing you look at WHEN things are broken; it cannot be fragile about it.
t "garbage log: still rendered"  True "$(uf ff-garbage "u['box']=='ff-garbage'")"
t "garbage log: no crash"        True "$(uf ff-garbage "u['state'] in ('idle','working','offline')")"
t "garbage log: metrics sane"    True "$(uf ff-garbage "isinstance(u['success'],int) and 0<=u['success']<=100")"

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

# The same root cause as this round's, one field over: `u["logs"]` is the card's
# session-log links, and NOTHING in this suite asserted on it — so the stub's
# `::sessionlogs` line was a fixture nobody read, and #483's first pass deleted
# it while inserting `::vitals` beside it. The suite stayed green because the
# only evidence it was ever there was the line itself. Pin it: a probe record
# that stops carrying session logs must red here rather than in a browser walk.
t "session logs reach the card" 2 "$(uf ff-working "len(u['logs'])")"
# `bool(u['logs']) and …`, not the bare `all(…)`: an empty list satisfies
# `all()` vacuously, so the deletion this round is about would have left this
# second assertion GREEN. A pinning check that survives the thing it pins is
# worse than no check, because it reads as coverage.
t "session logs are the names the box listed" True \
  "$(uf ff-working "bool(u['logs']) and all(f.endswith('.log') for f in u['logs'])")"

# A box inside its FIRST session: cur is set, sessions is empty. floor.py sets
# state=working whenever cur exists, so this is ordinary live telemetry — and
# it is the state that crashed the room's diagnostic hologram.
t "first-run box: is working"        working "$(uf ff-firstrun "u['state']")"
t "first-run box: has an open session" True  "$(uf ff-firstrun "u['cur'] is not None")"
t "first-run box: has NO history"       0    "$(uf ff-firstrun "len(u['sessions'])")"


# #190 — the engine's INTEGRITY reaches the page. `~/duty/VERSION` is a claim
# install.sh wrote once; #159 made it checkable and nothing carried the answer
# to the console, so the tile named a version an operator could not trust.
# ===========================================================================
echo "== engine integrity"
t "integrity: a clean box reports current"          current    "$(uf ff-working   'u["integrity"]')"
# The one that matters: a hotfix nobody told the fleet about, on a box whose
# every other reading is fine. The collector CARRIES this word — it must never
# smooth it, and it must never re-derive it, because the files are on the box.
t "integrity: a diverged engine is carried, not smoothed" modified "$(uf ff-modified 'u["integrity"]')"
t "integrity: a box hired before content stamping is unverified" unverified "$(uf ff-unverified 'u["integrity"]')"
# absent tracks the engine stamp: state() answers absent exactly when VERSION
# is empty, which is exactly when ::engine is.
t "integrity: an unhired box has no engine to verify" absent    "$(uf ff-nothired  'u["integrity"]')"
t "integrity: an unhired box says so on both fields"  ""         "$(uf ff-nothired  'u["engine"]')"
# A box that never answered must not inherit a neighbour's verdict, and must
# not read as verified: the default is empty and the page renders nothing.
t "integrity: an unreachable box claims nothing"      ""         "$(uf ff-unreach   'u["integrity"]')"
# Pinned at the source, like the credential rule above: the behavioural checks
# can only see the value the collector produced, and a floor that computed its
# own verdict would agree with `crew status` by coincidence until either moved.
if grep -q 'engine-manifest.sh' "$FLOOR/server/probe.sh"; then
  ok "integrity: the verdict comes from #159's script, not a second copy of it"
else
  fail "integrity: the verdict comes from #159's script, not a second copy of it" \
       "probe.sh does not consult engine-manifest.sh"
fi
if grep -qE 'u\["integrity"\] = meta\.get\("integrity"' "$FLOOR/server/floor/units.py"; then
  ok "integrity: the collector carries the box's word"
else
  fail "integrity: the collector carries the box's word" \
       "floor.py does not read ::integrity from the probe record"
fi

# ===========================================================================
# LOOP 4 — the box vitals record (#483). D1's criterion is that this page and
# `crew status` render the SAME record and CANNOT disagree, so the assertions
# here are about the parse and the publication; the equality of the two
# renderings is asserted where both readers can be run — fleet-floor/test/cli.sh.
# ===========================================================================
echo "== box vitals"

ff_vitals_case() {
  FF_SERVER="$FLOOR/server" python3 - "$@" <<'PY'
import json
import os
import sys

sys.path.insert(0, os.environ["FF_SERVER"])
from floor.units import parse_vitals

print(json.dumps(parse_vitals(sys.argv[1]), separators=(",", ":"), sort_keys=True))
PY
}

# Absence, in its four shapes. None every time — the page draws no section, and
# an empty dict would be indistinguishable from "a record that measured
# nothing", which is a different and much rarer thing.
t "vitals: no record is None"        null "$(ff_vitals_case "")"
t "vitals: a blank record is None"   null "$(ff_vitals_case "   ")"
t "vitals: an ordinary log line is not a record" null \
  "$(ff_vitals_case "2026-08-27T09:00:00Z duty run start")"
# The prefix alone is not enough. A `::vitals` carrying something else is a box
# answering a question nobody asked, and it renders as nothing rather than as a
# record with no fields in it.
t "vitals: the prefix without a stamp is not a record" null \
  "$(ff_vitals_case "VITALS cores=2")"

t "vitals: fields are carried as the strings the record spelled them" \
  '{"findings":[],"fields":{"cores":"2","load1":"0.00"},"series":[],"ts":"2026-08-28T09:00:00Z"}' \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z cores=2 load1=0.00" \
     | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({'findings':d['findings'],'fields':d['fields'],'series':d['series'],'ts':d['ts']},separators=(',',':')))")"

# D6, at the parser. An empty value is the shape of a field the box could not
# read, and it must be an ABSENCE — never the empty string, which a renderer
# would happily print as a measurement.
t "vitals: an empty value is an absent field" "" \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z cores= load1=0.00" \
     | python3 -c "import json,sys; print(json.load(sys.stdin)['fields'].get('cores',''))")"
t "vitals: an empty finding is not a finding" 0 \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z finding=" \
     | python3 -c "import json,sys; print(len(json.load(sys.stdin)['findings']))")"
t "vitals: a bare token is not a field" 0 \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z junk cores=2" \
     | python3 -c "import json,sys; print(len([k for k in json.load(sys.stdin)['fields'] if k=='junk']))")"

# Findings are worded by the RECORD. `crew status` builds this same string from
# the same token, which is what makes the two readers incapable of disagreeing
# about a finding — the alternative is each side owning a phrase-book.
t "vitals: a finding is rendered from the record's own tokens" \
  "swap-configured-inactive: configured_mb=8192, active_mb=0" \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z finding=swap-configured-inactive:configured_mb=8192,active_mb=0" \
     | python3 -c "import json,sys; print(json.load(sys.stdin)['findings'][0])")"
t "vitals: every finding on the record survives" 2 \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z finding=a:want=1,got=2 finding=b:x=1" \
     | python3 -c "import json,sys; print(len(json.load(sys.stdin)['findings']))")"
t "vitals: a finding with no detail is still a finding" "lonely" \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z finding=lonely" \
     | python3 -c "import json,sys; print(json.load(sys.stdin)['findings'][0])")"

# D5 — the backfilled series. Oldest first, stamps carried verbatim (offset and
# all: the boot gate wrote them with `date -Is` and this reader did not).
t "vitals: the disk series parses oldest-first" \
  '[{"pct":9,"ts":"2026-08-01T12:50:01+00:00"},{"pct":48,"ts":"2026-08-27T18:35:01+00:00"}]' \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z disk_series=2026-08-01T12:50:01+00:00@9,2026-08-27T18:35:01+00:00@48" \
     | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['series'],separators=(',',':'),sort_keys=True))")"
# A malformed point is DROPPED, not coerced: boot-check.log is pages of
# `gh auth status` with a df line in it, and a series that guesses at a
# reading is worse than a shorter one.
t "vitals: a malformed series point is dropped, never coerced" 1 \
  "$(ff_vitals_case "VITALS ts=2026-08-28T09:00:00Z disk_series=2026-08-01T12:50:01+00:00@9,broken,@7,2026-08-02T09:00:00+00:00@x" \
     | python3 -c "import json,sys; print(len(json.load(sys.stdin)['series']))")"

# Published on the unit, through the real collector and the real probe path.
t "vitals: a complete record reaches the unit"  2 "$(uf ff-working "u['vitals']['fields']['cores']")"
t "vitals: the swap PAIR reaches the unit, not one half of it" "0/8192" \
  "$(uf ff-working "'%s/%s' % (u['vitals']['fields']['swap_active_mb'], u['vitals']['fields']['swap_configured_mb'])")"
t "vitals: the backfilled series reaches the unit" 3 "$(uf ff-working "len(u['vitals']['series'])")"
t "vitals: the series starts before the first tick" "2026-08-01T12:50:01+00:00" \
  "$(uf ff-working "u['vitals']['series'][0]['ts']")"
t "vitals: both findings reach the unit" 2 "$(uf ff-working "len(u['vitals']['findings'])")"
t "vitals: the profile finding names both figures" \
  "cpu-profile-mismatch: want=4, got=2" "$(uf ff-working "u['vitals']['findings'][1]")"
# D6 end to end: a box whose `free` failed publishes the fields it HAS and none
# it does not, and the record still arrives.
t "vitals: a degraded record still reaches the unit" 48 "$(uf ff-idle "u['vitals']['fields']['disk_pct']")"
t "vitals: a field the box could not read is absent, not zero" "" \
  "$(uf ff-idle "u['vitals']['fields'].get('mem_total_mb', '')")"
t "vitals: no boot-check history is an empty series, not a fake point" 0 \
  "$(uf ff-idle "len(u['vitals']['series'])")"
# An engine older than the probe. None, so the page draws no section — the
# same rule `crew status` applies to the same absence.
t "vitals: a box with no record publishes None" None "$(uf ff-silent "u['vitals']")"
t "vitals: an unreachable box publishes None"    None "$(uf ff-unreach "u['vitals']")"

# Pinned at the source, as the integrity rule above is: the behavioural checks
# can only see the value the collector produced, and a floor that ran its own
# probe would agree with `crew status` by coincidence until either moved.
if grep -q '^emit vitals ' "$FLOOR/server/probe.sh"; then
  ok "vitals: the record is carried off duty.log, not re-measured box-side"
else
  fail "vitals: the record is carried off duty.log, not re-measured box-side" \
       "probe.sh does not emit ::vitals"
fi

echo "== tick health"
ff_health_case() {
  FF_SERVER="$FLOOR/server" python3 - "$@" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["FF_SERVER"])
from floor.units import parse_tick_health
print(json.dumps(parse_tick_health(sys.argv[1:]), separators=(",", ":"), sort_keys=True))
PY
}

t "tick health: no shared report is unknown, not healthy zeroes" null "$(ff_health_case)"
FF_HEALTH="$(ff_health_case \
  'TICK_HEALTH window_s=86400 last_tick_age_s=300 ticks=4 busy=1' \
  'TICK_HEALTH_KIND window_s=86400 kind=build skips=2 holds=budget:1,terminal-breaker:1 outcome=died-with-box streak=3')"
t "tick health: the bounded base figures survive" '86400|300|4|1' \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s|%s|%s"%(d["window"],d["last_tick_age"],d["ticks"],d["busy"]))' <<<"$FF_HEALTH")"
t "tick health: skip and hold reasons stay per kind" 'build|2|1|1' \
  "$(python3 -c 'import json,sys; k=json.load(sys.stdin)["kinds"][0]; print("%s|%s|%s|%s"%(k["kind"],k["skips"],k["holds"]["budget"],k["holds"]["terminal-breaker"]))' <<<"$FF_HEALTH")"
t "tick health: reconstructed outcome streak survives" 'died-with-box|3' \
  "$(python3 -c 'import json,sys; k=json.load(sys.stdin)["kinds"][0]; print("%s|%s"%(k["outcome"],k["streak"]))' <<<"$FF_HEALTH")"
t "tick health: malformed report degrades to unknown" null \
  "$(ff_health_case 'TICK_HEALTH window_s=nope last_tick_age_s=0 ticks=0 busy=0')"
if grep -q 'boxVitalsRows(d.vitals).concat(tickHealthRows(d.tickHealth))' "$FLOOR/src/app.js"; then
  ok "tick health: the floor renders the shared report"
else
  fail "tick health: the floor renders the shared report" "tickHealthRows is not on the live unit path"
fi

# ===========================================================================
# #610 — STUCK is measured against the ceiling the in-flight session declared,
# not against a fleet-wide 600s.
#
# The bug: STUCK_AFTER_S defaults to SILENT_AFTER_S = 2 * TICK_S = 600s and was
# compared against `.duty.lock.since`, which duty.sh writes at the top of a
# whole duty RUN. Four of the seven lanes are entitled to more than that
# (build/resume 3600s, hygiene 3000s, review 2700s), so a healthy build crossed
# STUCK at minute 10 and wore the pulsing badge — which also REPLACES the
# running-session panel — for the next fifty minutes.
#
# Every case below is driven off the same fixture evidence: a `build` session
# in flight declaring `timeout=3600s`. Only the lock age differs, so a reader
# comparing against anything other than that line grades at least one wrong.
# ===========================================================================
echo "== stuck: the in-flight session's own ceiling (#610)"

# The ceiling reaches the record at all. Without this the four cases below
# could all pass on a reader that had simply stopped grading.
t "stuck: the in-flight session's ceiling is parsed off SESSION START" 3600 \
  "$(uf ff-lane-build "u['cur']['timeout']")"
t "stuck: a START with no timeout= carries no ceiling" None \
  "$(uf ff-lane-legacy "u['cur']['timeout']")"

# @danmt's report, and the regression this exists for: 40 minutes into a build
# entitled to 60. Under the old rule this box wore the badge for fifty minutes.
t "stuck: a 40m build inside a 3600s ceiling is not stuck" False \
  "$(uf ff-lane-build "u['lock']['stuck']")"
t "stuck: ...and its note is not the STUCK note" False \
  "$(uf ff-lane-build "u['note'].startswith('STUCK')")"
# The half of the report that is easy to lose: the badge HIDES the running
# session, so "not stuck" is only the fix if the session is visible again.
t "stuck: ...and the running session is still the record drawn" build \
  "$(uf ff-lane-build "u['cur']['kind']")"
t "stuck: ...on a box still reported working" working \
  "$(uf ff-lane-build "u['state']")"

# The boundary, from both sides. 3660 is the ceiling plus the 60s kill grace:
# a session one second past its ceiling is being killed on schedule, not wedged.
t "stuck: at the ceiling plus the kill grace exactly, not yet stuck" False \
  "$(uf ff-lane-edge "u['lock']['stuck']")"
t "stuck: one second past it, stuck" True \
  "$(uf ff-lane-over "u['lock']['stuck']")"
t "stuck: the bound is the ceiling plus the grace, not the ceiling" 3660 \
  "$(uf ff-lane-over "u['lock']['bound']")"

# Naming the bound is the point of the note. "held 61m" is alarming until you
# know the lane was entitled to 60, and it is nothing at all until you know it
# was entitled to 10.
t "stuck: the note names the ceiling that was exceeded, not only the age" \
  "STUCK — duty run has held the lock for 1h 01m, past the build session's 1h 00m ceiling" \
  "$(uf ff-lane-over "u['note']")"
t "stuck: the ceiling is served, not merely used" 3600 \
  "$(uf ff-lane-over "u['lock']['ceiling']")"

# The second clause, and it is not the first one's optimisation: a duty run
# stalled BETWEEN dispatches has no session ceiling to exceed, so only
# STUCK_AFTER_S can catch it. ff-stuck is 47 minutes with nothing in flight.
t "stuck: a lock held with nothing in flight is still stuck" True \
  "$(uf ff-stuck "u['lock']['stuck']")"
t "stuck: ...at the unchanged STUCK_AFTER_S" 600 \
  "$(uf ff-stuck "u['lock']['bound']")"
t "stuck: ...and the note says there is no session to blame" True \
  "$(uf ff-stuck "u['note'] == 'STUCK — duty run has held the lock for 47m with no session in flight, past 10m'")"
t "stuck: ...on a box still reported working" working "$(uf ff-stuck "u['state']")"

# An un-upgraded box: a START carrying no `timeout=` token, which is every line
# written before #538 put one there. Its reading and its WORDING must be what
# they are today — there is no bound to name that this box has told us about,
# and inventing one from the host's idea of the lane is the second source of
# truth this whole change refuses.
t "stuck: a START with no timeout= falls back to STUCK_AFTER_S" True \
  "$(uf ff-lane-legacy "u['lock']['stuck']")"
t "stuck: ...at that bound and no other" 600 \
  "$(uf ff-lane-legacy "u['lock']['bound']")"
t "stuck: ...worded exactly as it is today" \
  "STUCK — duty run has held the lock for 11m" \
  "$(uf ff-lane-legacy "u['note']")"
t "stuck: ...and names no ceiling it was never told" None \
  "$(uf ff-lane-legacy "u['lock']['ceiling']")"

# BOTH ENTRY POINTS, one decision. ff-lane-ping's probe reports no lock at all
# — the evidence poll had nothing to grade — and only the 10s heartbeat carries
# an age, so this verdict can only have come through fleet.py's overlay. The
# assertion that matters is not that it is stuck but that it reached the
# IDENTICAL sentence: two comparisons in two files is how the badge and the
# note come to disagree, and this file used to hold both.
#
# ONE snapshot, three assertions. Every other `uf` in this file re-reads
# /api/fleet and can afford to: the evidence tier's record is rebuilt from a
# file and is the same on every read. This overlay is not — it exists only
# while the box's ping is FRESH, and a ping that goes stale between two reads
# drops it, falling back to an evidence tier that by design sees no lock on
# this box. Asserting three properties from three fetches therefore asks for
# the overlay three times and needs it three times; capturing the snapshot the
# loop settled on asks once. The wait is for a state to exist, not for a
# scheduler to be quiet.
FF_PING_DL=$(( $(date +%s) + 40 ))
FF_PING_SNAP='{}'
while :; do
  FF_PING_SNAP="$(unit ff-lane-ping)"
  if [ "$(jqf "d['lock']['stuck']" <<<"$FF_PING_SNAP")" = True ]; then break; fi
  if [ "$(date +%s)" -ge "$FF_PING_DL" ]; then break; fi
  sleep 1
done
t "stuck: the ping tier reaches the verdict the evidence tier could not" True \
  "$(jqf "d['lock']['stuck']" <<<"$FF_PING_SNAP")"
t "stuck: ...borrowing the ceiling the evidence tier parsed" 3600 \
  "$(jqf "d['lock']['ceiling']" <<<"$FF_PING_SNAP")"
t "stuck: ...and spells the note the other tier spells, to the byte" \
  "$(uf ff-lane-over "u['note']")" "$(jqf "d['note']" <<<"$FF_PING_SNAP")"
# The same tier, in the direction that used to fire: the ping overlay sees
# ff-lane-build's 2400s every two seconds and must not escalate it. Under the
# old rule it was the FIRST thing to call that box stuck, six times a minute.
t "stuck: the ping tier does not escalate a healthy long build" False \
  "$(uf ff-lane-build "u['lock']['stuck']")"

# The knob keeps meaning what its documentation says. Driven in-process rather
# than against a second collector: what has to be proved is which clause the
# override reaches, and that is a property of the function, not of a server.
ff_stuck_case() {
  FF_SERVER="$FLOOR/server" CREW_FLOOR_STUCK_AFTER="$1" python3 - "$2" "$3" "$4" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["FF_SERVER"])
from floor.units import stuck_verdict
held = None if sys.argv[1] == "-" else int(sys.argv[1])
cur = None if sys.argv[2] == "-" else {"kind": sys.argv[2],
                                       "timeout": None if sys.argv[3] == "-" else int(sys.argv[3])}
lock, note = stuck_verdict(held, cur)
print(json.dumps({"stuck": lock["stuck"], "bound": lock["bound"], "held": lock["held"],
                  "ceiling": lock["ceiling"], "note": note}, sort_keys=True))
PY
}
ff_stuck() { ff_stuck_case "$@" | python3 -c "import json,sys;print(json.load(sys.stdin)['$5'])"; }

t "knob: CREW_FLOOR_STUCK_AFTER still bounds the no-session clause" 5000 \
  "$(ff_stuck 5000 4000 - - bound)"
t "knob: ...and a run under the raised bound is not stuck" False \
  "$(ff_stuck 5000 4000 - - stuck)"
t "knob: ...and one over it still is" True \
  "$(ff_stuck 5000 5001 - - stuck)"
# The failure the knob must not be able to cause: an operator who raised it to
# quieten the false alarm would, under a min()/max() reading, have silently
# raised every lane's ceiling with it and blinded the clause that works.
t "knob: raising it does not re-cap a declared ceiling" 3660 \
  "$(ff_stuck 99999 3661 build 3600 bound)"
t "knob: ...so a build past its own ceiling is still caught" True \
  "$(ff_stuck 99999 3661 build 3600 stuck)"
# And it cannot LOWER a declared ceiling either — the in-flight clause does not
# consult it in either direction.
t "knob: lowering it does not shrink a declared ceiling" False \
  "$(ff_stuck 60 2400 build 3600 stuck)"

# An age the function cannot use is not an age it publishes. The site this
# replaced guarded with `held is not None and held >= 0` and left the default
# None in the served record; the verdict must keep doing that, or a box whose
# clock ran backwards starts serving a negative `lock.held` to every reader of
# /api/fleet — including `rehearsal-app.sh`, which truthiness-tests the field.
t "age: a negative lock age publishes no age at all" None \
  "$(ff_stuck 600 -5 - - held)"
t "age: ...and reaches no verdict on it" False \
  "$(ff_stuck 600 -5 - - stuck)"
t "age: a missing lock age is the same" None \
  "$(ff_stuck 600 - - - held)"
t "age: ...and is likewise no verdict" False \
  "$(ff_stuck 600 - - - stuck)"
# ...while a usable one is still served, which is the half the guard above
# must not cost.
t "age: a usable lock age is served" 300 \
  "$(ff_stuck 600 300 - - held)"

# The one-function rule, at the source. The end-to-end cases above pass on two
# implementations that happen to agree today; this is what reds when the next
# edit re-derives the comparison in fleet.py, which is exactly how these two
# came apart the first time.
# Comments stripped first, and deliberately: the block above the overlay
# EXPLAINS why the threshold is not read here, and a check that reds on the
# explanation would be a check against documenting the rule.
if grep -vE '^[[:space:]]*#' "$FLOOR/server/floor/fleet.py" | grep -q 'STUCK_AFTER_S'; then
  fail "stuck: fleet.py owns no threshold of its own" \
       "the ping overlay still names STUCK_AFTER_S in code"
else
  ok "stuck: fleet.py owns no threshold of its own"
fi
if grep -q 'stuck_verdict' "$FLOOR/server/floor/fleet.py"; then
  ok "stuck: the ping overlay calls the one decision function"
else
  fail "stuck: the ping overlay calls the one decision function" \
       "fleet.py does not call stuck_verdict"
fi
# The comment that produced the bug. `run_session` has no ceiling of its own —
# session.sh passes the CALLER's $tmo to `timeout` — and the rule was derived
# from that one wrong number. It must not survive the fix and outlive it as
# justification for the next person to restore the constant.
if grep -q "run_session's own ceiling is 1800s" "$FLOOR/server/floor/ping.py"; then
  fail "stuck: ping.py no longer claims run_session has an 1800s ceiling" \
       "the claim that produced this bug is still in the source"
else
  ok "stuck: ping.py no longer claims run_session has an 1800s ceiling"
fi
if grep -q 'stuckLine(d)' "$FLOOR/src/app.js"; then
  ok "stuck: the panel names the bound it was judged against"
else
  fail "stuck: the panel names the bound it was judged against" \
       "app.js still renders the age alone"
fi
