# duty-reaper.sh — the interim janitor (#457). A box is minted once and runs
# for weeks; nothing in the fleet reclaims what its own sessions leave behind,
# so every box drifts toward full and the failure lands on whichever member
# happens to be working when the disk crosses a threshold. #442 (a box per
# duty) retires this module entirely — everything here is scaffolding with a
# known end date and is built on that understanding.
#
# It reaps exactly what THIS ENGINE'S SESSIONS GENERATE: the CLI transcripts
# under ~/.claude/projects, and the package caches those sessions fill. The
# swapfile, /var/lib/docker and ~/duty are out of scope and named as such on
# the issue: the first is root-owned box shape (heavy-duty/box#178), the
# second is unevidenced on any box crew can read, and the third is the working
# set, not garbage.
#
# TWO CLASSES, TWO DIFFERENT AGE QUESTIONS, and the difference is the whole
# design. A transcript is WRITTEN and never read again, so its mtime is the
# age of the session that wrote it. A cache is BUILT once and READ for months,
# so its mtime is the age of the download and says nothing about whether the
# box still needs it — on claude-builder the chromium under
# ~/.cache/ms-playwright has an mtime of 2026-08-02 and an atime of
# 2026-08-25, so an mtime sweep at any retention shorter than the install's
# age deletes 656 MB the fleet-floor browser walk used the day before. The
# cache question is "when was this last USED", which is atime, and this file
# refuses to guess it: it probes whether atimes advance on the filesystem it
# is about to sweep, and holds the class when they do not.
#
# Every branch that cannot establish a fact HOLDS rather than deletes. A held
# class costs one interval; a wrong delete costs a live session's record or a
# working cache, and neither comes back. That asymmetry is why nothing here
# fails open the way duty-hygiene.sh's board gate deliberately does: a
# backstop that cannot read the board must stay the backstop, but a reaper
# that cannot read the box must not reap it.
#
# shellcheck shell=bash

# The shipped defaults, used only when the loaded fleet conf predates them.
# Config and engine are installed together but can skew across an upgrade, and
# under `set -u` a bare reference would abort the whole tick — the wrong
# direction for values whose only job is to bound a sweep. Kept equal to
# shared/conf/fleet.defaults.conf; `reaper-defaults-match-conf` fails if the
# two ever drift.
REAPER_INTERVAL_DEFAULT=86400
REAPER_TRANSCRIPT_DAYS_DEFAULT=14
REAPER_CACHE_DAYS_DEFAULT=30

# Where each class lives, resolved from $HOME at CALL time and never at source
# time: the suite drives every sweep against a fabricated tree under a
# temporary HOME, and a path frozen when the module was sourced would point at
# the real one.
_reaper_transcript_root() { printf '%s' "$HOME/.claude/projects"; }
_reaper_cache_roots() { printf '%s\n' "$HOME/.cache" "$HOME/.npm"; }

# _reaper_whole NAME VALUE DEFAULT — VALUE if it is a whole number, else
# DEFAULT with a warning. The same fail-safe duty-hygiene.sh applies to
# HYGIENE_FLOOR, for the same reason: `REAPER_CACHE_DAYS=30d` would otherwise
# make `find -atime +30d` an argument error that the sweep reports as a clean
# run over an empty result.
#
# THE ANSWER COMES BACK IN A GLOBAL, not on stdout, for the reason
# _hygiene_gate states about its own: every report here is a `log` line and
# log writes to stdout, so a function returning its value through the same
# channel folds its own warning into that value. It is not a hypothetical —
# `days="$(_reaper_whole …)"` set the retention to the warning text followed
# by the number, and `find -mtime "+<a whole log line> 14"` swept nothing at
# all while the sweep reported success.
REAPER_WHOLE=""
_reaper_whole() {
  local name="$1" value="$2" default="$3"
  REAPER_WHOLE="$value"
  case "$value" in
    ''|*[!0-9]*)
      REAPER_WHOLE="$default"
      warn "reaper: $name is not a whole number ($value); using the $default default this interval (#457)"
      ;;
  esac
}

# reaper_interval — the slot's own cadence, in seconds, left in
# REAPER_INTERVAL_SECONDS. Public because bin/duty.sh reads it to decide
# whether to run the slot at all; a global for the reason above.
# shellcheck disable=SC2034  # bin/duty.sh reads it after calling reaper_interval
REAPER_INTERVAL_SECONDS=""
reaper_interval() {
  _reaper_whole REAPER_INTERVAL "${REAPER_INTERVAL:-$REAPER_INTERVAL_DEFAULT}" \
    "$REAPER_INTERVAL_DEFAULT"
  # shellcheck disable=SC2034  # bin/duty.sh reads this after calling us
  REAPER_INTERVAL_SECONDS="$REAPER_WHOLE"
}

