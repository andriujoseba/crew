#!/usr/bin/env bash
# Offline contract suite for crew restart/down. The real verbs run unchanged;
# only the host-owned box CLI/control channel is replaced.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
CLI="$ROOT/cli/crew"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
CONF="$TMP/conf"
SHIM="$TMP/shim"
STATE="$TMP/state"
PROBE_BIN="$TMP/probe-bin"
NO_FLOCK_BIN="$TMP/no-flock-bin"
# #590. The host maintenance lock and job log are HOST state, so they must be
# pointed somewhere disposable or this suite writes into the machine's real
# ~/.local/state — and two suites exercising the two scheduled verbs would then
# contend for one real lock and skip each other's runs.
HOSTSTATE="$TMP/host-state"
HOSTLOG="$HOSTSTATE/host-maintenance.log"
HOSTLOCK="$HOSTSTATE/.host-maintenance.lock"
# A PATH carrying the box shim and the tools crew reaches before need_flock,
# and deliberately NOT flock: the refusal to run unlocked is a contract, and a
# fixture cannot assert it while the real flock is reachable.
NO_HOST_FLOCK_BIN="$TMP/no-host-flock-bin"
mkdir -p "$CONF" "$SHIM" "$STATE" "$STATE/guests" "$PROBE_BIN" "$NO_FLOCK_BIN" \
  "$HOSTSTATE" "$NO_HOST_FLOCK_BIN"
for host_tool in bash env readlink dirname basename head tail sed awk grep tr cat \
                 cut sort mkdir wc mv rm date sleep find ln chmod id uname; do
  host_tool_path="$(command -v "$host_tool" 2>/dev/null)" || continue
  ln -sf "$host_tool_path" "$NO_HOST_FLOCK_BIN/$host_tool"
done
ln -s "$(command -v cat)" "$PROBE_BIN/cat"
ln -s "$(command -v cat)" "$NO_FLOCK_BIN/cat"
cat >"$PROBE_BIN/date" <<'EOF'
#!/bin/bash
printf '%s\n' "${LIFE_NOW:-10000}"
EOF
cp "$PROBE_BIN/date" "$NO_FLOCK_BIN/date"
cat >"$PROBE_BIN/flock" <<'EOF'
#!/bin/bash
exit "${LIFE_FLOCK_RC:-0}"
EOF
chmod +x "$PROBE_BIN/date" "$PROBE_BIN/flock" "$NO_FLOCK_BIN/date"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$CONF/"
cat >"$CONF/fleet.roster" <<'EOF'
alpha claude builder
beta codex reviewer
EOF

# A COMPLETE fleet definition whose roster names nobody — the nothing-to-do
# case (#590 D2), and it has to be a real definition rather than a missing file
# so that resolution succeeds and the run reaches the job log to say so.
CONF_EMPTY="$TMP/conf-empty"
mkdir -p "$CONF_EMPTY"
cp "$CONF/fleet.conf" "$CONF/repos.txt" "$CONF/notify-repos.txt" \
  "$CONF/doctrine.conf" "$CONF_EMPTY/"
cat >"$CONF_EMPTY/fleet.roster" <<'EOF'
# every row a comment: a roster that names no box
EOF

