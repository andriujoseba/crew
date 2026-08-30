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

REASON="$(printf 'waiting for suite' | base64 | tr -d '\n')"
review_park_write "$REPO" "$PR" "$HEAD" "$DIGEST" "$REASON"
t review-park-recorded "$DIGEST" \
  "$(_detached_field "$(_review_park_path "$REPO" "$PR" "$HEAD")" digests)"
review_park_clear "$REPO" "$PR" "$HEAD"
if [ -f "$(_review_park_path "$REPO" "$PR" "$HEAD")" ]; then r1=kept; else r1=cleared; fi
t review-park-clears cleared "$r1"

suite_finish
