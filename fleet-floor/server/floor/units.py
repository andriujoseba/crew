"""duty.log and one probe -> the record the page renders."""

import base64
import re
from datetime import datetime, timezone

from floor import SILENT_AFTER_S
from floor.ping import STUCK_AFTER_S, probe_box

# --------------------------------------------------------------------------
# duty.log -> telemetry  (#38)
# --------------------------------------------------------------------------

TS = r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)"
RE_START = re.compile(TS + r" SESSION START kind=(\S+) key=(\S+)")
RE_END = re.compile(TS + r" SESSION END kind=(\S+) key=(\S+) rc=(\d+) dur=(\d+)s outcome=(\S+)"
                    r"(?: acted=(yes|no|unknown) reply_tail=(\S*))?")
RE_ANY_TS = re.compile("^" + TS + r" ")

# Wake lines the duty modules already write. The queue shown on the floor is
# derived from these — it is real detected work, not a placeholder list. Each
# pattern yields (repo, key) pairs for the most recent completed tick.
RE_QUEUE = [
    re.compile(TS + r" attention: (\S+?)#(\d+) — launching pickup session"),
    re.compile(TS + r" review: (\S+?)#(\d+) head moved during dedup"),
]
RE_REVIEW_BATCH = re.compile(TS + r" review: (\S+) needs verdicts on: (.+)$")
RE_BUILD_DUTY = re.compile(TS + r" (\S+): build duty \(ready unclaimed=(\d+), whole rounds owed=(\d+)\)")
RE_TRIAGE = re.compile(TS + r" (\S+): signals:(\S+) launching triage session")
# The tick-wide batch has no repository. Its trailing "one mention session"
# clause is the structural discriminator; the leading word is deliberately
# not treated as a magic repository name because a real repo may be `fleet`.
RE_MENTION_BATCH = re.compile(
    TS + r" \S+: (\d+) unread mention\(s\) — launching one mention session$"
)
RE_MENTION = re.compile(
    TS + r" (\S+): (\d+) unread mention(?:\(s\))?(?: — launching mention session)?$"
)
RE_RESUME = re.compile(TS + r" (\S+): resume duty")