cat >"$SHIM/box" <<'EOF'
#!/usr/bin/env bash
set -u
state_dir="$LIFE_STATE"
calls="$state_dir/calls"
cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    if [ "${1:-}" = --json ]; then
      printf '[{"name":"alpha"},{"name":"beta"},{"name":"offroster"}]\n'
    else
      printf 'NAME\nalpha\nbeta\noffroster\n'
    fi
    ;;
  exec)
    name="$1"; shift
    script="${*: -1}"
    current="running"
    [ ! -s "$state_dir/state-$name" ] || current="$(cat "$state_dir/state-$name")"
    [ "$current" != stopped ] || exit 1
    if [[ "$script" == *'flock -n "$lock"'* ]]; then
      probe="$state_dir/probe-$name"
      value="${LIFE_PROBE_DEFAULT:-idle:0}"
      if [ -s "$probe" ]; then
        value="$(head -1 "$probe")"
        tail -n +2 "$probe" >"$probe.next"
        mv "$probe.next" "$probe"
      fi
      guest_home="$state_dir/guests/$name"
      mkdir -p "$guest_home/duty"
      rm -f "$guest_home/duty/.duty.lock.since"
      case "$value" in
        idle:*) probe_path="$LIFE_PROBE_BIN"; probe_rc=0 ;;
        busy:*)
          probe_path="$LIFE_PROBE_BIN"; probe_rc=1
          printf '%s\n' "$((10000 - ${value#busy:}))" >"$guest_home/duty/.duty.lock.since"
          ;;
        since:*)
          probe_path="$LIFE_PROBE_BIN"; probe_rc=1
          printf '%s\n' "${value#since:}" >"$guest_home/duty/.duty.lock.since"
          ;;
        no-flock) probe_path="$LIFE_NO_FLOCK_BIN"; probe_rc=0 ;;
        flock-error) probe_path="$LIFE_PROBE_BIN"; probe_rc=2 ;;
        stop-during-probe)
          printf 'stopped\n' >"$state_dir/state-$name"
          exit 1
          ;;
        transport|unreadable) exit 1 ;;
        empty) exit 0 ;;
        *) exit 2 ;;
      esac
      probe_output="$(env HOME="$guest_home" PATH="$probe_path" LIFE_FLOCK_RC="$probe_rc" LIFE_NOW=10000 \
        /bin/bash -c "$script")"
      printf '%s\n' "$probe_output" >"$state_dir/probe-result-$name"
      printf '%s\n' "$probe_output"
    elif [[ "$script" == *'df -Pk'* ]]; then
      printf 'free-probe %s\n' "$name" >>"$calls"
      ready_file="$state_dir/ready-fails-$name"
      if [ -f "$state_dir/started-$name" ] && [ -s "$ready_file" ]; then
        remaining="$(cat "$ready_file")"
        if [ "$remaining" -gt 0 ]; then
          printf '%s\n' "$((remaining - 1))" >"$ready_file"
          exit 1
        fi
      fi
      if [ -f "$state_dir/started-$name" ]; then free=1200; else free=1000; fi
      # The stub stands at the box transport boundary, so it returns what the
      # complete remote pipeline prints, not df's intermediate table.
      printf '%s\n' "$free"
    elif [[ "$script" == *'duty-snapshot.*'* ]]; then
      printf 'cleanup %s\n' "$name" >>"$calls"
    else
      exit 2
    fi
    ;;
  down)
    if [ "${1:-}" = --help ]; then
      [ "${LIFE_FORCE_HELP:-yes}" = yes ] && printf 'usage: box down <box> [--force]\n'
      exit 0
    fi
    name="$1"; shift || true
    printf 'down %s%s\n' "$name" "${1:+ $1}" >>"$calls"
    if [ "$name" = "${LIFE_DOWN_FAIL:-}" ]; then exit 1; fi
    if [ "$name" != "${LIFE_STOP_NOT_TAKE:-}" ]; then printf 'stopped\n' >"$state_dir/state-$name"; fi
    ;;
  start)
    name="$1"
    printf 'start %s\n' "$name" >>"$calls"
    printf 'running\n' >"$state_dir/state-$name"
    : >"$state_dir/started-$name"
    printf '%s\n' "${LIFE_READY_FAILS:-0}" >"$state_dir/ready-fails-$name"
    ;;
  info)
    name="$1"
    state="running"; [ ! -s "$state_dir/state-$name" ] || state="$(cat "$state_dir/state-$name")"
    # The resource keys ride the same passthrough the real `box info --json`
    # is: `incus list --format json`, config and devices verbatim. Empty
    # LIFE_BOX_RESOURCES is the box that answers about its status and nothing
    # else, which is what #607 D5's note has to survive without inventing a
    # figure.
    # A box that cannot be read AT ALL is a different answer from one that
    # answers without resource keys, and it reaches a different line of the
    # reader — the shell fallback rather than jq's own defaults.
    [ "${LIFE_BOX_RESOURCES:-}" != unreadable ] || exit 1
    if [ -n "${LIFE_BOX_RESOURCES:-}" ]; then
      IFS='|' read -r r_cpu r_mem r_disk <<<"$LIFE_BOX_RESOURCES"
      printf '[{"status":"%s","expanded_config":{"limits.cpu":"%s","limits.memory":"%s"},"expanded_devices":{"root":{"type":"disk","size":"%s"}}}]\n' \
        "$state" "$r_cpu" "$r_mem" "$r_disk"
    else
      printf '[{"status":"%s"}]\n' "$state"
    fi
    ;;
  new)
    # `box new --help` is the capability probe's whole input (#607 D5). The
    # sentence WRAPS in box's real help output and it is reproduced wrapped
    # here on purpose: a probe that matched line-by-line would pass a fixture
    # that joined it and fail against the box an operator actually has.
    if [ "${1:-}" = --help ]; then
      case "${LIFE_CLONE_SIZING:-yes}" in
        yes)
          printf 'usage: box new --name <box> [--from <src>[/<snap>]]\n'
          printf 'Named sizes select fresh-mint bundles. A --from clone instead accepts the\n'
          printf 'explicit --cpu/--memory/--disk flags (#171). They ride the copy itself.\n' ;;
        old)
          printf 'usage: box new --name <box> [--from <src>[/<snap>]]\n'
          printf -- '--cpu/--memory/--disk shape a fresh mint; a clone carries its source resources.\n' ;;
        *) exit 2 ;;
      esac
      exit 0
    fi
    printf 'new %s\n' "$*" >>"$calls"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SHIM/box"

reset_case() {
  find "$STATE" -mindepth 1 -maxdepth 1 -type f -delete
  find "$STATE/guests" -mindepth 1 -delete
  : >"$STATE/calls"
  # The job log is per-case evidence, so it starts empty; the lock file itself
  # is left alone, because a case that HOLDS it does so across this call.
  rm -f "$HOSTLOG" "$HOSTLOG.1" "$HOSTLOCK.holder"
}

job_log() { cat "$HOSTLOG" 2>/dev/null || true; }

# A job log already past HOST_JOB_LOG_MAX, carrying one marker line so the
# generation it ends up in can be named. A REAL oversized file rather than a
# tuned threshold: 5 MiB is tick.sh's number, hardcoded there and here for the
# same reason, and a fixture that moved it would be asserting against a knob
# that does not exist on the host. 6 MiB of one repeated byte costs a second
# and no correctness.
big_host_log() { # MARKER
  printf '%s\n' "$1" >"$HOSTLOG"
  head -c $((6 * 1024 * 1024)) /dev/zero | tr '\0' 'p' >>"$HOSTLOG"
  printf '\n' >>"$HOSTLOG"
}

