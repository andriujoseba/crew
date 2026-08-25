# common/ledger.sh — ledger_filter, ledger_suppressed, report_suppressed,
# report_suppressed_if_complete, ledger_commit — the seen-ledgers and the
# reporting that keeps a suppression from becoming a silence.
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
