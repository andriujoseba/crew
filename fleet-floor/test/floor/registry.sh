# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/registry.sh — the suite for floor/registry.py (#488).
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/jqf and a
# running collector on $PORT over $CREW_CONFIG_DIR. One suite per module at the
# mirrored path (#508 D2).
#
# Subject: the two watch registries as a layer the console can edit — the
# fleet-wide files, the per-box override, what refuses, and what is recorded.
#
# POSITION. This suite WRITES $CREW_CONFIG_DIR/repos.txt and creates
# repos.d/, so by run.sh's ordering rule it belongs after everything that
# READS the fleet definition. Nothing in floor/ reads repos.txt at all — the
# collector resolves the definition for fleet.roster and fleet.conf — but
# cli.sh drives `crew floor`'s completeness refusal over this same directory,
# so this suite restores every file it touched before it returns rather than
# relying on that distinction holding.
#
# THE `gh` STUB IS THE WHOLE REACHABILITY TIER, and it is installed here rather
# than in run.sh on purpose. The probe is the one thing in this module that
# leaves the host, and two suites later boxside.sh runs the real probe.sh,
# which asks the real `gh` about the box's own credential. A stub left on PATH
# would silently answer that too, so this one is created for these cases and
# removed at the end of the file. `reachable.txt` beside it names the
# repositories it is willing to find; everything else 404s exactly as `gh`
# does. The stub resolves that file from its OWN path rather than an
# environment variable, because the process that runs it is the collector —
# spawned by run.sh long before this file is sourced, so it carries run.sh's
# environment and nothing this suite exports afterwards.
echo
echo "== registries (#488)"

FF_REG_DIR="$CREW_CONFIG_DIR"
FF_REG_WORK="$FF_REG_DIR/repos.txt"
FF_REG_NOTIFY="$FF_REG_DIR/notify-repos.txt"
FF_REG_JOURNAL="$FF_REG_DIR/.registry-journal.log"
FF_REG_GH="$TMP/bin/gh"
FF_REG_REACHABLE="$TMP/bin/reachable.txt"
printf 'heavy-duty/crew\nheavy-duty/box\nheavy-duty/ceremony\nheavy-duty/rig\n' \
  >"$FF_REG_REACHABLE"
cat >"$FF_REG_GH" <<'GHSTUB'
#!/usr/bin/env bash
# The reachability probe's whole world, for fleet-floor/test/floor/registry.sh.
# `gh api repos/<owner>/<repo> -q .full_name` and nothing else; anything the
# fixture does not list answers the way the real CLI answers a repository the
# credential cannot see.
if [ "${1:-}" = api ] && [ "${2#repos/}" != "${2:-}" ]; then
  repo="${2#repos/}"
  if grep -qxF "$repo" "$(dirname "$0")/reachable.txt" 2>/dev/null; then
    printf '%s\n' "$repo"; exit 0
  fi
  echo "gh: Not Found (HTTP 404)" >&2; exit 1
fi
echo "gh stub: unexpected invocation: $*" >&2; exit 2
GHSTUB
chmod +x "$FF_REG_GH"

# The fleet-wide starting point. run.sh writes a one-line repos.txt with no
# comments in it; a comment and a blank line go in here because "the write is a
# line edit and every comment survives it" is a claim this suite has to be able
# to falsify.
cat >"$FF_REG_WORK" <<'EOF'
# repos.txt — the suite's own fleet definition.
heavy-duty/crew

# A comment BETWEEN two entries, which is the shape notify-repos.txt ships and
# the shape a header-then-entries writer destroys.
heavy-duty/box
EOF
printf '# notify extras\nheavy-duty/ceremony\n' >"$FF_REG_NOTIFY"
rm -f "$FF_REG_JOURNAL"

# reg BODY -> the /api/command reply for one registry action
reg() { body POST /api/command "$1"; }
# regf KIND -> the fleet-wide entries the collector serves, comma-joined
regf() { body GET /api/registries | jqf "','.join(d['fleet']['$1']['entries'])"; }
# regb BOX KIND FIELD -> one field of a box's resolved cell
regb() { body GET /api/registries | jqf "d['boxes']['$1']['$2']['$3']"; }
regbe() { body GET /api/registries | jqf "','.join(d['boxes']['$1']['$2']['entries'])"; }

