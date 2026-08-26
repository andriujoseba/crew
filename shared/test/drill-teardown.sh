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
  "api repos/"*)
    slug="${2#repos/}"
    # STUB_REPO_LOOKUP_RC is the lookup failing for a reason that is NOT a
    # 404 — codex's transport failure underneath a perfectly good identity.
    # The message shape is gh's: a 404 says so in as many words and anything
    # else does not, which is the whole of what repo_probe reads.
    if [ -n "${STUB_REPO_LOOKUP_RC:-}" ]; then
      printf 'error connecting to api.github.com: dial tcp: lookup failed\n' >&2
      exit "$STUB_REPO_LOOKUP_RC"
    fi
    case " ${STUB_REPOS:-} " in
      *" $slug "*) ;;
      *) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
    esac
    case " $* " in
      *created_at*) printf '2026-07-31T12:00:00Z\n' ;;
      *) printf '%s\n' "$slug" ;;
    esac ;;
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

# Force the race that exposed #411 instead of hoping scheduler load happens to
# reproduce it. The old `producer | grep -q` predicate returns 141 here: grep
# exits after the matching line, then the producer wakes and writes again.
predicate_function() { sed -n "/^$1()/p" "$TEARDOWN"; }
eval "$(predicate_function is_drill_box)"
eval "$(predicate_function is_drill_repo)"
# shellcheck disable=SC2317  # called by the predicates loaded through eval
drill_box_names() {
  printf '%s\n' crew-drill crew-drill-triage
  sleep 0.05
  printf '%s\n' crew-drill-builder
}
# shellcheck disable=SC2317  # called by the predicates loaded through eval
drill_repo_names() {
  printf '%s\n' crew-drill crew-drill-triage
  sleep 0.05
  printf '%s\n' crew-drill-builder crew-drill-sandbox
}
if is_drill_box crew-drill-triage && ! is_drill_box someone-elses-box; then
  ok "drill-box-membership-survives-a-descheduled-producer"
else
  bad "drill-box-membership-survives-a-descheduled-producer"
fi
if is_drill_repo crew-drill-triage && ! is_drill_repo someone-elses-box; then
  ok "drill-repo-membership-survives-a-descheduled-producer"
else
  bad "drill-repo-membership-survives-a-descheduled-producer"
fi
unset -f is_drill_box is_drill_repo drill_box_names drill_repo_names predicate_function

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

# --- and never "absent" one grain further down either ---------------------
# The gates above are per CLASS: no gh, no login, an unanswerable identity.
# They all pass the moment `gh api user` answers, and the per-REPOSITORY
# lookup was still reading every non-zero as absence — so a live identity plus
# a dead network printed a clean host with the sandboxes standing. That is
# codex-bot's second-round reproduction, and it is the same defect as the
# first round's, one level down.

run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPO_LOOKUP_RC=1" \
    -- --sandbox danmt/crew-drill-reviewer --yes
if [ "$RC" -eq 2 ] && says "NOT inspected" && says "danmt/crew-drill-reviewer"; then
  ok "a-repository-lookup-that-failed-is-not-a-measured-absence"
else
  bad "a-repository-lookup-that-failed-is-not-a-measured-absence (rc=$RC, got '$OUT')"
fi
if says "nothing to do — no drill box"; then
  bad "a-failed-repository-lookup-is-not-reported-as-a-clean-host"
else
  ok "a-failed-repository-lookup-is-not-reported-as-a-clean-host"
fi
if called "repo delete"; then
  bad "a-repository-nobody-could-read-is-not-deleted"
else
  ok "a-repository-nobody-could-read-is-not-deleted"
fi

# The converse, and the reason it is asserted: a "fix" that made EVERY
# repository uninspectable would satisfy the three above and quietly destroy
# idempotence, so the measured absence has to be proved to still be one. A 404
# is the only non-zero that means "not there".
run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPOS=" -- --yes
if [ "$RC" -eq 0 ] && says "nothing to do" && ! says "NOT inspected"; then
  ok "a-404-really-is-a-measured-absence-and-still-a-clean-host"
