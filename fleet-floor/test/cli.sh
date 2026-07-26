# shellcheck shell=bash  # sourced by run.sh, so it has no shebang of its own
# fleet-floor/test/cli.sh — `crew floor` argument handling and preflight.
#
# Sourced by test/run.sh (which provides ok/fail/t/skip); runnable standalone.
#
# The CLI is the only part an operator actually types, and it is where the
# auth decision is made: a page that can power-cycle boxes must never come up
# without a password. None of that was covered by the collector or page tests,
# which start floor.py directly and hand it an env.
set -uo pipefail

CL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CL_FLOOR="$(dirname "$CL_HERE")"
CL_ROOT="$(dirname "$CL_FLOOR")"

if ! declare -F ok >/dev/null; then
  PASS=0 SKIP=0
  declare -a FAILS=()
  ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
  fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
  skip() { echo "skip $1${2:+  — $2}"; SKIP=$((SKIP + 1)); }
  t()    { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
  CL_STANDALONE=1
fi

CL_RC=0
CL_TMP="$(mktemp -d)"
mkdir -p "$CL_TMP/bin"
# `crew floor` calls need_box first, so a `box` must exist on PATH; it is never
# actually invoked by the paths under test here.
ln -sf "$CL_HERE/stub-box" "$CL_TMP/bin/box"
export FLOOR_FIXTURE="$CL_HERE/fixtures/fleet.txt"
export FLOOR_STATE="$CL_TMP/state"
export CREW_FLOOR_ROSTER="$CL_HERE/fixtures/roster.txt"

echo
echo "== crew floor CLI"

# crew_floor ARGS... — runs a short-lived `crew floor`, leaving its combined
# output in $CL_TMP/out and its exit status in $CL_RC.
#
# Deliberately NOT `CL_OUT="$(crew_floor ...)"`: command substitution runs the
# function in a subshell, so a CL_RC assigned inside it never reaches the
# caller and every exit-status assertion silently reads 0. That cost a round.
crew_floor() {
  CL_RC=0
  PATH="$CL_TMP/bin:$PATH" timeout 4 "$CL_ROOT/cli/crew" floor "$@" \
    > "$CL_TMP/out" 2>&1 || CL_RC=$?
}
cl_out() { cat "$CL_TMP/out"; }

# --- argument errors must be refused, loudly and before anything starts -----
crew_floor --bogus; CL_OUT="$(cl_out)"
if [ "$CL_RC" -ne 0 ] && printf '%s' "$CL_OUT" | grep -q "unknown option"; then
  ok "cli: unknown option refused"
else
  fail "cli: unknown option refused" "rc=$CL_RC out=$CL_OUT"
fi

crew_floor --port; CL_OUT="$(cl_out)"
if [ "$CL_RC" -ne 0 ]; then ok "cli: --port with no value refused"
else fail "cli: --port with no value refused" "rc=0, out=$CL_OUT"; fi

crew_floor --pass; CL_OUT="$(cl_out)"
if [ "$CL_RC" -ne 0 ]; then ok "cli: --pass with no value refused"
else fail "cli: --pass with no value refused" "rc=0, out=$CL_OUT"; fi

# --- help ------------------------------------------------------------------
crew_floor --help; CL_OUT="$(cl_out)"
t "cli: --help exits 0" 0 "$CL_RC"
if printf '%s' "$CL_OUT" | grep -q "IP:PORT"; then ok "cli: --help explains what it serves"
else fail "cli: --help explains what it serves" "$CL_OUT"; fi
# The help must not stop mid-sentence — this block is extracted by a sed range,
# which is exactly the kind of thing that silently truncates when edited.
if printf '%s' "$CL_OUT" | tail -1 | grep -q '\.$'; then ok "cli: --help is not truncated"
else fail "cli: --help is not truncated" "last line: $(printf '%s' "$CL_OUT" | tail -1)"; fi
if printf '%s' "$CL_OUT" | grep -q "^cmd_floor"; then
  fail "cli: --help stops before the code" "the function body leaked into help"
else ok "cli: --help stops before the code"; fi

# --- the banner an operator reads -----------------------------------------
crew_floor --local --port 8899; CL_OUT="$(cl_out)"
if printf '%s' "$CL_OUT" | grep -q "http://127.0.0.1:8899/"; then ok "cli: --local prints a loopback URL"
else fail "cli: --local prints a loopback URL" "$CL_OUT"; fi
if printf '%s' "$CL_OUT" | grep -qi "loopback only"; then ok "cli: --local says it is loopback only"
else fail "cli: --local says it is loopback only" "$CL_OUT"; fi
if printf '%s' "$CL_OUT" | grep -q "plain HTTP"; then
  fail "cli: no cleartext warning on loopback" "warned about the network for a loopback bind"
else ok "cli: no cleartext warning on loopback"; fi

crew_floor --port 8898; CL_OUT="$(cl_out)"
if printf '%s' "$CL_OUT" | grep -q "plain HTTP"; then ok "cli: warns that a bound port sends the password in clear"
else fail "cli: warns that a bound port sends the password in clear" "$CL_OUT"; fi

# --- the auth decision -----------------------------------------------------
# A generated password must be generated, not a constant: two runs, two values.
crew_floor --local --port 8897
CL_P1="$(cl_out | sed -n 's/^  password  \([^ ]*\) .*/\1/p')"
crew_floor --local --port 8896
CL_P2="$(cl_out | sed -n 's/^  password  \([^ ]*\) .*/\1/p')"
if [ -n "$CL_P1" ] && [ -n "$CL_P2" ] && [ "$CL_P1" != "$CL_P2" ]; then
  ok "cli: generated passwords differ between runs"
else
  fail "cli: generated passwords differ between runs" "[$CL_P1] vs [$CL_P2]"
fi
if [ "${#CL_P1}" -ge 16 ]; then ok "cli: generated password is long enough (${#CL_P1})"
else fail "cli: generated password is long enough" "${#CL_P1} chars"; fi

crew_floor --local --port 8895 --pass hunter2; CL_OUT="$(cl_out)"
if printf '%s' "$CL_OUT" | grep -q "hunter2"; then
  fail "cli: an explicit password is not echoed" "the password was printed back"
else ok "cli: an explicit password is not echoed"; fi

# The collector itself must refuse to serve without one, whatever starts it.
CL_RC2=0
CREW_FLOOR_PASS="" CREW_FLOOR_PORT=8894 timeout 5 python3 "$CL_FLOOR/server/floor.py" \
  > "$CL_TMP/nopass.out" 2>&1 || CL_RC2=$?
if [ "$CL_RC2" -ne 0 ] && grep -q "refusing to serve" "$CL_TMP/nopass.out"; then
  ok "collector: refuses to serve with no password"
else
  fail "collector: refuses to serve with no password" "rc=$CL_RC2 $(cat "$CL_TMP/nopass.out")"
fi

# --- preflight -------------------------------------------------------------
# A missing index.html must be named, not surfaced as a stack trace or a 500
# on first request.
CL_RC3=0
CREW_FLOOR_PASS=x CREW_FLOOR_PORT=8893 CREW_FLOOR_INDEX=/nonexistent/index.html \
  timeout 5 python3 -c "
import os, sys
sys.argv = ['floor.py']
sys.path.insert(0, '$CL_FLOOR/server')
import floor
floor.INDEX = '/nonexistent/index.html'
try:
    floor.main()
except SystemExit as e:
    print(e); sys.exit(1)
" > "$CL_TMP/noindex.out" 2>&1 || CL_RC3=$?
if [ "$CL_RC3" -ne 0 ] && grep -qi "missing" "$CL_TMP/noindex.out"; then
  ok "collector: a missing index.html is named at startup"
else
  fail "collector: a missing index.html is named at startup" "rc=$CL_RC3 $(cat "$CL_TMP/noindex.out")"
fi


# ---------------------------------------------------------------------------
# The drill must never run the browser walk in a mutating mode.
#
# codex-bot's finding: gating that on --allow-control only moved the hazard.
# `--allow-control` without `--boxes` skips the narrowed control block, yet the
# browser walk would still pause whichever unit was on screen; and its
# `wake-silent` click is FLEET-WIDE, which --boxes cannot constrain even in
# principle. So the opt-in path broke the script's own guarantee.
#
# Asserted as an INVARIANT over the source rather than by running two argument
# combinations: the property wanted is "for ANY arguments, the walk is
# read-only", and two sampled invocations cannot show that. This can.
# ---------------------------------------------------------------------------
echo
echo "== drill: the browser walk cannot mutate a real fleet"

CL_DRILL="$CL_ROOT/drill/rehearsal-app.sh"
CL_INVOKES="$(grep -cE 'node .*fleet-floor/test/browser\.js' "$CL_DRILL" || true)"
t "drill: exactly one browser.js invocation" 1 "${CL_INVOKES:-0}"

# Every invocation must carry the read-only env on the SAME line.
CL_RO="$(grep -B1 -E 'node .*fleet-floor/test/browser\.js' "$CL_DRILL" | grep -cE 'FLOOR_TEST_READONLY=1' || true)"
t "drill: that invocation is read-only" 1 "${CL_RO:-0}"

# And no branch may hand it an empty/!=1 value, which is how the first fix
# reintroduced the mutating path under --allow-control.
CL_BAD="$(grep -cE 'FLOOR_TEST_READONLY="?\$|FLOOR_TEST_READONLY=""|FLOOR_TEST_READONLY=$' "$CL_DRILL" || true)"
t "drill: read-only is not computed from a variable" 0 "${CL_BAD:-0}"

# The narrowed control block still refuses to act without an explicit allowlist.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -qE 'elif \[ -z "\$BOXES" \]; then' "$CL_DRILL"; then
  ok "drill: --allow-control still requires --boxes"
else
  fail "drill: --allow-control still requires --boxes" "the allowlist guard is gone"
fi

# browser.js must actually honour the flag: no control click outside a
# !READONLY guard. Counted, so a new control added without the guard trips it.
CL_BJS="$CL_HERE/browser.js"
CL_GUARDS="$(grep -cE '!READONLY' "$CL_BJS" || true)"
if [ "${CL_GUARDS:-0}" -ge 3 ]; then
  ok "browser.js: control blocks are behind a READONLY guard (${CL_GUARDS})"
else
  fail "browser.js: control blocks are behind a READONLY guard" "only ${CL_GUARDS:-0} guards found; expected the pause, paused-box and fleet-wide blocks"
fi

# The walk demands fixture-only states (a hostile-log box, a first-session box,
# offline boxes) and must demand them ONLY of the fixture. kimi-bot found the
# drill running the same walk against a real fleet, where those boxes do not
# exist and a healthy fleet has nothing offline: two unconditional hard-fails,
# so "browser walk against the real fleet" could never pass on any host.
#
# Both halves are asserted, because either one alone silently breaks the split:
# run.sh not setting it loses the loud coverage the fixture exists to provide,
# and the drill setting it puts the always-red walk straight back.
if grep -qE '^export FLOOR_TEST_FIXTURE=1' "$CL_HERE/run.sh"; then
  ok "fixture gate: run.sh claims the fixture fleet"
else
  fail "fixture gate: run.sh claims the fixture fleet" \
       "without it the hostile/first-run/offline guards go quiet in the suite"
fi
# Comments stripped first. The drill EXPLAINS why it withholds this flag, and a
# bare `grep FLOOR_TEST_FIXTURE` matched that explanation -- a detector tripping
# on its own documentation, which is the same bug as the read-only detector that
# once matched a string probe.sh itself contained.
if grep -vE '^[[:space:]]*#' "$CL_DRILL" | grep -q 'FLOOR_TEST_FIXTURE='; then
  fail "fixture gate: the drill does NOT claim the fixture fleet" \
       "the drill sets FLOOR_TEST_FIXTURE; the walk will demand boxes a real fleet has no reason to have"
else
  ok "fixture gate: the drill does NOT claim the fixture fleet"
fi
# ...and the walk must actually consult it, rather than the flag being inert.
CL_GATED="$(grep -cE 'FIXTURE &&|if \(FIXTURE\)' "$CL_BJS" || true)"
if [ "${CL_GATED:-0}" -ge 3 ]; then
  ok "fixture gate: the walk gates its fixture-only demands (${CL_GATED})"
else
  fail "fixture gate: the walk gates its fixture-only demands" \
       "only ${CL_GATED:-0} gated sites; expected the hostile, first-run and offline demands"
fi

# The read-only receipt check MOVED here from run.sh; it did not evaporate.
# CI cannot make it honestly (no real fleet), the drill can (real boxes, and a
# logging wrapper ahead of the real `box` on PATH). A check that leaves CI and
# lands nowhere is indistinguishable from one that was deleted, so this suite
# holds the drill to it by name.
if grep -q 'read-only walk issued no control command' "$CL_DRILL"; then
  ok "drill: still asserts the read-only walk touched nothing"
else
  fail "drill: still asserts the read-only walk touched nothing" \
       "the check moved out of run.sh and is not in the drill either"
fi
# ...and it must be checking CALLS, not the flag it set itself. Without the
# wrapper on PATH there is no receipt to read, and the assertion above would
# pass against an empty file forever.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'exec "\$REAL_BOX"' "$CL_DRILL" && grep -q 'PATH="\$TMP/bin:\$PATH"' "$CL_DRILL"; then
  ok "drill: reads the real box calls, not just its own flag"
else
  fail "drill: reads the real box calls, not just its own flag" \
       "no logging wrapper ahead of the real box on PATH"
fi
# The companion no-vacuity check goes with it: a read-only mode that did
# NOTHING would satisfy "issued no control command" perfectly.
if grep -q 'read-only walk still exercised the real fleet' "$CL_DRILL"; then
  ok "drill: proves the read-only walk still did something"
else
  fail "drill: proves the read-only walk still did something" "the probe-count check is gone"
fi

# The two invariants below are about the NARROWED control block, not the walk;
# they hold whether or not this file drives a browser. #40 gained them while the
# walk was out of tree, so they are carried forward here rather than reverted --
# re-adding the browser must not quietly drop coverage that outlived it.

# Read-only by default: no control verb may run without ALLOW_CONTROL.
# shellcheck disable=SC2016  # matching the literal source text
if grep -qE 'if \[ "\$ALLOW_CONTROL" -ne 1 \]; then' "$CL_DRILL"; then
  ok "drill: control verbs are opt-in"
else
  fail "drill: control verbs are opt-in" "the ALLOW_CONTROL gate is gone"
fi

# Anything it does pause must be repaired on the way out, on every exit path.
if grep -q 'PAUSED_BY_DRILL' "$CL_DRILL" && grep -q 'trap cleanup EXIT' "$CL_DRILL"; then
  ok "drill: pauses are repaired on teardown"
else
  fail "drill: pauses are repaired on teardown" "no PAUSED_BY_DRILL/trap pairing"
fi


# ---------------------------------------------------------------------------
# Nothing may point at a test file that is not there.
#
# kimi-bot caught this on #40 by hand: after the page walk was lifted out,
# cases.sh still called test/stale.js "the browser side of this" and the test
# .gitignore still explained a playwright-core install, both describing files
# that had just left the tree. Nobody was wrong -- there was simply no check,
# so a reader had to notice. This PR puts those files back, which makes both
# comments true again, and asserts it so the next move re-breaks the build
# instead of shipping directions to a file that is gone.
#
# Same failure mode, in the same directory, as the "read-only" drill header
# that outlived the browser walk it described.
# ---------------------------------------------------------------------------
echo
echo "== docs point at files that exist"

CL_REFS="$(grep -rhoE 'test/[a-z][a-z-]*\.js' \
             "$CL_HERE"/*.sh "$CL_FLOOR/README.md" "$CL_ROOT/drill"/*.sh \
             "$CL_ROOT/.github/workflows"/*.yml 2>/dev/null | sort -u)"

# A grep that finds nothing would make every assertion below vacuous.
CL_NREFS="$(printf '%s' "$CL_REFS" | grep -c . || true)"
if [ "${CL_NREFS:-0}" -ge 4 ]; then
  ok "docs: found the js references to check (${CL_NREFS})"
else
  fail "docs: found the js references to check" "only ${CL_NREFS:-0}; the grep stopped matching, so the check below proves nothing"
fi

CL_DANGLING=""
for CL_REF in $CL_REFS; do
  [ -f "$CL_FLOOR/$CL_REF" ] || CL_DANGLING="$CL_DANGLING $CL_REF"
done
if [ -z "$CL_DANGLING" ]; then
  ok "docs: every referenced test file exists"
else
  fail "docs: every referenced test file exists" "dangling:$CL_DANGLING"
fi

# The .gitignore explains WHY node_modules is ignored. If the page half ever
# leaves again, that explanation goes with it.
if grep -q 'playwright-core' "$CL_HERE/.gitignore"; then
  if [ -f "$CL_HERE/browser.js" ]; then
    ok "docs: .gitignore explains playwright only while the page half is here"
  else
    fail "docs: .gitignore explains playwright only while the page half is here" \
         "no browser.js, but .gitignore still describes installing playwright-core"
  fi
else
  ok "docs: .gitignore makes no claim about playwright"
fi

rm -rf "$CL_TMP"

if [ -n "${CL_STANDALONE:-}" ]; then
  echo
  echo "== cli summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
  [ "${#FAILS[@]}" -gt 0 ] && exit 1
  exit 0
fi
