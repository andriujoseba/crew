#!/usr/bin/env bash
# rehearsal-all.sh — run drill/rehearsal.sh once per role, one box each.
#
#   drill/rehearsal-all.sh [--agent <name>] [--tree <path>] [--remote <url>]
#     [--ref <git-ref>] [--roles "triage builder reviewer"] [--quick]
#
# Three single-role boxes, not one multi-role box: fleet.roster deploys
# single-role members, and duty.sh gates every module on has_role. A box
# carrying all three would exercise a composite path nobody runs, and would
# hide exactly the class of defect that made a reviewer box quietly run
# triage sweeps for a whole rehearsal (heavy-duty/crew#28).
#
# The three boxes may share ONE gh identity. That is safe only because
# repos.txt is the scope for every module (heavy-duty/crew#7's doctrine
# change) and each box gets its own sandbox — disjoint registries, disjoint
# work. Under the previous org-wide review sweep all three would have seen
# each other's PRs and raced for the same verdicts.
#
# Each role runs to completion before the next starts. They are NOT
# parallelised: the boxes share an identity, and a shared identity means
# shared rate limits and interleaved duty.log evidence that nobody can read.
set -uo pipefail

ROLES="triage builder reviewer"
PASSTHRU=()
AGENT="claude"
# The fleet app is part of the rehearsal, not a separate errand: it is the
# thing an operator will be looking at when they decide whether the fleet is
# healthy, so a drill that proves the roles but never the console has only
# proved half of what gets trusted. Read-only by default — see
# drill/rehearsal-app.sh for why the control verbs are opt-in.
APP=1
APP_ARGS=()
# Roles whose drill actually reached a box, for the app phase.
DRILLED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --roles) ROLES="$2"; shift 2 ;;
    --agent) AGENT="$2"; PASSTHRU+=(--agent "$2"); shift 2 ;;
    --tree|--remote|--ref) PASSTHRU+=("$1" "$2"); shift 2 ;;
    --quick) PASSTHRU+=(--quick); shift ;;
    --no-app) APP=0; shift ;;
    --app-boxes) APP_ARGS+=(--boxes "$2"); shift 2 ;;
    --app-allow-control) APP_ARGS+=(--allow-control); shift ;;
    --app-roster) APP_ARGS+=(--roster "$2"); shift 2 ;;
    --app-shots) APP_ARGS+=(--shots "$2"); shift 2 ;;
    *) echo "usage: drill/rehearsal-all.sh [--agent <name>] [--roles \"triage builder reviewer\"] [--tree <path>] [--remote <url>] [--ref <git-ref>] [--quick]"
       echo "         [--no-app] [--app-boxes \"a b\"] [--app-allow-control] [--app-roster <path>] [--app-shots <dir>]"; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -a SUMMARY=()
overall=0

for role in $ROLES; do
  case "$role" in
    triage|builder|reviewer) ;;
    *) echo "unknown role '$role' (triage, builder or reviewer)"; exit 1 ;;
  esac
  echo
  echo "############################################################"
  echo "## $role — box crew-drill-$role"
  echo "############################################################"
  "$HERE/rehearsal.sh" --role "$role" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"
  rc=$?
  # Roles whose box the drill actually REACHED, for the app phase below. rc=0
  # and rc=2 both mean the box was minted and installed (2 is "phase 2 skipped",
  # not "no box"); rc=1 can be a failure from before the box existed at all.
  # Handing the app drill a box that is not there recreates, in miniature, the
  # "NOT CREATED vs offline" non-comparisons this wiring exists to remove — and
  # they would now count as real comparisons under #50's floor.
  case "$rc" in
    0|2) DRILLED="$DRILLED $role" ;;
  esac
  # 2 is "nothing failed, but phase 2 never ran". It is NOT a pass: the role
  # loop is unproven, and collapsing it into ok is how a rehearsal that
  # tested nothing gets reported as clearing the rollout.
  case "$rc" in
    0) SUMMARY+=("ok         $role  (phase 2 ran)") ;;
    2) SUMMARY+=("INCOMPLETE $role  (phase 2 skipped — loop UNPROVEN)"); overall=2 ;;
    *) SUMMARY+=("FAIL       $role"); overall=1 ;;
  esac
done

if [ "$APP" -eq 1 ]; then
  echo
  echo "############################################################"
  echo "## fleet app — crew floor against this host's boxes"
  echo "############################################################"
  # Point the app drill at the boxes THIS run just drilled, unless the operator
  # named a roster. Without this it fell through to fleet.roster, which on a
  # drill host names the real fleet's members — boxes that do not exist here —
  # so every comparison was "NOT CREATED vs offline": three assertions that
  # agree about nothing being there.
  #
  # --agent goes WITH the roles, and that pairing is the whole point. The agent
  # column selects the vendor profile both the floor and `crew status` probe
  # with, so generating the roles correctly while defaulting the agent to
  # `claude` mislabels every non-default rehearsal — and both readers then share
  # the one wrong file, so their agreement still passes. A generated fact is
  # only safer than a hand-written one if ALL of it is generated from something
  # true; the role came from the drill, the agent silently did not.
  case " ${APP_ARGS[*]-} " in
    *" --roster "*) : ;;
    *)
      if [ -n "${DRILLED// /}" ]; then
        APP_ARGS+=(--drill-roles "${DRILLED# }" --agent "$AGENT")
      else
        echo "## (app phase: no role reached a box this run — nothing to compare against)"
        APP=0
      fi ;;
  esac
  # Say what was left out rather than quietly narrowing: a shorter roster that
  # nobody announced reads as full coverage.
  if [ "$APP" -eq 1 ] && [ "${DRILLED# }" != "$ROLES" ]; then
    echo "## (app phase covers ${DRILLED# } — roles whose drill never reached a box are excluded)"
  fi
fi

if [ "$APP" -eq 1 ]; then
  "$HERE/rehearsal-app.sh" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
  # rc on its own line, like the role loop above — this file's own history is
  # why (crew#30: a bare status read inside a compound).
  rc=$?
  case "$rc" in
    0) SUMMARY+=("ok         app  (collector + page)") ;;
    *) SUMMARY+=("FAIL       app"); overall=1 ;;
  esac
fi

echo
echo "############################################################"
echo "## fleet rehearsal summary ($AGENT)"
printf '##   %s\n' "${SUMMARY[@]}"
echo "############################################################"
if [ "$overall" -eq 2 ]; then
  echo "## NOT a pass: at least one role never reached phase 2. Log those boxes"
  echo "## in and re-run before reporting anything on crew PR #16."
fi
exit "$overall"
