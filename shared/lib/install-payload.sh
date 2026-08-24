#!/usr/bin/env bash
# install-payload.sh — repository-derived exclusions shared by both installers.

# A minimised installed crew tree deliberately carries no .gitignore. The
# shared installer runs from that tree during `crew upgrade`, so these are the
# literal fallback for the only source that cannot derive them. Keep this list
# byte-equivalent to the repository's simple, repository-wide ignore rules;
# checkout installs derive the live list below and the tests enforce parity. An
# existing .gitignore with no simple repository-wide rules is not a minimised
# tree: derivation fails closed instead of silently substituting this fallback.
INSTALL_PAYLOAD_IGNORE_FALLBACK=(
  .drill-shots
  '*.roster.local'
  node_modules
)

INSTALL_PAYLOAD_IGNORE_PATTERNS=()

install_payload_load_ignore_patterns() {  # <crew tree root>
  local root="$1" line pattern
  INSTALL_PAYLOAD_IGNORE_PATTERNS=()
  if [ -f "$root/.gitignore" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*|'!'*) continue ;; esac
      pattern="${line%/}"
      # A slash makes a rule location-specific. Those entries remain the root
      # installer's commented product-shape literals; the rules derivable for
      # both installers are the simple patterns Git applies at every depth.
      case "$pattern" in */*) continue ;; esac
      INSTALL_PAYLOAD_IGNORE_PATTERNS+=("$pattern")
    done <"$root/.gitignore"
  else
    INSTALL_PAYLOAD_IGNORE_PATTERNS=("${INSTALL_PAYLOAD_IGNORE_FALLBACK[@]}")
  fi
  [ "${#INSTALL_PAYLOAD_IGNORE_PATTERNS[@]}" -gt 0 ]
}

install_payload_path_is_ignored() {  # <path relative to crew tree>
  local rest="$1" component pattern
  while :; do
    component="${rest%%/*}"
    for pattern in "${INSTALL_PAYLOAD_IGNORE_PATTERNS[@]}"; do
      # shellcheck disable=SC2053  # the repository-owned ignore glob is intentional
      [[ "$component" == $pattern ]] && return 0
    done
    [ "$rest" = "$component" ] && break
    rest="${rest#*/}"
  done
  return 1
}

install_payload_prune_ignored() {  # <payload tree>
  local root="$1" pattern found
  for pattern in "${INSTALL_PAYLOAD_IGNORE_PATTERNS[@]}"; do
    while IFS= read -r -d '' found; do
      rm -rf -- "$found"
    done < <(find "$root" -mindepth 1 -name "$pattern" -print0)
  done
}

install_payload_find_ignored() {  # <payload tree> — one relative path per line
  local root="$1" pattern found
  for pattern in "${INSTALL_PAYLOAD_IGNORE_PATTERNS[@]}"; do
    while IFS= read -r -d '' found; do
      printf '%s\n' "${found#"$root"/}"
    done < <(find "$root" -mindepth 1 -name "$pattern" -print0)
  done | LC_ALL=C sort -u
}
