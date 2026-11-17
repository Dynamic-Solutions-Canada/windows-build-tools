<#
.SYNOPSIS
Prepare a test guest's desktop for screenshots, and put it back afterwards.

.DESCRIPTION
-Mode Prepare saves the current settings to C:\apptest\desktop, then sets the screenshot desktop:
the wallpaper (Windows 11's dark bloom, img19.jpg, by default), desktop icons hidden, the taskbar
search box and Widgets off, every pin that Windows lets a script remove taken off the taskbar, dark
mode for Windows and apps, and transparency effects on. Running it again keeps the settings saved the first time,
so a second Prepare never makes the screenshot desktop the one Restore returns to.

-Mode Restore puts every saved setting back, including the taskbar pins, and deletes the saved copy.
It also works from a later session or after a failed capture, since everything it needs is in the
saved copy; app_test_clean runs it before removing C:\apptest.

Run it in the desktop session (app_test_run): wallpaper, theme and Explorer changes made over SSH do
not reach the screen. It restarts Explorer once, to apply the search box, Widgets and pin changes,
and hides the desktop icons with the desktop's own command. Widgets are turned off with the "Allow
widgets" policy, because Windows 11 refuses writes to the per-user TaskbarDa setting (tried: "Attempted
to perform an unauthorized operation"). File Explorer's taskbar pin has no unpin command a script
can call, so it stays.

Rounded corners, shadows and Mica also need app_test_effects on windows-dev; this script reports
whether that is set but does not change it, because it needs a restart.

.PARAMETER Mode Prepare or Restore.
.PARAMETER Wallpaper File name in C:\Windows\Web\Wallpaper\Windows. Windows 10 has no img19.jpg;
pass img0.jpg there.
.PARAMETER State Folder for the saved settings; tests point it elsewhere.
#>
param(
    [Parameter(Mandatory)] [ValidateSet('Prepare', 'Restore')] [string]$Mode,
    [string]$Wallpaper = 'img19.jpg',
    [string]$State = 'C:\apptest\desktop'
)
$ErrorActionPreference = 'Stop'

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class DesktopNative {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool SystemParametersInfo(int action, int param, string value, int winIni);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, int msg, IntPtr wParam, string lParam, int flags, int timeout, out IntPtr result);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindow(string className, string windowName);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wParam, IntPtr lParam);
}
"@

# Registry values the screenshot desktop sets, with the value each takes while prepared.
$Settings = @(
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Value = 0 }
    # Windows itself (taskbar, Start, flyouts) dark too, so tray shots match the dark app.
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Value = 0 }
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Value = 1 }
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Value = 0 }
    # The documented "Allow widgets" policy; the per-user TaskbarDa value is write-protected (UCPD).
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = 0 }
)
$TaskbandKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
$PinnedFolder = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
$StateFile = Join-Path $State 'state.json'

<# Read a registry value, or $null when it does not exist. #>
function Get-RegistryValue([string]$Key, [string]$Name) {
    $item = Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue
    if ($item) { return $item.$Name }
    return $null
}

<# Set a registry value, or delete it when $Value is $null (it did not exist before Prepare). #>
function Set-RegistryValue([string]$Key, [string]$Name, $Value) {
    if ($null -eq $Value) {
        Remove-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }
    $type = if ($Value -is [string]) { 'String' } else { 'DWord' }
    New-ItemProperty -Path $Key -Name $Name -Value $Value -PropertyType $type -Force | Out-Null
}

<#
Run reg.exe and throw if it fails, unless -AllowFailure. reg.exe prints its success message on
stderr, which Windows PowerShell 5.1 turns into a terminating error under ErrorActionPreference Stop,
so its output is merged and the exit code decides instead.
#>
function Invoke-Reg([string[]]$Arguments, [switch]$AllowFailure) {
    $ErrorActionPreference = 'Continue'
    $output = & reg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "reg.exe $($Arguments -join ' ') failed: $output"
    }
}

<# Set the desktop wallpaper for the session and persist it (SPI_SETDESKWALLPAPER, update and broadcast). #>
function Set-Wallpaper([string]$Path) {
    [DesktopNative]::SystemParametersInfo(0x14, 0, $Path, 3) | Out-Null
}

<# Tell running apps the theme changed, so open windows switch to dark or light without a restart. #>
function Send-ThemeChange {
    $result = [IntPtr]::Zero
    [DesktopNative]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 5000, [ref]$result) | Out-Null
}

<# Restart Explorer so it rereads the taskbar and desktop settings, and wait until its taskbar is back. #>
function Restart-Explorer {
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    # Windows restarts the shell by itself; start it only if it has not.
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    $deadline = (Get-Date).AddSeconds(60)
    while ([DesktopNative]::FindWindow('Shell_TrayWnd', [NullString]::Value) -eq [IntPtr]::Zero) {
        if ((Get-Date) -gt $deadline) { throw 'Explorer did not bring the taskbar back within 60 seconds' }
        Start-Sleep -Milliseconds 500
    }
    # The taskbar window appears before its buttons and the desktop are drawn.
    Start-Sleep -Seconds 5
}