# Hold the host maintenance lock the way a running job holds it: an open fd
# with flock on it, released when the fd closes. Not a lock FILE — the file
# always exists, and a fixture that created one and called that "held" would
# pass against a crew that never locked anything.
hold_host_lock() {
  exec {HOLDFD}>>"$HOSTLOCK"
  flock -n "$HOLDFD"
}
release_host_lock() { exec {HOLDFD}>&-; }

run_crew() {
  env CREW_CONFIG_DIR="${LIFE_CONF:-$CONF}" CREW_HOST_STATE_DIR="$HOSTSTATE" \
    LIFE_STATE="$STATE" \
    LIFE_PROBE_DEFAULT="${LIFE_PROBE_DEFAULT:-idle:0}" \
    LIFE_FORCE_HELP="${LIFE_FORCE_HELP:-yes}" \
    LIFE_DOWN_FAIL="${LIFE_DOWN_FAIL:-}" \
    LIFE_STOP_NOT_TAKE="${LIFE_STOP_NOT_TAKE:-}" \
    LIFE_READY_FAILS="${LIFE_READY_FAILS:-0}" \
    LIFE_CLONE_SIZING="${LIFE_CLONE_SIZING:-yes}" \
    LIFE_BOX_RESOURCES="${LIFE_BOX_RESOURCES:-}" \
    LIFE_PROBE_BIN="$PROBE_BIN" LIFE_NO_FLOCK_BIN="$NO_FLOCK_BIN" \
    CREW_DRAIN_POLL_SECONDS=0 CREW_RESTART_READY_POLL_SECONDS=0 \
    CREW_RESTART_READY_ATTEMPTS=3 PATH="${LIFE_PATH:-$SHIM:$PATH}" bash "$CLI" "$@"
}

capture() {
  if OUT="$(run_crew "$@" 2>&1)"; then RC=0; else RC=$?; fi
}

reset_case
capture help restart
case "$OUT" in *'usage: crew restart <box>... | --all [--force-after <hours>]'*'only when a valid continuous lock age is available'*'stop that does not take is never followed by a start'*) r1=complete ;; *) r1="$OUT" ;; esac
t lifecycle-help-renders-table-and-detail complete "$r1"
capture help
case "$OUT" in *'3  lifecycle work completed after a busy restart skip or a down drain wait'*) r1=documented ;; *) r1="$OUT" ;; esac
t lifecycle-help-documents-skip-status documented "$r1"

reset_case
capture restart alpha
t lifecycle-idle-restart-exits-zero 0 "$RC"
t lifecycle-idle-restart-stops-then-starts $'down alpha\nstart alpha' \
  "$(grep -E '^(down|start) alpha' "$STATE/calls")"
t lifecycle-idle-restart-cleans-before-stop 1 "$(grep -c '^cleanup alpha$' "$STATE/calls")"
case "$OUT" in *'free 1000 → 1200 KiB (delta +200 KiB)'*) r1=reported ;; *) r1="$OUT" ;; esac
t lifecycle-idle-restart-reports-space-delta reported "$r1"

reset_case
LIFE_READY_FAILS=2 capture restart alpha
t lifecycle-restart-waits-for-guest-readiness 0 "$RC"
t lifecycle-restart-retries-post-start-probe 4 "$(grep -c '^free-probe alpha$' "$STATE/calls")"
unset LIFE_READY_FAILS

reset_case
LIFE_READY_FAILS=5 capture restart alpha
t lifecycle-restart-readiness-timeout-is-failure 1 "$RC"
case "$OUT" in *'guest stayed unreachable after 3 probes'*'box shell alpha'*) r1=actionable ;; *) r1="$OUT" ;; esac
t lifecycle-restart-readiness-timeout-is-actionable actionable "$r1"
unset LIFE_READY_FAILS

reset_case
printf 'stopped\n' >"$STATE/state-alpha"
capture restart alpha
t lifecycle-stopped-restart-starts-without-drain 0 "$RC"
t lifecycle-stopped-restart-does-not-stop-again 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"
t lifecycle-stopped-restart-starts 1 "$(grep -c '^start alpha$' "$STATE/calls")"
t lifecycle-stopped-restart-cleans-after-start 1 "$(grep -c '^cleanup alpha$' "$STATE/calls")"
case "$OUT" in *'alpha: already stopped; starting'*'started from stopped'*) r1=accurate ;; *) r1="$OUT" ;; esac
t lifecycle-stopped-restart-pins-precheck-wording accurate "$r1"

reset_case
printf 'busy:60\n' >"$STATE/probe-alpha"
capture restart alpha
t lifecycle-busy-restart-has-skip-status 3 "$RC"
case "$OUT" in *'alpha: SKIPPED busy'*'skipped: alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-busy-restart-is-named named "$r1"
t lifecycle-busy-restart-never-stops 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"

for unreadable_mode in no-flock flock-error transport empty; do
  reset_case
  printf '%s\n' "$unreadable_mode" >"$STATE/probe-alpha"
  capture restart alpha
  t "lifecycle-$unreadable_mode-is-busy-skip" 3 "$RC"
  t "lifecycle-$unreadable_mode-never-stops" 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"
