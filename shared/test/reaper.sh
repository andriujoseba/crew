#!/usr/bin/env bash
# shared/test/reaper.sh — standalone reaper subject suite (#457).
#
# Every sweep here runs against a fabricated tree under a temporary HOME. The
# module resolves its roots from $HOME at CALL time precisely so this is
# possible: a suite that had to point the reaper at the real ~/.claude would
# be a suite nobody could run twice.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"
# shellcheck source=shared/lib/duty-reaper.sh
source "$SHARED/lib/duty-reaper.sh"

REAP_MOD="$SHARED/lib/duty-reaper.sh"
REAP_CONF="$SHARED/conf/fleet.defaults.conf"
DUTYSH="$SHARED/bin/duty.sh"
# A CLI name nothing on any box is running, so the live-session probe answers
# "no session" for every case that is not about liveness.
DEAD_CLI="$TMP/reaper-absent-cli"

# reaper_home NAME — a fabricated box home with both class roots present.
reaper_home() {
  local h="$TMP/$1"
  mkdir -p "$h/.claude/projects/proj-a" "$h/.cache" "$h/.npm"
  printf '%s' "$h"
}

# reaper_run HOME CLI — one whole sweep, stdout captured. The atime prober is
# stubbed by default so the sweep cases are deterministic on any filesystem;
# the prober itself is tested on its own below, against the real one.
# shellcheck disable=SC2317  # the stubs run inside the sourced sweep
reaper_run() {
  local home="$1" cli="$2"
  (
    HOME="$home"
    BOT_CLI_CMD=("$cli")
    REAPER_TRANSCRIPT_DAYS="${REAP_TDAYS:-14}"
    REAPER_CACHE_DAYS="${REAP_CDAYS:-30}"
    _reaper_atime_advances() { return "${REAP_ATIME_RC:-0}"; }
    duty_reaper
  )
}

state() { [ -e "$1" ] && printf 'present' || printf 'absent'; }
class_line() { grep -c "reaper: $2 reclaimed" <<<"$1" | tr -d ' '; }

# --- the module is sourceable standalone, with no side effect ---------------
# The precedent is agent-conf-<a>-standalone: source it in a bare shell and
# ask only that the contract function exists afterwards. A module that
# swept, logged or read a path AT SOURCE TIME would be a module duty.sh could
# not source before deciding whether the interval had elapsed.
if bash -c '. "$1"; type duty_reaper >/dev/null; type reaper_interval >/dev/null' _ "$REAP_MOD"; then
  r1=sourceable
else
  r1=broken
fi
t reaper-module-standalone sourceable "$r1"
t reaper-module-source-is-silent "" \
  "$(bash -c '. "$1"' _ "$REAP_MOD" 2>&1)"

# --- retention, both directions (transcripts) -------------------------------
H1="$(reaper_home h1)"
head -c 100 /dev/zero >"$H1/.claude/projects/proj-a/aged.jsonl"
head -c 100 /dev/zero >"$H1/.claude/projects/proj-a/fresh.jsonl"
printf 'not a transcript\n' >"$H1/.claude/projects/proj-a/aged.log"
touch -d '30 days ago' "$H1/.claude/projects/proj-a/aged.jsonl" \
  "$H1/.claude/projects/proj-a/aged.log"
OUT1="$(reaper_run "$H1" "$DEAD_CLI")"
t reaper-transcript-aged-removed absent "$(state "$H1/.claude/projects/proj-a/aged.jsonl")"
# The case that reds a sweep with no age predicate at all.
t reaper-transcript-fresh-kept present "$(state "$H1/.claude/projects/proj-a/fresh.jsonl")"
# The sweep owns one file type. Anything else under the tree is somebody
# else's, however old it is.
t reaper-transcript-non-transcript-kept present "$(state "$H1/.claude/projects/proj-a/aged.log")"
t reaper-transcript-logs-exact-bytes 1 \
  "$(grep -c 'transcripts reclaimed 100 bytes in 1 files older than 14d' <<<"$OUT1" | tr -d ' ')"
t reaper-transcript-logs-one-line 1 "$(class_line "$OUT1" transcripts)"
t reaper-caches-logs-one-line 1 "$(class_line "$OUT1" caches)"

# --- the live session's own record ------------------------------------------
# The exclusion is whole-class, because per-file is not knowable from outside
# the CLI: it holds no descriptor on the transcript it is writing and does not
# carry the session id in its own environment. So the assertion is the one the
# criterion asks for — an aged transcript survives while a session is live —
# and it reds the moment the exclusion is removed.
H2="$(reaper_home h2)"
head -c 100 /dev/zero >"$H2/.claude/projects/proj-a/aged.jsonl"
touch -d '30 days ago' "$H2/.claude/projects/proj-a/aged.jsonl"
LIVE_CLI="$TMP/reaper-live-cli"
cp "$(command -v sleep)" "$LIVE_CLI"
"$LIVE_CLI" 30 &
LIVE_PID=$!
OUT2="$(reaper_run "$H2" "$LIVE_CLI")"
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
t reaper-live-session-keeps-aged-transcript present \
  "$(state "$H2/.claude/projects/proj-a/aged.jsonl")"
