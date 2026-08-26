#!/usr/bin/env bash
# shared/test/common/ledger.sh — standalone suite for shared/lib/common/ledger.sh.
#
# One suite per module at the mirrored relative path: this file covers that one
# and nothing else. The invariant is the layout, not this file (#507).
set -uo pipefail

# ../ : lib.sh lives beside the subject suites, one level up from the module
# tree, and derives HERE from itself so both depths resolve the same paths.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"

# --- seen-ledgers: ledger_filter / ledger_commit (the refire fix) ---------
# A wake whose signal is present but UNCHANGED must not re-launch a session;
# it may only wake on new-or-advanced activity. This is what stops the mention
# and held-discussion refire that burned the triage box's Fable quota.
LG="$TMP/ledger"
# cold ledger (first look): everything is new
t ledger-cold 2 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_commit "$LG"
# same state again: SUPPRESSED (the burn fix)
t ledger-suppress 0 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
# one timestamp advanced: only that id re-wakes
t ledger-advance "111 2026-07-24T20:30:00Z" "$(printf '111 2026-07-24T20:30:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG")"
# brand-new id wakes
t ledger-newid 1 "$(printf '333 2026-07-25T01:00:00Z\n' | ledger_filter "$LG" | n)"
# commit is monotonic: a stale (older) commit must not lower the mark
printf '111 2026-07-24T20:30:00Z\n' | ledger_commit "$LG"
printf '111 2026-07-01T00:00:00Z\n' | ledger_commit "$LG"
t ledger-monotonic 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"
# empty input is safe and preserves the ledger (no session -> nothing to commit)
printf '' | ledger_commit "$LG"
t ledger-empty-safe 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"

# cross-repo collision: discussion numbers are PER-REPO but the ledger is one
# file across every repo in repos.txt, so keys must be repo-qualified. After
# committing ceremony#1, an unchanged/older rig#1 must still wake — a bare "1"
# key would shadow it and triage would never see rig's discussion (codex, #16).
LG2="$TMP/ledger-disc"
printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_commit "$LG2"
t ledger-crossrepo-distinct 1 "$(printf 'heavy-duty/rig#1 2026-07-20T00:00:00Z\n' | ledger_filter "$LG2" | n)"
t ledger-crossrepo-samekey  0 "$(printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_filter "$LG2" | n)"

# --- ledger_suppressed: the exact inverse of ledger_filter (#59) ------------
# The two must partition the input between them. If they can ever disagree, the
# engine either pays for work it meant to suppress or goes quiet about work it
# meant to report — and the second is the dangerous one.
LG3="$TMP/ledger-inv"
printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | ledger_commit "$LG3"
IN3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T11:00:00Z\no/r#3 2026-07-27T09:00:00Z\n')"
# #1 unchanged -> suppressed; #2 advanced -> fresh; #3 unseen -> fresh
t suppressed-unchanged "o/r#1 2026-07-27T10:00:00Z" "$(printf '%s\n' "$IN3" | ledger_suppressed "$LG3")"
t suppressed-fresh-count 2 "$(printf '%s\n' "$IN3" | ledger_filter "$LG3" | n)"
# Partition: filter + suppressed together account for every input line, exactly
# once. Asserted rather than assumed — the set-arithmetic version of this that
# I wrote first reported NOTHING suppressed whenever the fresh list was empty.
t suppressed-partitions 3 "$(printf '%s\n' "$IN3" | { ledger_filter "$LG3"; printf '%s\n' "$IN3" | ledger_suppressed "$LG3"; } | n)"
t suppressed-disjoint 0 "$(comm -12 \
  <(printf '%s\n' "$IN3" | ledger_filter "$LG3" | sort) \
  <(printf '%s\n' "$IN3" | ledger_suppressed "$LG3" | sort) | n)"
# A cold ledger hides nothing.
t suppressed-cold 0 "$(printf 'o/r#9 2026-07-27T10:00:00Z\n' | ledger_suppressed "$TMP/nope" | n)"

