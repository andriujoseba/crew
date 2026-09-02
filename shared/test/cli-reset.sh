#!/usr/bin/env bash
# Offline contract suite for `crew reset` — the `armed` checkpoint (#589).
# The real verb runs unchanged; only the host-owned box CLI/control channel is
# replaced, exactly as cli-lifecycle.sh does for restart/down.
#
# THE ORDERING TEST IS THE ONE THAT NEEDED DESIGNING. D7's whole content is
# "reclaim, then measure, then decide", and an assertion that merely watches
# both calls happen would pass on the inverted order too. So the stub makes the
# box's disk reading DEPEND on the sweep: `df` answers RST_PCT_BEFORE until
# reap-now.sh has run against that box and RST_PCT_AFTER afterwards. A cut that
# measured first would read 95% and refuse the box this suite proves is cut —
# the fixture cannot pass with the steps the other way round.
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
mkdir -p "$CONF" "$SHIM" "$STATE" "$STATE/guests" "$PROBE_BIN"
ln -s "$(command -v cat)" "$PROBE_BIN/cat"
cat >"$PROBE_BIN/date" <<'EOF'
#!/bin/bash
printf '%s\n' "${RST_NOW:-10000}"
EOF
cat >"$PROBE_BIN/flock" <<'EOF'
#!/bin/bash
exit "${RST_FLOCK_RC:-0}"
EOF
chmod +x "$PROBE_BIN/date" "$PROBE_BIN/flock"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" \
  "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$CONF/"
cat >"$CONF/fleet.roster" <<'EOF'
alpha claude builder
beta codex reviewer
EOF