done

reset_case
printf 'busy:3601\n' >"$STATE/probe-alpha"
capture restart alpha --force-after 1
t lifecycle-force-after-restarts 0 "$RC"
case "$OUT" in *'force-after reached; restarting'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-force-after-is-announced named "$r1"

for invalid_since in 18446744073709551617 10002; do
  reset_case
  printf 'since:%s\n' "$invalid_since" >"$STATE/probe-alpha"
  capture restart alpha --force-after 1
  t "lifecycle-invalid-since-$invalid_since-is-busy-skip" 3 "$RC"
  case "$OUT" in *'SKIPPED busy — duty lock age unavailable'*) r1=unavailable ;; *) r1="$OUT" ;; esac
  t "lifecycle-invalid-since-$invalid_since-age-is-unavailable" unavailable "$r1"
  t "lifecycle-invalid-since-$invalid_since-probe-normalizes-age" 'busy -1' \
    "$(cat "$STATE/probe-result-alpha")"
  t "lifecycle-invalid-since-$invalid_since-never-cycles" 0 "$(grep -cE '^(down|start) alpha' "$STATE/calls" || true)"
done

reset_case
printf 'busy:3601\n' >"$STATE/probe-alpha"
capture restart alpha --force-after 08
t lifecycle-force-after-leading-zero-is-decimal 3 "$RC"
t lifecycle-force-after-leading-zero-does-not-cycle 0 "$(grep -cE '^(down|start) alpha' "$STATE/calls" || true)"

reset_case
capture restart alpha --force-after 00
t lifecycle-force-after-zero-spelling-refuses 2 "$RC"
t lifecycle-force-after-zero-spelling-mutates-nothing 0 "$(grep -cE '^(down|start) ' "$STATE/calls" || true)"

reset_case
capture restart alpha --force-after 99999999999999999999
t lifecycle-force-after-over-range-refuses 2 "$RC"
t lifecycle-force-after-over-range-mutates-nothing 0 "$(grep -cE '^(down|start) ' "$STATE/calls" || true)"

reset_case
LIFE_STOP_NOT_TAKE=alpha capture restart alpha
t lifecycle-stop-not-taken-is-failure 1 "$RC"
t lifecycle-stop-not-taken-never-starts 0 "$(grep -c '^start alpha' "$STATE/calls" || true)"
case "$OUT" in *'stop did not take'*'NOT starting'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-stop-not-taken-is-named named "$r1"
unset LIFE_STOP_NOT_TAKE

reset_case
capture restart --all
t lifecycle-all-restarts-roster 2 "$(grep -c '^start ' "$STATE/calls")"
t lifecycle-all-leaves-offroster 0 "$(grep -c 'offroster' "$STATE/calls" || true)"

reset_case
printf 'busy:65\nidle:0\n' >"$STATE/probe-alpha"
capture down
t lifecycle-down-waits-then-completes-with-wait-status 3 "$RC"
case "$OUT" in *'alpha: waiting for duty lock held 1m'*'crew down --force'*'down: 2 stopped, 1 waited'*) r1=loud ;; *) r1="$OUT" ;; esac
t lifecycle-down-wait-is-loud loud "$r1"
t lifecycle-plain-down-never-forces 0 "$(grep -c -- '--force' "$STATE/calls" || true)"

reset_case
printf 'stopped\n' >"$STATE/state-alpha"
capture down
t lifecycle-down-already-stopped-terminates 0 "$RC"
t lifecycle-down-already-stopped-does-not-call-down 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"
t lifecycle-down-continues-after-stopped-box 1 "$(grep -c '^down beta' "$STATE/calls")"

reset_case
printf 'stop-during-probe\n' >"$STATE/probe-alpha"
capture down
t lifecycle-down-stopped-during-probe-terminates 0 "$RC"
t lifecycle-down-stopped-during-probe-does-not-call-down 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"

reset_case
printf 'stop-during-probe\n' >"$STATE/probe-alpha"
capture restart alpha
t lifecycle-restart-stopped-during-probe-starts 0 "$RC"
t lifecycle-restart-stopped-during-probe-does-not-stop 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"
t lifecycle-restart-stopped-during-probe-calls-start 1 "$(grep -c '^start alpha$' "$STATE/calls")"

reset_case
LIFE_FORCE_HELP=no capture down --force
t lifecycle-old-box-force-refuses 1 "$RC"
case "$OUT" in *'requires box 0.10.0 or later'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-old-box-force-names-requirement named "$r1"
t lifecycle-old-box-force-mutates-nothing 0 "$(grep -c '^down ' "$STATE/calls" || true)"
unset LIFE_FORCE_HELP

reset_case
capture down --force
t lifecycle-force-down-exits-zero 0 "$RC"
t lifecycle-force-down-uses-box-feature 2 "$(grep -cE '^down (alpha|beta) --force$' "$STATE/calls")"
t lifecycle-force-down-skips-drain 0 "$(grep -c '^cleanup ' "$STATE/calls" || true)"

