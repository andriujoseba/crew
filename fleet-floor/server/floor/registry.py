"""The two watch registries, as a layer the console can edit (#488).

The fleet's scope is two files in the operator fleet definition: `repos.txt`,
the work registry every duty module is bounded by, and `notify-repos.txt`, the
extra handoff targets the operator notifier sweeps. Both are HOST files, so
re-pointing one droid at a different repository was an `ssh`, knowing where the
definition lives, and several edits by hand — for what is operationally a
one-line decision made weekly.

FOUR THINGS THIS MODULE IS NOT, each stated because each is the obvious wrong
turn:

  it is not a store.  Every read opens the file. There is no cache to
      invalidate, so an operator who edits `repos.txt` in vim is picked up by
      the next request with no floor restart, and the floor can never serve a
      view that disagrees with what the engine will transport (D4).

  it is not a rewriter.  A write is a LINE EDIT: every comment and blank line
      in the file survives it, removals drop their own line, and additions land
      after the last entry. `repos.txt` ships 60 lines of doctrine an operator
      is meant to read and `notify-repos.txt` carries a comment block BETWEEN
      two groups of entries, so a writer that emitted "header, then entries"
      would silently delete the second group's explanation. What lands is a
      diff the operator could have typed.

  it is not a second copy of the fleet-wide list.  A per-box override is its
      own file naming that box's selection; the box either has one or inherits
      (D2). Clearing REMOVES the file and is therefore a different act from
      writing a file that happens to select everything the fleet-wide list
      holds today: the cleared box follows a later widening and the pinned one
      does not, which is the whole reason an override is a layer rather than a
      copy.

  it is not a free list.  An override SELECTS from the fleet-wide registry and
      can never reach outside it (operator, 2026-08-29): a droid's watch set is
      drawn from the host-level list, and a repository in a member that is not
      at host level is the divergence the layer exists to make unnecessary. The
      rule is enforced twice on purpose, because once is not enough — refused
      at the edit by `set_override`, so the operator learns at the click, and
      applied again at every READ by `effective`, so that removing a repository
      fleet-wide takes it off the boxes that selected it rather than leaving
      them working a board the fleet no longer knows about. A write-time check
      alone would hold the invariant for exactly as long as nobody edited the
      fleet-wide list.

  it is not the transport.  Writing here changes what the next `crew upgrade`
      stages onto a box; nothing in this process reaches into a guest. The
      transport half is `cli/crew`'s `stage_fleet_definition`, which resolves
      the same override this module writes.
"""

import os
import re
import time

from floor.ping import log, run
from floor.roster import CONFIG_DIR

# The two registries, by the name the wire and the page use. The value is the
# file in the fleet definition and the directory its per-box overrides live in
# — `repos.d/<box>.txt` beside `repos.txt`, the `.d` convention an operator
# already knows from every other config in /etc.
KINDS = {
    "work": ("repos.txt", "repos.d"),
    "notify": ("notify-repos.txt", "notify-repos.d"),
}

# owner/repo, and nothing else. GitHub's own rule for both halves is letters,
# digits, `-`, `_` and `.`; anything else here is a typo that would reach the
# engine as a repository nobody can address. Bounded because these strings are
# later interpolated into `gh` arguments and box-side registries.
RE_REPO = re.compile(r"^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$")

# The reachability probe. Short, because it runs while an operator waits on a
# click and there are at most a handful of new entries in one edit.
REPO_PROBE_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_REPO_PROBE_TIMEOUT", "15"))

# D5's record. A dotfile beside the definition rather than inside it: the
# journal is evidence about the fleet definition, not part of it, and `crew
# init` scaffolds a definition. Same `key=value` shape as `duty.log`, so the
# fleet has one grammar for "what happened and who did it".
JOURNAL = os.path.join(CONFIG_DIR, ".registry-journal.log")


def _paths(kind, box=None):
    """(fleet-wide file, override file or None) for one registry."""
    name, overrides = KINDS[kind]
    fleet_wide = os.path.join(CONFIG_DIR, name)
    if box is None:
        return fleet_wide, None
    return fleet_wide, os.path.join(CONFIG_DIR, overrides, "%s.txt" % box)


def is_entry(line):
    """A registry line that names a repository, as every reader defines it.

    `# and blank lines are ignored` is the rule stated in both files' own
    headers and implemented identically in the CLI's `grep -vE`, the box-side
    engine and `read_roster` above. Spelled once here so the console's view of
    a file cannot drift from the engine's.
    """
    s = line.strip()
    return bool(s) and not s.startswith("#")


def read_entries(path):
    """The repositories one registry file names, in file order.

    A missing file is an empty registry and not an error: `notify-repos.txt` is
    optional in a hand-built definition, and an override file's ABSENCE is the
    inherit state this module has to be able to report.
    """
    try:
        with open(path, encoding="utf-8") as f:
            return [line.strip() for line in f if is_entry(line)]
    except OSError:
        return []