# --- reading -----------------------------------------------------------------
t "registry: both registries are served" "work,notify" \
  "$(body GET /api/registries | jqf "','.join(sorted(d['fleet'].keys(),key=['work','notify'].index))")"
t "registry: the fleet-wide work list is read off disk" "heavy-duty/crew,heavy-duty/box" "$(regf work)"
t "registry: the fleet-wide notify list is read off disk" "heavy-duty/ceremony" "$(regf notify)"
t "registry: a box with no override inherits" fleet "$(regb ff-working work source)"
t "registry: ...and inheriting means the fleet-wide entries" \
  "heavy-duty/crew,heavy-duty/box" "$(regbe ff-working work)"

# A HAND EDIT, PICKED UP WITH NO RESTART (D4). The collector is the same
# process that answered the three assertions above; nothing is signalled to it
# and nothing is restarted. Must fail: a cached view.
printf '# hand-edited\nheavy-duty/crew\nheavy-duty/box\nheavy-duty/rig\n' >"$FF_REG_WORK"
t "registry: a hand edit to the file is picked up without a restart" \
  "heavy-duty/crew,heavy-duty/box,heavy-duty/rig" "$(regf work)"

# --- the fleet-wide write ----------------------------------------------------
FF_REG_OUT="$(reg '{"action":"registry-set","kind":"work","entries":["heavy-duty/crew","heavy-duty/ceremony"]}')"
t "registry: the fleet-wide list is editable from the floor" True \
  "$(printf '%s' "$FF_REG_OUT" | jqf "d['ok']")"
t "registry: ...and the collector serves the new list at once" \
  "heavy-duty/crew,heavy-duty/ceremony" "$(regf work)"
t "registry: ...and the removal is reported" "heavy-duty/box,heavy-duty/rig" \
  "$(printf '%s' "$FF_REG_OUT" | jqf "','.join(d['registry']['removed'])")"
# The claim the docstring makes about the writer, asserted against the file
# rather than the API: an operator's comment is still there afterwards.
t "registry: the write preserves the file's comments" 1 \
  "$(grep -c '^# hand-edited$' "$FF_REG_WORK")"
t "registry: ...and adds nothing else to the file" 2 \
  "$(grep -cvE '^[[:space:]]*(#|$)' "$FF_REG_WORK")"

# --- what refuses (D3) -------------------------------------------------------
FF_REG_BAD="$(reg '{"action":"registry-set","kind":"work","entries":["not a repo"]}')"
t "registry: a malformed entry is refused" False "$(printf '%s' "$FF_REG_BAD" | jqf "d['ok']")"
t "registry: ...as a refusal and not a failed box" True \
  "$(printf '%s' "$FF_REG_BAD" | jqf "d['refused']")"
case "$(printf '%s' "$FF_REG_BAD" | jqf "d['error']")" in
  *"is not a repository"*) r1=stated ;; *) r1=SILENT ;;
esac
t "registry: ...with a reason naming what is wrong" stated "$r1"
t "registry: ...and nothing lands in the file" "heavy-duty/crew,heavy-duty/ceremony" "$(regf work)"

FF_REG_GONE="$(reg '{"action":"registry-set","kind":"work","entries":["heavy-duty/crew","heavy-duty/nosuchrepo"]}')"
t "registry: an unreachable repository is refused" False \
  "$(printf '%s' "$FF_REG_GONE" | jqf "d['ok']")"
case "$(printf '%s' "$FF_REG_GONE" | jqf "d['error']")" in
  *"heavy-duty/nosuchrepo"*"cannot reach"*) r1=named ;; *) r1=VAGUE ;;
