# Changelog

Release notes for each version. The **Release** workflow
(`.github/workflows/release.yml`) reads the section matching the pushed tag
and uses it as the GitHub release description — followed by the shared install
guide (`.github/release-install.md`) and a Full Changelog link. To cut a
release, add a `## vX.Y.Z` section here, commit, then tag and push:

```bash
git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z
```

Because the notes live in this file, Markdown headings work as-is — no
`--cleanup=verbatim` needed on the tag. Everything up to the next `## vX.Y.Z`
heading belongs to a version; use `##` for the subsections within it.

## v1.0.3 — show a SINR reading of 0 dB

## Fixes

- **SINR of exactly 0 dB was shown as `—`.** The signal meters treated any value of exactly 0 as "no reading", which is right for RSRP/RSRQ (never 0 for a live signal) but wrong for SINR, where 0 dB is a valid — if poor — reading. On a weak connection whose SINR sits at 0, the Overview signal card now shows `0 dB` instead of a blank.

## v1.0.2 — SSH robustness on Android, ARFCN in Cellular

## Fixes

- **SSH from cpe-box running on Android (KSWEB / AWebServer / Termux).** cpe-box spawns exactly one external process — `ssh` — and two of its options assumed a desktop layout:
  - the multiplexing control socket was hardcoded at `/tmp/cpebox_ssh_%C`. Where there is no `/tmp` (Android/KSWEB), the master never came up, so every router call opened its own connection and the router's dropbear closed the racing ones (`Error (255): Connection closed … port 22`). It now prefers `/tmp` and only falls back to `os.TempDir()` where `/tmp` isn't writable, and its name uses the router IP (`%h`) instead of a 40-char hash (`%C`) so the socket path stays under the ~104-char unix-domain-socket limit (which the long `/var/folders/.../T` `os.TempDir()` on macOS would otherwise blow past).
  - the key attempt now runs with `BatchMode=yes`, so a rejected key (or a stuck control socket) fails fast with 255 and retries with the password, instead of hanging on an interactive `root@host's password:` prompt until the deadline — which surfaced as `Timed out running …`.

  These only affect where cpe-box itself runs; everything router-side already ran over SSH on the router. `sshpass` (for the password fallback) and an OpenSSH-compatible `ssh` are still required in that environment.

## What's new

- **ARFCN / EARFCN on the Cellular page.** The serving cell's channel number now shows next to *LTE cell* (EARFCN) and *5G cell* (ARFCN). Read from `+QENG` on the AT path and from the `AT+QCAINFO` PCC line on the daemon path, so it works on both cb0401 v1 and v2.

## v1.0.1 — AT fallback for cb0401 v1

## What's new since v1.0

- **AT-command fallback for cb0401 v1 firmware.** Some cb0401 v1 units run firmware without the stock mobile-daemon API (`ubus call mobile device` / `dump_status`) the panel normally reads cellular status from. On those, the panel now falls back to talking to the RG520N modem directly over AT commands and reconstructs the same essentials — operator, network type (LTE / 5G NSA), primary + 5G bands, RSRP/RSRQ/RSSI/SNR, PCI, SIM status/number/ICCID and APN — so the Cellular page works the same on both firmware generations. Covered by a parser test against a real captured modem reply.
- **Standalone-5G (SA) on cb0401 v1.** The AT fallback now also handles a pure-SA connection: registration is read from 5GS registration (`AT+C5GREG?`), not just LTE `AT+CEREG?`, and serving-cell signal/PCI/band are parsed from the `NR5G-SA` `+QENG` line — so an SA-only v1 no longer reads as "not registered" / "no service". Verified against a real cb0401 v1 SA capture. The aggregated-band readout also ignores a bogus band 0 that some v1 firmware reports on a weak carrier, so the Carriers row shows the real band instead of `n0`.
- **App version in the panel header.** The running CPE Box version is shown next to the title (and stays on the System page), so it's easy to tell which build you're on.
- **Automatic RSA key fallback in setup.** If the router's dropbear is too old to accept the default ed25519 key, setup regenerates an RSA key and reinstalls it over the same password instead of failing with "key-based login still fails".

