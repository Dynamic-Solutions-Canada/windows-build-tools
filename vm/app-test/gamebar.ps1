<#
Helpers for testing an Xbox Game Bar widget in the guest's desktop session (dot-source after ui-lib.ps1).

Game Bar is invisible to UI Automation: its overlay has no top-level window the client can reach, and a
lookup by point lands on the desktop behind it. So a drive script works by sight: open Game Bar with the
Win+G chord, take a screenshot, click by screen position, screenshot again, and judge pass or fail from
the app's own logs (Wait-LogLine). The default positions are for the test VMs' 1280 x 800 screen with
Game Bar's default layout; take a screenshot first on a new guest or Windows version and pass the
positions it shows. Run only through run-interactive.ps1.
#>
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class GameBarInput {
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
    const uint KEYUP = 2, LEFTDOWN = 2, LEFTUP = 4;
    public static void Chord(byte modifier, byte key) {
        keybd_event(modifier, 0, 0, UIntPtr.Zero); keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, KEYUP, UIntPtr.Zero); keybd_event(modifier, 0, KEYUP, UIntPtr.Zero);
    }
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(200);
        mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero); mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }
}
'@

<# End Game Bar so it starts afresh: a widget installed while it ran appears only after a restart. #>
function Restart-GameBar {
    Get-Process GameBar, GameBarFTServer, XboxGameBarWidgets -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 2
}

<# Open (or close) Game Bar with Win+G, wait for it to draw, and save a shot named $Shot if given. #>
function Switch-GameBar([string]$Shot = '', [int]$WaitSeconds = 8) {
    [GameBarInput]::Chord(0x5B, 0x47)
    Start-Sleep $WaitSeconds
    "game bar processes: " + ((Get-Process GameBar, XboxGameBarWidgets -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')
    if ($Shot) { Save-Shot $Shot }
}

<# Click a screen position (physical pixels), wait, and save a shot named $Shot if given. #>
function Invoke-GameBarClick([int]$X, [int]$Y, [string]$Shot = '', [int]$WaitSeconds = 3) {
    [GameBarInput]::Click($X, $Y)
    Start-Sleep $WaitSeconds
    if ($Shot) { Save-Shot $Shot }
}

<# Open the Widget menu from Game Bar's toolbar (its second button). #>
function Open-WidgetMenu([int]$X = 473, [int]$Y = 55, [string]$Shot = 'gamebar-widget-menu') {
    Invoke-GameBarClick $X $Y $Shot
}

<#
Open a widget from the open Widget menu by its item's position. The menu lists Microsoft's favourites
first and then other widgets by name, so the position depends on the guest: read it from the menu's shot.
#>
function Open-GameBarWidget([int]$X, [int]$Y, [string]$Shot = 'gamebar-widget', [int]$WaitSeconds = 10) {
    Invoke-GameBarClick $X $Y $Shot $WaitSeconds
}

<#
Where a log stands now: the newest file matching $Path (wildcards allowed) and its line count, as
@{ Path; Count }, for Wait-LogLine's -Since. Path is $null when no file exists yet.
#>
function Get-LogPosition([string]$Path) {
    $file = Get-ChildItem $Path -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $file) { return [pscustomobject]@{ Path = $null; Count = 0 } }
    return [pscustomobject]@{ Path = $file.FullName; Count = @(Get-Content $file.FullName).Count }
}

<#
Wait until a log line matching $Pattern appears in the newest file matching $Path (wildcards allowed,
for example "$env:LOCALAPPDATA\Packages\<family>\LocalState\widget.log"). Returns the line, or $null
after $TimeoutSeconds. With -Since (from Get-LogPosition), only lines written after that position
count, so a test can't pass on an earlier run's line; if the log has since moved to a new file (a dated
or archived log), all of the new file counts.
#>
function Wait-LogLine([string]$Path, [string]$Pattern, [int]$TimeoutSeconds = 15, $Since = $null) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $file = Get-ChildItem $Path -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($file) {
            $skip = 0
            if ($Since -and $Since.Path -eq $file.FullName) { $skip = $Since.Count }
            $hit = Get-Content $file.FullName | Select-Object -Skip $skip | Select-String $Pattern | Select-Object -Last 1
            if ($hit) { return $hit.Line }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}
