#!/usr/bin/env bash
# Contract tests for .github/stamps-only.py — the guard on the rc ladder.
#
# Two halves, and the second is the one that matters. The first runs the guard
# over this repository's own tree, which is the assertion the CI gate makes.
# The second drives whole LADDERS built here: a base tree, a candidate cut and
# tagged, the re-arm, and a final cut — once clean, and once with work smuggled
# in between the candidate and the final. A guard is only worth its green when
# its red has been seen, so every case asserts the exit status AND what the
# guard said: a refusal that does not name the stray path leaves the reader
# doing by hand the diff the guard just did (#506 D2).
#
# The three exit statuses are distinct on purpose and are tested as three
# outcomes, never as zero-versus-nonzero: 0 clean or vacuous, 1 refused, 2 could
# not look. Collapsing the last two is the failure this guard exists to refuse,
# because an unreachable anchor reads exactly like a clean one.
#
# Offline, no credentials, no network: `git init` in a temp directory is the
# whole apparatus.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$ROOT/.github/stamps-only.py"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# --- the apparatus ------------------------------------------------------------

# A fixture repository. Committing is what makes a tree the shipped tree, so
# every fixture below goes through real commits and real tags rather than
# handing the guard a list — the anchor it resolves is a tag object or nothing.
new_repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@e.st
  git -C "$dir" config user.name test
  git -C "$dir" config commit.gpgsign false
  printf '%s' "$dir"
}

w()  { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "${3-x}" >"$1/$2"; }
ci() { git -C "$1" add -A; git -C "$1" commit -q -m "$2"; }

# The tree a release window starts from: engine code, a fragment, furniture.
base() {
  local d; d="$(new_repo "$1")"
  w "$d" VERSION "${2:-0.9.0-dev}"
  w "$d" CHANGELOG.md "# Changelog"
  w "$d" changelog.d/1.md "- a thing (#1)."
  w "$d" drills/README.md "records"
  w "$d" shared/lib/duty.sh "#!/bin/sh"
  w "$d" README.md "prose"
  ci "$d" base
  printf '%s' "$d"
}

# A candidate cut, exactly as .ceremony/RELEASES.md describes it: the version
# goes bare, the record lands, CHANGELOG.md and every fragment stay untouched.
# Then the tag, which is the thing the final anchors to.
cut_rc() {  # $1 = dir, $2 = X.Y.Z, $3 = N
  w "$1" VERSION "$2-rc$3"
  w "$1" "drills/$2-rc$3.md" "# drill $2-rc$3"
  ci "$1" "cut $2-rc$3"
  git -C "$1" tag "$2-rc$3"
}

# The merge door's re-arm.
rearm() { w "$1" VERSION "$2-rc$3-dev"; ci "$1" "re-arm $2-rc$3-dev"; }

# The final ceremony: assemble, consume the fragments, record, stamp.
cut_final() {  # $1 = dir, $2 = X.Y.Z
  w "$1" VERSION "$2"
  w "$1" CHANGELOG.md "# Changelog

## $2

- a thing (#1)."
  rm -f "$1/changelog.d/1.md"
  w "$1" "drills/$2.md" "# drill $2"
  ci "$1" "release $2"
}

run_guard() { OUT="$(python3 "$GUARD" --root "$1" 2>&1)"; RC=$?; }

# Assert the last run's status; and, where the case turns on it, what it said.
#   t_rc   <expected-rc> <name>
#   t_says <expected-rc> <name> <case-pattern>   — the guard names it
#   t_mute <expected-rc> <name> <case-pattern>   — and does not name this
t_rc()   { if [ "$RC" -eq "$1" ]; then ok "$2"; else bad "$2 (rc=$RC, got '$OUT')"; fi; }
t_says() {
  # shellcheck disable=SC2254  # $3 is a case pattern, deliberately unquoted
  case "$OUT" in $3) t_rc "$1" "$2" ;; *) bad "$2 (rc=$RC, unsaid, got '$OUT')" ;; esac
}
t_mute() {
  # shellcheck disable=SC2254  # $3 is a case pattern, deliberately unquoted
  case "$OUT" in $3) bad "$2 (rc=$RC, said, got '$OUT')" ;; *) t_rc "$1" "$2" ;; esac
}

# --- the repository's own tree ------------------------------------------------
# The assertion the CI gate makes, made here too so a builder sees it locally.
run_guard "$ROOT"
t_rc 0 "the-repository-tree-is-accepted"

# --- the trees that carry no claim --------------------------------------------
# Each of these is a PASS, and each is a pass for a DIFFERENT reason. They are
# asserted by what the guard said and not only by its status, because a guard
# that has silently stopped classifying still exits 0 on all three.