## Repository structure

- The host-side module directory `gui/` is renamed to **`panel/`** — it holds the whole web-panel app and its Go module (not just a frontend), mirroring the router-side `router/`. Module path `cpebox/gui` -> `cpebox/panel`; local secrets and build output now live under `panel/` (`panel/.env`, `panel/router_key`, ...). No behavior, `//go:embed` paths, launcher-script names, or the `GUI_BIND` env var changed — existing `.env` files keep working.

## v1.0 — CPE Box redesign

First release under the **CPE Box** name — the full redesign of the panel and setup flow.

> The repository was renamed from `cb0401-tune-control` to **`CPE-Box-cb0401`**. Old clone URLs still redirect; update your `origin` when convenient: `git remote set-url origin git@github.com:Kreal-exe/CPE-Box-cb0401.git`.

## What's new since v0.3.3

- **Modular web panel** — separate pages (Overview / Cellular / Wi‑Fi / Devices / Messages / Network / Router / Console) instead of one long scrolling page. Light and dark themes; the CPE Box logo takes you back to Overview.
- **LAN access with login** — panel binds to the LAN by default at `http://cpe.box` (port 80 when free, `:7777` otherwise); other devices sign in with the router's root password, localhost is trusted automatically. Sessions are bound to the current root password. SIM lock banner + PIN/PUK unlock form appear inline if the SIM asks for its PIN after a reboot.
- **AT command line to the modem** on the Console page — queries and writes straight to `/dev/ttyUSB2` (Quectel RG520N) with preset chips (`AT+QENG="servingcell"`, `AT+QNWPREFCFG=…`, `AT+CGSN`, `AT+CGMR`, `AT+CIMI`).
- **IMEI editor** on the Cellular page — reads the modem's current IMEI, writes a new one with `AT+EGMR=1,7,…` for carriers that gate SA to whitelisted device IDs. Behind a large "modifies modem, not reversible" warning.
- **160 MHz on 5 GHz** — setup unblocks the stock DFS channel ban, sets `htmode=HT160`, and turns on `preCACEn=1`. Radar-triggered channel moves swap to a pre-CAC'd backup instantly instead of the 60-second CAC. Re-applied every boot by `router/wifi_dfs_persist.sh`.
- **Real Data usage totals** — Today and This month come from the modem's own `mobile.flowstat.daily_usage` / `monthly_usage`, the only counters on this SoC that catch traffic the hardware flow-offload path would otherwise hide. Live rate pill + trafficd-ratio-based ↓/↑ split.
- **Device online/offline is real** — DHCP lease outlives association by hours, so "online" now comes from `ubus call trafficd hw` + `ip neigh show`. Header shows clickable `N online · M offline` chips that filter the list, sorted online-first.
- **Wi‑Fi form respects your saved choice** — if the driver narrows 160 MHz on ch 36 to 80 MHz on ch 40 because of DFS, the dropdowns still show what you set, with a note naming what's actually running.
- **Bands via the stock modem daemon** — bands are pushed through `ubus call mobile device`, so the modem persists them across reconnects and reboots.
- **SMS in the panel** — Messages page shows the SIM's inbox and threads; replying to a forwarded SMS on Telegram sends a real text back.
- **On-disk cache** for router polls — the panel polls the router once no matter how many people have it open.
- **CI + auto-release** — every `v*` tag builds cross-compiled binaries automatically.

## What got cleaner in the release itself

