#!/bin/bash
#
# setup.sh — one-shot, fully self-contained setup for the CPE Box,
# for macOS and Linux. No Python, no third-party exploit tool - just bash,
# an SSH client, and (optionally) Go if you want to build the GUI from
# source instead of using a prebuilt binary.
#
# What this does, in order:
#   1. Checks prerequisites (ssh/scp, curl).
#   2. Opens persistent root SSH on the router (bootstrap/open_ssh.sh) -
#      see that script's header comment for exactly how and why this
#      works. Skipped if SSH already works.
#   3. Falls back to a password-based key install if step 2 wasn't needed
#      (SSH already open with the factory default password) or didn't
#      apply (Telnet already closed) - this needs the router's password
#      exactly once. We never change this password - see the README for
#      why.
#   4. Sets up push notifications and device-block commands, either via a
#      random private ntfy.sh topic or a Telegram bot (your choice), and
#      copies router/*.sh onto the router with that config baked in (over
#      the key-based connection from step 2/3 — no more passwords needed
#      after this point).
#   5. Runs router/cleanup.sh on the router to remove telemetry/dead cron
#      jobs (safe by default — see cleanup.sh's own flags for optional
#      extras).
#   6. Gets the GUI (built from source with Go, otherwise the latest GitHub
#      release - see panel/fetch.sh), uses it to unlock every band the modem
#      supports and install the 5G mode hook (first run only - see
#      provisionRouter in panel/router.go), then launches it.
#
# Safe to re-run: every step is idempotent.
#
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_IP="${ROUTER_IP:-192.168.31.1}"
KEY_PATH="$REPO_DIR/panel/router_key"
ENV_FILE="$REPO_DIR/panel/.env"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o ConnectTimeout=5)