D="$(base dev)"
run_guard "$D"
t_says 0 "a-dev-tree-asserts-nothing" '*not a release tree*'

D="$(base candidate 0.9.0-rc2)"
run_guard "$D"
t_says 0 "a-candidate-tree-carries-no-stamps-only-claim" '*carries no stamps-only claim*'

# The re-arm. `-rc2-dev` is a development tree and not a candidate, and the two
# read alike to any parse that is not anchored at the end.
D="$(base rearmed 0.9.0-rc2-dev)"
run_guard "$D"
t_says 0 "the-rearm-is-a-dev-tree-and-not-a-candidate" '*VERSION is 0.9.0-rc2-dev*not a release tree*'

# A final whose window cut no candidate. This is the ordinary un-laddered
# release and it must stay ordinary — the ladder is available, never required
# (#506 D5).
D="$(base plain)"
cut_final "$D" 0.9.0
run_guard "$D"
t_says 0 "a-final-with-no-candidate-has-nothing-to-compare" '*cut no candidate*'

# Spellings outside the declared convention are not candidates, which is
# .ceremony/RELEASES.md's rule and not this guard's invention: anchoring a final
# to a `-rc.1` tag would anchor it to a stamp `changelog-armed` never accepted.
D="$(base oddspelling)"
w "$D" drills/0.9.0-rc.1.md "# not a declared spelling"
ci "$D" "an odd record"
cut_final "$D" 0.9.0
run_guard "$D"
t_says 0 "an-undeclared-candidate-spelling-is-not-an-anchor" '*cut no candidate*'

# --- the ladder, followed -----------------------------------------------------

D="$(base clean)"
cut_rc "$D" 0.9.0 1
rearm  "$D" 0.9.0 2
cut_final "$D" 0.9.0
run_guard "$D"
t_says 0 "a-stamps-only-final-passes" '*0.9.0 over 0.9.0-rc1*'

# Green says what it measured. A count that can silently become zero is how a
# guard stops guarding without ever going red — the diff it read is named.
t_says 0 "green-reports-what-it-measured" '*paths changed, all stamps.*'

# Every one of the four stamps really is moved by that ceremony, so the pass
# above is not a pass over an empty diff.
for stamp in VERSION CHANGELOG.md changelog.d/1.md drills/0.9.0.md; do
  if git -C "$D" diff --name-only 0.9.0-rc1 HEAD | grep -qx "$stamp"; then
    ok "the-clean-ladder-really-moves-$stamp"
  else
    bad "the-clean-ladder-really-moves-$stamp (absent from the fixture diff)"
  fi
done

# --- the ladder, not followed -------------------------------------------------

D="$(base smuggled)"
cut_rc "$D" 0.9.0 1
rearm  "$D" 0.9.0 2
w "$D" shared/lib/duty.sh "#!/bin/sh
echo work landed after the drill"
w "$D" changelog.d/2.md "- another thing (#2)."
ci "$D" "work that landed after the candidate was drilled"
cut_final "$D" 0.9.0
run_guard "$D"
t_says 1 "an-executable-change-after-the-candidate-is-refused" '*non-stamp: shared/lib/duty.sh*'

# The refusal is a diff, so it names only what left the set. A refusal that
# listed the stamps too would bury its own finding in the ceremony's own noise.
t_mute 1 "the-refusal-does-not-name-the-stamps-it-allowed" '*non-stamp: VERSION*'
t_mute 1 "the-refusal-does-not-name-the-consumed-fragment" '*non-stamp: changelog.d/*'

# And it names both ways forward, with the next candidate's number computed
# rather than left for the reader.
t_says 1 "the-refusal-names-the-next-candidate" '*Cut 0.9.0-rc2 and drill it*'
t_says 1 "the-refusal-names-drilling-the-final-instead" '*drill 0.9.0 itself*drills/0.9.0.md*'

# Deliberately stricter than "no executable byte": a prose-only merge still
# means the shipped tree is not the drilled tree. Stated in drills/README.md as
# a choice, and tested here so it is a choice and not an accident.
D="$(base prose)"
cut_rc "$D" 0.9.0 1
w "$D" README.md "prose, revised after the drill"
ci "$D" "a documentation-only merge"
cut_final "$D" 0.9.0
run_guard "$D"
t_says 1 "a-documentation-only-merge-is-refused-too" '*non-stamp: README.md*'

# Paths that merely BEGIN like a stamp. This is the quietest mutation of the
# four — every real release still passes it, because no release has ever had a
# `VERSION.md` — so it is the one worth a case of its own.
D="$(base lookalike)"
cut_rc "$D" 0.9.0 1
w "$D" VERSION.md "notes about versions"
w "$D" changelog.d.old/1.md "an archived fragment"
ci "$D" "paths that begin like stamps"
cut_final "$D" 0.9.0
run_guard "$D"
t_says 1 "a-file-that-begins-like-a-stamp-file-is-not-one" '*non-stamp: VERSION.md*'
t_says 1 "a-directory-that-begins-like-a-stamp-directory-is-not-one" '*non-stamp: changelog.d.old/1.md*'

