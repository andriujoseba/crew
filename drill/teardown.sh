#!/usr/bin/env bash
# drill/teardown.sh — remove what one drill round created, and nothing else.
#
#   drill/teardown.sh [--roles "triage builder reviewer"] [--role <role>]
#                     [--box <name>] [--sandbox <owner/repo>]
#                     [--dry-run] [--yes]
#
# The rehearsal mints real infrastructure — one box per role on the host, and
# one PUBLIC sandbox repository per role under the host's gh identity — and
# nothing in the tree removed either, so rounds accreted. Four boxes at 2 CPU
# / 4 GiB / 20 GiB with two snapshots apiece, still ARMED and still ticking
# against their sandboxes for a rehearsal that ended days ago, and four public
# repositories carrying bot PR traffic on the operator's own account (#217).
#
# `crew down` and `crew upgrade --all` cannot reach them: both iterate the
# ROSTER, and drill boxes are off-roster by construction. That is also why
# this is a drill script and not a crew verb — the fleet CLI's standing
# promise is that it never deletes a box, and deleting is this script's only
# job.
#
# The safety story is one predicate, and it shapes everything below: a name is
# deletable only when it is EXACTLY one of the drill's own names AND is named
# by no roster this host can see. Both halves are needed. The name set alone
# would delete a fleet member an operator had called `crew-drill-builder`; the
# roster alone would delete any off-roster box on the machine.
#
# Every target is validated BEFORE any of them is deleted, so a command
# carrying one bad name removes nothing at all — a partial teardown that
# stopped at the bad name would leave the operator guessing which half ran.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The roles the rehearsal knows, which is what `crew-drill-<role>` can expand
# to. rehearsal.sh validates --role against this same set.
KNOWN_ROLES="triage builder reviewer"

ROLES=""
declare -a BOXES=()
declare -a REPOS=()
DRY=0
YES=0
[ -n "${CREW_YES:-}" ] && YES=1

usage() {
  echo "usage: drill/teardown.sh [--roles \"triage builder reviewer\"] [--role <role>]"
  echo "         [--box <name>] [--sandbox <owner/repo>] [--dry-run] [--yes]"
}

die() { echo "teardown: $1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --roles)   ROLES="$ROLES $2"; shift 2 ;;
    --role)    ROLES="$ROLES $2"; shift 2 ;;
    --box)     BOXES+=("$2"); shift 2 ;;
    --sandbox) REPOS+=("$2"); shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes|-y)  YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

for role in $ROLES; do
  case " $KNOWN_ROLES " in
    *" $role "*) ;;
    *) die "unknown --role '$role' (triage, builder or reviewer)" ;;
  esac
done

# Naming nothing means the whole round: every role's box and every role's
# sandbox. Naming a --box or a --sandbox and no role targets exactly those, so
# a round that ran one leg can be cleared without touching the others.
if [ -z "${ROLES// /}" ] && [ "${#BOXES[@]}" -eq 0 ] && [ "${#REPOS[@]}" -eq 0 ]; then
  ROLES="$KNOWN_ROLES"
fi

# --- the deletable-name predicate ----------------------------------------
# The drill's own names, exactly: `crew-drill-<role>` per role, plus the bare
# `crew-drill` that rehearsal.sh defaulted to before it went one-box-per-role
# (0d1bc0c), which is why one is still standing on the operator's host. The
# sandbox set adds `crew-drill-sandbox`, that era's repository.
#
# EXACT names, never a `crew-drill*` prefix match. A prefix would make the
# predicate agree to delete anything an operator happened to name that way —
# and the operator's own scratch box is exactly the thing this script must not
# reach. Refusing a near-miss costs one flag; deleting one costs a machine.
drill_box_names() {
  local role
  printf '%s\n' crew-drill
  for role in $KNOWN_ROLES; do printf 'crew-drill-%s\n' "$role"; done
}
drill_repo_names() { drill_box_names; printf '%s\n' crew-drill-sandbox; }

is_drill_box()  { drill_box_names  | grep -qxF -- "$1"; }
is_drill_repo() { drill_repo_names | grep -qxF -- "$1"; }

