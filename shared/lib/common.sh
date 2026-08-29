# common.sh — shared plumbing for the duty engine. Sourced, never executed.
#
# Everything here is fleet-invariant. The box's runtime comes from its agent
# profile (conf/agents/), the shape of its work from its role profile(s)
# (conf/roles/), the pairing from conf/instance.conf (written by install.sh),
# and fleet facts from conf/fleet.defaults.conf + conf/fleet.conf.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # path constants are consumed by the sourcing scripts

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
WORK_DIR="$DUTY_DIR/work"    # main clones, parked on the default branch, fetch-only
TREES_DIR="$DUTY_DIR/trees"  # one worktree per PR; review trees are detached throwaways
LOG_DIR="$DUTY_DIR/logs"     # one file per session — session stdout never
                             # interleaves with duty.log (it corrupted grok's
                             # and kimi's line-oriented metrics)
CONF_DIR="$DUTY_DIR/conf"
PROMPTS_DIR="$DUTY_DIR/prompts"
BIN_DIR="$DUTY_DIR/bin"
REPOS_FILE="$DUTY_DIR/repos.txt"

# The functions live in one module per subject, under common/. Every caller
# still sources THIS file and still gets all of them: the split is a source
# layout, never an interface (#507).
#
# The suite tree mirrors this tree, one suite per module at the same relative
# path — shared/lib/common/identity.sh is covered by shared/test/common/identity.sh.
# That is an invariant and not this split's layout: the next module added here
# brings its mirrored suite with it.
_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common"
# shellcheck source=shared/lib/common/logging.sh
source "$_COMMON_LIB_DIR/logging.sh"
# shellcheck source=shared/lib/common/operating-limits.sh
source "$_COMMON_LIB_DIR/operating-limits.sh"
# shellcheck source=shared/lib/common/conf.sh
source "$_COMMON_LIB_DIR/conf.sh"
# shellcheck source=shared/lib/common/checkout.sh
source "$_COMMON_LIB_DIR/checkout.sh"
# shellcheck source=shared/lib/common/session.sh
source "$_COMMON_LIB_DIR/session.sh"
# shellcheck source=shared/lib/common/breaker.sh
source "$_COMMON_LIB_DIR/breaker.sh"
# shellcheck source=shared/lib/common/ledger.sh
source "$_COMMON_LIB_DIR/ledger.sh"
# shellcheck source=shared/lib/common/identity.sh
source "$_COMMON_LIB_DIR/identity.sh"
# shellcheck source=shared/lib/common/tick-health.sh
source "$_COMMON_LIB_DIR/tick-health.sh"
unset _COMMON_LIB_DIR
