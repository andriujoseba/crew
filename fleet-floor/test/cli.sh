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
    </dev/null > "$CL_TMP/out" 2>&1 || CL_RC=$?
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
# The roster loops, against a stub fleet.
#
# Nothing in this repo invoked cli/crew until now, and that is the whole reason
# #47 and #48 both reached a real host: `crew status` had NEVER worked on a
# populated fleet, and `crew up` — the steady-state convergence verb — had the
# same two defects. Both failed silently. The jq one printed a header and quit
# (rc=5, jq's runtime-error code, hidden by a `2>/dev/null` on jq itself); the
# stdin one exited 0 with N-1 boxes missing.
#
# The assertion that catches both is the same one, and it is a COUNT: a roster
# of six must produce six rows. #47 yields zero rows, #48 yields one.
# ---------------------------------------------------------------------------
echo
echo "== crew roster loops (stub fleet)"

CL_CREW_FLEET="$CL_HERE/fixtures/cli-fleet.txt"
CL_CREW_ROSTER="$CL_HERE/fixtures/cli-roster.txt"
CL_CREW_N="$(grep -cvE '^[[:space:]]*(#|$)' "$CL_CREW_ROSTER")"

# Fleet selection is directory-atomic. An explicit directory without its proof
# file is an error; a complete out-of-tree definition drives the normal loops.
CL_BAD_CONFIG="$CL_TMP/bad-config"
mkdir -p "$CL_BAD_CONFIG"
printf 'FLEET_HUMAN=wrong\n' >"$CL_BAD_CONFIG/fleet.conf"
CL_RC=0
CREW_CONFIG_DIR="$CL_BAD_CONFIG" "$CL_ROOT/cli/crew" profiles \
  >"$CL_TMP/config-out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'fleet.roster is required' "$CL_TMP/config-out"; then
  ok "crew config: explicit split-brain directory is refused"
else
  fail "crew config: explicit split-brain directory is refused" \
    "rc=$CL_RC $(cat "$CL_TMP/config-out")"
fi
CL_INCOMPLETE="$CL_TMP/incomplete-config"
mkdir -p "$CL_INCOMPLETE"
printf 'fixture claude builder\n' >"$CL_INCOMPLETE/fleet.roster"
CL_RC=0
CREW_CONFIG_DIR="$CL_INCOMPLETE" "$CL_ROOT/cli/crew" profiles \
  >"$CL_TMP/config-out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'missing: fleet.conf repos.txt' "$CL_TMP/config-out"; then
  ok "crew config: selected directory requires the identity trio"
else
  fail "crew config: selected directory requires the identity trio" \
    "rc=$CL_RC $(cat "$CL_TMP/config-out")"
fi
CL_CONFIG="$CL_TMP/operator-config"
mkdir -p "$CL_CONFIG"
cp "$CL_CREW_ROSTER" "$CL_CONFIG/fleet.roster"
printf 'FLEET_HUMAN=fixture\n' >"$CL_CONFIG/fleet.conf"
printf 'heavy-duty/crew\n' >"$CL_CONFIG/repos.txt"
CL_RC=0
PATH="$CL_TMP/bin:$PATH" FLOOR_FIXTURE="$CL_CREW_FLEET" \
FLOOR_STATE="$CL_TMP/crew-state" CREW_CONFIG_DIR="$CL_CONFIG" \
  env -u CREW_ROSTER timeout 60 "$CL_ROOT/cli/crew" status \
  </dev/null >"$CL_TMP/config-out" 2>&1 || CL_RC=$?
t "crew config: out-of-tree fleet drives roster loops" 0 "$CL_RC"

# crew_cmd ARGS... — cli/crew against the stub fleet, output in $CL_TMP/crew-out.
crew_cmd() {
  CL_RC=0
  PATH="$CL_TMP/bin:$PATH" \
  FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
  CREW_ROSTER="$CL_CREW_ROSTER" \
    timeout 60 "$CL_ROOT/cli/crew" "$@" </dev/null > "$CL_TMP/crew-out" 2>&1 || CL_RC=$?
}

crew_cmd status
t "crew status: exits 0 on a populated fleet" 0 "$CL_RC"

# One row per roster member. Counted by NAME rather than by line, so a banner
# or a note that wraps cannot inflate it.
CL_ROWS=0
while read -r cl_name _cl_rest; do
  [ -z "$cl_name" ] && continue
  grep -qE "^$cl_name " "$CL_TMP/crew-out" && CL_ROWS=$((CL_ROWS + 1))
done < <(grep -vE '^[[:space:]]*(#|$)' "$CL_CREW_ROSTER")
t "crew status: one row per roster box" "$CL_CREW_N" "$CL_ROWS"
if [ "$CL_ROWS" -ne "$CL_CREW_N" ]; then
  echo "  crew status said:"; sed 's/^/    /' "$CL_TMP/crew-out"
fi

# The per-branch facts the table is supposed to carry. Without these the count
# above could be satisfied by six rows that all say the same wrong thing.
if grep -qE '^cli-stopped +stopped' "$CL_TMP/crew-out"; then
  ok "crew status: a stopped box reads stopped"
