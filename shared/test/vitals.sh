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
hasnt "agree-marks-no-memory-low"     "$out" "memory-low"
hasnt "agree-marks-no-disk-low"       "$out" "disk-low"

# --- current headroom -------------------------------------------------------
B="$(mk_box disk-low)"
sed -i 's/48%/94%/' "$B/bin/df"
out="$(run_probe "$B" BOX_DISK=30GiB)"
has "disk-low-at-94" "$out" "finding=disk-low:want=under-90%,got=94%"

B="$(mk_box disk-healthy)"
sed -i 's/48%/60%/' "$B/bin/df"
out="$(run_probe "$B" BOX_DISK=30GiB)"
hasnt "disk-healthy-at-60" "$out" "disk-low"

B="$(mk_box memory-low)"
sed -i 's/3128"$/300"/' "$B/bin/free"
out="$(run_probe "$B" BOX_MEMORY=4GiB)"
has "memory-low-on-pair" "$out" \
  "finding=memory-low:want=over-10%-available,got=7%-available(300/3850MiB)"

# Operator overrides replace the table default without copying it elsewhere.
out="$(run_probe "$B" BOX_MEMORY=4GiB VITALS_MEMORY_LOW_PCT=5)"
hasnt "memory-low-operator-override" "$out" "memory-low"
B="$(mk_box disk-override)"
sed -i 's/48%/60%/' "$B/bin/df"
out="$(run_probe "$B" BOX_DISK=30GiB VITALS_DISK_LOW_PCT=55)"
has "disk-low-operator-override" "$out" "finding=disk-low:want=under-55%,got=60%"

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

# MUST-FAIL: drift marked in ONE direction only. The band exists because a
# reported total sits a little under the provisioned figure, but that argues
# for tolerance and not for one-sidedness: a box that came up with more than
# its profile declares was not minted from that profile either. This fixture
# reads 3850 MiB / ~29.7 GiB against a profile declaring 1 GiB of each, so it
# is over on BOTH figures while cores agree exactly — which is what makes it a
# test of the upper bound and not of the comparison in general. Delete either
# `-gt` branch from `outside_band` and the matching assertion here reds.
B="$(mk_box drift-over)"
out="$(run_probe "$B" BOX_CPU=2 BOX_MEMORY=1GiB BOX_DISK=1GiB)"
has "drift-over-marks-memory" "$out" "finding=memory-profile-mismatch:want=1024MiB,got=3850MiB"
has "drift-over-marks-disk"   "$out" "finding=disk-profile-mismatch:want=1024MiB,got=29696MiB"
# Cores agree, so the record must NOT invent a third finding: this is the
# control that says the upper bound is a band and not an always-on mismatch.
hasnt "drift-over-leaves-cpu-clean" "$out" "cpu-profile-mismatch"

# The band's edges, so "10%" is a tested figure and not a comment. 3850 MiB
# measured: a 4000 MiB profile is 3.75% under and clean; 3400 MiB is 13% over
# the declared and marked.
B="$(mk_box band-edge)"
out="$(run_probe "$B" BOX_MEMORY=4000MiB)"
hasnt "band-inside-is-clean" "$out" "memory-profile-mismatch"
out="$(run_probe "$B" BOX_MEMORY=3400MiB)"
has "band-outside-high-is-marked" "$out" "finding=memory-profile-mismatch:want=3400MiB,got=3850MiB"

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
#
# MUST-FAIL: a measured zero emitted as an absent field. `swapon --show`
# succeeds here and reports nothing, and there is no swapfile — so the answer
# is ZERO, and zero is a measurement. D6 reserves absence for a figure the
# platform could not report, and the cost of confusing the two lands on the
# PAIR: `swap_active_mb` comes off `free`, which prints a Swap: line on every
# box, so suppressing the configured half left active=0 standing alone and
# made a box with no swap look like a box whose swap probe is broken.
B="$(mk_box noswap)"
out="$(run_probe "$B" BOX_CPU=2)"
hasnt "noswap-no-finding"                   "$out" "swap-configured-inactive"
has   "noswap-configured-is-a-measured-zero" "$out" "swap_configured_mb=0"
has   "noswap-pair-stays-together"           "$out" "swap_active_mb=0"

