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
ensure_checkout() {
  local repo="$1" dir="$2"
  if [ ! -d "$dir/.git" ]; then
    gh repo clone "$repo" "$dir" -- --quiet || { warn "clone of $repo failed"; return 1; }
  else
    git -C "$dir" fetch --quiet --all --prune || warn "fetch failed in $dir"
    local br
    br="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
    if [ -n "$br" ] && [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      git -C "$dir" merge --ff-only --quiet "origin/$br" 2>/dev/null \
        || warn "cannot fast-forward $dir (diverged?) — sessions may read stale doctrine"
    fi
  fi
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