else
  fail "crew status: a stopped box reads stopped" "$(grep '^cli-stopped' "$CL_TMP/crew-out")"
fi
if grep -qE '^cli-absent .*NOT CREATED' "$CL_TMP/crew-out"; then
  ok "crew status: an absent box says NOT CREATED"
else
  fail "crew status: an absent box says NOT CREATED" "$(grep '^cli-absent' "$CL_TMP/crew-out")"
fi
if grep -qE '^cli-noauth .*MISSING' "$CL_TMP/crew-out"; then
  ok "crew status: dead logins are FLAGGED, not blank"
else
  fail "crew status: dead logins are FLAGGED, not blank" "$(grep '^cli-noauth' "$CL_TMP/crew-out")"
fi
# The floor and this CLI must derive credential state from the SAME evidence.
# `rehearsal-app.sh` asserts they agree about every box on a real host, and
# that assertion only means anything while neither has a private source: when
# the floor stopped polling and started reading the engine's markers, a
# `crew status` still running `gh auth status` would have disagreed with it
# for real, on a real fleet, with nothing in CI able to see it.
CL_CLI="$CL_ROOT/cli/crew"
if grep -q 'auth_from_flow' "$CL_CLI"; then
  ok "crew status reads the flow markers, not a second source"
else
  fail "crew status reads the flow markers, not a second source" \
       "cmd_status does not call auth_from_flow"
fi
# Anchored INSIDE cmd_status: the live probes are still correct in `crew hire`,
# where a human is standing there to fix what they find. It is the per-box
# status loop that must not reintroduce them.
CL_STATUS_PROBE="$(awk '
  /^cmd_status\(\)/ { inf = 1; next }
  inf && /^}/         { inf = 0 }
  inf && /gh auth status|vendor_probe/ { print "PROBES"; exit }
' "$CL_CLI")"
if [ -z "$CL_STATUS_PROBE" ]; then
  ok "crew status makes no network auth probe of its own"
else
  fail "crew status makes no network auth probe of its own" \
       "cmd_status still calls gh auth status or vendor_probe"
fi
# Both readers must speak one vocabulary, or "they agree" is a string compare
# between two dialects.
for cl_word in nofail stale missing unknown; do
  if grep -q "$cl_word" "$CL_CLI" && grep -q "$cl_word" "$CL_FLOOR/server/probe.sh"; then
    ok "vocabulary '$cl_word' is shared by crew and probe.sh"
  else
    fail "vocabulary '$cl_word' is shared by crew and probe.sh" "only one side emits it"
  fi
done

if grep -qE '^cli-nothired .*not hired' "$CL_TMP/crew-out"; then
  ok "crew status: an unhired box says so"
else
  fail "crew status: an unhired box says so" "$(grep '^cli-nothired' "$CL_TMP/crew-out")"
fi

# `crew up` reads box info at its OWN call site and runs its own roster loop,
# so it needs its own coverage: #47 and #48 were each present twice, and
# fixing one copy would have left the convergence verb broken. --dry-run
# reaches both the info read and the loop while creating and hiring nothing.
crew_cmd up --dry-run
t "crew up --dry-run: exits 0" 0 "$CL_RC"
CL_SEEN=0
while read -r cl_name _cl_rest; do
  [ -z "$cl_name" ] && continue
  grep -qE "(^|[[:space:]])$cl_name:" "$CL_TMP/crew-out" && CL_SEEN=$((CL_SEEN + 1))
done < <(grep -vE '^[[:space:]]*(#|$)' "$CL_CREW_ROSTER")
t "crew up --dry-run: reaches every roster box" "$CL_CREW_N" "$CL_SEEN"
if [ "$CL_SEEN" -ne "$CL_CREW_N" ]; then
  echo "  crew up said:"; sed 's/^/    /' "$CL_TMP/crew-out"
fi

# --- stdin and box info are each read in exactly ONE place -----------------
# The counts above catch the two bugs as they manifested. These catch the
# DEFECTS, for any call site added later.
#
# Both #47 and #48 were present TWICE — once in `crew status`, once in
# `crew up` — because each call site carried its own copy of the tricky part:
# the jq filter, and the stdin redirect. Fixing one copy would have left the
# convergence verb broken. So the invariant is the funnel itself: one helper
# each, asserted by COUNT over the code with comments stripped (a bare grep
# matches this file's own explanations — a detector tripping on its own
# documentation, the same trap as the read-only detector that once matched a
# string probe.sh contained).
# Comment lines stripped, and backslash continuations JOINED: vendor_probe puts
# its stdin redirect two lines below the `box exec`, so a per-line grep would
# report the one call site that has always been correct.
cl_code() {
  grep -vE '^[[:space:]]*#' "$CL_ROOT/cli/crew" | sed -e :a -e '/\\$/N; s/\\\n//; ta'
}
# `box exec "` — an actual invocation, always `box exec "$name"`. Deliberately
# not a bare `box exec`: cmd_floor's banner says "polling … over 'box exec'" in
# prose, and a detector that trips on its own documentation is the trap this
# suite has already been caught by twice.
cl_box_execs() { cl_code | grep -E 'box exec "'; }