# A path renamed INTO the stamp set. With rename detection on, the diff reports
# only the destination — a stamp — and the guard would pass a tree that moved
# engine code out from under the drill. `--no-renames` is what keeps the source
# path visible, and this is the case that dies without it.
D="$(base renamed)"
cut_rc "$D" 0.9.0 1
git -C "$D" mv shared/lib/duty.sh drills/duty.sh
ci "$D" "a rename into the stamp set"
cut_final "$D" 0.9.0
run_guard "$D"
t_says 1 "a-rename-into-the-stamp-set-still-shows-its-source" '*non-stamp: shared/lib/duty.sh*'

# --- which candidate is the last one ------------------------------------------
# rc10 sorts BELOW rc9 as a string and above it as a number. The stray change
# sits between rc9 and rc10, so a lexical maximum anchors at rc9, sees it, and
# reds — this green is the assertion that the comparison is numeric.
D="$(base ordering)"
cut_rc "$D" 0.9.0 9
w "$D" shared/lib/duty.sh "#!/bin/sh
echo changed between the ninth and tenth candidates"
ci "$D" "work between rc9 and rc10"
cut_rc "$D" 0.9.0 10
rearm  "$D" 0.9.0 11
cut_final "$D" 0.9.0
run_guard "$D"
t_says 0 "the-last-candidate-is-the-highest-numbered-not-the-last-sorted" '*over 0.9.0-rc10*'

# --- the record deleted out from under its own tag ----------------------------
# The bypass this guard shipped with, and the reason discovery reads the tags
# too (#579). A record lives in `drills/`, so the stamp set ADMITS its deletion;
# delete it in the final commit and a records-only discovery finds no candidate,
# reports a window that laddered nothing, and exits 0 over the smuggled work.
# Both cases below returned 0 against the pre-fix guard.

D="$(base deleted)"
cut_rc "$D" 0.9.0 1
rearm  "$D" 0.9.0 2
w "$D" shared/lib/duty.sh "#!/bin/sh
echo work the deleted record would have hidden"
ci "$D" "work that landed after the candidate was drilled"
cut_final "$D" 0.9.0
git -C "$D" rm -q drills/0.9.0-rc1.md
ci "$D" "delete the candidate's record"
run_guard "$D"
t_says 1 "a-deleted-candidate-record-cannot-disarm-the-guard" '*0.9.0-rc1*no drills/0.9.0-rc1.md*'
t_mute 1 "a-deleted-record-is-never-reported-as-no-candidate" '*cut no candidate*'
t_says 1 "the-retention-refusal-names-both-ways-forward" '*Restore drills/0.9.0-rc1.md, or cut 0.9.0-rc2 and drill it*'

# And the meaner one: the deletion is the ONLY thing outside the ceremony. A
# stray path would have been refused by the diff check anyway, so a case that
# smuggles code cannot tell the two checks apart — this one can, because there
# is nothing here for the diff check to catch.
D="$(base deletedonly)"
cut_rc "$D" 0.9.0 1
rearm  "$D" 0.9.0 2
cut_final "$D" 0.9.0
git -C "$D" rm -q drills/0.9.0-rc1.md
ci "$D" "delete the candidate's record and nothing else"
run_guard "$D"
t_says 1 "the-deletion-alone-is-refused-with-no-stray-path-to-catch" '*no drills/0.9.0-rc1.md*'
t_mute 1 "the-retention-refusal-is-not-the-stray-path-refusal" '*non-stamp:*'

# A tag on a line the final does not descend from must NOT raise the anchor:
# it drilled a different lineage, and reading it would red a window it has
# nothing to say about. Here rc2 is tagged on an abandoned branch while the
# shipped ladder is rc1, and rc1 is what the final is measured against.
D="$(base unreachedtag)"
cut_rc "$D" 0.9.0 1
rearm  "$D" 0.9.0 2
git -C "$D" checkout -q -b abandoned
cut_rc "$D" 0.9.0 2
git -C "$D" checkout -q main
git -C "$D" rm -q drills/0.9.0-rc2.md 2>/dev/null || true
cut_final "$D" 0.9.0
run_guard "$D"
t_says 0 "an-unreachable-tag-does-not-raise-the-anchor" '*0.9.0 over 0.9.0-rc1*'

