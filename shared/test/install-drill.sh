#!/usr/bin/env bash
# Offline contract tests for drill/install-drill.sh. The real path belongs on
# a box host; --dry-run proves its hardware observations and safety interlock
# without requiring box, Incus, credentials, or root.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DRIVER="$ROOT/drill/install-drill.sh"
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
NARROW="$WORK/repos.txt"
printf 'drill/installer-rehearsal\n' >"$NARROW"

if out="$("$DRIVER" --box crew-drill-reviewer --tree "$ROOT" --registry "$NARROW" --dry-run 2>&1)"; then
  ok "dry-run-exits-zero"
else
  bad "dry-run-exits-zero (got '$out')"
fi
for evidence in "step 4:" "steps 5–6:" "step 8:" "step 9:" "host checkout:"; do
  case "$out" in
    *"$evidence"*) ok "dry-run-reports-${evidence%:}" ;;
    *) bad "dry-run-reports-${evidence%:}" ;;
  esac
done

if prod="$("$DRIVER" --box crew-drill-reviewer --tree "$ROOT" \
    --registry "$ROOT/examples/repos.txt" --dry-run 2>&1)"; then
  bad "production-registry-refuses"
elif [[ "$prod" == *"refusing production registry"* &&
        "$prod" == *"narrowed, non-production repos.txt"* ]]; then
  ok "production-registry-refuses-and-explains"
else
  bad "production-registry-refuses-and-explains (got '$prod')"
fi

if "$DRIVER" --box production-reviewer --tree "$ROOT" --registry "$NARROW" \
    --dry-run >"$WORK/name.out" 2>&1; then
  bad "non-drill-box-refuses"
elif grep -qF "installer rehearsal targets crew-drill-* only" "$WORK/name.out"; then
  ok "non-drill-box-refuses"
else
  bad "non-drill-box-refuses (got '$(cat "$WORK/name.out")')"
fi

if [ "$(grep -cF "\"\$TREE/shared/test/install-lifecycle.sh\"" "$DRIVER")" -eq 1 ]; then
  ok "invokes-install-lifecycle-once"
else
  bad "invokes-install-lifecycle-once"
fi
if [ "$(grep -cF "\"\$TREE/shared/test/artifact.sh\"" "$DRIVER")" -eq 1 ]; then
  ok "invokes-artifact-once"
else
  bad "invokes-artifact-once"
fi
for duplicate in interrupted-reinstall-keeps-current-resolvable one-byte-corruption-caught \
                 artifact-and-source-trees-identical uninstall-dangling-current-refuses; do
  if grep -qF "$duplicate" "$DRIVER"; then
    bad "does-not-duplicate-$duplicate"
  else
    ok "does-not-duplicate-$duplicate"
  fi
done

if grep -qF 'step 9:' "$DRIVER" &&
   grep -qF 'kept engine' "$DRIVER" &&
   grep -qF 'armed cron' "$DRIVER" &&
   grep -qF 'latest tick' "$DRIVER"; then
  ok "step-9-positively-observes-engine-cron-and-tick"
else
  bad "step-9-positively-observes-engine-cron-and-tick"
fi

if grep -qF "\"\$HERE/install-drill.sh\"" "$ROOT/drill/rehearsal-all.sh"; then
  ok "rehearsal-all-wires-section-a"
else
  bad "rehearsal-all-wires-section-a"
fi

echo
echo "install-drill: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