# `box exec` forwards stdin like ssh, so ONE unredirected call inside a
# `while read … done < <(read_roster)` drains the roster: the loop ends after a
# single box, quietly, rc=0. Three call sites are legitimate — bxn pins
# /dev/null, while bxput and vendor_probe deliberately ship a named file.
CL_EXECS="$(cl_box_execs | grep -c . || true)"
t "crew: box exec appears only in bxn, bxput and vendor_probe" 3 "${CL_EXECS:-0}"
if [ "${CL_EXECS:-0}" -ne 3 ]; then
  echo "  call sites:"; cl_box_execs | sed 's/^/    /'
fi
# shellcheck disable=SC2016  # matching the literal redirect text in the source
CL_BARE="$(cl_box_execs | grep -vcE '</dev/null|<"\$AGENTS_DIR|<"\$source_file' || true)"
t "crew: every box exec call site pins stdin" 0 "${CL_BARE:-0}"
if [ "${CL_BARE:-0}" -ne 0 ]; then
  echo "  unpinned:"
  # shellcheck disable=SC2016  # matching the literal redirect text in the source
  cl_box_execs | grep -vE '</dev/null|<"\$AGENTS_DIR|<"\$source_file' | sed 's/^/    /'
fi

# `box info --json` returns an array; the filter that read it as an object
# exited 5 and took the command with it. One helper, one filter to be right.
CL_RAWINFO="$(cl_code | grep -cE 'box info' || true)"
t "crew: box info is read only inside box_state" 1 "${CL_RAWINFO:-0}"

# ...and that helper must DEGRADE rather than die. `set -euo pipefail` plus a
# command substitution is what turned a jq error into a dead command, so the
# fallback is the load-bearing half of the fix, not decoration.
CL_BS="$(sed -n '/^box_state()/,/^}/p' "$CL_ROOT/cli/crew")"
if printf '%s' "$CL_BS" | grep -q '|| true' && printf '%s' "$CL_BS" | grep -q '{s:-?}'; then
  ok "crew: box_state degrades to '?' instead of killing the command"
else
  fail "crew: box_state degrades to '?' instead of killing the command" \
       "no '|| true' + '\${s:-?}' pair — the next payload shape change exits 5 again"
fi

# The stub must keep presenting the shape that made #47 possible. A stub
# "corrected" to a convenient bare object would let the bug straight back in,
# and every assertion above would still pass.
if grep -q '"state":{"status"' "$CL_HERE/stub-box" && grep -qE "^ +printf '\[\{" "$CL_HERE/stub-box"; then
  ok "stub-box: box info still returns an ARRAY with a state OBJECT"
else
  fail "stub-box: box info still returns an ARRAY with a state OBJECT" \
       "the fixture no longer reproduces the payload #47 died on"
fi

# --- hiring an off-roster box against production is refused (#51) ----------
# A leftover crew-drill-* box, hand-hired to re-arm it, became a second
# production agent racing the real fleet within one tick. The guard is
# structural — roster membership plus the registry the box would actually work
# — so it reaches an ad-hoc box named anything, and it lets a drill box be
# hired as soon as its registry is a sandbox.
mkdir -p "$CL_TMP/crew-state"
crew_cmd hire cli-hired
t "crew hire: an on-roster box is hired without a flag" 0 "$CL_RC"

# The production roster is authoritative. Explicit profile flags on one of its
# members used to be accepted, echoed as fact, then silently discarded in
# favour of the roster row by install_identity_args (#35 review).
CL_PROD_FLEET="$CL_TMP/prod-fleet.txt"
printf 'claude-builder running idle\n' >"$CL_PROD_FLEET"
CL_RC=0
PATH="$CL_TMP/bin:$PATH" \
FLOOR_FIXTURE="$CL_PROD_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
  env -u CREW_ROSTER timeout 60 "$CL_ROOT/cli/crew" \
    hire claude-builder --agent claude --role reviewer \
    </dev/null >"$CL_TMP/crew-out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] &&
   grep -q 'claude-builder is declared as agent=claude role=builder' "$CL_TMP/crew-out" &&
   grep -q 'roster in force is authoritative' "$CL_TMP/crew-out"; then
  ok "crew hire: explicit profile for a production member is REFUSED"
else
  fail "crew hire: explicit profile for a production member is REFUSED" \
       "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi

# Same box, off the roster: production registry, so it must be refused.
CL_OFFROSTER="$CL_TMP/offroster.txt"
grep -vE '^cli-hired' "$CL_CREW_ROSTER" > "$CL_OFFROSTER"
crew_off() {
  CL_RC=0
  PATH="$CL_TMP/bin:$PATH" \
  FLOOR_FIXTURE="$CL_CREW_FLEET" FLOOR_STATE="$CL_TMP/crew-state" \
  CREW_ROSTER="$CL_OFFROSTER" \
    timeout 60 "$CL_ROOT/cli/crew" "$@" </dev/null > "$CL_TMP/crew-out" 2>&1 || CL_RC=$?
}
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -ne 0 ] && grep -q 'PRODUCTION registry' "$CL_TMP/crew-out"; then
  ok "crew hire: off-roster + production registry is REFUSED"
