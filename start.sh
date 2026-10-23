#!/bin/bash
#
# start.sh — the one command to run, on macOS or Linux, whether this is the
# very first run or the hundredth.
#
# Does a quick check for whether setup has already been done (does the SSH
# key exist and actually work against the router right now?):
#   - Not set up yet -> runs the full setup.sh (opens SSH, configures
#     notifications, cleans up telemetry, then launches the GUI).
#   - Already set up -> skips straight to launching the GUI, without
#     redoing the SSH/notification/cleanup steps every time.
#
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

ROUTER_IP="${ROUTER_IP:-192.168.31.1}"
KEY_PATH="panel/router_key"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o ConnectTimeout=5 -o BatchMode=yes)

# Setup is considered done when BOTH the SSH key still works AND cpe-box's
# own boot marker lives on the router - a naked working key isn't enough,
# because the router's tmpfs /etc gets wiped on factory reset (or by some
# firmware updates), which drops all our patches while the key itself
# survives in the local repo. Without this second check start.sh would
# happily skip to start_gui.sh and the panel would run half-broken (no
# notification hooks, no SMS reader, no DFS patches).
# Keep the router-side scripts in step with this checkout: setup.sh only
# uploads them once, so a fix to e.g. command_watcher.sh would otherwise
# never reach a router that's already set up. Compares md5s and re-uploads
# only what changed (notify.conf and the sms-reader binary are left alone).
# Best-effort - never stops the panel from starting.
sync_router_scripts() {
  local d=/etc/crontabs/patches f remote changed=""
  local files="notify_common.sh device_monitor.sh dhcp_notify.sh command_watcher.sh sms_notify.sh json_unescape.lua boot.sh sms_msg_hook.lua wifi_dfs_persist.sh"
  remote="$(ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" "root@$ROUTER_IP" "cd $d 2>/dev/null && md5sum $files 2>/dev/null" 2>/dev/null)" || return 0
  for f in $files; do
    [ -f "router/$f" ] || continue
    local l; l="$( { md5sum "router/$f" 2>/dev/null || md5 -r "router/$f"; } | awk '{print $1}')"
    printf '%s\n' "$remote" | grep -q "^$l  $f\$" || changed="$changed $f"
  done
  [ -n "$changed" ] || return 0
  echo "Updating router scripts:$changed"
  for f in $changed; do
    ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" "root@$ROUTER_IP" "cat > $d/$f.new && mv $d/$f.new $d/$f && chmod +x $d/$f" < "router/$f" 2>/dev/null || true
  done
  case "$changed" in *command_watcher.sh*)
    ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" "root@$ROUTER_IP" "sh $d/command_watcher.sh --restart" >/dev/null 2>&1 || true ;;
  esac
}

if [ -f "$KEY_PATH" ] && ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" "root@$ROUTER_IP" \
    "[ -f /etc/crontabs/patches/boot.sh ]" 2>/dev/null; then
  sync_router_scripts
  exec ./panel/start_gui.sh
else
  exec ./setup.sh
fi
