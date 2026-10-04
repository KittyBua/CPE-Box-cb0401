# CPE Box — Home Assistant OS add-on

Runs CPE Box as an always-on add-on on **Home Assistant OS / Supervised**, so you don't need a separate laptop or phone awake. (On HA **Container** or **Core** you have a normal Linux host — just use the regular [`./start.sh`](https://github.com/Kreal-exe/CPE-Box-cb0401#getting-started) flow instead.)

## Install

1. In Home Assistant: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**, and add:
   `https://github.com/Kreal-exe/CPE-Box-cb0401`
2. Install **CPE Box** from the store.
3. On the **Configuration** tab, set `router_password` (your router's root password) and, if your router isn't at `192.168.31.1`, `router_ip`. Pick `ntfy` (default) or `telegram` for notifications — for Telegram also fill `telegram_bot_token` / `telegram_chat_id`.
4. **Start** the add-on, then open `http://<your-home-assistant-ip>:7777`.

On first start it opens SSH to the router, installs its key, sets up the router-side hooks and launches the panel — the same thing `setup.sh` does, just non-interactively. The cloned repo, the SSH key and `.env` live in the add-on's persistent `/data`, so they survive restarts and updates.

## Notes

- Uses host networking so it can reach the router on your LAN and serve the panel on port 7777.
- The prebuilt `cpe-box` binary is downloaded on first start (CGO-free, so it runs on the add-on's Alpine base); no Go needed.
- To change the router password later, update it here and restart — the panel login reads it from `.env`.
