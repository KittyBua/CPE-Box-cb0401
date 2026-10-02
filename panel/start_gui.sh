#!/bin/bash
#
# Starts CPE Box and opens it in the browser. The binary is built from
# source when Go is installed, otherwise downloaded from the latest GitHub
# release (see fetch.sh) - no Go, Python or anything else needed.
#
# Usage: ./start_gui.sh
#
set -e
cd "$(dirname "$0")"

BIN="./cpe-box"
PORT=7777
# Keep the pid/log in a writable temp dir. Hardcoding /tmp breaks on Termux
# (Android), where there is no writable /tmp but $TMPDIR points to one - without
# this the pidfile/log redirects fail with "Permission denied" and set -e kills
# the launch.
TMPD="${TMPDIR:-/tmp}"
PIDFILE="$TMPD/cpe_box_gui.pid"
LOGFILE="$TMPD/cpe_box_gui.log"

. ./fetch.sh
ensure_gui_bin || exit 1

# Open to every device on the LAN by default (they log in with the router
# root password); GUI_BIND=127.0.0.1:7777 in .env keeps it on this machine.
# Also migrate an older 5757 pin - the default port moved to 7777 in v1.0,
# but existing .env files from earlier setups still say 5757.
grep -q '^GUI_BIND=' .env 2>/dev/null || echo "GUI_BIND=0.0.0.0:7777" >> .env
sed -i.bak 's/^GUI_BIND=\([^:]*\):5757$/GUI_BIND=\1:7777/' .env 2>/dev/null && rm -f .env.bak
chmod 600 .env 2>/dev/null || true

# If something is already listening on the port (e.g. a stale process from
# a previous run), stop it first so we don't hit "Address already in use"
# or end up talking to old code.
if [ -f "$PIDFILE" ]; then
  OLDPID=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    echo "Stopping previous instance (PID $OLDPID)..."
    kill "$OLDPID" 2>/dev/null || true
    sleep 1
    kill -9 "$OLDPID" 2>/dev/null || true
  fi
fi
LSOF_PID=$(lsof -ti tcp:$PORT 2>/dev/null || true)
if [ -n "$LSOF_PID" ]; then
  echo "Port $PORT is in use (PID $LSOF_PID) — freeing it..."
  kill -9 $LSOF_PID 2>/dev/null || true
fi

echo "Starting the GUI on http://127.0.0.1:$PORT ..."
"$BIN" > "$LOGFILE" 2>&1 &
BIN_PID=$!
echo $BIN_PID > "$PIDFILE"

# Wait until the server actually comes up before opening the browser.
# 127.0.0.1:$PORT is our readiness probe - it always works because we bind
# it. The URL we open is preferably http://cpe.box (no port): cpe-box also
# listens on port 80 for the LAN, so the panel opens under its friendly
# name with nothing after it. If port 80 couldn't be bound (permission
# denied) we fall through to http://cpe.box:$PORT, and finally to the raw
# loopback address if the router hasn't registered the .box name in its
# DNS yet (first-run setup).
for i in $(seq 1 20); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then
    break
  fi
  sleep 0.3
done

# http://cpe.box, always. cpe-box registers the .box name in the router's
# DNS on startup and grabs port 80 for the LAN when it can, so the friendly
# URL is what the user should see - no port suffix, no loopback IP. If
# something's wrong (router isn't up yet on a very first run, port 80
# couldn't be bound), the app's own console output tells them the exact
# alternate URL to try; we still open cpe.box so we don't teach them an
# uglier URL by default.
URL="http://cpe.box"
echo "Opening $URL"
open "$URL" 2>/dev/null || xdg-open "$URL" 2>/dev/null || true

# Stay attached to the GUI process instead of returning to the shell prompt
# right away - closing this terminal or hitting Ctrl+C stops the GUI too,
# rather than leaving it running invisibly in the background.
sed -n '2,6p' "$LOGFILE" 2>/dev/null
echo "GUI is running (PID $BIN_PID), log: $LOGFILE"
echo "Press Ctrl+C to stop it."
trap 'kill "$BIN_PID" 2>/dev/null; exit 0' INT TERM
wait "$BIN_PID"