else
  fail "crew hire: off-roster + production registry is REFUSED" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# The refusal must be overridable, or an operator who means it has no way
# through and will reach for something worse.
crew_off hire cli-hired --role builder --agent claude --allow-offroster
if [ "$CL_RC" -eq 0 ] && grep -q 'allow-offroster' "$CL_TMP/crew-out"; then
  ok "crew hire: --allow-offroster arms it, and says that is what happened"
else
  fail "crew hire: --allow-offroster arms it, and says that is what happened" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
# A narrowed registry is not production, so the same off-roster box is fine —
# which is the state drill/rehearsal.sh leaves a drill box in while it runs.
echo "drill-host/crew-drill-sandbox" > "$CL_TMP/crew-state/cli-hired.repos"
crew_off hire cli-hired --role builder --agent claude
if [ "$CL_RC" -eq 0 ]; then
  ok "crew hire: off-roster with a NARROWED registry is allowed"
else
  fail "crew hire: off-roster with a narrowed registry is allowed" "rc=$CL_RC $(cat "$CL_TMP/crew-out")"
fi
rm -f "$CL_TMP/crew-state/cli-hired.repos"

# The registry must be PRINTED either way: #51's second bullet. A guard that
# only speaks up when it refuses leaves the normal path as silent as before.
crew_cmd hire cli-hired --force
if grep -q '  registry:' "$CL_TMP/crew-out"; then
  ok "crew hire: prints the registry it is arming against"
else
  fail "crew hire: prints the registry it is arming against" "$(cat "$CL_TMP/crew-out")"
fi

# --- one bad box must not abort the fleet (#49) ----------------------------
# crew's top-level `set -e` killed hire-all on the first failure, so a single
# box with an unusable ~/crew blocked every box after it. Asserted over the
# source: the fixture fleet has no way to make a hire fail part-way.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'if hire_box "\$name" "\$agent" "\$role" "\$ref" 0; then' "$CL_ROOT/cli/crew"; then
  ok "crew hire-all: a failing box is caught, not fatal"
else
  fail "crew hire-all: a failing box is caught, not fatal" "the bare hire_box call is back — set -e will abort the fleet"
fi
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'hire-all: \$hired hired, \$failed failed' "$CL_ROOT/cli/crew"; then
  ok "crew hire-all: summarises what it could not do"
else
  fail "crew hire-all: summarises what it could not do" "no failure summary — a partial fleet reads as a whole one"
fi
# ...and the repair the bug actually needed: verify where ~/crew's origin
# POINTS, not just that the directory exists.
if grep -q 'remote get-url origin' "$CL_ROOT/cli/crew" &&
   grep -q 'remote set-url origin' "$CL_ROOT/cli/crew"; then
  ok "crew hire: repoints a ~/crew whose origin has vanished"
else
  fail "crew hire: repoints a ~/crew whose origin has vanished" \
       "hire still guards only on the directory; a stale bundle remote will fatal again"
fi


# --- a drill must never need to edit the tracked roster --------------------
# Editing fleet.roster to point a drill at a subset is not a tidiness point: the
# #51 registry guard keys on ROSTER MEMBERSHIP, so a drill box listed in
# fleet.roster is a fleet member as far as every safety check is concerned.
# That is how three leftover drill boxes came to be armed against production.
#
# So both readers take an override, and the drill feeds ONE file to all three
# consumers — the collector, the `crew status` it compares against, and its own
# counts. An agreement assertion across two different rosters is worse than no
# assertion, because it looks like one.
echo
echo "== roster overrides (drilling without touching fleet.roster)"

crew_floor --local --port 8892 --roster "$CL_CREW_ROSTER"; CL_OUT="$(cl_out)"
if printf '%s' "$CL_OUT" | grep -qF "$CL_CREW_ROSTER"; then
  ok "cli: crew floor --roster is echoed in the banner"
else
  fail "cli: crew floor --roster is echoed in the banner" "$CL_OUT"
fi
crew_floor --local --port 8891 --roster /nonexistent/roster.txt; CL_OUT="$(cl_out)"
if [ "$CL_RC" -ne 0 ] && printf '%s' "$CL_OUT" | grep -q "no roster at"; then
  ok "cli: a missing --roster is named at startup"
else
  fail "cli: a missing --roster is named at startup" "rc=$CL_RC out=$CL_OUT"
fi
crew_floor --local --port 8890; CL_OUT="$(cl_out)"
if printf '%s' "$CL_OUT" | grep -q '^  roster '; then
  ok "cli: crew floor always prints the roster it watches"
else
  fail "cli: crew floor always prints the roster it watches" "$CL_OUT"
fi