cat >"$SHIM/box" <<'SHIMEOF'
#!/usr/bin/env bash
set -u
state_dir="$RST_STATE"
calls="$state_dir/calls"
snaps_of() { cat "$state_dir/snaps-$1" 2>/dev/null; }
cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    if [ "${1:-}" = --json ]; then
      printf '[{"name":"alpha"},{"name":"beta"},{"name":"offroster"}]\n'
    else
      printf 'NAME\nalpha\nbeta\noffroster\n'
    fi
    ;;
  info)
    name="$1"; shift || true
    state="running"
    [ ! -s "$state_dir/state-$name" ] || state="$(cat "$state_dir/state-$name")"
    if [ "${1:-}" = --json ]; then
      printf '[{"name":"%s","status":"%s","state":{"status":"%s"}}]\n' "$name" "$state" "$state"
      exit 0
    fi
    printf 'info %s\n' "$name" >>"$calls"
    # A listing crew cannot read at all — D4's third value. Deliberately NOT
    # an empty SNAPSHOTS block: the point is that "I could not look" must not
    # score the same as "I looked and there is none".
    if [ "$name" = "${RST_INFO_BROKEN:-}" ]; then
      printf 'NAME       %s\nSTATE      %s\n' "$name" "$state"
      exit 0
    fi
    printf 'NAME       %s\nSTATE      %s\nTYPE       vm\n\n' "$name" "$state"
    if [ -s "$state_dir/snaps-$name" ]; then
      printf 'SNAPSHOTS\n'
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        printf '  %-14s%s\n' "$s" "2026-09-02T00:00Z"
      done <"$state_dir/snaps-$name"
      printf '\n'
      printf 'Clone one:  box new --name <new> --from %s/armed\n' "$name"
    else
      printf 'SNAPSHOTS  (none)\n\n'
      printf 'Take one:   box snapshot %s authed\n' "$name"
    fi
    ;;
  snapshot)
    name="$1"; label="${2:-}"
    printf 'snapshot %s %s\n' "$name" "$label" >>"$calls"
    if [ "$name" = "${RST_SNAPSHOT_FAIL:-}" ]; then exit 1; fi
    # incus refuses a label that already exists; the real thing does too, and
    # the re-cut path is only correct because it deletes first.
    if grep -qx -- "$label" <<<"$(snaps_of "$name")"; then
      echo "Error: snapshot \"$label\" already exists" >&2; exit 1
    fi
    printf '%s\n' "$label" >>"$state_dir/snaps-$name"
    printf '%s\n' "$label"
    ;;
  restore)
    name="$1"; label="${2:-}"
    printf 'restore %s %s%s\n' "$name" "$label" "${3:+ $3}" >>"$calls"
    if [ "$name" = "${RST_RESTORE_FAIL:-}" ]; then exit 1; fi
    grep -qx -- "$label" <<<"$(snaps_of "$name")" || { echo "Error: no snapshot $label" >&2; exit 1; }
    ;;
  incus)
    name="$1"; shift
    [ "${1:-}" != -- ] || shift
    printf 'incus %s %s\n' "$name" "$*" >>"$calls"
    case "${1:-} ${2:-}" in
      "snapshot delete")
        label="${4:-}"
        if [ "$name" = "${RST_SNAPDEL_FAIL:-}" ]; then exit 1; fi
        grep -vx -- "$label" "$state_dir/snaps-$name" >"$state_dir/snaps-$name.n" 2>/dev/null
        mv "$state_dir/snaps-$name.n" "$state_dir/snaps-$name"
        ;;
      *) exit 2 ;;
    esac
    ;;
  down)
    name="$1"; shift || true
    printf 'down %s%s\n' "$name" "${1:+ $1}" >>"$calls"
    if [ "$name" = "${RST_DOWN_FAIL:-}" ]; then exit 1; fi
    if [ "$name" != "${RST_STOP_NOT_TAKE:-}" ]; then printf 'stopped\n' >"$state_dir/state-$name"; fi
    ;;
  start)
    name="$1"
    printf 'start %s\n' "$name" >>"$calls"
    if [ "$name" = "${RST_START_FAIL:-}" ]; then exit 1; fi
    printf 'running\n' >"$state_dir/state-$name"
    ;;
  new)
    printf 'new %s\n' "$*" >>"$calls"
    ;;
  exec)
    name="$1"; shift
    script="${*: -1}"
    current="running"
    [ ! -s "$state_dir/state-$name" ] || current="$(cat "$state_dir/state-$name")"
    [ "$current" != stopped ] || exit 1
    if [[ "$script" == *'flock -n "$lock"'* ]]; then
      probe="$state_dir/probe-$name"
      value="${RST_PROBE_DEFAULT:-idle:0}"
      if [ -s "$probe" ]; then
        value="$(head -1 "$probe")"
        tail -n +2 "$probe" >"$probe.next"
        mv "$probe.next" "$probe"
      fi
      guest_home="$state_dir/guests/$name"
      mkdir -p "$guest_home/duty"
      rm -f "$guest_home/duty/.duty.lock.since"
      case "$value" in
        idle:*) probe_rc=0 ;;
        busy:*)
          probe_rc=1
          printf '%s\n' "$((10000 - ${value#busy:}))" >"$guest_home/duty/.duty.lock.since"
          ;;
        unreadable) exit 1 ;;
        *) exit 2 ;;
      esac
      env HOME="$guest_home" PATH="$RST_PROBE_BIN" RST_FLOCK_RC="$probe_rc" RST_NOW=10000 \
        /bin/bash -c "$script"
    elif [[ "$script" == *'gh auth status'* ]]; then
      printf 'login-probe %s\n' "$name" >>"$calls"
      case " ${RST_LOGGED_IN:-} " in *" $name "*) exit 0 ;; *) exit 1 ;; esac
    elif [[ "$script" == *'engine-manifest.sh'* ]]; then
      printf 'engine-probe %s\n' "$name" >>"$calls"
      stamp_var="RST_STAMP_$name"
      stamp="${!stamp_var:-}"
      if [ -z "$stamp" ]; then
        printf 'state=absent\nstamp=\nrecorded=\n'
      else
        printf 'state=current\nstamp=crew@%s\nrecorded=crew@%s\n' "$stamp" "$stamp"
      fi
    elif [[ "$script" == *'reap-now.sh'* ]]; then
      printf 'reap %s\n' "$name" >>"$calls"
      if [ "$name" = "${RST_REAP_FAIL:-}" ]; then
        echo "reap-now.sh: a duty tick holds .duty.lock — nothing run" >&2
        exit 199
      fi
      : >"$state_dir/reaped-$name"
      echo "reaper: transcripts reclaimed 12345 bytes in 3 files"
    elif [[ "$script" == *'df -Pk /'* ]]; then
      printf 'root-df %s\n' "$name" >>"$calls"
      # THE ORDERING FIXTURE: the reading depends on the sweep having run.
      if [ -f "$state_dir/reaped-$name" ]; then
        printf '%s%%\n' "${RST_PCT_AFTER:-40}"
      else
        printf '%s%%\n' "${RST_PCT_BEFORE:-40}"
      fi
    elif [[ "$script" == *'du -shx'* ]]; then
      printf 'large-probe %s\n' "$name" >>"$calls"
      [ -n "${RST_LARGE:-}" ] || exit 1
      printf '%s\n' "$RST_LARGE"
    elif [[ "$script" == *'df -Pk'* ]]; then
      printf 'free-probe %s\n' "$name" >>"$calls"
      printf '1200\n'
    elif [[ "$script" == *'crontab -l'* ]]; then
      exit 1
    else
      # The upgrade path's staging and install execs. Logged rather than
      # matched one by one: this suite's subject is the checkpoint mark the
      # upgrade leaves behind, not the transport #159 already covers.
      printf 'exec %s\n' "$name" >>"$calls"
    fi
    ;;
  *) exit 2 ;;
