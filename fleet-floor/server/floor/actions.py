"""Operator control (#39): the scripts fired into a box, and the dispatcher.

`floor_message_prompt` lives here rather than beside the paths it reads: the
envelope exists for exactly one caller, the `message` action below.
"""

import os
import uuid
from concurrent.futures import ThreadPoolExecutor

from floor import FLOOR_ENVELOPE
from floor.ping import log, run
from floor.roster import box_states, read_roster

ACTION_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_ACTION_TIMEOUT", "120"))
# Fleet-wide controls share the host with evidence and heartbeat fan-outs.
# Eight is a no-op for today's seven-member roster and a hard ceiling as the
# single-role fleet grows.
ACTION_WORKERS = 8


def force_stop_argv(box):
    """The host command that stops a guest which cannot stop itself (#486).

    Every stop the floor could fire was graceful: `box down` is `incus stop`
    with neither `--force` nor a timeout, so against a guest that can no
    longer schedule its own shutdown it runs out ACTION_TIMEOUT_S and the
    action reports failure. The one box state that needs stopping was the one
    state the console could not stop.

    Deliberately box's own non-interactive incus passthrough and NOT a new
    `box down --force`: heavy-duty/box#11's ownership rule puts that flag
    outside box, so this carries no cross-repo dependency (D2). One definition
    because two call sites fire it — the `force-stop` action and restart's
    recovery — and a second spelling is a second thing to keep in step.
    """
    return ["box", "incus", box, "--", "stop", "--force"]


def floor_message_prompt(operator_text):
    """Wrap an operator message in the shared one-shot environment contract."""
    try:
        with open(FLOOR_ENVELOPE, encoding="utf-8") as src:
            envelope = src.read()
    except OSError as exc:
        raise RuntimeError("floor message envelope unavailable: %s" % exc) from exc
    if not envelope:
        raise RuntimeError("floor message envelope is empty: %s" % FLOOR_ENVELOPE)
    return envelope + operator_text


# --------------------------------------------------------------------------
# operator control  (#39)
# --------------------------------------------------------------------------

# Fired into the box with `box exec`; the box initiates nothing.
#
# Each script states its own verdict on the last line and exits deliberately.
# It used to end on a bare `grep -c`, and `grep -c` exits 1 when it counts
# zero — so the count WAS the exit status, and a box with no armed `tick.sh`
# line reported the same rc 1 as a box that could not be reached. `in_box`
# read that as ok=False, `do_command` answered 500, and the console rendered
# it "command refused" (#188). Nothing was refusing: a count of zero was
# being reported as a failure, which is #176's shape — "nothing to do" and
# "it went wrong" collapsed into one status.
#
# Three outcomes, three answers: `paused N` (it took effect), `nothing to
# pause: ...` (rc 0, there was nothing armed), and a non-zero exit whose
# stderr says why. The counts travel as data on stdout; only a real failure
# is allowed to redden the row. Each write is checked on its own exit status
# rather than inferred from a later read, so a `crontab -` that refuses is
# named as the failure it is.
#
# N is the number of lines THIS call moved, not the number of lines now in
# the target state: a box carrying a `#CREW-FLOOR-PAUSED` line from an
# earlier pause, plus one armed line, pauses one line and says `paused 1`.
# Reporting the post-state total would say `paused 2` — an overcount on a
# control plane whose whole subject is saying what it actually did.
#
# That is also why the crontab is read ONCE, into `cron`, and the write is
# fed from that snapshot rather than from a second `crontab -l`: the counts
# and the text being rewritten are then the same crontab, so the delta check
# below means what it says. It costs one read rather than adding one.
PAUSE_SH = r"""
cron="$(crontab -l 2>/dev/null || true)"
armed="$(printf '%s\n' "$cron" | grep -cE '^[^#].*tick\.sh' || true)"
[ "$armed" -gt 0 ] || { echo "nothing to pause: no armed tick.sh line"; exit 0; }
was="$(printf '%s\n' "$cron" | grep -c '^#CREW-FLOOR-PAUSED' || true)"
printf '%s\n' "$cron" | sed -E 's|^([^#].*tick\.sh.*)$|#CREW-FLOOR-PAUSED \1|' | crontab - \
  || { echo "pause: crontab write failed" >&2; exit 1; }
now="$(crontab -l 2>/dev/null | grep -c '^#CREW-FLOOR-PAUSED' || true)"
[ "$(( now - was ))" -eq "$armed" ] \
  || { echo "pause: crontab write reported success, $(( now - was )) of $armed lines are commented" >&2; exit 1; }
echo "paused $armed"
"""