t reaper-live-session-says-why 1 \
  "$(grep -c 'transcripts reclaimed 0 bytes — held, a session is live' <<<"$OUT2" | tr -d ' ')"
# A hold is still one line with a byte figure: silence is what makes a held
# reaper indistinguishable from an absent one.
t reaper-live-session-logs-one-line 1 "$(class_line "$OUT2" transcripts)"
# ...and the dead session of the SAME box is not mistaken for a live one, or
# the class would be held forever on every box that has ever run a session.
t reaper-dead-cli-is-not-live absent "$(state "$H1/.claude/projects/proj-a/aged.jsonl")"

# A profile with no CLI command is "cannot tell", which holds and warns —
# never "no session", which would delete under a live one.
H3="$(reaper_home h3)"
head -c 100 /dev/zero >"$H3/.claude/projects/proj-a/aged.jsonl"
touch -d '30 days ago' "$H3/.claude/projects/proj-a/aged.jsonl"
OUT3="$(
  HOME="$H3"
  BOT_CLI_CMD=()
  # shellcheck disable=SC2317
  _reaper_atime_advances() { return 0; }
  duty_reaper
)"
t reaper-unknowable-liveness-holds present "$(state "$H3/.claude/projects/proj-a/aged.jsonl")"
t reaper-unknowable-liveness-warns 1 \
  "$(grep -c 'WARN: reaper: cannot tell whether a session is live' <<<"$OUT3" | tr -d ' ')"

# --- a box with no transcript root at all ----------------------------------
H4="$TMP/h4"
mkdir -p "$H4/.cache"
OUT4="$(reaper_run "$H4" "$DEAD_CLI")"
t reaper-absent-transcript-root-still-logs 1 "$(class_line "$OUT4" transcripts)"
t reaper-absent-transcript-root-is-zero 1 \
  "$(grep -c 'transcripts reclaimed 0 bytes — no ' <<<"$OUT4" | tr -d ' ')"

# --- the caches: by entry, and by last USE ---------------------------------
H5="$(reaper_home h5)"
mkdir -p "$H5/.cache/stale/sub" "$H5/.cache/live" "$H5/.npm/stale" "$H5/.npm/live"
head -c 1000 /dev/zero >"$H5/.cache/stale/sub/blob"
head -c 1000 /dev/zero >"$H5/.cache/live/blob"
head -c 1000 /dev/zero >"$H5/.npm/stale/blob"
head -c 1000 /dev/zero >"$H5/.npm/live/blob"
# The measured regression: an entry BUILT long ago and READ yesterday. An
# mtime sweep deletes it; this one must not.
mkdir -p "$H5/.cache/old-build-recent-use"
head -c 1000 /dev/zero >"$H5/.cache/old-build-recent-use/blob"
touch -m -d '90 days ago' "$H5/.cache/old-build-recent-use/blob"
touch -a -d '60 days ago' "$H5/.cache/stale/sub/blob" "$H5/.npm/stale/blob"
touch -a "$H5/.cache/live/blob" "$H5/.npm/live/blob" \
  "$H5/.cache/old-build-recent-use/blob"
OUT5="$(reaper_run "$H5" "$DEAD_CLI")"
t reaper-cache-unused-entry-removed absent "$(state "$H5/.cache/stale")"
t reaper-cache-used-entry-kept present "$(state "$H5/.cache/live")"
t reaper-npm-unused-entry-removed absent "$(state "$H5/.npm/stale")"
t reaper-npm-used-entry-kept present "$(state "$H5/.npm/live")"
t reaper-cache-old-build-recent-use-kept present "$(state "$H5/.cache/old-build-recent-use")"
t reaper-cache-entry-is-whole absent "$(state "$H5/.cache/stale/sub/blob")"
t reaper-cache-counts-two-entries 1 \
  "$(grep -c 'caches reclaimed [0-9]* bytes in 2 entries unused for 30d' <<<"$OUT5" | tr -d ' ')"
t reaper-cache-logs-one-line 1 "$(class_line "$OUT5" caches)"
REAP_BYTES="$(sed -n 's/.*caches reclaimed \([0-9]*\) bytes.*/\1/p' <<<"$OUT5")"
if [ -n "$REAP_BYTES" ] && [ "$REAP_BYTES" -ge 2000 ]; then r1=counted; else r1="$REAP_BYTES"; fi
t reaper-cache-byte-figure-covers-both-entries counted "$r1"

