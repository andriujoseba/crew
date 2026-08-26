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
_reaper_whole() {
  local name="$1" value="$2" default="$3"
  case "$value" in
    ''|*[!0-9]*)
      warn "reaper: $name is not a whole number ($value); using the $default default this interval (#457)"
      printf '%s' "$default"
      return 0
      ;;
  esac
  printf '%s' "$value"
}

# reaper_interval — the slot's own cadence, in seconds. Public because
# bin/duty.sh reads it to decide whether to run the slot at all.
reaper_interval() {
  _reaper_whole REAPER_INTERVAL "${REAPER_INTERVAL:-$REAPER_INTERVAL_DEFAULT}" \
    "$REAPER_INTERVAL_DEFAULT"
}

# _reaper_bytes — total apparent size, in bytes, of the newline-separated
# paths on stdin. Read BEFORE the removal, because afterwards there is nothing
# left to measure and a reclaim nobody can quantify is a log line the operator
# cannot act on. Apparent size rather than block count: it is the unit a
# retention age is reasoned about in, and it does not vary with the filesystem
# the suite happens to run on.
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
  du -scb -- "${paths[@]}" 2>/dev/null \
    | awk '$2 == "total" { sum = $1 } END { printf "%d", sum + 0 }'
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
  cli="${BOT_CLI_CMD[0]:-}"
  [ -n "$cli" ] || return 2
  cli="${cli##*/}"
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
  days="$(_reaper_whole REAPER_TRANSCRIPT_DAYS \
    "${REAPER_TRANSCRIPT_DAYS:-$REAPER_TRANSCRIPT_DAYS_DEFAULT}" \
    "$REAPER_TRANSCRIPT_DAYS_DEFAULT")"
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
  doomed="$(find "$root" -type f -name '*.jsonl' -mtime "+$days" -print 2>/dev/null)"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    dead+=("$path")
  done <<<"$doomed"
  count="${#dead[@]}"
  if [ "$count" -eq 0 ]; then
    log "reaper: transcripts reclaimed 0 bytes — nothing older than ${days}d under $root"
    return 0
  fi
  bytes="$(printf '%s\n' "${dead[@]}" | _reaper_bytes)"
  rm -f -- "${dead[@]}"
  log "reaper: transcripts reclaimed $bytes bytes in $count files older than ${days}d under $root"
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
_reaper_sweep_caches() {
  local days root entry count=0 bytes swept=0 held=""
  local -a dead=()
  days="$(_reaper_whole REAPER_CACHE_DAYS \
    "${REAPER_CACHE_DAYS:-$REAPER_CACHE_DAYS_DEFAULT}" \
    "$REAPER_CACHE_DAYS_DEFAULT")"
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    swept=1
    if ! _reaper_atime_advances "$root"; then
      held="$held $root"
      continue
    fi
    for entry in "$root"/* "$root"/.[!.]*; do
      [ -e "$entry" ] || continue
      # Anything read inside the window keeps the whole entry.
      [ -z "$(find "$entry" -atime "-$days" -print -quit 2>/dev/null)" ] || continue
      dead+=("$entry")
      count=$((count + 1))
    done
  done < <(_reaper_cache_roots)
  if [ -n "$held" ]; then
    warn "reaper: atimes do not advance on$held (noatime, or a filesystem that will not say); those caches are held rather than aged by mtime, which reads a cache's build date and not its use (#457)"
  fi
  if [ "$swept" -eq 0 ]; then
    log "reaper: caches reclaimed 0 bytes — no cache root on this box"
    return 0
  fi
  if [ "$count" -eq 0 ]; then
    log "reaper: caches reclaimed 0 bytes — no entry unused for ${days}d"
    return 0
  fi
  bytes="$(printf '%s\n' "${dead[@]}" | _reaper_bytes)"
  rm -rf -- "${dead[@]}"
  log "reaper: caches reclaimed $bytes bytes in $count entries unused for ${days}d"
  return 0
}

# duty_reaper — the slot. Returns 0 always, like every other duty: a janitor
# that reclaimed nothing is not a failed tick, and the stamp file this earns
# is what stops the tick five minutes from now repeating the walk.
duty_reaper() {
  log "reaper sweep starting"
  _reaper_sweep_transcripts
  _reaper_sweep_caches
  return 0
}
