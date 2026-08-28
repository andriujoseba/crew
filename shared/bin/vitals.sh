#!/usr/bin/env bash
# vitals.sh — one box vitals probe, emitted per tick, read by `crew status`
# and by the floor from the SAME line so the two cannot disagree (#483 D1).
#
# The record is one space-delimited `key=value` line, the shape SESSION END
# already uses (shared/lib/common/session.sh) — one line per tick, greppable,
# and parseable by both readers without a JSON dependency on a box that may
# not have `jq`.
#
# THE PROBE'S JOB IS THE PAIR, NOT THE NUMBER (#483 D4). Free memory and free
# disk each look explicable alone; only `swap_configured` beside `swap_active`
# says that an 8 GiB /swapfile is present and doing nothing, which is the
# claude-triage state the baseline measured and nothing else caught. So every
# field that is only meaningful next to another is emitted next to it, and the
# findings below are derived from pairs.
#
# Deliberately `set -u` only, never -e: D6 is per-field degradation, and a
# probe that exits on the first unreadable figure costs the other eight. Each
# reader is its own function, each failure is that field's absence, and the
# record still emits.
set -u

VITALS_ROOT="${VITALS_ROOT:-/}"
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
BOOT_CHECK_LOG="${BOOT_CHECK_LOG:-$DUTY_DIR/boot-check.log}"
# How many boot readings the disk series carries. See v_disk_series: the field
# is emitted on every record, so it needs a ceiling or it grows with the box's
# age. Twelve is the length of the series the issue's baseline measured, which
# is the shortest window in which that finding is still visible.
VITALS_SERIES_MAX="${VITALS_SERIES_MAX:-12}"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- field readers -----------------------------------------------------------
# Each prints its value and returns 0, or prints nothing and returns 1. A
# reader NEVER dies: the caller turns a non-zero return into an absent field.

v_cores() { nproc 2>/dev/null | grep -E '^[0-9]+$'; }

v_load1() { awk '{print $1}' /proc/loadavg 2>/dev/null | grep -E '^[0-9.]+$'; }

# free -m in one read: total, shared and available are three numbers off one
# line, and reading them separately would let them come from different moments.
v_mem() { # prints "total shared available"
  free -m 2>/dev/null | awk '/^Mem:/ {print $2, $5, $7; found=1} END {exit !found}'
}

# Swap has TWO facts and they are not the same fact (D4). `swapon --show` is
# what the kernel has ACTIVE; a swapfile on disk is what is CONFIGURED. The
# claude-triage finding is exactly the case where the second is non-zero and
# the first is zero, so they are separate fields and neither is derived from
# the other.
v_swap_active_mb() {
  free -m 2>/dev/null | awk '/^Swap:/ {print $2; found=1} END {exit !found}'
}

v_swap_configured_mb() {
  local total=0 sz name extra active="" listed
  # THREE states, not two, because "no swap" and "cannot tell" are different
  # answers and only one of them is an absent field. `swapon --show` is the
  # sole enumerator of active swap, so its exit status decides whether this
  # field is measurable at all:
  #
  #   succeeds, lists nothing  -> a measured ZERO. Emitted as 0.
  #   fails, missing, garbled  -> unreadable. Absent, per D6.
  #
  # Reporting the zero as an absence was the more damaging of the two,
  # because `swap_active_mb` comes off `free`, which prints a Swap: line on
  # every box. So a box with no swap emitted active=0 with its PAIR missing,
  # and D4's whole point is that neither number means anything alone: both
  # readers drop the swap row, and "no swap configured" becomes
  # indistinguishable from "the swap probe is broken".
  listed=$(swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null) || return 1

  # NAME as well as SIZE. Identity is what stops one resource being counted
  # twice: an active /swapfile is a device HERE and a file on disk THERE, and
  # it is the same 8 MiB either way. `--bytes` means BYTES, so the size
  # converts twice — the same two divisions the swapfile branch below applies
  # to `stat -c %s`. One field, two contributors, and they only add up if
  # both arrive in MiB.
  #
  # `read` splits on whitespace runs, which absorbs the column padding
  # smartcols right-aligns SIZE with. A line this cannot resolve into
  # exactly name + numeric size is not parsed leniently: it returns 1 and the
  # field goes absent, because a lenient parse here either invents a zero or
  # loses the identity the dedup below depends on.
  while read -r name sz extra; do
    [ -n "$name" ] || continue
    case "${sz:-}" in ""|*[!0-9]*) return 1 ;; esac
    [ -z "${extra:-}" ] || return 1
    total=$((total + sz / 1024 / 1024))
    active="$active $name"
  done <<EOF
