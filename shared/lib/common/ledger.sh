# common/ledger.sh — ledger_filter, ledger_suppressed, report_suppressed,
# report_suppressed_if_complete, ledger_commit — the seen-ledgers and the
# reporting that keeps a suppression from becoming a silence; and
# session_reconcile_orphans, which answers the one duty.log record nothing else
# ever closes.
#
# The two subjects share a module because they share a shape: each reads a
# ledger of what has already happened and decides what the engine still owes on
# it. duty.log is the session ledger, and #478 put its cases here.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash

# --- Seen-ledgers: turn "signal is present" into "signal CHANGED since I last
# looked". A wake whose only clearing action is one the session may correctly
# DECLINE — mark a mention read, comment on a held discussion — re-fired every
# tick forever, spawning a full model session each time (the triage box's
# overnight Fable burn, 2026-07-25: 147 mention + 61 triage sessions in 3 days,
# board unchanged). Each ledger records, per thread/discussion id, the activity
# timestamp last handled; a session launches only for entries new or advanced,
# and the ledger is committed ONLY after run_session reports rc 0 — a crashed
# session leaves its ids uncommitted, preserving crash-only retry. ISO-8601
# timestamps, so a lexical compare is a chronological one.
ledger_filter() { # $1=ledger; stdin "id ts" lines; stdout new-or-advanced ones
  local ledger="$1"
  awk -v L="$ledger" '
    BEGIN { while ((getline line < L) > 0) { n=split(line,a," "); if (n>=2) seen[a[1]]=a[2] } close(L) }
    NF>=2 { if (!($1 in seen) || seen[$1] < $2) print }
  '
}
ledger_suppressed() { # $1=ledger; stdin "id ts" lines; stdout the ones it HIDES
  # The exact inverse of ledger_filter, so the two can never disagree about
  # what was withheld. Set arithmetic on the two outputs cannot do this safely:
  # an empty "fresh" list makes `grep -vxF -f` match every line and report
  # nothing suppressed, which is the reading that matters most.
  local ledger="$1"
  awk -v L="$ledger" '
    BEGIN { while ((getline line < L) > 0) { n=split(line,a," "); if (n>=2) seen[a[1]]=a[2] } close(L) }
    NF>=2 { if (($1 in seen) && !(seen[$1] < $2)) print }
  '
}

# report_suppressed STATEFILE LABEL — stdin: the "id ts" lines a ledger hid.
#
# A ledger trades a burn for SILENCE, and silence is how the fleet starves. An
# issue still carrying no label is a live violation of the board invariant; the
# engine must stop PAYING for it, not stop SAYING it. Without this, #59's fix
# would convert a loud expensive bug into a quiet cheap one and the invariant
# would rot unobserved — the same shape as #52 (an interlock that reads like
# coverage) and #50 (skip lines nobody reads).
#
# Warns when the suppressed SET CHANGES, not every tick: at one tick per five
# minutes a standing violation would otherwise write 288 identical lines a day
# and bury the log it is trying to inform. Removing the state file when the set
# empties means the next occurrence speaks up again.
# $3 overrides the reason phrase. The default describes a LEDGER suppression —
# a session saw the item and declined to clear it. Not every withheld set has
# that history: the attention wake reports demands in repos this box does not
# carry, which no session ever saw and which were never actionable here. Both
# lines land in the same duty.log, and with one phrasing they read as the same
# event (grok, #67).
report_suppressed() {
  local state="$1" label="$2"
  local why="${3:-unactioned since a previous session and now suppressed}"
  local items n
  items="$(sort)"
  if [ -z "$items" ]; then rm -f "$state"; return 0; fi
  if [ "$items" = "$(cat "$state" 2>/dev/null)" ]; then return 0; fi
  n="$(printf '%s\n' "$items" | awk 'NF{c++} END{print c+0}')"
  warn "$label: $n item(s) $why — $(printf '%s\n' "$items" | awk 'NF>=2{printf "%s(%s) ", $1, $2}')"
  printf '%s\n' "$items" >"$state"
}

report_suppressed_if_complete() { # $1=0|1 $2=state $3=label; stdin items
  local complete="$1" state="$2" label="$3" items
  items="$(cat)"
  if [ "$complete" -eq 1 ]; then
    printf '%s\n' "$items" | report_suppressed "$state" "$label"
  else
    log "$label: suppression report state unchanged after partial sweep"
  fi
}