esac
t "registry: ...naming the entry and why" named "$r1"
t "registry: ...and the edit does not land" "heavy-duty/crew,heavy-duty/ceremony" "$(regf work)"
# AN ENTRY THAT HAS SINCE BECOME UNREACHABLE MUST STILL BE REMOVABLE — the
# removal IS the repair for it, so a probe that refused the whole edit would
# make the registry a trap: a repository renamed or moved to another fleet
# could never be taken out of the list naming it. Written in by hand, past the
# validator, exactly as the world writes it: the entry was fine when it landed.
printf '# hand-edited\nheavy-duty/crew\nheavy-duty/gone\n' >"$FF_REG_WORK"
t "registry: an entry already in the list is never re-probed" True \
  "$(reg '{"action":"registry-set","kind":"work","entries":["heavy-duty/crew"]}' | jqf "d['ok']")"
t "registry: ...so an unreachable entry can be taken out" "heavy-duty/crew" "$(regf work)"
reg '{"action":"registry-set","kind":"work","entries":["heavy-duty/crew","heavy-duty/ceremony"]}' >/dev/null
t "registry: an unknown registry name is refused" False \
  "$(reg '{"action":"registry-set","kind":"nope","entries":[]}' | jqf "d['ok']")"
t "registry: an override for a box off the roster is refused" False \
  "$(reg '{"action":"registry-override","box":"not-a-box","kind":"work","entries":[]}' | jqf "d['ok']")"

# --- the per-box override (D2) -----------------------------------------------
#
# CONTAINMENT FIRST, because it bounds everything below it: the operator's
# direction of 2026-08-29 makes a box's override a SELECTION from the
# fleet-wide registry, never a free list, so "a box can watch a board the fleet
# does not" is the shape that must not be reachable. The fleet-wide work list
# is `heavy-duty/crew,heavy-duty/ceremony` at this point and `heavy-duty/rig`
# is reachable — the `gh` stub lists it — so a refusal here can only be
# containment and never the probe.
FF_REG_OUT="$(reg '{"action":"registry-override","box":"ff-working","kind":"work","entries":["heavy-duty/rig"]}')"
t "registry: a box cannot select a repository the fleet does not watch" False \
  "$(printf '%s' "$FF_REG_OUT" | jqf "d['ok']")"
case "$(printf '%s' "$FF_REG_OUT" | jqf "d['error']")" in
  *"heavy-duty/rig"*"not in the fleet-wide registry"*) r1=named ;; *) r1=VAGUE ;;
esac
t "registry: ...naming the entry and the rule" named "$r1"
t "registry: ...and refusing rather than failing a box" True \
  "$(printf '%s' "$FF_REG_OUT" | jqf "d['refused']")"
t "registry: ...leaving the box inheriting" fleet "$(regb ff-working work source)"
t "registry: ...and writing no override file" 0 \
  "$(test -f "$FF_REG_DIR/repos.d/ff-working.txt" && echo 1 || echo 0)"

t "registry: a box selects from the fleet-wide list" True \
  "$(reg '{"action":"registry-override","box":"ff-working","kind":"work","entries":["heavy-duty/ceremony"]}' | jqf "d['ok']")"
t "registry: ...which wins over the fleet-wide list" "heavy-duty/ceremony" "$(regbe ff-working work)"
t "registry: ...and says so" override "$(regb ff-working work source)"
# Must fail: an override leaking to a sibling box.
t "registry: ...for that box only" "heavy-duty/crew,heavy-duty/ceremony" "$(regbe ff-idle work)"
t "registry: ...leaving the sibling inheriting" fleet "$(regb ff-idle work source)"
t "registry: ...and the other registry untouched" fleet "$(regb ff-working notify source)"
t "registry: the override is a file in the fleet definition" 1 \
  "$(test -f "$FF_REG_DIR/repos.d/ff-working.txt" && echo 1 || echo 0)"

# CONTAINMENT IS A READ-TIME INVARIANT, NOT A WRITE-TIME CHECK, and this is the
# case that tells the two apart. `heavy-duty/ceremony` was legal when the box
# selected it a few lines up; retiring it fleet-wide must take it off the box
# too. A build that only validated at the edit passes everything above this
# line and fails here, having left a droid working a board the fleet no longer
# knows about — which is exactly the divergence the direction forbids, on a
# delay. Must fail: the selection outliving its universe.
reg '{"action":"registry-set","kind":"work","entries":["heavy-duty/crew"]}' >/dev/null
t "registry: retiring a repository fleet-wide takes it off the boxes that selected it" \
  "" "$(regbe ff-working work)"