# The drill must hand the SAME path to every reader. Asserted over the source:
# a real run needs a host with boxes, and the property wanted is "one list",
# which no single invocation demonstrates.
CL_DRILL_APP="$CL_ROOT/drill/rehearsal-app.sh"
for CL_V in CREW_FLOOR_ROSTER CREW_ROSTER; do
  # shellcheck disable=SC2016  # matching the literal source assignment
  if grep -qE "^export $CL_V=\"\\\$ROSTER\"" "$CL_DRILL_APP"; then
    ok "drill: $CL_V comes from --roster"
  else
    fail "drill: $CL_V comes from --roster" \
         "the collector and the CLI can now be compared across two different rosters"
  fi
done
# ...and nothing may still read fleet.roster directly, which would silently
# reintroduce exactly that split.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
CL_DIRECT="$(grep -vE '^[[:space:]]*#' "$CL_DRILL_APP" | grep -cE '\$ROOT/examples/fleet\.roster' || true)"
t "drill: examples/fleet.roster is read only as the --roster default" 1 "${CL_DIRECT:-0}"
if [ "${CL_DIRECT:-0}" -ne 1 ]; then
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
  grep -nvE '^[[:space:]]*#' "$CL_DRILL_APP" | grep -E '\$ROOT/examples/fleet\.roster' | sed 's/^/    /'
fi

# --- a clone must not be handed the sizing flags (box refuses them) --------
# `box new --from` rejects --cpu/--memory/--disk outright: "a clone carries its
# source's resources". crew passed them anyway, so every roster line with a
# 4th-column gold snapshot died at create. Never caught because no roster line
# has ever had one — the same never-exercised path as #47 and #48.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
CL_FROM="$(sed -n '/if \[ -n "\$from" \]; then/,/^  else/p' "$CL_ROOT/cli/crew")"
if printf '%s' "$CL_FROM" | grep -q 'box new --name' &&
   ! printf '%s' "$CL_FROM" | grep -q -- '--cpu'; then
  ok "crew: a --from clone is created without the sizing flags"
else
  fail "crew: a --from clone is created without the sizing flags" \
       "box new --from refuses --cpu/--memory/--disk; every gold-snapshot roster line would fail"
fi
# The role profile's sizing does not apply to a clone, and that must be SAID —
# a builder minted from a reviewer-sized gold comes up undersized either way,
# but silently is how it gets discovered under load.
if printf '%s' "$CL_FROM" | grep -qi 'inherits'; then
  ok "crew: a clone says its resources are inherited, not from the role profile"
else
  fail "crew: a clone says its resources are inherited, not from the role profile" \
       "no note about the role profile's sizing being ignored"
fi

# The status table must fit the names it prints. `crew-drill-reviewer` is 19
# characters and overflowed an 18-wide column, shifting every field after it.
CL_W="$(sed -n "s/^  local fmt='%-\([0-9]*\)s .*/\1/p" "$CL_ROOT/cli/crew")"
CL_LONGEST=0
while read -r cl_name _cl_rest; do
  [ -z "$cl_name" ] && continue
  [ "${#cl_name}" -gt "$CL_LONGEST" ] && CL_LONGEST="${#cl_name}"
done < <(cat "$CL_ROOT/examples/fleet.roster" "$CL_HERE/fixtures/roster.txt" \
              "$CL_HERE/fixtures/cli-roster.txt" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)')
# Drill boxes are crew-drill-<role>; the longest role is 'reviewer'.
[ "$CL_LONGEST" -lt 19 ] && CL_LONGEST=19
if [ -n "$CL_W" ] && [ "$CL_W" -gt "$CL_LONGEST" ]; then
  ok "crew status: MEMBER column ($CL_W) is wider than the longest box name ($CL_LONGEST)"
else
  fail "crew status: MEMBER column is wider than the longest box name" \
       "column=${CL_W:-?} longest=$CL_LONGEST — the row's remaining fields shift right"
fi


# --- the drill's own harness -----------------------------------------------
# Every check below is a bug that cost a live session on a real host. They are
# all the same shape: a precondition or a premise that does not hold, reported
# as a verdict about the thing under test.
echo
echo "== drill harness (preconditions, artifacts, defaults)"

CL_APP="$CL_ROOT/drill/rehearsal-app.sh"

# --drill-roles generates the roster from the crew-drill-<role> convention, so
# nobody hand-maintains a second copy of a naming rule rehearsal.sh owns.
# Deliberately run WITHOUT a `box` on PATH, so the drill stops at the host check
# — the first thing after roster generation. Reaching that message proves the
# flag parsed and the generated roster passed the `[ -f ]` guard, without
# starting a collector. Standalone this happens for free; sourced from run.sh
# the stub-box is on PATH, which is why the path is stripped explicitly rather
# than assumed (this assertion failed exactly that way once).
CL_NOBOX_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$CL_TMP/bin" | paste -sd: -)"
if PATH="$CL_NOBOX_PATH" command -v box >/dev/null 2>&1; then
  skip "drill: --drill-roles parses and reaches the host check" "a real box CLI is on PATH"
else
  CL_RC=0
  PATH="$CL_NOBOX_PATH" "$CL_APP" --drill-roles "triage builder" >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
  if grep -q "no 'box' on PATH" "$CL_TMP/app.out"; then
    ok "drill: --drill-roles parses and reaches the host check"
  else
    fail "drill: --drill-roles parses and reaches the host check" "$(head -3 "$CL_TMP/app.out")"
  fi