# --- a scan or a removal that did not finish HOLDS (#540, round 1) ---------
# The blocking defect of round 1: the cache predicate read find's OUTPUT and
# discarded its STATUS, so "I could not look inside this entry" scored
# identically to "I looked and nothing has been read", and the unchecked
# `rm -rf` that followed failed on the same unreadable subtree while the class
# line reported the reclaim anyway.
#
# Driven against a REAL mode-000 subtree rather than a stubbed failure: the
# suite runs as an ordinary user, so find and rm fail here for exactly the
# reason they fail on a box, and the case would stop meaning anything if it
# were the module's own error handling standing in for the filesystem's.
H10="$(reaper_home h10)"
mkdir -p "$H10/.cache/blind/sub" "$H10/.cache/locked" "$H10/.cache/stale" \
  "$H10/.cache/fileless/empty-sub" "$H10/.cache/blind-removable/zz-locked"
head -c 1000 /dev/zero >"$H10/.cache/blind/sub/blob"
head -c 1000 /dev/zero >"$H10/.cache/locked/blob"
head -c 1000 /dev/zero >"$H10/.cache/stale/blob"
head -c 1000 /dev/zero >"$H10/.cache/blind-removable/blob"
touch -a -d '60 days ago' "$H10/.cache/blind/sub/blob" "$H10/.cache/locked/blob" \
  "$H10/.cache/stale/blob" "$H10/.cache/blind-removable/blob"
# blind: find cannot descend into it. locked: find can (r-x), but rm cannot
# unlink through a directory it may not write.
chmod 000 "$H10/.cache/blind/sub"
chmod 500 "$H10/.cache/locked"
# blind-removable is the sharp one, and the reason this round is a round.
# Its aged blob makes the recency scan traverse the WHOLE entry rather than
# quitting at the first hit, so that scan always reaches an unreadable
# directory and always fails — while `rm -rf` removes the entry cleanly,
# because an EMPTY unreadable directory can still be rmdir'd. Permission is
# what usually makes the failed scan and the failed removal coincide, and
# that coincidence is what made the round-1 defect look survivable: the entry
# it wrongly doomed happened to be one rm could not touch. Here they come
# apart, and the round-1 code deletes a cache it never managed to look at.
chmod 000 "$H10/.cache/blind-removable/zz-locked"
OUT10="$(reaper_run "$H10" "$DEAD_CLI" 2>&1)"
chmod 700 "$H10/.cache/blind/sub" "$H10/.cache/locked" \
  "$H10/.cache/blind-removable/zz-locked" 2>/dev/null
t reaper-cache-untraversable-entry-held present "$(state "$H10/.cache/blind")"
t reaper-cache-untraversable-but-removable-entry-held present \
  "$(state "$H10/.cache/blind-removable")"
t reaper-cache-untraversable-entry-warns 1 \
  "$(grep -c 'WARN: reaper: could not read all of .*/\.cache/blind' <<<"$OUT10" | tr -d ' ')"
t reaper-cache-failed-removal-survives present "$(state "$H10/.cache/locked/blob")"
t reaper-cache-failed-removal-warns 1 \
  "$(grep -c 'WARN: reaper: caches — 1 of 2 could not be removed' <<<"$OUT10" | tr -d ' ')"
# The entry that really was unused still goes: failing closed must not become
# failing shut, or the janitor stops being one.
t reaper-cache-unused-entry-still-reclaimed absent "$(state "$H10/.cache/stale")"
# nit 2: an entry holding no regular file at all never answered the age
# question, so "no file read in the window" must not become "no file at all".
t reaper-cache-entry-with-no-files-kept present "$(state "$H10/.cache/fileless")"
# The count and the byte figure describe what LEFT THE DISK: one entry, and
# not the 1000 bytes still sitting in locked/. Under the round-1 code this
# line read "in 2 entries" (or 3, with blind doomed on a scan that never ran).
t reaper-cache-counts-only-what-went 1 \
  "$(grep -c 'caches reclaimed [0-9]* bytes in 1 entries unused for 30d' <<<"$OUT10" | tr -d ' ')"
REAP_B10="$(sed -n 's/.*caches reclaimed \([0-9]*\) bytes in 1 entries.*/\1/p' <<<"$OUT10")"
if [ -n "$REAP_B10" ] && [ "$REAP_B10" -ge 1000 ] && [ "$REAP_B10" -lt 2000 ]; then
  r1=one-entry-only
else
  r1="$REAP_B10"