ledger_commit() { # $1=ledger; stdin "id ts" lines; merge keeping max ts, atomically
  local ledger="$1" tmp
  tmp="$(mktemp "${ledger}.XXXXXX")"
  awk -v L="$ledger" '
    BEGIN { while ((getline line < L) > 0) { n=split(line,a," "); if (n>=2) seen[a[1]]=a[2] } close(L) }
    NF>=2 { if (!($1 in seen) || seen[$1] < $2) seen[$1]=$2 }
    END { for (k in seen) print k, seen[k] }
  ' > "$tmp"
  mv -f "$tmp" "$ledger"
}

# --- The fourth session shape: a session that died with its box (#478) -------
#
# run_session writes SESSION END on every path ITS OWN PROCESS survives — ok,
# TIMEOUT, FAILED, TERMINAL. A session killed WITH the box survives none of
# them and leaves a SESSION START that nothing ever answers. The evidence
# contract names no shape for it, so every reader of duty.log counts that
# session as still running for as long as the log generation lives, and a box
# that kills itself repeatedly is uncountable: each incident leaves a dangling
# start attributed to nothing, and the terminal breaker is never told that a
# dispatch failed at all.
#
# The reconciliation runs at the next tick, the first thing the box does when
# it is back. It APPENDS and never edits: one reconstructed terminal per
# orphan, reading back no further than each kind's newest observed terminal.
# It is not a log rewriter.

# The outcome token that says "this line was reconstructed". It is the only
# thing that distinguishes a reconstructed terminal from an observed one, so it
# lives in one place: the writer below stamps it and the read-back bound reads
# it, and the two can never disagree about which lines the engine WATCHED and
# which it inferred.
SESSION_ORPHAN_OUTCOME=ORPHANED

# _session_boot_id — the kernel's boot id, first field only.
#
# Trimmed rather than whole because the comparison is only ever against THIS
# box's current boot id: a holder is written on one boot and read on the next,
# and the question is "same boot or not". A trimmed collision reads a dead
# holder's boot as the live one, which falls back to the pid check below — the
# safe direction, since it can only MISS a reconciliation, never manufacture
# one. A box with no /proc answers `unknown` on every boot, which is the same
# fallback stated as a value rather than as an error.
_session_boot_id() {
  local id
  id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || id=""
  [ -n "$id" ] || id=unknown
  printf '%s' "${id%%-*}"
}

# _session_holder — who to ask, later, whether a session is still running.
#
# The duty process that dispatched it. If that process is alive the session is
# alive, because run_session writes SESSION END on every path it survives; if
# it is gone, the session went with it. `$$` and not `$BASHPID`: the tick is
# the holder even where a duty module calls run_session from a subshell.
#
# The pid is qualified by the boot id because a pid means nothing across a
# reboot, and a reboot is this feature's headline case: without it, the first
# process to inherit a dead session's pid would read as that session.
_session_holder() {
  printf '%s.%s' "$$" "$(_session_boot_id)"
}

