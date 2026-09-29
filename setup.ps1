#
# setup.ps1 — one-shot, fully self-contained setup for CPE Box +
# Control, for Windows. No Python, no third-party exploit tool - just
# PowerShell, the OpenSSH Client Windows feature, and (optionally) Go if
# you want to build the GUI from source instead of using a prebuilt binary.
#
# What this does, in order:
#   1. Checks prerequisites (ssh/scp — the OpenSSH Client Windows feature).
#   2. Opens persistent root SSH on the router (bootstrap/open_ssh.ps1) -
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
#   6. Builds (if needed) and launches the GUI at panel/.
#
# Safe to re-run: every step is idempotent.
#
# Usage: powershell -ExecutionPolicy Bypass -File setup.ps1
#
$ErrorActionPreference = 'Stop'

$RepoDir = $PSScriptRoot
$RouterIp = if ($env:ROUTER_IP) { $env:ROUTER_IP } else { '192.168.31.1' }
$KeyPath = Join-Path $RepoDir 'panel\router_key'
$EnvFile = Join-Path $RepoDir 'panel\.env'

$SshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'HostKeyAlgorithms=+ssh-rsa', '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa', '-o', 'ConnectTimeout=5')

function Say($msg) { Write-Host ''; Write-Host "==> $msg" }
function Die($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# Modern OpenSSH (9.0+, which recent Windows updates ship) defaults scp to
# an SFTP-based transfer, which needs /usr/libexec/sftp-server on the
# remote side - this router's dropbear does not have one. Only the legacy
# SCP protocol works against it (-O). Older OpenSSH clients (<9.0) don't
# recognize -O at all and use the legacy protocol anyway, so this tries -O
# first and falls back to plain scp if the local client rejects the flag.
function Copy-ToRouter {
    & scp -O @SshOpts -i $KeyPath @args 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    & scp @SshOpts -i $KeyPath @args
}

Say 'CPE Box setup'
Write-Host "Router IP:      $RouterIp"
Write-Host "GUI key path:   $KeyPath"

# --- 1. Prerequisites -------------------------------------------------------

Say 'Checking prerequisites'
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Die "ssh.exe was not found. On Windows 10/11, enable it with:`n  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`nthen re-run this script."
}
if (-not (Get-Command sshpass -ErrorAction SilentlyContinue)) {
    Write-Host "Note: 'sshpass' isn't available on Windows by default. The GUI only needs it to"
    Write-Host "self-heal automatically if it ever loses SSH key access (e.g. after a factory-reset-"
    Write-Host "like event on the router) - everything in this script works fine without it. If that"
    Write-Host "ever happens, just re-run this script to reinstall the key."
}

New-Item -ItemType Directory -Force -Path (Split-Path $KeyPath) | Out-Null
if (-not (Test-Path $KeyPath)) {
    ssh-keygen -t ed25519 -f $KeyPath -N '""' -C 'cpe-box-gui' -q
}

# --- 2. Open SSH on the router -----------------------------------------------

$keyWorks = $false
& ssh @SshOpts -i $KeyPath -o BatchMode=yes "root@$RouterIp" true 2>$null
$keyWorks = ($LASTEXITCODE -eq 0)