t "registry: ...without rewriting the box's own selection" "heavy-duty/ceremony" \
  "$(grep -vE '^[[:space:]]*(#|$)' "$FF_REG_DIR/repos.d/ff-working.txt" | paste -sd, -)"
t "registry: ...so restoring it fleet-wide restores it on the box" "heavy-duty/ceremony" \
  "$(reg '{"action":"registry-set","kind":"work","entries":["heavy-duty/crew","heavy-duty/ceremony"]}' >/dev/null; regbe ff-working work)"

# The resolved order is the fleet-wide file's, not the order a click submitted.
# The console and the operator's own `cat` then read alike, and a selection
# saved in any order lands the same way twice.
reg '{"action":"registry-override","box":"ff-working","kind":"work","entries":["heavy-duty/ceremony","heavy-duty/crew"]}' >/dev/null
t "registry: a selection resolves in fleet-wide order" "heavy-duty/crew,heavy-duty/ceremony" \
  "$(regbe ff-working work)"

# CLEAR IS NOT SET-IDENTICAL, which is the distinction the whole layer rests
# on. Both leave ff-working reading the same two repositories today; only one
# of them follows the fleet-wide list when it changes tomorrow.
reg '{"action":"registry-override","box":"ff-working","kind":"work","entries":["heavy-duty/crew","heavy-duty/ceremony"]}' >/dev/null
t "registry: setting the fleet-wide list as an override reads identically" \
  "heavy-duty/crew,heavy-duty/ceremony" "$(regbe ff-working work)"
t "registry: ...but is still an override, not inheritance" override "$(regb ff-working work source)"
reg '{"action":"registry-set","kind":"work","entries":["heavy-duty/crew","heavy-duty/ceremony","heavy-duty/box"]}' >/dev/null
t "registry: ...and a later widening does not reach the pinned box" \
  "heavy-duty/crew,heavy-duty/ceremony" "$(regbe ff-working work)"
t "registry: ...while the inheriting sibling follows it" \
  "heavy-duty/crew,heavy-duty/ceremony,heavy-duty/box" "$(regbe ff-idle work)"

FF_REG_CLR="$(reg '{"action":"registry-inherit","box":"ff-working","kind":"work"}')"
t "registry: clearing reports that it removed something" True \
  "$(printf '%s' "$FF_REG_CLR" | jqf "d['registry']['cleared']")"
t "registry: ...and the box inherits again" fleet "$(regb ff-working work source)"
t "registry: ...including the widening it had been pinned against" \
  "heavy-duty/crew,heavy-duty/ceremony,heavy-duty/box" "$(regbe ff-working work)"
t "registry: ...and the override file is gone" 0 \
  "$(test -f "$FF_REG_DIR/repos.d/ff-working.txt" && echo 1 || echo 0)"
t "registry: clearing an override that is not there is not an error" True \
  "$(reg '{"action":"registry-inherit","box":"ff-working","kind":"work"}' | jqf "d['ok']")"
t "registry: ...and says it removed nothing" False \
  "$(reg '{"action":"registry-inherit","box":"ff-working","kind":"work"}' | jqf "d['registry']['cleared']")"

# An EMPTY override is a box narrowed to no board at all, not an absent one.
reg '{"action":"registry-override","box":"ff-idle","kind":"notify","entries":[]}' >/dev/null
t "registry: an empty override is a narrowing, not an absence" override \
  "$(regb ff-idle notify source)"
t "registry: ...and the box watches nothing" "" "$(regbe ff-idle notify)"
reg '{"action":"registry-inherit","box":"ff-idle","kind":"notify"}' >/dev/null

# A FLEET-WIDE LIST WITH NOTHING IN IT refuses a selection as itself, rather
# than as a containment failure per entry: there is no universe to select from,
# and the operator's next move is a fleet-wide edit and not a narrower box.
# Driven on `notify` so the work registry's own sequence above is untouched,
# and restored immediately.
reg '{"action":"registry-set","kind":"notify","entries":[]}' >/dev/null
FF_REG_OUT="$(reg '{"action":"registry-override","box":"ff-working","kind":"notify","entries":["heavy-duty/ceremony"]}')"
t "registry: selecting from an empty fleet-wide list is refused" False \
  "$(printf '%s' "$FF_REG_OUT" | jqf "d['ok']")"
