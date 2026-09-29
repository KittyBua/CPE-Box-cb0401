#!/bin/sh
#
# Shared by device_monitor.sh and command_watcher.sh: loads the active
# notification backend's config and provides notify() to send an alert
# through whichever one is configured.
#
# Config file (written by setup.sh/setup.ps1): /etc/crontabs/patches/notify.conf
#
#   NOTIFY_BACKEND=ntfy
#   NTFY_TOPIC=cpebox-xxxxxxxxxxxxxxxx
#
# or:
#
#   NOTIFY_BACKEND=telegram
#   TELEGRAM_BOT_TOKEN=123456:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#   TELEGRAM_CHAT_ID=12345678
#
DIR=/etc/crontabs/patches
CONF="$DIR/notify.conf"

NOTIFY_BACKEND="ntfy"
NTFY_TOPIC=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# $1=title  $2=tag (ntfy-only, ignored for telegram)  $3=body
#
# Returns success (0) only if the backend actually accepted the message
# (HTTP 200), not just "curl ran" - a caller that uses this to decide
# whether it's safe to mark something as handled (e.g. "this SMS/device is
# now dealt with, don't repeat it") needs to know the difference between
# "delivered" and "curl hit a timeout/DNS blip", or a transient failure
# silently and permanently drops the one notification it happened to hit.
#
# On a successful Telegram send, also sets NOTIFY_LAST_MSGID to the
# message_id Telegram assigned - callers that need to correlate a later
# reply back to this specific message (e.g. sms_notify.sh, so a Telegram
# reply can be routed back to the phone number that sent the original SMS)
# read it right after calling notify(). Empty for ntfy (no such concept)
# or if the send failed. NOTIFY_LAST_HTTP always holds the HTTP status, so a
# caller can tell a transient failure (timeout: empty/000, 5xx, 429 - worth
# retrying) from a permanent one (other 4xx, e.g. Telegram rejecting the
# payload itself - retrying can never succeed).
# The bot token / ntfy topic are secrets and live in the request URL. Any
# process on the router can read another's command line (ps, /proc/*/cmdline),
# so the URL goes to curl as a config on stdin (-K -) instead of an argument.
curl_url() {
    _url="$1"
    shift
    printf 'url = "%s"\n' "$_url" | curl "$@" -K -
}

notify() {
    title="$1"
    body="$3"
    NOTIFY_LAST_MSGID=""
    NOTIFY_LAST_HTTP=""
    case "$NOTIFY_BACKEND" in
        telegram)
            resp=$(curl_url "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -s -m 10 -w '\nHTTPSTATUS:%{http_code}' -X POST \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=${title}
${body}")
            code=$(printf '%s\n' "$resp" | sed -n 's/^HTTPSTATUS://p')
            NOTIFY_LAST_MSGID=$(printf '%s\n' "$resp" | sed -n 's/.*"message_id":\([0-9]*\).*/\1/p' | head -1)
            ;;
        *)
            code=$(curl_url "https://ntfy.sh/$NTFY_TOPIC" -s -m 10 -o /dev/null -w '%{http_code}' -H "Title: $title" -H "Tags: $2" -d "$body")
            ;;
    esac
    NOTIFY_LAST_HTTP="$code"
    [ "$code" = "200" ]
}
