#!/usr/bin/env bash
# shared/test/common/detached-run.sh — mirrored suite for detached-run.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP/duty"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"

REPO=fixture/repo
PR=7
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIGEST="$(run_detached "$REPO" "$PR" "$HEAD" -- bash -c 'printf complete')"
for _wait in $(seq 1 100); do
  detached_run_read "$REPO" "$PR" "$HEAD" "$DIGEST" >/dev/null
  [ "$DETACHED_RUN_STATE" = complete ] && break
  sleep 0.02
done
detached_run_read "$REPO" "$PR" "$HEAD" "$DIGEST" >/dev/null
t detached-run-completes complete "$DETACHED_RUN_STATE"
t detached-run-status 0 "$DETACHED_RUN_STATUS"
t detached-run-log complete "$(cat "$DETACHED_RUN_LOG")"
t detached-run-deduplicates "$DIGEST" \
  "$(run_detached "$REPO" "$PR" "$HEAD" -- bash -c 'printf complete')"
t detached-run-finish-recorded 2026 \
  "$(printf '%s' "$DETACHED_RUN_FINISH" | cut -c1-4)"
t detached-run-command-readable 'bash -c printf\ complete' "$DETACHED_RUN_COMMAND"

# The launcher is itself a disposable session/process group. Killing that
# group must not kill the command run_detached put in a fresh setsid group.
SURVIVE_DUTY="$TMP/survive-duty"
SURVIVE_DIGEST="$TMP/survive-digest"
SURVIVE_READY="$TMP/survive-ready"
setsid bash -c '
  export DUTY_DIR=$1 HOME=$2 XDG_CONFIG_HOME=$3
  source "$4/lib/common.sh"
  digest=$(run_detached fixture/repo 8 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    -- bash -c "sleep 0.2; printf survived")
  printf "%s\n" "$digest" >"$5"
  : >"$6"
  sleep 30
' _ "$SURVIVE_DUTY" "$HOME" "$XDG_CONFIG_HOME" "$SHARED" \
  "$SURVIVE_DIGEST" "$SURVIVE_READY" &
SURVIVE_SESSION_PID=$!
for _wait in $(seq 1 100); do [ -f "$SURVIVE_READY" ] && break; sleep 0.02; done
kill -TERM -- "-$SURVIVE_SESSION_PID" 2>/dev/null || true
wait "$SURVIVE_SESSION_PID" 2>/dev/null || true
SURVIVE_RUN_DIGEST="$(cat "$SURVIVE_DIGEST")"
old_duty="$DUTY_DIR"; DUTY_DIR="$SURVIVE_DUTY"
for _wait in $(seq 1 100); do
  detached_run_read fixture/repo 8 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    "$SURVIVE_RUN_DIGEST" >/dev/null
  [ "$DETACHED_RUN_STATE" = complete ] && break
  sleep 0.02
done
t detached-run-survives-launcher-kill complete "$DETACHED_RUN_STATE"
t detached-run-survival-log survived "$(cat "$DETACHED_RUN_LOG")"
DUTY_DIR="$old_duty"

REASON="$(printf 'waiting for suite' | base64 | tr -d '\n')"
review_park_write "$REPO" "$PR" "$HEAD" "$DIGEST" "$REASON"
t review-park-recorded "$DIGEST" \
  "$(_detached_field "$(_review_park_path "$REPO" "$PR" "$HEAD")" digests)"
review_park_clear "$REPO" "$PR" "$HEAD"
if [ -f "$(_review_park_path "$REPO" "$PR" "$HEAD")" ]; then r1=kept; else r1=cleared; fi
t review-park-clears cleared "$r1"

# A valid final declaration is captured against the exact prompted head; a
# malformed attempt is loud so the caller can withhold its seen-ledger commit.
CAPTURE_LOG="$TMP/capture.log"
printf 'PARKED %s#%s@%s runs=%s reason=%s\n' \
  "$REPO" "$PR" "$HEAD" "$DIGEST" "$REASON" >"$CAPTURE_LOG"
review_park_capture "$CAPTURE_LOG" "$REPO" "$PR=$HEAD"
t review-park-capture-valid 0 "$REVIEW_PARK_CAPTURE_INVALID"
t review-park-capture-subject "$PR" "$REVIEW_PARK_CAPTURED"
printf 'PARKED malformed\n' >"$CAPTURE_LOG"
review_park_capture "$CAPTURE_LOG" "$REPO" "$PR=$HEAD"
t review-park-capture-malformed 1 "$REVIEW_PARK_CAPTURE_INVALID"

# Completed runs make the park ready and hand their immutable result facts to
# the next session. A missing stamp expires instead of reading as in-flight.
review_park_write "$REPO" "$PR" "$HEAD" "$DIGEST" "$REASON"
review_park_inspect "$REPO" "$PR" "$HEAD"
t review-park-complete-is-ready ready "$REVIEW_PARK_STATE"
case "$REVIEW_PARK_RESULTS" in *'exit=0'*"log=$DETACHED_RUN_LOG"*) r1=handed ;; *) r1=MISSING ;; esac
t review-park-results-handed handed "$r1"
review_park_clear "$REPO" "$PR" "$HEAD"

MISSING_DIGEST="$(printf '0%.0s' $(seq 1 64))"
review_park_write "$REPO" "$PR" "$HEAD" "$MISSING_DIGEST" "$REASON"
review_park_inspect "$REPO" "$PR" "$HEAD"
t review-park-missing-stamp-expires expired "$REVIEW_PARK_STATE"

# An unfinished run suppresses through the twelfth tick, then the thirteenth
# observation abandons it and deliberately asks for a fresh review.
LONG_DIGEST="$(run_detached "$REPO" 9 cccccccccccccccccccccccccccccccccccccccc \
  -- bash -c 'sleep 30')"
review_park_write "$REPO" 9 cccccccccccccccccccccccccccccccccccccccc \
  "$LONG_DIGEST" "$REASON"
review_park_inspect "$REPO" 9 cccccccccccccccccccccccccccccccccccccccc
t review-park-running-is-parked parked "$REVIEW_PARK_STATE"
PARK_PATH="$(_review_park_path "$REPO" 9 cccccccccccccccccccccccccccccccccccccccc)"
_review_park_rewrite_ticks "$PARK_PATH" "$REVIEW_PARK_TICK_LIMIT"
review_park_inspect "$REPO" 9 cccccccccccccccccccccccccccccccccccccccc
t review-park-bound-expires expired "$REVIEW_PARK_STATE"
if [ -f "$PARK_PATH" ]; then r1=kept; else r1=removed; fi
t review-park-expiry-removes-record removed "$r1"

suite_finish