else
  bad "a-404-really-is-a-measured-absence-and-still-a-clean-host (rc=$RC, got '$OUT')"
fi

# INCOMPLETE still deletes what it COULD see, on the repository path as much
# as on the identity one: the box half was read, so leave it clean.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-builder" "STUB_LOGIN=danmt" "STUB_REPO_LOOKUP_RC=1" \
    -- --role builder --yes
if [ "$RC" -eq 2 ] && called "box rm --force crew-drill-builder" && says "NOT inspected"; then
  ok "a-failed-repository-lookup-still-removes-the-box-it-could-read"
else
  bad "a-failed-repository-lookup-still-removes-the-box-it-could-read (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
fi

# --- naming one target twice deletes it once ------------------------------
# `box rm --force` against a box the first call already removed will usually
# fail, and that would turn a SUCCESSFUL teardown into `FAIL could not remove
# box` for a box that WAS removed — the one message an operator has to trust.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=crew-drill-builder" "STUB_LOGIN=danmt" "STUB_REPOS=" \
    -- --box crew-drill-builder --role builder --yes
if [ "$RC" -eq 0 ] && [ "$(grep -cF 'box rm --force crew-drill-builder' "$CALLS")" -eq 1 ]; then
  ok "a-target-named-twice-is-deleted-once"
else
  bad "a-target-named-twice-is-deleted-once (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
fi
if [ "$(printf '%s\n' "$OUT" | grep -cF 'box   crew-drill-builder')" -eq 1 ]; then
  ok "a-target-named-twice-is-listed-once-in-the-confirmation"
else
  bad "a-target-named-twice-is-listed-once-in-the-confirmation (got '$OUT')"
fi

# --- the repo predicate has two gates too ---------------------------------
# The box half checks the exact name AND the roster; the repo half checked the
# <repo> component alone, so a drill-shaped name under somebody else's account
# validated. A round's sandboxes are always $REPO_OWNER/crew-drill-<role>.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPOS=other/crew-drill-builder" \
    -- --sandbox other/crew-drill-builder --yes
if [ "$RC" -eq 1 ] && says "other/crew-drill-builder" && says "danmt" && ! called "repo delete"; then
  ok "refuses-a-drill-shaped-sandbox-owned-by-someone-else"
else
  bad "refuses-a-drill-shaped-sandbox-owned-by-someone-else (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
fi

# The same gate must not refuse the round's own sandbox, or teardown clears
# nothing at all.
run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPOS=danmt/crew-drill-builder" \
    -- --sandbox danmt/crew-drill-builder --yes
if [ "$RC" -eq 0 ] && called "repo delete danmt/crew-drill-builder"; then
  ok "accepts-the-round-s-own-sandbox-under-this-identity"
else
  bad "accepts-the-round-s-own-sandbox-under-this-identity (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
fi

# --- the round's OTHER sandbox: the notify one ----------------------------
# The notifier union leg mints a SECOND sandbox per role — watch-only, so the
# watch set can be widened without widening the work set (#423). Everything
# above drives teardown.sh over the WORK sandboxes alone, so the delete set,
# the ownership refusal and prefix-is-not-membership were all enforced for
# one of the round's two sandboxes and unenforced for the other. The gap was
# the POPULATION and not the rules, so the rules are re-run here over the
# sandbox that was outside it (#496 D1).
#
# The names are READ OUT OF teardown.sh rather than restated: its refusal
# message prints its own whole enumeration, for the box half and the repo
# half alike. A case spelling `crew-drill-<role>-notify` here would keep
# passing the day the round renames its sandboxes, green against a name
# nothing mints — so what is asserted below is membership and ownership, and
# every fixture derives (#496 D2).
name_set() {  # the enumeration teardown.sh prints when it refuses a name
  printf '%s\n' "$OUT" | sed -n 's/.*teardown removes only: //p' | head -1
}
run "CREW_ROSTER=$FLEET" -- --box zzz-outside-every-drill-name --yes
BOX_NAMES=" $(name_set) "
run "CREW_ROSTER=$FLEET" "STUB_LOGIN=danmt" -- --sandbox danmt/zzz-outside-every-drill-name --yes
read -r -a REPO_NAMES <<<"$(name_set)"
# teardown.sh's roles, read the same way rather than restated here.
eval "$(grep -m1 '^KNOWN_ROLES=' "$TEARDOWN")"
read -r -a ROLES_KNOWN <<<"${KNOWN_ROLES:-}"

