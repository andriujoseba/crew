#!/usr/bin/env bash
# drill/rehearsal-config.sh — exercise operator registry convergence against
# one REAL box on a box host.
#
# Run after rehearsal.sh has installed the named drill box:
#
#   drill/rehearsal-config.sh --box crew-drill-reviewer \
#     --agent claude --role reviewer
#
# The fixture is always built with `crew init`. Every case reaches the real
# box through `crew upgrade`; this is deliberately not another install.sh unit
# test. Teardown restores repos.txt and its provenance record byte-for-byte.
set -uo pipefail

BOX_NAME=""
AGENT="claude"
ROLE="reviewer"

usage() {
  echo "usage: drill/rehearsal-config.sh --box <name> [--agent <name>] [--role triage|builder|reviewer]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --box)   BOX_NAME="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --role)  ROLE="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done
[ -n "$BOX_NAME" ] || { usage; exit 1; }
case "$BOX_NAME" in
  crew-drill-*) ;;
  *)
    echo "refusing non-drill box '$BOX_NAME' — operator-config rehearsal targets crew-drill-* boxes only" >&2
    exit 1 ;;
esac
case "$ROLE" in
  triage|builder|reviewer) ;;
  *) echo "unknown role '$ROLE' (triage, builder or reviewer)" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/cli/crew"
command -v box >/dev/null || { echo "drill/rehearsal-config.sh runs on a box HOST — no 'box' on PATH"; exit 1; }

PASS=0
declare -a FAILS=()
ok()   { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1${2:+  — $2}"; FAILS+=("$1"); }
bx()   { box exec "$BOX_NAME" -- bash -lc "$1" </dev/null; }
put_registry() {
  # shellcheck disable=SC2016  # expanded by bash inside the box
  box exec "$BOX_NAME" -- bash -lc '
    set -euo pipefail
    destination="$HOME/duty/repos.txt"
    tmp="$(mktemp "$HOME/duty/.repos.XXXXXX")"
    cat >"$tmp"
    mv "$tmp" "$destination"
  ' <"$1"
}

TMP="$(mktemp -d)"
CONFIG="$TMP/operator"
INCOMPLETE="$TMP/incomplete"
BACKUP_TAG=".crew-config-drill-$$"
REPOS_WAS=""
PROVENANCE_WAS=""

cleanup() {
  local rc=$? restore_rc=0 final_rc
  if [ -n "$REPOS_WAS" ]; then
    if bx "
      set -e
      if [ '$REPOS_WAS' = present ]; then
        mv ~/$BACKUP_TAG.repos ~/duty/repos.txt
      else
        rm -f ~/duty/repos.txt ~/$BACKUP_TAG.repos
      fi
      if [ '$PROVENANCE_WAS' = present ]; then
        mv ~/$BACKUP_TAG.provenance ~/duty/.repos.txt.crew-provenance
      else
        rm -f ~/duty/.repos.txt.crew-provenance ~/$BACKUP_TAG.provenance
      fi
    "; then
      echo "teardown: restored $BOX_NAME repos.txt and registry provenance to their pre-drill state"
    else
      restore_rc=1
      echo "teardown: WARNING — could not restore $BOX_NAME registry; stop the box and inspect ~/$BACKUP_TAG.*" >&2
    fi
  fi
  rm -rf -- "$TMP"
  final_rc="$rc"
  if [ "$restore_rc" -ne 0 ] && [ "$final_rc" -eq 0 ]; then final_rc=1; fi
  # `return` from an EXIT-trap function cannot change the shell's status.
  # Exit explicitly so a green case body plus a failed registry restore is a
  # failed drill, never an "ok config" summary over changed containment.
  trap - EXIT
  exit "$final_rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "== operator-config rehearsal (real box $BOX_NAME)"

if ! "$CREW" init "$CONFIG" >"$TMP/init.out" 2>&1; then
  echo "could not build fixture with crew init: $(cat "$TMP/init.out")" >&2
  exit 1
fi
printf '%s %s %s\n' "$BOX_NAME" "$AGENT" "$ROLE" >"$CONFIG/fleet.roster"
ok "fixture fleet built by crew init"

# The assertion is evaluated inside cli/crew immediately after config
# resolution. If this export is lost, every command below must fail rather
# than quietly exercising examples/ with CONFIG_IS_OPERATOR=0.
export CREW_CONFIG_DIR="$CONFIG"
export CREW_EXPECT_OPERATOR_CONFIG=1
if "$CREW" profiles >/dev/null 2>"$TMP/mode.err"; then
  ok "operator config selected (CONFIG_IS_OPERATOR=1)"
else
  fail "operator config selected (CONFIG_IS_OPERATOR=1)" "$(cat "$TMP/mode.err")"
  exit 1
fi

REPOS_RAW="$(bx "if [ -f ~/duty/repos.txt ]; then cp ~/duty/repos.txt ~/$BACKUP_TAG.repos; echo present; else echo absent; fi" | tr -d '\r\n')" \
  || { echo "cannot back up $BOX_NAME repos.txt — refusing before mutation" >&2; exit 1; }
PROVENANCE_RAW="$(bx "if [ -f ~/duty/.repos.txt.crew-provenance ]; then cp ~/duty/.repos.txt.crew-provenance ~/$BACKUP_TAG.provenance; echo present; else echo absent; fi" | tr -d '\r\n')" \
  || { echo "cannot back up $BOX_NAME registry provenance — refusing before mutation" >&2; exit 1; }
case "$REPOS_RAW:$PROVENANCE_RAW" in
  present:present|present:absent|absent:present|absent:absent) ;;
  *) echo "registry backup returned an unknown state — refusing before mutation" >&2; exit 1 ;;
