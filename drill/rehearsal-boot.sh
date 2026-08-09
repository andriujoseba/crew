#!/usr/bin/env bash
# Sourceable boot-check assertions for drill/rehearsal.sh. These stay separate
# so their failure cases can be driven against a fixture log under a stubbed
# `bx()`, with no drill box and no credentials (#427).
#
# What they are for: `test -s ~/duty/boot-check.log` asserts the boot gate
# RAN. After #240 the interesting question is what it SAID — the gate writes
# `cli probe: ok` or `cli probe: FAILED` from the drilled agent's own
# `bot_cli_probe`, and a log full of `WARN` passes `test -s` unread.

# The boot gate APPENDS one block per boot to ~/duty/boot-check.log, headed
# `== boot check <date> ==`. Every assertion here reads the LAST block only:
# a box that is drilled creds-free, logged in and re-drilled carries the
# creds-free block forever, so a whole-file read would answer for a boot
# other than the one under test.
#
# A log with no header at all is passed through whole rather than swallowed:
# an unrecognised shape must reach the assertion and red there naming what it
# read, not arrive as an empty string that reds for the wrong reason.
rehearsal_boot_last_block() {
  tr -d '\r' | awk '
    /^== boot check / { block = "" }
    { block = block $0 "\n" }
    END { printf "%s", block }
  '
}

# One read of the box feeds both assertions, so whether that read SUCCEEDED is
# a fact both of them need: a box that stopped answering and a box whose boot
# check is clean both arrive here as an empty block, and an assertion that
# cannot tell them apart scores silence as proof — the `test -s` mistake this
# file exists to undo, one level down. The read's own exit status is the only
# thing that separates them (`boot check ran` is a SEPARATE box request, and a
# box can stop answering between the two), so keep it out of the pipeline,
# where the status would be `awk`'s and always 0, and publish it.
rehearsal_boot_load() {
  local raw
  REHEARSAL_BOOT_BLOCK=""
  REHEARSAL_BOOT_READ_OK=0
  raw="$(bx "cat ~/duty/boot-check.log" 2>/dev/null)" || return 1
  REHEARSAL_BOOT_READ_OK=1
  # shellcheck disable=SC2034  # sourced global consumed by the assertions below
  REHEARSAL_BOOT_BLOCK="$(printf '%s\n' "$raw" | rehearsal_boot_last_block)"
}

# The one thing neither assertion may answer: a box that did not come back.
# Both call this first, so an unreadable log is reported as an unreadable log
# in both rows, rather than as whatever the empty block happens to look like
# to each of them.
rehearsal_boot_read_failed() {  # rehearsal_boot_read_failed <agent> <name>
  [ "${REHEARSAL_BOOT_READ_OK:-0}" -eq 1 ] && return 1
  echo "  read: nothing — ~/duty/boot-check.log did not come back from the box for $1"
  fail "$2"
  return 0
}

# The verdict, not the transcript: name the agent the round was given and
# quote the one line the assertion read, in the shape #341 settled on step 9.
rehearsal_boot_probe_ok() {  # rehearsal_boot_probe_ok <agent>
  local agent="$1" name line verdict
  name="boot check: cli probe verdict is ok for $agent"
  rehearsal_boot_read_failed "$agent" "$name" && return 1
  line="$(printf '%s\n' "${REHEARSAL_BOOT_BLOCK:-}" \
    | grep -E '^cli probe:' | tail -1)"
  if [ -z "$line" ]; then
    echo "  read: no 'cli probe:' line in the last boot block for $agent"
    fail "$name"
    return 1
  fi
  verdict="${line#cli probe:}"
  verdict="${verdict# }"
  if [ "$verdict" = ok ]; then
    ok "$name"
    return 0
  fi
  echo "  read: $line"
  echo "  verdict '$verdict' for $agent, expected 'ok'"
  fail "$name"
  return 1
}

# Quote the first WARN and count the rest: a boot check that warns twenty
# times is one finding, and twenty quoted lines is the transcript #341 ruled
# out.
rehearsal_boot_warn_free() {  # rehearsal_boot_warn_free <agent>
  local agent="$1" name hits count
  name="boot check: no WARN for $agent"
  rehearsal_boot_read_failed "$agent" "$name" && return 1
  # A read that succeeded and returned nothing is still nothing: `grep` finding
  # no WARN in an empty block certifies the box, and it never saw one.
  if [ -z "${REHEARSAL_BOOT_BLOCK:-}" ]; then
    echo "  read: an empty last boot block for $agent — no WARN in nothing is not a clean boot"
    fail "$name"
    return 1
  fi
  hits="$(printf '%s\n' "${REHEARSAL_BOOT_BLOCK:-}" | grep -F WARN)" || hits=""
  if [ -z "$hits" ]; then
    ok "$name"
    return 0
  fi
  count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  echo "  read: $count WARN line(s) in the last boot block for $agent, first:"
  printf '%s\n' "$hits" | head -1 | sed 's/^/    /'
  fail "$name"
  return 1
}