# _reaper_bytes — total apparent size, in bytes, of the newline-separated
# paths on stdin. Read BEFORE the removal, because afterwards there is nothing
# left to measure and a reclaim nobody can quantify is a log line the operator
# cannot act on. Apparent size rather than block count: it is the unit a
# retention age is reasoned about in, and it does not vary with the filesystem
# the suite happens to run on.
#
# THE TOTAL IS READ BY POSITION, NOT BY LABEL. `du -sc` writes its total on
# the LAST line, but the word on it is translated — `$2 == "total"` matches
# nothing under a non-C LC_MESSAGES, so every reclaim line would report 0
# bytes while the delete happened anyway. That is the reporting-layer version
# of exactly the failure this module is built to avoid, so the label is not
# parsed at all and `LC_ALL=C` pins the rest of du's output shape besides.
_reaper_bytes() {
  local line
  local -a paths=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    paths+=("$line")
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    printf '0'
    return 0
  fi
  # `|| true`, and a bare `return 0` below: du exits non-zero over a path it
  # cannot fully read, and this function is called through an assignment,
  # where errexit would take the whole tick down (see duty_reaper's note).
  LC_ALL=C du -scb -- "${paths[@]}" 2>/dev/null \
    | awk '{ last = $1 } END { printf "%d", last + 0 }' || true
  return 0
}

# _reaper_reclaim CLASS PATH... — remove the paths, VERIFY each one is gone,
# and leave the honest accounting in REAPER_RECLAIMED_BYTES /
# REAPER_RECLAIMED_COUNT. Survivors are warned about, by name, and counted
# into neither.
#
# The round-1 defect this exists for (#540, codex-bot-andresmgsl): the sweeps
# ran `rm` and then logged the byte figure they had measured beforehand, so a
# removal that FAILED — a mode-000 subtree is enough, and `rm -rf` cannot
# unlink through one — was reported as a reclaim while the entry sat on disk.
# A byte figure that describes what the sweep intended rather than what it
# did is worse than no figure at all: it is the operator's only evidence that
# the disk moved, and it was lying in exactly the case where it mattered.
#
# `rm`'s own diagnostics are captured rather than left to reach the tick's
# output raw. Everything this module tells the operator goes through log or
# warn; a bare `rm: … Permission denied` in the middle of a tick belongs to
# no duty and names no cause.
REAPER_RECLAIMED_BYTES=0
REAPER_RECLAIMED_COUNT=0
_reaper_reclaim() {
  local class="$1"
  shift
  local before after path err total="$#"
  local -a survivors=()
  REAPER_RECLAIMED_BYTES=0
  REAPER_RECLAIMED_COUNT=0
  [ "$total" -gt 0 ] || return 0
  before="$(printf '%s\n' "$@" | _reaper_bytes)"
  err="$(rm -rf -- "$@" 2>&1 >/dev/null)" || true
  err="${err%%$'\n'*}"
  for path in "$@"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      survivors+=("$path")
    fi
  done
  if [ "${#survivors[@]}" -eq 0 ]; then
    REAPER_RECLAIMED_BYTES="$before"
    REAPER_RECLAIMED_COUNT="$total"
    return 0
  fi
  # What is left is measured again: `rm -rf` can empty most of an entry and
  # fail on one subtree, and those bytes DID come back.
  after="$(printf '%s\n' "${survivors[@]}" | _reaper_bytes)"
  REAPER_RECLAIMED_BYTES=$((before - after))
  REAPER_RECLAIMED_COUNT=$((total - ${#survivors[@]}))
  warn "reaper: $class — ${#survivors[@]} of $total could not be removed and are not counted as reclaimed: ${survivors[*]}${err:+ ($err)} (#457)"
  return 0
}

# _reaper_cli_name ARGV... — the process name a live session of this profile
# would actually be running under, left in REAPER_CLI_NAME. rc 1 when the
# array names no command, which the caller must read as "cannot tell".
#
# BOT_CLI_CMD[0] IS NOT ALWAYS THE CLI. kimi.conf:47 ships
# `BOT_CLI_CMD=(env "KIMI_CODE_HOME=$(_kimi_home)" kimi --afk -p)` and its own
# comment says the `env` prefix is deliberate, so that every consumer of the
# array — real sessions and the boot probe — gets one launch shape (#240).
# `env` then execs the command it was given, so no `env` process is ever
# resident: a probe that took argv[0]'s basename would look for a process
# nobody on that box is running and answer "no session" on a box that has
# one. So the prefix is resolved past — `env` itself, then the NAME=VALUE
# assignments and option forms that belong to it — and the first token left
# is the name to look for. Nothing left is rc 1 → the caller holds; it is
# never allowed to degrade into "no session", which is the answer that
# deletes.
REAPER_CLI_NAME=""
_reaper_cli_name() {
  local -a argv=("$@")
  local i=0 tok
  REAPER_CLI_NAME=""
  [ "${#argv[@]}" -gt 0 ] || return 1
  if [ "${argv[0]##*/}" = "env" ]; then
    i=1
    while [ "$i" -lt "${#argv[@]}" ]; do
      case "${argv[$i]}" in
        -i|--ignore-environment|-|-0|--null) ;;
        -u|--unset) i=$((i + 1)) ;;
        -u?*|*=*) ;;
        *) break ;;
      esac
      i=$((i + 1))
    done
  fi
  [ "$i" -lt "${#argv[@]}" ] || return 1
  tok="${argv[$i]##*/}"
  [ -n "$tok" ] || return 1
  REAPER_CLI_NAME="$tok"
  return 0
}