esac
# Arm cleanup only after BOTH receipts are complete and validated. Before this
# assignment, every refusal path leaves the box untouched; an empty or noisy
# receipt can never be interpreted as "the file was absent, delete it".
REPOS_WAS="$REPOS_RAW"
PROVENANCE_WAS="$PROVENANCE_RAW"

upgrade_operator() {
  if ! "$CREW" upgrade "$BOX_NAME" >"$TMP/upgrade.out" 2>&1; then return 1; fi
  ! grep -qF "upgrade FAILED" "$TMP/upgrade.out"
}
registry_is() {
  local expected="$1" actual
  actual="$(bx "cat ~/duty/repos.txt 2>/dev/null" | tr -d '\r')"
  [ "$actual" = "$expected" ]
}

# Prime a known transported value so the highest-risk case starts from an
# authentic provenance state rather than a hand-written imitation of one.
printf 'drill/baseline\n' >"$CONFIG/repos.txt"
bx "printf '%s\n' drill/baseline > ~/duty/repos.txt; rm -f ~/duty/.repos.txt.crew-provenance"
upgrade_operator || { fail "veto setup converges a baseline" "$(tail -5 "$TMP/upgrade.out")"; exit 1; }

# 1. Veto holds and is loud.
bx "printf '%s\n' drill/narrow > ~/duty/repos.txt"
printf 'drill/wide\n' >"$CONFIG/repos.txt"
upgrade_operator || true
if registry_is drill/narrow &&
   grep -qF "$BOX_NAME: repos.txt diverged" "$TMP/upgrade.out" &&
   grep -qF "LEFT UNCHANGED" "$TMP/upgrade.out"; then
  ok "veto holds on a real box and names it loudly"
else
  fail "veto holds on a real box and names it loudly" "$(tail -8 "$TMP/upgrade.out")"
fi

# 2a. The one-time migration adopts a shipped-example registry.
put_registry "$ROOT/examples/repos.txt"
bx "rm -f ~/duty/.repos.txt.crew-provenance"
printf 'drill/adopted\n' >"$CONFIG/repos.txt"
upgrade_operator || true
if registry_is drill/adopted && grep -qF "adopted and converged" "$TMP/upgrade.out"; then
  ok "no-provenance migration adopts the shipped example"
else
  fail "no-provenance migration adopts the shipped example" "$(tail -8 "$TMP/upgrade.out")"
fi

# 2b. The same migration refuses an unknown local registry, loudly.
bx "printf '%s\n' drill/unknown-local > ~/duty/repos.txt; rm -f ~/duty/.repos.txt.crew-provenance"
printf 'drill/incoming\n' >"$CONFIG/repos.txt"
upgrade_operator || true
if registry_is drill/unknown-local &&
   grep -qF "$BOX_NAME: repos.txt diverged" "$TMP/upgrade.out" &&
   grep -qF "LEFT UNCHANGED" "$TMP/upgrade.out"; then
  ok "no-provenance migration refuses and names an unknown registry"
