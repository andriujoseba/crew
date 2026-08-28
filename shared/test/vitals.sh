#!/usr/bin/env bash
# shared/test/vitals.sh — #483's probe, driven against FIXTURE boxes rather
# than against the box the suite happens to run on. Every reader in vitals.sh
# shells out (nproc, free, df, swapon, stat, uname), so each fixture is a
# directory of stubs prepended to PATH: that is what makes "a platform missing
# one field" and "a swapfile present but not active" expressible at all, and
# it is why none of these cases can pass by accident on a healthy host.
#
# The three must-fail cases the issue's test plan names are marked MUST-FAIL
# below. Each is written so it FAILS against a probe that has the defect, not
# merely passes against one that does not — a case that cannot fail proves
# nothing about the code it points at.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
PROBE="$SHARED/bin/vitals.sh"
WORK="$TMP"

# The subject is a text record, so the two predicates are substring presence
# and absence. Both route through lib.sh's `t` so this suite counts, reports
# and terminates exactly like every other subject suite — run.sh reads the
# final `passed N, failed N` and nothing else.
same() { t "$1" "$2" "$3"; }
has()  { case "$2" in *"$3"*) t "$1" present present ;; *) t "$1" "present:$3" "absent (in: $2)" ;; esac; }
hasnt(){ case "$2" in *"$3"*) t "$1" "absent:$3" "present (in: $2)" ;; *) t "$1" absent absent ;; esac; }

# mk_box <name> — a fixture box: a stub dir on PATH plus a fake root for the
# swapfile probe. Callers overwrite individual stubs to shape the reading.
mk_box() {
  local b="$WORK/$1"
  mkdir -p "$b/bin" "$b/root"
  cat > "$b/bin/nproc"  <<'EOF'
#!/bin/sh
echo 2
EOF
  # free -m: the Mem: and Swap: lines the probe reads, in `free -m` column
  # order (total used free shared buff/cache available).
  cat > "$b/bin/free" <<'EOF'
#!/bin/sh
echo "               total        used        free      shared  buff/cache   available"
echo "Mem:            3850        1200        1500         103        1150        3128"
echo "Swap:              0           0           0"
EOF
  cat > "$b/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem     1024-blocks     Used Available Capacity Mounted on"
echo "/dev/sda2         30408704 14596096  15812608      48% /"
EOF
  cat > "$b/bin/swapon" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$b/bin/uname" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-r" ] && { echo "6.12.0-fixture"; exit 0; }
echo Linux
EOF
  chmod +x "$b/bin/"*
  echo "$b"
}

run_probe() { # run_probe <box> [VAR=VAL ...] — prints the record
  local b="$1"; shift
  env -i PATH="$b/bin:/usr/bin:/bin" HOME="$WORK" \
      VITALS_ROOT="$b/root/" "$@" bash "$PROBE"
}

# --- 1. agreeing profile: every field present, no findings -------------------
B="$(mk_box agree)"
out="$(run_probe "$B" BOX_CPU=2 BOX_MEMORY=4GiB BOX_DISK=30GiB)"
has  "agree-emits-cores"        "$out" "cores=2"
has  "agree-emits-mem-triple"   "$out" "mem_total_mb=3850"
has  "agree-emits-mem-shared"   "$out" "mem_shared_mb=103"
has  "agree-emits-mem-avail"    "$out" "mem_avail_mb=3128"
has  "agree-emits-disk-pct"     "$out" "disk_pct=48"
has  "agree-emits-platform"     "$out" "platform=linux"
hasnt "agree-marks-no-cpu-finding"    "$out" "cpu-profile-mismatch"
hasnt "agree-marks-no-memory-finding" "$out" "memory-profile-mismatch"
hasnt "agree-marks-no-disk-finding"   "$out" "disk-profile-mismatch"

# --- 2. disagreeing profile --------------------------------------------------
# MUST-FAIL: a profile mismatch going unmarked. The fixture reads 2 cores /
# 3850 MiB / 30 GiB against a builder profile of 4 / 8GiB / 60GiB, so a probe
# that skips the D3 comparison — or that compares and says nothing — fails
# every one of these three.
B="$(mk_box drift)"
out="$(run_probe "$B" BOX_CPU=4 BOX_MEMORY=8GiB BOX_DISK=60GiB)"
has "drift-marks-cpu"    "$out" "finding=cpu-profile-mismatch:want=4,got=2"
has "drift-marks-memory" "$out" "finding=memory-profile-mismatch:"
has "drift-marks-disk"   "$out" "finding=disk-profile-mismatch:"
# The finding carries BOTH numbers, so a reader never goes back to the box.
has "drift-cpu-names-both-numbers" "$out" "want=4,got=2"
# ...and the record is still a record: a finding annotates it, never replaces it.
has "drift-still-emits-fields" "$out" "cores=2"