esac
SHIMEOF
chmod +x "$SHIM/box"

reset_case() {
  find "$STATE" -mindepth 1 -maxdepth 1 -type f -delete
  find "$STATE/guests" -mindepth 1 -delete 2>/dev/null
  rm -rf "$CONF/checkpoints"
  : >"$STATE/calls"
}

run_crew() {
  env CREW_CONFIG_DIR="$CONF" RST_STATE="$STATE" RST_PROBE_BIN="$PROBE_BIN" \
    RST_PROBE_DEFAULT="${RST_PROBE_DEFAULT:-idle:0}" \
    RST_LOGGED_IN="${RST_LOGGED_IN:-alpha beta}" \
    RST_STAMP_alpha="${RST_STAMP_alpha-0.1.3}" RST_STAMP_beta="${RST_STAMP_beta-0.1.3}" \
    RST_PCT_BEFORE="${RST_PCT_BEFORE:-40}" RST_PCT_AFTER="${RST_PCT_AFTER:-40}" \
    RST_LARGE="${RST_LARGE-13G /swapfile;13G /swapfile-drill;19G /var;6.9G /home;}" \
    RST_INFO_BROKEN="${RST_INFO_BROKEN:-}" RST_REAP_FAIL="${RST_REAP_FAIL:-}" \
    RST_SNAPSHOT_FAIL="${RST_SNAPSHOT_FAIL:-}" RST_SNAPDEL_FAIL="${RST_SNAPDEL_FAIL:-}" \
    RST_RESTORE_FAIL="${RST_RESTORE_FAIL:-}" RST_DOWN_FAIL="${RST_DOWN_FAIL:-}" \
    RST_STOP_NOT_TAKE="${RST_STOP_NOT_TAKE:-}" RST_START_FAIL="${RST_START_FAIL:-}" \
    CREW_DRAIN_POLL_SECONDS=0 CREW_RESTART_READY_POLL_SECONDS=0 \
    CREW_RESTART_READY_ATTEMPTS=3 PATH="$SHIM:$PATH" bash "$CLI" "$@"
}

capture() {
  if OUT="$(run_crew "$@" 2>&1)"; then RC=0; else RC=$?; fi
}

arm() { printf '%s\n' "armed" >"$STATE/snaps-$1"; }
calls_of() { grep -c "^$1" "$STATE/calls" 2>/dev/null || true; }

# --- D2: the help states the credential fact and the trust boundary ---------

reset_case
capture help reset
case "$OUT" in *'LIVE CREDENTIALS'*'trust boundary'*) r1=stated ;; *) r1="$OUT" ;; esac
t reset-help-states-credentials-and-trust-boundary stated "$r1"
case "$OUT" in *"refused as a 'crew new --from' source"*) r1=stated ;; *) r1="$OUT" ;; esac
t reset-help-states-clone-refusal stated "$r1"
case "$OUT" in *"never rolled back to 'bootstrapped'"*) r1=stated ;; *) r1="$OUT" ;; esac
t reset-help-rules-out-other-labels stated "$r1"
capture help
case "$OUT" in *'reset'*"Restore boxes to their 'armed' checkpoint"*) r1=listed ;; *) r1="$OUT" ;; esac
t reset-appears-in-the-command-table listed "$r1"

# --- D1: --cut refuses a box that is not logged in, and one that is not hired