fi
CL_RC=0; "$CL_APP" --drill-roles triage --roster /tmp/x >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'alternatives, not both' "$CL_TMP/app.out"; then
  ok "drill: --roster and --drill-roles are mutually exclusive"
else
  fail "drill: --roster and --drill-roles are mutually exclusive" "rc=$CL_RC $(cat "$CL_TMP/app.out")"
fi
CL_RC=0; "$CL_APP" --drill-roles nosuchrole >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q "unknown role" "$CL_TMP/app.out"; then
  ok "drill: --drill-roles refuses a role that is not a role"
else
  fail "drill: --drill-roles refuses a role that is not a role" "rc=$CL_RC $(cat "$CL_TMP/app.out")"
fi
CL_RC=0; "$CL_APP" --roster /nonexistent/r.txt >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q 'no roster at' "$CL_TMP/app.out"; then
  ok "drill: a missing --roster is named before anything starts"
else
  fail "drill: a missing --roster is named before anything starts" "rc=$CL_RC $(cat "$CL_TMP/app.out")"
fi

# The browser precondition must check for a BROWSER, not only the module.
# playwright-core ships without browsers on purpose, so `npm i playwright-core`
# flipped this from a clean skip to a run that died on a missing binary — and
# emitted three failures, one of which blamed the read-only walk. A missing
# dependency must never read as a broken floor.
if grep -q 'PW_CHROME' "$CL_APP" && grep -q 'no browser found' "$CL_APP"; then
  ok "drill: a missing browser is its own named skip, not a walk failure"
else
  fail "drill: a missing browser is its own named skip, not a walk failure" \
       "the precondition still checks only that playwright-core is installed"
fi
# ...and it must find a system Chrome itself, the same probe CI does.
CL_PROBE="$(grep -cE '/usr/bin/google-chrome|/opt/google/chrome' "$CL_APP" || true)"
if [ "${CL_PROBE:-0}" -ge 1 ]; then
  ok "drill: probes the usual browser paths so PW_CHROME is an override"
else
  fail "drill: probes the usual browser paths so PW_CHROME is an override" \
       "PW_CHROME is required knowledge again"
fi

# The no-vacuity check must not count something structurally impossible. The
# collector runs at CREW_FLOOR_INTERVAL=3600, so it polls ONCE at startup; the
# walk reads its cached answer over HTTP and never touches the box layer. The
# old check counted probes inside the walk's window and therefore failed every
# run, including one that had just made 15 assertions on a live fleet.
# Comments stripped: the drill EXPLAINS why the old check was removed, and a
# bare grep matched that explanation — a detector tripping on its own
# documentation, which this file has now been caught by three times.
if grep -vE '^[[:space:]]*#' "$CL_APP" | grep -q "read-only walk still exercised the real fleet"; then
  fail "drill: no-vacuity check does not count probes that cannot happen" \
       "the probe-window check is back; it cannot pass at CREW_FLOOR_INTERVAL=3600"
else
  ok "drill: no-vacuity check does not count probes that cannot happen"
fi
# What replaced it must still guard the real risk: an EMPTY receipt would make
# "issued no control command" pass forever.
if grep -q 'the box-call receipt is real' "$CL_APP"; then
  ok "drill: still proves the box-call receipt is not empty"
else
  fail "drill: still proves the box-call receipt is not empty" \
       "nothing checks the wrapper recorded anything, so the no-control assertion is vacuous"
fi

# Screenshots are described in browser.js as "for humans" — they must survive
# teardown. They were written into $TMP and rm -rf'd on exit, every run.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'node .*browser\.js.*"\$SHOTS"' "$CL_APP"; then
  ok "drill: screenshots go to a directory that outlives the run"
else
  fail "drill: screenshots go to a directory that outlives the run" \
       "the walk still writes into \$TMP, which teardown deletes"
fi
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -qE 'rm -rf -- "\$TMP"' "$CL_APP" && ! grep -qE 'rm -rf.*\$SHOTS' "$CL_APP"; then
  ok "drill: teardown does not delete the screenshots"
else
  fail "drill: teardown does not delete the screenshots" "the shots directory is removed on exit"
fi

# Watching the walk drive: headless must be a choice, not a hardcode.
CL_BJS2="$CL_HERE/browser.js"
if grep -q 'FLOOR_TEST_HEADED' "$CL_BJS2" && grep -q 'headless: !HEADED' "$CL_BJS2"; then
  ok "browser.js: headed mode is available for watching a walk"
else
  fail "browser.js: headed mode is available for watching a walk" "headless is not overridable"
fi
if grep -q 'FLOOR_TEST_SLOWMO' "$CL_BJS2" && grep -q 'slowMo' "$CL_BJS2"; then
  ok "browser.js: slowMo is available"
else
  fail "browser.js: slowMo is available" "no pacing control"