fi
t reaper-cache-failed-removal-not-in-byte-figure one-entry-only "$r1"
# Everything this module tells the operator goes through log or warn. A raw
# `rm: cannot remove …` in the middle of a tick belongs to no duty and names
# no cause, so the only line allowed to carry rm's words is the warn.
t reaper-cache-no-raw-rm-error 0 \
  "$(grep 'cannot remove' <<<"$OUT10" | grep -vc 'WARN: reaper:' | tr -d ' ')"
t reaper-cache-holds-still-log-one-class-line 1 "$(class_line "$OUT10" caches)"

# ...and when nothing at all could be removed, the class says that rather
# than reporting a sweep that reclaimed nothing because there was nothing.
H10B="$(reaper_home h10b)"
mkdir -p "$H10B/.cache/locked"
head -c 1000 /dev/zero >"$H10B/.cache/locked/blob"
touch -a -d '60 days ago' "$H10B/.cache/locked/blob"
chmod 500 "$H10B/.cache/locked"
OUT10B="$(reaper_run "$H10B" "$DEAD_CLI" 2>&1)"
chmod 700 "$H10B/.cache/locked"
t reaper-cache-nothing-removable-says-so 1 \
  "$(grep -c 'caches reclaimed 0 bytes — none of the 1 entries unused for 30d could be removed' <<<"$OUT10B" | tr -d ' ')"
t reaper-cache-nothing-removable-is-not-a-clean-sweep 0 \
  "$(grep -c 'no entry unused' <<<"$OUT10B" | tr -d ' ')"

# The transcript class, the same two failures. A scan there is one find over
# one tree, so a non-zero status makes the whole list unknown-completeness and
# the class holds — there is no per-file version of that question to ask.
H11="$(reaper_home h11)"
mkdir -p "$H11/.claude/projects/blind"
head -c 100 /dev/zero >"$H11/.claude/projects/blind/aged.jsonl"
head -c 100 /dev/zero >"$H11/.claude/projects/proj-a/aged.jsonl"
touch -d '30 days ago' "$H11/.claude/projects/blind/aged.jsonl" \
  "$H11/.claude/projects/proj-a/aged.jsonl"
chmod 000 "$H11/.claude/projects/blind"
OUT11="$(reaper_run "$H11" "$DEAD_CLI" 2>&1)"
chmod 700 "$H11/.claude/projects/blind"
t reaper-transcript-unreadable-tree-holds-the-class present \
  "$(state "$H11/.claude/projects/proj-a/aged.jsonl")"
t reaper-transcript-unreadable-tree-warns 1 \
  "$(grep -c 'WARN: reaper: could not read all of .*/\.claude/projects' <<<"$OUT11" | tr -d ' ')"
t reaper-transcript-unreadable-tree-not-reported-clean 0 \
  "$(grep -c 'nothing older than' <<<"$OUT11" | tr -d ' ')"
t reaper-transcript-unreadable-tree-reports-once 1 \
  "$(grep -c 'transcripts reclaimed' <<<"$OUT11" | tr -d ' ')"

H12="$(reaper_home h12)"
mkdir -p "$H12/.claude/projects/locked"
head -c 100 /dev/zero >"$H12/.claude/projects/locked/aged.jsonl"
head -c 100 /dev/zero >"$H12/.claude/projects/proj-a/aged.jsonl"
touch -d '30 days ago' "$H12/.claude/projects/locked/aged.jsonl" \
  "$H12/.claude/projects/proj-a/aged.jsonl"
chmod 500 "$H12/.claude/projects/locked"
OUT12="$(reaper_run "$H12" "$DEAD_CLI" 2>&1)"
chmod 700 "$H12/.claude/projects/locked"
t reaper-transcript-failed-removal-survives present \
  "$(state "$H12/.claude/projects/locked/aged.jsonl")"
t reaper-transcript-removable-file-still-goes absent \
  "$(state "$H12/.claude/projects/proj-a/aged.jsonl")"
# 100 bytes and one file — not the 200 and two that were measured before the
# removal and, until this round, logged whatever the removal did.
t reaper-transcript-failed-removal-not-reclaimed 1 \
  "$(grep -c 'transcripts reclaimed 100 bytes in 1 files older than 14d' <<<"$OUT12" | tr -d ' ')"
t reaper-transcript-failed-removal-warns 1 \
  "$(grep -c 'WARN: reaper: transcripts — 1 of 2 could not be removed' <<<"$OUT12" | tr -d ' ')"
t reaper-transcript-no-raw-rm-error 0 \
  "$(grep 'cannot remove' <<<"$OUT12" | grep -vc 'WARN: reaper:' | tr -d ' ')"

