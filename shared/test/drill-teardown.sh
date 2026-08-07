#!/usr/bin/env bash
# Offline contract tests for drill/teardown.sh — the refusal set above all.
#
# The real teardown belongs on a box host, but the dangerous half of it is a
# pure predicate over names, and a teardown that can be talked into deleting a
# fleet member is worse than no teardown at all. So the predicate is driven
# here, with fixtures, on any machine: no box, no Incus, no credentials.
#
# Doubles for `box`, `gh` and `jq`, and for the same reason install-drill.sh's
# suite doubles them (#180's suite): this file also runs on box HOSTS, where a
# real `box` would make the answers depend on which drill boxes happen to be
# standing. Every double's branches are asserted below in both directions —
# present and absent, deleted and refused — so a wrong double fails the suite
# rather than quietly passing it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TEARDOWN="$ROOT/drill/teardown.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

STUB="$WORK/stub"; mkdir -p "$STUB"
CALLS="$WORK/calls"; : >"$CALLS"

cat >"$STUB/box" <<'SHIM'
#!/usr/bin/env bash
# `list --json` names whatever STUB_BOXES says; `info` answers with a creation
# date, so the survey's date column is exercised rather than assumed; `rm` is
# recorded and never does anything.
printf 'box %s\n' "$*" >>"$STUB_CALLS"
case "${1:-}" in
  list)
    # STUB_BOX_LIST_RC is an inventory that cannot be answered at all;
    # STUB_BOX_LIST_JUNK is one that answers with something that is not JSON.
    # Two different causes of the same "could not tell", and teardown has to
    # reach the same verdict from both.
    [ -z "${STUB_BOX_LIST_RC:-}" ] || exit "$STUB_BOX_LIST_RC"
    if [ -n "${STUB_BOX_LIST_JUNK:-}" ]; then printf 'box: cannot reach incus\n'; exit 0; fi
    printf '['
    sep=''
    for n in ${STUB_BOXES:-}; do printf '%s{"name":"%s"}' "$sep" "$n"; sep=','; done
    printf ']\n' ;;
  info)
    n="${2:-}"
    case " ${STUB_BOXES:-} " in *" $n "*) ;; *) exit 1 ;; esac
    printf '[{"name":"%s","created_at":"2026-07-25T09:00:00Z"}]\n' "$n" ;;
  rm) exit "${STUB_BOX_RM_RC:-0}" ;;
  *) exit 1 ;;
esac
SHIM

cat >"$STUB/gh" <<'SHIM'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$STUB_CALLS"
case "${1:-} ${2:-}" in
  "api user")
    [ -n "${STUB_LOGIN:-}" ] || exit 1
    printf '%s\n' "$STUB_LOGIN" ;;
  "repo view")
    slug="${3:-}"
    case " ${STUB_REPOS:-} " in *" $slug "*) ;; *) exit 1 ;; esac
    case " $* " in *" --json "*) printf '2026-07-31T12:00:00Z\n' ;; esac ;;
  "repo delete") exit "${STUB_REPO_DELETE_RC:-0}" ;;
  *) exit 1 ;;
esac
SHIM

cat >"$STUB/jq" <<'SHIM'
#!/usr/bin/env bash
# The three queries drill/teardown.sh makes, told apart by their program:
#   -e 'type == "array"'                            is the inventory readable
#   -e --arg n <name> '.[] | select(.name == $n)'   presence, by exit status
#   -r '…created_at // …'                           the creation date
#
# STUB_JQ_RC is jq itself failing — 127 is the no-jq-on-this-host case, which
# real jq cannot simulate and which must NOT read as an empty inventory.
[ -z "${STUB_JQ_RC:-}" ] || exit "$STUB_JQ_RC"
mode=presence name='' prog=''
while [ $# -gt 0 ]; do
  case "$1" in
    --arg) name="$3"; shift 3 ;;
    -e) shift ;;
    -r) mode=field; shift ;;
    *) prog="$1"; shift ;;
  esac