say() { echo; echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Modern OpenSSH (9.0+, the default on macOS 13+ and recent Linux distros)
# switched scp to an SFTP-based transfer by default, which needs
# /usr/libexec/sftp-server on the remote side - this router's dropbear does
# not have one ("ash: /usr/libexec/sftp-server: not found"), only the
# legacy SCP protocol works against it (-O). Older OpenSSH clients (<9.0)
# don't recognize -O at all and use the legacy protocol anyway, so this
# tries -O first and falls back to plain scp if the local client rejects
# the flag outright.
scp_to_router() {
  local err
  err="$(scp -O "${SSH_OPTS[@]}" -i "$KEY_PATH" "$@" 2>&1)" && return 0
  if echo "$err" | grep -qi 'unknown option'; then
    scp "${SSH_OPTS[@]}" -i "$KEY_PATH" "$@"
  else
    echo "$err" >&2
    return 1
  fi
}

say "CPE Box setup"
echo "Router IP:      $ROUTER_IP"
echo "GUI key path:   $KEY_PATH"

# --- 1. Prerequisites -------------------------------------------------------

say "Checking prerequisites"
command -v ssh >/dev/null 2>&1 || die "an OpenSSH client (ssh/scp) is required. Install it and re-run."
command -v curl >/dev/null 2>&1 || die "curl is required. Install it and re-run."

if ! command -v sshpass >/dev/null 2>&1; then
  say "Installing sshpass (used by the GUI to self-heal if it ever loses SSH key access)"
  if command -v brew >/dev/null 2>&1; then
    brew install sshpass 2>/dev/null || brew install hudochenkov/sshpass/sshpass || true
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y sshpass || true
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y sshpass || true
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm sshpass || true
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y sshpass || true
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache sshpass || true
  fi
  command -v sshpass >/dev/null 2>&1 || echo "Could not install sshpass automatically — the GUI will still work, it just won't be able to self-heal a lost SSH key. Install sshpass manually to enable that."
fi

mkdir -p "$(dirname "$KEY_PATH")"
if [ ! -f "$KEY_PATH" ]; then
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "cpe-box-gui" -q
fi

# --- 2. Open SSH on the router -----------------------------------------------

if ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" -o BatchMode=yes "root@$ROUTER_IP" true 2>/dev/null; then
  say "SSH already works via key — nothing to open."
else
  say "Opening SSH access on the router"
  if "$REPO_DIR/bootstrap/open_ssh.sh" "$ROUTER_IP" "$KEY_PATH.pub"; then
    say "SSH opened and this toolkit's key installed."
  else
    echo "The automatic bootstrap didn't apply (e.g. Telnet is already closed, which is"
    echo "normal if SSH is already enabled with the factory password some other way)."

    # --- 3. Fall back to a password-based key install -------------------------

    say "Falling back to installing the key over SSH with a password"
    PUBKEY="$(cat "$KEY_PATH.pub")"
    INSTALL_CMD="mkdir -p /etc/dropbear; grep -qF '$PUBKEY' /etc/dropbear/authorized_keys 2>/dev/null || echo '$PUBKEY' >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys"

    # If a previous run on this router already recorded a password (e.g.
    # changed through the GUI's own "Change root password" field), try that
    # first via sshpass - no need to retype it by hand every time just
    # because this particular checkout's key hasn't been installed yet.
    KNOWN_PASSWORD=""
    if [ -f "$ENV_FILE" ] && grep -q '^ROUTER_ROOT_PASSWORD=' "$ENV_FILE"; then
      KNOWN_PASSWORD="$(grep '^ROUTER_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
    fi
    if [ -n "$KNOWN_PASSWORD" ] && command -v sshpass >/dev/null 2>&1 \
      && sshpass -p "$KNOWN_PASSWORD" ssh "${SSH_OPTS[@]}" "root@$ROUTER_IP" "$INSTALL_CMD" 2>/dev/null; then
      say "Installed the key using the password already on file."
    else
      echo "You will be asked for the router's SSH password now — the derived default"
      echo "described in the README's 'How SSH access is opened' section, or whatever"
      echo "you've since changed it to (e.g. through the GUI's Change root password)."
      echo
      if command -v sshpass >/dev/null 2>&1 && [ -t 0 ]; then
        # Read it here rather than letting ssh prompt, so a password that
        # works gets remembered in panel/.env below - the GUI's self-heal and
        # the next setup run need it, and before this fix .env only ever
        # held the placeholder "root", which never matches a changed one.
        KNOWN_PASSWORD=""
        for _attempt in 1 2 3; do
          read -r -s -p "root@$ROUTER_IP password: " TYPED_PASSWORD; echo
          if sshpass -p "$TYPED_PASSWORD" ssh "${SSH_OPTS[@]}" "root@$ROUTER_IP" "$INSTALL_CMD" 2>/dev/null; then
            KNOWN_PASSWORD="$TYPED_PASSWORD"
            break
          fi
          echo "That password was rejected."
        done
        unset TYPED_PASSWORD
        [ -n "$KNOWN_PASSWORD" ] || die "Could not log in to the router over SSH with that password. Check that it's reachable at $ROUTER_IP and see the README for the derived default."
      else
        ssh "${SSH_OPTS[@]}" "root@$ROUTER_IP" "$INSTALL_CMD" \
          || die "Could not reach the router over SSH with that password either. Check that it's reachable at $ROUTER_IP."
      fi
    fi
  fi
fi

ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" -o BatchMode=yes "root@$ROUTER_IP" true \
  || die "Key-based login still fails after installing the key — check the router's dropbear config."
echo "Key-based SSH login confirmed. No more passwords needed from here on."

# /etc/dropbear/authorized_keys sits on this router's ramfs-mounted /etc,
# so the key installed above vanishes on every router reboot (confirmed:
# after one, both the key and a stale .env password were rejected and
# nothing could log in). Keep a copy in /etc/crontabs/patches - persistent
# storage, the same place ssh_patch.sh lives - and put it back within a
# minute of every boot.
PUBKEY="$(cat "$KEY_PATH.pub")"
if {
  echo "mkdir -p /etc/crontabs/patches"
  echo "echo '$PUBKEY' > /etc/crontabs/patches/toolkit_key.pub"
  cat <<'KEEP_KEY_REMOTE'
cat > /etc/crontabs/patches/keep_ssh_key.sh <<'KEEP_KEY_EOF'
#!/bin/sh
# Re-adds cpe-box's SSH key after a reboot wiped the ramfs /etc.
K=/etc/crontabs/patches/toolkit_key.pub
[ -s "$K" ] || exit 0
mkdir -p /etc/dropbear
grep -qF "$(cat "$K")" /etc/dropbear/authorized_keys 2>/dev/null && exit 0
cat "$K" >> /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
KEEP_KEY_EOF
chmod +x /etc/crontabs/patches/keep_ssh_key.sh
sed -i '/keep_ssh_key.sh/d' /etc/crontabs/root
sh /etc/crontabs/patches/keep_ssh_key.sh
KEEP_KEY_REMOTE
} | ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" -o BatchMode=yes "root@$ROUTER_IP" sh; then
  echo "The key will be restored automatically after router reboots (by boot.sh, set up below)."
else
  echo "NOTE: couldn't install the key-restore job; after a router reboot, re-run ./start.sh."
fi

# --- 4. Notifications: ntfy.sh or Telegram, + device-monitor scripts -------

say "Setting up push notifications"
# Precedence: an explicit NOTIFY_BACKEND env var always wins (needed for a
# non-interactive re-run that switches backend); otherwise reuse whatever
# was chosen last time; otherwise ask, if we can; otherwise default to ntfy.
if [ -n "${NOTIFY_BACKEND:-}" ]; then
  echo "Using notification backend from the NOTIFY_BACKEND environment variable: $NOTIFY_BACKEND"
elif [ -f "$ENV_FILE" ] && grep -q '^NOTIFY_BACKEND=' "$ENV_FILE"; then
  NOTIFY_BACKEND="$(grep '^NOTIFY_BACKEND=' "$ENV_FILE" | cut -d= -f2-)"
  echo "Reusing existing notification backend from $ENV_FILE: $NOTIFY_BACKEND"
elif [ -t 0 ]; then
  echo "Choose how you want to receive device alerts and send block/red-alert commands:"
  echo "  1) ntfy.sh  - zero setup: just a free app and a random shared topic (default)"
  echo "  2) Telegram - needs a bot token + your chat ID, but ties access to your account"
  read -r -p "Choice [1]: " choice
  case "$choice" in
    2) NOTIFY_BACKEND="telegram" ;;
    *) NOTIFY_BACKEND="ntfy" ;;
  esac
