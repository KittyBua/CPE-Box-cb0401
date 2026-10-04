#!/usr/bin/with-contenv bashio
# Home Assistant OS add-on entrypoint. Reads the options, drops them into the
# panel's .env so setup.sh/start.sh run non-interactively, then launches the
# normal flow. /data is the add-on's persistent store, so the cloned repo, the
# SSH key and .env survive restarts and updates.
set -e

ROUTER_IP="$(bashio::config 'router_ip')"
ROUTER_PW="$(bashio::config 'router_password')"
NOTIFY_BACKEND="$(bashio::config 'notify_backend')"
TELEGRAM_BOT_TOKEN="$(bashio::config 'telegram_bot_token')"
TELEGRAM_CHAT_ID="$(bashio::config 'telegram_chat_id')"
export ROUTER_IP NOTIFY_BACKEND TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID

if [ -z "$ROUTER_PW" ]; then
  bashio::exit.nok "Set 'router_password' (the router's root password) in the add-on configuration, then restart."
fi
if [ "$NOTIFY_BACKEND" = "telegram" ] && { [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; }; then
  bashio::exit.nok "notify_backend is 'telegram' but telegram_bot_token / telegram_chat_id aren't set."
fi

APP=/data/CPE-Box-cb0401
if [ -d "$APP/.git" ]; then
  bashio::log.info "Updating CPE Box..."
  # Hard-reset to the latest upstream rather than a --ff-only pull: that keeps
  # working across a rewritten/force-pushed history (otherwise a fix can ship
  # but never reach the installed copy). .env and the SSH key are untracked, so
  # they're left untouched.
  if git -C "$APP" fetch --depth 1 origin 2>/dev/null; then
    git -C "$APP" reset --hard FETCH_HEAD >/dev/null 2>&1 || bashio::log.warning "update checkout failed; keeping the existing copy."
  else
    bashio::log.warning "git fetch failed; keeping the existing copy."
  fi
else
  bashio::log.info "Cloning CPE Box..."
  git clone --depth 1 https://github.com/Kreal-exe/CPE-Box-cb0401 "$APP"
fi

# Write router_ip / password / bind from the options (so changing them in the
# add-on config takes effect), while preserving anything setup.sh already added
# (the notification config, the panel's session secret).
install -d -m 700 "$APP/panel"
ENV="$APP/panel/.env"
KEEP=""
[ -f "$ENV" ] && KEEP="$(grep -vE '^(ROUTER_IP|ROUTER_ROOT_PASSWORD|GUI_BIND)=' "$ENV" || true)"
{
  printf 'ROUTER_IP=%s\n' "$ROUTER_IP"
  printf 'ROUTER_ROOT_PASSWORD=%s\n' "$ROUTER_PW"
  printf 'GUI_BIND=0.0.0.0:7777\n'
  [ -n "$KEEP" ] && printf '%s\n' "$KEEP"
} > "$ENV"
chmod 600 "$ENV"

cd "$APP"
bashio::log.info "Starting CPE Box - open http://<your-home-assistant>:7777"
exec ./start.sh
