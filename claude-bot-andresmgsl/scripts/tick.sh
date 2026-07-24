# NOTE (crew copy): cron entrypoint — flocks duty.sh and logs one evidence line per 5-minute slot; fires every 5 minutes via crontab.
#!/usr/bin/env bash
# The cron entrypoint: one line of evidence per 5-minute slot, no
# exceptions (operator rule, 2026-07-23: passes are sharp every 5 minutes
# so a legitimate delay is distinguishable from an error — and never a
# self-paced monitor loop, whose drift is exactly what made delay and
# error indistinguishable). Three outcomes, all visible in duty.log:
#
#   * "duty run start" at the boundary — the normal pass;
#   * "tick skipped: previous duty run still holds the lock" — the
#     legitimate delay (a session is mid-flight; the next boundary picks
#     the work up);
#   * "tick FAILED: duty.sh exited N" — an actual error.
#
# Silence at a boundary now means exactly one thing: cron itself is dead.
#
# DUTY_LOG/DUTY_LOCK/DUTY_SH are overridable for tests only.
set -u

LOG="${DUTY_LOG:-$HOME/duty/duty.log}"
LOCK="${DUTY_LOCK:-$HOME/duty/.lock}"
DUTY="${DUTY_SH:-$HOME/duty/duty.sh}"

# rc is captured on the same line as the command runs: `rc=$?` after an
# `if` compound would read the if's own status (0 when no branch ran) —
# the first draft of this file shipped exactly that bug.
flock -n -E 99 "$LOCK" "$DUTY" >> "$LOG" 2>&1
rc=$?

[ "$rc" -eq 0 ] && exit 0

ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
if [ "$rc" -eq 99 ]; then
  since=$(ps -o etime= -p "$(pgrep -f 'duty-snapshot' | head -1)" 2>/dev/null | tr -d ' ')
  echo "$ts tick skipped: previous duty run still holds the lock${since:+ (running $since)}" >> "$LOG"
else
  echo "$ts tick FAILED: duty.sh exited $rc" >> "$LOG"
fi