# MUST-FAIL: the ACTIVE swap device counted in the wrong unit. Until this
# fixture existed no case in this file had active swap at all — every mk_box
# answered `swapon` with `exit 0` — so the `swapon --show` accumulator was
# never once executed under test, and it was converting BYTES as if they were
# KiB. `--bytes` means bytes; one division left the field 1024x high in a
# field named `_mb`.
#
# It hid behind the finding rather than behind the field: swap-configured-
# inactive fires only when active is 0, and when active is 0 this branch
# contributes nothing. So the assertion has to be on the FIGURE.
mk_active_swap() { # mk_active_swap <box> <bytes> <mb> [name] — an active device
  # NAME as well as SIZE, and SIZE right-aligned into a padded column, which
  # is what smartcols actually prints. The padding is deliberate: the reader
  # splits on whitespace runs, and a stub that emitted one bare column would
  # let a parse that cannot cope with the real output pass.
  cat > "$1/bin/swapon" <<EOF
#!/bin/sh
printf '%s %12s\n' "${4:-/dev/sda3}" "$2"
EOF
  cat > "$1/bin/free" <<EOF
#!/bin/sh
echo "               total        used        free      shared  buff/cache   available"
echo "Mem:            3850        1200        1500         103        1150        3128"
echo "Swap:           $3           0        $3"
EOF
  chmod +x "$1/bin/swapon" "$1/bin/free"
}

B="$(mk_box swapon-active)"
mk_active_swap "$B" 2147483648 2048   # one 2 GiB device, swapped on
out="$(run_probe "$B" BOX_CPU=2)"
has "active-swap-configured-in-mib" "$out" "swap_configured_mb=2048"
has "active-swap-active-in-mib"     "$out" "swap_active_mb=2048"
# The pair agrees, so there is nothing to report: a box with working swap is
# not a finding. Under the KiB bug the figures disagree by 1024x and this is
# still silent — which is why the assertion above is on the number.
hasnt "active-swap-is-not-a-finding" "$out" "swap-configured-inactive"

# Both contributors to swap_configured_mb in ONE record, which is the shape
# the defect actually had: an active device and a swapfile on disk are added
# together, so they only sum correctly if both arrive in MiB. 2048 + 8.
B="$(mk_box swapon-active-plus-file)"
mk_active_swap "$B" 2147483648 2048   # a DISTINCT device, not the swapfile
dd if=/dev/zero of="$B/root/swapfile" bs=1M count=8 status=none 2>/dev/null ||
  head -c 8388608 /dev/zero > "$B/root/swapfile"
out="$(run_probe "$B" BOX_CPU=2)"
has "active-swap-sums-with-swapfile" "$out" "swap_configured_mb=2056"

# MUST-FAIL: ONE resource counted twice. The case above is two DISTINCT
# resources and so tests the arithmetic; this is the same 8 MiB swapfile
# reported by `swapon --show` as an active device AND found on disk by the
# stat loop, which is the ordinary shape on any box that has swap at all —
# swap is usually a /swapfile, so the aliased case was the COMMON one and the
# summed case the rare one. Identity is what separates them, which is why the
# reader carries NAME and not only SIZE.
B="$(mk_box swapfile-active-alias)"
dd if=/dev/zero of="$B/root/swapfile" bs=1M count=8 status=none 2>/dev/null ||
  head -c 8388608 /dev/zero > "$B/root/swapfile"
mk_active_swap "$B" 8388608 8 "$B/root/swapfile"
out="$(run_probe "$B" BOX_CPU=2)"
has   "active-swapfile-counted-once" "$out" "swap_configured_mb=8 "
hasnt "active-swapfile-not-doubled"  "$out" "swap_configured_mb=16"
# 8 configured against 8 active agrees, so there is nothing to report. Under
# the aliasing bug it read 16 against 8 — a gap this finding does NOT fire on
# (it needs active=0), which is why the assertion is on the figure.
hasnt "active-swapfile-no-finding"   "$out" "swap-configured-inactive"

# MUST-FAIL: `swapon`'s exit status ignored. It is the sole enumerator of
# active swap, so when it fails there is no way to total the configured
# figure and no way to attribute the swapfile on disk — a number here would
# omit any active partition and could report configured BELOW active, which
# is a self-contradicting record. Absent is the honest answer, and this is
# the state that must not be confused with the measured zero above.
B="$(mk_box swapon-broken)"
cat > "$B/bin/swapon" <<'EOF'
#!/bin/sh
echo "swapon: unrecognized option '--show=NAME,SIZE'" >&2
exit 2
EOF
chmod +x "$B/bin/swapon"
dd if=/dev/zero of="$B/root/swapfile" bs=1M count=8 status=none 2>/dev/null ||
  head -c 8388608 /dev/zero > "$B/root/swapfile"