reset_case
RST_LOGGED_IN="beta" capture reset --cut alpha
t reset-cut-refuses-unauthenticated-box 1 "$RC"
case "$OUT" in *'alpha: REFUSED — not logged in'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unauthenticated-is-named named "$r1"
t reset-cut-unauthenticated-cuts-nothing 0 "$(calls_of 'snapshot')"

reset_case
RST_STAMP_alpha="" capture reset --cut alpha
t reset-cut-refuses-unhired-box 1 "$RC"
case "$OUT" in *'alpha: REFUSED — not hired'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unhired-is-named named "$r1"
t reset-cut-unhired-cuts-nothing 0 "$(calls_of 'snapshot')"

# --- D7: reclaim, THEN measure, THEN decide ---------------------------------
# 95% before the sweep, 60% after: a cut that measured first refuses this box.

reset_case
RST_PCT_BEFORE=95 RST_PCT_AFTER=60 capture reset --cut alpha
t reset-cut-reaper-brings-box-under-threshold 0 "$RC"
t reset-cut-reclaims-before-measuring $'reap alpha\nroot-df alpha' \
  "$(grep -E '^(reap|root-df) alpha$' "$STATE/calls")"
t reset-cut-takes-the-snapshot 1 "$(calls_of 'snapshot alpha armed')"
case "$OUT" in *'reclaiming before measuring'*'reaper: transcripts reclaimed 12345 bytes'*) r1=forwarded ;; *) r1="$OUT" ;; esac
t reset-cut-forwards-the-sweep-evidence forwarded "$r1"
case "$OUT" in *'alpha: armed cut at crew@0.1.3; root filesystem 60% used'*) r1=reported ;; *) r1="$OUT" ;; esac
t reset-cut-reports-the-post-reclaim-figure reported "$r1"

reset_case
RST_PCT_BEFORE=95 RST_PCT_AFTER=95 capture reset --cut alpha
t reset-cut-refuses-a-box-still-fat 1 "$RC"
case "$OUT" in *'alpha: REFUSED — root filesystem 95% used after reclaiming, over the 80% ceiling'*) r1=refused ;; *) r1="$OUT" ;; esac
t reset-cut-over-threshold-is-refused refused "$r1"
# D7 step 3: the COMPOSITION, not only the percentage.
case "$OUT" in *'largest: 13G /swapfile;13G /swapfile-drill;19G /var;6.9G /home'*) r1=composed ;; *) r1="$OUT" ;; esac
t reset-cut-refusal-names-what-is-large composed "$r1"
t reset-cut-over-threshold-cuts-nothing 0 "$(calls_of 'snapshot')"

reset_case
RST_PCT_BEFORE=95 RST_PCT_AFTER=95 RST_LARGE="" capture reset --cut alpha
case "$OUT" in *'largest: unavailable'*) r1=honest ;; *) r1="$OUT" ;; esac
t reset-cut-unreadable-composition-is-honest honest "$r1"

reset_case
RST_REAP_FAIL=alpha capture reset --cut alpha
t reset-cut-refuses-when-the-sweep-cannot-run 1 "$RC"
case "$OUT" in *'REFUSED — the on-demand reaper did not complete'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-unswept-box-is-named named "$r1"
t reset-cut-unswept-box-is-never-measured 0 "$(calls_of 'root-df')"
t reset-cut-unswept-box-cuts-nothing 0 "$(calls_of 'snapshot')"

# --- D5: the cut records its version; a re-cut replaces the label -----------

reset_case
capture reset --cut alpha
t reset-cut-records-the-version 'CHECKPOINT_VERSION=0.1.3' \
  "$(grep '^CHECKPOINT_VERSION=' "$CONF/checkpoints/alpha.conf")"
t reset-cut-records-no-stale-mark 'CHECKPOINT_STALE=' \
  "$(grep '^CHECKPOINT_STALE=' "$CONF/checkpoints/alpha.conf")"

reset_case
arm alpha
capture reset --cut alpha
t reset-recut-succeeds 0 "$RC"
t reset-recut-deletes-the-old-label-first 1 "$(calls_of 'incus alpha snapshot delete')"
t reset-recut-leaves-exactly-one-armed 1 "$(grep -cx armed "$STATE/snaps-alpha")"

reset_case
arm alpha
RST_SNAPDEL_FAIL=alpha capture reset --cut alpha
t reset-recut-refuses-when-the-old-label-survives 1 "$RC"
case "$OUT" in *'could not replace the existing armed checkpoint; it is unchanged'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-recut-failure-is-named named "$r1"

