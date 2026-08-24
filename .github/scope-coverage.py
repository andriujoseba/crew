#!/usr/bin/env python3
"""Every tracked path matches a scope row, or is a declared exception (#500).

`.github/labeler.yml` is the PR half of the scope story, and it is enumerated
by hand. The tree grows; the map does not follow on its own. When it falls
behind, a PR touching only the unmapped paths is labelled with nothing — and
nothing about that is loud: the scope job succeeds, the PR just arrives bare.
Twice now that drift has been found by a hand census (#238, then #500), which
is the cost this file exists to stop paying.

So the map is checked by construction instead: run its own globs over the
tracked tree, and fail naming every path no row matched. What is deliberately
unmapped is declared in `.github/scope-coverage.allow` with a reason, so the
exceptions are readable rather than the check being silenced wholesale.

THE CONSUMER IS NOT actions/labeler. The file keeps that project's config
format, but what reads it is ceremony's `labels-scope` job — a replacement
adopted at ceremony#130 because labeler writes its labels with a full-replace
PUT and ate a label applied in the window. Its glob dialect is that job's, and
this file mirrors it rather than minimatch, because the only question worth
answering here is whether THAT job would derive a label. Being stricter than
the consumer is safe — a false red costs one author a minute. Being looser is
the failure this guard exists to prevent: reporting a path covered that the job
leaves bare is the original defect wearing a green check.

Run it from anywhere:  .github/scope-coverage.py [--root DIR]

Stdlib only, deliberately — the guard has to run on a bare runner, and a check
that needs installing is a check that gets skipped.
"""

import argparse
import os
import re
import subprocess
import sys

CONFIG = ".github/labeler.yml"
ALLOW = ".github/scope-coverage.allow"

# The scope job's only match key: it refuses any other one by name, so a row
# carrying one derives nothing at all. Refused here for the same reason it is
# refused there — this parser exists to say what a row matches, not to guess.
MATCH_KEY = "any-glob-to-any-file"
# Bytes the scope job's translator passes through as LITERAL characters. A row
# using them as glob syntax matches, in practice, nothing — so it reads here as
# a mapping and derives no label, which is the exact shape of the defect this
# guard was written against. Refused at the door, named, rather than silently
# honoured as a filename nobody has. A backslash the job refuses outright.
UNSUPPORTED = "{}()!+@|[\\"


def die(msg):
    print("scope-coverage: ERROR: %s" % msg, file=sys.stderr)
    raise SystemExit(2)


def glob_to_re(glob, where):
    """Translate one glob exactly as the scope job's `glob_to_regex` does.

    `**` crosses `/`; `*` and `?` do not; a leading dot is not special; the
    whole path must match, so `README` matches README and never docs/README.
    Deliberately byte-for-byte the consumer's rule and not minimatch's — the
    two disagree about a `**` that is not a whole segment, and the answer that
    matters is the one that decides whether a label gets derived.
    """
    if not glob or glob.startswith("/") or glob.endswith("/"):
        die("%s: %r is not a path glob" % (where, glob))
    bad = [c for c in UNSUPPORTED if c in glob]
    if bad:
        die("%s: %r uses %s, which the scope job reads as literal characters "
            "rather than glob syntax — so the row would derive nothing. Express "
            "it as a plain path or a `dir/**` glob" % (where, glob, ", ".join(bad)))
    out, i = "", 0
    while i < len(glob):
        if glob[i:i + 2] == "**":
            out += ".*"
            i += 2
            continue
        ch = glob[i]
        out += "[^/]*" if ch == "*" else "[^/]" if ch == "?" else re.escape(ch)
        i += 1
    return re.compile("^" + out + "$")


def read_config(path):
    """Parse the labeler config's globs, one list per label.

    A deliberately small reader for the one shape this config has. It refuses
    anything else (see MATCH_KEY) rather than skipping it, because a row it
    silently ignored would read here as paths going unmapped, and a row it
    silently mis-read would read as paths being mapped when they are not.
    """
    rows, label, collecting = {}, None, False
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        where = "%s:%d" % (path, n)
        bare = line.strip()
        if not bare or bare.startswith("#"):
            continue
        top = re.match(r'^"([^"]+)":$', line)
        if top:
            label, collecting = top.group(1), False
            rows.setdefault(label, [])
            continue
        if label is None:
            die("%s: %r before any label" % (where, bare))
        if bare == "- changed-files:":
            continue
        key = re.match(r"^- ([a-z-]+):\s*(.*)$", bare)
        if key:
            name, rest = key.group(1), key.group(2).strip()
            if name != MATCH_KEY:
                die("%s: `%s:` is not `%s:` — this guard evaluates only the "
                    "latter, so it cannot say what that row matches" % (where, name, MATCH_KEY))
            collecting = not rest
            if rest.startswith("[") and rest.endswith("]"):
                rows[label] += [(g, where) for g in parse_inline(rest, where)]
            elif rest:
                # The scope job accepts a bare glob where a list would do.
                rows[label].append((unquote(rest, where), where))
            continue
        if collecting and bare.startswith("- "):
            rows[label].append((unquote(bare[2:].strip(), where), where))
            continue
        die("%s: %r is a shape this guard does not read" % (where, bare))
    if not rows:
        die("%s: no scope rows at all — the map cannot be empty" % path)
    empty = sorted(l for l, g in rows.items() if not g)
    if empty:
        die("%s: %s match nothing at all" % (path, ", ".join(empty)))
    return rows