RESUME_SH = r"""
cron="$(crontab -l 2>/dev/null || true)"
paused="$(printf '%s\n' "$cron" | grep -c '^#CREW-FLOOR-PAUSED' || true)"
[ "$paused" -gt 0 ] || { echo "nothing to resume: no paused tick.sh line"; exit 0; }
was="$(printf '%s\n' "$cron" | grep -cE '^[^#].*tick\.sh' || true)"
printf '%s\n' "$cron" | sed -E 's|^#CREW-FLOOR-PAUSED ||' | crontab - \
  || { echo "resume: crontab write failed" >&2; exit 1; }
now="$(crontab -l 2>/dev/null | grep -cE '^[^#].*tick\.sh' || true)"
[ "$(( now - was ))" -eq "$paused" ] \
  || { echo "resume: crontab write reported success, $(( now - was )) of $paused lines are live" >&2; exit 1; }
echo "resumed $paused"
"""

# The operator's message becomes a real session of the box's own vendor CLI,
# detached so the HTTP request does not hold a model run open, and logged where
# every other session logs so it shows up in the console's history.
MESSAGE_SH = r"""
set -u
# Every path here is per-invocation. They used to be fixed names, and the
# server is threaded: two rapid messages to one box interleaved as
#   write prompt A -> launch A -> write prompt B -> A reads .floor-prompt
# and session A ran prompt B. An operator's instruction executed with someone
# else's text, on a real box. Same-second sessions also collided on the log
# name. __TOK__ is a uuid4 hex minted per request by the collector.
tok="__TOK__"
conf="/tmp/.crew-floor-agent.$tok.conf"
pf="${DUTY_DIR:-$HOME/duty}/.floor-prompt.$tok"
cat >"$conf"
# shellcheck disable=SC1090
source "$conf"
export PATH="${BOT_PATH_PREPEND:-$HOME/.local/bin}:$PATH"
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
mkdir -p "$DUTY_DIR/logs"
# Read ONCE, here, and hand the bytes to the detached shell as an argument.
# The re-read inside that shell was the race: it resolved the path long after
# this request had returned.
prompt="$(cat "$pf")"
rm -f "$pf"
[ -n "$prompt" ] || { echo "empty prompt"; rm -f "$conf"; exit 2; }
ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
slog="$DUTY_DIR/logs/$(date -u '+%Y%m%dT%H%M%SZ')-operator-floor-$tok.log"
# One O_APPEND write under 4K is atomic, so this cannot interleave with a
# tick's own line even though the operator session runs outside the duty flock.
printf '%s SESSION START kind=operator key=floor timeout=1800s log=%s\n' "$ts" "$slog" >>"$DUTY_DIR/duty.log"
nohup setsid bash -c '
  DUTY_DIR="'"$DUTY_DIR"'"; slog="'"$slog"'"; conf="'"$conf"'"
  start=$SECONDS; rc=0
  source "$conf"; rm -f "$conf"
  export PATH="${BOT_PATH_PREPEND:-$HOME/.local/bin}:$PATH"
  cd "$HOME"
  timeout -k 60 1800 "${BOT_CLI_CMD[@]}" "$1" </dev/null >"$slog" 2>&1 || rc=$?
  dur=$((SECONDS - start)); v=ok; acted=unknown
  [ "$rc" -eq 124 ] && v=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && v=FAILED
  if declare -F bot_session_acted >/dev/null 2>&1; then
    bot_session_acted "$slog" && arc=0 || arc=$?
    case "$arc" in 0) acted=yes;; 1) acted=no;; esac
  fi
  reply_tail="$(awk '\''NF { line=$0 } END { printf "%s", substr(line, 1, 200) }'\'' "$slog" 2>/dev/null | base64 | tr -d '\''\n'\'')"
  printf "%s SESSION END kind=operator key=floor rc=%s dur=%ss outcome=%s acted=%s reply_tail=%s\n" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$dur" "$v" "$acted" "$reply_tail" >>"$DUTY_DIR/duty.log"
' _ "$prompt" </dev/null >/dev/null 2>&1 &
echo "session started; log $slog"
"""


