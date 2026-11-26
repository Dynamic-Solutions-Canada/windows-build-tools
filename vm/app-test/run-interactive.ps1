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

<#
The script's own output from a transcript: the lines between the begin and end markers the task
writes, so the transcript's header and footer drop out in any display language (their labels, such
as "Start time", are translated: "Startzeit" in German). PowerShell's "PS>TerminatingError" echo lines
are dropped too. A transcript cut off before the end marker (a timeout) gives everything after the
begin marker; one with no begin marker gives nothing.
#>
function Select-TranscriptOutput([string[]]$Lines, [string]$Begin, [string]$End) {
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -eq $Begin) { $inside = $true; continue }
        if ($line -eq $End) { return }
        if ($inside -and $line -notmatch '^PS>TerminatingError') { $line }
    }
}

$name = "apptest-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
$log = "C:\apptest\out\$name.log"
New-Item -ItemType Directory -Force C:\apptest\out | Out-Null

# The task's own command line: run the script with a transcript, so its output can be printed here,
# between two markers that set it apart from the transcript's own header and footer.
$begin = "apptest-output-begin-$name"
$end = "apptest-output-end-$name"
$command = "Start-Transcript -Path '$log' | Out-Null; Write-Output '$begin'; try { & '$Script' } catch { Write-Output ('ERROR: ' + `$_) }; Write-Output '$end'; Stop-Transcript | Out-Null"
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
    Select-TranscriptOutput (Get-Content $log) $begin $end
}
else {
    Write-Output "No transcript: the task did not start in the desktop session (is a user signed in?)"
}