out="$(run_probe "$B" BOX_CPU=2 2>/dev/null)"
hasnt "swapon-broken-configured-absent" "$out" "swap_configured_mb"
hasnt "swapon-broken-is-not-a-zero"     "$out" "swap_configured_mb=0"
has   "swapon-broken-record-still-emits" "$out" "cores=2"
has   "swapon-broken-keeps-active"       "$out" "swap_active_mb=0"

# The same distinction from the other side: `swapon` exits 0 but prints
# something this cannot resolve into name + numeric size. Not a zero, and not
# arithmetic on a non-number either — before the guard, `total=$((total +
# sz / 1024 / 1024))` on a non-numeric field aborted the reader under `set -u`
# and put a bash error line in duty.log.
B="$(mk_box swapon-garbled)"
cat > "$B/bin/swapon" <<'EOF'
#!/bin/sh
echo "NAME      SIZE"
echo "/dev/sda3 not-a-number"
EOF
chmod +x "$B/bin/swapon"
out="$(run_probe "$B" BOX_CPU=2)"
hasnt "swapon-garbled-configured-absent" "$out" "swap_configured_mb"
has   "swapon-garbled-record-still-emits" "$out" "cores=2"
err="$(run_probe "$B" BOX_CPU=2 2>&1 >/dev/null)"
same "swapon-garbled-is-silent-on-stderr" "" "$err"

# MUST-FAIL: a PRESENT swapfile whose size cannot be read, counted as nothing.
# The two cases above pin the enumerator's two failure states; this pins the
# same two on the field's OTHER contributor, which had neither. `[ -f ]` has
# already said the file is there, so skipping it does not report "no
# swapfile" — it reports a total with a known hole in it, and here the hole is
# the whole of it: `swapon --show` succeeds empty, so the emitted figure was
# `swap_configured_mb=0` beside `swap_active_mb=0`, a fabricated measurement
# that also silences swap-configured-inactive, the one finding this field
# exists to expose. Absent is the honest answer, exactly as for swapon-broken.
B="$(mk_box swapfile-stat-broken)"
dd if=/dev/zero of="$B/root/swapfile" bs=1M count=8 status=none 2>/dev/null ||
  head -c 8388608 /dev/zero > "$B/root/swapfile"
cat > "$B/bin/stat" <<'EOF'
#!/bin/sh
echo "stat: cannot stat '$2': Permission denied" >&2
exit 2
EOF
chmod +x "$B/bin/stat"
out="$(run_probe "$B" BOX_CPU=2)"
hasnt "swapfile-stat-broken-configured-absent" "$out" "swap_configured_mb"
hasnt "swapfile-stat-broken-is-not-a-zero"     "$out" "swap_configured_mb=0"
# The silenced finding, asserted directly: this is the cost of the fabricated
# zero, and it is what makes the case blocking rather than cosmetic.
hasnt "swapfile-stat-broken-invents-no-finding" "$out" "swap-configured-inactive"
has   "swapfile-stat-broken-record-still-emits" "$out" "cores=2"
has   "swapfile-stat-broken-keeps-active"       "$out" "swap_active_mb=0"
# D6 is per-FIELD: the unreadable candidate costs this field and nothing else.
has   "swapfile-stat-broken-keeps-disk"         "$out" "disk_pct=48"
err="$(run_probe "$B" BOX_CPU=2 2>&1 >/dev/null)"
same "swapfile-stat-broken-is-silent-on-stderr" "" "$err"

# The same distinction from the other side, and the half that is invisible in
# the record: `stat` exits 0 but prints something that is not a number. The
# field goes absent either way — but without the numeric guard the non-number
# reaches `total=$((total + sz / 1024 / 1024))` and `set -u` aborts the reader
# with `vitals.sh: line NNN: not: unbound variable` on stderr. tick.sh runs
# the probe as `( … ) >>"$LOG" 2>&1`, so that line lands in duty.log, which is
# why the stderr assertion is the one that matters here.
B="$(mk_box swapfile-stat-garbled)"
dd if=/dev/zero of="$B/root/swapfile" bs=1M count=8 status=none 2>/dev/null ||
  head -c 8388608 /dev/zero > "$B/root/swapfile"
cat > "$B/bin/stat" <<'EOF'
#!/bin/sh
echo "not-a-number"
EOF
chmod +x "$B/bin/stat"
out="$(run_probe "$B" BOX_CPU=2)"
hasnt "swapfile-stat-garbled-configured-absent" "$out" "swap_configured_mb"
has   "swapfile-stat-garbled-record-still-emits" "$out" "cores=2"
err="$(run_probe "$B" BOX_CPU=2 2>&1 >/dev/null)"
same "swapfile-stat-garbled-is-silent-on-stderr" "" "$err"

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
hasnt "degrade-marks-no-memory-low" "$out" "memory-low"

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
hasnt "degrade-df-marks-no-disk-low"  "$out" "disk-low"

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