if ($keyWorks) {
    Say 'SSH already works via key - nothing to open.'
} else {
    Say 'Opening SSH access on the router'
    & powershell -ExecutionPolicy Bypass -File (Join-Path $RepoDir 'bootstrap\open_ssh.ps1') -RouterIp $RouterIp -PubKeyFile "$KeyPath.pub"
    if ($LASTEXITCODE -eq 0) {
        Say "SSH opened and this toolkit's key installed."
    } else {
        Write-Host "The automatic bootstrap didn't apply (e.g. Telnet is already closed, which is"
        Write-Host "normal if SSH is already enabled with the factory password some other way)."

        # --- 3. Fall back to a password-based key install ---------------------

        Say 'Falling back to installing the key over SSH with a password'
        $pubKey = (Get-Content "$KeyPath.pub" -Raw).Trim()
        $remoteCmd = "mkdir -p /etc/dropbear; grep -qF '$pubKey' /etc/dropbear/authorized_keys 2>/dev/null || echo '$pubKey' >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys"

        # If a previous run on this router already recorded a password (e.g.
        # changed through the GUI's own "Change root password" field), try
        # that first via sshpass (when available) - no need to retype it by
        # hand every time just because this checkout's key isn't installed
        # yet. sshpass isn't on Windows by default, so this is a no-op there
        # unless you've installed it yourself.
        $knownPassword = $null
        if (Test-Path $EnvFile) {
            $line = Get-Content $EnvFile | Where-Object { $_ -match '^ROUTER_ROOT_PASSWORD=' }
            if ($line) { $knownPassword = ($line -split '=', 2)[1] }
        }
        $installedWithKnownPassword = $false
        if ($knownPassword -and (Get-Command sshpass -ErrorAction SilentlyContinue)) {
            & sshpass -p $knownPassword ssh @SshOpts "root@$RouterIp" $remoteCmd 2>$null
            $installedWithKnownPassword = ($LASTEXITCODE -eq 0)
        }
        if ($installedWithKnownPassword) {
            Say 'Installed the key using the password already on file.'
        } else {
            Write-Host 'You will be asked for the router SSH password now - the derived default'
            Write-Host "described in the README's 'How SSH access is opened' section, or"
            Write-Host "whatever you've since changed it to."
            Write-Host ''
            & ssh @SshOpts "root@$RouterIp" $remoteCmd
            if ($LASTEXITCODE -ne 0) { Die "Could not reach the router over SSH with that password either. Check that it's reachable at $RouterIp." }
        }
    }
}

& ssh @SshOpts -i $KeyPath -o BatchMode=yes "root@$RouterIp" true
if ($LASTEXITCODE -ne 0) { Die 'Key-based login still fails after installing the key - check the router dropbear config.' }
Write-Host 'Key-based SSH login confirmed. No more passwords needed from here on.'

# --- 4. Notifications: ntfy.sh or Telegram, + device-monitor scripts -------

Say 'Setting up push notifications'
function Get-EnvValue($Name) {
    if (Test-Path $EnvFile) {
        $line = Get-Content $EnvFile | Where-Object { $_ -match "^$Name=" }
        if ($line) { return ($line -split '=', 2)[1] }
    }
    return $null
}

# Precedence: an explicit environment variable always wins (needed for a
# non-interactive re-run that switches backend); otherwise reuse whatever
# was chosen last time; otherwise ask, if we can; otherwise default to ntfy.
$notifyBackend = $env:NOTIFY_BACKEND
if ($notifyBackend) {
    Write-Host "Using notification backend from the NOTIFY_BACKEND environment variable: $notifyBackend"
} else {
    $notifyBackend = Get-EnvValue 'NOTIFY_BACKEND'
    if ($notifyBackend) {
        Write-Host "Reusing existing notification backend from ${EnvFile}: $notifyBackend"
    } elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host 'Choose how you want to receive device alerts and send block/red-alert commands:'
        Write-Host '  1) ntfy.sh  - zero setup: just a free app and a random shared topic (default)'
        Write-Host '  2) Telegram - needs a bot token + your chat ID, but ties access to your account'
        $choice = Read-Host 'Choice [1]'
        if ($choice -eq '2') { $notifyBackend = 'telegram' } else { $notifyBackend = 'ntfy' }
    }
}
if (-not $notifyBackend) { $notifyBackend = 'ntfy' }

$ntfyTopic = ''
$telegramBotToken = $env:TELEGRAM_BOT_TOKEN
$telegramChatId = $env:TELEGRAM_CHAT_ID

