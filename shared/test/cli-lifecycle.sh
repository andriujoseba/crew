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
mkdir -p "$CONF" "$SHIM" "$STATE"
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
    if [[ "$script" == *'flock -n "$lock"'* ]]; then
      probe="$state_dir/probe-$name"
      value="${LIFE_PROBE_DEFAULT:-idle:0}"
      if [ -s "$probe" ]; then
        value="$(head -1 "$probe")"
        tail -n +2 "$probe" >"$probe.next"
        mv "$probe.next" "$probe"
      fi
      case "$value" in
        idle:*) printf 'idle 0\n' ;;
        busy:*) printf 'busy %s\n' "${value#busy:}" ;;
        *) printf 'unreadable -1\n' ;;
      esac
    elif [[ "$script" == *'df -Pk'* ]]; then
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
  : >"$STATE/calls"
}

run_crew() {
  env CREW_CONFIG_DIR="$CONF" LIFE_STATE="$STATE" \
    LIFE_PROBE_DEFAULT="${LIFE_PROBE_DEFAULT:-idle:0}" \
    LIFE_FORCE_HELP="${LIFE_FORCE_HELP:-yes}" \
    LIFE_DOWN_FAIL="${LIFE_DOWN_FAIL:-}" \
    LIFE_STOP_NOT_TAKE="${LIFE_STOP_NOT_TAKE:-}" \
    CREW_DRAIN_POLL_SECONDS=0 PATH="$SHIM:$PATH" bash "$CLI" "$@"
}

capture() {
  if OUT="$(run_crew "$@" 2>&1)"; then RC=0; else RC=$?; fi
}

reset_case
capture help restart
case "$OUT" in *'usage: crew restart <box>... | --all [--force-after <hours>]'*'stop that does not take is never followed by a start'*) r1=complete ;; *) r1="$OUT" ;; esac
t lifecycle-help-renders-table-and-detail complete "$r1"
capture help
case "$OUT" in *'3  restart completed partially because one or more busy boxes were skipped'*) r1=documented ;; *) r1="$OUT" ;; esac
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
printf 'busy:60\n' >"$STATE/probe-alpha"
capture restart alpha
t lifecycle-busy-restart-has-skip-status 3 "$RC"
case "$OUT" in *'alpha: SKIPPED busy'*'skipped: alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-busy-restart-is-named named "$r1"
t lifecycle-busy-restart-never-stops 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"

reset_case
printf 'unreadable\n' >"$STATE/probe-alpha"
capture restart alpha
t lifecycle-unreadable-is-busy-skip 3 "$RC"
t lifecycle-unreadable-never-stops 0 "$(grep -c '^down alpha' "$STATE/calls" || true)"

reset_case
printf 'busy:3601\n' >"$STATE/probe-alpha"
capture restart alpha --force-after 1
t lifecycle-force-after-restarts 0 "$RC"
case "$OUT" in *'force-after reached; restarting'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-force-after-is-announced named "$r1"

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
t lifecycle-down-waits-then-completes 0 "$RC"
case "$OUT" in *'alpha: waiting for duty lock held 1m'*'crew down --force'*'down: 2 stopped, 1 waited'*) r1=loud ;; *) r1="$OUT" ;; esac
t lifecycle-down-wait-is-loud loud "$r1"
t lifecycle-plain-down-never-forces 0 "$(grep -c -- '--force' "$STATE/calls" || true)"

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
case "$OUT" in *'down FAILED on alpha'*'down: 1 stopped'*'1 failed'*) r1=named ;; *) r1="$OUT" ;; esac
t lifecycle-partial-down-is-named named "$r1"
unset LIFE_DOWN_FAIL

suite_finish
