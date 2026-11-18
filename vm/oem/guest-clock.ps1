<#
.SYNOPSIS
Keep the guest clock right: Toronto time zone, and a time resync at every boot.

.DESCRIPTION
The dockurr/windows image starts QEMU with "-rtc base=localtime", so the guest's hardware clock
holds the container's local time, and Windows reads it as local time in the guest's own time zone.
The compose files set the container to TZ=America/Toronto; this script sets the guest to the
matching "Eastern Standard Time" zone. If the two disagree, the guest boots hours off (a UTC
container with the image's default Pacific guest booted 8 hours ahead).

It also registers the "Clock resync" scheduled task, which runs this script with -Resync as SYSTEM
at startup. That corrects whatever the hardware clock got wrong, including a clock Windows wrote
back before a guest restart, instead of waiting for the weekly Windows Time poll.

Run it elevated over SSH (setup), or let oem\install.bat run it on a fresh install. Safe to re-run.

.PARAMETER Resync Only resync the clock, retrying while the network comes up, and log the result to
C:\OEM\clock-resync.log. This is what the startup task runs.
#>
param(
    [switch]$Resync
)
$ErrorActionPreference = 'Stop'

$TimeZone = 'Eastern Standard Time'
$TaskName = 'Clock resync'
$ScriptPath = 'C:\OEM\guest-clock.ps1'
$LogPath = 'C:\OEM\clock-resync.log'

<#
Start Windows Time and ask it to resync, retrying while the network comes up at boot.
Progress goes to the host stream (the startup task's transcript keeps it). Returns $true once
w32tm reports success, $false after the last attempt.
#>
function Invoke-ClockResync([int]$Attempts = 12, [int]$DelaySeconds = 10) {
    # On a workgroup machine Windows Time is trigger-started, so it may not be running yet.
    Start-Service W32Time

    # Windows PowerShell turns a native command's stderr into errors, which Stop would throw.
    $ErrorActionPreference = 'Continue'
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $output = & w32tm.exe /resync /rediscover 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "resynced on attempt ${attempt}"
            return $true
        }
        Write-Host "attempt ${attempt} failed: $output"
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}

<# Register (or replace) the startup task that runs this script with -Resync as SYSTEM. #>
function Register-ResyncTask {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Resync"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Output "task: '$TaskName' runs $ScriptPath -Resync at startup"
}

# ── Startup task: resync only, keeping the last boot's result for diagnosis ──
if ($Resync) {
    Start-Transcript $LogPath | Out-Null
    try {
        Invoke-ClockResync | Out-Null
        Write-Host "guest time: $(Get-Date -Format o)"
    }
    finally {
        Stop-Transcript | Out-Null
    }
    return
}

# ── Setup: time zone, startup task, then correct the clock now ──
if ((Get-TimeZone).Id -ne $TimeZone) {
    Set-TimeZone -Id $TimeZone
}
Write-Output "time zone: $((Get-TimeZone).Id)"

if ($PSCommandPath -ne $ScriptPath) {
    Copy-Item $PSCommandPath $ScriptPath -Force
}
Register-ResyncTask

if (-not (Invoke-ClockResync)) {
    throw 'Windows Time could not resync; check the guest network'
}
Write-Output "guest time: $(Get-Date -Format 'yyyy-MM-dd h:mm tt') $((Get-TimeZone).StandardName)"
