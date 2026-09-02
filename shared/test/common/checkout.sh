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

# --- ensure_main_clone ----------------------------------------------------
# The checkout lifecycle is covered above. Fork cases keep its local git
# fixtures stationary so a synthetic GitHub URL is never fetched.
ensure_main_clone_without_fetch() {
  ensure_checkout() { return 0; }
  ensure_main_clone "$@"
}
export ME=bot
FORK_CALLS="$TMP/fork-calls"

new_main_clone() { # $1=name
  local clone="$TMP/forks/$1"
  mkdir -p "$(dirname "$clone")"
  git clone -q "$UPSTREAM" "$clone"
  printf '%s\n' "$clone"
}

stub_fork_api() { # candidate-parent fork-list-json
  FORK_CANDIDATE_PARENT="$1"
  FORK_LIST_JSON="$2"
  FORK_API_FAIL="${3:-no}"
  : >"$FORK_CALLS"
  gh() {
    printf '%s\n' "$*" >>"$FORK_CALLS"
    case "$*" in
      'api repos/bot/repo --jq '*)
        [ "$FORK_API_FAIL" != candidate ] || return 1
        printf '%s\n' "$FORK_CANDIDATE_PARENT"
        ;;
      'api --paginate repos/owner/repo/forks?per_page=100')
        [ "$FORK_API_FAIL" != list ] || return 1
        printf '%s\n' "$FORK_LIST_JSON"
        ;;
      *) return 97 ;;
    esac
  }
}

FORK_CONVENTIONAL="$(new_main_clone conventional)"
stub_fork_api owner/repo '[]'
ensure_main_clone_without_fetch owner/repo "$FORK_CONVENTIONAL" >/dev/null
t fork-conventional-remote https://github.com/bot/repo.git \
  "$(git -C "$FORK_CONVENTIONAL" remote get-url fork)"
t fork-conventional-one-api-call 1 "$(wc -l <"$FORK_CALLS" | tr -d ' ')"

FORK_NAMED="$(new_main_clone named)"
stub_fork_api '' '[{"id":101,"name":"renamed-repo","full_name":"bot/renamed-repo","owner":{"login":"bot"},"fork":true}]'
ensure_main_clone_without_fetch owner/repo "$FORK_NAMED" >/dev/null
t fork-nonfork-candidate-searches-list 2 "$(wc -l <"$FORK_CALLS" | tr -d ' ')"
t fork-unique-nonconventional-adopted https://github.com/bot/renamed-repo.git \
  "$(git -C "$FORK_NAMED" remote get-url fork)"

FORK_OTHER_PARENT="$(new_main_clone other-parent)"
stub_fork_api somebody/else '[{"id":102,"name":"right-parent","full_name":"bot/right-parent","owner":{"login":"bot"},"fork":true}]'
ensure_main_clone_without_fetch owner/repo "$FORK_OTHER_PARENT" >/dev/null
t fork-wrong-parent-rejected https://github.com/bot/right-parent.git \
  "$(git -C "$FORK_OTHER_PARENT" remote get-url fork)"

FORK_NONE="$(new_main_clone none)"
stub_fork_api '' '[]'
NONE_LOG="$(ensure_main_clone_without_fetch owner/repo "$FORK_NONE" 2>&1)" && NONE_RC=0 || NONE_RC=$?
t fork-zero-match-refuses 1 "$NONE_RC"
t fork-zero-match-adds-no-remote 2 "$(git -C "$FORK_NONE" remote get-url fork >/dev/null 2>&1; printf '%s' "$?")"
if grep -Fq 'no fork of owner/repo owned by bot exists' <<<"$NONE_LOG"; then r1=reported; else r1=MISSING; fi
t fork-zero-match-reported reported "$r1"

FORK_AMBIGUOUS="$(new_main_clone ambiguous)"
stub_fork_api '' '[{"id":103,"name":"one","full_name":"bot/one","owner":{"login":"bot"},"fork":true},{"id":104,"name":"two","full_name":"bot/two","owner":{"login":"bot"},"fork":true},{"id":105,"name":"other","full_name":"somebody/other","owner":{"login":"somebody"},"fork":true}]'
AMBIGUOUS_LOG="$(ensure_main_clone_without_fetch owner/repo "$FORK_AMBIGUOUS" 2>&1)" && AMBIGUOUS_RC=0 || AMBIGUOUS_RC=$?
t fork-ambiguous-refuses 1 "$AMBIGUOUS_RC"
t fork-ambiguous-adds-no-remote 2 "$(git -C "$FORK_AMBIGUOUS" remote get-url fork >/dev/null 2>&1; printf '%s' "$?")"
if grep -Fq '2 forks of owner/repo are owned by bot' <<<"$AMBIGUOUS_LOG"; then r1=reported; else r1=MISSING; fi
t fork-ambiguous-distinct-report reported "$r1"

