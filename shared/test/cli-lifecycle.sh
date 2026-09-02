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
mkdir -p "$CONF" "$SHIM" "$STATE" "$STATE/guests" "$PROBE_BIN" "$NO_FLOCK_BIN"
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
    printf '[{"status":"%s"}]\n' "$state"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SHIM/box"

reset_case() {
  find "$STATE" -mindepth 1 -maxdepth 1 -type f -delete
  find "$STATE/guests" -mindepth 1 -delete
  : >"$STATE/calls"
}

run_crew() {
  env CREW_CONFIG_DIR="$CONF" LIFE_STATE="$STATE" \
    LIFE_PROBE_DEFAULT="${LIFE_PROBE_DEFAULT:-idle:0}" \
    LIFE_FORCE_HELP="${LIFE_FORCE_HELP:-yes}" \
    LIFE_DOWN_FAIL="${LIFE_DOWN_FAIL:-}" \
    LIFE_STOP_NOT_TAKE="${LIFE_STOP_NOT_TAKE:-}" \
    LIFE_READY_FAILS="${LIFE_READY_FAILS:-0}" \
    LIFE_PROBE_BIN="$PROBE_BIN" LIFE_NO_FLOCK_BIN="$NO_FLOCK_BIN" \
    CREW_DRAIN_POLL_SECONDS=0 CREW_RESTART_READY_POLL_SECONDS=0 \
    CREW_RESTART_READY_ATTEMPTS=3 PATH="$SHIM:$PATH" bash "$CLI" "$@"
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

suite_finish
