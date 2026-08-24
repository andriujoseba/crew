#!/usr/bin/env bash
# Aggregate entrypoint for the standalone duty-engine subject suites.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUITES=(common triage builder hygiene conf)
PASS=0
FAIL=0
suite_failed=0

for suite in "${SUITES[@]}"; do
  if output="$("$HERE/$suite.sh")"; then
    rc=0
  else
    rc=$?
    suite_failed=1
  fi
  printf '%s\n' "$output"
  summary="$(printf '%s\n' "$output" | tail -1)"
  if [[ "$summary" =~ ^passed\ ([0-9]+),\ failed\ ([0-9]+)$ ]]; then
    PASS=$((PASS + BASH_REMATCH[1]))
    FAIL=$((FAIL + BASH_REMATCH[2]))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s-suite-summary\n  expected: passed N, failed N\n  actual:   %s (rc=%s)\n' \
      "$suite" "$summary" "$rc"
  fi
done

echo
echo "passed $PASS, failed $FAIL"
[ "$suite_failed" -eq 0 ] && [ "$FAIL" -eq 0 ]
