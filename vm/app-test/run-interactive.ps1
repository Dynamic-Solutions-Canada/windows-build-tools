<#
.SYNOPSIS
Run a PowerShell script inside the guest's signed-in desktop session and wait for it.

.DESCRIPTION
SSH sessions run outside the desktop, so UI Automation, screenshots and theme changes made there do
not reach what is on screen. This registers a one-off scheduled task for the signed-in user with an
interactive logon, runs it, waits for it to finish (or for -TimeoutSeconds), prints its transcript and
removes the task. The guest must have a user signed in (the dockurr image signs in automatically).

.PARAMETER Script  Path in the guest of the script to run. It takes no arguments: quoting through SSH,
                   cmd and a scheduled task is fragile, so write any inputs into the script itself.
#>
param(
    [Parameter(Mandatory)] [string]$Script,
    [int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$name = "apptest-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$log = "C:\apptest\out\$name.log"
New-Item -ItemType Directory -Force C:\apptest\out | Out-Null

# The task's own command line: run the script with a transcript, so its output can be printed here.
$command = "Start-Transcript -Path '$log' | Out-Null; try { & '$Script' } catch { Write-Output ('ERROR: ' + `$_) }; Stop-Transcript | Out-Null"
# Through a headless console host: Windows 11 hands a plain console program to Windows Terminal,
# which ignores -WindowStyle Hidden and leaves a terminal button on the taskbar of every capture.
$action = New-ScheduledTaskAction -Execute "conhost.exe" -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$command`""
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal | Out-Null

try {
    Start-ScheduledTask -TaskName $name
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $state = (Get-ScheduledTask -TaskName $name).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    if ($state -eq 'Running') {
        Stop-ScheduledTask -TaskName $name
        Write-Output "TIMEOUT after $TimeoutSeconds s"
    }
}
finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}

if (Test-Path $log) {
    # Drop the transcript's header and footer blocks.
    Get-Content $log | Where-Object { $_ -notmatch '^PS>TerminatingError' -and $_ -notmatch '^\*{10,}|^(Windows PowerShell transcript|Start time|End time|Username|RunAs User|Configuration Name|Machine|Host Application|Process ID|PSVersion|PSEdition|PSCompatibleVersions|BuildVersion|CLRVersion|WSManStackVersion|PSRemotingProtocolVersion|SerializationVersion|Transcript started)' }
}
else {
    Write-Output "No transcript: the task did not start in the desktop session (is a user signed in?)"
}