def effective(kind, box):
    """(entries, source) for one box: its selection if it has one, else the
    fleet-wide list. `source` is `"override"` or `"fleet"`.

    Existence is the test, never content. A box whose override file is EMPTY
    has been deliberately narrowed to no repositories at all — containment
    state the registry header calls a divergence veto — and reading that as
    "nothing set, fall through" would silently widen the one box somebody
    pointed at nothing.

    The selection is INTERSECTED with the fleet-wide list here, and in
    fleet-wide order, which is the read half of the containment invariant
    above. Two consequences, both wanted: a repository dropped from the
    fleet-wide registry leaves every box at once, including the boxes that had
    selected it, so an operator retiring a board does it in one edit; and the
    order a box sees is the order the operator maintains upstream, so the two
    views read alike rather than preserving whatever order a click happened to
    submit.
    """
    fleet_wide, override = _paths(kind, box)
    universe = read_entries(fleet_wide)
    if override and os.path.isfile(override):
        chosen = set(read_entries(override))
        return [e for e in universe if e in chosen], "override"
    return universe, "fleet"


def snapshot(boxes):
    """Everything the page renders, read fresh from disk on every call."""
    out = {"config_dir": CONFIG_DIR, "fleet": {}, "boxes": {}}
    for kind in KINDS:
        fleet_wide, _ = _paths(kind)
        out["fleet"][kind] = {
            "path": fleet_wide,
            "entries": read_entries(fleet_wide),
            # An absent fleet-wide file is worth saying out loud rather than
            # rendering as an empty list: `repos.txt` is required by both
            # resolvers, so its absence means this floor is serving a
            # definition the CLI would refuse.
            "present": os.path.isfile(fleet_wide),
        }
    for box in boxes:
        cell = {}
        for kind in KINDS:
            entries, source = effective(kind, box)
            _, override = _paths(kind, box)
            cell[kind] = {
                "entries": entries,
                "source": source,
                "inherited": source == "fleet",
                "path": override,
            }
        out["boxes"][box] = cell
    return out


# --------------------------------------------------------------------------
# validation  (D3)
# --------------------------------------------------------------------------

def _probe_reachable(repo):
    """(ok, reason) — can the fleet reach this repository right now?

    `gh api` rather than an unauthenticated HTTP GET, because the question is
    not "does this repository exist somewhere" but "can THIS fleet work it":
    a private repository the host's credential can read is reachable and a
    public one it cannot is not, and only the credential the engine actually
    uses can answer that.

    A probe that cannot be RUN refuses too, and that is a deliberate choice
    rather than an oversight. The costs are asymmetric in the direction that
    settles it: a refusal is one operator click that says exactly what is
    broken on the host, while a write admitted on an unasked question is the
    failure D3 names — a repository that lands in the registry and is
    discovered at the next tick, in a duty log nobody is reading. The reason
    string distinguishes the two cases, so an operator is never left guessing
    whether GitHub said no or nothing asked it.
    """
    rc, out, err = run(["gh", "api", "repos/%s" % repo, "-q", ".full_name"],
                       REPO_PROBE_TIMEOUT_S)
    if rc == 0 and out.strip():
        return True, ""
    if rc == 127:
        return False, ("the reachability probe could not be run: `gh` is not "
                       "installed on this host")
    if rc == 124:
        return False, ("the reachability probe timed out after %ss"
                       % REPO_PROBE_TIMEOUT_S)
    detail = (err or out).strip().splitlines()
    detail = detail[-1][:200] if detail else "rc %d" % rc
    return False, "the fleet cannot reach it: %s" % detail


def validate(entries, probe=None, within=None):
    """(clean, error) — the submitted list, or the first reason to refuse it.

    Reachability is asked only of entries this edit ADDS; `probe` is the set
    already in the file. An existing line that has since become unreachable —
    a repository renamed, archived out of view, or moved to another fleet —
    must not block every unrelated edit to the same registry, and above all
    must not block its own REMOVAL, which is the repair for it.

    `within` bounds the submission to a universe, and is how a per-box
    selection is held inside the fleet-wide registry (operator, 2026-08-29).
    It is checked BEFORE reachability and instead of it: an entry drawn from
    the fleet-wide list was probed when it landed there, so asking GitHub again
    would spend a round trip per repository to re-answer a settled question
    while the operator waits on a click. The two arguments are therefore
    alternatives in practice — a fleet-wide write probes because its entries
    are new to the fleet, a per-box write contains because none of its can be.
    """
    seen = []
    for raw in entries:
        entry = str(raw).strip()
        if not entry:
            continue
        if not RE_REPO.match(entry):
            return None, ("%r is not a repository: name one owner/repo per "
                          "entry, using letters, digits, `.`, `-` and `_`"
                          % entry)
        if entry in seen:
            return None, "%s is listed twice" % entry
        if within is not None and entry not in within:
            return None, ("%s is not in the fleet-wide registry — a box can "
                          "only watch repositories the fleet watches, so add "
                          "it fleet-wide first and then select it here"
                          % entry)
        seen.append(entry)
    if probe is not None:
        for entry in seen:
            if entry in probe:
                continue
            ok, why = _probe_reachable(entry)
            if not ok:
                return None, "%s was not added — %s" % (entry, why)
    return seen, ""