# _session_holder_live HOLDER — 0 when that holder is still running.
#
# This is D1's second half, and its whole point is that it is not a clock. An
# age threshold cannot answer the question: a build legitimately runs for two
# hours, so any threshold short enough to reconcile promptly also reconciles
# live sessions, and any threshold safe enough to spare them waits out the
# longest timeout the fleet allows before saying anything.
#
# Every unreadable answer is `live`, so an orphan is missed rather than
# invented. A reconstructed terminal is evidence and feeds a breaker; a wrong
# one is a lie about a session that ran.
_session_holder_live() {
  local holder="$1" pid boot
  case "$holder" in *.*) ;; *) return 0 ;; esac
  pid="${holder%%.*}"
  boot="${holder#*.}"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pid" -gt 0 ] || return 0
  # A different boot is decisive on its own: whatever holds that pid today, it
  # is not the process that dispatched this session.
  [ "$boot" = "$(_session_boot_id)" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# _session_orphan_scan LOGFILE — the unanswered starts, oldest first, one
# `kind<TAB>key<TAB>holder<TAB>log<TAB>started` record per line.
#
# Two passes over the same file. The first is D4's bound: a kind's newest
# OBSERVED terminal is where that kind's history is settled, and no line at or
# before it is read again — which is what keeps this a bounded pass over a log
# that rotates at 5 MB rather than a walk of everything the box ever did.
#
# Reconstructed terminals are deliberately NOT bounds while still being
# matches. That asymmetry is what makes a second run produce nothing: the
# orphan's own reconstructed terminal is inside the window, pairs with the
# start, and the start is no longer unanswered — while the bound itself stays a
# statement about what the engine watched, as D4 words it.
#
# Starts are matched against ends per kind AND key, most-recent-first, so an
# interleaving cannot answer one session's start with another's end. A start
# carrying no holder is matched like any other and dropped at emission time,
# not here: leaving it out of the matching would let its end pop a start that
# genuinely is an orphan.
_session_orphan_scan() {
  local logfile="$1"
  awk -v ORPHAN="$SESSION_ORPHAN_OUTCOME" '
    function fields(   i, p) {
      delete f
      for (i = 4; i <= NF; i++) {
        p = index($i, "=")
        if (p > 1) f[substr($i, 1, p - 1)] = substr($i, p + 1)
      }
    }
    NR == FNR {
      if ($2 == "SESSION" && $3 == "END") {
        fields()
        if (f["outcome"] != ORPHAN) bound[f["kind"]] = FNR
      }
      next
    }
    $2 != "SESSION" { next }
    $3 == "START" {
      fields()
      if (FNR <= bound[f["kind"]]) next
      q = f["kind"] SUBSEP f["key"]
      depth[q]++
      open[q SUBSEP depth[q]] = FNR SUBSEP f["kind"] SUBSEP f["key"] \
        SUBSEP f["holder"] SUBSEP f["log"] SUBSEP $1
      next
    }
    $3 == "END" {
      fields()
      if (FNR <= bound[f["kind"]]) next
      q = f["kind"] SUBSEP f["key"]
      if (depth[q] > 0) { delete open[q SUBSEP depth[q]]; depth[q]-- }
      next
    }
    END {
      for (o in open) {
        split(open[o], p, SUBSEP)
        keep[p[1] + 0] = p[2] "\t" p[3] "\t" p[4] "\t" p[5] "\t" p[6]
      }
      # Emitted in log order rather than in the hash order `for (o in open)`
      # gives, so the reconstructed lines land in the order the sessions
      # started and the log reads as a history.
      for (i = 1; i <= FNR; i++) if (i in keep) print keep[i]
    }
  ' "$logfile" "$logfile"
}

# session_reconcile_orphans — one bounded pass, at tick time.
#
# Called by duty.sh before any dispatch, which is what makes the answer simple:
# the only unanswered starts in the log belong to a previous run, never to this
# one.
#
# The reconstructed terminal carries `rc=-` and `dur=-`. It is the one thing
# this line must not fake: the reconciler knows the session started and knows
# nobody is running it, and knows nothing whatever about how it exited or how
# long it took. `-` for a number the engine does not have is this codebase's
# existing spelling (_session_budget_ceiling), so it needs no new vocabulary,
# and `started=` names the start being answered because this line's own stamp
# is the reconcile time and not the death.
session_reconcile_orphans() {
  local logfile="$DUTY_DIR/duty.log" records kind key holder slog started closed=0
  [ -s "$logfile" ] || return 0
  records="$(_session_orphan_scan "$logfile")" || records=""
  [ -n "$records" ] || return 0
  # A here-string and not a pipe: the loop must run in THIS shell to keep its
  # count, and `scan | while` under pipefail is the shape #449 exists about.
  while IFS=$'\t' read -r kind key holder slog started; do
    [ -n "$kind" ] || continue
    # No holder field, no reconciliation. D1 requires BOTH halves, and a start
    # written by an engine older than this one — or by a writer that is not
    # run_session, as the floor's `operator` sessions are — carries nobody to
    # ask. Answering it anyway would be the fabrication this refuses to make,
    # so those starts stay open and this feature is forward-looking by
    # construction.
    [ -n "$holder" ] || continue
    ! _session_holder_live "$holder" || continue
    log "SESSION END kind=$kind key=$key rc=- dur=- outcome=$SESSION_ORPHAN_OUTCOME acted=unknown reply_tail= started=$started"
    # D3: the same per-kind counter an observed TERMINAL feeds, and no second
    # mechanism. A box that kills itself on every review session has a dead
    # review lane, whether the vendor said so or the kernel did.
    _session_terminal_record "$kind" yes unknown "$slog"
    closed=$((closed + 1))
  done <<<"$records"
  [ "$closed" -eq 0 ] \
    || warn "session reconcile: $closed session(s) died with the box and were closed as $SESSION_ORPHAN_OUTCOME"
}
