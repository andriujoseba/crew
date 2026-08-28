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

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- field readers -----------------------------------------------------------
# Each prints its value and returns 0, or prints nothing and returns 1. A
# reader NEVER dies: the caller turns a non-zero return into an absent field.

v_cores() { nproc 2>/dev/null | grep -qE '^[0-9]+$' && nproc 2>/dev/null; }

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
  local total=0 found=1 sz
  # Active swap devices are configured by definition.
  while read -r sz; do
    [ -n "$sz" ] && { total=$((total + sz / 1024)); found=0; }
  done <<EOF
$(swapon --show=SIZE --bytes --noheadings 2>/dev/null | tr -d ' ')
EOF
  # A swapfile present but not swapped on is the finding this exists for. It
  # is counted as configured, which is what makes swap_configured disagree
  # with swap_active and produces the finding below.
  for f in "$VITALS_ROOT"swapfile "$VITALS_ROOT"swap.img; do
    if [ -f "$f" ]; then
      sz=$(stat -c %s "$f" 2>/dev/null) && [ -n "$sz" ] && {
        total=$((total + sz / 1024 / 1024)); found=0
      }
    fi
  done
  [ "$found" -eq 0 ] && echo "$total"
}

v_disk() { # prints "total_kb used_kb pct" for VITALS_ROOT
  df -Pk "$VITALS_ROOT" 2>/dev/null |
    awk 'NR==2 {gsub(/%/,"",$5); print $2, $3, $5; found=1} END {exit !found}'
}

v_platform() { uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

v_os() {
  # os-release first, uname -r as the fallback; a box with neither omits the
  # field rather than emitting "unknown", which would read as a measurement.
  if [ -r /etc/os-release ]; then
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
  local cores load mem disk swap_a swap_c plat os
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
      # Reported total is always a little under the provisioned figure
      # (firmware reservation), so the test is a 10% band, not equality — an
      # exact compare would mark every healthy box and the finding would be
      # ignored within a day.
      [ "$mem_total" -lt $((want * 9 / 10)) ] &&
      mark memory-profile-mismatch "${want}MiB" "${mem_total}MiB"
  fi

  if [ -n "${disk_total:-}" ] && [ -n "${BOX_DISK:-}" ]; then
    local wantd; wantd=$(profile_to_mib "$BOX_DISK") &&
      [ $((disk_total / 1024)) -lt $((wantd * 9 / 10)) ] &&
      mark disk-profile-mismatch "${wantd}MiB" "$((disk_total / 1024))MiB"
  fi

  printf '%s%s\n' "$out" "$FINDINGS"
}

# Sourced by the tick for the function; run directly it prints one record.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  emit_vitals
fi