# The two sandboxes of a role, told apart by the membership rule itself
# rather than by their spelling: the WORK one is the name that is both a box
# and a repository, and the NOTIFY one is the name the repository set holds
# that the box set does not — "a repository and never a box", one per role.
work_for_role() {
  local n
  for n in ${REPO_NAMES[@]+"${REPO_NAMES[@]}"}; do
    case "$BOX_NAMES" in *" $n "*) ;; *) continue ;; esac
    case "$n" in *"$1"*) printf '%s\n' "$n"; return 0 ;; esac
  done
  return 1
}
notify_for_role() {
  local n
  for n in ${REPO_NAMES[@]+"${REPO_NAMES[@]}"}; do
    case "$BOX_NAMES" in *" $n "*) continue ;; esac
    case "$n" in *"$1"*) printf '%s\n' "$n"; return 0 ;; esac
  done
  return 1
}

# The guard that keeps every case below from passing by running zero times.
# A derivation that stops finding its subject has to say so: a `for` loop
# over an empty set is the one way a coverage fix quietly un-covers itself,
# and this whole section is a coverage fix.
NOTIFY_FOUND=0
for role in ${ROLES_KNOWN[@]+"${ROLES_KNOWN[@]}"}; do
  notify_for_role "$role" >/dev/null && NOTIFY_FOUND=$((NOTIFY_FOUND + 1))
done
if [ "${#ROLES_KNOWN[@]}" -gt 0 ] && [ "$NOTIFY_FOUND" -eq "${#ROLES_KNOWN[@]}" ]; then
  ok "every-role-has-a-repository-only-sandbox-in-the-name-set"
else
  bad "every-role-has-a-repository-only-sandbox-in-the-name-set (roles=${#ROLES_KNOWN[@]}, found=$NOTIFY_FOUND, repo set='${REPO_NAMES[*]}')"
fi

# `repo delete danmt/crew-drill-triage` is a PREFIX of the notify sandbox's
# own delete call, so the substring `called` cannot tell the round's two
# sandboxes apart — the work half's assertion would be satisfied by the
# notify half's deletion, and a teardown that deleted only the notify one
# would read as a clean round. Widening the population is what makes the
# difference matter, so the cases below match the whole recorded call line.
called_line() { grep -qxF -- "$1" "$CALLS"; }

# The delete set: a whole round clears BOTH sandboxes of every role, in one
# run, and neither at the other's expense.
WORK_SLUGS="" NOTIFY_SLUGS=""
for role in ${ROLES_KNOWN[@]+"${ROLES_KNOWN[@]}"}; do
  WORK_SLUGS="$WORK_SLUGS danmt/$(work_for_role "$role")"
  NOTIFY_SLUGS="$NOTIFY_SLUGS danmt/$(notify_for_role "$role")"
done
run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" \
    "STUB_REPOS=$WORK_SLUGS$NOTIFY_SLUGS" -- --yes
if [ "$RC" -eq 0 ]; then
  ok "a-round-carrying-both-sandboxes-per-role-exits-zero"
else
  bad "a-round-carrying-both-sandboxes-per-role-exits-zero (rc=$RC, got '$OUT')"
fi
for role in ${ROLES_KNOWN[@]+"${ROLES_KNOWN[@]}"}; do
  notify="$(notify_for_role "$role")"
  work="$(work_for_role "$role")"
  if called_line "gh repo delete danmt/$notify --yes"; then
    ok "deletes-notify-sandbox-$notify"
  else
    bad "deletes-notify-sandbox-$notify (calls='$(cat "$CALLS")')"
  fi
  if called_line "gh repo delete danmt/$work --yes"; then
    ok "still-deletes-work-sandbox-$work-alongside-it"
  else
    bad "still-deletes-work-sandbox-$work-alongside-it (calls='$(cat "$CALLS")')"
  fi