reset_case
LIFE_DOWN_FAIL=alpha capture down
t lifecycle-partial-down-is-nonzero 1 "$RC"
case "$OUT" in *'down FAILED on alpha (stop command failed)'*'down: 1 stopped'*'1 failed'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-partial-down-is-named named "$r1"
case "$OUT" in *'(state: failed)'*) r1="$OUT" ;; *) r1=hidden ;; esac
t lifecycle-partial-down-hides-internal-sentinel hidden "$r1"
unset LIFE_DOWN_FAIL

# --- #590: the host schedule, its lock, its log and its exit statuses --------
#
# THE SUBJECT IS THE UNATTENDED CALLER. Everything above asserts what the verbs
# do to boxes; these assert what they leave behind for somebody who was asleep
# when they ran. They live in THIS suite rather than a third one because it is
# the suite `crew restart` already has, and the daily line is `crew restart`.

# D1 — the example file. The charter is checkable by reading it, so read it:
# a cron line that grew its own flock or its own redirect is the exact drift
# shared/crontab.example was written to end, and it would arrive as a helpful
# edit rather than as a mistake anybody argued for.
HOST_CRONTAB="$ROOT/shared/host-crontab.example"
host_cron_lines="$(grep -vE '^[[:space:]]*(#|$)' "$HOST_CRONTAB" || true)"
t hostcron-example-exists yes "$([ -f "$HOST_CRONTAB" ] && echo yes || echo no)"
t hostcron-has-exactly-two-job-lines 2 \
  "$(printf '%s\n' "$host_cron_lines" | grep -c '[^[:space:]]' || true)"
t hostcron-no-flock-in-any-line 0 \
  "$(printf '%s\n' "$host_cron_lines" | grep -c 'flock' || true)"
t hostcron-no-redirect-in-any-line 0 \
  "$(printf '%s\n' "$host_cron_lines" | grep -c '[>|]' || true)"
t hostcron-daily-line-is-restart-all 1 \
  "$(printf '%s\n' "$host_cron_lines" | grep -cE '^[0-9]+ [0-9]+ \* \* \* .*crew restart --all$' || true)"
t hostcron-weekly-line-is-reset-all 1 \
  "$(printf '%s\n' "$host_cron_lines" | grep -cE '^[0-9]+ [0-9]+ \* \* [0-6] .*crew reset --all$' || true)"
# The weekly line inherits #589's refusal and must never be handed a way past
# it: --force on the scheduled reset is the silent fleet-wide downgrade D4
# exists to prevent, and it would arrive here as a one-word edit.
t hostcron-weekly-line-carries-no-force 0 \
  "$(printf '%s\n' "$host_cron_lines" | grep -c -- '--force' || true)"

capture help
case "$OUT" in *'4  nothing was attempted'*) r1=documented ;; *) r1="$OUT" ;; esac
t hostjob-help-documents-nothing-to-do documented "$r1"
capture help restart
case "$OUT" in *'host maintenance lock'*) r1=documented ;; *) r1="$OUT" ;; esac
t hostjob-restart-help-names-the-lock documented "$r1"

# D2 — a run that did nothing still says so, at both boundaries. This is the
# whole point of the log: silence at a boundary has to mean cron is dead, and
# it cannot mean that if a quiet run is also silent.
reset_case
LIFE_CONF="$CONF_EMPTY" capture restart --all
t hostjob-empty-roster-is-nothing-to-do 4 "$RC"
case "$OUT" in *'restart: no box selected — nothing to do'*) r1=said ;; *) r1="$OUT" ;; esac
t hostjob-empty-roster-says-so said "$r1"
case "$(job_log)" in
  *'restart run start'*'restart: no box selected'*'restart run end: nothing to do (exit 4)'*) r1=logged ;;
  *) r1="$(job_log)" ;;
esac
t hostjob-empty-roster-writes-both-boundaries logged "$r1"
t hostjob-empty-roster-touches-no-box 0 "$(grep -cE '^(down|start|cleanup) ' "$STATE/calls" || true)"

# D2 — a skipped box is NAMED in the log rather than omitted, and the boundary
# line carries the status a cron mail would have shown.
reset_case
printf 'busy:60\n' >"$STATE/probe-alpha"
capture restart --all
t hostjob-busy-run-exits-skipped-busy 3 "$RC"
case "$(job_log)" in
  *'restart run start'*'alpha: SKIPPED busy'*'skipped: alpha'*'restart run end: some boxes SKIPPED busy (exit 3)'*) r1=complete ;;
  *) r1="$(job_log)" ;;
esac
t hostjob-log-names-the-skipped-box complete "$r1"

# D2 — a failing run reaches the log too, and its boundary line does not claim
# the run succeeded.
reset_case
LIFE_STOP_NOT_TAKE=alpha capture restart alpha
t hostjob-failed-run-exits-one 1 "$RC"
case "$(job_log)" in
  *'restart FAILED on alpha'*'restart run end: a box FAILED or was REFUSED (exit 1)'*) r1=logged ;;
  *) r1="$(job_log)" ;;
esac
t hostjob-log-carries-the-failure logged "$r1"
unset LIFE_STOP_NOT_TAKE

