#!/usr/bin/env bash
# shared/test/common/checkout.sh — standalone suite for shared/lib/common/checkout.sh.
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

# --- validate_sha
validate_sha "0123456789abcdef0123456789abcdef01234567" && r1=ok || r1=bad
validate_sha "0123456" && r2=ok || r2=bad
validate_sha "g123456789abcdef0123456789abcdef01234567" && r3=ok || r3=bad
t sha-full ok "$r1"
t sha-short bad "$r2"
t sha-nonhex bad "$r3"

# --- ensure_checkout -------------------------------------------------------
UPSTREAM="$TMP/upstream"
CHECKOUT="$TMP/work/owner__repo"
mkdir -p "$UPSTREAM" "$(dirname "$CHECKOUT")"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.name fixture
git -C "$UPSTREAM" config user.email fixture@example.invalid
printf 'one\n' >"$UPSTREAM/doctrine"
git -C "$UPSTREAM" add doctrine
GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z \
  git -C "$UPSTREAM" commit -qm initial
git clone -q "$UPSTREAM" "$CHECKOUT"
TEST_ENGINE_ID=engine_one
_checkout_engine_id() { printf '%s' "$TEST_ENGINE_ID"; }

printf 'dirty\n' >"$CHECKOUT/local"
DIRTY_LOG=""
for _ in $(seq 1 10); do
  DIRTY_LOG+="$(ensure_checkout owner/repo "$CHECKOUT")"$'\n'
done
t checkout-dirty-warns-once 1 \
  "$(grep -c 'WARN: checkout: .* is dirty on main' <<<"$DIRTY_LOG")"
if grep -Eq 'HEAD age=[0-9]+s' <<<"$DIRTY_LOG"; then r1=aged; else r1=MISSING; fi
t checkout-dirty-warning-names-age aged "$r1"
if [ -f "$CHECKOUT/local" ]; then r1=untouched; else r1=REPAIRED; fi
t checkout-dirty-does-not-repair untouched "$r1"
ensure_checkout owner/repo "$CHECKOUT" >/dev/null
t checkout-return-unchanged 0 "$?"

rm -f "$CHECKOUT/local"
RECOVERY_LOG="$(ensure_checkout owner/repo "$CHECKOUT")"
if grep -Fq 'doctrine checkout recovered' <<<"$RECOVERY_LOG"; then r1=recovered; else r1=SILENT; fi
t checkout-recovery-speaks-once recovered "$r1"
t checkout-recovery-stays-quiet "" "$(ensure_checkout owner/repo "$CHECKOUT")"

mkdir "$CHECKOUT/growing"
GROWING_LOG=""
for tick in $(seq 1 10); do
  printf '%s\n' "$tick" >"$CHECKOUT/growing/$tick"
  GROWING_LOG+="$(ensure_checkout owner/repo "$CHECKOUT")"$'\n'
done
t checkout-growing-untracked-dir-warns-once 1 \
  "$(grep -c 'WARN: checkout: .* is dirty on main' <<<"$GROWING_LOG")"
rm -rf "$CHECKOUT/growing"
ensure_checkout owner/repo "$CHECKOUT" >/dev/null

DETACHED_HEAD="$(git -C "$CHECKOUT" rev-parse HEAD)"
git -C "$CHECKOUT" switch -q --detach
DETACHED_LOG=""
for _ in $(seq 1 10); do
  DETACHED_LOG+="$(ensure_checkout owner/repo "$CHECKOUT")"$'\n'
  DETACHED_RC="$?"
done
t checkout-detached-warns-once 1 \
  "$(grep -c 'WARN: checkout: .* is detached at HEAD' <<<"$DETACHED_LOG")"