reset_case
RST_SNAPSHOT_FAIL=alpha capture reset --cut alpha
t reset-cut-snapshot-failure-is-loud 1 "$RC"
case "$OUT" in *'this box now has NO checkpoint'*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-cut-snapshot-failure-names-the-repair named "$r1"

# --- D4: box info is the only thing that knows a label exists ---------------

reset_case
capture reset alpha
t reset-refuses-a-box-with-no-checkpoint 1 "$RC"
case "$OUT" in *'alpha: REFUSED — no armed checkpoint'*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-missing-checkpoint-is-named named "$r1"
# It is a FAILURE, never a skip: a box the reset cannot perform must not be
# counted beside the ones a live duty lock legitimately deferred.
case "$OUT" in *'reset: 0 restored, 0 skipped-busy, 1 failed'*'failed: alpha'*) r1=failed ;; *) r1="$OUT" ;; esac
t reset-missing-checkpoint-is-not-skipped failed "$r1"
# The refusal that matters: it does NOT fall back to another label.
t reset-missing-checkpoint-restores-nothing 0 "$(calls_of 'restore')"

reset_case
printf 'bootstrapped\npristine\n' >"$STATE/snaps-alpha"
capture reset alpha
t reset-does-not-fall-back-to-bootstrapped 1 "$RC"
t reset-does-not-restore-any-other-label 0 "$(calls_of 'restore')"
case "$OUT" in *'it is NOT rolled back to any other label'*) r1=explicit ;; *) r1="$OUT" ;; esac
t reset-other-labels-refusal-is-explicit explicit "$r1"

reset_case
arm alpha
RST_INFO_BROKEN=alpha capture reset alpha
t reset-refuses-an-unreadable-listing 1 "$RC"
case "$OUT" in *'could not read its snapshot labels'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-unreadable-listing-is-named named "$r1"
t reset-unreadable-listing-restores-nothing 0 "$(calls_of 'restore')"

# --- D3: the green path — restore and start ---------------------------------

reset_case
arm alpha
capture reset --cut alpha
reset_case_calls="$STATE/calls"
: >"$reset_case_calls"
capture reset alpha
t reset-restores-and-starts 0 "$RC"
t reset-stops-before-restoring $'down alpha\nrestore alpha armed --force\nstart alpha' \
  "$(grep -E '^(down|restore|start) alpha' "$STATE/calls")"
case "$OUT" in *'alpha: restored to armed (crew@0.1.3) and started'*) r1=reported ;; *) r1="$OUT" ;; esac
t reset-restore-is-reported reported "$r1"

reset_case
arm alpha
capture reset --cut alpha
: >"$STATE/calls"
RST_STOP_NOT_TAKE=alpha capture reset alpha
t reset-stop-not-taken-is-failure 1 "$RC"
t reset-stop-not-taken-never-restores 0 "$(calls_of 'restore')"
case "$OUT" in *'stop did not take'*'NOT restoring'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-stop-not-taken-is-named named "$r1"

# --- D5: the engine-version interlock ---------------------------------------
# The recorded version and the live one disagree, by any route.

reset_case
arm alpha
capture reset --cut alpha
: >"$STATE/calls"
RST_STAMP_alpha=0.1.4 capture reset alpha
t reset-refuses-a-version-mismatch 1 "$RC"
case "$OUT" in *'cut at crew@0.1.3 and the box now runs crew@0.1.4'*'crew reset --cut alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-version-mismatch-names-both-and-the-repair named "$r1"
t reset-version-mismatch-restores-nothing 0 "$(calls_of 'restore')"

# `crew upgrade` marks the checkpoint stale IN THE SAME WRITE, and the reset
# immediately afterwards is refused by that recorded fact.
reset_case
arm alpha
capture reset --cut alpha
: >"$STATE/calls"
capture upgrade alpha
t reset-upgrade-succeeds 0 "$RC"
case "$OUT" in *"alpha's armed checkpoint is now STALE"*'crew reset --cut alpha'*) r1=announced ;; *) r1="$OUT" ;; esac
t reset-upgrade-announces-the-stale-mark announced "$r1"
t reset-upgrade-writes-the-stale-mark 1 \
  "$(grep -c '^CHECKPOINT_STALE=[0-9]' "$CONF/checkpoints/alpha.conf")"
