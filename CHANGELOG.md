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

## v1.0.1 — AT fallback for cb0401 v1

## What's new since v1.0

- **AT-command fallback for cb0401 v1 firmware.** Some cb0401 v1 units run firmware without the stock mobile-daemon API (`ubus call mobile device` / `dump_status`) the panel normally reads cellular status from. On those, the panel now falls back to talking to the RG520N modem directly over AT commands and reconstructs the same essentials — operator, network type (LTE / 5G NSA), primary + 5G bands, RSRP/RSRQ/RSSI/SNR, PCI, SIM status/number/ICCID and APN — so the Cellular page works the same on both firmware generations. Covered by a parser test against a real captured modem reply.

## Repository structure

- The host-side module directory `gui/` is renamed to **`panel/`** — it holds the whole web-panel app and its Go module (not just a frontend), mirroring the router-side `router/`. Module path `cpebox/gui` -> `cpebox/panel`; local secrets and build output now live under `panel/` (`panel/.env`, `panel/router_key`, ...). No behavior, `//go:embed` paths, launcher-script names, or the `GUI_BIND` env var changed — existing `.env` files keep working.

## v1.0 — CPE Box redesign

First release under the **CPE Box** name — the full redesign of the panel and
setup flow: modular web panel (separate pages, light/dark themes), LAN access
with login at `http://cpe.box`, AT command line and IMEI editor, 160 MHz on
5 GHz with DFS pre-CAC, real data-usage totals and online/offline detection,
SMS in the panel, and CI + auto-release of cross-compiled binaries. Full notes:
<https://github.com/Kreal-exe/CPE-Box-cb0401/releases/tag/v1.0>.
