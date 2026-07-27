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

# --- credentials: read, never tested ---------------------------------------
#
# This probe used to run `gh auth status` and the agent profile's
# bot_cli_probe on every poll. Both touch the network — `gh auth status` is a
# real api.github.com round-trip (~450ms, and the single slowest thing in this
# file; everything else is a local read) — to re-answer a question whose
# answer changes when a token expires, i.e. about monthly. At a 60s poll that
# was ~7,000 GitHub requests a day per fleet to re-learn a constant.
#
# Both are now REPORTED BY THE FLOW instead of polled. The duty engine already
# talks to GitHub every tick (duty_attention runs first, for every role), so
# it is the thing that finds out first and for free:
#
#   .auth-fail.<svc>  — written at the moment a credential is rejected or found
#                       expired, cleared on the next success.
#                       `<iso8601> <what failed>`.
#
# One boolean per service, and no expiry date: providers express expiry four
# different ways and two of the four agent CLIs cannot answer locally at all,
# so the countdown was the flaky half. What survives is the stable half, and
# it is a stronger claim than the probe it replaces — a rejection means the
# credential could not do the WORK, not merely that it authenticates against
# `GET /`, which a token with the wrong scopes does happily.
#
# The wire keys stay `gh` and `vendor`, but `ok` is gone: absence of a failure
# is not proof of a credential, and a value that cannot tell those apart is how
# a logged-out box renders green.
#
# FOUR values, because three were one short. `flowing` claims the engine has
# been talking to this service and has not been rejected — but the first cut
# derived it from `VERSION` existing, and VERSION is written once by
# install.sh and never touched again. It records that the engine was
# INSTALLED, not that it has RUN. So a box hired last month with its cron
# since disarmed and its token expired last week records no rejection (nothing
# runs to be rejected), has a VERSION, and rendered `flowing` — exactly the
# "a logged-out box renders green" failure this value exists to prevent, with
# a comment above it reassuring the reader otherwise.
#
# `flowing` therefore requires a RECENT TICK as well: the engine must have
# logged something within two tick boundaries, the same death rule the floor
# and tick.sh already use. Installed-but-not-running is `stale` — not a
# failure, not a claim, just the honest fourth state.
#
#   unknown  no engine: nothing has ever run, so nothing is known
#   stale    engine installed but not ticking: cannot know, and says so
#   flowing  ticking, and no rejection recorded
#   missing  a rejection was recorded
#
# One marker file PER SERVICE. The first cut used a single .auth-fail and
# decided which service was broken by substring-matching the reason text — so a
# gh error mentioning the word "vendor" condemned the agent CLI too, and sent
# the operator to re-login the wrong thing.

# Age of the newest timestamped duty.log line, in seconds; empty if there is
# none. Computed here rather than left to the collector because the credential
# values are emitted here and must not disagree with themselves.
tick_age=""
if [ -r "$DUTY_DIR/duty.log" ]; then
  last_ts="$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
    "$DUTY_DIR/duty.log" 2>/dev/null | tail -1)"
  if [ -n "$last_ts" ]; then
    last_epoch="$(date -u -d "$last_ts" +%s 2>/dev/null || echo)"
    case "$last_epoch" in
      ''|*[!0-9]*) : ;;
      *) tick_age=$(( $(date -u +%s) - last_epoch )) ;;
    esac
  fi
fi
emit tickage "$tick_age"

for svc in gh vendor; do
  fail=""
  [ -f "$DUTY_DIR/.auth-fail.$svc" ] \
    && fail="$(head -1 "$DUTY_DIR/.auth-fail.$svc" 2>/dev/null | tr -d '\r')"
  if [ -n "$fail" ]; then
    emit "$svc" missing
    emit "authfail-$svc" "$fail"
  elif [ ! -s "$DUTY_DIR/VERSION" ]; then
    emit "$svc" unknown
  elif [ -n "$tick_age" ] && [ "$tick_age" -lt 600 ]; then
    emit "$svc" flowing
  else
    emit "$svc" stale
  fi
done

# How long the current duty run has held the lock, in seconds — duty.sh writes
# .duty.lock.since on entry and clears it on EXIT, so a value here means a run
# is in flight RIGHT NOW, and its age is that run's age.
#
# This is the wedge the SILENT rule cannot see. A duty session hung on a vendor
# CLI network call keeps ticking (tick.sh logs "tick skipped: previous run
# still holds the lock"), so duty.log stays fresh, cron reads healthy, and the
# floor renders a green box that has done nothing for 40 minutes — until the
# 1800s session timeout fires. tick.sh already computes this age for its log
# line; nothing had ever surfaced it to an operator.
if [ -f "$DUTY_DIR/.duty.lock.since" ]; then
  since="$(cat "$DUTY_DIR/.duty.lock.since" 2>/dev/null || echo)"
  case "$since" in
    ''|*[!0-9]*) : ;;   # absent or truncated mid-write — report nothing, not a bogus age
    *) emit lockheld "$(( $(date +%s) - since ))" ;;
  esac
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