$listed
EOF

  # A swapfile present but not swapped on is the finding this exists for. It
  # is counted as configured, which is what makes swap_configured disagree
  # with swap_active and produces the finding below — but only when it is not
  # ALREADY counted above as an active device. Deduplicated by path and not
  # by size, because two genuinely distinct 8 MiB resources must still sum.
  for f in "$VITALS_ROOT"swapfile "$VITALS_ROOT"swap.img; do
    case " $active " in *" $f "*) continue ;; esac
    if [ -f "$f" ]; then
      sz=$(stat -c %s "$f" 2>/dev/null) && [ -n "$sz" ] &&
        total=$((total + sz / 1024 / 1024))
    fi
  done
  echo "$total"
}

v_disk() { # prints "total_kb used_kb pct" for VITALS_ROOT
  df -Pk "$VITALS_ROOT" 2>/dev/null |
    awk 'NR==2 {gsub(/%/,"",$5); print $2, $3, $5; found=1} END {exit !found}'
}

# --- the disk series (D5) ----------------------------------------------------
# The boot gate in shared/bin/duty.sh has appended `df -h /` to boot-check.log
# once per boot since the box was hired, so the disk series has weeks of
# history behind it before this probe's first tick ever runs. Reading it is
# what makes the series start where the BOX did rather than where the
# telemetry did — and on the baseline box the series IS the finding: `/` rose
# monotonically across twelve readings, 9% → 48%, and no single reading says
# that.
#
# Emitted on EVERY record and not once, because both readers take the newest
# VITALS line and nothing else. A series stitched across lines would be a
# second parse, in two languages, over a log that rotates — the first thing
# the two readers would disagree about, which is the property D1 exists to
# make impossible.
#
# The stamp is carried VERBATIM from the header the boot gate wrote. That is
# `date -Is`, so it carries the box's own offset; re-normalising an offset
# this probe did not write is how a series acquires a timezone bug.
#
# Prints `<stamp>@<pct>[,<stamp>@<pct>]…`, oldest first. The record's own
# `disk_pct=` is the LIVE point and is deliberately not appended here: one was
# measured a moment ago and the others were read out of a log, and a reader
# that cannot tell them apart cannot say which is which.
v_disk_series() {
  [ -r "$BOOT_CHECK_LOG" ] || return 1
  # Pairing is per BLOCK, not per line: `gh auth status` writes a variable
  # number of lines between the header and the df line, and on a failed boot
  # it writes arbitrary text. So each header opens a block and the FIRST df
  # -shaped line in it closes it.
  #
  # The df shape is anchored on the tail of the line, never on the field
  # count: `df -h` wraps a long device name onto a second line, and `tail -1`
  # then hands over a five-field row instead of six. Both forms end
  # `<pct>% /`, and nothing else the boot gate writes does.
  #
  # Character classes rather than `{4}`: an awk without --re-interval treats
  # the interval as literal text and the guard silently matches nothing.
  awk -v max="$VITALS_SERIES_MAX" '
    /^== boot check / { stamp = $4; have = 0; next }
    !have && stamp != "" && NF >= 5 && $NF == "/" && $(NF-1) ~ /^[0-9]+%$/ {
      if (stamp ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]/) {
        pct = $(NF-1); sub(/%/, "", pct)
        n++; s[n] = stamp "@" pct
      }
      have = 1
    }
    END {
      if (n == 0) exit 1
      from = (n > max) ? n - max + 1 : 1
      for (i = from; i <= n; i++) out = out (i == from ? "" : ",") s[i]
      print out
    }
  ' "$BOOT_CHECK_LOG" 2>/dev/null
}

v_platform() { uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

v_os() {
  # os-release first, uname -r as the fallback; a box with neither omits the
  # field rather than emitting "unknown", which would read as a measurement.
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091  # a runtime file, not an input to the check
    ( . /etc/os-release 2>/dev/null; [ -n "${VERSION_ID:-}" ] &&
      echo "${ID:-linux}-${VERSION_ID}" || echo "${ID:-}" ) | grep -E '.'
  else
    uname -r 2>/dev/null
  fi
}

# --- profile comparison (D3) -------------------------------------------------
# BOX_CPU / BOX_MEMORY / BOX_DISK are declared per role in
# shared/conf/roles/*.conf. A reading that disagrees is a FINDING ON THE
# RECORD, not something left for a human to notice — that is the cheap half of
# this probe and the half that catches provisioning drift.

# "8GiB" / "60GiB" / "4096MiB" -> MiB. Unparseable returns 1 and the
# comparison is skipped rather than guessed.
profile_to_mib() {
  printf '%s' "${1:-}" | awk '
    match($0, /^([0-9]+)(GiB|G|MiB|M)?$/, m) { print (m[2]=="MiB"||m[2]=="M") ? m[1] : m[1]*1024; ok=1 }
    END { exit !ok }
  ' 2>/dev/null || {
    # ugrep/mawk lack match() with captures; fall back to sed+case.
    local n u
    n=$(printf '%s' "${1:-}" | sed -n 's/^\([0-9]\{1,\}\)\([A-Za-z]*\)$/\1/p')
    u=$(printf '%s' "${1:-}" | sed -n 's/^\([0-9]\{1,\}\)\([A-Za-z]*\)$/\2/p')
    [ -n "$n" ] || return 1
    case "$u" in
      MiB|M) echo "$n" ;;
      GiB|G|"") echo $((n * 1024)) ;;
      *) return 1 ;;
    esac
  }
}

