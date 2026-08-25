#!/usr/bin/env bash
# shared/test/common/logging.sh — standalone suite for shared/lib/common/logging.sh.
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

# --- rotate_log
printf 'x' >"$TMP/small.log"
rotate_log "$TMP/small.log"
[ -f "$TMP/small.log" ] && r1=kept || r1=gone
t rotate-small kept "$r1"


suite_finish