# --- the liveness probe resolves past an `env` prefix (#540 nit 1) ----------
# kimi.conf ships `BOT_CLI_CMD=(env "KIMI_CODE_HOME=…" kimi --afk -p)` and its
# own comment says the prefix is deliberate, so every consumer of the array
# gets one launch shape (#240). `env` execs the command it was given and is
# never resident, so a probe reading argv[0] looks for a process no box runs
# and answers "no session" on a box that has one — the answer that deletes.
t reaper-cli-name-plain claude \
  "$(_reaper_cli_name /usr/bin/claude --dangerously-skip-permissions -p; printf '%s' "$REAPER_CLI_NAME")"
t reaper-cli-name-past-env kimi \
  "$(_reaper_cli_name env "KIMI_CODE_HOME=/tmp/k" /usr/bin/kimi --afk -p; printf '%s' "$REAPER_CLI_NAME")"
t reaper-cli-name-past-env-options kimi \
  "$(_reaper_cli_name env -i -u FOO "A=1" kimi -p; printf '%s' "$REAPER_CLI_NAME")"
# An array that names no command at all is "cannot tell", never a name that
# happens not to be running.
if _reaper_cli_name env "A=1"; then r1="resolved($REAPER_CLI_NAME)"; else r1=cannot-tell; fi
t reaper-cli-name-all-env-is-unknown cannot-tell "$r1"

H14="$(reaper_home h14)"
head -c 100 /dev/zero >"$H14/.claude/projects/proj-a/aged.jsonl"
touch -d '30 days ago' "$H14/.claude/projects/proj-a/aged.jsonl"
ENV_CLI="$TMP/reaper-env-cli"
cp "$(command -v sleep)" "$ENV_CLI"
"$ENV_CLI" 30 &
ENV_PID=$!
OUT14="$(
  HOME="$H14"
  BOT_CLI_CMD=(env "REAPER_PROBE_HOME=$TMP" "$ENV_CLI" --afk -p)
  # shellcheck disable=SC2317
  _reaper_atime_advances() { return 0; }
  duty_reaper
)"
kill "$ENV_PID" 2>/dev/null
wait "$ENV_PID" 2>/dev/null
t reaper-env-prefixed-cli-is-seen-live present \
  "$(state "$H14/.claude/projects/proj-a/aged.jsonl")"
t reaper-env-prefixed-cli-says-live 1 \
  "$(grep -c 'transcripts reclaimed 0 bytes — held, a session is live' <<<"$OUT14" | tr -d ' ')"

H15="$(reaper_home h15)"
head -c 100 /dev/zero >"$H15/.claude/projects/proj-a/aged.jsonl"
touch -d '30 days ago' "$H15/.claude/projects/proj-a/aged.jsonl"
OUT15="$(
  HOME="$H15"
  BOT_CLI_CMD=(env "A=1")
  # shellcheck disable=SC2317
  _reaper_atime_advances() { return 0; }
  duty_reaper
)"
t reaper-nameless-cli-holds present "$(state "$H15/.claude/projects/proj-a/aged.jsonl")"
t reaper-nameless-cli-warns 1 \
  "$(grep -c 'WARN: reaper: cannot tell whether a session is live' <<<"$OUT15" | tr -d ' ')"

# --- the byte figure does not depend on du's label (#540 nit 3) ------------
# `du -sc` writes its total on the LAST line, but the word on that line is
# translated: `$2 == "total"` matches nothing under a non-C LC_MESSAGES, so
# every reclaim would report 0 bytes while the delete happened anyway. No
# non-C locale is installed on a box, so the guard is a `du` on PATH that
# labels its total the way a translated one does. The mutation it kills is
# keying on the label at all; `LC_ALL=C` in the real call pins du's output
# shape besides, and is deliberately not what this case rests on.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/du" <<'STUB'
#!/usr/bin/env bash
# Real sizes from the real du, with the total line's label translated.
/usr/bin/du "$@" | awk '
  { line[NR] = $0; n = NR }
  END {
    for (i = 1; i < n; i++) print line[i]
    if (n) { split(line[n], f, "\t"); printf "%s\tinsgesamt\n", f[1] }
  }'
STUB
chmod +x "$STUB_BIN/du"
BYTES_DIR="$TMP/bytes"
mkdir -p "$BYTES_DIR"
head -c 4096 /dev/zero >"$BYTES_DIR/blob"
t reaper-bytes-ignores-a-translated-du-label 4096 \
  "$(PATH="$STUB_BIN:$PATH"; printf '%s\n' "$BYTES_DIR/blob" | _reaper_bytes)"