# The memory and disk bands are TWO-SIDED, and one function owns the rule so
# the two figures cannot acquire different ones.
#
# The low side cannot be equality: reported total is always a little under the
# provisioned figure (firmware reservation reads 7876 MiB on an 8 GiB box), so
# an exact compare would mark every healthy box and the finding would be
# ignored inside a day. That argument is for TOLERANCE, though, and not for
# one-sidedness — nothing explains a box reading over its profile except the
# profile never having been applied, which is exactly the provisioning drift
# D3 exists to catch. AC3 says a reading that DISAGREES is marked, and a box
# minted from a 4 GiB profile that came up with 8 disagrees as loudly as one
# that came up with 2. `cores` has always marked drift in both directions;
# these two now do the same.
outside_band() { # outside_band <measured_mib> <want_mib>
  [ "$1" -lt $(( $2 * 9 / 10 )) ] || [ "$1" -gt $(( $2 * 11 / 10 )) ]
}

# Disagreement is reported with BOTH numbers: a finding that says only
# "mismatch" sends the reader back to the box to find out what it read.
mark() { # mark <name> <want> <got>
  FINDINGS="${FINDINGS} finding=$1:want=$2,got=$3"
}

# --- the record --------------------------------------------------------------
emit_vitals() {
  # Declared and assigned separately: `local x=$(cmd)` masks the command's
  # return value behind local's own, which is exactly the mistake every reader
  # below is written to avoid (SC2155).
  local out FINDINGS=""
  out="VITALS ts=$(ts)"
  local cores load mem disk swap_a swap_c plat os series
  local mem_total mem_shared mem_avail disk_total disk_used disk_pct

  cores=$(v_cores) && out="$out cores=$cores"
  load=$(v_load1) && out="$out load1=$load"

  if mem=$(v_mem); then
    mem_total=${mem%% *}; mem_shared=$(echo "$mem" | cut -d' ' -f2)
    mem_avail=${mem##* }
    out="$out mem_total_mb=$mem_total mem_shared_mb=$mem_shared mem_avail_mb=$mem_avail"
  fi

  # Both swap fields or neither pairing is meaningful; each still degrades on
  # its own, and the finding below fires only when both were readable.
  swap_a=$(v_swap_active_mb) && out="$out swap_active_mb=$swap_a"
  swap_c=$(v_swap_configured_mb) && out="$out swap_configured_mb=$swap_c"

  if disk=$(v_disk); then
    disk_total=${disk%% *}; disk_used=$(echo "$disk" | cut -d' ' -f2)
    disk_pct=${disk##* }
    out="$out disk_total_mb=$((disk_total / 1024)) disk_used_mb=$((disk_used / 1024)) disk_pct=$disk_pct"
  fi

  # D5. Independent of the live disk read above, deliberately: a box whose
  # `df` has just failed still has its history, and the series is the half a
  # reader cannot reconstruct from anywhere else.
  series=$(v_disk_series) && out="$out disk_series=$series"

  plat=$(v_platform) && out="$out platform=$plat"
  os=$(v_os) && out="$out os=$os"

  # --- findings ---
  # (a) configured but not active — the pair the baseline found.
  if [ -n "${swap_a:-}" ] && [ -n "${swap_c:-}" ] &&
     [ "$swap_c" -gt 0 ] && [ "$swap_a" -eq 0 ]; then
    FINDINGS="${FINDINGS} finding=swap-configured-inactive:configured_mb=$swap_c,active_mb=0"
  fi

  # (b) profile drift, one comparison per declared figure.
  [ -n "${cores:-}" ] && [ -n "${BOX_CPU:-}" ] &&
    [ "$cores" != "$BOX_CPU" ] && mark cpu-profile-mismatch "$BOX_CPU" "$cores"

  if [ -n "${mem_total:-}" ] && [ -n "${BOX_MEMORY:-}" ]; then
    local want; want=$(profile_to_mib "$BOX_MEMORY") &&
      outside_band "$mem_total" "$want" &&
      mark memory-profile-mismatch "${want}MiB" "${mem_total}MiB"
  fi

  if [ -n "${disk_total:-}" ] && [ -n "${BOX_DISK:-}" ]; then
    local wantd; wantd=$(profile_to_mib "$BOX_DISK") &&
      outside_band $((disk_total / 1024)) "$wantd" &&
      mark disk-profile-mismatch "${wantd}MiB" "$((disk_total / 1024))MiB"
  fi

  printf '%s%s\n' "$out" "$FINDINGS"
}

# Sourced by the tick for the function; run directly it prints one record.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  emit_vitals
fi
