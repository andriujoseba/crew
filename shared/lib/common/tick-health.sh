# common/tick-health.sh — bounded, read-only health derived from duty.log.
#
# This module emits no durable record. It derives one report on demand so
# `crew status` and the floor consume the same computation (#484).
# A module of shared/lib/common.sh; nothing sources this file directly.
#
# shellcheck shell=bash

TICK_HEALTH_WINDOW_S_DEFAULT=86400

tick_health_report() { # [duty.log] [now epoch] [window seconds] [notify.log]
  local log_file="${1:-$DUTY_DIR/duty.log}"
  local now="${2:-$(date -u +%s)}"
  local window="${3:-$TICK_HEALTH_WINDOW_S_DEFAULT}"
  local notify_log="${4:-${log_file%/*}/notify.log}"
  local -a log_files=("$log_file")
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  case "$window" in ''|*[!0-9]*|0) window="$TICK_HEALTH_WINDOW_S_DEFAULT" ;; esac
  [ -r "$log_file" ] || return 0
  if [ "$notify_log" != "$log_file" ] && [ -r "$notify_log" ]; then
    log_files+=("$notify_log")
  fi

  local cutoff
  cutoff="$(date -u -d "@$((now - window))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || return 0
  TZ=UTC awk -v cutoff="$cutoff" -v now="$now" -v window="$window" '
    function remember_kind(kind) {
      if (!(kind in seen_kind)) { seen_kind[kind]=1; kinds[++kind_n]=kind }
    }
    function remember_reason(kind, reason, key) {
      key=kind SUBSEP reason
      if (!(key in seen_reason)) {
        seen_reason[key]=1; reasons[kind, ++reason_n[kind]]=reason
      }
    }
    function epoch(ts, a) {
      split(ts, a, /[-T:Z]/)
      return mktime(a[1] " " a[2] " " a[3] " " a[4] " " a[5] " " a[6])
    }
    {
      ts=$1
      if (ts !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ || ts < cutoff) next

      job=$2
      if ((job == "duty" || job == "notify") && $3 == "run" && $4 == "start") {
        ticks++
        active[job]=1
        if (ts > last_tick) last_tick=ts
      } else if ((job == "duty" || job == "notify") && $3 == "run" && $4 == "end") {
        active[job]=0
      } else if ((job == "duty" || job == "notify") &&
                 $3 == "tick" && $4 == "skipped:" &&
                 $0 ~ /previous run still holds the lock/) {
        ticks++
        busy++
        if (ts > last_tick) last_tick=ts
      } else if ((job == "duty" || job == "notify") &&
                 $3 == "tick" && $4 == "FAILED:") {
        # tick.sh writes FAILED after the job has already written run start.
        # That pair is one boundary. A bare FAILED still counts because a job
        # can fail before reaching its own start record.
        if (!active[job]) ticks++
        active[job]=0
        if (ts > last_tick) last_tick=ts
      }

      if ($2 == "SESSION" && $3 == "SKIP") {
        kind=""; reason=""
        for (field=4; field<=NF; field++) {
          if ($field ~ /^kind=/) { kind=$field; sub(/^kind=/, "", kind) }
          else if ($field ~ /^reason=/) { reason=$field; sub(/^reason=/, "", reason) }
        }
        # The shipped vocabulary requires both fields. A partial lookalike is
        # not a skip whose hold reason may be guessed by the reader.
        if (kind == "" || reason == "") next
        remember_kind(kind); skips[kind]++
        remember_reason(kind, reason); holds[kind, reason]++
      }
      if ($2 == "SESSION" && $3 == "END") {
        kind=""; outcome=""
        for (field=4; field<=NF; field++) {
          if ($field ~ /^kind=/) { kind=$field; sub(/^kind=/, "", kind) }
          else if ($field ~ /^outcome=/) { outcome=$field; sub(/^outcome=/, "", outcome) }
        }
        if (kind == "" || outcome == "") next
        remember_kind(kind)
        if (last_outcome[kind] == outcome) streak[kind]++
        else { last_outcome[kind]=outcome; streak[kind]=1 }
      }
    }
    END {
      if (!ticks && !kind_n) exit
      age="-"
      if (last_tick != "") { age=now-epoch(last_tick); if (age < 0) age=0 }
      printf "TICK_HEALTH window_s=%d last_tick_age_s=%s ticks=%d busy=%d\n", window, age, ticks+0, busy+0
      for (i=1; i<=kind_n; i++) {
        kind=kinds[i]; hold_text="-"
        for (j=1; j<=reason_n[kind]; j++) {
          reason=reasons[kind,j]
          hold_text=(hold_text == "-" ? "" : hold_text ",") reason ":" holds[kind,reason]
        }
        outcome=(last_outcome[kind] == "" ? "-" : last_outcome[kind])
        count=(outcome == "-" ? 0 : streak[kind])
        printf "TICK_HEALTH_KIND window_s=%d kind=%s skips=%d holds=%s outcome=%s streak=%d\n", window, kind, skips[kind]+0, hold_text, outcome, count
      }
    }
  ' "${log_files[@]}"
}