def parse_ts(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return 0.0


def parse_probe(text):
    """Split the probe's `::key value` record from its delimited log section."""
    meta, loglines, in_log = {}, [], False
    for line in text.splitlines():
        if line == "::logstart":
            in_log = True
            continue
        if line == "::logend":
            in_log = False
            continue
        if in_log:
            loglines.append(line)
        elif line.startswith("::"):
            k, _, v = line[2:].partition(" ")
            meta[k] = v.strip()
    return meta, loglines


def last_tick_block(loglines):
    """Lines of the most recent `duty run start` block — the current work set."""
    start = None
    for i in range(len(loglines) - 1, -1, -1):
        if " duty run start" in loglines[i]:
            start = i
            break
    return loglines[start:] if start is not None else loglines[-40:]


def derive_queue(loglines):
    """Work the last tick actually detected, as {repo,key} chips."""
    q, seen = [], set()

    def add(repo, key):
        k = (repo, str(key))
        if k not in seen:
            seen.add(k)
            q.append({"repo": repo, "key": str(key)})

    for line in last_tick_block(loglines):
        for rx in RE_QUEUE:
            m = rx.search(line)
            if m:
                add(m.group(2), m.group(3))
        m = RE_REVIEW_BATCH.search(line)
        if m:
            for num in re.findall(r"#?(\d+)", m.group(3)):
                add(m.group(2), num)
        m = RE_BUILD_DUTY.search(line)
        if m:
            ready, owed = int(m.group(3)), int(m.group(4))
            for n in range(ready):
                add(m.group(2), "ready %d" % (n + 1))
            for n in range(owed):
                add(m.group(2), "round %d" % (n + 1))
        m = RE_TRIAGE.search(line)
        if m:
            add(m.group(2), m.group(3))
        m = RE_MENTION_BATCH.search(line)
        if m:
            add(None, "%s mentions" % m.group(2))
        m = RE_MENTION.search(line)
        if m:
            add(m.group(2), "%s mention" % m.group(3))
        m = RE_RESUME.search(line)
        if m:
            add(m.group(2), "resume")
    return q


def derive_sessions(loglines, now, clock_offset=0):
    """Finished sessions (newest first) and the open one, if any."""
    done, opens = [], []
    for line in loglines:
        m = RE_END.search(line)
        if m:
            try:
                reply = base64.b64decode(m.group(8) or "", validate=True).decode("utf-8", "replace")
            except (ValueError, TypeError):
                reply = ""
            done.append({
                "ts": parse_ts(m.group(1)) + clock_offset, "kind": m.group(2), "key": m.group(3),
                "rc": int(m.group(4)), "dur": int(m.group(5)), "out": m.group(6),
                "acted": m.group(7) or "unknown", "reply": reply,
            })
            if opens:
                opens.pop()
            continue
        m = RE_START.search(line)
        if m:
            opens.append({"ts": parse_ts(m.group(1)) + clock_offset,
                          "kind": m.group(2), "key": m.group(3)})

    done.sort(key=lambda s: s["ts"], reverse=True)
    for s in done:
        s["ago"] = max(0, int((now - s["ts"]) / 60))
    cur = None
    if opens:
        o = opens[-1]
        # A START with no END that predates the silence rule is a crashed or
        # killed session, not a running one — the box would have logged the END.
        if now - o["ts"] < 6 * 3600:
            cur = {"key": o["key"], "kind": o["kind"], "start": int(o["ts"])}
    return done, cur


def spark_24h(sessions, now):
    """22 buckets of session activity, matching the console's sparkline."""
    buckets = [0.0] * 22
    span = 24 * 3600.0
    for s in sessions:
        age = now - s["ts"]
        if 0 <= age < span:
            idx = 21 - int(age / span * 22)
            buckets[min(21, max(0, idx))] += 1
    peak = max(buckets) or 1.0
    return [round(0.06 + 0.94 * (b / peak), 3) for b in buckets]


def unit_defaults():
    """Every key a unit record carries, at its "nothing known yet" value.

    ONE definition, because there are two producers — build_unit below and the
    poller's probe-error path — and they used to spell the same dict out by
    hand. They drifted the moment a key was added: the error path shipped
    without `disarmed`, so a single box that threw during its probe made
    `wake-silent` raise KeyError for the WHOLE fleet, and the poll log with it.
    (It was also already missing `agent_actual`.)

    A hand-copied second skeleton is the same defect this PR is about — two
    readers holding private copies of one fact — one layer down. Adding the
    missing key would have fixed today's instance and left the next one.
    """
    return {
        "state": "offline", "engine": "", "integrity": "", "gh": "unknown", "vendor": "unknown",
        "queue": [], "sessions": [], "cur": None, "spark": [0.0] * 22,
        "up": {"h": 0, "m": 0}, "repo": "", "repos": [], "logs": [],
        "longest": 0, "avg": 0, "success": 0, "today": 0,
        "paused": False, "disarmed": False,
        "cron": {"ok": False, "last": None, "age": None},
        "lock": {"held": None, "stuck": False},
        "authfail": [], "ping": None,
        "note": "", "agent_actual": "",
        # HIRED — "yes" / "no" / "unknown", and never an inference from the
        # engine string. The page draws a console for what is DEPLOYED rather
        # than for what the roster DECLARES (#204), and that filter needs a
        # positive fact to fire on: `engine == ""` is true of a box that was
        # never created, a box that is down, a box that did not answer, and a
        # box that answered and has no engine — four different situations with
        # two different answers. Inferring the filter from silence is the #308
        # defect one reader over, so the collector — which already ranks those
        # four apart with its own early returns — publishes the verdict and the
        # page never re-derives it.
        #
        # "unknown" is the default because the two producers that never reach a
        # probe (a stopped box, and build_unit's exception path in the poller)
        # must land on the answer that KEEPS the console: a box whose hired
        # state cannot be measured is exactly the hired-and-gone-dark box this
        # page exists to show.
        "hired": "unknown",
    }


def build_unit(unit, state, agent_conf, now, inventory_ok=True):
    """Roster entry + live probe -> the record the page renders.

    `inventory_ok` is whether `box list` ANSWERED. It matters only where state
    is None, which that one call is the sole evidence for: a failed listing
    makes every box look absent, and #204's grid filter would then read a
    broken inventory as a fleet nobody ever hired and draw an empty floor.
    Absence has to be measured before it can hide anything.
    """
    u = dict(unit)
    u.update(unit_defaults())

    if state is None:
        if not inventory_ok:
            # `box list` could not be asked, so this box's absence is silence
            # rather than evidence, and `hired` stays "unknown" — the console
            # is kept and says why. Hiding here would be the exact inference
            # the verdict exists to refuse, on the one signal whose job is
            # noticing that something stopped answering.
            u["note"] = "box inventory unreadable — cannot tell what exists"
            return u
        # No box exists, so nothing was ever hired into it. This is a MEASURED
        # "no", not a fallback: `box list` answered and this name was not in it.
        u["hired"] = "no"
        u["note"] = "not created — crew new %s" % unit["box"]
        return u
    if state == "stopped":
        # Keeps "unknown": the box exists and nobody can ask it anything while
        # it is down. Hiring is not undone by `crew down`.
        u["note"] = "stopped — crew up starts it"
        return u

    raw, err = probe_box(unit, agent_conf)
    if raw is None:
        # Also "unknown", and this is the one that matters most: a box that
        # stopped answering is the hired-and-gone-dark case, and dropping its
        # console would hide the failure the floor is for.
        u["note"] = "unreachable: %s" % err
        return u

    meta, loglines = parse_probe(raw)
    u["engine"] = meta.get("engine", "")
    # The engine stamp's provenance, in #159's vocabulary: current, modified,
    # unverified, absent. Carried, never re-derived and never smoothed — the box
    # holds the files, so the box is the only thing that can hash them, and a
    # collector that turned an answer it did not like into a friendlier one
    # would be the "consistent, wrong data" failure described further down.
    # Empty means the box did not answer: an engine too old to ship the tool
    # still answers `unverified` (probe.sh's fallback), so "" is a probe that
    # could not run at all, and the page renders nothing rather than a verdict.
    u["integrity"] = meta.get("integrity", "")
    u["gh"] = meta.get("gh", "unknown")
    u["vendor"] = meta.get("vendor", "unknown")
    u["paused"] = meta.get("paused", "0") != "0"
    # DISARMED — no live `tick.sh` line in the crontab at all, which is a
    # different fact from "armed and not ticking" and needs a different action.
    # probe.sh has always emitted ::cron; nothing consumed it except a note on
    # the one path where a box has no log history whatsoever, so a box with
    # ticks behind it and cron since removed fell straight through to SILENT.
    #
    # `paused` is the same fact with a cause attached — the console's own Pause
    # comments the line out — so a paused box is BOTH, and `paused` wins the
    # note because "the operator did this, here is how to undo it" is the more
    # useful sentence. Kept as separate wire values rather than one tri-state:
    # a caller that means "can this box tick at all" must not have to know that
    # `paused` implies `disarmed`.
    u["disarmed"] = meta.get("cron", "0") == "0"
    # Both services, same shape. gh and the agent CLI fail independently and
    # are fixed by different commands, so they are never merged into one
    # "auth is bad" flag — the operator needs to know WHICH login to redo.
    # `nofail` means the box found no rejection; whether that amounts to
    # `flowing` depends on the engine having actually RUN recently, and that
    # threshold is SILENT_AFTER_S — the same one the SILENT rule uses, derived
    # once from TICK_S. The box deliberately ships ::tickage rather than a
    # verdict so this number exists in exactly one place.
    try:
        tick_age = int(meta.get("tickage") or -1)
    except (TypeError, ValueError):
        tick_age = -1
    fresh = 0 <= tick_age < SILENT_AFTER_S
    # WAITING — no tick has ever been observed, so there is no age to compare
    # against any threshold. `stale` is the wrong word here and it is wrong in
    # a costly direction: it means "we used to hear from this box and no longer
    # do", which is why the page renders it amber `~`. A box hired sixty seconds
    # ago has not stopped ticking; nobody has heard from it AT ALL. Telling an
    # operator their minute-old hire is stale, on a row whose every other column
    # says it is fine, is the same conflation #221 and #224 fix at the two
    # neighbouring call sites (#265).
    #
    # Not `unknown`: that value is reserved for a box with no engine, and
    # rehearsal-app.sh asserts no HIRED box ever reports it, on the grounds that
    # it leaves the operator nothing to act on. A never-ticked box is actionable
    # — the action is to wait one tick boundary — so it gets its own word.
    never_ticked = tick_age < 0
    for svc in ("gh", "vendor"):
        fail = meta.get("authfail-%s" % svc, "")
        if fail:
            u["authfail"].append("%s: %s" % (svc, fail))
        if u[svc] == "nofail":
            if never_ticked:
                u[svc] = "waiting"
            else:
                u[svc] = "flowing" if fresh else "stale"

    # A duty run is in flight and has held the lock this long. Absent means no
    # run is in flight — the common case between ticks, and not a fault.
    try:
        held = int(meta["lockheld"])
    except (KeyError, ValueError, TypeError):
        held = None
    if held is not None and held >= 0:
        u["lock"] = {"held": held, "stuck": held > STUCK_AFTER_S}
    u["repos"] = [r for r in meta.get("repos", "").split() if r]
    u["logs"] = [f for f in meta.get("sessionlogs", "").split() if f]
    try:
        up = int(meta.get("uptime") or 0)
        u["up"] = {"h": up // 3600, "m": (up % 3600) // 60}
    except ValueError:
        pass

    # The box ANSWERED — every "cannot tell" path returned above — so its
    # engine stamp is now evidence rather than silence, and this is the only
    # place the empty string is allowed to mean "not hired".
    u["hired"] = "yes" if u["engine"] else "no"
    if not u["engine"]:
        u["note"] = "not hired — crew hire %s" % unit["box"]

    # The roster DECLARES an agent; the box knows what it actually is. Those are
    # two different facts and were never compared, so a roster that named the
    # wrong agent made this page probe with the wrong vendor profile and report
    # the box auth-unhealthy — while every cross-reader assertion stayed green,
    # because `crew status` reads the same wrong column. Consistent, wrong data
    # is worse than an obvious error, and it is what let a generated drill
    # roster pin every box to "claude" without anything noticing.
    #
    # Ranked below "not hired" (no engine means no instance.conf to disagree
    # with) and above cron/paused/SILENT: a wrong profile invalidates the vendor
    # reading itself, so it is the thing to say first.
    u["agent_actual"] = meta.get("agent", "")
    if u["agent_actual"] and u["agent_actual"] != unit.get("agent"):
        u["note"] = u["note"] or (
            "roster says %s, box is installed as %s — the vendor probe is running "
            "the wrong profile" % (unit.get("agent"), u["agent_actual"]))

    # Cron liveness: probe.sh computes tick_age inside the box, where both
    # operands use the same clock. Log timestamps are still useful for ordering,
    # but must be translated onto the host timeline before the page ages them.
    last_ts = 0.0
    for line in reversed(loglines):
        m = RE_ANY_TS.match(line)
        if m:
            last_ts = parse_ts(m.group(1))
            break
    if last_ts and tick_age >= 0:
        u["cron"] = {
            "ok": tick_age < SILENT_AFTER_S and not u["paused"],
            "last": datetime.fromtimestamp(now - tick_age, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "age": tick_age,
        }
    elif meta.get("cron", "0") == "0":
        u["note"] = u["note"] or "no cron armed — crew hire %s" % unit["box"]

    clock_offset = (now - (last_ts + tick_age)) if last_ts and tick_age >= 0 else 0
    sessions, cur = derive_sessions(loglines, now, clock_offset)
    u["queue"] = derive_queue(loglines)
    u["cur"] = cur
    u["sessions"] = [{k: s[k] for k in ("ago", "kind", "key", "rc", "dur", "out", "acted", "reply")}
                     for s in sessions[:11]]
    u["spark"] = spark_24h(sessions, now)
    repo_fallback = ("crew" if u["queue"]
                     else (u["repos"][0] if u["repos"] else ""))
    u["repo"] = next((item["repo"] for item in u["queue"] if item["repo"]),
                     repo_fallback)

    if sessions:
        durs = [s["dur"] for s in sessions]
        ok = sum(1 for s in sessions if s["rc"] == 0)
        u["longest"] = max(durs)
        u["avg"] = round(sum(durs) / len(durs))
        u["success"] = round(100 * ok / len(sessions))
        u["today"] = sum(1 for s in sessions if now - s["ts"] < 86400)

    # The state the floor colours by. Order matters: a paused or silent box is
    # reported SILENT even if a stale session line suggests work, because the
    # thing that would have ended that session is exactly what is not running.
    if u["paused"]:
        u["state"] = "offline"
        u["note"] = u["note"] or "paused by operator — resume from the console"
    elif u["disarmed"]:
        # Disarmed OUTSIDE the console: `crew hire` before it arms, a box
        # disarmed by hand, and every drill box by design (drill/rehearsal.sh
        # disarms before any tick and aborts the run if it cannot). Ranked above
        # SILENT because it is the more specific claim and the actionable one:
        # SILENT says "this box should be ticking and is not", which is a real
        # alarm, and it must not be spent on a box nobody armed. Resume cannot
        # fix this — there is no commented line to uncomment — so the note names
        # the command that can.
        u["state"] = "offline"
        u["note"] = u["note"] or "disarmed — no cron line; crew hire %s arms it" % unit["box"]
    elif last_ts and u["cron"]["age"] is None:
        u["state"] = "offline"
        u["note"] = u["note"] or "tick age unknown — waiting for a valid probe"
    elif last_ts and not u["cron"]["ok"]:
        u["state"] = "offline"
        u["note"] = u["note"] or "SILENT — no tick for %s" % fmt_dur(u["cron"]["age"])
    elif u["authfail"]:
        # Ticking, answering, and unable to do any work — the engine tried and
        # was rejected. Not "offline": the box is fine and every control still
        # works, which is exactly why this needs saying out loud rather than
        # being inferred from a queue that quietly stopped moving.
        u["state"] = "idle"
        u["note"] = "AUTH BLOCKED — %s" % "; ".join(u["authfail"])
    elif u["lock"]["stuck"]:
        # Still "working": the box is alive, cron is ticking, and a session
        # genuinely is running — every one of those is true and none of them is
        # the point. The note OVERRIDES rather than defers, because a run stuck
        # past two tick boundaries is the most important thing about this box,
        # and the notes it would defer to describe a healthy one.
        u["state"] = "working"
        u["note"] = "STUCK — duty run has held the lock for %s" % fmt_dur(u["lock"]["held"])
    elif cur:
        u["state"] = "working"
    else:
        u["state"] = "idle"

    return u


def fmt_dur(s):
    if s is None:
        return "—"
    h, m = s // 3600, (s % 3600) // 60
    return "%dh %02dm" % (h, m) if h else ("%dm" % m if m else "%ds" % s)