done
payload="$(cat)"
# Matched exactly, not by substring: the creation-date program contains the
# same `type == "array"` text and must not be answered as the probe.
if [ "$prog" = 'type == "array"' ]; then
  # Real jq exits 5 on unparseable input; only a JSON array answers `true`.
  case "$payload" in
    \[*) printf 'true\n'; exit 0 ;;
    *) exit 5 ;;
  esac
fi
if [ "$mode" = field ]; then
  case "$payload" in
    *'"created_at":"'*)
      rest="${payload#*\"created_at\":\"}"; printf '%s\n' "${rest%%\"*}" ;;
    *) printf 'unknown\n' ;;
  esac
  exit 0
fi
case "$payload" in *"\"name\":\"$name\""*) exit 0 ;; esac
exit 1
SHIM
chmod +x "$STUB/box" "$STUB/gh" "$STUB/jq"
PATH="$STUB:$PATH"; export PATH
export STUB_CALLS="$CALLS"

# A PATH with no `gh` on it at all — hermetic rather than subtractive, because
# this suite also runs on hosts where the real gh sits in /usr/bin and simply
# dropping $STUB would find it. Everything teardown.sh actually shells out to
# is symlinked in; gh is the one thing deliberately missing.
NOGH="$WORK/nogh"; mkdir -p "$NOGH"
for c in bash grep awk paste head tr; do
  ln -s "$(command -v "$c")" "$NOGH/$c" 2>/dev/null || true
done
ln -s "$STUB/box" "$NOGH/box"
ln -s "$STUB/jq"  "$NOGH/jq"

# A HOME and an XDG root of our own: roster resolution reads both, and a suite
# whose answers depend on the developer's own fleet definition is not a test.
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config"
mkdir -p "$XDG_CONFIG_HOME"
cd "$WORK" || exit 1

FLEET="$WORK/fleet.roster"
cat >"$FLEET" <<'EOF'
# <box> <agent> <role>
claude-triage   claude  triage
codex-reviewer  codex   reviewer
EOF
# The collision the second gate exists for: a REAL fleet member whose name is
# also a drill name. The name set says yes; the roster must still say no.
COLLIDE="$WORK/collide.roster"
cat >"$COLLIDE" <<'EOF'
crew-drill-builder  claude  builder
EOF