# --- the roster, as protection rather than as selection -------------------
# cli/crew RESOLVES one fleet definition: CREW_ROSTER, else CREW_CONFIG_DIR,
# else the first candidate directory carrying a fleet.roster. Protection is
# the other question — not "which fleet am I acting on" but "is this name a
# real fleet member anywhere on this host" — so this reads the UNION of every
# roster it can see. A roster that is not the one in force still names boxes
# that exist here, and #51 is what a drill box counted as a fleet member costs
# in the other direction.
#
# An EXPLICIT override that does not resolve is an error, matching cli/crew:
# an operator who named a roster and got silence would believe a protection
# ran that never did.
roster_files() {
  local c
  if [ "${CREW_ROSTER+x}" = x ]; then
    if [ -z "$CREW_ROSTER" ] || [ ! -f "$CREW_ROSTER" ]; then
      die "CREW_ROSTER '$CREW_ROSTER' is not a readable roster file"
    fi
    printf '%s\n' "$CREW_ROSTER"
  fi
  if [ "${CREW_CONFIG_DIR+x}" = x ]; then
    if [ -z "$CREW_CONFIG_DIR" ] || [ ! -f "$CREW_CONFIG_DIR/fleet.roster" ]; then
      die "CREW_CONFIG_DIR '${CREW_CONFIG_DIR:-}' is not a fleet definition (fleet.roster is required)"
    fi
    printf '%s\n' "$CREW_CONFIG_DIR/fleet.roster"
  fi
  for c in "${XDG_CONFIG_HOME:-$HOME/.config}/crew" "$PWD" "$ROOT/examples"; do
    [ -f "$c/fleet.roster" ] && printf '%s\n' "$c/fleet.roster"
  done
  return 0
}

ROSTER_FILES="$(roster_files)" || exit 1
roster_names() {
  local f
  [ -n "$ROSTER_FILES" ] || return 0
  printf '%s\n' "$ROSTER_FILES" | while read -r f; do
    [ -n "$f" ] && grep -vE '^[[:space:]]*(#|$)' "$f" | awk '{print $1}'
  done
}
ROSTER_NAMES="$(roster_names)"
is_roster_member() { printf '%s\n' "$ROSTER_NAMES" | grep -qxF -- "$1"; }

# --- validate every target, before touching anything ----------------------
declare -a REFUSALS=()
for role in $ROLES; do BOXES+=("crew-drill-$role"); done

for name in ${BOXES[@]+"${BOXES[@]}"}; do
  if is_roster_member "$name"; then
    # Checked FIRST and reported as its own refusal: a roster member whose
    # name happens to match the drill pattern is the one case where the name
    # set says yes, so it is the case worth naming out loud.
    REFUSALS+=("box $name is a fleet member (named in a roster on this host) — teardown never removes a roster member")
  elif ! is_drill_box "$name"; then
    REFUSALS+=("box $name is not a drill box — teardown removes only: $(drill_box_names | paste -sd' ' -)")
  fi
done

# The sandbox owner comes from the host identity, exactly as rehearsal.sh
# derives it (`$HOST_ME/crew-drill-$ROLE`). No identity means the repo half
# cannot be addressed at all — say so rather than quietly tearing down half a
# round and reporting a clean host.
REPO_OWNER=""
REPO_HALF=1
if [ -n "${ROLES// /}" ]; then
  if command -v gh >/dev/null 2>&1; then
    REPO_OWNER="$(gh api user --jq .login 2>/dev/null | tr -d '\r\n')"
  fi
  if [ -n "$REPO_OWNER" ]; then
    for role in $ROLES; do REPOS+=("$REPO_OWNER/crew-drill-$role"); done
  else
    REPO_HALF=0
  fi
fi

for repo in ${REPOS[@]+"${REPOS[@]}"}; do
  case "$repo" in
    */*/*|/*|*/) REFUSALS+=("sandbox '$repo' is not an <owner>/<repo> slug"); continue ;;
    */*) ;;
    *) REFUSALS+=("sandbox '$repo' is not an <owner>/<repo> slug"); continue ;;
  esac
  if ! is_drill_repo "${repo#*/}"; then
    REFUSALS+=("sandbox $repo is not a drill sandbox — teardown removes only: $(drill_repo_names | paste -sd' ' -)")
  fi
done