# D3 — the exit status is what a cron mail is read off, so the four outcomes
# must be four numbers. Asserted TOGETHER and in one line, because the property
# is distinctness: three separate assertions all pass on a verb that returns
# the same code for two different things.
reset_case; capture restart alpha; rc_ok=$RC
reset_case; printf 'busy:60\n' >"$STATE/probe-alpha"; capture restart alpha; rc_busy=$RC
reset_case; LIFE_STOP_NOT_TAKE=alpha capture restart alpha; rc_failed=$RC
unset LIFE_STOP_NOT_TAKE
reset_case; LIFE_CONF="$CONF_EMPTY" capture restart --all; rc_none=$RC
t hostjob-four-outcomes-are-four-statuses '0 3 1 4' \
  "$rc_ok $rc_busy $rc_failed $rc_none"

# D3 — the host lock. A second job started while the first holds it does not
# run, and says which job holds it.
reset_case
hold_host_lock
printf '%s reset 4242\n' "$(( $(date +%s) - 42 ))" >"$HOSTLOCK.holder"
capture restart --all
release_host_lock
t hostjob-lock-held-exits-nothing-to-do 4 "$RC"
# The seconds are not pinned — the age is computed against a real clock at run
# time, and an exact match would be a flake waiting for a slow runner.
case "$OUT" in
  *"SKIPPED — the host maintenance lock is held by 'crew reset' (running "*", pid 4242)"*"no box was touched"*) r1=named ;;
  *) r1="$OUT" ;;
esac
t hostjob-lock-held-names-the-holder named "$r1"
t hostjob-lock-held-touches-no-box 0 "$(grep -cE '^(down|start|cleanup) ' "$STATE/calls" || true)"
case "$(job_log)" in
  *"restart run skipped: the host maintenance lock is held by 'crew reset'"*) r1=logged ;;
  *) r1="$(job_log)" ;;
esac
t hostjob-lock-held-logs-the-skip logged "$r1"
# A run that never started must not claim it did: `run start` in the log is the
# line every reader uses to say cron fired AND the job ran.
case "$(job_log)" in *'run start'*) r1="$(job_log)" ;; *) r1=absent ;; esac
t hostjob-lock-held-writes-no-start-line absent "$r1"

# D3 — the holder is reported from a record, so an absent or malformed record
# must read as "I do not know" and never as a name. Sending an operator to look
# at a job that was not running is worse than saying nothing.
for holder_record in '' 'not-a-timestamp reset 1'; do
  reset_case
  hold_host_lock
  if [ -n "$holder_record" ]; then printf '%s\n' "$holder_record" >"$HOSTLOCK.holder"; fi
  capture restart --all
  release_host_lock
  t "hostjob-unknown-holder-still-skips-[${holder_record:-empty}]" 4 "$RC"
  case "$OUT" in *'its holder record is missing or unreadable'*) r1=honest ;; *) r1="$OUT" ;; esac
  t "hostjob-unknown-holder-does-not-guess-[${holder_record:-empty}]" honest "$r1"
done

# The green case from the test plan: two jobs colliding produce ONE run and ONE
# skip line — and the lock is released by the holder going away, not by a
# timeout, so the fleet is not wedged until somebody notices.
reset_case
hold_host_lock
printf '%s reset 4242\n' "$(date +%s)" >"$HOSTLOCK.holder"
capture restart alpha
rc_blocked=$RC
release_host_lock
capture restart alpha
t hostjob-collision-then-release '4 0' "$rc_blocked $RC"
t hostjob-collision-logs-one-skip 1 "$(grep -c 'run skipped:' "$HOSTLOG" || true)"
t hostjob-collision-logs-one-start 1 "$(grep -c 'run start' "$HOSTLOG" || true)"
t hostjob-collision-cycles-the-box-once 1 "$(grep -c '^start alpha$' "$STATE/calls" || true)"

# D2 — ROTATION BELONGS TO THE HOLDER. The evidence contract is that one run's
# start, output and end are readable together; a contender that rotated the log
# it does not own would split the run in flight across two generations, because
# `tee -a` holds the inode and host_job_log reopens by name. A reader of either
# generation then sees a start with no end — the one shape this log reserves for
# cron itself being dead.
#
# First the holder's side, so "nobody rotates" cannot pass this block: an
# oversized log IS cut, and the whole of the run that cut it is on the near side
# of the cut, with the previous generation's marker on the far side.
reset_case
big_host_log MARKER-previous-generation
capture restart alpha
gen_new="$(job_log)"
# Read the old generation's head, not the whole 6 MiB of it.
gen_old="$(head -c 120 "$HOSTLOG.1" 2>/dev/null || true)"
r1="start=$(grep -c 'run start' <<<"$gen_new" || true)"
r1="$r1 end=$(grep -c 'run end' <<<"$gen_new" || true)"
r1="$r1 box=$(grep -c 'alpha: restarted' <<<"$gen_new" || true)"
r1="$r1 marker=$(grep -c MARKER-previous-generation <<<"$gen_new" || true)"
t hostjob-rotate-holder-keeps-its-run-in-one-generation \
  'start=1 end=1 box=1 marker=0' "$r1"
# 'cut' quoted: bare, shellcheck reads the assignment as the cut(1) command.
case "$gen_old" in MARKER-previous-generation*) r1='cut' ;; *) r1="${gen_old:0:80}" ;; esac
t hostjob-rotate-holder-cuts-the-old-generation cut "$r1"

