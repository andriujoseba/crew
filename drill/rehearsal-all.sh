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

while [ $# -gt 0 ]; do
  case "$1" in
    --roles) ROLES="$2"; shift 2 ;;
    --agent) AGENT="$2"; PASSTHRU+=(--agent "$2"); shift 2 ;;
    --tree|--remote|--ref) PASSTHRU+=("$1" "$2"); shift 2 ;;
    --quick) PASSTHRU+=(--quick); shift ;;
    *) echo "usage: drill/rehearsal-all.sh [--agent <name>] [--roles \"triage builder reviewer\"] [--tree <path>] [--remote <url>] [--ref <git-ref>] [--quick]"; exit 1 ;;
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
  if "$HERE/rehearsal.sh" --role "$role" "${PASSTHRU[@]+"${PASSTHRU[@]}"}"; then
    SUMMARY+=("ok   $role")
  else
    SUMMARY+=("FAIL $role")
    overall=1
  fi
done

echo
echo "############################################################"
echo "## fleet rehearsal summary ($AGENT)"
printf '##   %s\n' "${SUMMARY[@]}"
echo "############################################################"
# A role that never reached phase 2 reports ok for phase 0/1 alone — read
# the per-role summaries above, not just this line.
exit "$overall"
