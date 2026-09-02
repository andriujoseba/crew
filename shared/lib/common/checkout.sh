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
    :*) printf 'unknown'; return 0 ;;
    *[!0-9:]*) printf 'unknown'; return 0 ;;
  esac
  age=$((now - committed))
  [ "$age" -ge 0 ] || age=0
  printf '%ss' "$age"
}

_checkout_engine_id() {
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown'
}

_checkout_report() { # $1=state-file $2=condition-id $3=message
  local state="$1" condition="$2" message="$3" engine
  engine="$(_checkout_engine_id)"
  condition="$engine:$condition"
  [ "$condition" = "$(cat "$state" 2>/dev/null)" ] && return 0
  warn "$message"
  printf '%s\n' "$condition" >"$state"
}

_checkout_recovered() { # $1=state-file $2=dir [$3=message]
  local state="$1" dir="$2" message="${3:-}"
  [ -f "$state" ] || return 0
  rm -f "$state"
  if [ -n "$message" ]; then
    log "$message"
  else
    log "checkout: $dir can fast-forward again; doctrine checkout recovered"
  fi
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
    dirt="$(git -C "$dir" status --porcelain 2>/dev/null || true)"
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
_checkout_remote_repo() { # $1=remote URL — print GitHub owner/repository
  local remote="$1"
  remote="${remote%.git}"
  case "$remote" in
    https://github.com/*) printf '%s\n' "${remote#https://github.com/}" ;;
    git@github.com:*) printf '%s\n' "${remote#git@github.com:}" ;;
    *) return 1 ;;
  esac
}

_checkout_fork_list() { # $1=upstream — print this identity's matching forks
  local repo="$1" payload
  payload="$(gh api --paginate "repos/$repo/forks?per_page=100" 2>/dev/null)" || return 1
  jq -r --arg owner "$ME" --arg upstream "$repo" '
    .[]
    | select(.owner.login == $owner)
    | select((.parent.full_name // .source.full_name // "") == $upstream)
    | .full_name
  ' <<<"$payload"
}

ensure_main_clone() {
  local repo="$1" dir="$2" name state
  local current_url="" current_repo="" cached_upstream="" cached_repo=""
  local candidate parent="" matches="" count=0 resolved="" old_repo=""
  name="${repo##*/}"
  ensure_checkout "$repo" "$dir" || return 1
  state="$(_checkout_state_file "$dir:fork")"
  current_url="$(git -C "$dir" remote get-url fork 2>/dev/null || true)"
  current_repo="$(_checkout_remote_repo "$current_url" 2>/dev/null || true)"
  cached_upstream="$(git -C "$dir" config --local --get crew.fork-upstream 2>/dev/null || true)"
  cached_repo="$(git -C "$dir" config --local --get crew.fork-repository 2>/dev/null || true)"

  # The cache is the API validation record. As long as both the upstream and
  # remote still match it, a transient GitHub failure must not stop a tick.
  if [ "$cached_upstream" = "$repo" ] && [ -n "$cached_repo" ] \
    && [ "$current_repo" = "$cached_repo" ] \
    && [ "${cached_repo%%/*}" = "$ME" ]; then
    _checkout_recovered "$state" "$dir" \
      "checkout: $dir has a valid fork remote again; head repository recovered"
    return 0
  fi

  candidate="$ME/$name"
  parent="$(gh api "repos/$candidate" --jq '.parent.full_name // .source.full_name // empty' 2>/dev/null || true)"
  if [ "$parent" = "$repo" ]; then
    resolved="$candidate"
  else
    if ! matches="$(_checkout_fork_list "$repo")"; then
      _checkout_report "$state" "fork-api:$repo" \
        "checkout: cannot resolve a head repository for $repo because the GitHub fork-list API failed; refusing this builder tick"
      return 1
    fi
    count="$(awk 'NF { n++ } END { print n+0 }' <<<"$matches")"
    case "$count" in
      0)
        _checkout_report "$state" "fork-none:$ME:$repo" \
          "checkout: no fork of $repo owned by $ME exists; refusing this builder tick"
        return 1
        ;;
      1) resolved="$(awk 'NF { print; exit }' <<<"$matches")" ;;
      *)
        _checkout_report "$state" "fork-ambiguous:$ME:$repo:$count" \
          "checkout: $count forks of $repo are owned by $ME; refusing to guess a head repository"
        return 1
        ;;
    esac
  fi

  old_repo="$current_repo"
  if [ -n "$current_url" ]; then
    git -C "$dir" remote set-url fork "https://github.com/$resolved.git" || return 1
  else
    git -C "$dir" remote add fork "https://github.com/$resolved.git" || return 1
  fi
  git -C "$dir" config --local crew.fork-upstream "$repo" || return 1
  git -C "$dir" config --local crew.fork-repository "$resolved" || return 1

  if [ -n "$old_repo" ] && [ "$old_repo" != "$resolved" ]; then
    _checkout_report "$state" "fork-repaired:$old_repo:$resolved" \
      "checkout: repaired fork remote in $dir from $old_repo to validated head repository $resolved"
  else
    _checkout_recovered "$state" "$dir" \
      "checkout: $dir has a valid fork remote again; head repository recovered"
  fi
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