case "$(printf '%s' "$FF_REG_OUT" | jqf "d['error']")" in
  *"names no repositories"*"fleet-wide list first"*) r1=stated ;; *) r1=VAGUE ;;
esac
t "registry: ...saying so as itself, not per entry" stated "$r1"
# Selecting NOTHING from nothing is still legal — it is the box narrowed to no
# board, which the empty-override case below is about, and refusing it would
# make an already-empty fleet a state no box could be pointed at.
t "registry: ...while selecting nothing from it is still allowed" True \
  "$(reg '{"action":"registry-override","box":"ff-working","kind":"notify","entries":[]}' | jqf "d['ok']")"
reg '{"action":"registry-inherit","box":"ff-working","kind":"notify"}' >/dev/null
reg '{"action":"registry-set","kind":"notify","entries":["heavy-duty/ceremony"]}' >/dev/null

# --- the record (D5) ---------------------------------------------------------
t "registry: every write is journalled" 1 \
  "$(test -f "$FF_REG_JOURNAL" && echo 1 || echo 0)"
# Every line, not the last one: an unattributed write is the failure D5 names,
# so one line missing an actor is as bad as none of them carrying it.
t "registry: ...naming the operator who made it" 0 \
  "$(grep -cv "actor=$USER" "$FF_REG_JOURNAL")"
case "$(cat "$FF_REG_JOURNAL")" in
  *"set-override:work file=repos.d/ff-working.txt box=ff-working"*) r1=named ;;
  *) r1=MISSING ;;
esac
t "registry: ...and the file and box it changed" named "$r1"
# Recorded APART from the set, which is the journal's half of the distinction
# the layer rests on: reading back "this box was set to the fleet-wide list"
# where it was actually cleared loses which of the two happened.
case "$(cat "$FF_REG_JOURNAL")" in
  *"clear-override:work file=repos.d/ff-working.txt"*) r1=named ;; *) r1=MISSING ;;
esac
t "registry: ...with the clear recorded apart from the set" named "$r1"
t "registry: a refused write is not journalled" 0 \
  "$(grep -c 'nosuchrepo' "$FF_REG_JOURNAL")"

# --- the transport half: cli/crew resolves the same override -----------------
#
# The console's write is inert unless the transport picks it up, and that is
# the CLI's `registry_seed`. Driven here rather than in the CLI suite because
# the override this reads was written a few lines up by the collector — the
# two halves of D2 asserted against one artifact instead of two fixtures that
# have to be kept in step by hand.
reg '{"action":"registry-override","box":"ff-working","kind":"work","entries":["heavy-duty/ceremony"]}' >/dev/null
# The functions are EXTRACTED rather than the file sourced: cli/crew ends in a
# dispatch, so sourcing it runs a command. That is the idiom shared/test uses
# on cmd_floor for the same reason, and it keeps the assertion pointed at the
# shipped resolver instead of a copy of it. The whole family comes across
# together because they call each other; each extracts on the same
# `/^name() {/,/^}/` range, which is why none of them is folded onto one line.
FF_REG_FNS="registry_entries registry_fleet_file registry_override_file"
FF_REG_FNS="$FF_REG_FNS resolved_registry registry_seed registry_seed_discard"
ff_reg_cli() { # SNIPPET ARGS... — run SNIPPET with the CLI's resolvers in scope
  local snippet="$1"; shift
  CONFIG_DIR="$FF_REG_DIR" REPOS_SEED="$FF_REG_WORK" \
  NOTIFY_REPOS_SEED="$FF_REG_NOTIFY" FF_REG_CLI="$FLOOR/../cli/crew" \
  FF_REG_FNS="$FF_REG_FNS" \
  bash -c '
    die() { echo "$*" >&2; exit 1; }
    for fn in $FF_REG_FNS; do
      eval "$(sed -n "/^$fn() {/,/^}/p" "$FF_REG_CLI")"
    done
    eval "$1"
  ' _ "$snippet" "$@"
}
# Single quotes throughout the snippets below, and SC2016 is silenced rather
# than satisfied: NOT expanding here is the point. The snippet is a program for
# the inner `bash -c` to run against the extracted resolvers, so `$2` and `$3`
# must reach it as themselves and be its positional parameters, not this
# shell's.
# shellcheck disable=SC2016
ff_reg_seed() { ff_reg_cli 'registry_seed "$2" "$3"' "$1" "$2"; }
# What the guest would actually receive: the staged file's entries, and the
# temporary one discarded exactly as stage_fleet_definition discards it.
# shellcheck disable=SC2016
ff_reg_staged() { # BOX KIND
  ff_reg_cli '
    seed="$(registry_seed "$2" "$3")"
    registry_entries "$seed" | paste -sd, -
    registry_seed_discard "$3" "$seed"
  ' "$1" "$2"
}
# THE TRANSPORT RESOLVES THE SAME INTERSECTION THE CONSOLE RENDERS. Two halves
# reading one override two ways is the failure nobody sees until a tick: the
# floor would report a narrowing the box does not have, or the reverse.
t "registry: the transport stages the box's selection" "heavy-duty/ceremony" \
  "$(ff_reg_staged ff-working work)"