# A full twelve-reading monotonic rise is itself a disk-low finding, even
# below the point threshold. The trend is why the boot series exists.
B="$(mk_box series-rising)"
BC="$B/boot-check.log"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  boot_block "$BC" "2026-08-$(printf '%02d' "$i")T09:00:01+00:00" \
    "/dev/sda2        58G  2.5G   56G   $((36 + i))% /"
done
out="$(run_probe "$B" BOX_DISK=30GiB BOOT_CHECK_LOG="$BC")"
has "series-rising-is-a-disk-finding" "$out" \
  "finding=disk-low:want=under-90%,got=48%-after-12-rising-boots"

# Eleven rising points are not the declared twelve-boot window, and one fall
# inside a full window breaks monotonicity. Either shape must stay clean.
B="$(mk_box series-short)"
BC="$B/boot-check.log"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  boot_block "$BC" "2026-08-$(printf '%02d' "$i")T09:00:01+00:00" \
    "/dev/sda2        58G  2.5G   56G   $((20 + i))% /"
done
out="$(run_probe "$B" BOX_DISK=30GiB BOOT_CHECK_LOG="$BC")"
hasnt "series-short-is-not-a-disk-finding" "$out" "disk-low"

B="$(mk_box series-fell)"
BC="$B/boot-check.log"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  pct=$((30 + i)); [ "$i" -eq 8 ] && pct=32
  boot_block "$BC" "2026-08-$(printf '%02d' "$i")T09:00:01+00:00" \
    "/dev/sda2        58G  2.5G   56G   ${pct}% /"
done
out="$(run_probe "$B" BOX_DISK=30GiB BOOT_CHECK_LOG="$BC")"
hasnt "series-with-a-fall-is-not-a-disk-finding" "$out" "disk-low"

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

# --- 7. the tick call site (AC1) ---------------------------------------------
# Everything above drives the PROBE. AC1 is about the TICK — "every tick emits
# a vitals record" — and that lives in shared/bin/tick.sh, which nothing else
# in shared/test/ or fleet-floor/test/ reaches: delete the block and every
# other assertion in this file still passes. So these drive the real tick.sh
# against a fixture DUTY_DIR, and each one pins a claim the call site's own
# comment makes.
#
# The probe runs on the HOST here, not on a stub box: the subject is the call
# site's wiring — is it called, is the profile in scope, does it survive the
# lock and its own absence — and the readings themselves are covered above.
# The profile is therefore declared absurd (BOX_CPU=999) so the D3 comparison
# is a mismatch on any real host, however many cores it has.
mk_tick_dir() { # mk_tick_dir <name> — a fixture DUTY_DIR wired like a real box
  local d="$WORK/$1"
  mkdir -p "$d/bin" "$d/conf/roles"
  mkdir -p "$d/lib/common"
  cp "$SHARED/bin/vitals.sh" "$d/bin/vitals.sh"
  cp "$SHARED/lib/common/operating-limits.sh" "$d/lib/common/operating-limits.sh"
  cp "$SHARED/conf/fleet.defaults.conf" "$d/conf/fleet.defaults.conf"
  # The job the tick dispatches: writes the evidence line duty.sh writes, and
  # nothing else. tick.sh's contract is about that line's presence, so a stub
  # is the right subject — a real duty.sh would drag the whole engine in.
  cat > "$d/bin/duty.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') duty run start"
EOF
  chmod +x "$d/bin/duty.sh"
  # instance.conf names the roles; the role file carries the profile. Two
  # files, because that is how a minted box carries them and the call site
  # sources them in that order.
  printf 'BOT_ROLES="builder"\n' > "$d/conf/instance.conf"
  printf 'BOX_CPU=999\n' > "$d/conf/roles/builder.conf"
  echo "$d"
}
# No VITALS_SH, no CONF_DIR: both default off DUTY_DIR inside tick.sh, and the
# defaults are part of what is being tested — an installed box passes neither.
run_tick() { env DUTY_DIR="$1" bash "$SHARED/bin/tick.sh" duty; }
vitals_lines() { grep -c '^VITALS ' "$1" 2>/dev/null || true; }

