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
$KeyPath = Join-Path $PSScriptRoot 'panel\router_key'
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

# Keep the router-side scripts in step with this checkout (mirror of
# start.sh): setup.ps1 only uploads them once, so a fix to e.g.
# command_watcher.sh would otherwise never reach a router that's already
# set up. Compares md5s, re-uploads only what changed. Best-effort.
function Sync-RouterScripts {
    $d = '/etc/crontabs/patches'
    $files = 'notify_common.sh', 'device_monitor.sh', 'dhcp_notify.sh', 'command_watcher.sh', 'sms_notify.sh', 'json_unescape.lua', 'boot.sh', 'sms_msg_hook.lua', 'wifi_dfs_persist.sh'
    try {
        $remote = & ssh @SshOpts -i $KeyPath "root@$RouterIp" "cd $d 2>/dev/null && md5sum $($files -join ' ') 2>/dev/null" 2>$null
        if ($LASTEXITCODE -ne 0 -and -not $remote) { return }
        $changed = @()
        foreach ($f in $files) {
            $local = Join-Path $PSScriptRoot "router\$f"
            if (-not (Test-Path $local)) { continue }
            $h = (Get-FileHash -Algorithm MD5 $local).Hash.ToLower()
            if (-not ($remote | Where-Object { $_ -match "^$h\s+$([regex]::Escape($f))$" })) { $changed += $f }
        }
        if (-not $changed) { return }
        Write-Host "Updating router scripts: $($changed -join ' ')"
        foreach ($f in $changed) {
            $local = Join-Path $PSScriptRoot "router\$f"
            & scp -O @SshOpts -i $KeyPath $local "root@${RouterIp}:$d/$f.new" 2>$null
            if ($LASTEXITCODE -ne 0) { & scp @SshOpts -i $KeyPath $local "root@${RouterIp}:$d/$f.new" 2>$null }
            if ($LASTEXITCODE -eq 0) { & ssh @SshOpts -i $KeyPath "root@$RouterIp" "mv $d/$f.new $d/$f && chmod +x $d/$f" 2>$null }
        }
        if ($changed -contains 'command_watcher.sh') {
            & ssh @SshOpts -i $KeyPath "root@$RouterIp" "sh $d/command_watcher.sh --restart" 2>$null | Out-Null
        }
    } catch { }
}

if ($keyOK) {
    Sync-RouterScripts
    & (Join-Path $PSScriptRoot 'panel\start_gui.ps1')
} else {
    & (Join-Path $PSScriptRoot 'setup.ps1')
}