fi
NOTIFY_BACKEND="${NOTIFY_BACKEND:-ntfy}"

NTFY_TOPIC=""
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [ "$NOTIFY_BACKEND" = "telegram" ]; then
  if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ -f "$ENV_FILE" ] && grep -q '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE"; then
    TELEGRAM_BOT_TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2-)"
    TELEGRAM_CHAT_ID="$(grep '^TELEGRAM_CHAT_ID=' "$ENV_FILE" | cut -d= -f2-)"
    echo "Reusing existing Telegram bot config from $ENV_FILE"
  fi
  if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ -t 0 ]; then
    echo "Create a bot with @BotFather on Telegram (free, one-time) to get a token,"
    echo "then send it any message so it can see your chat ID."
    read -r -p "Telegram bot token: " TELEGRAM_BOT_TOKEN
    read -r -p "Your Telegram chat ID: " TELEGRAM_CHAT_ID
  fi
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || die "Telegram backend selected but TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID aren't set (export them as environment variables for a non-interactive run)."
  echo "Telegram bot configured."
  echo "(The bot token is a secret — anyone who has it can send messages as your bot"
  echo " and read what's sent to it. It's stored only in $ENV_FILE, which is gitignored.)"
else
  if [ -f "$ENV_FILE" ] && grep -q '^NTFY_TOPIC=' "$ENV_FILE"; then
    NTFY_TOPIC="$(grep '^NTFY_TOPIC=' "$ENV_FILE" | cut -d= -f2-)"
    echo "Reusing existing topic from $ENV_FILE"
  else
    if command -v openssl >/dev/null 2>&1; then
      NTFY_TOPIC="cpebox-$(openssl rand -hex 8)"
    else
      NTFY_TOPIC="cpebox-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
  fi
  echo "ntfy.sh topic: $NTFY_TOPIC"
  echo "(This is a shared secret — anyone who knows it can read your device alerts"
  echo " and send block/red-alert commands. Keep it private; it is never committed to git.)"
fi

TMP_DIR="$(mktemp -d)"
cat > "$TMP_DIR/notify.conf" <<EOF
NOTIFY_BACKEND=$NOTIFY_BACKEND
NTFY_TOPIC=$NTFY_TOPIC
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF
for f in install.sh cleanup.sh notify_common.sh device_monitor.sh dhcp_notify.sh command_watcher.sh \
    sms_notify.sh json_unescape.lua boot.sh sms_msg_hook.lua; do
  cp "$REPO_DIR/router/$f" "$TMP_DIR/$f"
done

# sms-reader is the ARMv7 SQLite reader that runs ON the router. It ships
# embedded inside every prebuilt cpe-box binary (see panel/embed_smsreader.go),
# so ensure_gui_bin below makes it available; fetch_sms_reader dumps it out.
# When Go is installed it cross-builds a fresh one instead, so anyone
# hacking on router/sms-reader/ sees their edits without re-running the
# whole release pipeline. On the very rare setup where none of that works,
# SMS forwarding is skipped rather than the whole setup failing.
. "$REPO_DIR/panel/fetch.sh"
ensure_gui_bin || die "couldn't build or download CPE Box"
if ! fetch_sms_reader "$TMP_DIR"; then
  echo "NOTE: couldn't extract or build sms-reader (needs Go, or an already-fetched"
  echo "      cpe-box binary). Skipping SMS forwarding; everything else is unaffected."
