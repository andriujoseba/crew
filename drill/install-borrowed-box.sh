#!/usr/bin/env bash
# Snapshot and restore the box state borrowed by install-drill.sh. The caller
# supplies bx(), which executes one shell body inside the drill box.

INSTALL_BORROWED_SNAPSHOT_TAKEN=0
INSTALL_BORROWED_REPOS_STATE=""
# A basename keeps the path safe to interpolate into the remote shell while
# leaving that shell (not the host) responsible for resolving ~/duty.
INSTALL_BORROWED_REPOS_BACKUP=".repos.txt.install-drill.$$"
# shellcheck disable=SC2034  # read by the sourcing driver after helper calls
INSTALL_BORROWED_DETAIL=""

install_borrowed_box_snapshot() {
  local state
  INSTALL_BORROWED_REPOS_STATE=""
  # Classify and copy in one successful remote invocation. An outer `box
  # exec` failure may also return 1, so its status alone never means absent.
  state="$(bx "if [ -e ~/duty/repos.txt ]; then
                  cp ~/duty/repos.txt ~/duty/$INSTALL_BORROWED_REPOS_BACKUP || exit 1
                  printf 'present\\n'
                else
                  printf 'absent\\n'
                fi")" || {
    INSTALL_BORROWED_DETAIL="could not read and snapshot ~/duty/repos.txt"
    return 1
  }
  case "$state" in
    present|absent) INSTALL_BORROWED_REPOS_STATE="$state" ;;
    *)
      INSTALL_BORROWED_DETAIL="could not classify ~/duty/repos.txt as present or absent"
      return 1 ;;
  esac
  INSTALL_BORROWED_SNAPSHOT_TAKEN=1
}

install_borrowed_box_disarm() {
  # Keep unrelated cron entries, and keep an absent crontab absent. The
  # locale-pinned no-table diagnostic is the only failed read that proves
  # absence; every other error is indeterminate and must preserve the table.
  # shellcheck disable=SC2016  # expanded by bash inside the box
  bx 'current=$(mktemp) || exit 1
      filtered=$(mktemp) || { rm -f -- "$current"; exit 1; }
      error=$(mktemp) || { rm -f -- "$current" "$filtered"; exit 1; }
      if LC_ALL=C crontab -l >"$current" 2>"$error"; then
        grep -vF "/duty/bin/tick.sh" "$current" >"$filtered" || true
        crontab "$filtered"; rc=$?
      else
        rc=$?
        if [ "$rc" -eq 1 ] && grep -q "^no crontab for " "$error"; then
          rc=0
        fi
      fi
      rm -f -- "$current" "$filtered" "$error"
      exit "$rc"'
}

install_borrowed_box_restore() {
  [ "$INSTALL_BORROWED_SNAPSHOT_TAKEN" -eq 1 ] || return 0
  INSTALL_BORROWED_DETAIL=""
  install_borrowed_box_disarm || {
    INSTALL_BORROWED_DETAIL="could not remove duty tick.sh from the borrowed box's crontab"
    return 1
  }
  case "$INSTALL_BORROWED_REPOS_STATE" in
    present)
      bx "cp ~/duty/$INSTALL_BORROWED_REPOS_BACKUP ~/duty/repos.txt" || {
        INSTALL_BORROWED_DETAIL="could not restore the borrowed box's ~/duty/repos.txt"
        return 1
      } ;;
    absent)
      bx 'rm -f -- ~/duty/repos.txt' || {
        INSTALL_BORROWED_DETAIL="could not restore the borrowed box's absent ~/duty/repos.txt state"
        return 1
      } ;;
    *)
      INSTALL_BORROWED_DETAIL="the borrowed box's registry snapshot state is unknown"
      return 1 ;;
  esac
}

install_borrowed_box_verify() {
  local cron_state
  # An explicit answer from a successful remote invocation keeps transport or
  # read failures distinct from a proven absent/disarmed table.
  # shellcheck disable=SC2016  # expanded by bash inside the box
  cron_state="$(bx 'tmp=$(mktemp) || exit 1
                     error=$(mktemp) || { rm -f -- "$tmp"; exit 1; }
                     if LC_ALL=C crontab -l >"$tmp" 2>"$error"; then
                       if grep -F "/duty/bin/tick.sh" "$tmp" >/dev/null; then
                         printf "armed\\n"
                       else
                         printf "disarmed\\n"
                       fi
                     else
                       rc=$?
                       [ "$rc" -eq 1 ] && grep -q "^no crontab for " "$error" ||
                         { rm -f -- "$tmp" "$error"; exit "$rc"; }
                       printf "absent\\n"
                     fi
                     rm -f -- "$tmp" "$error"')" || {
    INSTALL_BORROWED_DETAIL="could not read the borrowed box's crontab"
    return 1
  }
  case "$cron_state" in
    disarmed|absent) ;;
    armed)
      INSTALL_BORROWED_DETAIL="the borrowed box is still armed"
      return 1 ;;
    *)
      INSTALL_BORROWED_DETAIL="could not classify the borrowed box's crontab state"
      return 1 ;;
  esac
  case "$INSTALL_BORROWED_REPOS_STATE" in
    present)
      bx "cmp -s ~/duty/$INSTALL_BORROWED_REPOS_BACKUP ~/duty/repos.txt" || {
        INSTALL_BORROWED_DETAIL="the borrowed box's ~/duty/repos.txt differs from its pre-Section-A bytes"
        return 1
      } ;;
    absent)
      bx 'test ! -e ~/duty/repos.txt' || {
        # shellcheck disable=SC2034  # read by the sourcing driver
        INSTALL_BORROWED_DETAIL="Section A created ~/duty/repos.txt on a box that arrived without one"
        return 1
      } ;;
  esac
}

install_borrowed_box_discard_snapshot() {
  [ "$INSTALL_BORROWED_SNAPSHOT_TAKEN" -eq 1 ] || return 0
  if [ "$INSTALL_BORROWED_REPOS_STATE" = present ]; then
    bx "rm -f -- ~/duty/$INSTALL_BORROWED_REPOS_BACKUP" || return 1
  fi
  INSTALL_BORROWED_SNAPSHOT_TAKEN=0
}