else
  fail "no-provenance migration refuses and names an unknown registry" "$(tail -8 "$TMP/upgrade.out")"
fi

# 3. Once adopted, an untouched registry follows the operator definition.
bx "printf '%s\n' drill/converge-before > ~/duty/repos.txt; rm -f ~/duty/.repos.txt.crew-provenance"
printf 'drill/converge-before\n' >"$CONFIG/repos.txt"
upgrade_operator || true
printf 'drill/converge-before\ndrill/converge-added\n' >"$CONFIG/repos.txt"
upgrade_operator || true
if registry_is $'drill/converge-before\ndrill/converge-added' &&
   grep -qF "converged " "$TMP/upgrade.out"; then
  ok "untouched registry converges an added repo through crew upgrade"
else
  fail "untouched registry converges an added repo through crew upgrade" "$(tail -8 "$TMP/upgrade.out")"
fi

# 4. With no operator directory selected, examples/ is a seed, not authority —
# and since #216 it is not even that: a mutating verb REFUSES there outright.
# Both halves are asserted. Containment alone would now pass vacuously (a verb
# that never runs converges nothing), and a drill that cannot tell "refused"
# from "ran and declined" is exactly the drill that stops noticing when the
# refusal is lost.
bx "printf '%s\n' drill/fallback-contained > ~/duty/repos.txt; rm -f ~/duty/.repos.txt.crew-provenance"
(
  cd "$ROOT/examples"
  XDG_CONFIG_HOME="$TMP/no-such-xdg" \
    env -u CREW_CONFIG_DIR -u CREW_EXPECT_OPERATOR_CONFIG "$CREW" upgrade "$BOX_NAME"
) >"$TMP/fallback.out" 2>&1 || true
if registry_is drill/fallback-contained; then
  ok "examples fallback does not converge an existing registry"
else
  fail "examples fallback does not converge an existing registry" "$(tail -8 "$TMP/fallback.out")"
fi
if grep -qF "refuses under the shipped example fleet definition" "$TMP/fallback.out" &&
   grep -qF "crew init" "$TMP/fallback.out"; then
  ok "examples fallback refuses to upgrade at all, and names crew init"
else
  fail "examples fallback refuses to upgrade at all, and names crew init" "$(tail -8 "$TMP/fallback.out")"
fi

# 4a. ...and the read-only verbs still work there, banner and all. This is the
# half a real host needs: refusing everything would leave an operator with no
# way to see WHY their unconfigured host refuses.
(
  cd "$ROOT/examples"
  XDG_CONFIG_HOME="$TMP/no-such-xdg" \
    env -u CREW_CONFIG_DIR -u CREW_EXPECT_OPERATOR_CONFIG "$CREW" status
) >"$TMP/fallback-status.out" 2>&1 || true
if grep -qF "NO operator fleet definition" "$TMP/fallback-status.out"; then
  ok "examples fallback still reports status, and says what it is reading"
else
  fail "examples fallback still reports status, and says what it is reading" \
    "$(tail -8 "$TMP/fallback-status.out")"
fi

# 5. A roster alone is not allowed to borrow the rest from examples/.
mkdir -p "$INCOMPLETE"
printf '%s %s %s\n' "$BOX_NAME" "$AGENT" "$ROLE" >"$INCOMPLETE/fleet.roster"
if CREW_CONFIG_DIR="$INCOMPLETE" CREW_EXPECT_OPERATOR_CONFIG=1 "$CREW" profiles \
     >"$TMP/incomplete.out" 2>&1; then
  fail "incomplete operator trio is refused" "fleet.roster alone exited 0"
elif grep -qF "fleet.conf repos.txt" "$TMP/incomplete.out"; then
  ok "incomplete operator trio is refused and names fleet.conf and repos.txt"
else
  fail "incomplete operator trio is refused and names fleet.conf and repos.txt" "$(cat "$TMP/incomplete.out")"
fi

echo
echo "== operator-config rehearsal summary: $PASS ok, ${#FAILS[@]} failed"
# fleet.roster and fleet.conf intentionally remain drill fixture state: this
# script now refuses non-drill targets, and rehearsal.sh installed this box in
# the same run. Registry bytes and provenance are different — they are the
# containment boundary and therefore always return to their pre-drill state.
[ "${#FAILS[@]}" -eq 0 ]
