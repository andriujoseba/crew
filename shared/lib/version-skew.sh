#!/usr/bin/env bash
# Shared host/engine skew reporter for install.sh and cli/crew.
#
# The host CLI and the engines copied into hired boxes are independent axes.
# A host-version flip must therefore report skew, never refuse the flip.

hired_engine_versions() {
  command -v box >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local name stamp version
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    stamp="$(timeout 10 box exec "$name" -- bash -lc \
      'head -1 ~/duty/VERSION 2>/dev/null' </dev/null 2>/dev/null \
      | tr -d '\r\n' || true)"
    [ -n "$stamp" ] || continue
    case "$stamp" in
      crew@*) version="${stamp#crew@}"; version="${version%% *}" ;;
      *) version="$stamp" ;;
    esac
    printf '%s\t%s\n' "$name" "$version"
  done < <(box list --json 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)
}

report_engine_skew() { # HOST_VERSION
  local host_version="$1" rows count name version
  rows="$(hired_engine_versions | awk -F '\t' -v want="$host_version" '$2 != want')"
  [ -n "$rows" ] || return 0
  count="$(printf '%s\n' "$rows" | grep -c .)"
  printf 'crew: %s hired box(es) are still running a different engine from host %s:\n' \
    "$count" "$host_version" >&2
  while IFS=$'\t' read -r name version; do
    printf 'crew:   · %s: %s\n' "$name" "$version" >&2
  done <<<"$rows"
  printf 'crew: converge them when you are ready: crew upgrade --all\n' >&2
}
