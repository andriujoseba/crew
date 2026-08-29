#!/usr/bin/env python3
"""A final release tree differs from its last candidate by stamps only (#506).

The rc ladder (`drills/README.md`, `.ceremony/RELEASES.md`) exists to make one
claim: drill the candidate, publish it as a tag, and the final that ships is
the tree that was drilled — they "differ by no executable byte". Everything
else the ladder buys follows from that sentence being TRUE, and nothing in the
release doors checks it. A window that quietly merges work between `X.Y.Z-rc2`
and `X.Y.Z` still publishes, still carries `drills/X.Y.Z-rc2.md`, and still
reads as evidenced — the record just describes a tree nobody ran.

So the sentence is checked. At a final release tree, the diff from the last
candidate's tag to HEAD must touch STAMPS only: the four paths a ceremony PR is
allowed to move. Anything else means the ladder was not followed, and the ways
forward are the ordinary two: cut the next candidate at the tree that actually
ships and drill THAT, so the final rides a candidate it does not differ from;
or take the non-stamp change back out of this release window.

WHAT DOES NOT CLEAR IT IS DRILLING THE FINAL ITSELF, and this module said
otherwise for a while (crew#579, codex-bot-andresmgsl). The candidate below is
already published and already in this final's history, so writing a fresh
`drills/X.Y.Z.md` adds a stamp and removes nothing — the anchor stands and the
stray path is still in the diff. Drilling the final alone is what an UN-LADDERED
window does, and there this guard is vacuous because no candidate sits above it
to be compared against. That is a different shape of window, not a remedy for
this one, and a guard that reds and then names an action which cannot clear it
sends its reader in a circle.

STRICTER THAN THE SENTENCE, DELIBERATELY. "No executable byte" would admit a
documentation-only merge; the stamp set refuses it. The costs are asymmetric in
the way `scope-coverage.py` describes for its own dialect: a false red costs one
author a re-read and is answered by cutting the next candidate, while a false
green ships a final whose evidence describes a different tree. A guard looser
than its claim is the claim wearing a green check.

TWO SOURCES NAME THE LAST CANDIDATE, AND NEITHER IS TRUSTED ALONE. Which
candidate was last is the highest-numbered of the `drills/X.Y.Z-rcN.md` records
in the shipped tree UNION the `X.Y.Z-rcN` tags reachable from HEAD, and each
source covers the way the other fails open:

  - The records alone were the first design, and they are DELETABLE by the very
    diff under examination. A record lives in `drills/`, which is a stamp path,
    so removing it in the final commit is admitted by the stamp set — and it
    lowers the anchor. Delete the only record and the guard reports a window
    that cut no candidate and exits 0 over a diff full of engine code. The
    evidence was its own bypass (crew#579, codex-bot-andresmgsl).
  - The tags alone fail the other way, which is why the first design chose the
    records: a tag that was never fetched is indistinguishable from a tag that
    was never cut, so a shallow clone would read as a window that laddered
    nothing. That is a silent pass, the one answer this guard must never give.

So a record whose tag cannot be found is a REFUSAL — "I found nothing" and "I
could not look" are different answers, the distinction `drill/teardown.sh`
already keeps in its exit table. And a reachable published candidate whose
record is NOT in the shipped tree is a refusal too: `drill-recorded` is what
makes a record exist, so a tag in this final's own history with no record
beneath it means the evidence was removed after it published. RETENTION IS
PROVED RATHER THAN ASSUMED.

That check reads EVERY reachable candidate and not only the anchor. A ladder is
`rc1 → rc2 → … → X.Y.Z`, so a window with several rungs is the ordinary case,
and each rung's record is the only description of the tree that rung ran.
Deleting a NON-maximal record cannot move the anchor, so it is not a stamps-only
bypass — what it destroys is the evidence, which is the thing the ladder exists
to keep (crew#579, claude-bot-andresmgsl). The only action that answers this
refusal is restoring the record, and the refusal says so rather than offering a
next cut that would leave the same tag recordless.

THE NUMBER ORDERS THE LADDER AND NEVER NAMES IT. `version_is_rc` at the pin is
`^X.Y.Z-rc[0-9]+$`, which accepts a ZERO-PADDED number, and `version_next_dev`
re-arms `0.9.0-rc01` as `0.9.0-rc2-dev` through an explicit base-10 read. So
`0.9.0-rc01` is a candidate the release doors publish, and parsing the suffix to
an integer and then REBUILDING the name from it would send this guard looking
for a `0.9.0-rc1` tag nobody ever cut — a could-not-look raised against a
perfectly good ladder (crew#579, codex-bot-andresmgsl). The integer is an
ordering key and nothing else; every ref resolved and every path named is the
spelling that is actually on disk. Where one number is spelled two ways in one
ladder, the guard says so and stops, because an arbitrary anchor is a
measurement against a tree nobody declared.

REACHABILITY IS THE FILTER ON TAGS, deliberately. A candidate tagged on a line
this final does not descend from never drilled this lineage, and anchoring to
it would red a window it has nothing to say about — while a candidate the final
DOES descend from is exactly the one whose record cannot be allowed to vanish.
An `X.Y.Z-rcN` tag that is an ancestor but whose tree diverges is caught by the
ancestry check below, not by discovery.

EVERYTHING ELSE IS READ FROM HEAD — the version, the records, the diff. What
ships is what is committed, and one source of truth is why a worktree edit
cannot move this guard's answer while leaving the published tree alone. The
tags are the one thing HEAD cannot carry, which is the whole reason they are
read separately and never trusted on their own.

Run it from anywhere:  .github/stamps-only.py [--root DIR]

  exit 0  the tree is a stamps-only final, or there is nothing to assert
  exit 1  refused — the diff leaves the stamp set, the anchor is not an
          ancestor of what ships, or a reachable candidate's record is not in
          the shipped tree
  exit 2  could not look — a record's tag is unreachable, one candidate number
          is spelled two ways, the tags cannot be read at all, or git could not
          answer

Stdlib only, for `scope-coverage.py`'s reason: a check that needs installing is
a check that gets skipped.
"""