# _reaper_live_session — is a session of this engine's CLI running on this box
# right now? rc 0 yes · 1 no · 2 cannot tell.
#
# THIS IS THE LIVE-TRANSCRIPT EXCLUSION, and it is deliberately whole-class
# rather than per-file, because per-file is not knowable from outside the CLI.
# Measured on claude-builder, 2026-08-26: the CLI holds NO open descriptor on
# the transcript it is writing (`/proc/*/fd` resolves to none of them — it
# appends and closes), and its own process environment does not carry the
# session id (`CLAUDE_CODE_SESSION_ID` is exported into the session's
# children, not set on the `claude` process itself). The file is keyed by
# working directory rather than by session, so nothing outside the CLI can
# name the file a live session is appending to. What IS knowable is whether a
# session is live at all — so while one is, the whole class is held. That
# costs a day of retention on a box busy at the moment the slot fires, and it
# cannot delete the record of the tick it is running in.
#
# The scan reads /proc directly rather than calling pgrep: this engine's
# dependency floor is bash+gh+jq+git+flock+timeout, and procps is not on it.
_reaper_live_session() {
  local cli pid argv0
  local -a argv=()
  if [ -n "${BOT_CLI_CMD[0]:-}" ]; then
    argv=("${BOT_CLI_CMD[@]}")
  fi
  _reaper_cli_name "${argv[@]+"${argv[@]}"}" || return 2
  cli="$REAPER_CLI_NAME"
  [ -r /proc/self/cmdline ] || return 2
  for pid in /proc/[0-9]*; do
    # `read -d ''` takes the first NUL-delimited field — argv[0] — without a
    # `tr … | head` pipeline, which would SIGPIPE its producer into a 141
    # under the pipefail this module is sourced into (#449).
    IFS= read -r -d '' argv0 <"$pid/cmdline" 2>/dev/null || continue
    if [ -n "$argv0" ] && [ "${argv0##*/}" = "$cli" ]; then
      return 0
    fi
  done
  return 1
}

# _reaper_atime_advances DIR — does this filesystem record reads? rc 0 yes ·
# 1 no · 2 cannot tell. Anything but 0 holds the cache class.
#
# Probed rather than parsed out of /proc/mounts: finding which mount carries a
# path is a walk up the tree with bind mounts and overlays to get wrong, while
# the question itself is answerable directly in four syscalls. The probe file
# is aged FIRST because `relatime` — the default on every box's ext4 root —
# updates atime only when it is already older than mtime, so a freshly written
# file read immediately would look like `noatime` and hold the class forever.
_reaper_atime_advances() {
  local dir="$1" probe before after rc=2
  probe="$(mktemp "$dir/.reaper-atime.XXXXXX" 2>/dev/null)" || return 2
  if printf 'probe\n' >"$probe" 2>/dev/null &&
     touch -d @1 "$probe" 2>/dev/null &&
     before="$(stat -c %X "$probe" 2>/dev/null)" &&
     cat -- "$probe" >/dev/null 2>&1 &&
     after="$(stat -c %X "$probe" 2>/dev/null)"; then
    if [ "$after" != "$before" ]; then rc=0; else rc=1; fi
  fi
  rm -f "$probe"
  return "$rc"
}

