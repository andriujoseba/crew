# common/checkout.sh — ensure_checkout, ensure_main_clone, validate_sha — git working copies
# the engine keeps, and the object ids it accepts.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash

# ensure_checkout REPO DIR — clone if missing, fetch if present, and
# fast-forward a CLEAN parked default branch so sessions read current
# doctrine (a frozen clone serves last month's AGENTS.md forever). Never
# force-updates: a dirty or diverged tree gets a warning, not a reset — a
# session owns its own git state.
_checkout_state_file() { # $1=dir — stable per checkout, without path bytes in the filename
  local key
  key="$(printf '%s' "$1" | cksum | awk '{print $1 "-" $2}')"
  printf '%s/.checkout-warning.%s' "$DUTY_DIR" "$key"
}

_checkout_head_age() { # $1=dir — age of the doctrine commit the clone serves
  local committed now age
  committed="$(git -C "$1" log -1 --format=%ct HEAD 2>/dev/null)" || {
    printf 'unknown'
    return 0
  }
  now="$(date +%s)"
  case "$committed:$now" in
    *[!0-9:]*) printf 'unknown'; return 0 ;;
  esac
  age=$((now - committed))
  [ "$age" -ge 0 ] || age=0
  printf '%ss' "$age"
}

_checkout_report() { # $1=state-file $2=condition-id $3=message
  local state="$1" condition="$2" message="$3"
  [ "$condition" = "$(cat "$state" 2>/dev/null)" ] && return 0
  warn "$message"
  printf '%s\n' "$condition" >"$state"
}

_checkout_recovered() { # $1=state-file $2=dir
  local state="$1" dir="$2"
  [ -f "$state" ] || return 0
  rm -f "$state"
  log "checkout: $dir can fast-forward again; doctrine checkout recovered"
}

ensure_checkout() {
  local repo="$1" dir="$2" state br dirt age condition
  state="$(_checkout_state_file "$dir")"
  if [ ! -d "$dir/.git" ]; then
    gh repo clone "$repo" "$dir" -- --quiet || { warn "clone of $repo failed"; return 1; }
    _checkout_recovered "$state" "$dir"
  else
    git -C "$dir" fetch --quiet --all --prune || warn "fetch failed in $dir"
    br="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
    dirt="$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null || true)"
    age="$(_checkout_head_age "$dir")"
    if [ -z "$br" ]; then
      _checkout_report "$state" "detached:$(git -C "$dir" rev-parse HEAD 2>/dev/null || printf unknown)" \
        "checkout: $dir is detached at HEAD (age=$age); sessions may read stale doctrine"
    elif [ -n "$dirt" ]; then
      condition="dirty:$br:$(printf '%s' "$dirt" | cksum | awk '{print $1 "-" $2}')"
      _checkout_report "$state" "$condition" \
        "checkout: $dir is dirty on $br ($(printf '%s\n' "$dirt" | awk 'NF{n++} END{print n+0}') path(s), HEAD age=$age); refusing to fast-forward because a session owns this git state — sessions may read stale doctrine"
    elif git -C "$dir" merge --ff-only --quiet "origin/$br" 2>/dev/null; then
      _checkout_recovered "$state" "$dir"
    elif ! git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$br"; then
      _checkout_report "$state" "missing-origin:$br" \
        "checkout: $dir is parked on $br, which has no origin/$br (HEAD age=$age); sessions may read stale doctrine"
    else
      _checkout_report "$state" "diverged:$br" \
        "checkout: $dir cannot fast-forward from origin/$br (HEAD age=$age, histories diverged); sessions may read stale doctrine"
    fi
  fi
  return 0
}

# ensure_main_clone REPO DIR — parked main clone with a `fork` remote at the
# bot's fork. Builds happen in worktrees, never here (a crashed build
# corrupted claude-bot's build clone on 2026-07-22).
ensure_main_clone() {
  local repo="$1" dir="$2"
  local name="${repo##*/}"
  ensure_checkout "$repo" "$dir" || return 1
  git -C "$dir" remote get-url fork >/dev/null 2>&1 \
    || git -C "$dir" remote add fork "https://github.com/$ME/$name.git"
}

# validate_sha SHA — full 40-hex object id. Short SHAs broke submit gates
# (grok's crew report: an unvalidated short SHA burns the retry and never
# matches commit_id).
validate_sha() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
    *) [ "${#1}" -eq 40 ] ;;
  esac
}
