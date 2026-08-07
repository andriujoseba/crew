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
#
# Exit status, and the distinction it carries:
#
#   0  every resource class this run was asked to clear was INSPECTED, and
#      whatever of it existed is gone. Only this answer means a clean host.
#   1  refused (a name outside the deletable set), or a deletion failed.
#   2  INCOMPLETE — at least one requested class could not be inspected at
#      all, so what it holds is unknown and may still be standing.
#
# 2 exists because "absent" and "could not tell" must never collapse. A
# teardown that could not read the box inventory, or had no gh identity to
# address the sandboxes with, and reported a clean host anyway is the
# leftovers-nobody-knows-about shape #217 was filed about — produced by the
# script written to end it. An INCOMPLETE run still deletes everything it
# COULD see; what it may not do is return success.
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

# A flag whose argument was left off is an operator error, and it gets the
# usage line rather than `line 55: $2: unbound variable`. Nothing is deleted
# on this path either way; a raw bash trace just makes a typo look like a bug
# in the script the operator is about to trust with `box rm`.
need() { [ "$1" -ge 2 ] || { usage >&2; die "$2 needs an argument"; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --roles)   need $# --roles;   ROLES="$ROLES $2"; shift 2 ;;
    --role)    need $# --role;    ROLES="$ROLES $2"; shift 2 ;;
    --box)     need $# --box;     BOXES+=("$2"); shift 2 ;;
    --sandbox) need $# --sandbox; REPOS+=("$2"); shift 2 ;;
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

# --- which CLIs are here at all -------------------------------------------
# Read before validation, because the sandbox half's names are derived from
# the host identity and so the identity has to resolve before there is
# anything to validate.
have_box=0
command -v box >/dev/null 2>&1 && have_box=1
have_gh=0
command -v gh >/dev/null 2>&1 && have_gh=1

# Every class this run was asked to clear but could not READ, one entry each,
# naming the class and the reason. A non-empty list is exit 2 and forbids the
# clean-host claim, whatever else the run managed to delete.
declare -a UNINSPECTED=()

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
#
# The identity is a precondition for INSPECTING repositories, not only for
# NAMING them, so it is required whenever any sandbox is in play — including
# an explicit `--sandbox owner/repo`, which is surveyed by a `gh repo view`
# that fails identically for "no such repository" and "not logged in". An
# unauthenticated survey would answer "absent" for a repository standing in
# plain sight.
REPOS_REQUESTED=0
[ -n "${ROLES// /}" ] && REPOS_REQUESTED=1
[ "${#REPOS[@]}" -gt 0 ] && REPOS_REQUESTED=1

REPO_OWNER=""
REPO_INSPECT_FAIL=""
if [ "$REPOS_REQUESTED" -eq 1 ]; then
  if [ "$have_gh" -eq 0 ]; then
    REPO_INSPECT_FAIL="no gh CLI on this host"
  else
    REPO_OWNER="$(gh api user --jq .login 2>/dev/null | tr -d '\r\n')" || REPO_OWNER=""
    [ -n "$REPO_OWNER" ] ||
      REPO_INSPECT_FAIL="gh has no usable identity here (gh api user failed)"
  fi
  if [ -n "$REPO_OWNER" ] && [ -n "${ROLES// /}" ]; then
    for role in $ROLES; do REPOS+=("$REPO_OWNER/crew-drill-$role"); done
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
# The inventory is read ONCE and must PARSE before a single name is looked up
# in it. The old shape asked `box list --json | jq` per name and read every
# non-zero as "does not exist", so `box` installed with an unanswerable
# inventory — or a missing or broken `jq` — answered "absent" for every name
# and printed a clean host. `jq -e 'type == "array"'` is the whole gate: 0 on
# a real array (`[]` included, which is a genuinely empty host), non-zero on
# unparseable input and 127 when there is no jq to ask.
BOX_LIST=""
BOX_LIST_OK=0
if [ "$have_box" -eq 1 ]; then
  if BOX_LIST="$(box list --json 2>/dev/null)" &&
     printf '%s' "$BOX_LIST" | jq -e 'type == "array"' >/dev/null 2>&1; then
    BOX_LIST_OK=1
  fi
fi

# Only ever called behind BOX_LIST_OK, so its non-zero really does mean
# "measured, and not there".
box_exists() {
  printf '%s' "$BOX_LIST" | jq -e --arg n "$1" '.[] | select(.name == $n)' >/dev/null 2>&1
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
if [ "${#BOXES[@]}" -gt 0 ]; then
  if [ "$have_box" -eq 0 ]; then
    UNINSPECTED+=("boxes (${BOXES[*]}) — no box CLI on this host")
  elif [ "$BOX_LIST_OK" -eq 0 ]; then
    UNINSPECTED+=("boxes (${BOXES[*]}) — 'box list --json' could not be read or parsed")
  else
    for name in "${BOXES[@]}"; do
      box_exists "$name" && DOOMED_BOXES+=("$name")
    done
  fi
fi

if [ "$REPOS_REQUESTED" -eq 1 ] && [ -n "$REPO_INSPECT_FAIL" ]; then
  UNINSPECTED+=("sandbox repositories of this round — $REPO_INSPECT_FAIL")
else
  for repo in ${REPOS[@]+"${REPOS[@]}"}; do
    gh repo view "$repo" >/dev/null 2>&1 && DOOMED_REPOS+=("$repo")
  done
fi

# Said before anything is deleted and repeated in the exit status, because
# this is the line that decides whether the host is clean. rehearsal-all.sh
# turns the 2 into its own INCOMPLETE summary row rather than `ok teardown`.
if [ "${#UNINSPECTED[@]}" -gt 0 ]; then
  echo "teardown: INCOMPLETE — this run could not inspect everything it was asked to clear:" >&2
  printf '  NOT inspected: %s\n' "${UNINSPECTED[@]}" >&2
  echo "  Whatever those hold may still be standing. This is NOT a clean host." >&2
  echo "  Re-run once they can be read (a logged-in gh, a box CLI with a readable" >&2
  echo "  inventory, jq on PATH), or name the survivors: --box <name> / --sandbox <owner>/<repo>" >&2
fi

# Idempotence: a second run over a clean host has nothing to say and nothing
# to ask. It reports so and exits zero, which is what makes teardown safe to
# wire into rehearsal-all.sh unconditionally — but ONLY when every requested
# class was actually inspected. "I found nothing" and "I could not look" are
# the same sentence to an operator and must not be the same exit status.
if [ "${#DOOMED_BOXES[@]}" -eq 0 ] && [ "${#DOOMED_REPOS[@]}" -eq 0 ]; then
  if [ "${#UNINSPECTED[@]}" -gt 0 ]; then
    echo "teardown: nothing to delete among what could be inspected — see NOT inspected above."
    exit 2
  fi
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
  [ "${#UNINSPECTED[@]}" -eq 0 ] || exit 2
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

# An INCOMPLETE run still deleted everything it could see — that half of the
# host really is clean and there is no reason to leave it dirty. What it may
# not do is call the whole thing done. A deletion that FAILED is the louder
# fact and keeps 1; only an otherwise-clean run degrades to 2.
[ "$rc" -ne 0 ] && exit "$rc"
[ "${#UNINSPECTED[@]}" -eq 0 ] || exit 2
exit 0
