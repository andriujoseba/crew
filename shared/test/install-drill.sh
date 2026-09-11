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

# A test double for the box CLI. `list --json` names whatever STUB_BOXES says,
# and `exec` runs the requested body against STUB_BOX_HOME — so the driver's
# real identity reader runs against a real fixture file rather than a canned
# answer. It also pins the no-host case: this suite runs on box HOSTS too,
# where a real `box` would otherwise make the dry-run's output depend on which
# drill boxes happen to exist.
STUB="$WORK/stub"; mkdir -p "$STUB"
cat >"$STUB/box" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    [ "${2:-}" = --json ] || exit 1
    printf '['
    sep=''
    for n in ${STUB_BOXES:-}; do printf '%s{"name":"%s"}' "$sep" "$n"; sep=','; done
    printf ']\n' ;;
  exec)
    name="${2:-}"; shift 2
    case " ${STUB_BOXES:-} " in *" $name "*) ;; *) exit 1 ;; esac
    [ "${1:-}" = -- ] && shift
    [ "${1:-}" = bash ] && shift
    [ "${1:-}" = -lc ] && shift
    HOME="${STUB_BOX_HOME:-/nonexistent}" bash -c "${1:-}" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$STUB/box"
cat >"$STUB/crontab" <<'SHIM'
#!/usr/bin/env bash
state="${STUB_BOX_HOME:?}/crontab"
case "${1:-}" in
  -l)
    if [ "${STUB_CRONTAB_READ_RC:-0}" -ne 0 ]; then
      printf '%s\n' "${STUB_CRONTAB_READ_ERROR:-read failed}" >&2
      exit "$STUB_CRONTAB_READ_RC"
    fi
    [ -f "$state" ] || { printf 'no crontab for fixture\n' >&2; exit 1; }
    cat "$state" ;;
  '') cat >"$state" ;;
  *) cp "$1" "$state" ;;
esac
SHIM
chmod +x "$STUB/crontab"
# …and a double for the one jq query the driver's box-presence gate makes, so
# stubbing `box` is enough to make this suite host-independent. Without it the
# gate reports "no host" on any machine without jq, and the identity cases
# below silently stop testing what they say they test. Both branches of the
# gate are asserted below, so a wrong double fails the suite rather than
# passing it.
cat >"$STUB/jq" <<'SHIM'
#!/usr/bin/env bash
# jq -e --arg n <name> '.[] | select(.name == $n)' — present is exit 0.
name=''
while [ $# -gt 0 ]; do
  case "$1" in
    --arg) name="$3"; shift 3 ;;
    -e) shift ;;
    *) shift ;;
  esac
done
grep -qF "\"name\":\"$name\"" && exit 0
exit 1
SHIM
chmod +x "$STUB/jq"
PATH="$STUB:$PATH"; export PATH
export STUB_BOXES="" STUB_BOX_HOME="$WORK/boxhome"
mkdir -p "$STUB_BOX_HOME/duty/conf"
# Written the way shared/install.sh writes it — unquoted agent, quoted roles.
{ echo 'BOT_AGENT=kimi'; echo 'BOT_ROLES="triage"'; } >"$STUB_BOX_HOME/duty/conf/instance.conf"

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

# The box's own identity is the only source Section A may hire from. A fixture
# roster naming a role of its own re-roles a box that later phases share, and
# the config drill then meets ROLES CHANGED on the box it was handed (#180).
case "$out" in
  *"WOULD ADOPT"*"instance.conf"*) ok "dry-run-with-no-host-says-it-adopts-the-installed-identity" ;;
  *) bad "dry-run-with-no-host-says-it-adopts-the-installed-identity (got '$out')" ;;
esac

if adopt="$(STUB_BOXES="crew-drill-triage" "$DRIVER" --box crew-drill-triage --tree "$ROOT" \
    --registry "$NARROW" --dry-run 2>&1)"; then
  ok "identity-read-exits-zero"
else
  bad "identity-read-exits-zero (got '$adopt')"
fi
EXPECT_IDENTITY="agent \`kimi\`, roles \`triage\`"
case "$adopt" in
  *"$EXPECT_IDENTITY"*) ok "reads-agent-and-roles-off-the-box" ;;
  *) bad "reads-agent-and-roles-off-the-box (got '$adopt')" ;;
esac
# Scoped to the identity line: the tree path alone can carry the word `claude`.
IDENTITY_LINE="$(printf '%s\n' "$adopt" | grep -F 'WOULD HIRE' || true)"
case "$IDENTITY_LINE" in
  *claude*|*reviewer*) bad "does-not-fall-back-to-a-hard-coded-identity (got '$IDENTITY_LINE')" ;;
  *) ok "does-not-fall-back-to-a-hard-coded-identity" ;;