D="$(mk_tick_dir tick-plain)"
run_tick "$D" >/dev/null 2>&1
tickrc=$?
LOGF="$D/duty.log"
log="$(cat "$LOGF" 2>/dev/null || true)"
same "tick-emits-exactly-one-vitals-line" "1" "$(vitals_lines "$LOGF")"
has  "tick-vitals-carries-the-fields"     "$log" "cores="
# The record is FIRST: emitted before the dispatch, so a job that hangs or a
# lock that is held cannot cost the reading.
same "tick-vitals-precedes-the-dispatch" "VITALS" \
  "$(head -1 "$LOGF" 2>/dev/null | cut -d' ' -f1)"
# The role profile is in scope AT the call site. Nothing above proves this:
# every other case exports BOX_CPU by hand, so a tick that never sourced
# conf/ would emit a findingless record and read as healthy.
has  "tick-sources-the-role-profile" "$log" "finding=cpu-profile-mismatch:want=999,"
# ...and the evidence contract the top of tick.sh is about is untouched by the
# fourth line: `duty run start` is still there, and the tick still exits 0.
has  "tick-keeps-the-evidence-line" "$log" "duty run start"
same "tick-exits-zero" "0" "$tickrc"

# MUST-FAIL: the probe moved inside the lock. A tick that skips is a box
# already wedged behind a stuck run — the box whose memory and disk a reader
# most wants — so the record must land on a SKIPPED tick too. Holding the
# lock is the only way to express that, and it is the assertion that reds if
# the call is moved below the flock line.
D="$(mk_tick_dir tick-locked)"
flock -n "$D/.duty.lock" -c 'sleep 3' >/dev/null 2>&1 &
lock_bg=$!
sleep 1
run_tick "$D" >/dev/null 2>&1
wait "$lock_bg" 2>/dev/null || true
LOGF="$D/duty.log"
log="$(cat "$LOGF" 2>/dev/null || true)"
same "tick-skipped-still-emits-vitals" "1" "$(vitals_lines "$LOGF")"
has  "tick-skipped-says-so"            "$log" "duty tick skipped:"
hasnt "tick-skipped-ran-no-job"        "$log" "duty run start"

# The probe is telemetry, and telemetry that can break the thing it observes
# is worse than no telemetry: a missing or unreadable vitals.sh costs the
# record and nothing else. This is the subshell guard at the call site, and
# it is what makes the block safe to have added to the only cron target.
D="$(mk_tick_dir tick-no-probe)"
rm -f "$D/bin/vitals.sh"
run_tick "$D" >/dev/null 2>&1
tickrc=$?
LOGF="$D/duty.log"
log="$(cat "$LOGF" 2>/dev/null || true)"
same "tick-without-probe-exits-zero"   "0" "$tickrc"
has  "tick-without-probe-still-ticks"  "$log" "duty run start"
same "tick-without-probe-emits-no-record" "0" "$(vitals_lines "$LOGF")"

# A box with no instance.conf yet — hired but not configured — still gets a
# record, just without the profile findings. The conf sourcing is best-effort
# by design, and `[ -r ]` on a missing file must not take the tick with it.
D="$(mk_tick_dir tick-no-conf)"
rm -rf "$D/conf"
run_tick "$D" >/dev/null 2>&1
LOGF="$D/duty.log"
log="$(cat "$LOGF" 2>/dev/null || true)"
same "tick-without-conf-still-emits" "1" "$(vitals_lines "$LOGF")"
hasnt "tick-without-conf-has-no-profile-finding" "$log" "profile-mismatch"
has  "tick-without-conf-still-ticks" "$log" "duty run start"

# The tick loads fleet defaults and the operator overlay before the probe. A
# standalone probe accepts env overrides above; these guards prove an installed
# tick actually supplies persistent fleet.conf values.
has "tick-loads-vitals-defaults" "$(sed -n '/fleet.defaults.conf/p' "$SHARED/bin/tick.sh")" \
  'fleet.defaults.conf'
has "tick-loads-vitals-operator-overlay" "$(sed -n '/fleet.conf/p' "$SHARED/bin/tick.sh")" \
  'fleet.conf'

# MUST-FAIL: a host-side threshold. The consoles quote generic finding tokens;
# neither reader may learn either finding name and re-derive it.
ROOT="$(dirname "$SHARED")"
for host_reader in "$ROOT/cli/crew" "$ROOT/fleet-floor/src/app.js" \
                   "$ROOT/fleet-floor/server/floor/units.py"; do
  if grep -Eq 'disk-low|memory-low|VITALS_(DISK|MEMORY)_LOW_PCT' "$host_reader"; then
    same "headroom-policy-stays-box-side: ${host_reader#"$ROOT/"}" clean contaminated
  else
    same "headroom-policy-stays-box-side: ${host_reader#"$ROOT/"}" clean clean
  fi
done

suite_finish
