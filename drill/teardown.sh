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
# teardown that could not read the box inventory, had no gh identity to
# address the sandboxes with, or asked after one sandbox and got no answer,
# and reported a clean host anyway, is the leftovers-nobody-knows-about shape
# #217 was filed about — produced by the script written to end it. An
# INCOMPLETE run still deletes everything it COULD see; what it may not do is
# return success.
#
# The distinction is enforced at BOTH grains, because it escapes through
# either: per CLASS (no box, an unreadable inventory, no gh, no identity) and
# per RESOURCE (one repository lookup that failed for a reason that is not a
# measured 404). A live identity plus a dead network is the second kind, and
# the class-level gates cannot see it.
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

# Order-preserving dedupe of an array, through a scratch global. No `mapfile`
# and no namerefs, so this stays where the rest of the drill scripts are, and
# no round-trip through a newline-delimited stream, so a name carrying a
# newline reaches the refusal loop intact rather than split into two.
#
# `sort -u` would do the job and reorder the confirmation listing while it was
# there; the listing should read back in the order the operator named things.
declare -a DEDUPED=()
dedupe() {
  local x y dup
  DEDUPED=()
  for x in ${@+"$@"}; do
    dup=0
    for y in ${DEDUPED[@]+"${DEDUPED[@]}"}; do
      [ "$x" = "$y" ] && { dup=1; break; }
    done
    [ "$dup" -eq 1 ] || DEDUPED+=("$x")
  done
}

# --- validate every target, before touching anything ----------------------
declare -a REFUSALS=()
for role in $ROLES; do BOXES+=("crew-drill-$role"); done

# `--box crew-drill-builder --role builder` names one box twice, and the
# duplicate is not merely noisy: it lists the box twice in the confirmation
# and calls `box rm --force` on it twice. The second call — against a box the
# first one just removed — will usually fail, turning a SUCCESSFUL teardown
# into `FAIL could not remove box crew-drill-builder`. That is the one message
# an operator has to be able to trust, so the duplicate dies here.
dedupe ${BOXES[@]+"${BOXES[@]}"}
BOXES=(${DEDUPED[@]+"${DEDUPED[@]}"})

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
# an explicit `--sandbox owner/repo`, whose survey would otherwise answer
# "absent" for a repository standing in plain sight. It is also what the owner
# half of the repo predicate is checked against, below.
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

dedupe ${REPOS[@]+"${REPOS[@]}"}
REPOS=(${DEDUPED[@]+"${DEDUPED[@]}"})

for repo in ${REPOS[@]+"${REPOS[@]}"}; do
  case "$repo" in
    */*/*|/*|*/) REFUSALS+=("sandbox '$repo' is not an <owner>/<repo> slug"); continue ;;
    */*) ;;
    *) REFUSALS+=("sandbox '$repo' is not an <owner>/<repo> slug"); continue ;;
  esac
  if ! is_drill_repo "${repo#*/}"; then
    REFUSALS+=("sandbox $repo is not a drill sandbox — teardown removes only: $(drill_repo_names | paste -sd' ' -)")
  # The box half has TWO gates — the exact drill name AND named by no roster —
  # and the repo half had one, on the `<repo>` component alone, so
  # `--sandbox someone-else/crew-drill-builder` validated and could be deleted.
  # A round's sandboxes are always `$REPO_OWNER/crew-drill-<role>` and the
  # owner is already resolved by the time this loop runs, so the second gate is
  # free: the owner must be this host's gh identity.
  #
  # When the owner is NOT known the gate cannot be evaluated, and does not need
  # to be — that path has already put the whole repository class on UNINSPECTED
  # and will exit 2 without deleting anything.
  #
  # A round created under a different identity than the one now logged in
  # therefore REFUSES rather than deletes, naming the identity it expected.
  # That is the right direction for a destructive command: refusing is
  # recoverable by logging in as that identity, deleting is not.
  elif [ -n "$REPO_OWNER" ] && [ "${repo%%/*}" != "$REPO_OWNER" ]; then
    REFUSALS+=("sandbox $repo is owned by '${repo%%/*}', not by this host's gh identity '$REPO_OWNER' — a round's sandboxes are always $REPO_OWNER/crew-drill-<role>")
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
  d="$(gh api "repos/$1" --jq '.created_at // "unknown"' 2>/dev/null | tr -d '\r\n' || true)"
  printf '%s\n' "${d:-unknown}"
}

# `gh repo view` cannot tell "no such repository" from "the API did not
# answer": it is GraphQL, and both come back as exit 1. Reading that non-zero
# as absence is how a live identity and a dead network together reported a
# clean host while every sandbox stood — the class-level gates above catch no
# gh, no login and an unanswerable `gh api user`, and caught nothing at all
# once the identity resolved and the per-repository lookup was the thing that
# failed.
#
# The REST endpoint CAN tell them apart, so the probe answers three ways and
# only ONE of them is absence:
#
#   0  it exists
#   1  measured absent — HTTP 404, and nothing else reaches this
#   2  could not tell — gh's own reason on stdout, for UNINSPECTED
#
# Worth writing down rather than papering over: GitHub answers 404 for a
# PRIVATE repository the token cannot see, so a measured absence is really
# "absent to this identity". That is the API's shape and not this script's,
# and it is still the safe direction — a repository this identity cannot see
# is not one this identity can delete either.
repo_probe() {
  local err rc=0
  err="$(gh api "repos/$1" --jq .full_name 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  case "$err" in
    *"HTTP 404"*|*"Not Found"*) return 1 ;;
  esac
  err="${err:-gh api repos/$1 exited $rc and said nothing}"
  # One line, bounded: this reason is printed inside a NOT inspected list, and
  # gh answers some failures with a whole JSON body.
  err="${err//$'\n'/ }"
  err="${err//$'\r'/ }"
  printf '%.200s\n' "$err"
  return 2
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
    # Per repository, not per class: the identity resolving says the API can be
    # asked, not that it answered. An unanswered lookup names ITS OWN
    # repository on the list, so the operator is told which one is unaccounted
    # for rather than that "something" was not inspected.
    probe_why=""
    probe_rc=0
    probe_why="$(repo_probe "$repo")" || probe_rc=$?
    case "$probe_rc" in
      0) DOOMED_REPOS+=("$repo") ;;
      1) ;;  # measured absent — the only non-zero that may mean "not there"
      *) UNINSPECTED+=("sandbox $repo — could not be looked up: $probe_why") ;;
    esac
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