fi
# CI must never turn them on — headed needs a display, and a slowed walk in CI
# is a timeout waiting to happen.
if grep -qE 'FLOOR_TEST_(HEADED|SLOWMO)' "$CL_ROOT/.github/workflows/shared-ci.yml"; then
  fail "CI does not enable headed/slowMo" "CI has no display and no time for it"
else
  ok "CI does not enable headed/slowMo"
fi

# The drill's default source must be the tracked mainline. It defaulted to
# dan-claude-bot/crew @ crew/shared-duty — a fork branch from the #16 era — so
# a flagless drill rehearsed code the fleet does not deploy, long after that
# branch merged.
CL_DRILL_SH="$CL_ROOT/drill/rehearsal.sh"
if grep -qE '^REF=.*main' "$CL_DRILL_SH" && grep -qE '^REMOTE=.*heavy-duty/crew' "$CL_DRILL_SH"; then
  ok "drill: defaults to the tracked mainline, not a fork branch"
else
  fail "drill: defaults to the tracked mainline, not a fork branch" \
       "$(grep -E '^(REF|REMOTE)=' "$CL_DRILL_SH" | tr '\n' ' ')"
fi

# rehearsal-all must point the app drill at the boxes it just drilled. Falling
# through to fleet.roster meant comparing the real fleet's members, which do not
# exist on a drill host: three "NOT CREATED vs offline" agreements about nothing.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q -- '--drill-roles "\${DRILLED# }" --agent "\$AGENT"' "$CL_ROOT/drill/rehearsal-all.sh"; then
  ok "rehearsal-all: the app drill sees the boxes this run built, with their agent"
else
  fail "rehearsal-all: the app drill sees the boxes this run built, with their agent" \
       "roles and agent must travel together — a correct role list with a defaulted agent probes the wrong vendor"
fi

# --- the agent column is generated from something TRUE (all three reviewers) --
# `rehearsal-all.sh --agent codex` drilled codex boxes and then generated an app
# roster claiming `claude`, because --agent reached rehearsal.sh but never the
# app phase. The column is load-bearing: floor.py feeds it to probe.sh to pick
# agents/<agent>.conf, and crew status feeds it to vendor_probe. So every
# non-default rehearsal probed the wrong vendor and reported the fleet
# auth-unhealthy — while the agreement assertions stayed GREEN, because both
# readers share the one wrong file. Consistent, wrong data.
#
# That is this PR's own defect class one layer up: "generated, it cannot drift"
# only holds if ALL of it is generated from something true. The role came from
# the drill; the agent silently did not.
if grep -q -- '--agent)         DRILL_AGENT=' "$CL_APP"; then
  ok "drill: rehearsal-app takes an explicit --agent"
else
  fail "drill: rehearsal-app takes an explicit --agent" \
       "the agent is settable only through an undiscoverable env var"
fi
CL_RC=0; "$CL_APP" --drill-roles triage --agent nosuchagent >"$CL_TMP/app.out" 2>&1 || CL_RC=$?
if [ "$CL_RC" -ne 0 ] && grep -q "unknown agent" "$CL_TMP/app.out"; then
  ok "drill: an agent with no profile is refused, not written into the roster"
else
  fail "drill: an agent with no profile is refused, not written into the roster" \
       "rc=$CL_RC $(cat "$CL_TMP/app.out")"
fi
# Only roles whose drill reached a box; and the narrowing must be announced.
# shellcheck disable=SC2016  # matching the literal source text, not expanding it
if grep -q 'DRILLED="\$DRILLED \$role"' "$CL_ROOT/drill/rehearsal-all.sh" &&
   grep -q 'roles whose drill never reached a box are excluded' "$CL_ROOT/drill/rehearsal-all.sh"; then
  ok "rehearsal-all: excludes roles that never reached a box, and says so"
else
  fail "rehearsal-all: excludes roles that never reached a box, and says so" \
       "a failed role's absent box becomes a NOT-CREATED-vs-offline non-comparison, silently"
fi

# --- a declaration must be checkable against ground truth -------------------
# The reason the bug above was SILENT: nothing ever compared the roster's agent
# claim with what the box was actually installed as. Both readers took the
# claim on faith and handed it to the vendor probe, so a misdeclared agent is
# indistinguishable from a logged-out box — forever, on the real fleet too.
# Run probe.sh for real against a scratch DUTY_DIR, rather than grepping for
# the line: what matters is that it PARSES instance.conf correctly, and a
# source-grep would pass just as happily on a filter that emits nothing.
# Deliberately not added to fixtures/fleet.txt — three assertions in cases.sh
# hardcode a 15-box fleet and browser.js's scroll walk has been destabilised by
# fleet size before (browser.js:246). A 16th row is not worth that risk.
CL_PD="$CL_TMP/probe-duty"; mkdir -p "$CL_PD/conf"
printf 'BOT_AGENT=codex\nBOT_ROLES="builder"\n' > "$CL_PD/conf/instance.conf"
CL_PA="$(DUTY_DIR="$CL_PD" bash "$CL_FLOOR/server/probe.sh" </dev/null 2>/dev/null | sed -n 's/^::agent //p')"
t "probe: reports the agent the box was actually installed as" codex "$CL_PA"
# An unhired box has no instance.conf: the key must still be emitted, empty, so
# the floor can tell "no claim to check" from "claim disagrees".
CL_PD2="$CL_TMP/probe-duty-bare"; mkdir -p "$CL_PD2"
CL_PA2="$(DUTY_DIR="$CL_PD2" bash "$CL_FLOOR/server/probe.sh" </dev/null 2>/dev/null | grep -c '^::agent' || true)"
t "probe: an unhired box still emits the key, empty" 1 "${CL_PA2:-0}"
if grep -q 'agent_actual' "$CL_FLOOR/server/floor.py"; then
  ok "floor: compares the roster's agent claim against the box"