- **One binary per OS.** The router-side `sms-reader` (ARMv7) is now embedded inside every host `cpe-box` binary via `//go:embed`; `setup.sh` dumps it with `cpe-box --dump-sms-reader <path>` at install time. The release page no longer carries a separate `sms-reader-linux-armv7` file next to the actual apps.
- **`build.sh` lives at the repo root**, not `gui/build.sh` — one obvious place to build everything, the same script CI runs.
- **Smarter first-run URL.** `start.sh` opens `http://cpe.box` (no port) when cpe-box grabs port 80, falls through to `http://cpe.box:7777`, then `http://127.0.0.1:7777` — instead of always opening a loopback IP that refused the connection on the first tick.
- **Router sanity check after install.** `setup.sh` verifies `boot.sh`, `wifi_dfs_persist.sh`, the cron line and `notify.conf` actually landed under `/etc/crontabs/patches/` — the stock firmware's ramfs `/etc` used to swallow a mid-install error silently.
- **`start.sh` / `start.ps1` don't skip setup on a stale key.** Both now check that SSH works AND that `/etc/crontabs/patches/boot.sh` exists on the router.
- **`.env` auto-migration.** `start_gui.sh` / `.ps1` move an existing `GUI_BIND=…:5757` to `:7777` on first run (default port moved in v1.0).
- **Go version check** — old Go trips a clear error instead of "undefined: min".
- **`sshpass` install covers Fedora / Arch / openSUSE / Alpine** in addition to apt/brew.

## v0.3.3 — band fix via stock modem daemon (legacy)

Last release under the old *CB0401 Tune + Control* name, before the CPE Box redesign — single-page GUI and `cb0401-tune-control-*` binaries. Prefer v1.0+ unless you specifically need the old UI or asset names.

- Bands are applied through the router's own stock modem daemon (`ubus call mobile device`) instead of raw AT commands, so the modem persists them across reconnects and reboots.

## v0.3.2 — CA bands, LAN access, Wi‑Fi motion sensing

- **Aggregated CA bands, SIM/phone rows, SSH multiplexing** in the System card.
- **`GUI_BIND` for LAN access** plus live operator / network / bands in System.
- **Wi‑Fi CSI motion sensing ("Motion map")** — a dedicated Go app replacing the `sensing.sh` / RuView flow: Qualcomm CFR capture (`cfr-trigger`, capture daemon), Widar2.0-style CSI cleanup, Doppler-based presence and a particle-filter tracker, plus a floor-plan editor.
- **setup** keeps the real root password in `.env` and restores the SSH key after router reboots.

## v0.3.1 — data usage counters

- **Data usage counters** added to the System card.

## v0.3.0 — 5G mode selector

- **5G mode selector** (SA+NSA / Force SA / 5G off) replacing the old SA toggle, with the SA-vs-NSA distinction documented and option labels cleaned up.
- **Band-write reliability** — the hotplug hook no longer overrides the saved `NR5G_MODE` on every reconnect, and the unreliable band-mismatch verification (which raised false "Mismatch" errors when writing a band subset) was removed.

## v0.2.0 — CVE-2023-26319 SSH fallback; LTE band prefix fix

- **`bootstrap/open_ssh.sh` / `.ps1`: Path B — SmartController mac-field injection (CVE-2023-26319)**, the same mechanism xmir-patcher's `connect5.py` uses. Tried automatically when Telnet (port 23) is closed (firmware 3.0.100+): writes the SSH-enable + key-install script to `/tmp/e` in 2-char chunks via `scene_setting` / `scene_start_by_crontab` / `scene_delete`, then installs persistence over the now-open SSH connection. `WEB_PASSWORD` overrides the derived default for the web-UI login step.
- **LTE band chips** now use the `B` prefix (B3, B7, B20…) instead of `n`; 5G NR chips keep `n` (n1, n78…).
- Add an `appVersion` constant.
- README: rewrite "How SSH access is opened" to document both paths and the cron + firewall-hook persistence mechanism.

## v0.1.0 — initial release

First working version of the toolkit — autonomous setup plus a web GUI for the Xiaomi CB0401 / CB0401V2 5G CPE, driven entirely over SSH to the router.

- **One-command setup + web GUI** to open SSH, tune the modem and unlock bands; the stock firmware's telemetry/junk is cleaned up along the way.
- **Push notifications for new devices** — event-driven off the dnsmasq lease hook instead of polling, with a `trust` reply command to whitelist a device straight from the alert.
- **SMS in notifications** — incoming SMS forwarded to ntfy / Telegram, and replying in Telegram texts the sender back; delivery hardened (no silent loss, and one undeliverable message no longer blocks the queue).
- **Nameless-device identification** — MAC vendor (OUI) lookup plus a reverse mDNS query.
- **Instant reply handling** — a long-polling listener instead of a 2-minute cron poll.
