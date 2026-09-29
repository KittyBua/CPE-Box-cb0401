# GUI

The web dashboard for CPE Box. Written in Go and compiled to a single native
binary per OS — no runtime dependency at all for whoever runs it, only the Go
toolchain to build it, once.

Web assets live in [`web/`](web/) (plain HTML/CSS/JS, no build step, one file
per page) and are embedded into the binary at compile time.

It still shells out to the system `ssh` (and `sshpass` for the password
fallback) rather than reimplementing the SSH protocol — those are already
required elsewhere in this toolkit (opening SSH access in the first place
needs a real SSH client), so this doesn't add a new dependency, it just
means nothing here needs Python either.

## Building

Requires the [Go toolchain](https://go.dev/dl/) (1.21+) — only to build,
not to run the result:

```bash
../build.sh                # cross-compiles for macOS (arm64 + Intel), Linux (amd64 + arm64) and Windows into dist/ (run from the repo root)
# or, for just your own machine:
go build -o cpe-box .
```

## Running

```bash
./start_gui.sh       # macOS/Linux — downloads a prebuilt binary if Go isn't installed, otherwise builds; then launches
./start_gui.ps1      # Windows — same
```

`setup.sh`/`setup.ps1` normally do this for you, generating `router_key`/`router_key.pub` and `.env` (`ROUTER_IP`, `ROUTER_ROOT_PASSWORD`, `NOTIFY_BACKEND`, `NTFY_TOPIC`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `GUI_BIND`, and the login secrets) next to the binary — see the main [README](../README.md) for the full setup flow.
