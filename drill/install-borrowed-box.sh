#!/usr/bin/env bash
# Snapshot and restore the box state borrowed by install-drill.sh. The caller
# supplies bx(), which executes one shell body inside the drill box.

INSTALL_BORROWED_SNAPSHOT_TAKEN=0
INSTALL_BORROWED_REPOS_STATE=""
INSTALL_BORROWED_REPOS_BACKUP="~/duty/.repos.txt.install-drill.$$"
INSTALL_BORROWED_DETAIL=""

install_borrowed_box_snapshot() {
  local rc
  if bx 'test -e ~/duty/repos.txt'; then
    INSTALL_BORROWED_REPOS_STATE=present
    bx "cp ~/duty/repos.txt $INSTALL_BORROWED_REPOS_BACKUP" || {
      INSTALL_BORROWED_DETAIL="could not snapshot ~/duty/repos.txt"
      return 1
    }
  else
    rc=$?
    [ "$rc" -eq 1 ] || {
      INSTALL_BORROWED_DETAIL="could not determine whether ~/duty/repos.txt exists"
      return 1
    }
    INSTALL_BORROWED_REPOS_STATE=absent
  fi
  INSTALL_BORROWED_SNAPSHOT_TAKEN=1
}

install_borrowed_box_disarm() {
  # Keep unrelated cron entries. An empty installed crontab is still disarmed;
  # the contract is specifically that no duty tick survives Section A.
  bx 'tmp=$(mktemp) || exit 1
      crontab -l 2>/dev/null | grep -vF ~/duty/bin/tick.sh >"$tmp" || true
      crontab "$tmp"; rc=$?
      rm -f -- "$tmp"
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
      bx "cp $INSTALL_BORROWED_REPOS_BACKUP ~/duty/repos.txt" || {
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
  if bx 'crontab -l 2>/dev/null | grep -F ~/duty/bin/tick.sh >/dev/null'; then
    INSTALL_BORROWED_DETAIL="the borrowed box is still armed"
    return 1
  fi
  case "$INSTALL_BORROWED_REPOS_STATE" in
    present)
      bx "cmp -s $INSTALL_BORROWED_REPOS_BACKUP ~/duty/repos.txt" || {
        INSTALL_BORROWED_DETAIL="the borrowed box's ~/duty/repos.txt differs from its pre-Section-A bytes"
        return 1
      } ;;
    absent)
      bx 'test ! -e ~/duty/repos.txt' || {
        INSTALL_BORROWED_DETAIL="Section A created ~/duty/repos.txt on a box that arrived without one"
        return 1
      } ;;
  esac
}

install_borrowed_box_discard_snapshot() {
  [ "$INSTALL_BORROWED_SNAPSHOT_TAKEN" -eq 1 ] || return 0
  if [ "$INSTALL_BORROWED_REPOS_STATE" = present ]; then
    bx "rm -f -- $INSTALL_BORROWED_REPOS_BACKUP" || return 1
  fi
  INSTALL_BORROWED_SNAPSHOT_TAKEN=0
}
