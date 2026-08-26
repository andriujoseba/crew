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
t "state: cron silent -> offline"  offline  "$(uf ff-silent  "u['state']")"
t "clock: three-hours-behind healthy box is not silent" False "$(uf ff-skew-behind "u['state'] == 'offline'")"
t "clock: three-hours-ahead healthy box is not silent"  False "$(uf ff-skew-ahead  "u['state'] == 'offline'")"
t "clock: cron age comes from box-side tickage" 110 "$(uf ff-skew-behind "u['cron']['age']")"
t "clock: session age survives negative skew" 10 "$(uf ff-skew-behind "u['sessions'][0]['ago']")"
t "clock: session age survives positive skew" 10 "$(uf ff-skew-ahead "u['sessions'][0]['ago']")"
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
t "agreement: skewed box reaches the real up-comparison branch" up \
  "$(agreement_case "$(uf ff-skew-behind "u['state']")" 'ff-skew-behind running' '' False)"
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
t "sessions: parsed"          1    "$(uf ff-working "len(u['sessions'])")"
t "sessions: rc carried"      0    "$(uf ff-working "u['sessions'][0]['rc']")"
t "sessions: outcome carried" ok   "$(uf ff-working "u['sessions'][0]['out']")"
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
