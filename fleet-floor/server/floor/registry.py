"""The two watch registries, as a layer the console can edit (#488).

The fleet's scope is two files in the operator fleet definition: `repos.txt`,
the work registry every duty module is bounded by, and `notify-repos.txt`, the
extra handoff targets the operator notifier sweeps. Both are HOST files, so
re-pointing one droid at a different repository was an `ssh`, knowing where the
definition lives, and several edits by hand — for what is operationally a
one-line decision made weekly.

A WRITE IS ONE TRANSACTION, and that is the shape the rest of this module
serves. Three things happen on every edit — the current state is read, the file
is replaced, the change is recorded — and the console is a threaded server, so
all three run under one lock per registry and the record is a PRECONDITION of
the write rather than a remark about it (see `_journal_writable`). A change to
the fleet's scope that nobody can attribute afterwards is the failure D5 names,
so a journal that cannot be appended to refuses the edit before anything moves.

FIVE THINGS THIS MODULE IS NOT, each stated because each is the obvious wrong
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
import tempfile
import threading
import time

from floor import CREW_ROOT
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

# ONE LOCK PER REGISTRY KIND, and per kind rather than per file on purpose. The
# console is a `ThreadingHTTPServer`, so two operators — or one operator and a
# double-clicked button — can be inside a write at the same moment, and a write
# is a read-modify-write whose reported and JOURNALLED change describes the
# state it read. Unserialised, two writes to one registry interleave into a
# record that describes input the other thread has already replaced.
#
# Per KIND because `set_override` reads the fleet-wide list as the universe it
# validates against: a per-file lock would have to hold two at once, which
# needs an ordering rule to stay deadlock-free, while one lock per kind is
# deadlock-free by construction and costs nothing at operator pace. The journal
# is shared across kinds, so it takes its own lock, always acquired INSIDE a
# kind lock and never the other way about.
#
# READS ARE DELIBERATELY UNLOCKED. `_rewrite` replaces the file with `os.replace`,
# which is atomic, so a reader sees the whole old file or the whole new one and
# never a torn one — and a snapshot that read the fleet-wide list just before a
# write and the override just after still resolves to a contained set, because
# `effective` intersects. Locking reads would serialise every poll against every
# edit to buy nothing.
_LOCKS = {kind: threading.Lock() for kind in KINDS}
_JOURNAL_LOCK = threading.Lock()


def _paths(kind, box=None):
    """(fleet-wide file, override file or None) for one registry.

    These are the paths this module WRITES, always inside the fleet definition.
    What a fleet-wide list is READ from can be the shipped example instead —
    see `_fleet_source`, which is the read half and the only one that falls
    back.
    """
    name, overrides = KINDS[kind]
    fleet_wide = os.path.join(CONFIG_DIR, name)
    if box is None:
        return fleet_wide, None
    return fleet_wide, os.path.join(CONFIG_DIR, overrides, "%s.txt" % box)


def _fleet_source(kind):
    """(path the fleet-wide list is read from, is it the definition's own).

    `cli/crew`'s `config_file` resolves a fleet definition file that is absent
    to the SHIPPED `examples/<name>`, and `notify-repos.txt` is optional in a
    hand-built definition while `examples/notify-repos.txt` names nine live
    repositories. A floor that read only `CONFIG_DIR` would therefore render an
    empty notify universe for a definition whose next `crew upgrade` stages
    nine — the console-vs-transport drift this module exists to make
    impossible, and worse than a wrong number: an operator "filling in" that
    empty list from the floor would drop eight sweep targets the fleet was
    actually working.

    So the read falls back exactly where the transport falls back, and the
    WRITE never does: `_paths` stays inside the fleet definition, so the first
    save materialises the operator's own file — carrying the shipped file's
    comments with it, since `_rewrite` line-edits from what was being served —
    and from then on it wins, which is `config_file`'s own rule arriving one
    edit later. Nothing here can write into the installed tree.
    """
    own, _ = _paths(kind)
    if os.path.isfile(own):
        return own, True
    shipped = os.path.join(CREW_ROOT, "examples", KINDS[kind][0])
    return (shipped, False) if os.path.isfile(shipped) else (own, False)


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
    _, override = _paths(kind, box)
    source, _ = _fleet_source(kind)
    universe = read_entries(source)
    if override and os.path.isfile(override):
        chosen = set(read_entries(override))
        return [e for e in universe if e in chosen], "override"
    return universe, "fleet"


def snapshot(boxes):
    """Everything the page renders, read fresh from disk on every call."""
    out = {"config_dir": CONFIG_DIR, "fleet": {}, "boxes": {}}
    for kind in KINDS:
        fleet_wide, _ = _paths(kind)
        source, own = _fleet_source(kind)
        out["fleet"][kind] = {
            "path": fleet_wide,
            "entries": read_entries(source),
            # An absent fleet-wide file is worth saying out loud rather than
            # rendering as an empty list, and it is a state the page RENDERS
            # rather than a flag nobody reads: what is being served is then the
            # shipped `examples/` file, which is what the transport stages too,
            # so an operator who cannot see the difference would read nine
            # inherited notify targets as a list they were free to replace.
            "present": own,
            "served_from": None if own else source,
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

def _rewrite(path, wanted, base=None):
    """Apply `wanted` to `path` as a line edit, atomically.

    Comments and blanks are carried through untouched and in place; an entry
    that is staying keeps its own line and its own position; an entry that is
    going takes its line with it; new entries land after the last surviving
    entry, or at the end of the file when there is none. Returns
    (added, removed).

    `base` is the file the edit is applied TO when it is not `path` itself —
    the shipped example a fleet-wide list was being served from before this
    first save materialised the definition's own copy (`_fleet_source`). The
    edit is then a line edit of what the operator was actually looking at,
    comments and all, rather than a bare list dropped where a documented file
    used to be resolved.

    Written through a temporary file in the same directory and renamed, so a
    reader — the CLI staging a box, or the operator's own `cat` — never sees a
    half-written registry, and a crash mid-write leaves the previous file
    intact rather than a truncated one.

    THE TEMPORARY FILE IS UNIQUE PER WRITE, via `mkstemp`. It used to be
    `<path>.crew-floor.<pid>`, which is one name for the whole process: under
    the threaded server two writes to one registry then shared a temp file and
    the second `os.replace` raised `FileNotFoundError` on a path the first had
    already renamed away. A unique name also settles the case a lock cannot —
    two floor processes over one definition — where the worst that remains is a
    lost update and never a corrupt or vanished registry.
    """
    read_from = base or path
    try:
        with open(read_from, encoding="utf-8") as f:
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

    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    # The file's own mode carried onto its replacement, because `mkstemp` makes
    # 0600 and a registry every other reader on the host opens must not quietly
    # become private on its first edit from the console. 0644 for a file that
    # did not exist yet, which is the mode `crew init` scaffolds one with.
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        mode = 0o644
    fd, tmp = tempfile.mkstemp(dir=parent,
                               prefix="%s.crew-floor." % os.path.basename(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("".join("%s\n" % line for line in out))
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        # A write that failed must not leave its temporary file beside the
        # registry: the directory is the operator's fleet definition, and a
        # litter of half-written registries there is the next reader's problem.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return added, [e for e in have if e not in keep]


def _journal_writable():
    """(ok, reason) — can the journal be appended to, right now?

    THE RECORD IS A PRECONDITION OF THE WRITE, not a remark about it. This
    module used to append best-effort and report success regardless, on the
    argument that a journal failure must not turn a landed edit into a reported
    one. That argument is wrong on its own terms: it treats D5 as commentary
    when D5 makes the record part of what a registry write IS, and what it
    actually bought was a fleet whose scope could change with nothing durable
    saying who changed it — a `.registry-journal.log` that is a directory, or a
    definition gone read-only, and the console answers "saved".

    So the question is asked BEFORE anything moves, and a No refuses the edit
    while the registry is still untouched. Asked after validation, so a refused
    edit never creates the journal, and the operator's own mistakes are still
    reported as their own rather than behind a host fault.

    The append this proves is `O_APPEND` on an existing writable file, which is
    the same call the write itself will make moments later under the same lock.
    It is not a proof against a disk that fills in between — that residual
    window has its own defined outcome in the writers below, and is why
    `_journal` reports rather than swallows.
    """
    try:
        with open(JOURNAL, "a", encoding="utf-8"):
            pass
        return True, ""
    except OSError as e:
        return False, (
            "the write was refused because it could not be recorded: the "
            "registry journal %s cannot be appended to (%s). Every change to "
            "the fleet's scope is attributable, so nothing was written — fix "
            "the journal on the host and make the edit again."
            % (JOURNAL, e))


def _rewrite_refusal(path, e):
    """The sentence a write that could not be made says, rather than a stack.

    `_rewrite` raises `OSError` for the residual the preflight cannot cover: a
    definition directory gone read-only, or occupied, AFTER `_journal_writable`
    answered yes. That exception used to travel out through `registry_command`
    and `do_command` into the handler and drop the connection — the one path in
    this module where the operator got a dead request instead of a sentence,
    while every neighbouring failure refuses with its reason. Nothing has
    landed when this is reached, so it is a refusal like any other and the
    console reports it as one.
    """
    return ("the write was refused: %s could not be replaced (%s). Nothing "
            "was written — fix the fleet definition on the host and make the "
            "edit again." % (path, e))


def _journal(actor, action, path, box, entries, added, removed):
    """D5: one line per write, so a registry change is attributable after it.

    Returns (recorded, reason). Append-only, and never silent about failing:
    the caller has already replaced the registry by the time this runs, so a
    failure here is a landed edit with no record and the operator has to be
    told exactly that. `_journal_writable` makes it nearly unreachable; the
    writers below define what happens when it is reached anyway.

    `entries=` IS THE STATE THE WRITE APPLIED, and it is what makes a line
    self-sufficient. The record used to carry the two deltas and nothing else,
    which reads like an audit log and is not one: a set to the state the file
    already held journalled `added=- removed=-`, an entry that stayed appeared
    in no record anywhere, and the first line in a fresh journal had no earlier
    line to difference against — so reconstructing what the fleet's scope
    actually WAS after any given write meant replaying every line before it and
    hoping none was missing. AC10 asks for a record describing the input that
    write applied, and a delta over an unrecorded baseline does not describe
    one. The deltas stay beside it: they are what an operator scanning the log
    reads, and they are the two fields the console echoes back.

    Two field values are not repositories, and cannot collide with one, because
    every entry is an `owner/repo`: `-` is the EMPTY state — a registry or a
    selection deliberately naming nothing — and `inherit` is the absence of a
    file, which is the state a cleared override leaves its box in. The action
    already distinguishes a clear from a set; this makes the resulting state
    readable without knowing that.
    """
    line = ("%s registry %s file=%s box=%s actor=%s entries=%s added=%s "
            "removed=%s\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                action,
                os.path.relpath(path, CONFIG_DIR) if path else "-",
                box or "-",
                actor or "-",
                "inherit" if entries is None else (",".join(entries) or "-"),
                ",".join(added) or "-",
                ",".join(removed) or "-",
            ))
    try:
        # One `write` of one line, under the journal's own lock: two kinds can
        # be edited at the same moment and a record split down the middle is
        # worse than no record, because it reads as two writes that never
        # happened.
        with _JOURNAL_LOCK:
            with open(JOURNAL, "a", encoding="utf-8") as f:
                f.write(line)
    except OSError as e:
        log("registry journal unwritable (%s): %s" % (e, line.strip()))
        return False, (
            "the edit LANDED and could not be recorded: the registry journal "
            "%s could not be appended to (%s). %s has changed on disk and no "
            "durable record of it exists — reconcile the journal by hand."
            % (JOURNAL, e, path))
    log(line.strip())
    return True, ""


def set_fleet(kind, entries, actor=""):
    """Rewrite one fleet-wide registry. Returns (result, error).

    THE THREE OUTCOMES, and the reason each is distinguishable: `(result, "")`
    is a landed and recorded write; `(None, error)` is a refusal with the
    registry untouched, whether the operator's entry was bad or the journal was
    unwritable; `(result, error)` — a result AND an error — is the one narrow
    case where the file changed and the record did not, and it carries both
    because "refused" over a file that moved is a lie the console would tell
    the operator once and never correct.

    Everything from the read of the current list to the record runs under this
    kind's lock, so the change this reports is the change it made.
    """
    path, _ = _paths(kind)
    with _LOCKS[kind]:
        source, own = _fleet_source(kind)
        clean, err = validate(entries, probe=set(read_entries(source)))
        if err:
            return None, err
        ok, why = _journal_writable()
        if not ok:
            return None, why
        try:
            added, removed = _rewrite(path, clean, base=None if own else source)
        except OSError as e:
            return None, _rewrite_refusal(path, e)
        recorded, jerr = _journal(actor, "set-fleet:%s" % kind, path, None,
                                  clean, added, removed)
        return {"kind": kind, "scope": "fleet", "path": path, "entries": clean,
                "added": added, "removed": removed, "recorded": recorded}, jerr


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

    The three outcomes are `set_fleet`'s, and the lock is the same one: the
    universe this validates against is the fleet-wide list, so a selection can
    never be checked against a list another thread is in the middle of
    replacing.
    """
    _, path = _paths(kind, box)
    with _LOCKS[kind]:
        source, _ = _fleet_source(kind)
        universe = read_entries(source)
        wanted = [str(e).strip() for e in entries if str(e).strip()]
        if wanted and not universe:
            return None, ("the fleet-wide %s registry names no repositories, "
                          "so there is nothing for %s to select — edit the "
                          "fleet-wide list first" % (kind, box))
        clean, err = validate(wanted, within=set(universe))
        if err:
            return None, err
        ok, why = _journal_writable()
        if not ok:
            return None, why
        try:
            added, removed = _rewrite(path, clean)
        except OSError as e:
            return None, _rewrite_refusal(path, e)
        recorded, jerr = _journal(actor, "set-override:%s" % kind, path, box,
                                  clean, added, removed)
        entries_, esource = effective(kind, box)
        return {"kind": kind, "scope": "override", "box": box, "path": path,
                "entries": entries_, "source": esource, "added": added,
                "removed": removed, "recorded": recorded}, jerr


def clear_override(kind, box, actor=""):
    """Remove one box's override so it inherits again. Returns (result, error).

    Clearing an override the box does not have is NOT an error and not a
    no-op's silence either: it reports `cleared: False` and the box's state,
    which is what a console owes an operator who clicked Inherit on a cell that
    was already inheriting. Only a file that could not be removed fails.

    A clear that has nothing to remove writes nothing, so it asks nothing of
    the journal either: the record is a precondition of a WRITE, and reporting
    "already inheriting" is not one.
    """
    _, path = _paths(kind, box)
    with _LOCKS[kind]:
        had = os.path.isfile(path)
        removed = read_entries(path) if had else []
        jerr, recorded = "", True
        if had:
            ok, why = _journal_writable()
            if not ok:
                return None, why
            try:
                os.remove(path)
            except OSError as e:
                return None, "could not clear the override for %s: %s" % (box, e)
            recorded, jerr = _journal(actor, "clear-override:%s" % kind, path,
                                      box, None, [], removed)
        entries, source = effective(kind, box)
        return {"kind": kind, "scope": "override", "box": box, "path": path,
                "cleared": had, "entries": entries, "source": source,
                "recorded": recorded}, jerr
