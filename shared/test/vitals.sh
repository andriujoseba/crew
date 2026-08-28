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

# --- 5. the record's shape ---------------------------------------------------
# One line, always: both readers parse it by line, so a probe that wrapped
# would break `crew status` and the floor at the same time.
B="$(mk_box shape)"
out="$(run_probe "$B" BOX_CPU=2)"
same "record-is-one-line" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
same "record-starts-VITALS" "VITALS" "$(printf '%s' "$out" | cut -d' ' -f1)"
has  "record-timestamp-is-utc-iso8601" "$out" "Z "

suite_finish
