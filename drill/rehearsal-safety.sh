#!/usr/bin/env bash
# Safety interlocks for drill/rehearsal.sh. The caller supplies bx(), BOX_NAME,
# and REPOS_BACKUP; keeping these functions separate makes failure cleanup
# fixture-testable without a box or credentials.
# shellcheck disable=SC2088  # stored tildes expand inside the box via bx()

rehearsal_disarm_cron() {
  bx "if command -v crontab >/dev/null 2>&1; then
        tmp=\$(mktemp)
        crontab -l 2>/dev/null | grep -vF ~/duty/bin/tick.sh >\"\$tmp\" || true
        crontab \"\$tmp\"; rc=\$?
        rm -f \"\$tmp\"
        exit \"\$rc\"
      fi"
}

rehearsal_begin_isolation() {
  REPOS_BACKUP="~/duty/repos.txt.pre-drill-$$"
  bx "cp ~/duty/repos.txt $REPOS_BACKUP && : > ~/duty/repos.txt" &&
    bx "test ! -s ~/duty/repos.txt"
}

rehearsal_narrow_to_sandbox() {
  local sandbox="$1"
  bx "printf '%s\n' '$sandbox' > ~/duty/repos.txt" &&
    bx "[ \"\$(wc -l < ~/duty/repos.txt)\" -eq 1 ] && grep -qxF '$sandbox' ~/duty/repos.txt"
}

rehearsal_cleanup() {
  local rc=$?
  if [ -n "${REPOS_BACKUP:-}" ]; then
    bx "if [ -f $REPOS_BACKUP ]; then mv $REPOS_BACKUP ~/duty/repos.txt; fi" \
      || echo "WARNING: could not restore the pre-drill repos.txt; stop the box: box down $BOX_NAME" >&2
  fi
  rehearsal_disarm_cron \
    || echo "WARNING: could not disarm the drill cron; stop the box: box down $BOX_NAME" >&2
  return "$rc"
}