# --- 3. swapfile present but not active --------------------------------------
# MUST-FAIL: the swapfile fixture reading clean. This is the claude-triage
# state the issue measured — an 8 GiB /swapfile on disk with `swapon --show`
# empty — and it is invisible in either number alone, which is the whole
# reason D4 makes them two fields.
B="$(mk_box swapfile)"
dd if=/dev/zero of="$B/root/swapfile" bs=1M count=8 status=none 2>/dev/null ||
  head -c 8388608 /dev/zero > "$B/root/swapfile"
out="$(run_probe "$B" BOX_CPU=2 BOX_MEMORY=4GiB BOX_DISK=30GiB)"
has "swapfile-configured-nonzero" "$out" "swap_configured_mb=8"
has "swapfile-active-zero"        "$out" "swap_active_mb=0"
has "swapfile-is-a-finding"       "$out" "finding=swap-configured-inactive:configured_mb=8,active_mb=0"

# The inverse, so the finding is not simply always-on: no swapfile, no finding.
B="$(mk_box noswap)"
out="$(run_probe "$B" BOX_CPU=2)"
hasnt "noswap-no-finding" "$out" "swap-configured-inactive"

# --- 4. a platform missing one field -----------------------------------------
# MUST-FAIL: one absent field suppressing the whole record. D6 is per-field,
# so the unreadable figure is absent and the other eight still emit.
B="$(mk_box nofree)"
cat > "$B/bin/free" <<'EOF'
#!/bin/sh
echo "free: command not supported" >&2
exit 127
EOF
chmod +x "$B/bin/free"
out="$(run_probe "$B" BOX_CPU=2 BOX_MEMORY=4GiB BOX_DISK=30GiB)"
has   "degrade-record-still-emits"   "$out" "VITALS ts="
has   "degrade-keeps-cores"          "$out" "cores=2"
has   "degrade-keeps-disk"           "$out" "disk_pct=48"
has   "degrade-keeps-platform"       "$out" "platform=linux"
hasnt "degrade-omits-mem-total"      "$out" "mem_total_mb="
hasnt "degrade-omits-mem-avail"      "$out" "mem_avail_mb="
# Absent, never a placeholder: "unknown" would read as a measurement.
hasnt "degrade-writes-no-unknown"    "$out" "unknown"
# A missing memory reading must not manufacture a memory FINDING either.
hasnt "degrade-marks-no-memory-finding" "$out" "memory-profile-mismatch"

# A second missing field, on a different reader, so the degradation is not
# one special case in the memory path.
B="$(mk_box nodf)"
cat > "$B/bin/df" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$B/bin/df"
out="$(run_probe "$B" BOX_CPU=2 BOX_DISK=30GiB)"
has   "degrade-df-record-still-emits" "$out" "VITALS ts="
has   "degrade-df-keeps-mem"          "$out" "mem_total_mb=3850"
hasnt "degrade-df-omits-disk"         "$out" "disk_total_mb="
hasnt "degrade-df-marks-no-finding"   "$out" "disk-profile-mismatch"

# --- 5. the disk series is backfilled from boot-check.log (D5) ---------------
# MUST-FAIL: the disk series starting at the first tick. The boot gate has
# been writing `df -h /` to boot-check.log once per boot since the box was
# hired, so a probe that begins its series at its own first record throws away
# every reading the box already has — which on the baseline box is the entire
# finding, since `/` rising monotonically is invisible in any one reading.
#
# The fixture is written in the boot gate's own shape (shared/bin/duty.sh):
# a `== boot check <date -Is> ==` header, then `gh auth status` output, then
# the df line, then the cli probe verdict.
boot_block() { # boot_block <file> <stamp> <df-line>
  {
    echo "== boot check $2 =="
    echo "github.com"
    echo "  ✓ Logged in to github.com account cndgrr (/home/claude/.config/gh/hosts.yml)"
    echo "  - Token scopes: 'read:org', 'repo', 'workflow'"
    echo "$3"
    echo "cli probe: ok"
  } >> "$1"
}

B="$(mk_box series)"
BC="$B/boot-check.log"
boot_block "$BC" "2026-08-01T12:50:01+00:00" "/dev/sda2        58G  2.5G   56G   5% /"
boot_block "$BC" "2026-08-02T09:00:01+00:00" "/dev/sda2        58G  3.1G   55G   6% /"
boot_block "$BC" "2026-08-10T21:15:01+00:00" "/dev/sda2        58G   31G   28G  53% /"
out="$(run_probe "$B" BOX_CPU=2 BOOT_CHECK_LOG="$BC")"
has "series-is-emitted"        "$out" "disk_series="
has "series-carries-history"   "$out" "disk_series=2026-08-01T12:50:01+00:00@5,"
has "series-is-oldest-first"   "$out" \
  "disk_series=2026-08-01T12:50:01+00:00@5,2026-08-02T09:00:01+00:00@6,2026-08-10T21:15:01+00:00@53 "
