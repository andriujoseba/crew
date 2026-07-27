#!/usr/bin/env bash
# probe.sh — read one box's duty evidence, from the HOST, over `box exec`.
#
#   box exec <name> -- bash -lc "$(cat probe.sh)" < shared/conf/agents/<a>.conf
#
# Nothing is installed in the box and nothing is written except the throwaway
# agent-profile copy vendor probing already used (crew's vendor_probe). The
# box stays a read target: the operator host holds the control, exactly as it
# does for `crew status`. This is the whole box-side half of #38/#39 — there
# is no daemon, no collector client, no outbound call from the box.
#
# Output is a line-oriented record, NOT JSON: building JSON in bash across
# duty.log lines that contain quotes, braces and backslashes is how you ship a
# parser bug. Every line is `::<key> <value>`; the log section is delimited so
# its content is never parsed as keys.
#
# set -u only, never -e: a missing file or a vendor CLI that exits non-zero is
# a fact to report, not a reason to return nothing (the same reasoning as
# tick.sh's rc dispatch).
set -u

DUTY_DIR="${DUTY_DIR:-$HOME/duty}"

emit() { printf '::%s %s\n' "$1" "${2-}"; }

# The agent profile arrives on stdin so this works on unhired boxes too.
conf=/tmp/.crew-floor-probe.conf
if [ ! -t 0 ]; then cat >"$conf" 2>/dev/null; fi

emit engine "$(head -1 "$DUTY_DIR/VERSION" 2>/dev/null | tr -d '\r')"
# The agent the box was ACTUALLY installed as, from the instance.conf
# install.sh wrote — not what a roster claims about it.
#
# Nothing used to read this, and that is what made a whole class of bug silent:
# both readers (the floor here, and `crew status`) take the roster's agent
# column on faith and hand it straight to the vendor probe, so a roster that
# misdeclares an agent produces a permanently red vendor column with nothing
# saying the ROSTER is what is wrong. Reported so a declaration can be checked
# against ground truth instead of assumed.
#
# Parsed, not sourced: this file is read on every poll of every box, and
# sourcing a config to learn one string is a much bigger blast radius than
# reading it.
emit agent "$(sed -n 's/^BOT_AGENT=//p' "$DUTY_DIR/conf/instance.conf" 2>/dev/null \
  | head -1 | tr -d '"'\''\r')"
emit uptime "$(cut -d. -f1 /proc/uptime 2>/dev/null)"
emit now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if gh auth status >/dev/null 2>&1; then emit gh ok; else emit gh missing; fi

# bot_cli_probe is the agent profile's own liveness check — the same one
# `crew status` uses, so the floor and the CLI can never disagree about
# whether a vendor CLI is logged in.
if [ -s "$conf" ]; then
  # shellcheck disable=SC1090
  if ( source "$conf" && bot_cli_probe ) >/dev/null 2>&1; then
    emit vendor ok
  else
    emit vendor missing
  fi
else
  emit vendor unknown
fi

# Cron is the liveness contract: tick.sh guarantees one duty.log line per
# 5-minute boundary, so silence means cron itself is dead (#38's death rule).
emit cron "$(crontab -l 2>/dev/null | grep -cE '^[^#].*tick\.sh')"
emit paused "$(crontab -l 2>/dev/null | grep -cE '^#[[:space:]]*CREW-FLOOR-PAUSED')"

# repos.txt is the box's real work scope — the floor shows it instead of
# inventing one.
if [ -f "$DUTY_DIR/repos.txt" ]; then
  emit repos "$(grep -vE '^[[:space:]]*(#|$)' "$DUTY_DIR/repos.txt" 2>/dev/null | tr '\n' ' ')"
fi

# run_session names these itself, from a UTC stamp and a sanitized key
# (`${key//[\/#]/_}`), so there is nothing here for `ls` to mangle and the
# lexical order IS the chronological one.
# shellcheck disable=SC2012
emit sessionlogs "$(ls -1 "$DUTY_DIR/logs" 2>/dev/null | tail -40 | tr '\n' ' ')"

# 600 lines ≈ several hours of ticks at one run per 5 minutes — enough for the
# session history and 24h metrics the console shows, small enough to move over
# `box exec` every poll.
echo "::logstart"
tail -n 600 "$DUTY_DIR/duty.log" 2>/dev/null | tr -d '\r'
echo "::logend"