FORK_REPAIR="$(new_main_clone repair)"
git -C "$FORK_REPAIR" remote add fork https://github.com/somebody/repo.git
stub_fork_api '' '[{"id":106,"name":"renamed-repo","full_name":"bot/renamed-repo","owner":{"login":"bot"},"fork":true}]'
REPAIR_LOG="$(ensure_main_clone_without_fetch owner/repo "$FORK_REPAIR" 2>&1)"
t fork-other-owner-repaired https://github.com/bot/renamed-repo.git \
  "$(git -C "$FORK_REPAIR" remote get-url fork)"
if grep -Fq 'repaired fork remote' <<<"$REPAIR_LOG"; then r1=reported; else r1=MISSING; fi
t fork-repair-reported reported "$r1"
REPAIR_SECOND_LOG="$(ensure_main_clone_without_fetch owner/repo "$FORK_REPAIR" 2>&1)"
t fork-repair-next-tick-reports-nothing "" "$REPAIR_SECOND_LOG"

FORK_PUSH_REPAIR="$(new_main_clone push-repair)"
git -C "$FORK_PUSH_REPAIR" remote add fork git@github.com:bot/custom.git
git -C "$FORK_PUSH_REPAIR" remote set-url --push fork https://github.com/somebody/repo.git
stub_fork_api '' '[{"id":107,"name":"custom","full_name":"bot/custom","owner":{"login":"bot"},"fork":true}]'
PUSH_REPAIR_LOG="$(ensure_main_clone_without_fetch owner/repo "$FORK_PUSH_REPAIR" 2>&1)"
t fork-valid-fetch-url-left-byte-identical git@github.com:bot/custom.git \
  "$(git -C "$FORK_PUSH_REPAIR" remote get-url fork)"
t fork-stale-push-url-repaired https://github.com/bot/custom.git \
  "$(git -C "$FORK_PUSH_REPAIR" remote get-url --push fork)"
if grep -Fq 'repaired fork remote' <<<"$PUSH_REPAIR_LOG"; then r1=reported; else r1=MISSING; fi
t fork-push-repair-reported reported "$r1"

FORK_CACHED="$(new_main_clone cached)"
git -C "$FORK_CACHED" remote add fork https://github.com/bot/custom.git
stub_fork_api '' '[{"id":108,"name":"custom","full_name":"bot/custom","owner":{"login":"bot"},"fork":true}]'
ensure_main_clone_without_fetch owner/repo "$FORK_CACHED" >/dev/null
t fork-cache-upstream owner/repo "$(git -C "$FORK_CACHED" config --local --get crew.fork-upstream)"
t fork-cache-repository bot/custom "$(git -C "$FORK_CACHED" config --local --get crew.fork-repository)"

stub_fork_api '' '[]' candidate
CACHED_LOG="$(ensure_main_clone_without_fetch owner/repo "$FORK_CACHED" 2>&1)" && CACHED_RC=0 || CACHED_RC=$?
t fork-valid-cache-survives-api-outage 0 "$CACHED_RC"
t fork-valid-cache-makes-no-api-call 0 "$(wc -l <"$FORK_CALLS" | tr -d ' ')"
t fork-valid-existing-stays-byte-identical https://github.com/bot/custom.git \
  "$(git -C "$FORK_CACHED" remote get-url fork)"
t fork-valid-second-tick-reports-nothing "" "$CACHED_LOG"

FORK_API_DOWN="$(new_main_clone api-down)"
stub_fork_api '' '[]' list
API_DOWN_LOG="$(ensure_main_clone_without_fetch owner/repo "$FORK_API_DOWN" 2>&1)" && API_DOWN_RC=0 || API_DOWN_RC=$?
t fork-api-failure-refuses-uncached 1 "$API_DOWN_RC"
if grep -Fq 'fork-list API failed' <<<"$API_DOWN_LOG"; then r1=reported; else r1=MISSING; fi
t fork-api-failure-reported reported "$r1"

suite_finish