# --- report_suppressed: stop paying, do NOT stop saying (#59) ---------------
# A ledger converts a burn into silence. An unactioned item is still a live
# board-invariant violation, so the suppressed set has to surface — but at one
# tick per five minutes, a line every tick would bury the log it informs. So:
# warn when the SET CHANGES, and again from scratch after it clears.
ST="$TMP/suppressed-state"
r1="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r1" in *"1 item(s)"*"o/r#1"*) r2=warned ;; *) r2="$r1" ;; esac
t report-first warned "$r2"
# Same set again: silent.
t report-repeat "" "$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
# Set grows: speaks again.
r3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r3" in *"2 item(s)"*) r4=warned ;; *) r4="$r3" ;; esac
t report-grew warned "$r4"
# Emptied: silent, and the state file goes, so a recurrence is reported afresh
# rather than being swallowed as "same as last time".
t report-cleared "" "$(printf '' | report_suppressed "$ST" "o/r: board")"
if [ -f "$ST" ]; then r5=kept; else r5=removed; fi
t report-state-removed removed "$r5"
r6="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r6" in *"1 item(s)"*) r7=warned ;; *) r7="$r6" ;; esac
t report-recurrence-speaks warned "$r7"
# Blank lines are not items and must not render as the malformed `()`.
r8="$(printf '\no/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$TMP/sup-blank" "review")"
case "$r8" in *'()'*) r9=MALFORMED ;; *) r9=clean ;; esac
t report-blank-line-format clean "$r9"

# An incomplete sweep cannot compare its partial set with the previous complete
# set. Preserve the state byte-for-byte; otherwise one flaky repo makes every
# healthy repo's standing suppression look changed twice (drop + return).
ST_PART="$TMP/sup-partial"
printf 'o/a#1 T1\no/b#1 T1\n' | report_suppressed "$ST_PART" "review" >/dev/null
before_part="$(cat "$ST_PART")"
printf 'o/a#1 T1\n' \
  | report_suppressed_if_complete 0 "$ST_PART" "review" >/dev/null
t report-partial-preserves-state "$before_part" "$(cat "$ST_PART")"
# The next complete steady set remains silent, proving the partial tick did not
# replace the state and manufacture a second warning when repo B returns.
t report-after-partial-still-settled "" \
  "$(printf 'o/a#1 T1\no/b#1 T1\n' \
      | report_suppressed_if_complete 1 "$ST_PART" "review")"

# --- suppression state must be PER REPO (#60 review) ------------------------
# Both duty modules call report_suppressed inside a per-repo loop. With ONE
# shared state file, repo B's set replaces repo A's, and a repo with nothing
# suppressed rm -f's the file outright — so A's unchanged set looks new on the
# next tick and warns again, every tick, on exactly the 3-repo production box
# this was written to protect. codex-bot and grok-bot both caught it; grok-bot
# reproduced the flip-flop with these helpers.
sup_says() { if grep -q 'item(s)'; then echo warned; else echo silent; fi; }
SUP_A='o/a#1 2026-07-27T10:00:00Z'
SUP_B='o/b#1 2026-07-27T10:00:00Z'

# Per-repo files: each repo settles independently and stays quiet.
STA="$TMP/sup.o_a"; STB="$TMP/sup.o_b"
printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" >/dev/null
t report-perrepo-a-settles silent "$(printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" | sup_says)"
t report-perrepo-b-settles silent "$(printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" | sup_says)"

# The shape that was wrong, kept as a negative control: sharing one file makes
# A speak again after B has been through it. If this ever reads `silent` the
# helper has changed and the per-repo keying above may no longer be load-bearing.
SUP_SHARED="$TMP/sup.shared"
printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$SUP_SHARED" "o/b: board" >/dev/null
t report-shared-state-refires warned "$(printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" | sup_says)"

# ...and the modules must actually key by repo, not just be capable of it.
for pair in "duty-triage.sh:suppressed-triage-board" "duty-builder.sh:suppressed-build"; do
  mod="${pair%%:*}"; sfile="${pair##*:}"
  if grep -qE "$sfile\.\\\$\{?(R|slug)" "$SHARED/lib/$mod"; then r1=perrepo; else r1=SHARED; fi
  t "suppression-state-perrepo-$mod" perrepo "$r1"
done

