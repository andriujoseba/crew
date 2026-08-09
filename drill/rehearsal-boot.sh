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

# One read of the box feeds both assertions. A box that cannot be read leaves
# the block empty, which each assertion reports as what it read — the file
# missing or empty is already `boot check ran`, which fires first.
rehearsal_boot_load() {
  # shellcheck disable=SC2034  # sourced global consumed by the assertions below
  REHEARSAL_BOOT_BLOCK="$(bx "cat ~/duty/boot-check.log" 2>/dev/null \
    | rehearsal_boot_last_block)"
}

# The verdict, not the transcript: name the agent the round was given and
# quote the one line the assertion read, in the shape #341 settled on step 9.
rehearsal_boot_probe_ok() {  # rehearsal_boot_probe_ok <agent>
  local agent="$1" name line verdict
  name="boot check: cli probe verdict is ok for $agent"
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