def do_command(fleet, body):
    """Apply one operator action. Returns (http_status, result dict)."""
    action = str(body.get("action", ""))
    box = str(body.get("box", ""))

    roster = {u["box"]: u for u in read_roster()}
    fleet_wide = {"start-all", "stop-all", "wake-silent"}

    if action not in fleet_wide:
        if box not in roster:
            return 400, {"ok": False, "error": "unknown box %r" % box}

    def one(name, argv, timeout=ACTION_TIMEOUT_S, stdin_data=None, step=None):
        rc, out, err = run(argv, timeout, stdin_data)
        ok = rc == 0
        # `step` names WHICH call this row is, for the actions that now have
        # more than one shape: restart reaches its box gracefully or by force
        # depending on whether the box still answers, and "the action records
        # what it did" is worthless if the record cannot say which (#486 D4).
        # Additive and only where a caller passes one, so every row this
        # module wrote before carries exactly the keys it carried before.
        log("%s %s%s -> rc %d" % (action, name, " (%s)" % step if step else "", rc))
        row = {"box": name, "ok": ok, "out": (out or err).strip()[-400:]}
        if step:
            row["step"] = step
        return row

    def in_box(name, script, stdin_data=None):
        return one(name, ["box", "exec", name, "--", "bash", "-lc", script],
                   stdin_data=stdin_data)

    def agent_conf_for(name):
        return fleet.agent_conf(roster[name]["agent"])

    def concurrently(tasks):
        """Run per-box calls together and return results in submission order."""
        if not tasks:
            return []
        with ThreadPoolExecutor(max_workers=min(len(tasks), ACTION_WORKERS)) as pool:
            futures = [pool.submit(fn, *args) for fn, args in tasks]
            return [future.result() for future in futures]

    def done(result):
        """Make an already-known per-box result fit a concurrent task list."""
        return result

    results = []

    if action == "message":
        prompt = str(body.get("prompt", "")).strip()
        if not prompt:
            return 400, {"ok": False, "error": "empty prompt"}
        if len(prompt) > 8000:
            return 400, {"ok": False, "error": "prompt too long"}
        try:
            prompt = floor_message_prompt(prompt)
        except RuntimeError as exc:
            return 500, {"ok": False, "error": str(exc)}
        # Two hops so the prompt is never interpolated into a shell string:
        # it travels as stdin bytes, and the session reads it from a file.
        # The filename carries a per-request token: with one fixed name, two
        # rapid messages to the same box raced and a session could run the
        # OTHER request's prompt.
        token = uuid.uuid4().hex
        w = one(box, ["box", "exec", box, "--", "bash", "-lc",
                      'mkdir -p "$HOME/duty" && cat > "$HOME/duty/.floor-prompt.%s"' % token],
                stdin_data=prompt)
        if not w["ok"]:
            results.append(w)
        else:
            results.append(in_box(box, MESSAGE_SH.replace("__TOK__", token),
                                  stdin_data=agent_conf_for(box)))

    elif action == "pause":
        results.append(in_box(box, PAUSE_SH))
    elif action == "resume":
        results.append(in_box(box, RESUME_SH))
    elif action == "restart":
        # Force-then-start recovery WHEN THE BOX IS UNREACHABLE, and only then
        # (#486 D3). A box that still answers is restarted exactly as it was
        # before this branch existed — `box down`, then `box start` — because
        # a restart that quietly became a kill is the escalation D1 refuses,
        # one verb over.
        #
        # The predicate is the ping tier's own wedge rule, asked of the fleet
        # rather than re-derived here: what the console paints UNREACHABLE and
        # what this escalates on have to be one fact, or an operator meets two
        # answers about the same box mid-incident.
        if fleet.box_unreachable(box):
            results.append(one(box, force_stop_argv(box), step="force-stop"))
        else:
            results.append(one(box, ["box", "down", box], step="down"))
        results.append(one(box, ["box", "start", box], step="start"))
    elif action == "force-stop":
        # ITS OWN ACTION, never an escalation from a graceful one (#486 D1):
        # an operator who fired Power off must not discover it became a kill.
        # That is also why nothing here checks reachability first — force is
        # what was asked for, and a control that second-guessed the operator
        # would be as surprising in the other direction.
        results.append(one(box, force_stop_argv(box), step="force-stop"))
    elif action == "power-off":
        results.append(one(box, ["box", "down", box]))
    elif action == "power-on":
        results.append(one(box, ["box", "start", box]))
    elif action in ("start-all", "stop-all"):
        verb = "start" if action == "start-all" else "down"
        states = box_states()
        tasks = []
        for name in roster:
            st = states.get(name)
            if st is None:
                # A roster line with no box yet is inventory drift, not a refusal:
                # `fleet.roster` is the TARGET fleet and deliberately names boxes
                # `crew up` has not created. `ok: None` keeps the box named in the
                # per-box detail while excluding it from the pass/fail verdict, so
                # the whole action does not read failed mid-migration (#77).
                tasks.append((done, ({"box": name, "ok": None, "out": "not created"},)))
                continue
            if (verb == "start") == (st == "stopped"):
                tasks.append((one, (name, ["box", verb, name])))
            else:
                tasks.append((done, ({"box": name, "ok": True,
                                      "out": "already %s" % st},)))
        results = concurrently(tasks)
    elif action == "wake-silent":
        # A silent box is one cron is not ticking for. Waking it means resuming
        # the crontab and, if it is stopped, starting it — not a model session.
        states = box_states()
        tasks = []
        for u in fleet.get()["units"]:
            if u["state"] != "offline":
                continue
            # A box that is disarmed WITHOUT being paused has no commented line
            # for RESUME_SH to restore, so waking it is not a thing this action
            # can do — arming is `crew hire`, on the host. It used to be sent
            # RESUME_SH anyway and reported as a failed row, which made
            # wake-silent read as broken on any fleet holding an unarmed box.
            #
            # The `not paused` half is load-bearing: pausing comments the line
            # out, so a paused box reports cron=0 and is disarmed too — and it
            # is exactly the box this action exists to wake.
            if u["disarmed"] and not u["paused"]:
                continue
            name = u["box"]
            if states.get(name) == "stopped":
                tasks.append((one, (name, ["box", "start", name])))
            elif states.get(name) is not None:
                tasks.append((in_box, (name, RESUME_SH)))
        results = concurrently(tasks)
    else:
        return 400, {"ok": False, "error": "unknown action %r" % action}

    # An action with nothing to do is not a failure: `wake-silent` on a fleet
    # with no silent boxes had `results == []`, which read as ok=False and 500.
    # Only `message`-class actions, which must produce a result, stay strict.
    # An action that did everything it COULD is not a failure either: a row with
    # `ok is None` (a not-yet-created box) is inventory drift, not a refusal, so
    # it is excluded from the verdict — 500 is reserved for a box that was there
    # and refused. All rows still travel in `results`, absent ones included.
    ok = all(r["ok"] for r in results if r["ok"] is not None)
    # A control action changes exactly what the page is displaying, so refresh
    # rather than leaving the operator to guess whether it took. Coalesced, so
    # a burst of clicks cannot become a burst of fleet-wide probe storms.
    fleet.request_refresh()
    return (200 if ok else 500), {"ok": ok, "action": action, "results": results}