: >"$STATE/calls"
capture reset alpha
t reset-after-upgrade-is-refused 1 "$RC"
case "$OUT" in *'was cut at crew@0.1.3 and the box was upgraded to crew@'*'silently downgrade the engine'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-stale-checkpoint-names-both-versions named "$r1"
t reset-stale-checkpoint-restores-nothing 0 "$(calls_of 'restore')"
# A re-cut clears the mark and the reset then proceeds.
: >"$STATE/calls"
capture reset --cut alpha
t reset-recut-clears-the-stale-mark 'CHECKPOINT_STALE=' \
  "$(grep '^CHECKPOINT_STALE=' "$CONF/checkpoints/alpha.conf")"
: >"$STATE/calls"
capture reset alpha
t reset-after-recut-proceeds 0 "$RC"
t reset-after-recut-restores 1 "$(calls_of 'restore alpha armed')"

# An upgrade of a box with NO checkpoint invents no record to invalidate.
reset_case
capture upgrade alpha
t reset-upgrade-without-a-checkpoint-writes-nothing absent \
  "$([ -f "$CONF/checkpoints/alpha.conf" ] && echo present || echo absent)"

# --- D6: the drain contract, inherited from #588 ----------------------------

for path in "--cut alpha" "alpha"; do
  reset_case
  arm alpha
  printf 'busy:60\n' >"$STATE/probe-alpha"
  # shellcheck disable=SC2086  # the two argument shapes are the point
  capture reset $path
  label="$(printf '%s' "$path" | tr -d ' -')"
  t "reset-busy-$label-has-skip-status" 3 "$RC"
  case "$OUT" in *'alpha: SKIPPED busy — duty lock held for 1m'*'skipped: alpha'*) r1=named ;; *) r1="$OUT" ;; esac
  t "reset-busy-$label-is-named" named "$r1"
  t "reset-busy-$label-mutates-nothing" 0 "$(grep -cE '^(snapshot|restore|down|start) ' "$STATE/calls" || true)"
done

reset_case
arm alpha
printf 'unreadable\n' >"$STATE/probe-alpha"
capture reset alpha
t reset-unreadable-lock-is-a-busy-skip 3 "$RC"
t reset-unreadable-lock-mutates-nothing 0 "$(grep -cE '^(snapshot|restore) ' "$STATE/calls" || true)"

reset_case
arm alpha
printf 'busy:3601\n' >"$STATE/probe-alpha"
capture reset alpha --force-after 1
t reset-force-after-proceeds 0 "$RC"
case "$OUT" in *'force-after reached; proceeding'*) r1=announced ;; *) r1="$OUT" ;; esac
t reset-force-after-is-announced announced "$r1"

reset_case
capture reset alpha --force-after 00
t reset-force-after-zero-spelling-refuses 2 "$RC"
t reset-force-after-zero-mutates-nothing 0 "$(grep -cE '^(snapshot|restore|down) ' "$STATE/calls" || true)"

reset_case
capture reset alpha --force-after 99999999999999999999
t reset-force-after-over-range-refuses 2 "$RC"

reset_case
capture reset --all alpha
t reset-all-with-names-is-a-usage-error 2 "$RC"
reset_case
capture reset
t reset-no-target-is-a-usage-error 2 "$RC"

# --- --all is the ROSTER, never every box on the host -----------------------

reset_case
arm alpha; arm beta; arm offroster
capture reset --all
t reset-all-restores-the-roster 2 "$(calls_of 'restore')"
t reset-all-leaves-offroster 0 "$(grep -c 'offroster' "$STATE/calls" || true)"

# --- a stopped box is refused, never silently skipped -----------------------

reset_case
arm alpha
printf 'stopped\n' >"$STATE/state-alpha"
capture reset alpha
t reset-stopped-box-is-refused 1 "$RC"
case "$OUT" in *'alpha: REFUSED — stopped'*'box start alpha'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-stopped-box-is-named named "$r1"

reset_case
capture reset nosuchbox
t reset-absent-box-is-a-failure 1 "$RC"
case "$OUT" in *'nosuchbox: not present'*) r1=named ;; *) r1="$OUT" ;; esac
t reset-absent-box-is-named named "$r1"

# --- D2: an armed checkpoint is never a clone source ------------------------