# _reaper_sweep_transcripts — one CLI transcript per session, forever, with no
# retention anywhere in the engine: 1083 of them, 544 MB, on claude-builder.
# Age is mtime, which for a write-once file is the age of its session.
#
# Exactly ONE line is logged whatever happens, and it always carries a byte
# figure: a reaper that says nothing when it reclaims nothing is
# indistinguishable from a reaper that is not installed.
_reaper_sweep_transcripts() {
  local root days doomed count bytes path live=0
  local -a dead=()
  root="$(_reaper_transcript_root)"
  _reaper_whole REAPER_TRANSCRIPT_DAYS \
    "${REAPER_TRANSCRIPT_DAYS:-$REAPER_TRANSCRIPT_DAYS_DEFAULT}" \
    "$REAPER_TRANSCRIPT_DAYS_DEFAULT"
  days="$REAPER_WHOLE"
  if [ ! -d "$root" ]; then
    log "reaper: transcripts reclaimed 0 bytes — no $root on this box"
    return 0
  fi
  _reaper_live_session || live=$?
  case "$live" in
    0)
      log "reaper: transcripts reclaimed 0 bytes — held, a session is live on this box"
      return 0
      ;;
    2)
      warn "reaper: cannot tell whether a session is live; transcripts reclaimed 0 bytes — held rather than risk a live session's own record (#457)"
      return 0
      ;;
  esac
  # THE SCAN'S STATUS IS AN ANSWER. A find that could not read part of the
  # tree prints what it did reach and exits non-zero; taking its output alone
  # is taking an unknown-completeness list as a complete one. Nothing here is
  # certain enough to delete from, so the class holds for one interval.
  if ! doomed="$(find "$root" -type f -name '*.jsonl' -mtime "+$days" -print 2>/dev/null)"; then
    warn "reaper: could not read all of $root; transcripts reclaimed 0 bytes — held rather than delete from a scan that did not finish (#457)"
    return 0
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    dead+=("$path")
  done <<<"$doomed"
  count="${#dead[@]}"
  if [ "$count" -eq 0 ]; then
    log "reaper: transcripts reclaimed 0 bytes — nothing older than ${days}d under $root"
    return 0
  fi
  _reaper_reclaim transcripts "${dead[@]}"
  bytes="$REAPER_RECLAIMED_BYTES"
  if [ "$REAPER_RECLAIMED_COUNT" -eq 0 ]; then
    log "reaper: transcripts reclaimed 0 bytes — none of the $count files older than ${days}d under $root could be removed"
    return 0
  fi
  log "reaper: transcripts reclaimed $bytes bytes in $REAPER_RECLAIMED_COUNT files older than ${days}d under $root"
  return 0
}

# _reaper_entry_state ENTRY DAYS — what this sweep actually knows about one
# cache entry, left in REAPER_ENTRY_STATE:
#
#   used        a file inside it was read inside the window — keep
#   fileless    it holds no regular file at all, so the age question was
#               never answered — keep (and reaping it would reclaim nothing)
#   unreadable  the scan could not finish — keep, and say so
#   unused      the scan finished and found nothing read in the window — reap
#
# `-type f` is not a filter, it is the correctness of the predicate: reading
# a directory's entries updates that directory's atime, and this sweep reads
# every directory it walks. Counting directory atimes would mean the first
# walk warmed every cache root it visited, so nothing was ever old enough
# afterwards — a janitor that reaps nothing, forever, and says so in a log
# line indistinguishable from a clean box. A file's atime is only moved by
# reading its CONTENTS, which `find` never does.
#
# Both finds are read through `if`, so their STATUS is part of the answer and
# not discarded output. `-print -quit` keeps each one to the first hit, which
# is what makes a daily walk over a 1.5 GB browser cache cost ~2 ms.
REAPER_ENTRY_STATE=""
_reaper_entry_state() {
  local entry="$1" days="$2" any recent
  REAPER_ENTRY_STATE=unreadable
  if ! any="$(find "$entry" -type f -print -quit 2>/dev/null)"; then
    return 0
  fi
  if [ -z "$any" ]; then
    REAPER_ENTRY_STATE=fileless
    return 0
  fi
  if ! recent="$(find "$entry" -type f -atime "-$days" -print -quit 2>/dev/null)"; then
    return 0
  fi
  if [ -n "$recent" ]; then
    REAPER_ENTRY_STATE=used
  else
    REAPER_ENTRY_STATE=unused
  fi
  return 0
}

