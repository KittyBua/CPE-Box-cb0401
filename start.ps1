#
# start.ps1 — the one command to run, on Windows, whether this is the very
# first run or the hundredth.
#
# Does a quick check for whether setup has already been done (does the SSH
# key exist and actually work against the router right now?):
#   - Not set up yet -> runs the full setup.ps1 (opens SSH, configures
#     notifications, cleans up telemetry, then launches the GUI).
#   - Already set up -> skips straight to launching the GUI, without
#     redoing the SSH/notification/cleanup steps every time.
#
# Usage: powershell -ExecutionPolicy Bypass -File start.ps1
#
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$RouterIp = if ($env:ROUTER_IP) { $env:ROUTER_IP } else { '192.168.31.1' }
$KeyPath = Join-Path $PSScriptRoot 'gui\router_key'
$SshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'HostKeyAlgorithms=+ssh-rsa', '-o', 'PubkeyAcceptedAlgorithms=+ssh-rsa', '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes')

# Setup is considered done when BOTH the SSH key still works AND cpe-box's
# own boot marker lives on the router (mirror of start.sh's behaviour): a
# naked working key isn't enough - the router's tmpfs /etc gets wiped on
# factory reset, dropping every patch while the key survives in the local
# repo. Without this second check start.ps1 would happily skip to
# start_gui.ps1 and the panel would run half-broken.
$keyOK = $false
if (Test-Path $KeyPath) {
    & ssh @SshOpts -i $KeyPath "root@$RouterIp" '[ -f /etc/crontabs/patches/boot.sh ]' 2>$null
    $keyOK = ($LASTEXITCODE -eq 0)
}

if ($keyOK) {
    & (Join-Path $PSScriptRoot 'gui\start_gui.ps1')
} else {
    & (Join-Path $PSScriptRoot 'setup.ps1')
}