<#
The desktop's view window (SHELLDLL_DefView), under Progman or, after wallpaper changes on some
builds, under a WorkerW window.
#>
function Get-DesktopView {
    # [NullString]::Value, not $null: PowerShell passes $null to a string parameter as "", which
    # FindWindow takes as "a window with an empty title".
    $view = [DesktopNative]::FindWindowEx([DesktopNative]::FindWindow('Progman', [NullString]::Value), [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
    $worker = [IntPtr]::Zero
    while ($view -eq [IntPtr]::Zero) {
        $worker = [DesktopNative]::FindWindowEx([IntPtr]::Zero, $worker, 'WorkerW', [NullString]::Value)
        if ($worker -eq [IntPtr]::Zero) { throw 'Could not find the desktop window' }
        $view = [DesktopNative]::FindWindowEx($worker, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
    }
    $view
}

<# Whether the desktop icons are showing. #>
function Test-DesktopIcons {
    $icons = [DesktopNative]::FindWindowEx((Get-DesktopView), [IntPtr]::Zero, 'SysListView32', [NullString]::Value)
    [DesktopNative]::IsWindowVisible($icons)
}

<#
Show or hide the desktop icons. Sends the desktop's own "Show desktop icons" command (0x7402, a
toggle), which Explorer persists in its folder view flags. Writing the HideIcons registry value does
not work: Explorer rewrites it from those flags when it starts.
#>
function Set-DesktopIcons([bool]$Visible) {
    if ((Test-DesktopIcons) -ne $Visible) {
        [DesktopNative]::SendMessage((Get-DesktopView), 0x111, [IntPtr]0x7402, [IntPtr]::Zero) | Out-Null   # WM_COMMAND
        Start-Sleep -Seconds 1
    }
}

<# Unpin every app whose shell item offers "Unpin from taskbar", and return their names. #>
function Remove-TaskbarPins {
    $apps = (New-Object -ComObject Shell.Application).NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}').Items()
    foreach ($app in $apps) {
        $verb = $app.Verbs() | Where-Object { $_.Name.Replace('&', '') -eq 'Unpin from taskbar' } | Select-Object -First 1
        if ($verb) {
            $verb.DoIt()
            $app.Name
        }
    }
}

<# Report whether DWM effects (rounded corners, shadows, Mica) are forced on, as app_test_effects sets. #>
function Write-EffectsStatus {
    $build = [int](Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild')
    if ($build -lt 22000) { return }
    if ((Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'ForceEffectMode') -eq 2) {
        Write-Output 'effects: on'
    }
    else {
        Write-Output 'effects: off (square corners, no Mica); run app_test_effects on the host first'
    }
}

<# Save the current settings, unless an earlier Prepare already did. #>
function Save-DesktopState {
    if (Test-Path $StateFile) {
        Write-Output "already prepared; keeping the settings saved at $((Get-Item $StateFile).LastWriteTime)"
        return
    }
    New-Item -ItemType Directory -Force $State | Out-Null
    $saved = @{
        Wallpaper = Get-RegistryValue 'HKCU:\Control Panel\Desktop' 'WallPaper'
        DesktopIcons = Test-DesktopIcons
        Values = @($Settings | ForEach-Object { @{ Key = $_.Key; Name = $_.Name; Value = Get-RegistryValue $_.Key $_.Name } })
    }
    # The pin list lives in the Taskband key and the pinned shortcuts folder; keep both.
    Invoke-Reg 'export', $TaskbandKey, (Join-Path $State 'taskband.reg'), '/y'
    if (Test-Path $PinnedFolder) { Copy-Item $PinnedFolder (Join-Path $State 'pins') -Recurse -Force }
    $saved | ConvertTo-Json -Depth 4 | Set-Content $StateFile -Encoding UTF8
    Write-Output "saved the current desktop settings in $State"
}

<# Apply the screenshot desktop. #>
function Invoke-Prepare {
    $wallpaperPath = Join-Path 'C:\Windows\Web\Wallpaper\Windows' $Wallpaper
    if (-not (Test-Path $wallpaperPath)) {
        throw "$wallpaperPath does not exist in this guest (Windows 10 has only img0.jpg); pass -Wallpaper"
    }
    Save-DesktopState

    foreach ($setting in $Settings) {
        Set-RegistryValue $setting.Key $setting.Name $setting.Value
    }
    $unpinned = @(Remove-TaskbarPins)
    Restart-Explorer
    Set-DesktopIcons $false
    Set-Wallpaper $wallpaperPath
    Send-ThemeChange

    Write-Output "prepared: wallpaper $Wallpaper, dark mode for Windows and apps, transparency on, desktop icons, search box and Widgets hidden"
    if ($unpinned) { Write-Output "unpinned: $($unpinned -join ', ')" }
    Write-EffectsStatus
}

<# Put back everything Save-DesktopState saved, then delete the saved copy. #>
function Invoke-Restore {
    if (-not (Test-Path $StateFile)) {
        Write-Output 'nothing to restore: the desktop was not prepared'
        return
    }
    $saved = Get-Content $StateFile -Raw | ConvertFrom-Json

    foreach ($value in $saved.Values) {
        Set-RegistryValue $value.Key $value.Name $value.Value
    }
    # Replace the pin list wholesale, so pins added by Prepare's unpinning are not merged back in.
    Invoke-Reg 'delete', $TaskbandKey, '/f' -AllowFailure
    Invoke-Reg 'import', (Join-Path $State 'taskband.reg')
    $pins = Join-Path $State 'pins'
    if (Test-Path $pins) {
        New-Item -ItemType Directory -Force $PinnedFolder | Out-Null
        Copy-Item "$pins\*" $PinnedFolder -Force
    }
    Restart-Explorer
    Set-DesktopIcons ([bool]$saved.DesktopIcons)
    if ($saved.Wallpaper) { Set-Wallpaper $saved.Wallpaper }
    Send-ThemeChange

    Remove-Item $State -Recurse -Force
    Write-Output 'restored the desktop settings saved before Prepare'
}

if ($Mode -eq 'Prepare') { Invoke-Prepare } else { Invoke-Restore }