# _reaper_sweep_caches — ~/.cache and ~/.npm, by ENTRY and by access time.
#
# The unit is the entry — a top-level child of a cache root — and never a file
# inside one. An entry is one artefact: an installed browser, a compiled
# module tree, npm's content-addressed store. Deleting the files inside it
# that happen to be old leaves a half-populated directory that still looks
# installed and fails at the moment it is next used, which is worse than
# either keeping it or removing it whole. So an entry is kept unless NOTHING
# under it has been read inside the retention window.
#
# THE ENTRY'S STATE IS FOUR-VALUED, and collapsing it to two was round 1's
# blocking defect (#540, codex-bot-andresmgsl): "I could not look inside this
# entry" scored identically to "I looked and nothing has been read", so an
# entry with one unreadable subtree was doomed on the strength of a scan that
# never happened. An entry holding no regular file at all had the same shape
# from the other side — "no file read in the window" quietly became "no file
# at all" (claude-bot-andresmgsl). Both now keep the entry: the predicate
# that deletes is only ever satisfied by a scan that ran to completion over
# an entry that actually holds something to age.
_reaper_sweep_caches() {
  local days root entry count=0 bytes swept=0 checked=0 held="" blind=""
  local -a dead=()
  _reaper_whole REAPER_CACHE_DAYS \
    "${REAPER_CACHE_DAYS:-$REAPER_CACHE_DAYS_DEFAULT}" \
    "$REAPER_CACHE_DAYS_DEFAULT"
  days="$REAPER_WHOLE"
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    swept=1
    if ! _reaper_atime_advances "$root"; then
      held="$held $root"
      continue
    fi
    checked=$((checked + 1))
    for entry in "$root"/* "$root"/.[!.]*; do
      [ -e "$entry" ] || continue
      _reaper_entry_state "$entry" "$days"
      case "$REAPER_ENTRY_STATE" in
        unused)
          dead+=("$entry")
          count=$((count + 1))
          ;;
        unreadable) blind="$blind $entry" ;;
      esac
    done
  done < <(_reaper_cache_roots)
  if [ -n "$held" ]; then
    warn "reaper: atimes do not advance on$held (noatime, or a filesystem that will not say); those caches are held rather than aged by mtime, which reads a cache's build date and not its use (#457)"
  fi
  if [ -n "$blind" ]; then
    warn "reaper: could not read all of$blind; those entries are held — a scan that did not finish cannot show a cache is unused (#457)"
  fi
  if [ "$swept" -eq 0 ]; then
    log "reaper: caches reclaimed 0 bytes — no cache root on this box"
    return 0
  fi
  if [ "$checked" -eq 0 ]; then
    # Every root was held, so the sweep never asked the question. Reporting
    # "no entry unused" here would be a claim about caches nothing looked at —
    # the one shape that makes a held reaper read like a working one.
    log "reaper: caches reclaimed 0 bytes — held on$held"
    return 0
  fi
  if [ "$count" -eq 0 ]; then
    log "reaper: caches reclaimed 0 bytes — no entry unused for ${days}d"
    return 0
  fi
  _reaper_reclaim caches "${dead[@]}"
  bytes="$REAPER_RECLAIMED_BYTES"
  if [ "$REAPER_RECLAIMED_COUNT" -eq 0 ]; then
    log "reaper: caches reclaimed 0 bytes — none of the $count entries unused for ${days}d could be removed"
    return 0
  fi
  log "reaper: caches reclaimed $bytes bytes in $REAPER_RECLAIMED_COUNT entries unused for ${days}d"
  return 0
}

# duty_reaper — the slot. Returns 0 always, like every other duty: a janitor
# that reclaimed nothing is not a failed tick, and the stamp file this earns
# is what stops the tick five minutes from now repeating the walk.
#
# AND IT COMPLETES UNDER A BARE CALL, not only under duty.sh's
# `duty_reaper && …`. The engine runs `set -euo pipefail`; the `&&` at the one
# call site suppresses errexit for everything underneath it, so for a while
# this module was only correct because of how it happened to be invoked —
# called bare, the first `find` over an unreadable directory took the whole
# tick down after `reaper sweep starting` and before either class line
# (#540, claude-bot-andresmgsl). Every status that means something is now read
# through an `if`, so both classes report on every path regardless of the call
# shape. `reaper-bare-call-under-errexit-completes` is the guard.
duty_reaper() {
  log "reaper sweep starting"
  _reaper_sweep_transcripts
  _reaper_sweep_caches
  return 0
}