# Then the contender's: the lock is held, the log is oversized, and this
# invocation is not entitled to rotate it. The marker stands for the holder's
# in-flight evidence — it must not move — and no generation may be cut at all.
reset_case
big_host_log MARKER-in-flight
hold_host_lock
printf '%s reset 4242\n' "$(date +%s)" >"$HOSTLOCK.holder"
capture restart alpha
rc_blocked=$RC
release_host_lock
r1="rc=$rc_blocked"
r1="$r1 marker=$(grep -c MARKER-in-flight "$HOSTLOG" || true)"
r1="$r1 rotated=$([ -e "$HOSTLOG.1" ] && echo 1 || echo 0)"
r1="$r1 skip=$(grep -c 'run skipped:' "$HOSTLOG" || true)"
t hostjob-rotate-contender-rotates-nothing \
  'rc=4 marker=1 rotated=0 skip=1' "$r1"

# A lock that cannot be taken is not a lock. Without flock on PATH the verb
# REFUSES rather than running unlocked — the fail-open here is a weekly reset
# rolling a fleet back underneath a restart that is mid-cycle.
reset_case
LIFE_PATH="$SHIM:$NO_HOST_FLOCK_BIN" capture restart --all
t hostjob-no-flock-refuses 1 "$RC"
case "$OUT" in *"needs 'flock'"*'refuses rather than'*) r1=named ;; *) r1="$OUT" ;; esac
t hostjob-no-flock-names-why named "$r1"
t hostjob-no-flock-touches-no-box 0 "$(grep -cE '^(down|start|cleanup) ' "$STATE/calls" || true)"

# A rejected invocation takes no fleet-wide lock and writes no boundary line:
# it is not a run, and a `run start` for a typo'd flag would make the log lie
# about how often the schedule fired.
reset_case
capture restart alpha --force-after 00
t hostjob-usage-error-still-exits-two 2 "$RC"
t hostjob-usage-error-writes-no-log '' "$(job_log)"

# --- `crew new` sizes the box it mints (#607) -------------------------------
# Asserted at the box transport boundary — the argv crew hands `box new` — for
# the reason every other case in this suite is: the sizing a role gets is a
# statement crew makes to the host, and it is the whole of crew's half of it.
# A test that minted a real box would prove the same thing about incus.
#
# Its own fleet definition, so the roster rows these cases need do not enter
# the --all iterations above and shift their counts.
CONF_NEW="$TMP/conf-new"
mkdir -p "$CONF_NEW"
cp "$CONF/fleet.conf" "$CONF/repos.txt" "$CONF/notify-repos.txt" \
  "$CONF/doctrine.conf" "$CONF_NEW/"
cat >"$CONF_NEW/fleet.roster" <<'EOF'
gamma claude reviewer
delta claude reviewer goldbox/gold
epsilon claude builder
EOF

# The criterion in the issue's own words: a reviewer roster line with no 4th
# column produces a box at 4 vCPU / 8GiB / 60GiB. Read out of reviewer.conf at
# run time and not pinned here, so this case follows the conf it is about.
read -r EXP_CPU EXP_MEM EXP_DISK <<<"$(
  bash -c '. "$1"; printf "%s %s %s\n" "$BOX_CPU" "$BOX_MEMORY" "$BOX_DISK"' \
    _ "$SHARED/conf/roles/reviewer.conf")"

reset_case
LIFE_CONF="$CONF_NEW" capture new gamma
t new-fresh-mint-exits-zero 0 "$RC"
t new-fresh-mint-carries-the-role-size \
  "new --name gamma --template claude-box --cpu $EXP_CPU --memory $EXP_MEM --disk $EXP_DISK" \
  "$(grep '^new ' "$STATE/calls")"
t new-fresh-mint-is-the-reviewer-at-builder-parity \
  "new --name gamma --template claude-box --cpu 4 --memory 8GiB --disk 60GiB" \
  "$(grep '^new ' "$STATE/calls")"

# D5, the half that lands — and it lands in TWO figures, not three. box 0.10.0
# takes --cpu and --memory on a copy unconditionally, but --disk only where the
# SOURCE has a root device of its own: a VM whose root is profile-inherited, or
# a source box cannot read, makes it refuse and die before `incus copy`, so
# nothing is created at all. crew therefore never passes --disk on this path.
# Triage ruled it on #607 (2026-09-03): no branch of this fix may turn a roster
# line that mints today into one that does not.
#
# The exact argv IS the assertion. A `--disk` creeping back in is invisible to
# every other test here and kills every gold-snapshot roster line on the first
# host whose gold predates box's own `--device root,size=` mints.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_RESOURCES="$EXP_CPU|$EXP_MEM|30GiB" capture new delta
t new-clone-sized-exits-zero 0 "$RC"
t new-clone-sized-carries-cpu-and-memory-only \
  "new --name delta --from goldbox/gold --cpu $EXP_CPU --memory $EXP_MEM" \
  "$(grep '^new ' "$STATE/calls")"
t new-clone-sized-passes-no-disk 0 \
  "$(grep -c -- '--disk' <<<"$(grep '^new ' "$STATE/calls")" || true)"
# A PARTIAL landing is a legitimate outcome and must be said out loud (#607
# criterion 5 as amended) — so the sized branch reports too, per figure, and
# the figure that did not ride is named as not applied rather than omitted.
t new-clone-sized-still-reports-one-line 1 "$(grep -c '^note: ' <<<"$OUT" || true)"
note_line="$(grep '^note: ' <<<"$OUT" || true)"
t new-clone-sized-reports-cpu-applied 1 \
  "$(grep -cF 'cpu applied' <<<"$note_line" || true)"
