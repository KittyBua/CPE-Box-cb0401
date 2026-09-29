#!/bin/sh
#
# CPE Box router-side installer - the single copy of everything setup.sh and
# setup.ps1 do ON the router, so macOS/Linux and Windows installs can't drift
# apart. They upload the router/ files (plus the generated notify.conf and,
# if available, the sms-reader binary) to /tmp/cpebox/ and run:
#
#   sh /tmp/cpebox/install.sh [cleanup.sh flags, e.g. --keep-mesh]
#
# Safe to re-run.
#
SRC=/tmp/cpebox
DIR=/etc/crontabs/patches
say() { echo "==> $*"; }

mkdir -p "$DIR"
for f in notify.conf notify_common.sh device_monitor.sh dhcp_notify.sh command_watcher.sh \
    sms_notify.sh json_unescape.lua boot.sh sms_msg_hook.lua sms-reader wifi_dfs_persist.sh; do
    if [ -f "$SRC/$f" ]; then cp "$SRC/$f" "$DIR/$f"; fi
done
chmod 600 "$DIR/notify.conf" 2>/dev/null
chmod +x "$DIR"/*.sh
if [ -f "$DIR/sms-reader" ]; then chmod +x "$DIR/sms-reader"; fi
rm -f "$DIR/ntfy_command_watcher.sh"

# New-device alerts: dnsmasq runs dhcp_notify.sh for every lease it grants
# (event-driven, nothing polls). The one-shot device_monitor.sh scan first
# marks devices that are already connected as seen.
touch "$DIR/known_macs.txt"
sh "$DIR/device_monitor.sh"
uci set dhcp.@dnsmasq[0].dhcpscript="$DIR/dhcp_notify.sh"
uci commit dhcp
/etc/init.d/dnsmasq reload >/dev/null 2>&1 || /etc/init.d/dnsmasq restart >/dev/null 2>&1
say "new-device alerts wired to dnsmasq"

# One cron line for the whole toolkit (boot.sh); drop the per-script lines
# earlier versions added.
sed -i '/ntfy_command_watcher\.sh/d; /\/device_monitor\.sh/d; /command_watcher\.sh/d; /sms_notify\.sh/d; /keep_ssh_key\.sh/d; /cleanup_persist\.sh/d; /patches\/ssh_patch\.sh/d; /patches\/boot\.sh/d' /etc/crontabs/root 2>/dev/null
echo "* * * * * sh $DIR/boot.sh >/dev/null 2>&1" >> /etc/crontabs/root
/etc/init.d/cron restart >/dev/null 2>&1
sh "$DIR/command_watcher.sh" --restart
say "command listener started"

# SMS forwarding used to be a polling daemon; it's event-driven now (see
# sms_notify.sh). Stop a leftover daemon from an older install.
for p in $(ps w | grep '[s]ms_notify.sh --daemon' | awk '{print $1}'); do kill "$p" 2>/dev/null; done
rm -f /tmp/sms_notify.pid
if [ -x "$DIR/sms-reader" ]; then
    # Whatever is already in the inbox counts as seen - setup never forwards
    # old messages.
    sh "$DIR/sms_notify.sh" --seed
    sh "$DIR/sms_notify.sh" --hook
    say "SMS forwarding hooked to the stock SMS handler"
fi

if [ -f "$SRC/cleanup.sh" ]; then
    sh "$SRC/cleanup.sh" "$@"
fi

# 5 GHz: unblock DFS channels (needed for 160 MHz) and turn on pre-CAC so a
# real radar hit swaps to a ready backup channel instantly. See the script
# comment for the full rationale.
if [ -f "$DIR/wifi_dfs_persist.sh" ]; then
    sh "$DIR/wifi_dfs_persist.sh" || true
    say "5 GHz DFS-friendly config applied (survives reboot)"
fi

rm -rf "$SRC"
say "router side done"