if grep -Eq 'detached at HEAD \(age=[0-9]+s\)' <<<"$DETACHED_LOG"; then r1=aged; else r1=MISSING; fi
t checkout-detached-warning-names-age aged "$r1"
t checkout-detached-does-not-move-head "$DETACHED_HEAD" "$(git -C "$CHECKOUT" rev-parse HEAD)"
t checkout-detached-return-unchanged 0 "$DETACHED_RC"
git -C "$CHECKOUT" switch -q main
DETACHED_RECOVERY="$(ensure_checkout owner/repo "$CHECKOUT")"
if grep -Fq 'doctrine checkout recovered' <<<"$DETACHED_RECOVERY"; then r1=recovered; else r1=SILENT; fi
t checkout-detached-recovery-speaks-once recovered "$r1"

git -C "$CHECKOUT" switch -qc topic
MISSING_LOG="$(ensure_checkout owner/repo "$CHECKOUT")"
MISSING_LOG+=$'\n'"$(ensure_checkout owner/repo "$CHECKOUT")"
t checkout-missing-origin-warns-once 1 \
  "$(grep -c 'WARN: checkout: .* is parked on topic, which has no origin/topic' <<<"$MISSING_LOG")"
if grep -Eq 'HEAD age=[0-9]+s' <<<"$MISSING_LOG"; then r1=aged; else r1=MISSING; fi
t checkout-missing-origin-names-age aged "$r1"

# The marker survives in the box working area, while the boot identity changes
# when the engine restarts with the box. That re-arms exactly one announcement;
# an older engine observing the condition never silences it forever.
TEST_ENGINE_ID=engine_two
RESTART_LOG="$(ensure_checkout owner/repo "$CHECKOUT")"
if grep -Fq 'WARN: checkout:' <<<"$RESTART_LOG"; then r1=reannounced; else r1=SILENT; fi
t checkout-engine-state-restart-reannounces reannounced "$r1"
t checkout-restarted-engine-settles "" "$(ensure_checkout owner/repo "$CHECKOUT")"

git -C "$CHECKOUT" switch -q main
ensure_checkout owner/repo "$CHECKOUT" >/dev/null
git -C "$CHECKOUT" config user.name fixture
git -C "$CHECKOUT" config user.email fixture@example.invalid
printf 'upstream\n' >>"$UPSTREAM/doctrine"
git -C "$UPSTREAM" commit -qam upstream
printf 'local\n' >>"$CHECKOUT/doctrine"
git -C "$CHECKOUT" commit -qam local
DIVERGED_HEAD="$(git -C "$CHECKOUT" rev-parse HEAD)"
DIVERGED_LOG=""
for _ in $(seq 1 10); do
  DIVERGED_LOG+="$(ensure_checkout owner/repo "$CHECKOUT")"$'\n'
  DIVERGED_RC="$?"
done
t checkout-diverged-warns-once 1 \
  "$(grep -c 'WARN: checkout: .* histories diverged' <<<"$DIVERGED_LOG")"
if grep -Eq 'HEAD age=[0-9]+s, histories diverged' <<<"$DIVERGED_LOG"; then r1=aged; else r1=MISSING; fi
t checkout-diverged-warning-names-age aged "$r1"
t checkout-diverged-does-not-move-head "$DIVERGED_HEAD" "$(git -C "$CHECKOUT" rev-parse HEAD)"
t checkout-diverged-return-unchanged 0 "$DIVERGED_RC"
git -C "$CHECKOUT" reset -q --hard origin/main
DIVERGED_RECOVERY="$(ensure_checkout owner/repo "$CHECKOUT")"
if grep -Fq 'doctrine checkout recovered' <<<"$DIVERGED_RECOVERY"; then r1=recovered; else r1=SILENT; fi
t checkout-diverged-recovery-speaks-once recovered "$r1"
t checkout-diverged-recovery-stays-quiet "" "$(ensure_checkout owner/repo "$CHECKOUT")"

EMPTY_COMMITTED="$(
  git() { return 0; }
  _checkout_head_age ignored
)"
t checkout-empty-commit-time-is-unknown unknown "$EMPTY_COMMITTED"

suite_finish