esac

# A box that was never hired carries no identity, so there is none to
# overwrite: #180's task list makes that the one case where Section A chooses,
# and it chooses `claude reviewer`.
if unhired="$(STUB_BOXES="crew-drill-triage" STUB_BOX_HOME="$WORK/unhired-boxhome" \
    "$DRIVER" --box crew-drill-triage --tree "$ROOT" --registry "$NARROW" --dry-run 2>&1)"; then
  UNHIRED_LINE="$(printf '%s\n' "$unhired" | grep -F 'WOULD HIRE' || true)"
  # shellcheck disable=SC2016  # the backticks are the driver's literal output
  case "$UNHIRED_LINE" in
    *'agent `claude`, roles `reviewer`'*) ok "unhired-box-falls-back-to-claude-reviewer" ;;
    *) bad "unhired-box-falls-back-to-claude-reviewer (got '$UNHIRED_LINE')" ;;
  esac
  case "$UNHIRED_LINE" in
    *"instance.conf"*) ok "unhired-fallback-says-why-it-chose" ;;
    *) bad "unhired-fallback-says-why-it-chose (got '$UNHIRED_LINE')" ;;
  esac
else
  bad "unhired-box-dry-run-still-reports (got '$unhired')"
fi

# But an instance.conf that is THERE and unreadable is not an unhired box: the
# box may well be carrying an identity, and guessing over one is #180 firing
# for real. Only the absent file licenses a choice.
UNREADABLE_HOME="$WORK/unreadable-boxhome"
mkdir -p "$UNREADABLE_HOME/duty/conf"
printf 'BOT_AGENT=\nBOT_ROLES=""\n' >"$UNREADABLE_HOME/duty/conf/instance.conf"
if unreadable="$(STUB_BOXES="crew-drill-triage" STUB_BOX_HOME="$UNREADABLE_HOME" \
    "$DRIVER" --box crew-drill-triage --tree "$ROOT" --registry "$NARROW" --dry-run 2>&1)"; then
  case "$unreadable" in
    *"WOULD REFUSE"*"instance.conf"*) ok "unreadable-identity-refuses-rather-than-inventing-one" ;;
    *) bad "unreadable-identity-refuses-rather-than-inventing-one (got '$unreadable')" ;;
  esac
  # Asserted as the absence of a hire, not as a refusal line that says the
  # right words: a mutation that routes `unreadable` into the fallback branch
  # prints WOULD HIRE, and that is the failure worth catching.
  if hire_line="$(printf '%s\n' "$unreadable" | grep -F 'WOULD HIRE')"; then
    bad "unreadable-identity-does-not-fall-back (got '$hire_line')"
  else
    ok "unreadable-identity-does-not-fall-back"
  fi
else
  bad "unreadable-identity-dry-run-still-reports (got '$unreadable')"
fi

# The roster field is comma-separated; a two-role box must not be written as
# two roster columns, which resolves to the second role alone.
# shellcheck disable=SC2016  # the driver's literal expansion is the pattern
if grep -qF '${BOX_ROLES// /,}' "$DRIVER"; then
  ok "multi-role-identity-is-comma-joined-for-the-roster"
else
  bad "multi-role-identity-is-comma-joined-for-the-roster"
fi
if grep -qE "printf '%s [a-z]+ [a-z]+" "$DRIVER"; then
  bad "no-hard-coded-identity-left-in-the-fixture-roster"
else
  ok "no-hard-coded-identity-left-in-the-fixture-roster"
fi

if prod="$("$DRIVER" --box crew-drill-reviewer --tree "$ROOT" \
    --registry "$ROOT/examples/repos.txt" --dry-run 2>&1)"; then
  bad "production-registry-refuses"