_tick_health_window() { # seconds -> compact surface label
  local seconds="$1"
  if [ $((seconds % 86400)) -eq 0 ]; then printf '%dd' $((seconds / 86400))
  elif [ $((seconds % 3600)) -eq 0 ]; then printf '%dh' $((seconds / 3600))
  else printf '%ss' "$seconds"
  fi
}

_tick_health_duration() { # seconds -> compact age
  local seconds="$1"
  if [ "$seconds" -ge 86400 ]; then printf '%dd %dh' $((seconds / 86400)) $(((seconds % 86400) / 3600))
  elif [ "$seconds" -ge 3600 ]; then printf '%dh %dm' $((seconds / 3600)) $(((seconds % 3600) / 60))
  elif [ "$seconds" -ge 60 ]; then printf '%dm' $((seconds / 60))
  else printf '%ds' "$seconds"
  fi
}

tick_health_rows() { # REPORT -> <label><TAB><text>
  local report="${1:-}" line tok key val window age ticks busy rate kind skips hold_text outcome streak
  while IFS= read -r line; do
    case "$line" in
      'TICK_HEALTH '*)
        window=""; age=""; ticks=0; busy=0
        for tok in $line; do key="${tok%%=*}"; val="${tok#*=}"; case "$key" in
          window_s) window="$val" ;; last_tick_age_s) age="$val" ;; ticks) ticks="$val" ;; busy) busy="$val" ;;
        esac; done
        [ -n "$window" ] || continue
        if [ "$age" = - ]; then
          printf 'Last tick (%s window)\tunknown\n' "$(_tick_health_window "$window")"
        else
          printf 'Last tick (%s window)\t%s ago\n' "$(_tick_health_window "$window")" "$(_tick_health_duration "$age")"
        fi
        if [ "$ticks" -eq 0 ]; then
          printf 'Busy ticks (%s window)\tunknown\n' "$(_tick_health_window "$window")"
        else
          rate=$(((busy * 1000 + ticks / 2) / ticks))
          printf 'Busy ticks (%s window)\t%d/%d (%d.%d%%)\n' "$(_tick_health_window "$window")" "$busy" "$ticks" $((rate / 10)) $((rate % 10))
        fi
        ;;
      'TICK_HEALTH_KIND '*)
        window=""; kind=""; skips=0; hold_text=-; outcome=-; streak=0
        for tok in $line; do key="${tok%%=*}"; val="${tok#*=}"; case "$key" in
          window_s) window="$val" ;; kind) kind="$val" ;; skips) skips="$val" ;; holds) hold_text="$val" ;; outcome) outcome="$val" ;; streak) streak="$val" ;;
        esac; done
        if [ -z "$window" ] || [ -z "$kind" ]; then continue; fi
        if [ "$hold_text" = - ]; then hold_text="none"; else hold_text="${hold_text//,/\, }"; fi
        printf '%s skips/holds (%s window)\t%s skips · %s\n' "$kind" "$(_tick_health_window "$window")" "$skips" "$hold_text"
        if [ "$outcome" = - ]; then outcome="unknown"; else outcome="$outcome ×$streak"; fi
        printf '%s outcome streak (%s window)\t%s\n' "$kind" "$(_tick_health_window "$window")" "$outcome"
        ;;
    esac
  done <<<"$report"
}