# The series is history; the live reading stays its own field, because one was
# measured a moment ago and the others were read out of a log.
has "series-does-not-replace-live-disk" "$out" "disk_pct=48"

# The `gh auth status` lines between the header and the df line are not
# readings. A block-scoped parse that anchored on "first line after the
# header" would take the word `github.com` as a series point.
same "series-has-exactly-three-points" "3" \
  "$(printf '%s\n' "$out" | tr ' ' '\n' | sed -n 's/^disk_series=//p' | tr ',' '\n' | grep -c '@')"

# A boot the gate could not complete writes a header and no df line. It
# contributes no point rather than a point with the previous block's number.
B="$(mk_box series-partial)"
BC="$B/boot-check.log"
boot_block "$BC" "2026-08-01T12:50:01+00:00" "/dev/sda2        58G  2.5G   56G   5% /"
{ echo "== boot check 2026-08-02T09:00:01+00:00 =="
  echo "You are not logged into any GitHub hosts. To log in, run: gh auth login"
  echo "cli probe: FAILED"; } >> "$BC"
out="$(run_probe "$B" BOX_CPU=2 BOOT_CHECK_LOG="$BC")"
has  "series-partial-keeps-the-good-block" "$out" "disk_series=2026-08-01T12:50:01+00:00@5 "
hasnt "series-partial-invents-no-point"    "$out" "2026-08-02T09:00:01+00:00@"

# `df -h` wraps a long device name onto a second line, and the boot gate's
# `tail -1` then hands over a FIVE-field row. Both forms end `<pct>% /`, which
# is why the shape is anchored on the tail of the line and not on NF.
B="$(mk_box series-wrapped)"
BC="$B/boot-check.log"
boot_block "$BC" "2026-08-01T12:50:01+00:00" "                  58G  2.5G   56G   7% /"
out="$(run_probe "$B" BOX_CPU=2 BOOT_CHECK_LOG="$BC")"
has "series-reads-a-wrapped-df-line" "$out" "disk_series=2026-08-01T12:50:01+00:00@7 "

# Bounded, because the field ships on every record and boot-check.log grows
# with the box's age. The NEWEST readings survive the cap.
B="$(mk_box series-cap)"
BC="$B/boot-check.log"
for i in 1 2 3 4 5; do
  boot_block "$BC" "2026-08-0${i}T09:00:01+00:00" "/dev/sda2        58G  2.5G   56G   ${i}% /"
done
out="$(run_probe "$B" BOX_CPU=2 BOOT_CHECK_LOG="$BC" VITALS_SERIES_MAX=3)"
has   "series-cap-keeps-the-newest" "$out" \
  "disk_series=2026-08-03T09:00:01+00:00@3,2026-08-04T09:00:01+00:00@4,2026-08-05T09:00:01+00:00@5 "
hasnt "series-cap-drops-the-oldest" "$out" "2026-08-01T09:00:01+00:00@1"

# D6 again, on this reader: no boot-check.log at all is an absent field, and
# the record still emits every other figure.
B="$(mk_box series-absent)"
out="$(run_probe "$B" BOX_CPU=2 BOOT_CHECK_LOG="$B/nothing-here.log")"
has   "series-absent-record-still-emits" "$out" "VITALS ts="
has   "series-absent-keeps-disk"         "$out" "disk_pct=48"
hasnt "series-absent-omits-the-field"    "$out" "disk_series="

# A boot-check.log with no df line in it at all — an engine older than the
# boot gate's df line — is the same case, and must not emit an empty series.
B="$(mk_box series-empty)"
BC="$B/boot-check.log"
{ echo "== boot check 2026-08-01T12:50:01+00:00 =="; echo "cli probe: ok"; } > "$BC"
out="$(run_probe "$B" BOX_CPU=2 BOOT_CHECK_LOG="$BC")"
has   "series-empty-record-still-emits" "$out" "VITALS ts="
hasnt "series-empty-omits-the-field"    "$out" "disk_series="

# --- 6. the record's shape ---------------------------------------------------
# One line, always: both readers parse it by line, so a probe that wrapped
# would break `crew status` and the floor at the same time.
B="$(mk_box shape)"
out="$(run_probe "$B" BOX_CPU=2)"
same "record-is-one-line" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
same "record-starts-VITALS" "VITALS" "$(printf '%s' "$out" | cut -d' ' -f1)"
has  "record-timestamp-is-utc-iso8601" "$out" "Z "

suite_finish
