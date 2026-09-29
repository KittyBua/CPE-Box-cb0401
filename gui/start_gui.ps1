#
# Builds (if needed) and starts the router admin GUI, then opens it in the
# browser (Windows). No Python, no venv, no pip - just a Go binary.
#
# Usage: powershell -ExecutionPolicy Bypass -File start_gui.ps1
#
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Bin = Join-Path $PSScriptRoot 'cpe-box.exe'
$Port = 7777
$PidFile = Join-Path $env:TEMP 'cpe_box_gui.pid'
$LogFile = Join-Path $env:TEMP 'cpe_box_gui.log'

. (Join-Path $PSScriptRoot 'fetch.ps1')
if (-not (Ensure-GuiBin)) { exit 1 }

# Open to every device on the LAN by default (they log in with the router
# root password); GUI_BIND=127.0.0.1:7777 in .env keeps it on this machine.
# Also migrate an older 5757 pin - the default port moved to 7777 in v1.0,
# but existing .env files from earlier setups still say 5757.
$EnvFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $EnvFile) -or -not (Select-String -Path $EnvFile -Pattern '^GUI_BIND=' -Quiet)) {
    Add-Content -Path $EnvFile -Value 'GUI_BIND=0.0.0.0:7777' -Encoding ascii
} elseif (Test-Path $EnvFile) {
    (Get-Content $EnvFile) | ForEach-Object { $_ -replace '^(GUI_BIND=[^:]+):5757$', '$1:7777' } | Set-Content $EnvFile
}

# Stop a stale instance from a previous run, if any, so we don't end up
# talking to old code or hit a port conflict.
if (Test-Path $PidFile) {
    $oldPid = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "Stopping previous instance (PID $oldPid)..."
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }
}
$existing = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
    Write-Host "Port $Port is in use (PID $($existing.OwningProcess)) - freeing it..."
    Stop-Process -Id $existing.OwningProcess -Force -ErrorAction SilentlyContinue
}

Write-Host "Starting the GUI on http://127.0.0.1:$Port ..."
$proc = Start-Process -FilePath $Bin -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err"
$proc.Id | Out-File -FilePath $PidFile -Encoding ascii

# 127.0.0.1:$Port is our readiness probe. Preferred URL is
# http://cpe.box with no port - cpe-box also binds port 80 for LAN
# convenience, so if that grabbed we open the friendly name. Otherwise
# fall through to :$Port on cpe.box, and finally to loopback if the
# router hasn't registered .box in DNS yet (first-run setup).
for ($i = 0; $i -lt 20; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 1
        if ($resp.StatusCode -eq 200) { break }
    } catch {}
    Start-Sleep -Milliseconds 300
}

# http://cpe.box, always. cpe-box registers the .box name in the router's
# DNS on startup and grabs port 80 for the LAN when it can, so the friendly
# URL is what the user should see - no port suffix, no loopback IP.
$Url = 'http://cpe.box'
Write-Host "Opening $Url"
Start-Process $Url

# Stay attached to the GUI process instead of returning to the prompt right
# away - closing this window or hitting Ctrl+C stops the GUI too, rather
# than leaving it running invisibly in the background.
Get-Content $LogFile -ErrorAction SilentlyContinue | Select-Object -Skip 1 -First 5 | ForEach-Object { Write-Host $_ }
Write-Host "GUI is running (PID $($proc.Id)), logs: $LogFile / $LogFile.err"
Write-Host "Press Ctrl+C to stop it."
try {
    Wait-Process -Id $proc.Id
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