# --- could not look -----------------------------------------------------------
# The record says a candidate was drilled and its tag is unreachable. This is
# the case the whole design turns on: reading the tags alone would call it a
# window that cut no candidate and exit 0.

D="$(base untagged)"
cut_rc "$D" 0.9.0 1
git -C "$D" tag -d 0.9.0-rc1 >/dev/null
rearm  "$D" 0.9.0 2
w "$D" shared/lib/duty.sh "#!/bin/sh
echo this would be refused if the anchor could be read"
ci "$D" "work that a missing anchor would hide"
cut_final "$D" 0.9.0
run_guard "$D"
t_says 2 "a-record-whose-tag-is-unreachable-is-not-a-pass" '*0.9.0-rc1*cannot be resolved*'
t_says 2 "the-unreachable-anchor-names-the-record-that-claims-it" '*drills/0.9.0-rc1.md*'
t_mute 2 "an-unreachable-anchor-is-never-reported-as-no-candidate" '*cut no candidate*'

# A shallow clone is the way this arrives in CI — a checkout without
# fetch-depth: 0 has no tags — so it says so, and points at the fix.
D="$(base shallowsrc)"
cut_rc "$D" 0.9.0 1
rearm  "$D" 0.9.0 2
cut_final "$D" 0.9.0
if git clone -q --depth 1 --no-tags "file://$D" "$WORK/shallow" 2>/dev/null; then
  run_guard "$WORK/shallow"
  t_says 2 "a-shallow-clone-cannot-look-and-says-which-tag-it-wanted" '*0.9.0-rc1*cannot be resolved*'
  t_says 2 "a-shallow-clone-names-the-fetch-depth-fix" '*fetch-depth: 0*'
else
  bad "a-shallow-clone-cannot-look-and-says-which-tag-it-wanted (clone failed)"
  bad "a-shallow-clone-names-the-fetch-depth-fix (clone failed)"
fi

# The same clone with no record either. Nothing points at a candidate — but a
# tag that was never fetched reads exactly like a tag that was never cut, so
# this is a could-not-look and not the vacuous pass of an un-laddered release.
D="$(base shallowplain)"
cut_final "$D" 0.9.0
if git clone -q --depth 1 --no-tags "file://$D" "$WORK/shallowplain-clone" 2>/dev/null; then
  run_guard "$WORK/shallowplain-clone"
  t_says 2 "a-shallow-clone-with-no-record-cannot-look-either" '*clone is SHALLOW*'
  t_mute 2 "a-shallow-clone-is-never-reported-as-no-candidate" '*cut no candidate*'
else
  bad "a-shallow-clone-with-no-record-cannot-look-either (clone failed)"
  bad "a-shallow-clone-is-never-reported-as-no-candidate (clone failed)"
fi

# A BRANCH named like a candidate is not a tag. `rev-parse --verify 0.9.0-rc1`
# resolves it, so a bare anchor would diff against the branch and go quiet on
# the one thing worth being loud about — that the tags are not here.
D="$(base branchnottag)"
cut_rc "$D" 0.9.0 1
git -C "$D" branch 0.9.0-rc1-asbranch
git -C "$D" tag -d 0.9.0-rc1 >/dev/null
git -C "$D" branch -m 0.9.0-rc1-asbranch 0.9.0-rc1
rearm  "$D" 0.9.0 2
w "$D" shared/lib/duty.sh "#!/bin/sh
echo work a branch-shaped anchor would have compared away"
ci "$D" "work after the candidate"
cut_final "$D" 0.9.0
run_guard "$D"
t_says 2 "a-branch-named-like-the-candidate-is-not-its-tag" '*0.9.0-rc1*cannot be resolved*'

# --- the anchor is an ancestor, not a lookalike -------------------------------
# A candidate tagged on a branch the final does not descend from. The trees may
# even match; what was drilled is still not what ships.
D="$(base divergent)"
git -C "$D" checkout -q -b candidate
cut_rc "$D" 0.9.0 1
git -C "$D" checkout -q main
cut_final "$D" 0.9.0
git -C "$D" checkout -q candidate -- drills/0.9.0-rc1.md
ci "$D" "carry the candidate record onto main without its history"
run_guard "$D"
t_says 1 "a-final-that-does-not-descend-from-its-candidate-is-refused" '*not an ancestor of HEAD*'

# --- could not read at all ----------------------------------------------------
# Distinct from both: no answer is not a clean answer.
mkdir -p "$WORK/nogit"
run_guard "$WORK/nogit"
t_says 2 "a-tree-that-is-not-a-repository-is-a-could-not-look" '*not a git repository*'

D="$(new_repo empty)"
run_guard "$D"
t_says 2 "a-repository-with-no-HEAD-is-a-could-not-look" '*no HEAD*'

echo
echo "stamps-only: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