fi

ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" "root@$ROUTER_IP" 'rm -rf /tmp/cpebox && mkdir -p /tmp/cpebox'
scp_to_router "$TMP_DIR"/* "root@$ROUTER_IP:/tmp/cpebox/" >/dev/null
rm -rf "$TMP_DIR"

# --- 5. Router install + cleanup ---------------------------------------------
# router/install.sh is the one place everything done ON the router lives
# (shared with setup.ps1). It also runs cleanup.sh: telemetry, dead cron jobs
# and the cloud/Mesh/TR-069/Mi Home services are switched off by default;
# CLEANUP_FLAGS keeps a group you use (--keep-cloud / --keep-mesh /
# --keep-tr069 / --keep-miot - see router/cleanup.sh).
say "Installing on the router and cleaning it up"
ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" "root@$ROUTER_IP" "sh /tmp/cpebox/install.sh ${CLEANUP_FLAGS:-}"
[ -z "${CLEANUP_FLAGS:-}" ] && echo "(Using the Mi WiFi/Mi Home app, Mesh satellites or carrier remote management? Re-run with e.g. CLEANUP_FLAGS='--keep-mesh'.)"

# Sanity check that install.sh's pieces actually landed. The stock firmware
# owns /etc via ramfs, so a stray "Read-only file system" / "no space left
# on device" mid-install used to fail silently and leave a half-configured
# router (e.g. cron entry but no boot.sh, so nothing runs on next boot).
say "Verifying the router side"
MISSING="$(ssh "${SSH_OPTS[@]}" -i "$KEY_PATH" "root@$ROUTER_IP" '
  D=/etc/crontabs/patches; missing=""
  for f in boot.sh notify_common.sh command_watcher.sh dhcp_notify.sh notify.conf wifi_dfs_persist.sh; do
    [ -f "$D/$f" ] || missing="$missing $f"
  done
  grep -q "$D/boot.sh" /etc/crontabs/root || missing="$missing (cron line)"
  echo "$missing"
' 2>/dev/null)"
if [ -n "$MISSING" ]; then
  echo "WARNING: some router-side pieces didn't install:$MISSING"
  echo "         setup keeps going, but re-run setup.sh once - it's idempotent."
else
  echo "All router-side pieces are in place."
fi

# --- 6. GUI --------------------------------------------------------------

say "Setting up the local GUI"

# Keep the root password .env already had (the GUI's Change root password
# writes it there) unless a different one was just typed and accepted
# above. This used to be hard-coded to "root", silently wiping the real
# password on every setup run.
if [ -z "${KNOWN_PASSWORD:-}" ] && [ -f "$ENV_FILE" ] && grep -q '^ROUTER_ROOT_PASSWORD=' "$ENV_FILE"; then
  KNOWN_PASSWORD="$(grep '^ROUTER_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
fi
# Same for an opt-in LAN bind (see README) - don't silently drop it.
KEEP_GUI_BIND=""
if [ -f "$ENV_FILE" ] && grep -q '^GUI_BIND=' "$ENV_FILE"; then
  KEEP_GUI_BIND="$(grep '^GUI_BIND=' "$ENV_FILE" | cut -d= -f2-)"
fi
# Anything else in .env (the panel's session key, GUI_HOSTNAME, ...) is kept.
KEEP_OTHER=""
[ -f "$ENV_FILE" ] && KEEP_OTHER="$(grep -vE '^(ROUTER_IP|ROUTER_ROOT_PASSWORD|NOTIFY_BACKEND|NTFY_TOPIC|TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID|GUI_BIND)=' "$ENV_FILE" | grep -v '^[[:space:]]*$' || true)"
cat > "$ENV_FILE" <<EOF
ROUTER_IP=$ROUTER_IP
ROUTER_ROOT_PASSWORD=${KNOWN_PASSWORD:-root}
NOTIFY_BACKEND=$NOTIFY_BACKEND
NTFY_TOPIC=$NTFY_TOPIC
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF
# Reachable from every device on the LAN by default (they log in with the
# router root password); set GUI_BIND=127.0.0.1:7777 to keep it local.
echo "GUI_BIND=${KEEP_GUI_BIND:-0.0.0.0:7777}" >> "$ENV_FILE"
[ -n "$KEEP_OTHER" ] && echo "$KEEP_OTHER" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

say "Unlocking modem bands and installing the 5G mode hook"
GUI_BIN="$REPO_DIR/panel/cpe-box"
"$GUI_BIN" --provision || die "band unlock / 5G mode hook setup failed"

say "Setup complete. Starting the GUI..."
exec "$REPO_DIR/panel/start_gui.sh"