# --------------------------------------------------------------------------
# writing
# --------------------------------------------------------------------------

def _rewrite(path, wanted):
    """Apply `wanted` to `path` as a line edit, atomically.

    Comments and blanks are carried through untouched and in place; an entry
    that is staying keeps its own line and its own position; an entry that is
    going takes its line with it; new entries land after the last surviving
    entry, or at the end of the file when there is none. Returns
    (added, removed).

    Written through a temporary file in the same directory and renamed, so a
    reader — the CLI staging a box, or the operator's own `cat` — never sees a
    half-written registry, and a crash mid-write leaves the previous file
    intact rather than a truncated one.
    """
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []

    have = [line.strip() for line in lines if is_entry(line)]
    keep = set(wanted)
    kept, out, last_entry = [], [], -1
    for line in lines:
        if is_entry(line):
            entry = line.strip()
            if entry not in keep or entry in kept:
                continue                       # removed, or a duplicate line
            kept.append(entry)
            out.append(entry)
            last_entry = len(out) - 1
            continue
        out.append(line)
    added = [e for e in wanted if e not in kept]
    at = last_entry + 1 if last_entry >= 0 else len(out)
    out[at:at] = added

    tmp = "%s.crew-floor.%d" % (path, os.getpid())
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("".join("%s\n" % line for line in out))
    os.replace(tmp, path)
    return added, [e for e in have if e not in keep]


def _journal(actor, action, path, box, added, removed):
    """D5: one line per write, so a registry change is attributable after it.

    Append-only and best-effort. A definition directory that has gone
    read-only under the floor is a real failure and the write above would have
    raised on it first; a journal that could not be appended must not be the
    thing that turns a landed edit into a reported failure, so it says so in
    the floor log and the action still reports what it did.
    """
    line = ("%s registry %s file=%s box=%s actor=%s added=%s removed=%s\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        action,
        os.path.relpath(path, CONFIG_DIR) if path else "-",
        box or "-",
        actor or "-",
        ",".join(added) or "-",
        ",".join(removed) or "-",
    ))
    try:
        with open(JOURNAL, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError as e:
        log("registry journal unwritable (%s): %s" % (e, line.strip()))
    log(line.strip())


def set_fleet(kind, entries, actor=""):
    """Rewrite one fleet-wide registry. Returns (result, error)."""
    path, _ = _paths(kind)
    clean, err = validate(entries, probe=set(read_entries(path)))
    if err:
        return None, err
    added, removed = _rewrite(path, clean)
    _journal(actor, "set-fleet:%s" % kind, path, None, added, removed)
    return {"kind": kind, "scope": "fleet", "path": path, "entries": clean,
            "added": added, "removed": removed}, ""


def set_override(kind, box, entries, actor=""):
    """Write one box's selection from the fleet-wide registry. (result, error).

    Bounded by the fleet-wide list and not probed: every candidate is already
    in that list, so the reachability question this edit could ask was answered
    when the entry landed there (see `validate`). What replaces the probe is
    containment — an entry the fleet-wide registry does not name is refused
    here with its reason, which is D3's "refused at the edit" applied to the
    invariant the operator stated on 2026-08-29.

    A fleet-wide registry that is EMPTY or absent refuses every non-empty
    selection, and says so as itself rather than as five containment failures
    in a row: there is nothing to select from, and the operator's next move is
    a fleet-wide edit and not a narrower box.
    """
    fleet_wide, path = _paths(kind, box)
    universe = read_entries(fleet_wide)
    wanted = [str(e).strip() for e in entries if str(e).strip()]
    if wanted and not universe:
        return None, ("the fleet-wide %s registry names no repositories, so "
                      "there is nothing for %s to select — edit the fleet-wide "
                      "list first" % (kind, box))
    clean, err = validate(wanted, within=set(universe))
    if err:
        return None, err
    added, removed = _rewrite(path, clean)
    _journal(actor, "set-override:%s" % kind, path, box, added, removed)
    entries_, source = effective(kind, box)
    return {"kind": kind, "scope": "override", "box": box, "path": path,
            "entries": entries_, "source": source,
            "added": added, "removed": removed}, ""


def clear_override(kind, box, actor=""):
    """Remove one box's override so it inherits again. Returns (result, error).

    Clearing an override the box does not have is NOT an error and not a
    no-op's silence either: it reports `cleared: False` and the box's state,
    which is what a console owes an operator who clicked Inherit on a cell that
    was already inheriting. Only a file that could not be removed fails.
    """
    _, path = _paths(kind, box)
    had = os.path.isfile(path)
    removed = read_entries(path) if had else []
    if had:
        try:
            os.remove(path)
        except OSError as e:
            return None, "could not clear the override for %s: %s" % (box, e)
        _journal(actor, "clear-override:%s" % kind, path, box, [], removed)
    entries, source = effective(kind, box)
    return {"kind": kind, "scope": "override", "box": box, "path": path,
            "cleared": had, "entries": entries, "source": source}, ""
