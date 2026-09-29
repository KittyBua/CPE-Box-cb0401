#!/bin/sh
#
# Forwards incoming SMS to your notification backend (ntfy.sh/Telegram).
#
# Event-driven, nothing runs in between SMS: for every incoming message the
# stock mobile daemon itself launches /usr/sbin/sms_msg.lua. The root
# filesystem is read-only, so `--hook` bind-mounts a tiny wrapper
# (sms_msg_hook.lua) over that path - memory-only, re-applied at boot by
# boot.sh. The wrapper runs a copy of the stock handler first (which stores
# the message in /data/etc/mobile/xqSMS.db) and then this script once, which
# reads the new rows with sms-reader (a small static binary - there's no
# sqlite3 CLI on this router; see router/sms-reader/) and forwards them.
#
# Modes:
#   (none)   forward any SMS newer than the last one forwarded
#   --seed   mark everything already in the inbox as seen (setup time)
#   --hook   install the sms_msg.lua wrapper (idempotent)
#   --unhook remove it again
#
DIR=/etc/crontabs/patches
BIN="$DIR/sms-reader"
DB=/data/etc/mobile/xqSMS.db
STATE="$DIR/sms_last_id.txt"
REPLY_MAP="$DIR/sms_reply_map.txt"
HOOK="$DIR/sms_msg_hook.lua"
STOCK=/usr/sbin/sms_msg.lua
STOCK_COPY=/tmp/sms_msg_stock.lua

# shellcheck disable=SC1091
. "$DIR/notify_common.sh"

# sms-reader escapes \, tab, \n and \r in the content/phone fields so each
# row fits on one tab-separated output line (see its own doc comment) -
# undo that before putting the text in an actual notification.
unescape() {
    printf '%s' "$1" | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\r/\r/g; s/\\\\/\\/g'
}

check_once() {
    [ "$SMS_FORWARD" = "0" ] && return 0
    [ -f "$DB" ] || return 0
    [ -x "$BIN" ] || return 0

    last=0
    [ -f "$STATE" ] && last=$(cat "$STATE")
    case "$last" in '' | *[!0-9]*) last=0 ;; esac

    out=$("$BIN" "$DB" "$last" 2>/tmp/sms_reader_err.log) || {
        # Fails closed: log and skip this round rather than guess at
        # something we couldn't actually parse. A transient failure (e.g.
        # caught mid-write) self-heals on the next poll rather than
        # retrying the same read in a tight loop.
        return 0
    }
    [ -z "$out" ] && return 0

    printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r id _state _ts phone content; do
        [ -z "$id" ] && continue
        phone_clean=$(unescape "$phone")
        content_clean=$(unescape "$content")
        if notify "SMS from ${phone_clean:-unknown}" "envelope" "$content_clean"; then
            echo "$id" >"$STATE"
            # Remember which Telegram message this SMS became, so
            # command_watcher.sh can tell a reply to it apart from an
            # ordinary command and send it back to this same number - see
            # its send_sms_reply(). Only meaningful for a real numeric
            # sender (an alphanumeric SMSC alias like "Telekom" can't
            # receive an SMS back) and only on Telegram (ntfy has no
            # reply-to-a-specific-message of its own to hook into).
            if [ "$NOTIFY_BACKEND" = "telegram" ] && [ -n "$NOTIFY_LAST_MSGID" ] && [ -n "$phone_clean" ]; then
                echo "$NOTIFY_LAST_MSGID $phone_clean" >>"$REPLY_MAP"
                tail -n 200 "$REPLY_MAP" >"$REPLY_MAP.tmp" 2>/dev/null && mv "$REPLY_MAP.tmp" "$REPLY_MAP"
            fi
        else
            case "$NOTIFY_LAST_HTTP" in
            429 | 5?? | 000 | "")
                # Transient (network blip, rate limit, backend hiccup) -
                # stop here without advancing STATE, so this same message
                # is retried next poll instead of being silently skipped.
                break
                ;;
            *)
                # Permanent (e.g. Telegram 400 rejecting the payload):
                # retrying can never succeed, and stopping here would block
                # every later SMS behind this one forever (seen live). Skip
                # it, and say so in the log.
                echo "$(date +%s) skipped SMS id=$id: HTTP $NOTIFY_LAST_HTTP" >>/tmp/sms_notify_skipped.log
                echo "$id" >"$STATE"
                ;;
            esac
        fi
    done
}

seed() {
    [ -f "$STATE" ] && return 0
    [ -x "$BIN" ] && [ -f "$DB" ] || return 0
    last=$("$BIN" "$DB" 0 2>/dev/null | cut -f 1 | sort -n | tail -n 1)
    case "$last" in '' | *[!0-9]*) return 0 ;; esac
    echo "$last" >"$STATE"
}

hooked() { grep -q " $STOCK " /proc/mounts 2>/dev/null; }

case "$1" in
--seed) seed ;;
--hook)
    [ -f "$HOOK" ] || exit 1
    hooked && exit 0
    # Copy the stock handler before covering it, so the wrapper can still
    # run it. Never re-copy while hooked - that would copy the wrapper.
    cp "$STOCK" "$STOCK_COPY" && mount --bind "$HOOK" "$STOCK"
    ;;
--unhook)
    hooked && umount "$STOCK"
    rm -f "$STOCK_COPY"
    ;;
*)
    # Two SMS arriving together start two wrappers; take turns so the same
    # message is never forwarded twice.
    (
        flock -w 60 9 || exit 0
        check_once
    ) 9>/tmp/sms_notify.lock
    ;;
esac