# --- every state signal is ledgered (#59) -----------------------------------
# The engine had TWO ledgers, both in triage, while builder and reviewer had
# none — so any signal cleared by an in-session action the agent may DECLINE
# re-fired a model session every tick forever. These pin the wiring: a new
# signal site added without a ledger is the regression.
for pair in "duty-triage.sh:.seen-triage-board" "duty-builder.sh:.seen-build" \
            "duty-review.sh:.seen-review" "duty-attention.sh:.seen-attention"; do
  mod="${pair%%:*}"; led="${pair##*:}"
  if grep -q "$led" "$SHARED/lib/$mod"; then r1=ledgered; else r1=UNGUARDED; fi
  t "signal-ledgered-$mod" ledgered "$r1"
  # ...and committed only after a session that actually completed.
  if grep -q 'RUN_SESSION_RC:-1}" -eq 0' "$SHARED/lib/$mod"; then r1=gated; else r1=UNGATED; fi
  t "ledger-commit-gated-$mod" gated "$r1"
  # ...and what it hides must be reported.
  if grep -q 'report_suppressed' "$SHARED/lib/$mod"; then r1=reported; else r1=SILENT; fi
  t "suppression-reported-$mod" reported "$r1"
done

# --- the fourth session shape: a session that died with its box (#478) -------
#
# run_session writes SESSION END on every path its own process survives. A
# session killed WITH the box survives none of them, so duty.log keeps a start
# nothing answers and every reader counts it as still running. These drive the
# reconciler over fixture logs, appending its output to the log it read exactly
# as tick.sh appends duty.sh's stdout — which is what makes the second pass
# below a real second pass rather than a re-read.

ORPH_BOOT="$(_session_boot_id)"
# A pid that is certainly not running: a child, reaped. Asserted rather than
# assumed. If this box ever handed the pid straight back out, every case below
# would read `live` and red for a reason that has nothing to do with the
# reconciler, so the fixture states its own precondition first.
: & ORPH_DEAD=$!
wait "$ORPH_DEAD" 2>/dev/null
if kill -0 "$ORPH_DEAD" 2>/dev/null; then r1=STILL-LIVE; else r1=dead; fi
t orphan-fixture-dead-pid-is-dead dead "$r1"

orph_fixture() { mkdir -p "$1/logs"; : >"$1/duty.log"; }

orph_start() {  # orph_start <dir> <ts> <kind> <key> <holder>
  printf '%s SESSION START kind=%s key=%s timeout=7200s log=%s/logs/%s.log%s\n' \
    "$2" "$3" "$4" "$1" "$3" "${5:+ holder=$5}" >>"$1/duty.log"
}

orph_end() {  # orph_end <dir> <ts> <kind> <key>
  printf '%s SESSION END kind=%s key=%s rc=0 dur=12s outcome=ok acted=yes reply_tail=\n' \
    "$2" "$3" "$4" >>"$1/duty.log"
}

# orph_pass <dir> [mutant] — one reconciler pass, output appended to the log it
# read. `alert` is captured rather than sent; everything else is the library.
# shellcheck disable=SC2317  # alert is reached from inside the library
orph_pass() (
  local dir="$1" mutant="${2:-}" alerts="$1/alerts"
  DUTY_DIR="$dir"; LOG_DIR="$dir/logs"; DUTY_TICK_ID='tick-orphan'
  SESSION_TERMINAL_THRESHOLD=3
  alert() { printf '%s\n' "$*" >>"$alerts"; }
  # shellcheck disable=SC1090
  [ -z "$mutant" ] || source "$mutant"
  session_reconcile_orphans >>"$dir/duty.log" 2>&1
)

orph_lines() { grep -F "outcome=$SESSION_ORPHAN_OUTCOME" "$1/duty.log" || true; }
orph_count() { orph_lines "$1" | n; }
orph_kv() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }

# orph_mutant <name> <sed-expr> — write a mutated copy of the module under test
# to $TMP/ledger-mutant-<name>.sh, and assert the sed BIT. A mutation probe
# that silently matched nothing would run the production code and report a kill
# it never made.
#
# The path is derived by the caller rather than printed here, and that is not a
# style choice: `$(orph_mutant …)` would run this in a subshell, where the `t`
# below increments a FAIL nobody ever reads and prints its diagnosis into the
# captured path. An inert probe would then be inert AND silent.
orph_mutant() {
  local name="$1" expr="$2" out="$TMP/ledger-mutant-$1.sh" applied
  sed "$expr" "$SHARED/lib/common/ledger.sh" >"$out"
  if cmp -s "$out" "$SHARED/lib/common/ledger.sh"; then applied=INERT; else applied=applied; fi
  t "orphan-mutation-$name-applies" applied "$applied"
}