done

# Then the two gates and the exactness rule, per role, over the sandbox that
# was outside the population.
for role in ${ROLES_KNOWN[@]+"${ROLES_KNOWN[@]}"}; do
  notify="$(notify_for_role "$role")"

  # A repository and never a box: the box name set must not have grown the
  # notify name along with the repository set. Asserted in both directions
  # like every other double in this file, because a widening that leaked
  # into the box half would delete a box the drill never minted.
  run "CREW_ROSTER=$FLEET" "STUB_BOXES=$notify" -- --box "$notify" --yes
  if [ "$RC" -ne 0 ] && says "$notify" && says "not a drill box" && ! called "box rm"; then
    ok "notify-sandbox-$notify-is-a-repository-and-never-a-box"
  else
    bad "notify-sandbox-$notify-is-a-repository-and-never-a-box (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
  fi

  # The ownership gate. A drill-shaped notify name under somebody else's
  # account is refused, naming both the owner it has and the identity it
  # would need — refusing is recoverable by logging in as that identity,
  # deleting is not.
  run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPOS=other/$notify" \
      -- --sandbox "other/$notify" --yes
  if [ "$RC" -eq 1 ] && says "other/$notify" && says "danmt" && ! called "repo delete"; then
    ok "refuses-notify-sandbox-$notify-owned-by-someone-else"
  else
    bad "refuses-notify-sandbox-$notify-owned-by-someone-else (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
  fi

  # And the converse, for the same reason the work half asserts it: a gate
  # that refused the round's own notify sandbox would clear nothing.
  run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPOS=danmt/$notify" \
      -- --sandbox "danmt/$notify" --yes
  if [ "$RC" -eq 0 ] && called_line "gh repo delete danmt/$notify --yes"; then
    ok "accepts-notify-sandbox-$notify-under-this-identity"
  else
    bad "accepts-notify-sandbox-$notify-under-this-identity (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
  fi

  # Prefix is not membership, in the two directions a near-miss arrives
  # from. Both fixtures EXIST and are owned by this identity, so the exact
  # set is the only thing standing between them and `gh repo delete` — which
  # is the whole reason the set is exact.
  longer="$notify-2"
  run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPOS=danmt/$longer" \
      -- --sandbox "danmt/$longer" --yes
  if [ "$RC" -eq 1 ] && says "$longer" && says "not a drill sandbox" && ! called "repo delete"; then
    ok "refuses-$longer-which-merely-extends-a-notify-sandbox-name"
  else
    bad "refuses-$longer-which-merely-extends-a-notify-sandbox-name (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
  fi

done

# The operator's own scratch repository, named in the drill's family for a
# role the drill does not know — the repository twin of the
# `crew-drill-experiment` box the box half already protects. Derived from one
# role rather than looped: substituting the role out of the name collapses to
# the same fixture whichever role it came from, and three runs of one case
# under one label is noise, not coverage.
foreign="$(notify_for_role "${ROLES_KNOWN[0]}")"
foreign="${foreign/${ROLES_KNOWN[0]}/experiment}"
run "CREW_ROSTER=$FLEET" "STUB_BOXES=" "STUB_LOGIN=danmt" "STUB_REPOS=danmt/$foreign" \
    -- --sandbox "danmt/$foreign" --yes
if [ "$RC" -eq 1 ] && says "$foreign" && says "not a drill sandbox" && ! called "repo delete"; then
  ok "refuses-$foreign-a-notify-shaped-name-for-a-role-the-drill-does-not-know"
else
  bad "refuses-$foreign-a-notify-shaped-name-for-a-role-the-drill-does-not-know (rc=$RC, calls='$(cat "$CALLS")', got '$OUT')"
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
