#!/bin/sh
#
# CPE Box's only cron job (every minute). Its real work happens once per
# boot - /tmp is ramfs, so the marker below disappears on every reboot -
# which is when this router forgets things: /etc is ramfs too, so the SSH
# key, dropbear's enable state and the disabled stock services all revert.
# After that it's a single cheap check that the Telegram/ntfy command
# listener (the toolkit's one long-running process) is still up.
#
DIR=/etc/crontabs/patches

if [ ! -e /tmp/cpebox_boot.done ]; then
    : > /tmp/cpebox_boot.done
    [ -f "$DIR/ssh_patch.sh" ] && sh "$DIR/ssh_patch.sh"
    [ -f "$DIR/keep_ssh_key.sh" ] && sh "$DIR/keep_ssh_key.sh"
    [ -f "$DIR/cleanup_persist.sh" ] && sh "$DIR/cleanup_persist.sh" >/dev/null
    [ -f "$DIR/wifi_dfs_persist.sh" ] && sh "$DIR/wifi_dfs_persist.sh" >/dev/null
    [ -f "$DIR/sms_msg_hook.lua" ] && [ -x "$DIR/sms-reader" ] && sh "$DIR/sms_notify.sh" --hook
fi

[ -f "$DIR/command_watcher.sh" ] && sh "$DIR/command_watcher.sh" --ensure
exit 0