run() {  # run <env-assignments…> -- <args…>  → OUT, RC
  local envs=()
  while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done
  shift
  : >"$CALLS"
  OUT="$(env "${envs[@]}" "$TEARDOWN" "$@" 2>&1)"
  RC=$?
}
says()   { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
called() { grep -qF "$1" "$CALLS"; }

# --- the refusal set ------------------------------------------------------
# Each refusal is asserted BY NAME: a teardown that refuses without saying
# which name it refused sends the operator back to guess.

run "CREW_ROSTER=$COLLIDE" "STUB_BOXES=crew-drill-builder" -- --box crew-drill-builder --yes
if [ "$RC" -ne 0 ] && says "crew-drill-builder" && says "fleet member"; then
  ok "refuses-a-roster-member-whose-name-matches-the-drill-pattern"
else
  bad "refuses-a-roster-member-whose-name-matches-the-drill-pattern (rc=$RC, got '$OUT')"
fi
if called "box rm"; then
  bad "refused-roster-member-was-not-deleted"
else
  ok "refused-roster-member-was-not-deleted"
fi

run "CREW_ROSTER=$FLEET" "STUB_BOXES=claude-triage" -- --box claude-triage --yes
if [ "$RC" -ne 0 ] && says "claude-triage"; then
  ok "refuses-an-ordinary-roster-member"
else
  bad "refuses-an-ordinary-roster-member (rc=$RC, got '$OUT')"
fi

run "CREW_ROSTER=$FLEET" "STUB_BOXES=operator-scratch" -- --box operator-scratch --yes
if [ "$RC" -ne 0 ] && says "operator-scratch" && says "not a drill box"; then
  ok "refuses-an-arbitrary-box-name"
else
  bad "refuses-an-arbitrary-box-name (rc=$RC, got '$OUT')"
fi

# A prefix is not membership. `crew-drill-experiment` is the operator's own
# box, named after the same subject; the predicate is an EXACT set precisely
# so that box survives.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-experiment" -- --box crew-drill-experiment --yes
if [ "$RC" -ne 0 ] && says "crew-drill-experiment" && says "not a drill box"; then
  ok "refuses-a-name-that-merely-starts-with-crew-drill"
else
  bad "refuses-a-name-that-merely-starts-with-crew-drill (rc=$RC, got '$OUT')"
fi

run "CREW_ROSTER=$FLEET" "STUB_REPOS=someone/private-notes" -- --sandbox someone/private-notes --yes
if [ "$RC" -ne 0 ] && says "someone/private-notes"; then
  ok "refuses-a-repository-that-is-not-a-drill-sandbox"
else
  bad "refuses-a-repository-that-is-not-a-drill-sandbox (rc=$RC, got '$OUT')"
fi

run "CREW_ROSTER=$FLEET" -- --sandbox not-a-slug --yes
if [ "$RC" -ne 0 ] && says "not-a-slug"; then
  ok "refuses-a-sandbox-that-is-not-an-owner-repo-slug"
else
  bad "refuses-a-sandbox-that-is-not-an-owner-repo-slug (rc=$RC, got '$OUT')"
fi

# One bad name in a list of good ones deletes NOTHING. Validation runs over
# every target before the first deletion, so the operator retries a whole
# command rather than working out which half already ran.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-builder operator-scratch" \
  -- --box crew-drill-builder --box operator-scratch --yes
if [ "$RC" -ne 0 ] && says "operator-scratch" && ! called "box rm"; then
  ok "one-bad-name-in-the-list-deletes-nothing"
else
  bad "one-bad-name-in-the-list-deletes-nothing (rc=$RC, calls='$(cat "$CALLS")')"
fi

# An explicitly named roster that does not resolve is an error, not a silent
# skip: an operator who named a roster and got silence would believe a
# protection ran that never did.
run "CREW_ROSTER=$WORK/no-such-roster" "STUB_BOXES=crew-drill-builder" -- --box crew-drill-builder --yes
if [ "$RC" -ne 0 ] && says "CREW_ROSTER"; then
  ok "an-explicit-roster-that-does-not-resolve-is-an-error"
else
  bad "an-explicit-roster-that-does-not-resolve-is-an-error (rc=$RC, got '$OUT')"
fi

# Protection is a union, not a selection: a roster elsewhere on the host still
# names boxes that exist here (#51), so it protects even when another roster
# is the one in force.
mkdir -p "$XDG_CONFIG_HOME/crew"
cp "$COLLIDE" "$XDG_CONFIG_HOME/crew/fleet.roster"
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-builder" -- --box crew-drill-builder --yes
if [ "$RC" -ne 0 ] && says "fleet member"; then
  ok "a-roster-elsewhere-on-the-host-still-protects"
else
  bad "a-roster-elsewhere-on-the-host-still-protects (rc=$RC, got '$OUT')"
fi
rm -f "$XDG_CONFIG_HOME/crew/fleet.roster"

# --- idempotence ----------------------------------------------------------
run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPOS=" -- --yes
if [ "$RC" -eq 0 ] && says "nothing to do"; then
  ok "clean-host-exits-zero-with-nothing-to-do"
else
  bad "clean-host-exits-zero-with-nothing-to-do (rc=$RC, got '$OUT')"
fi
if called "box rm" || called "repo delete"; then
  bad "clean-host-deletes-nothing"
else
  ok "clean-host-deletes-nothing"
fi

# --- the green path -------------------------------------------------------
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-triage crew-drill-builder crew-drill-reviewer" \
    "STUB_LOGIN=danmt" "STUB_REPOS=danmt/crew-drill-triage danmt/crew-drill-builder danmt/crew-drill-reviewer" \
  -- --yes
if [ "$RC" -eq 0 ]; then ok "whole-round-teardown-exits-zero"
else bad "whole-round-teardown-exits-zero (rc=$RC, got '$OUT')"; fi
for role in triage builder reviewer; do
  if called "box rm --force crew-drill-$role"; then ok "removes-box-crew-drill-$role"
  else bad "removes-box-crew-drill-$role (calls='$(cat "$CALLS")')"; fi
  if called "repo delete danmt/crew-drill-$role"; then ok "deletes-sandbox-crew-drill-$role"
  else bad "deletes-sandbox-crew-drill-$role (calls='$(cat "$CALLS")')"; fi
done
# Named before deleted, with the date that tells one round from another.
if says "2026-07-25T09:00:00Z" && says "2026-07-31T12:00:00Z"; then
  ok "names-boxes-and-repos-with-their-creation-dates"
else
  bad "names-boxes-and-repos-with-their-creation-dates (got '$OUT')"
fi

# One round, not every round: --role targets a single leg.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-triage crew-drill-builder" \
    "STUB_LOGIN=danmt" "STUB_REPOS=danmt/crew-drill-triage danmt/crew-drill-builder" \
  -- --role builder --yes
if called "box rm --force crew-drill-builder" && ! called "box rm --force crew-drill-triage"; then
  ok "role-targets-one-leg-only"
else
  bad "role-targets-one-leg-only (calls='$(cat "$CALLS")')"
fi

# --- confirmation ---------------------------------------------------------
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-builder" "STUB_LOGIN=danmt" "STUB_REPOS=" \
  -- --box crew-drill-builder --dry-run
if [ "$RC" -eq 0 ] && says "crew-drill-builder" && ! called "box rm"; then
  ok "dry-run-names-the-targets-and-deletes-nothing"
else
  bad "dry-run-names-the-targets-and-deletes-nothing (rc=$RC, calls='$(cat "$CALLS")')"
fi

# No --yes, no CREW_YES, no terminal (this suite has none): the run refuses
# rather than deleting unasked.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-builder" "STUB_LOGIN=danmt" "STUB_REPOS=" \
  -- --box crew-drill-builder </dev/null
if [ "$RC" -ne 0 ] && ! called "box rm"; then
  ok "without-a-confirmation-nothing-is-deleted"
else
  bad "without-a-confirmation-nothing-is-deleted (rc=$RC, calls='$(cat "$CALLS")')"
fi

run "CREW_ROSTER=$FLEET" "CREW_YES=1" "STUB_BOXES=crew-drill-builder" "STUB_LOGIN=danmt" "STUB_REPOS=" \
  -- --box crew-drill-builder </dev/null
if [ "$RC" -eq 0 ] && called "box rm --force crew-drill-builder"; then
  ok "CREW_YES-is-the-non-interactive-yes"
else
  bad "CREW_YES-is-the-non-interactive-yes (rc=$RC, got '$OUT')"
fi

# --- failure is reported, not swallowed -----------------------------------
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-builder" "STUB_BOX_RM_RC=1" "STUB_LOGIN=danmt" "STUB_REPOS=" \
  -- --box crew-drill-builder --yes
if [ "$RC" -ne 0 ] && says "could not remove box crew-drill-builder"; then
  ok "a-failed-removal-exits-non-zero-and-says-which"
else
  bad "a-failed-removal-exits-non-zero-and-says-which (rc=$RC, got '$OUT')"
fi

# --- "could not tell" is never "absent" -----------------------------------
# The whole point of the script is to end leftovers nobody knows about, so the
# one answer it must never give is a clean host it did not measure. Every
# class it was ASKED to clear is either inspected or declared, and a run that
# could not look exits 2 (INCOMPLETE) — never 0, whatever else it managed.

# A host with no gh identity cannot address the sandbox half. Say what was
# left out, and do not call the round done: a shorter run nobody announced
# reads as a clean host.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=" "STUB_REPOS=" -- --yes
if [ "$RC" -eq 2 ] && says "NOT inspected"; then
  ok "says-so-when-the-sandbox-half-could-not-be-inspected"
else
  bad "says-so-when-the-sandbox-half-could-not-be-inspected (rc=$RC, got '$OUT')"
fi
if says "nothing to do — no drill box"; then
  bad "an-uninspected-sandbox-half-is-not-reported-as-a-clean-host"
else
  ok "an-uninspected-sandbox-half-is-not-reported-as-a-clean-host"
fi

# codex-bot's reproduction, as an assertion: gh cannot be asked who we are,
# but a drill box IS standing. It gets removed — that half of the host really
# is clean and there is no reason to leave it dirty — and the run still
# refuses to return success, because the sandboxes were never looked at.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-reviewer" "STUB_LOGIN=" "STUB_REPOS=" -- --yes
if [ "$RC" -eq 2 ] && called "box rm --force crew-drill-reviewer" && says "NOT inspected"; then
  ok "an-uninspected-half-cannot-return-success-even-when-the-other-half-was-deleted"
else
  bad "an-uninspected-half-cannot-return-success-even-when-the-other-half-was-deleted (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
fi

# No gh on this host at all — the other way to be unable to read the sandbox
# half, and it must land in the same place as a gh that cannot answer.
run "CREW_ROSTER=$FLEET" "PATH=$NOGH" "STUB_BOXES=" -- --yes
if [ "$RC" -eq 2 ] && says "no gh CLI"; then
  ok "no-gh-cli-leaves-the-sandbox-half-uninspected-and-non-zero"
else
  bad "no-gh-cli-leaves-the-sandbox-half-uninspected-and-non-zero (rc=$RC, got '$OUT')"
fi

# The box half, from three different causes. The old shape asked
# `box list --json | jq` per name and read every non-zero as "does not
# exist", so all three printed a clean host and exited 0.
run "CREW_ROSTER=$FLEET" "STUB_BOX_LIST_RC=1" "STUB_LOGIN=danmt" "STUB_REPOS=" -- --yes
if [ "$RC" -eq 2 ] && says "NOT inspected" && says "could not be read"; then
  ok "an-unanswerable-box-inventory-is-not-a-clean-host"
else
  bad "an-unanswerable-box-inventory-is-not-a-clean-host (rc=$RC, got '$OUT')"
fi
if called "box rm"; then
  bad "an-unanswerable-box-inventory-deletes-no-box"
else
  ok "an-unanswerable-box-inventory-deletes-no-box"
fi

run "CREW_ROSTER=$FLEET" "STUB_BOX_LIST_JUNK=1" "STUB_LOGIN=danmt" "STUB_REPOS=" -- --yes
if [ "$RC" -eq 2 ] && says "could not be read"; then
  ok "an-inventory-that-is-not-json-is-not-a-clean-host"
else
  bad "an-inventory-that-is-not-json-is-not-a-clean-host (rc=$RC, got '$OUT')"
fi

run "CREW_ROSTER=$FLEET" "STUB_JQ_RC=127" "STUB_BOXES=crew-drill-builder" "STUB_LOGIN=danmt" "STUB_REPOS=" -- --yes
if [ "$RC" -eq 2 ] && says "NOT inspected" && ! called "box rm"; then
  ok "no-jq-to-read-the-inventory-with-is-not-a-clean-host"
else
  bad "no-jq-to-read-the-inventory-with-is-not-a-clean-host (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
fi

# 2 is INCOMPLETE and 1 is refused-or-failed: two different facts, and
# rehearsal-all.sh reports them as two different summary rows.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=operator-scratch" "STUB_LOGIN=danmt" -- --box operator-scratch --yes
if [ "$RC" -eq 1 ]; then
  ok "a-refusal-is-status-1-not-the-INCOMPLETE-2"
else
  bad "a-refusal-is-status-1-not-the-INCOMPLETE-2 (rc=$RC, got '$OUT')"
fi

# --- an argument left off is an operator error, not a bash trace ----------
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-builder" "STUB_LOGIN=danmt" -- --role
if [ "$RC" -ne 0 ] && says "usage" && says "needs an argument" && ! called "box rm"; then
  ok "a-flag-missing-its-argument-prints-usage-and-deletes-nothing"
else
  bad "a-flag-missing-its-argument-prints-usage-and-deletes-nothing (rc=$RC, got '$OUT')"
fi

echo
echo "drill-teardown: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