# The three shapes the test plan names, in one log: an orphaned start, a
# live-held start, and a well-formed pair. Exactly one reconstruction is owed.
#
# Interleaved with what a real duty.log is mostly made of — tick markers, a
# WARN, and a SESSION SKIP. The SKIP is the one that has to be got right on
# purpose: it names the same kind and key as a start and is not an end, so a
# scanner reading "a SESSION line mentioning this key" instead of the two
# verbs would silently answer the orphan with it.
ORPH1="$TMP/orphan-basic"; orph_fixture "$ORPH1"
{
  printf '2026-08-14T03:00:00Z duty run start\n'
} >>"$ORPH1/duty.log"
orph_start "$ORPH1" 2026-08-14T03:00:01Z build  o/r#1  "$ORPH_DEAD.$ORPH_BOOT"
{
  printf '2026-08-14T03:05:00Z duty run start\n'
  printf '2026-08-14T03:05:00Z SESSION SKIP kind=build key=o/r#1 reason=budget over=sessions\n'
  printf '2026-08-14T03:05:00Z WARN: session budget: kind=build reached its ceiling\n'
} >>"$ORPH1/duty.log"
orph_start "$ORPH1" 2026-08-14T03:05:01Z review o/r#2  "$$.$ORPH_BOOT"
orph_start "$ORPH1" 2026-08-14T03:10:00Z triage board  "$ORPH_DEAD.$ORPH_BOOT"
orph_end   "$ORPH1" 2026-08-14T03:12:00Z triage board
orph_pass "$ORPH1"
ORPH1_LINE="$(orph_lines "$ORPH1")"

t orphan-reconciles-exactly-one 1 "$(orph_count "$ORPH1")"
t orphan-closes-the-dead-session "build|o/r#1" \
  "$(orph_kv "$ORPH1_LINE" kind)|$(orph_kv "$ORPH1_LINE" key)"
# The other half of D1, and the one an age threshold gets wrong: a build may
# legitimately run for two hours, so the live-held start must survive a
# reconciler that has no idea how old it is.
t orphan-live-holder-untouched 0 \
  "$(grep -cF "kind=review key=o/r#2 rc=- dur=- outcome=$SESSION_ORPHAN_OUTCOME" \
      "$ORPH1/duty.log" || true)"
t orphan-complete-pair-untouched 0 \
  "$(grep -cF "kind=triage key=board rc=- dur=- outcome=$SESSION_ORPHAN_OUTCOME" \
      "$ORPH1/duty.log" || true)"

# D2. The reconciler knows the session started and knows nobody is running it;
# it knows nothing whatever about how the session exited or how long it took.
t orphan-claims-no-rc  '-' "$(orph_kv "$ORPH1_LINE" rc)"
t orphan-claims-no-dur '-' "$(orph_kv "$ORPH1_LINE" dur)"
t orphan-names-the-start-it-answers 2026-08-14T03:00:01Z \
  "$(orph_kv "$ORPH1_LINE" started)"
t orphan-acted-is-unknown-not-no unknown "$(orph_kv "$ORPH1_LINE" acted)"
# "Distinguishable by its outcome ALONE" is a claim about the token, not about
# the rest of the line: no verdict run_session can reach may spell it. Read off
# session.sh's own assignments so a fourth observed verdict added there without
# a thought for this one reds here.
t orphan-outcome-is-no-observed-verdict 0 \
  "$(grep -c "verdict=$SESSION_ORPHAN_OUTCOME" "$SHARED/lib/common/session.sh" || true)"

# AC5. The reconstructed terminal answers the start, so a second tick finds
# nothing owed — and it does so without the reconstructed line becoming a
# read-back bound, which is what D4 words as "newest OBSERVED".
orph_pass "$ORPH1"
t orphan-second-pass-adds-nothing 1 "$(orph_count "$ORPH1")"