if [ "${#REFUSALS[@]}" -gt 0 ]; then
  echo "teardown: REFUSING — nothing was deleted." >&2
  printf '  %s\n' "${REFUSALS[@]}" >&2
  exit 1
fi

# --- survey: what of that actually exists, and when it was created --------
have_box=0
command -v box >/dev/null 2>&1 && have_box=1
have_gh=0
command -v gh >/dev/null 2>&1 && have_gh=1

box_exists() {
  [ "$have_box" -eq 1 ] || return 1
  box list --json 2>/dev/null | jq -e --arg n "$1" '.[] | select(.name == $n)' >/dev/null
}
# `box info --json` returns an ARRAY, and its creation field has moved before;
# every read here degrades to "unknown" rather than killing the survey (#47).
box_created() {
  local d
  d="$(box info "$1" --json 2>/dev/null \
    | jq -r 'if type == "array" then (.[0] // {}) else . end
             | .created_at // .createdAt // .created // "unknown"' 2>/dev/null \
    | head -1 | tr -d '\r' || true)"
  printf '%s\n' "${d:-unknown}"
}
repo_created() {
  local d
  d="$(gh repo view "$1" --json createdAt --jq .createdAt 2>/dev/null | tr -d '\r\n' || true)"
  printf '%s\n' "${d:-unknown}"
}

declare -a DOOMED_BOXES=() DOOMED_REPOS=()
for name in ${BOXES[@]+"${BOXES[@]}"}; do
  box_exists "$name" && DOOMED_BOXES+=("$name")
done
if [ "$have_gh" -eq 1 ]; then
  for repo in ${REPOS[@]+"${REPOS[@]}"}; do
    gh repo view "$repo" >/dev/null 2>&1 && DOOMED_REPOS+=("$repo")
  done
fi

if [ "$REPO_HALF" -eq 0 ]; then
  echo "teardown: no gh identity on this host — the sandbox repositories were NOT inspected."
  echo "          Re-run with a logged-in gh, or name them: --sandbox <owner>/crew-drill-<role>"
fi
if [ "$have_box" -eq 0 ]; then
  echo "teardown: no box CLI on this host — the boxes were NOT inspected."
fi

# Idempotence: a second run over a clean host has nothing to say and nothing
# to ask. It reports so and exits zero, which is what makes teardown safe to
# wire into rehearsal-all.sh unconditionally.
if [ "${#DOOMED_BOXES[@]}" -eq 0 ] && [ "${#DOOMED_REPOS[@]}" -eq 0 ]; then
  echo "teardown: nothing to do — no drill box and no drill sandbox of this round exists."
  exit 0
fi

echo "teardown: this will DELETE, permanently:"
for name in ${DOOMED_BOXES[@]+"${DOOMED_BOXES[@]}"}; do
  echo "  box   $name (created $(box_created "$name"))"
done
for repo in ${DOOMED_REPOS[@]+"${DOOMED_REPOS[@]}"}; do
  echo "  repo  $repo (created $(repo_created "$repo")) — with its issues, PRs and history"
done

if [ "$DRY" -eq 1 ]; then
  echo "teardown: --dry-run, so nothing was deleted."
  exit 0
fi

# Asked ONCE, over the whole list, because a per-item prompt over seven items
# is how an operator learns to answer y without reading.
if [ "$YES" -ne 1 ]; then
  [ -t 0 ] ||
    die "refusing to delete without a terminal to confirm on (CREW_YES=1 or --yes means yes)"
  printf 'teardown: delete all of the above? [y/N] '
  read -r reply || die "aborted."
  case "$reply" in y|Y|yes|YES|Yes) ;; *) die "aborted." ;; esac
fi

rc=0
for name in ${DOOMED_BOXES[@]+"${DOOMED_BOXES[@]}"}; do
  if box rm --force "$name"; then echo "ok   removed box $name"
  else echo "FAIL could not remove box $name" >&2; rc=1; fi
done
for repo in ${DOOMED_REPOS[@]+"${DOOMED_REPOS[@]}"}; do
  if gh repo delete "$repo" --yes; then echo "ok   deleted repo $repo"
  else
    echo "FAIL could not delete repo $repo" >&2
    echo "     (gh needs the delete_repo scope: gh auth refresh -h github.com -s delete_repo)" >&2
    rc=1
  fi
done
exit "$rc"