# --- duty_reaper called BARE under the engine's own set -euo pipefail ------
# duty.sh calls it as `duty_reaper && …`, and the `&&` suppresses errexit for
# everything underneath — so the module was only correct because of how it
# happened to be invoked (#540 nit 4). Called bare, the first find over an
# unreadable directory took the whole tick down after "reaper sweep starting"
# and before either class line. Both classes must report on every path.
H16="$(reaper_home h16)"
mkdir -p "$H16/.cache/blind/sub"
head -c 100 /dev/zero >"$H16/.cache/blind/sub/blob"
chmod 000 "$H16/.cache/blind/sub"
ERRX_OUT="$(bash -euo pipefail -c '
  DUTY_DIR="$4"; XDG_CONFIG_HOME="$5"; export DUTY_DIR XDG_CONFIG_HOME
  . "$1"
  . "$2"
  HOME="$3"
  BOT_CLI_CMD=("$6")
  duty_reaper
' _ "$SHARED/lib/common.sh" "$REAP_MOD" "$H16" "$TMP" "$XDG_CONFIG_HOME" \
  "$DEAD_CLI" 2>&1)" || true
chmod 700 "$H16/.cache/blind/sub"
t reaper-bare-call-under-errexit-completes 1 \
  "$(grep -c 'transcripts reclaimed' <<<"$ERRX_OUT" | tr -d ' ')"
t reaper-bare-call-under-errexit-reaches-caches 1 \
  "$(grep -c 'caches reclaimed' <<<"$ERRX_OUT" | tr -d ' ')"

# --- the empty sweep says so ------------------------------------------------
# The mutation this case exists for is an early return when there is nothing
# to reclaim, which is how a broken reaper becomes indistinguishable from a
# working one.
H6="$(reaper_home h6)"
head -c 10 /dev/zero >"$H6/.claude/projects/proj-a/fresh.jsonl"
mkdir -p "$H6/.cache/live"
head -c 10 /dev/zero >"$H6/.cache/live/blob"
OUT6="$(reaper_run "$H6" "$DEAD_CLI")"
t reaper-empty-transcript-sweep-logs 1 \
  "$(grep -c 'transcripts reclaimed 0 bytes — nothing older than 14d' <<<"$OUT6" | tr -d ' ')"
t reaper-empty-cache-sweep-logs 1 \
  "$(grep -c 'caches reclaimed 0 bytes — no entry unused for 30d' <<<"$OUT6" | tr -d ' ')"
t reaper-empty-sweep-still-announces 1 \
  "$(grep -c 'reaper sweep starting' <<<"$OUT6" | tr -d ' ')"

# --- a filesystem that does not record reads holds the class ---------------
# Aging a cache by mtime there would read its BUILD date and delete a browser
# in daily use, so the class is held and the operator is told which root.
H7="$(reaper_home h7)"
mkdir -p "$H7/.cache/stale"
head -c 1000 /dev/zero >"$H7/.cache/stale/blob"
touch -a -d '60 days ago' "$H7/.cache/stale/blob"
OUT7="$(REAP_ATIME_RC=1 reaper_run "$H7" "$DEAD_CLI")"
t reaper-noatime-keeps-entry present "$(state "$H7/.cache/stale")"
t reaper-noatime-warns 1 \
  "$(grep -c 'WARN: reaper: atimes do not advance on .*\.cache' <<<"$OUT7" | tr -d ' ')"
t reaper-noatime-still-logs-the-class 1 "$(class_line "$OUT7" caches)"
# ...and it says HELD, not "no entry unused for 30d": the second is a claim
# about caches this sweep never looked at.
t reaper-noatime-says-held 1 \
  "$(grep -c 'caches reclaimed 0 bytes — held on ' <<<"$OUT7" | tr -d ' ')"
t reaper-noatime-does-not-claim-a-clean-sweep 0 \
  "$(grep -c 'no entry unused' <<<"$OUT7" | tr -d ' ')"
OUT7B="$(REAP_ATIME_RC=2 reaper_run "$H7" "$DEAD_CLI")"
t reaper-unknowable-atime-keeps-entry present "$(state "$H7/.cache/stale")"
t reaper-unknowable-atime-warns 1 \
  "$(grep -c 'WARN: reaper: atimes do not advance' <<<"$OUT7B" | tr -d ' ')"

# --- the atime prober itself, against the real filesystem ------------------
# It must ANSWER (0 or 1) on a writable directory rather than fall through to
# "cannot tell", and it must say "cannot tell" where it cannot even write a
# probe. The probe file never survives either answer.
PROBE_DIR="$TMP/probe"
mkdir -p "$PROBE_DIR"
_reaper_atime_advances "$PROBE_DIR" && probe_rc=0 || probe_rc=$?
case "$probe_rc" in 0|1) r1=answered ;; *) r1="cannot-tell($probe_rc)" ;; esac
t reaper-atime-probe-answers answered "$r1"
t reaper-atime-probe-leaves-nothing "" "$(find "$PROBE_DIR" -name '.reaper-atime.*' -print)"
_reaper_atime_advances "$TMP/not-a-directory" && probe_rc=0 || probe_rc=$?
t reaper-atime-probe-unwritable-is-unknown 2 "$probe_rc"