t "registry: ...which is what the console renders for it" "$(regbe ff-working work)" \
  "$(ff_reg_staged ff-working work)"
t "registry: ...and the whole fleet-wide list for a box without one" \
  "$(regbe ff-idle work)" "$(ff_reg_staged ff-idle work)"
t "registry: ...per registry, not per box" "heavy-duty/ceremony" \
  "$(ff_reg_staged ff-working notify)"
# An inheriting box is staged the fleet-wide FILE ITSELF, not a copy of its
# entries: `repos.txt` ships 60 lines of doctrine an operator is meant to read
# on the box, and a resolver that always regenerated would drop every one of
# them on every box that never had a selection — the common case.
t "registry: an inheriting box is staged the fleet-wide file itself" "$FF_REG_WORK" \
  "$(ff_reg_seed ff-idle work)"
t "registry: ...while a selected box is staged a generated one" not-the-fleet-file \
  "$(test "$(ff_reg_seed ff-working work)" = "$FF_REG_WORK" && echo THE-FLEET-FILE || echo not-the-fleet-file)"
# Must fail: the generated seed left behind. stage_fleet_definition pairs every
# registry_seed with a discard, and a leak there is one temp file per box per
# upgrade, forever.
FF_REG_SEEDPATH="$(ff_reg_seed ff-working work)"
# shellcheck disable=SC2016
ff_reg_cli 'registry_seed_discard "$2" "$3"' work "$FF_REG_SEEDPATH"
t "registry: ...which is discarded after staging" 0 \
  "$(test -e "$FF_REG_SEEDPATH" && echo 1 || echo 0)"
# shellcheck disable=SC2016
t "registry: ...and discarding never removes the fleet-wide file" 1 \
  "$(ff_reg_cli 'registry_seed_discard "$2" "$3"' work "$FF_REG_WORK" >/dev/null 2>&1; \
     test -f "$FF_REG_WORK" && echo 1 || echo 0)"
# The transport's own containment: a selection naming a repository that has
# since left the fleet-wide list must not reach the guest. Written past the
# validator by hand, because the collector will not write it.
printf 'heavy-duty/ceremony\nheavy-duty/rig\n' >"$FF_REG_DIR/repos.d/ff-working.txt"
t "registry: a stale selection cannot smuggle a repository onto a box" \
  "heavy-duty/ceremony" "$(ff_reg_staged ff-working work)"
t "registry: ...and the console agrees with it" "$(regbe ff-working work)" \
  "$(ff_reg_staged ff-working work)"
reg '{"action":"registry-inherit","box":"ff-working","kind":"work"}' >/dev/null

# --- leave the definition as this suite found it -----------------------------
rm -f "$FF_REG_GH" "$FF_REG_REACHABLE" "$FF_REG_JOURNAL"
rm -rf "$FF_REG_DIR/repos.d" "$FF_REG_DIR/notify-repos.d"
printf 'heavy-duty/crew\n' >"$FF_REG_WORK"
rm -f "$FF_REG_NOTIFY"