elif [[ "$prod" == *"byte-equivalent to the shipped examples/repos.txt scaffold"* &&
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

# Exercise the production snapshot/restore functions against a borrowed-box
# fixture. Section A replaces repos.txt and leaves the engine armed before the
# post-step-9 cleanup; return must preserve unrelated cron and registry bytes.
# shellcheck source=drill/install-borrowed-box.sh
. "$ROOT/drill/install-borrowed-box.sh"
BORROWED_HOME="$WORK/borrowed-boxhome"
mkdir -p "$BORROWED_HOME/duty"
printf 'owner/original  # preserve these bytes\n' >"$BORROWED_HOME/duty/repos.txt"
cp "$BORROWED_HOME/duty/repos.txt" "$WORK/repos.before"
printf '17 * * * * /usr/local/bin/unrelated\n*/5 * * * * %s/duty/bin/tick.sh\n' \
  "$BORROWED_HOME" >"$BORROWED_HOME/crontab"
STUB_BOX_HOME="$BORROWED_HOME"
bx() {
  [ "${BORROWED_BX_FAIL:-0}" -eq 0 ] || return 1
  HOME="$STUB_BOX_HOME" bash -c "$1"
}
if install_borrowed_box_snapshot; then
  printf 'drill/installer-rehearsal\n' >"$BORROWED_HOME/duty/repos.txt"
  if install_borrowed_box_restore && install_borrowed_box_verify; then
    ok "borrowed-box-return-restores-state"
  else
    bad "borrowed-box-return-restores-state ($INSTALL_BORROWED_DETAIL)"
  fi
else
  bad "borrowed-box-return-snapshots-state ($INSTALL_BORROWED_DETAIL)"
fi
if cmp -s "$WORK/repos.before" "$BORROWED_HOME/duty/repos.txt"; then
  ok "borrowed-box-return-restores-registry-byte-identically"
else
  bad "borrowed-box-return-restores-registry-byte-identically"
fi
if grep -qF '/usr/local/bin/unrelated' "$BORROWED_HOME/crontab" &&
   ! grep -qF '/duty/bin/tick.sh' "$BORROWED_HOME/crontab"; then
  ok "borrowed-box-return-disarms-only-duty-tick"
else
  bad "borrowed-box-return-disarms-only-duty-tick"
fi
install_borrowed_box_discard_snapshot || bad "borrowed-box-snapshot-discard"

# A failed box transport is not evidence that repos.txt was absent. In
# particular, restore must remain a no-op rather than deleting real state.
INSTALL_BORROWED_SNAPSHOT_TAKEN=0
INSTALL_BORROWED_REPOS_STATE=""
BORROWED_BX_FAIL=1
if install_borrowed_box_snapshot; then
  bad "borrowed-box-failed-read-refuses-snapshot"
elif [ "$INSTALL_BORROWED_SNAPSHOT_TAKEN" -eq 0 ] &&
     [ -z "$INSTALL_BORROWED_REPOS_STATE" ]; then
  ok "borrowed-box-failed-read-is-not-classified-absent"
else
  bad "borrowed-box-failed-read-is-not-classified-absent"
fi
install_borrowed_box_restore
if cmp -s "$WORK/repos.before" "$BORROWED_HOME/duty/repos.txt"; then
  ok "borrowed-box-failed-read-does-not-remove-registry"
else
  bad "borrowed-box-failed-read-does-not-remove-registry"
fi
BORROWED_BX_FAIL=0

# An unreadable crontab must neither be replaced with an empty table nor pass
# verification. The status-1 no-table case remains a clean absent state.
printf '17 * * * * /usr/local/bin/unrelated\n*/5 * * * * %s/duty/bin/tick.sh\n' \
  "$BORROWED_HOME" >"$BORROWED_HOME/crontab"
cp "$BORROWED_HOME/crontab" "$WORK/crontab.before"
export STUB_CRONTAB_READ_RC=2
if install_borrowed_box_disarm; then
  bad "borrowed-box-unreadable-crontab-refuses-disarm"
else
  ok "borrowed-box-unreadable-crontab-refuses-disarm"
fi
if cmp -s "$WORK/crontab.before" "$BORROWED_HOME/crontab"; then
  ok "borrowed-box-unreadable-crontab-preserves-content"
else
  bad "borrowed-box-unreadable-crontab-preserves-content"
fi
if install_borrowed_box_verify; then
  bad "borrowed-box-unreadable-crontab-reds-verification"
else
  ok "borrowed-box-unreadable-crontab-reds-verification"
fi
export STUB_CRONTAB_READ_RC=0
rm -f -- "$BORROWED_HOME/crontab"
if install_borrowed_box_disarm && install_borrowed_box_verify &&
   [ ! -e "$BORROWED_HOME/crontab" ]; then
  ok "borrowed-box-absent-crontab-stays-absent"
else
  bad "borrowed-box-absent-crontab-stays-absent ($INSTALL_BORROWED_DETAIL)"
fi

if grep -qF "\"\$HERE/install-drill.sh\"" "$ROOT/drill/rehearsal-all.sh"; then
  ok "rehearsal-all-wires-section-a"
else
  bad "rehearsal-all-wires-section-a"
fi
if grep -qF 'install_borrowed_box_restore' "$DRIVER"; then
  ok "install-drill-wires-borrowed-box-restore"
else
  bad "install-drill-wires-borrowed-box-restore"
fi

echo
echo "install-drill: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