# --- a knob that is not a whole number degrades, and says so ---------------
# `find -atime +30d` is an argument error the sweep would otherwise report as
# a clean run over an empty result — fail-CLOSED on the one value whose job is
# to bound what gets deleted.
H8="$(reaper_home h8)"
head -c 100 /dev/zero >"$H8/.claude/projects/proj-a/aged.jsonl"
touch -d '30 days ago' "$H8/.claude/projects/proj-a/aged.jsonl"
OUT8="$(REAP_TDAYS='14d' reaper_run "$H8" "$DEAD_CLI")"
t reaper-malformed-knob-warns 1 \
  "$(grep -c 'WARN: reaper: REAPER_TRANSCRIPT_DAYS is not a whole number (14d)' <<<"$OUT8" | tr -d ' ')"
t reaper-malformed-knob-uses-default 1 \
  "$(grep -c 'transcripts reclaimed 100 bytes in 1 files older than 14d' <<<"$OUT8" | tr -d ' ')"
# The cadence answers in a global for the same reason: read through a command
# substitution, its own warning would become part of the number duty.sh then
# compares an elapsed interval against.
t reaper-interval-malformed-falls-back 86400 \
  "$(REAPER_INTERVAL=hourly; reaper_interval >/dev/null; printf '%s' "$REAPER_INTERVAL_SECONDS")"
t reaper-interval-reads-the-conf-value 3600 \
  "$(REAPER_INTERVAL=3600; reaper_interval; printf '%s' "$REAPER_INTERVAL_SECONDS")"
t reaper-interval-warns-once-on-a-bad-value 1 \
  "$(REAPER_INTERVAL=hourly; reaper_interval | grep -c 'WARN: reaper: REAPER_INTERVAL is not a whole number' | tr -d ' ')"

# --- the shipped defaults and the module's fallbacks are one value ---------
conf_value() { sed -n "s/^$1=\([0-9]*\)\$/\1/p" "$REAP_CONF"; }
t reaper-defaults-match-conf-interval "$REAPER_INTERVAL_DEFAULT" "$(conf_value REAPER_INTERVAL)"
t reaper-defaults-match-conf-transcript "$REAPER_TRANSCRIPT_DAYS_DEFAULT" \
  "$(conf_value REAPER_TRANSCRIPT_DAYS)"
t reaper-defaults-match-conf-cache "$REAPER_CACHE_DAYS_DEFAULT" "$(conf_value REAPER_CACHE_DAYS)"
# The interval is a fleet fact and must be at least the 5-minute tick period:
# a shorter one would walk both trees on every tick forever.
if [ "$(conf_value REAPER_INTERVAL)" -ge 300 ]; then r1=bounded; else r1=TOO-SHORT; fi
t reaper-interval-at-least-a-tick bounded "$r1"

# --- the duty.sh slot -------------------------------------------------------
# Extracted and RUN, not just read: the criterion is that the slot is reached
# on a box with no triage role, and only executing it can show that. The
# mutation it exists for — nesting the call under `has_role triage`, the
# obvious thing to copy from the hygiene slot beside it — reds here.
SLOT="$(awk '/^# The reaper: EVERY role/,/^fi$/' "$DUTYSH")"
t reaper-slot-extracted 1 "$(grep -c '^  duty_reaper && echo' <<<"$SLOT" | tr -d ' ')"
# Read the slot's CODE, not its commentary: the comment explains why the slot
# is not role-gated and names the clock it stays away from, and a grep over
# the whole block would be satisfied by that explanation alone.
SLOT_CODE="$(grep -v '^[[:space:]]*#' <<<"$SLOT")"
t reaper-slot-is-not-role-gated "" "$(grep -F 'has_role' <<<"$SLOT_CODE")"
# ...and it does not touch the clock the attention-audit leg drives.
t reaper-slot-leaves-hygiene-clock-alone "" "$(grep -F '.hygiene-last' <<<"$SLOT_CODE")"
t reaper-slot-has-one-call-site 1 \
  "$(grep -c '^[[:space:]]*duty_reaper && echo' "$DUTYSH" | tr -d ' ')"
# Inside the tick's lock means: in duty.sh, which is the flock'd body, and NOT
# in a cron line of its own — the hazard the hygiene slot's own comment
# records ("the old separate hygiene cron could, and did share ~/duty/work
# with duty.sh unlocked").
t reaper-not-a-separate-cron-line 0 \
  "$(grep -c reaper "$SHARED/crontab.example" | tr -d ' ')"
