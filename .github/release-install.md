## Getting the app

Same one command on every OS. No Go, no Python, no `pip`, no dependencies to hunt down — everything the script needs is already on a stock macOS / Linux / Windows 10 1809+ install (OpenSSH client + a shell). `cpe-box` itself is downloaded as a prebuilt binary from this release page.

**macOS / Linux**
```bash
git clone https://github.com/Kreal-exe/CPE-Box-cb0401
cd CPE-Box-cb0401
./start.sh
```

**Windows** (built-in PowerShell, run in the folder after `git clone`)
```powershell
powershell -ExecutionPolicy Bypass -File start.ps1
```

`start.sh` / `start.ps1` handles the executable bit and the macOS quarantine flag, opens SSH to the router, installs the router side, launches the panel and opens it in your browser — first at `http://cpe.box`, fall-throughs handled automatically.

## If you want the prebuilt binary standalone

The downloads below are plain executables with no extension.

**macOS**
```bash
curl -L -o cpe-box https://github.com/Kreal-exe/CPE-Box-cb0401/releases/download/__TAG__/cpe-box-macos-arm64
chmod +x cpe-box
xattr -d com.apple.quarantine cpe-box 2>/dev/null || true
./cpe-box
```

**Linux**
```bash
curl -L -o cpe-box https://github.com/Kreal-exe/CPE-Box-cb0401/releases/download/__TAG__/cpe-box-linux-amd64
chmod +x cpe-box
./cpe-box
```

**Windows** — download `cpe-box-windows-amd64.exe` and double-click, or run it from PowerShell.

The binary needs `panel/.env` (router IP, root password, notification token) next to it — `start.sh` / `start.ps1` generates that during setup, so a first-time user should go the git-clone path. Once `.env` exists you can copy the whole `panel/` folder anywhere. To extract the router-side sms-reader from any host cpe-box: `cpe-box --dump-sms-reader ./sms-reader`.

## Assets

- `cpe-box-macos-arm64` / `cpe-box-macos-intel` — macOS Apple Silicon / Intel
- `cpe-box-linux-amd64` / `cpe-box-linux-arm64` — Linux
- `cpe-box-windows-amd64.exe` — Windows
- `SHA256SUMS`

The router-side sms-reader is inside every host binary above; no separate file to grab.