# D4. A kind's newest observed terminal is where its history is settled, and
# nothing at or before it is read again. The start below that line is older
# than the bound and stays open; the one above it is reconciled.
ORPH2="$TMP/orphan-bound"; orph_fixture "$ORPH2"
orph_start "$ORPH2" 2026-08-14T01:00:00Z build o/r#7 "$ORPH_DEAD.$ORPH_BOOT"
orph_end   "$ORPH2" 2026-08-14T02:00:00Z build o/r#8
orph_start "$ORPH2" 2026-08-14T03:00:00Z build o/r#9 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH2"
t orphan-bounded-read-back-reconciles-one 1 "$(orph_count "$ORPH2")"
t orphan-bounded-read-back-stops-at-the-newest-observed-end o/r#9 \
  "$(orph_kv "$(orph_lines "$ORPH2")" key)"

# The boot qualifier does the work the pid cannot. This holder's pid is THIS
# process — as live as a pid gets — and the session is still correctly read as
# gone, because it was dispatched on a boot that has ended.
ORPH3="$TMP/orphan-reboot"; orph_fixture "$ORPH3"
orph_start "$ORPH3" 2026-08-14T04:00:00Z build o/r#3 "$$.0000dead"
orph_pass "$ORPH3"
t orphan-previous-boot-is-gone-though-the-pid-lives 1 "$(orph_count "$ORPH3")"

# A start carrying no holder cannot be asked the question, and D1 requires both
# halves — so it is left open rather than answered on a guess. That covers both
# an engine older than this reconciler and the floor's own `operator` sessions,
# which fleet-floor/server/floor/actions.py writes into duty.log by hand.
ORPH4="$TMP/orphan-holderless"; orph_fixture "$ORPH4"
orph_start "$ORPH4" 2026-08-14T05:00:00Z operator floor ''
orph_pass "$ORPH4"
t orphan-holderless-start-is-never-answered 0 "$(orph_count "$ORPH4")"

# AC4/D3. Three box-kills on one lane over three ticks trip that lane's
# breaker, through the counter an observed TERMINAL already feeds and no second
# mechanism. Driven as three passes rather than one log carrying three orphans,
# because that is the shape the incident has: a box that kills itself, comes
# back, and does it again.
ORPH5="$TMP/orphan-breaker"; orph_fixture "$ORPH5"
for i in 1 2 3; do
  orph_start "$ORPH5" "2026-08-14T0$i:00:00Z" build "o/r#$i" "$ORPH_DEAD.$ORPH_BOOT"
  orph_pass "$ORPH5"
done
t orphan-breaker-counts-three 3 "$(orph_count "$ORPH5")"
t orphan-breaker-trips-the-kind tripped \
  "$(cut -f2 <"$ORPH5/.session-terminal.build" 2>/dev/null || echo NONE)"
t orphan-breaker-alerts-once 1 "$([ -e "$ORPH5/alerts" ] && wc -l <"$ORPH5/alerts" || echo 0)"
# ...and only that kind. A box that dies under review must not silence build.
t orphan-breaker-spares-other-kinds absent \
  "$([ -e "$ORPH5/.session-terminal.review" ] && echo PRESENT || echo absent)"
# A fourth tick with nothing new neither reconstructs nor counts, so the
# threshold measures box-kills and not reconciler passes.
orph_pass "$ORPH5"
t orphan-idle-pass-does-not-count 3 "$(cut -f1 <"$ORPH5/.session-terminal.build")"

# --- the three must-fail cases, each run against its own mutation ------------
#
# A case that cannot red under the defect it names proves nothing, so each of
# the test plan's three is re-driven here with the module mutated to reintroduce
# exactly that defect, and the case must come out the other way.

# Must fail: reconciling a live session.
# shellcheck disable=SC2016  # the sed matches the module's literal $pid
orph_mutant live 's/^  kill -0 "\$pid" 2>\/dev\/null$/  return 1/'
ORPH_M1="$TMP/ledger-mutant-live.sh"
ORPH6="$TMP/orphan-mut-live"; orph_fixture "$ORPH6"
orph_start "$ORPH6" 2026-08-14T06:00:00Z review o/r#2 "$$.$ORPH_BOOT"
orph_pass "$ORPH6" "$ORPH_M1"
t orphan-mutation-live-reconciles-a-running-session 1 "$(orph_count "$ORPH6")"