reset_case
capture new --name gamma --role builder --agent claude --from alpha/armed
t reset-armed-is-refused-as-a-clone-source 1 "$RC"
case "$OUT" in *"refusing to clone 'alpha/armed'"*"alpha's live credentials"*) r1=named ;; *) r1="$OUT" ;; esac
t reset-clone-refusal-is-named named "$r1"
t reset-clone-refusal-mints-nothing 0 "$(calls_of 'new')"

# A gold snapshot is still a clone source: the guard is the label, not --from.
reset_case
capture new --name gamma --role builder --agent claude --from alpha/gold-crew-0.1.3
t reset-gold-remains-a-clone-source 0 "$RC"
t reset-gold-clone-mints 1 "$(calls_of 'new')"

# The roster's own fourth column goes through the same guard: create-all and
# up read it, and a roster line is exactly where this would go unnoticed.
reset_case
printf 'gamma claude builder alpha/armed\n' >>"$CONF/fleet.roster"
capture new gamma
t reset-roster-armed-source-is-refused 1 "$RC"
t reset-roster-armed-source-mints-nothing 0 "$(calls_of 'new')"
sed -i '/^gamma /d' "$CONF/fleet.roster"

# --- the on-demand reaper entry point (D7 step 1) ---------------------------
#
# The lock gate is the subject. reap-now.sh takes $DUTY_DIR/.duty.lock exactly
# as duty.sh does, so a tick or a live session holding it means the sweep does
# not run — #457 D1's own hazard note is a reaper deleting files under a
# running session, and this is the one reaper call not already inside a tick.
REAPNOW="$SHARED/bin/reap-now.sh"
RDUTY="$TMP/reapduty"
mkdir -p "$RDUTY/conf/agents" "$RDUTY/conf/roles" "$RDUTY/.claude/projects" "$RDUTY/.cache"
ln -s "$SHARED/lib" "$RDUTY/lib"
cp "$SHARED/conf/fleet.defaults.conf" "$RDUTY/conf/"
cp "$SHARED/conf/agents/claude.conf" "$RDUTY/conf/agents/"
cp "$SHARED/conf/roles/builder.conf" "$RDUTY/conf/roles/"
printf 'BOT_AGENT=claude\nBOT_ROLES=builder\n' >"$RDUTY/conf/instance.conf"

if out="$(env DUTY_DIR="$RDUTY" HOME="$RDUTY" bash "$REAPNOW" 2>&1)"; then rc=0; else rc=$?; fi
t reapnow-runs-with-a-free-lock 0 "$rc"
case "$out" in *'on-demand sweep requested'*'reaper sweep starting'*) r1=swept ;; *) r1="$out" ;; esac
t reapnow-performs-the-sweep swept "$r1"

# Held by somebody else: refused, named, and nothing swept.
exec 9>"$RDUTY/.duty.lock"
flock -n 9
if out="$(env DUTY_DIR="$RDUTY" HOME="$RDUTY" bash "$REAPNOW" 2>&1)"; then rc=0; else rc=$?; fi
exec 9>&-
t reapnow-refuses-a-held-lock 199 "$rc"
case "$out" in *'a duty tick holds'*'nothing run'*) r1=named ;; *) r1="$out" ;; esac
t reapnow-held-lock-is-named named "$r1"
case "$out" in *'reaper sweep starting'*) r1="$out" ;; *) r1=unswept ;; esac
t reapnow-held-lock-sweeps-nothing unswept "$r1"

# It runs REGARDLESS of the stamp, and does not move the box's daily cadence.
printf '%s\n' "$(date +%s)" >"$RDUTY/.reaper-last"
if out="$(env DUTY_DIR="$RDUTY" HOME="$RDUTY" bash "$REAPNOW" 2>&1)"; then rc=0; else rc=$?; fi
t reapnow-ignores-a-fresh-reaper-last 0 "$rc"
case "$out" in *'reaper sweep starting'*) r1=swept ;; *) r1="$out" ;; esac
t reapnow-sweeps-despite-the-stamp swept "$r1"
# Named in its header, read nowhere: the three mentions are the comment that
# explains why the stamp is neither consulted nor written.
t reapnow-does-not-read-the-stamp 0 \
  "$(grep -v '^[[:space:]]*#' "$REAPNOW" | grep -c 'reaper-last' | tr -d ' ')"

suite_finish