import argparse
import os
import re
import subprocess
import sys

VERSION_FILE = "VERSION"
DRILLS = "drills"

# A final release version: bare `X.Y.Z`, exactly what the release doors tag and
# what `drill-recorded` treats as a release ceremony tree.
FINAL = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
# The declared candidate spelling, and only it. `.ceremony/RELEASES.md` rules
# that `-rc.1`, `-RC1` and `-beta1` are not rc stamps; a guard that read them as
# candidates would anchor a final to a tag `changelog-armed` never accepted.
RC_SUFFIX = re.compile(r"^-rc(\d+)$")

# The four paths a ceremony PR moves. Directories are matched by prefix, files
# exactly — `VERSION` is the file and never `VERSION.md`, for the reason
# `scope-coverage.py` refuses a prefix match: the loosest mutation is also the
# quietest, and every real release would still pass it.
STAMP_FILES = ("VERSION", "CHANGELOG.md")
STAMP_DIRS = ("changelog.d/", "drills/")


def die(msg):
    """Could not look. Never conflated with a clean answer."""
    print("stamps-only: ERROR: %s" % msg, file=sys.stderr)
    raise SystemExit(2)


def refuse(msg):
    print("stamps-only: REFUSED: %s" % msg, file=sys.stderr)


def git(root, args, what):
    proc = subprocess.run(
        ["git", "-C", root] + args,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        die("%s: git %s failed in %s: %s"
            % (what, " ".join(args), os.path.abspath(root),
               proc.stderr.decode("utf-8", "replace").strip()))
    return proc.stdout.decode("utf-8", "replace")


def git_ok(root, args):
    """A git question whose NO is an answer rather than a failure."""
    proc = subprocess.run(
        ["git", "-C", root] + args,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return proc.returncode == 0


def is_stamp(path):
    return path in STAMP_FILES or path.startswith(STAMP_DIRS)


def parse_version(raw):
    """(kind, final, n) — kind is 'final', 'rc' or 'other'.

    `0.9.0-rc2-dev` is 'other' by construction: the `-dev` re-arm is a
    development tree, and the RC_SUFFIX match is anchored so the trailing
    `-dev` cannot be read past.
    """
    if FINAL.match(raw):
        return "final", raw, None
    base, sep, rest = raw.partition("-")
    if sep and FINAL.match(base):
        rc = RC_SUFFIX.match("-" + rest)
        if rc:
            return "rc", base, int(rc.group(1))
    return "other", None, None


def read_version(root):
    raw = git(root, ["show", "HEAD:%s" % VERSION_FILE],
              "reading the version that ships").strip()
    if not raw:
        die("HEAD:%s is empty — there is no version to classify" % VERSION_FILE)
    return raw


def record_path(spelling):
    """The record a candidate of this spelling is carried in."""
    return "%s/%s.md" % (DRILLS, spelling)


def rc_records(root, final):
    """{n: '<final>-rcN'} — the SPELLING each record is carried under.

    The number is returned as a key so the ladder can be ordered by it, and the
    spelling is returned as the value because the spelling is what names a path.
    `drills/0.9.0-rc01.md` is a record of candidate 1 whose path is not
    `drills/0.9.0-rc1.md`, and rebuilding the path from the number would name a
    file that is not there.
    """
    listing = git(root, ["ls-tree", "-r", "--name-only", "-z", "HEAD", "--", DRILLS],
                  "reading the drill records")
    want = re.compile(r"^%s/(%s-rc(\d+))\.md$" % (re.escape(DRILLS), re.escape(final)))
    found = {}
    for path in listing.split("\0"):
        m = want.match(path)
        if not m:
            continue
        n = int(m.group(2))
        if n in found and found[n] != m.group(1):
            die("the shipped tree carries two records for candidate %d — %s and "
                "%s. They are one rung of the ladder by number and two different "
                "trees on disk, so which one this final must be measured against "
                "cannot be answered from here. Keep the record of the candidate "
                "that actually published and remove the other."
                % (n, record_path(min(found[n], m.group(1))),
                   record_path(max(found[n], m.group(1)))))
        found[n] = m.group(1)
    return found


def rc_tags(root, final):
    """{n: ['<final>-rcN', ...]} — every PUBLISHED spelling of each candidate.

    A list and not a single name: `0.9.0-rc1` and `0.9.0-rc01` are one number
    and two refs, and which of them is an ancestor is the question that decides
    whether the collision matters at all.

    The `--list` glob is a first pass and the anchored pattern is the real
    filter: `-rc.1` and `-rc1-dev` both match the glob and neither is a
    candidate `.ceremony/RELEASES.md` would publish.
    """
    listing = git(root, ["tag", "--list", "%s-rc*" % final],
                  "reading the candidate tags")
    want = re.compile(r"^%s-rc(\d+)$" % re.escape(final))
    found = {}
    for name in listing.split("\n"):
        name = name.strip()
        m = want.match(name)
        if m:
            found.setdefault(int(m.group(1)), []).append(name)
    return found


def reachable_tags(root, tags):
    """{n: '<the one reachable spelling>'} — the tags that raise the anchor.

    Reachability is applied BEFORE the collision check on purpose. A stray
    `0.9.0-rc01` on an abandoned branch has no say over a `0.9.0-rc1` this final
    descends from, for the same reason an unreachable tag never raises the
    anchor: it drilled a different lineage. Two spellings BOTH in this final's
    history is the case that cannot be resolved, and it stops the guard.
    """
    live = {}
    for n in sorted(tags):
        here = sorted(name for name in tags[n]
                      if is_ancestor(root, "refs/tags/%s" % name))
        if not here:
            continue
        if len(here) > 1:
            die("candidate %d is published under %d spellings that are ALL in "
                "this final's history — %s. One rung of the ladder drilled one "
                "tree, and there is no way to tell from here which of these "
                "tags is it, so the measurement would be against a tree nobody "
                "declared. Delete the tag that was not drilled."
                % (n, len(here), ", ".join(here)))
        live[n] = here[0]
    return live


def is_ancestor(root, ref):
    return git_ok(root, ["merge-base", "--is-ancestor", ref, "HEAD"])


def is_shallow(root):
    return git(root, ["rev-parse", "--is-shallow-repository"],
               "asking whether the clone is shallow").strip() == "true"


def changed_paths(root, anchor):
    """Every path that differs between the anchor's tree and HEAD.

    `--no-renames` on purpose: with rename detection a moved file reports only
    its new name, so a non-stamp path renamed INTO the stamp set would vanish
    from this list entirely. Both sides are wanted, and a rename out of the
    stamp set is exactly the change that must be seen.
    """
    out = git(root, ["diff", "--name-only", "--no-renames", "-z", anchor, "HEAD"],
              "diffing the final against its candidate")
    return [p for p in out.split("\0") if p]


def main():
    ap = argparse.ArgumentParser(
        description="a final release tree differs from its last candidate by stamps only")
    ap.add_argument("--root", default=".", help="repository root (default: .)")
    args = ap.parse_args()
    root = args.root

    if not git_ok(root, ["rev-parse", "--git-dir"]):
        die("%s is not a git repository — the anchor is a tag, so there is "
            "nothing to read it from" % os.path.abspath(root))
    if not git_ok(root, ["rev-parse", "--verify", "HEAD"]):
        die("%s has no HEAD — there is no shipped tree to check"
            % os.path.abspath(root))

    raw = read_version(root)
    kind, final, n = parse_version(raw)
    if kind == "other":
        print("stamps-only: VERSION is %s — not a release tree, nothing to assert." % raw)
        return 0
    if kind == "rc":
        # A candidate exists BECAUSE something changed since the last one. There
        # is no stamps-only claim to make about it, and making one would forbid
        # the very cut the ladder asks for.
        print("stamps-only: VERSION is %s — a candidate carries no stamps-only "
              "claim, only its own record." % raw)
        return 0

    records = rc_records(root, final)
    tags = rc_tags(root, final)
    # Only the reachable tags raise the anchor. An unreachable one is not this
    # final's ladder; an unreachable one that a RECORD claims is a refusal, and
    # that is decided below rather than here.
    reachable = reachable_tags(root, tags)
    candidates = set(records) | set(reachable)
    if not candidates:
        if is_shallow(root):
            die("%s carries no drills/%s-rcN.md and the clone is SHALLOW, so "
                "whether this window cut a candidate cannot be answered from "
                "here — a tag that was never fetched reads exactly like a tag "
                "that was never cut. Fetch the tags (actions/checkout with "
                "fetch-depth: 0)." % (final, final))
        print("stamps-only: %s cut no candidate — no drills/%s-rcN.md in the "
              "shipped tree and no reachable %s-rcN tag, so there is nothing "
              "above it to compare against." % (final, final, final))
        return 0

    last = max(candidates)

    # The anchor's spelling, taken from the tree rather than rebuilt from the
    # number. Prefer the tag's own spelling where a tag exists: an UNREACHABLE
    # tag still names the anchor, and it is refused by the ancestry check below
    # as the wrong lineage rather than as a tag that could not be read.
    anchor = reachable.get(last) or (sorted(tags[last])[0] if last in tags
                                     else records[last])

    # EVERY reachable candidate, not only the anchor. A rung below the anchor
    # cannot move it, so this is not a stamps-only bypass — the deletion is
    # inside `drills/`, the stamp set admits it, and what leaves with it is the
    # only description of the tree that rung ran.
    missing = sorted(n for n in reachable if n not in records)
    if missing:
        for n in missing:
            tag = reachable[n]
            refuse("%s is published and is an ancestor of HEAD, but the shipped "
                   "tree carries no %s. A candidate's record is the evidence "
                   "that it was drilled, and removing it after the tag "
                   "published does not un-publish the candidate — it only hides "
                   "which tree that rung of the ladder ran."
                   % (tag, record_path(tag)))
        # The only action that clears this is the record coming back, and it is
        # recoverable exactly: it is in the candidate's own tree. Cutting the
        # next candidate is NOT an alternative — it leaves this tag reachable
        # and still recordless, so naming it here would be advice that cannot
        # turn the guard green (crew#579, codex-bot-andresmgsl).
        for n in missing:
            print("stamps-only: restore it from the tag that carries it — "
                  "git checkout %s -- %s"
                  % (reachable[n], record_path(reachable[n])), file=sys.stderr)
        if last in records:
            # A rung BELOW the anchor lost its record. Say so, or this refusal
            # reads as a lost anchor and sends its reader looking for a
            # measurement that was never in doubt.
            print("stamps-only: the anchor is unchanged — %s is still what this "
                  "final would be measured against. A rung below the anchor "
                  "cannot move it; what is gone is the evidence of the tree "
                  "that rung ran." % anchor, file=sys.stderr)
        return 1

    if last not in tags or not git_ok(
            root, ["rev-parse", "--verify", "refs/tags/%s^{commit}" % anchor]):
        die("the shipped tree carries %s, so %s is this final's anchor — and "
            "that tag cannot be resolved%s. This is not a pass: an unreachable "
            "anchor is the one case where a missing check reads exactly like a "
            "clean one. Fetch the tags (actions/checkout with fetch-depth: 0), "
            "or say in %s/%s.md why a record exists for a candidate that never "
            "published."
            % (record_path(records[last]), anchor,
               " (the clone is shallow)" if is_shallow(root) else "",
               DRILLS, final))

    # `refs/tags/` and not the bare name: `rev-parse` resolves a BRANCH of that
    # name too, so a bare anchor would quietly diff against a branch and mask
    # the one signal this guard most wants to be loud about — fetch the tags.
    anchor_ref = "refs/tags/%s" % anchor

    if not is_ancestor(root, anchor_ref):
        refuse("%s is not an ancestor of HEAD. The ladder promises the final "
               "DESCENDS from the candidate that was drilled; a tree that "
               "merely resembles it is not the tree that ran." % anchor)
        return 1

    changed = changed_paths(root, anchor_ref)
    strays = sorted(p for p in changed if not is_stamp(p))
    if strays:
        refuse("%s differs from %s outside the stamp set, so the tree that "
               "ships is not the tree that was drilled:" % (final, anchor))
        for path in strays:
            print("  non-stamp: %s" % path, file=sys.stderr)
        # Both of these actually clear the refusal, and that is the whole test
        # of what belongs here. Drilling the final itself does NOT: the anchor
        # above is published and reachable, so a fresh drills/X.Y.Z.md adds a
        # stamp and leaves both the anchor and the stray path exactly where they
        # are (crew#579, codex-bot-andresmgsl).
        print("stamps-only: the ladder has not been followed. Cut %s-rc%d at "
              "the tree that ships and drill it, so the final rides a candidate "
              "it does not differ from — or take the change above back out of "
              "this release window. Re-drilling %s on top of %s answers "
              "neither: it adds a stamp and removes nothing."
              % (final, last + 1, final, anchor), file=sys.stderr)
        return 1

    print("stamps-only: %s over %s — %d path%s changed, all stamps."
          % (final, anchor, len(changed), "" if len(changed) == 1 else "s"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