# Must fail: a reconstructed line carrying a fabricated dur.
orph_mutant dur 's/rc=- dur=-/rc=0 dur=0s/'
ORPH_M2="$TMP/ledger-mutant-dur.sh"
ORPH7="$TMP/orphan-mut-dur"; orph_fixture "$ORPH7"
orph_start "$ORPH7" 2026-08-14T07:00:00Z build o/r#4 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH7" "$ORPH_M2"
t orphan-mutation-dur-fabricates-a-measurement 0s "$(orph_kv "$(orph_lines "$ORPH7")" dur)"

# Must fail: double reconciliation on a second tick. The defect is a scanner
# that does not accept its OWN reconstructed terminal as the start's answer.
orph_mutant double \
  's/if (depth\[q\] > 0) { delete open/if (f["outcome"] != ORPHAN \&\& depth[q] > 0) { delete open/'
ORPH_M3="$TMP/ledger-mutant-double.sh"
ORPH8="$TMP/orphan-mut-double"; orph_fixture "$ORPH8"
orph_start "$ORPH8" 2026-08-14T08:00:00Z build o/r#5 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH8" "$ORPH_M3"
orph_pass "$ORPH8" "$ORPH_M3"
t orphan-mutation-double-reconciles-twice 2 "$(orph_count "$ORPH8")"

# --- the wiring, which no fixture above can reach ---------------------------
# The reconciler is worth nothing unless a tick calls it, and it must be called
# before any dispatch: that ordering is what makes an unanswered start mean
# "left by a previous run" rather than "started a moment ago by this one".
if grep -q '^session_reconcile_orphans$' "$SHARED/bin/duty.sh"; then r1=called; else r1=UNWIRED; fi
t orphan-reconciler-runs-at-tick-time called "$r1"
# Ordered against the duty module invocations themselves — the only things in
# this file that dispatch — and not against the string `run_session`, which
# duty.sh mentions in a comment above the call site and would score a pass on
# any placement at all.
t orphan-reconciler-runs-before-any-dispatch before \
  "$(awk '/^[[:space:]]*#/ { next }
          /^session_reconcile_orphans$/ { rec = NR }
          /(^|[^[:alnum:]_])duty_[a-z]+/ { if (!disp) disp = NR }
          END { print (rec && disp && rec < disp) ? "before" : "AFTER" }' \
      "$SHARED/bin/duty.sh")"
# duty.sh runs under `set -euo pipefail`, and this is called before the boot
# gate, so a non-zero return anywhere in it does not degrade the tick — it ENDS
# the tick, and a box whose duty.log has nothing to reconcile is the common
# case. Driven under the caller's own flags, in each state it can meet.
# shellcheck disable=SC2317  # alert is reached from inside the library
orph_strict() (  # orph_strict <dir>
  set -euo pipefail
  DUTY_DIR="$1"; LOG_DIR="$1/logs"; DUTY_TICK_ID='tick-strict'
  # Stubbed even though nothing here reaches the threshold that alerts: the
  # suite exports the box's real HOME, and the real `alert` reads a Telegram
  # token out of it. A case must not be one edit away from paging the operator.
  alert() { :; }
  session_reconcile_orphans >/dev/null 2>&1
  printf survived
)
ORPH9="$TMP/orphan-strict"; orph_fixture "$ORPH9"
t orphan-strict-empty-log survived "$(orph_strict "$ORPH9" || printf 'ABORTED(%s)' "$?")"
printf '2026-08-14T09:00:00Z duty run start\n' >>"$ORPH9/duty.log"
t orphan-strict-nothing-owed survived "$(orph_strict "$ORPH9" || printf 'ABORTED(%s)' "$?")"
orph_start "$ORPH9" 2026-08-14T09:00:01Z build o/r#6 "$ORPH_DEAD.$ORPH_BOOT"
t orphan-strict-with-an-orphan survived "$(orph_strict "$ORPH9" || printf 'ABORTED(%s)' "$?")"
t orphan-strict-missing-log survived \
  "$(orph_strict "$TMP/orphan-no-such-dir" || printf 'ABORTED(%s)' "$?")"

# ...and the start it reads has to carry the holder it asks about.
# shellcheck disable=SC2016  # match the module's literal $(_session_holder)
if grep -q 'SESSION START .*holder=\$(_session_holder)' "$SHARED/lib/common/session.sh"; then
  r1=stamped
else
  r1=UNSTAMPED
fi
t orphan-session-start-carries-its-holder stamped "$r1"

suite_finish