else
  fail "floor: compares the roster's agent claim against the box" "the claim is still taken on faith"
fi
if grep -q 'box_agent' "$CL_ROOT/cli/crew"; then
  ok "crew status: a failing vendor probe distinguishes logged-out from mislabelled"
else
  fail "crew status: a failing vendor probe distinguishes logged-out from mislabelled" \
       "MISSING still has two causes and names neither"
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
# NOTHING would satisfy "issued no control command" perfectly. Two halves, and
# they guard different things — the walk's own assertion count proves the WALK
# did something, and a non-empty receipt proves the RECEIPT is real (without the
# wrapper on PATH, "issued no control command" passes against an empty file
# forever). This used to be a single probe-count check that guarded neither and
# could never pass; see the drill-harness section above.
if grep -q 'browser walk reported its assertion count' "$CL_DRILL"; then
  ok "drill: proves the walk itself did something"
else
  fail "drill: proves the walk itself did something" "the assertion-count check is gone"
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

# ---------------------------------------------------------------------------
# crew init: a fresh operator definition, never an overwrite (#76)
# ---------------------------------------------------------------------------
echo
echo "== crew init"

CL_INIT_DIR="$CL_TMP/init-fleet"
CL_SHARED_BEFORE="$(
  find "$CL_ROOT/shared" -type f -print0 | sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
CL_RC=0
XDG_CONFIG_HOME="$CL_TMP/no-implicit-config" "$CL_ROOT/cli/crew" init "$CL_INIT_DIR" \
  >"$CL_TMP/init-out" 2>&1 || CL_RC=$?
t "crew init: fresh scaffold exits 0" 0 "$CL_RC"
for CL_INIT_FILE in fleet.roster fleet.conf repos.txt notify-repos.txt doctrine.conf; do
  if [ -f "$CL_INIT_DIR/$CL_INIT_FILE" ]; then
    ok "crew init: scaffolds $CL_INIT_FILE"
  else
    fail "crew init: scaffolds $CL_INIT_FILE" "missing from $CL_INIT_DIR"
  fi
done
if [ -d "$CL_INIT_DIR/agents" ]; then
  ok "crew init: scaffolds optional agents directory"
else
  fail "crew init: scaffolds optional agents directory" "missing agents/"
fi

CL_ROSTER_NAMES="$(grep -vE '^[[:space:]]*(#|$)' "$CL_INIT_DIR/fleet.roster" | awk '{print $1}')"
CL_REPORTED_NAMES="$(sed -n 's/^  \([^ ]*\) — by hand:.*/\1/p' "$CL_TMP/init-out")"
t "crew init: names every static login obligation" "$CL_ROSTER_NAMES" "$CL_REPORTED_NAMES"
if grep -q 'definition only; not a live auth check' "$CL_TMP/init-out"; then
  ok "crew init: labels the roster reading as static"
else
  fail "crew init: labels the roster reading as static" "$(cat "$CL_TMP/init-out")"
fi

CL_INIT_HASH_BEFORE="$(
  find "$CL_INIT_DIR" -type f -print0 | sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
CL_RC=0
XDG_CONFIG_HOME="$CL_TMP/no-implicit-config" "$CL_ROOT/cli/crew" init "$CL_INIT_DIR" \
  >"$CL_TMP/init-again-out" 2>&1 || CL_RC=$?
CL_INIT_HASH_AFTER="$(
  find "$CL_INIT_DIR" -type f -print0 | sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
if [ "$CL_RC" -ne 0 ] && grep -q 'refusing to overwrite' "$CL_TMP/init-again-out"; then
  ok "crew init: second run refuses loudly"
else
  fail "crew init: second run refuses loudly" "rc=$CL_RC $(cat "$CL_TMP/init-again-out")"
fi
t "crew init: refusal preserves every generated byte" "$CL_INIT_HASH_BEFORE" "$CL_INIT_HASH_AFTER"
CL_SHARED_AFTER="$(
  find "$CL_ROOT/shared" -type f -print0 | sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}'
)"
t "crew init: writes nothing under shared" "$CL_SHARED_BEFORE" "$CL_SHARED_AFTER"

rm -rf "$CL_TMP"

if [ -n "${CL_STANDALONE:-}" ]; then
  echo
  echo "== cli summary: $PASS ok, $SKIP skipped, ${#FAILS[@]} failed"
  [ "${#FAILS[@]}" -gt 0 ] && exit 1
  exit 0
fi
