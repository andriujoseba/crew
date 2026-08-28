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
allowed to move. Anything else means the ladder was not followed, and the two
ways forward are ordinary — cut the next candidate and drill it, or drill the
final itself, which makes this guard vacuous because a final with no candidate
above it has nothing to be compared against.

STRICTER THAN THE SENTENCE, DELIBERATELY. "No executable byte" would admit a
documentation-only merge; the stamp set refuses it. The costs are asymmetric in
the way `scope-coverage.py` describes for its own dialect: a false red costs one
author a re-read and is answered by cutting the next candidate, while a false
green ships a final whose evidence describes a different tree. A guard looser
than its claim is the claim wearing a green check.

THE ANCHOR IS THE RECORD, NOT THE TAG. Which candidate was last is read from
`drills/X.Y.Z-rcN.md` in the shipped tree, and the tag is then required to
exist. Reading the tags alone would make a missing tag look like a window that
cut no candidate — a silent pass, which is the one answer this guard must never
give. So a record whose tag cannot be found is a REFUSAL: "I found nothing" and
"I could not look" are different answers, the distinction `drill/teardown.sh`
already keeps in its exit table. A tag carrying no record in the shipped tree
is not evidence and is not anchored to; `drill-recorded` is what makes a record
exist, and a tag without one never passed it.

EVERYTHING IS READ FROM HEAD — the version, the records, the diff. What ships
is what is committed, and one source of truth is why a worktree edit cannot
move this guard's answer while leaving the published tree alone.

Run it from anywhere:  .github/stamps-only.py [--root DIR]

  exit 0  the tree is a stamps-only final, or there is nothing to assert
  exit 1  refused — the diff leaves the stamp set, or the anchor is not an
          ancestor of what ships
  exit 2  could not look — a record's tag is unreachable, or git could not
          answer at all

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


def rc_records(root, final):
    """The candidate numbers this shipped tree carries a record for."""
    listing = git(root, ["ls-tree", "-r", "--name-only", "-z", "HEAD", "--", DRILLS],
                  "reading the drill records")
    want = re.compile(r"^%s/%s-rc(\d+)\.md$" % (re.escape(DRILLS), re.escape(final)))
    found = {}
    for path in listing.split("\0"):
        m = want.match(path)
        if m:
            found[int(m.group(1))] = path
    return found


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
    if not records:
        print("stamps-only: %s cut no candidate — no drills/%s-rcN.md in the "
              "shipped tree, so there is nothing above it to compare against."
              % (final, final))
        return 0

    last = max(records)
    anchor = "%s-rc%d" % (final, last)
    if not git_ok(root, ["rev-parse", "--verify", "%s^{commit}" % anchor]):
        shallow = git(root, ["rev-parse", "--is-shallow-repository"],
                      "asking whether the clone is shallow").strip() == "true"
        die("the shipped tree carries %s, so %s is this final's anchor — and "
            "that tag cannot be resolved%s. This is not a pass: an unreachable "
            "anchor is the one case where a missing check reads exactly like a "
            "clean one. Fetch the tags (actions/checkout with fetch-depth: 0), "
            "or say in %s/%s.md why a record exists for a candidate that never "
            "published."
            % (records[last], anchor,
               " (the clone is shallow)" if shallow else "",
               DRILLS, final))

    if not git_ok(root, ["merge-base", "--is-ancestor", anchor, "HEAD"]):
        refuse("%s is not an ancestor of HEAD. The ladder promises the final "
               "DESCENDS from the candidate that was drilled; a tree that "
               "merely resembles it is not the tree that ran." % anchor)
        return 1

    changed = changed_paths(root, anchor)
    strays = sorted(p for p in changed if not is_stamp(p))
    if strays:
        refuse("%s differs from %s outside the stamp set, so the tree that "
               "ships is not the tree that was drilled:" % (final, anchor))
        for path in strays:
            print("  non-stamp: %s" % path, file=sys.stderr)
        print("stamps-only: the ladder has not been followed. Cut %s-rc%d and "
              "drill it, or drill %s itself and record it in %s/%s.md — either "
              "answers this, and neither is an exception to it."
              % (final, last + 1, final, DRILLS, final), file=sys.stderr)
        return 1

    print("stamps-only: %s over %s — %d path%s changed, all stamps."
          % (final, anchor, len(changed), "" if len(changed) == 1 else "s"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