def unquote(value, where):
    m = re.match(r'^"([^"]*)"$', value)
    if not m:
        die("%s: %r is not a quoted glob" % (where, value))
    return m.group(1)


def parse_inline(text, where):
    """Read `["a", "b"]`. Matched by quoted run, never split on the comma — a
    glob may legally contain one, and splitting first turns a glob this guard
    would have refused by name into an unreadable half of itself."""
    inner = text[1:-1].strip()
    if not inner:
        die("%s: empty glob list" % where)
    globs = re.findall(r'"[^"]*"', inner)
    if re.sub(r'"[^"]*"', "", inner).strip(", \t"):
        die("%s: %r is not a list of quoted globs" % (where, text))
    return [unquote(g, where) for g in globs]


def read_allow(path):
    """Parse the declared exceptions: one `<glob>  # <reason>` line each."""
    entries = []
    if not os.path.exists(path):
        return entries
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.strip()
        where = "%s:%d" % (path, n)
        if not line or line.startswith("#"):
            continue
        glob, sep, reason = line.partition("#")
        glob, reason = glob.strip(), reason.strip()
        if not sep or not reason:
            die("%s: %r carries no reason — a declared exception says why, or "
                "it is just a silenced check" % (where, glob or line))
        entries.append((glob, reason, where))
    return entries


def tracked(root):
    proc = subprocess.run(
        ["git", "-C", root, "ls-files", "-z"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        die("git ls-files failed in %s: %s"
            % (root, proc.stderr.decode("utf-8", "replace").strip()))
    return [p for p in proc.stdout.decode("utf-8").split("\0") if p]


def main():
    ap = argparse.ArgumentParser(
        description="every tracked path matches a scope row, or is declared")
    ap.add_argument("--root", default=".", help="repository root (default: .)")
    args = ap.parse_args()
    root = args.root
    config, allow_path = os.path.join(root, CONFIG), os.path.join(root, ALLOW)
    if not os.path.exists(config):
        die("%s does not exist" % config)

    rows = read_config(config)
    patterns = [(label, glob, glob_to_re(glob, where))
                for label, globs in rows.items() for glob, where in globs]
    allow = [(glob, reason, where, glob_to_re(glob, where))
             for glob, reason, where in read_allow(allow_path)]
    paths = tracked(root)
    if not paths:
        die("no tracked paths under %s — nothing was checked" % os.path.abspath(root))

    mapped, declared, unmapped = set(), {}, []
    for path in paths:
        hit = [label for label, _, rx in patterns if rx.match(path)]
        if hit:
            mapped.add(path)
            continue
        for glob, _, _, rx in allow:
            if rx.match(path):
                declared.setdefault(glob, []).append(path)
                break
        else:
            unmapped.append(path)

    # A declared exception that has stopped applying is rot of the same kind
    # this guard was written against: it reads as covered and covers nothing.
    stale = []
    for glob, reason, where, rx in allow:
        if glob in declared:
            continue
        covered = [p for p in mapped if rx.match(p)]
        stale.append("%s: %r %s" % (where, glob, (
            "is already matched by a scope row, so the exception hides the "
            "mapping" if covered else "matches no tracked path")))

    if unmapped or stale:
        for path in unmapped:
            print("scope-coverage: unmapped: %s" % path, file=sys.stderr)
        for line in stale:
            print("scope-coverage: stale exception: %s" % line, file=sys.stderr)
        if unmapped:
            print("scope-coverage: %d tracked path(s) match no row in %s. Map each "
                  "to the scope that owns it, or declare it in %s with a reason."
                  % (len(unmapped), CONFIG, ALLOW), file=sys.stderr)
        return 1

    print("scope-coverage: %d tracked paths, %d rows, %d declared exception(s) — "
          "all covered." % (len(paths), len(rows), len(allow)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
