# common/logging.sh — log, warn, rotate_log, alert — the engine's four ways of saying
# something: two to stdout, one about the file they land in, and one out of
# band to the operator.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { log "WARN: $*"; }

# rotate_log FILE — keep one 5 MB generation. Logs previously grew unbounded
# on every box.
rotate_log() {
  local f="$1"
  [ -f "$f" ] && [ "$(wc -c <"$f")" -gt 5242880 ] && mv "$f" "$f.1"
  return 0
}

# alert MESSAGE — best-effort operator ping over Telegram. Non-fatal by
# contract: a dead notification path must never take a duty loop down.
# dan-claude-bot kept an unused tg_send "for the boot gate" — this wires it.
alert() {
  local token chat
  token="$(cat "$HOME/.tg_bot_token" 2>/dev/null)" || return 0
  chat="$(cat "$HOME/.tg_chat_id" 2>/dev/null)" || return 0
  [ -n "$token" ] && [ -n "$chat" ] || return 0
  curl -sS -m 10 "https://api.telegram.org/bot$token/sendMessage" \
    --data-urlencode "chat_id=$chat" --data-urlencode "text=$1" \
    >/dev/null 2>&1 || log "alert send failed (non-fatal)"
  return 0
}