slot_ln="$(grep -n '^  duty_reaper && echo' "$DUTYSH" | cut -d: -f1)"
end_ln="$(grep -n '^log "duty run end"' "$DUTYSH" | cut -d: -f1)"
if [ "$slot_ln" -lt "$end_ln" ]; then r1=inside; else r1=OUTSIDE; fi
t reaper-slot-runs-before-the-tick-ends inside "$r1"

# slot_run DUTYDIR HOME — the extracted slot, on a box whose only role is
# builder. `has_role` is the real one from common.sh, so a role gate would
# actually gate.
# shellcheck disable=SC2317
slot_run() {
  local ddir="$1" home="$2"
  (
    DUTY_DIR="$ddir"
    HOME="$home"
    BOT_ROLES="builder"
    BOT_CLI_CMD=("$DEAD_CLI")
    # shellcheck disable=SC1090
    eval "$SLOT"
  )
}

SD="$TMP/slot-duty"
mkdir -p "$SD/lib"
ln -sf "$REAP_MOD" "$SD/lib/duty-reaper.sh"
H9="$(reaper_home h9)"
SLOT_OUT1="$(slot_run "$SD" "$H9")"
t reaper-slot-reached-without-triage-role 1 \
  "$(grep -c 'reaper sweep starting' <<<"$SLOT_OUT1" | tr -d ' ')"
t reaper-slot-stamps-its-clock present "$(state "$SD/.reaper-last")"
SLOT_STAMP="$(cat "$SD/.reaper-last")"
# A second tick five minutes later does no work and does not move the stamp.
SLOT_OUT2="$(slot_run "$SD" "$H9")"
t reaper-slot-skips-inside-the-interval 0 \
  "$(grep -c 'reaper sweep starting' <<<"$SLOT_OUT2" | tr -d ' ')"
t reaper-slot-keeps-its-stamp "$SLOT_STAMP" "$(cat "$SD/.reaper-last")"
# An elapsed interval runs it again.
echo 0 >"$SD/.reaper-last"
SLOT_OUT3="$(slot_run "$SD" "$H9")"
t reaper-slot-runs-when-the-interval-elapsed 1 \
  "$(grep -c 'reaper sweep starting' <<<"$SLOT_OUT3" | tr -d ' ')"
# The stamp is EARNED: a sweep that did not run leaves the clock alone, so the
# next tick retries rather than losing the day.
SD2="$TMP/slot-duty-failing"
mkdir -p "$SD2/lib"
# The stub answers through the same global the real module does. A stub that
# printed the cadence instead would leave the comparison with an empty operand,
# the `if` false, and this case passing because the slot never ran at all —
# which is not what it is asserting.
printf '%s\n' '# shellcheck shell=bash' \
  'REAPER_INTERVAL_DEFAULT=86400' \
  'reaper_interval() { REAPER_INTERVAL_SECONDS=86400; }' \
  'duty_reaper() { log "reaper sweep starting"; return 1; }' >"$SD2/lib/duty-reaper.sh"
SLOT_OUT4="$(slot_run "$SD2" "$H9")"
t reaper-slot-reached-the-failing-sweep 1 \
  "$(grep -c 'reaper sweep starting' <<<"$SLOT_OUT4" | tr -d ' ')"
t reaper-slot-does-not-stamp-an-unrun-sweep absent "$(state "$SD2/.reaper-last")"

# --- what must not change (#457's own list) --------------------------------
# duty_hygiene, duty_attention_audit and the hygiene slot's scheduling are not
# this issue's, and a second stamp file in that block is exactly where a
# reaper would break them.
# shellcheck disable=SC2016  # matching duty.sh's literal line, not expanding it
t reaper-hygiene-slot-unchanged 1 \
  "$(grep -c 'duty_hygiene && echo "\$now" >"\$DUTY_DIR/.hygiene-last"' "$DUTYSH" | tr -d ' ')"
t reaper-hygiene-audit-call-unchanged 1 \
  "$(grep -c '^[[:space:]]*duty_attention_audit$' "$DUTYSH" | tr -d ' ')"
t reaper-module-does-not-touch-duty-dir "" "$(grep -F 'DUTY_DIR' "$REAP_MOD")"
# The out-of-scope set, stated on the issue and asserted here so a later
# session cannot drift into it: the swapfile is root-owned box shape, the
# docker legs rest on measurements that were withdrawn, and ~/duty is the
# working set.
# shellcheck disable=SC2016  # the $HOME/duty spelling is the thing searched for
t reaper-stays-out-of-scope "" \
  "$(grep -nE 'swapfile|docker|\$HOME/duty|~/duty' "$REAP_MOD" | grep -v '^[0-9]*:#' || true)"

suite_finish