t new-clone-sized-reports-memory-applied 1 \
  "$(grep -cF 'memory applied' <<<"$note_line" || true)"
t new-clone-sized-reports-disk-not-applied 1 \
  "$(grep -cF 'disk NOT applied' <<<"$note_line" || true)"
t new-clone-sized-names-the-carried-disk 1 \
  "$(grep -cF "carries $EXP_CPU cpu / $EXP_MEM / 30GiB" <<<"$note_line" || true)"

# D5, the half that cannot: an older box refuses the flags on a copy outright,
# so the clone is made unsized — passing them would kill every gold-snapshot
# roster line, which is the #590 defect — and ONE line names the box, all three
# verdicts, and both sizes.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=old LIFE_BOX_RESOURCES='2|4GiB|30GiB' \
  capture new delta
t new-clone-unsized-exits-zero 0 "$RC"
t new-clone-unsized-passes-no-sizing-flags "new --name delta --from goldbox/gold" \
  "$(grep '^new ' "$STATE/calls")"
t new-clone-unsized-note-is-one-line 1 "$(grep -c '^note: ' <<<"$OUT" || true)"
note_line="$(grep '^note: ' <<<"$OUT" || true)"
for needle in delta 'carries 2 cpu / 4GiB / 30GiB' \
              "profile asks $EXP_CPU cpu / $EXP_MEM / $EXP_DISK" \
              'cpu NOT applied' 'memory NOT applied' 'disk NOT applied'; do
  t "new-clone-unsized-note-names-${needle// /-}" 1 \
    "$(grep -cF "$needle" <<<"$note_line" || true)"
done
# Nothing crew did not ask for is ever reported as applied — the whole line's
# worth is that "applied" means verified.
t new-clone-unsized-claims-nothing-applied 0 \
  "$(grep -cE '(cpu|memory|disk) applied' <<<"$note_line" || true)"
# ...and the route the line hands the operator repairs EVERY figure it renders
# a verdict for. This is the branch where all three read NOT applied, so a
# route missing one is a figure the operator is told about and cannot fix.
# Memory is the figure #607 exists over — codex-reviewer died with exit 137 —
# and it was the one the first cut of this line omitted (round 1).
t new-clone-unsized-route-repairs-cpu 1 \
  "$(grep -cF "limits.cpu $EXP_CPU" <<<"$note_line" || true)"
t new-clone-unsized-route-repairs-memory 1 \
  "$(grep -cF "limits.memory $EXP_MEM" <<<"$note_line" || true)"
t new-clone-unsized-route-repairs-disk 1 \
  "$(grep -cF "root size=$EXP_DISK" <<<"$note_line" || true)"

# The probe fails CLOSED. A box whose help cannot be read at all is treated as
# one that cannot size a clone: the cost of guessing wrong that way is this
# note, and the cost of guessing wrong the other way is a `crew new` that dies
# on a roster line that worked yesterday.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=broken LIFE_BOX_RESOURCES='2|4GiB|30GiB' \
  capture new delta
t new-clone-unreadable-help-does-not-size "new --name delta --from goldbox/gold" \
  "$(grep '^new ' "$STATE/calls")"
t new-clone-unreadable-help-still-reports 1 "$(grep -c '^note: ' <<<"$OUT" || true)"

# A figure that does not read says so. The alternative — printing the profile's
# own numbers, or nothing — is a note that states as fact something crew never
# read off the daemon.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=old capture new delta
t new-clone-unreadable-resources-are-not-invented 1 \
  "$(grep -c 'carries ? cpu / ? / ?' <<<"$OUT" || true)"

# ...and the same answer when the box cannot be read at all, which is a
# different line of the reader: jq's defaults answer the first case, the
# shell's the second, and only one of them runs per case.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_CLONE_SIZING=old LIFE_BOX_RESOURCES=unreadable \
  capture new delta
t new-clone-unreadable-box-still-reports-one-line 1 "$(grep -c '^note: ' <<<"$OUT" || true)"
t new-clone-unreadable-box-invents-nothing 1 \
  "$(grep -c 'carries ? cpu / ? / ?' <<<"$OUT" || true)"

# An unreadable figure on a flag crew DID pass is "unverified" and never
# "applied": the sized branch asked for cpu and memory, and a daemon that will
# not say what the box carries has not confirmed they landed.
reset_case
LIFE_CONF="$CONF_NEW" LIFE_BOX_RESOURCES=unreadable capture new delta
t new-clone-sized-unreadable-is-unverified 1 \
  "$(grep -cF 'cpu unverified, memory unverified' <<<"$OUT" || true)"
t new-clone-sized-unreadable-claims-nothing-applied 0 \
  "$(grep -cE '(cpu|memory|disk) applied' <<<"$OUT" || true)"

# The builder is untouched by all of this and mints at its own figures — the
# parity is reviewer→builder, not a new tier for both.
reset_case
LIFE_CONF="$CONF_NEW" capture new epsilon
t new-builder-mint-unchanged \
  "new --name epsilon --template claude-box --cpu 4 --memory 8GiB --disk 60GiB" \
  "$(grep '^new ' "$STATE/calls")"

suite_finish
