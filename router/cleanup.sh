#!/bin/sh
#
# cleanup.sh - strips a Xiaomi 5G CPE Pro (CB0401/CB0401V2) on stock MiWiFi
# firmware down to what the router actually needs to route, run Wi-Fi and
# stay on the cellular network: telemetry uploads, dead cron jobs, and the
# background services that only talk to Xiaomi's cloud, the Mi Home app,
# Mesh satellites or the carrier's remote management. Run ON the router as
# root (setup.sh / setup.ps1 do this for you).
#
# Everything is switched off by default. Keep a group if you use it:
#   --keep-cloud   Xiaomi cloud / MQTT (messagingagent, xq_info_sync_mqtt,
#                  mosquitto) - needed only for remote access via the Mi
#                  WiFi / Mi Home app
#   --keep-mesh    Xiaomi Mesh (cab_meshd, meshd, miwifi-discovery,
#                  miwifi-roam) - needed only with Mesh satellite nodes
#   --keep-tr069   carrier remote management (easycwmpd, tr069_stun)
#   --keep-miot    Mi Home smart-device integration (miot)
#
# smartcontroller is deliberately left alone: its web API is what
# bootstrap/open_ssh uses to open SSH on newer firmware.
#
set -e

KEEP_CLOUD=0
KEEP_MESH=0
KEEP_TR069=0
KEEP_MIOT=0
for arg in "$@"; do
  case "$arg" in
    --keep-cloud) KEEP_CLOUD=1 ;;
    --keep-mesh) KEEP_MESH=1 ;;
    --keep-tr069) KEEP_TR069=1 ;;
    --keep-miot) KEEP_MIOT=1 ;;
  esac
done

DIR=/etc/crontabs/patches
say() { echo "==> $*"; }

remove_cron_matching() {
  if [ -f /etc/crontabs/root ] && grep -q "$1" /etc/crontabs/root 2>/dev/null; then
    grep -v "$1" /etc/crontabs/root > /etc/crontabs/root.new
    mv /etc/crontabs/root.new /etc/crontabs/root
    say "removed cron entry: $1"
  fi
}

# --- Telemetry and dead cron entries ------------------------------------------
# /etc/crontabs/root and UCI live on the persistent /data partition, so these
# survive reboots on their own.
remove_cron_matching 'sp_check.sh'       # uploads web/rom/privacy logs to Xiaomi
remove_cron_matching 'otapredownload'    # OTA pre-download (would also undo a downgrade)
remove_cron_matching 'mobile_accel.sh'   # script doesn't exist on this build
remove_cron_matching 'run-parts'         # /etc/periodic doesn't exist on this build
uci set misc.features='features' 2>/dev/null || true
uci set misc.features.statpointsNoLog='1' 2>/dev/null || true
uci commit misc 2>/dev/null || true

# --- Services -----------------------------------------------------------------
# `/etc/init.d/X disable` only edits /etc/rc.d, which sits on this router's
# ramfs /etc and reverts on every reboot, so the list is saved here and
# re-applied once per boot by boot.sh (via cleanup_persist.sh).
mkdir -p "$DIR"
cat > "$DIR/cleanup.conf" <<EOF
KEEP_CLOUD=$KEEP_CLOUD
KEEP_MESH=$KEEP_MESH
KEEP_TR069=$KEEP_TR069
KEEP_MIOT=$KEEP_MIOT
EOF

cat > "$DIR/cleanup_persist.sh" <<'PERSIST_EOF'
#!/bin/sh
# Stops and disables the stock services cleanup.sh switched off.
DIR=/etc/crontabs/patches
KEEP_CLOUD=0 KEEP_MESH=0 KEEP_TR069=0 KEEP_MIOT=0
[ -f "$DIR/cleanup.conf" ] && . "$DIR/cleanup.conf"
off() {
    for s in "$@"; do
        [ -f "/etc/init.d/$s" ] || continue
        /etc/init.d/"$s" stop >/dev/null 2>&1 || true
        /etc/init.d/"$s" disable >/dev/null 2>&1 || true
        echo "off: $s"
    done
}
off breakpad
[ "$KEEP_CLOUD" = "1" ] || off messagingagent.sh xq_info_sync_mqtt mosquitto
[ "$KEEP_MESH" = "1" ] || off cab_meshd meshd miwifi-discovery miwifi-roam
[ "$KEEP_TR069" = "1" ] || off easycwmpd tr069_stun
[ "$KEEP_MIOT" = "1" ] || off miot
exit 0
PERSIST_EOF
chmod +x "$DIR/cleanup_persist.sh"

# Older versions ran cleanup_persist.sh from its own cron line; boot.sh does now.
remove_cron_matching 'cleanup_persist.sh'
rm -f /tmp/cleanup_persist.log

sh "$DIR/cleanup_persist.sh" | while read -r line; do say "$line"; done
say "Done (kept: cloud=$KEEP_CLOUD mesh=$KEEP_MESH tr069=$KEEP_TR069 miot=$KEEP_MIOT)."