if ($notifyBackend -eq 'telegram') {
    if (-not $telegramBotToken) {
        $telegramBotToken = Get-EnvValue 'TELEGRAM_BOT_TOKEN'
        $telegramChatId = Get-EnvValue 'TELEGRAM_CHAT_ID'
        if ($telegramBotToken) { Write-Host "Reusing existing Telegram bot config from $EnvFile" }
    }
    if (-not $telegramBotToken -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host 'Create a bot with @BotFather on Telegram (free, one-time) to get a token,'
        Write-Host 'then send it any message so it can see your chat ID.'
        $telegramBotToken = Read-Host 'Telegram bot token'
        $telegramChatId = Read-Host 'Your Telegram chat ID'
    }
    if (-not $telegramBotToken -or -not $telegramChatId) {
        Die "Telegram backend selected but TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID aren't set (set them as environment variables for a non-interactive run)."
    }
    Write-Host 'Telegram bot configured.'
    Write-Host "(The bot token is a secret - anyone who has it can send messages as your bot"
    Write-Host " and read what's sent to it. It's stored only in $EnvFile, which is gitignored.)"
} else {
    $ntfyTopic = Get-EnvValue 'NTFY_TOPIC'
    if ($ntfyTopic) {
        Write-Host "Reusing existing topic from $EnvFile"
    } else {
        $bytes = New-Object byte[] 8
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $ntfyTopic = 'cpebox-' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    Write-Host "ntfy.sh topic: $ntfyTopic"
    Write-Host '(This is a shared secret - anyone who knows it can read your device alerts'
    Write-Host ' and send block/red-alert commands. Keep it private; it is never committed to git.)'
}

$tmpDir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmpDir | Out-Null

# Written with [System.IO.File]::WriteAllText (not Get-Content | Set-Content)
# and forced to LF-only line endings: these run through BusyBox ash on the
# router, which breaks on a stray "\r" (e.g. at the end of the shebang
# line). Get-Content/Set-Content would silently rejoin the file using
# Windows' CRLF here, and a plain file copy could carry CRLF too if the
# repo was ever checked out with core.autocrlf=true.
function Write-UnixScript($SourcePath, $DestPath, $Substitute) {
    $content = [System.IO.File]::ReadAllText($SourcePath) -replace "`r`n", "`n"
    if ($Substitute) {
        foreach ($key in $Substitute.Keys) {
            $content = $content -replace [regex]::Escape($key), $Substitute[$key]
        }
    }
    [System.IO.File]::WriteAllText($DestPath, $content)
}

$notifyConf = "NOTIFY_BACKEND=$notifyBackend`nNTFY_TOPIC=$ntfyTopic`nTELEGRAM_BOT_TOKEN=$telegramBotToken`nTELEGRAM_CHAT_ID=$telegramChatId`n"
[System.IO.File]::WriteAllText((Join-Path $tmpDir 'notify.conf'), $notifyConf)
foreach ($f in @('install.sh', 'cleanup.sh', 'notify_common.sh', 'device_monitor.sh', 'dhcp_notify.sh',
                 'command_watcher.sh', 'sms_notify.sh', 'json_unescape.lua', 'boot.sh', 'sms_msg_hook.lua')) {
    Write-UnixScript (Join-Path $RepoDir "router\$f") (Join-Path $tmpDir $f) $null
}

# sms-reader is the ARMv7 SQLite reader that runs ON the router. It ships
# embedded inside every prebuilt cpe-box binary (see panel/embed_smsreader.go),
# so Ensure-GuiBin makes it available; Fetch-SmsReader dumps it out. If Go
# is installed it cross-builds a fresh one instead.
. (Join-Path $RepoDir 'panel\fetch.ps1')
if (-not (Ensure-GuiBin)) { throw "couldn't build or download CPE Box" }
$smsReaderBin = Fetch-SmsReader $tmpDir
if (-not $smsReaderBin) {
    Write-Host "NOTE: couldn't extract or build sms-reader (needs Go, or an already-fetched"
    Write-Host '      cpe-box binary). Skipping SMS forwarding; everything else is unaffected.'
}

& ssh @SshOpts -i $KeyPath "root@$RouterIp" 'rm -rf /tmp/cpebox && mkdir -p /tmp/cpebox'
$filesToCopy = @(Get-ChildItem -File $tmpDir | ForEach-Object { $_.FullName })
Copy-ToRouter @filesToCopy "root@${RouterIp}:/tmp/cpebox/" | Out-Null
$scpExit = $LASTEXITCODE
Remove-Item -Recurse -Force $tmpDir
if ($scpExit -ne 0) { Die 'Could not copy the router scripts over SSH (scp failed).' }

# --- 5. Router install + cleanup ---------------------------------------------
# router/install.sh is the one place everything done ON the router lives
# (shared with setup.sh). It also runs cleanup.sh: telemetry, dead cron jobs
# and the cloud/Mesh/TR-069/Mi Home services are switched off by default;
# CLEANUP_FLAGS keeps a group you use (--keep-cloud / --keep-mesh /
# --keep-tr069 / --keep-miot - see router/cleanup.sh).
Say 'Installing on the router and cleaning it up'
$cleanupFlags = $env:CLEANUP_FLAGS
& ssh @SshOpts -i $KeyPath "root@$RouterIp" "sh /tmp/cpebox/install.sh $cleanupFlags"
if ($LASTEXITCODE -ne 0) { Die 'The router-side install failed.' }
if (-not $cleanupFlags) {
    Write-Host "(Using the Mi WiFi/Mi Home app, Mesh satellites or carrier remote management? Re-run with e.g. `$env:CLEANUP_FLAGS='--keep-mesh'.)"
}

# --- 6. GUI --------------------------------------------------------------

Say 'Setting up the local GUI'
Set-Location $RepoDir

# Keep the root password .env already had (the GUI's Change root password
# writes it there) - this used to be hard-coded to "root", silently wiping
# the real one on every setup run.
$keepPassword = 'root'
if (Test-Path $EnvFile) {
    $pwLine = Get-Content $EnvFile | Where-Object { $_ -match '^ROUTER_ROOT_PASSWORD=' }
    if ($pwLine) { $keepPassword = ($pwLine -split '=', 2)[1] }
}
# Same for an opt-in LAN bind (see README) - don't silently drop it.
$keepGuiBind = ''
if (Test-Path $EnvFile) {
    $bindLine = Get-Content $EnvFile | Where-Object { $_ -match '^GUI_BIND=' }
    if ($bindLine) { $keepGuiBind = ($bindLine -split '=', 2)[1] }
}
# Anything else in .env (the panel's session key, GUI_HOSTNAME, ...) is kept.
$keepOther = @()
if (Test-Path $EnvFile) {
    $keepOther = @(Get-Content $EnvFile | Where-Object { $_ -and $_ -notmatch '^(ROUTER_IP|ROUTER_ROOT_PASSWORD|NOTIFY_BACKEND|NTFY_TOPIC|TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID|GUI_BIND)=' })
}
@"
ROUTER_IP=$RouterIp
ROUTER_ROOT_PASSWORD=$keepPassword
NOTIFY_BACKEND=$notifyBackend
NTFY_TOPIC=$ntfyTopic
TELEGRAM_BOT_TOKEN=$telegramBotToken
TELEGRAM_CHAT_ID=$telegramChatId
"@ | Set-Content -Path $EnvFile -Encoding ascii
# Reachable from every device on the LAN by default (they log in with the
# router root password); set GUI_BIND=127.0.0.1:7777 to keep it local.
if (-not $keepGuiBind) { $keepGuiBind = '0.0.0.0:7777' }
Add-Content -Path $EnvFile -Value "GUI_BIND=$keepGuiBind" -Encoding ascii
if ($keepOther.Count) { Add-Content -Path $EnvFile -Value $keepOther -Encoding ascii }

Say 'Unlocking modem bands and installing the 5G mode hook'
$guiBin = Join-Path $RepoDir 'panel\cpe-box.exe'
& $guiBin --provision
if ($LASTEXITCODE -ne 0) { throw 'band unlock / 5G mode hook setup failed' }

Say 'Setup complete. Starting the GUI...'
& (Join-Path $RepoDir 'panel\start_gui.ps1')
