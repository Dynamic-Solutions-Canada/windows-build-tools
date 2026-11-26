<#
.SYNOPSIS
Prepare a test guest's desktop for screenshots, and put it back afterwards.

.DESCRIPTION
-Mode Prepare saves the current settings to C:\apptest\desktop, then sets the screenshot desktop:
the wallpaper (Windows 11's dark bloom, img19.jpg, by default), desktop icons hidden, the taskbar
search box, Widgets and app notifications off, every pin that Windows lets a script remove taken off
the taskbar, dark mode for Windows and apps, transparency effects on, and a 1920 x 1080 desktop: the
screen at 1920 x 1080 and 100% display scale, or with -Scale 200 at 3840 x 2160 and 200% (the screen
size is not persisted, so a guest restart also returns it to its usual size). Running it again keeps the settings saved the
first time, so a second Prepare never makes the screenshot desktop the one Restore returns to.

Both modes first close any popup menu left open, so a stale menu cannot leak into captures or tests.
Nothing depends on the display language: pins are found by the shell's own verb text for that
language, so the script works the same in a guest switched to another language (guest-language.ps1).

-Mode Restore puts every saved setting back, including the taskbar pins exactly as they were (any pin
a test added is removed), and deletes the saved copy. It also works from a later session or after a
failed capture, since everything it needs is in the saved copy; app_test_clean runs it before
removing C:\apptest.

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
.PARAMETER Width Desktop width for the session in logical pixels: the screen is switched to Width x
Scale / 100 physical pixels (Store screenshots need at least 1366 x 768 logical; the guest starts at
1280 x 800).
.PARAMETER Height Desktop height, likewise.
.PARAMETER Scale Display scale for the session, 100 or 200 percent. Store captures move to 200%,
whose 3840 x 2160 capture the winui-app-kit renderer (v2.10.0 or later) crops in logical pixels and
reduces to the Store size. Drive scripts size windows in physical pixels (Set-WindowCentered), so at
200% they pass twice the 100% size.
.PARAMETER State Folder for the saved settings; tests point it elsewhere.
#>
param(
    [Parameter(Mandatory)] [ValidateSet('Prepare', 'Restore')] [string]$Mode,
    [string]$Wallpaper = 'img19.jpg',
    [int]$Width = 1920,
    [int]$Height = 1080,
    [ValidateSet(100, 200)] [int]$Scale = 100,
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
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wParam, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadLibrary(string file);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int LoadString(IntPtr module, uint id, System.Text.StringBuilder text, int size);
  // A string resource of a system DLL in the display language (Windows picks the matching MUI file).
  public static string SystemString(string dll, uint id) {
    var text = new System.Text.StringBuilder(512);
    return LoadString(LoadLibrary(dll), id, text, text.Capacity) > 0 ? text.ToString() : null;
  }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT point, int flags);
  [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static DEVMODE Current() {
    var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) throw new InvalidOperationException("EnumDisplaySettings failed");
    return dm;
  }
}
"@

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class DisplayScale {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] public struct HEADER { public int type; public int size; public LUID adapterId; public uint id; }
  [StructLayout(LayoutKind.Sequential)] struct GET { public HEADER header; public int minRel; public int curRel; public int maxRel; }
  [StructLayout(LayoutKind.Sequential)] struct SET { public HEADER header; public int rel; }
  [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] struct PATH_TARGET { public LUID adapterId; public uint id; public uint modeInfoIdx; public int outputTechnology; public int rotation; public int scaling; public uint rrNum; public uint rrDen; public int scanLineOrdering; public bool targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] struct PATH { public PATH_SOURCE source; public PATH_TARGET target; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] struct MODE { public int infoType; public uint id; public LUID adapterId; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 48)] public byte[] data; }
  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr topology);
  [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref GET request);
  [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref SET request);

  // The first active display's source (QDC_ONLY_ACTIVE_PATHS); the test guests have one display.
  static HEADER Source(int type, int size) {
    uint np, nm;
    if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) throw new InvalidOperationException("GetDisplayConfigBufferSizes failed");
    var paths = new PATH[np]; var modes = new MODE[nm];
    int result = QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero);
    if (result != 0 || np == 0) throw new InvalidOperationException("QueryDisplayConfig failed: " + result);
    return new HEADER { type = type, size = size, adapterId = paths[0].source.adapterId, id = paths[0].source.id };
  }

  // The scale steps Windows allows for the display, relative to its recommended scale: min, current, max.
  // Undocumented request (-3), the one Settings > Display > Scale uses.
  public static int[] Steps() {
    var request = new GET { header = Source(-3, Marshal.SizeOf(typeof(GET))) };
    int result = DisplayConfigGetDeviceInfo(ref request);
    if (result != 0) throw new InvalidOperationException("Reading the display scale failed: " + result);
    return new[] { request.minRel, request.curRel, request.maxRel };
  }

  // Set the display's scale, as a step relative to its recommended scale (undocumented request -4).
  public static void Set(int relative) {
    var request = new SET { header = Source(-4, Marshal.SizeOf(typeof(SET))), rel = relative };
    int result = DisplayConfigSetDeviceInfo(ref request);
    if (result != 0) throw new InvalidOperationException("Setting the display scale failed: " + result);
  }
}
"@
# Per-monitor aware (v2), so the display scale and sizes read here are the display's real ones.
[DesktopNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

# Registry values the screenshot desktop sets, with the value each takes while prepared.
$Settings = @(
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Value = 0 }
    # Windows itself (taskbar, Start, flyouts) dark too, so tray shots match the dark app.
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Value = 0 }
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Value = 1 }
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Value = 0 }
    # App notifications (toasts) off for the session ("Notifications" in Settings), so a late toast,
    # such as Windows' own pin request, cannot appear in a capture. With them off, Windows also refuses
    # taskbar pin requests (TaskbarManager.IsPinningAllowed is false), so a capture that needs the pin
    # prompt turns ToastEnabled on around it and restarts WpnUserService_* (Little Launcher's does).
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 0 }
    # The documented "Allow widgets" policy; the per-user TaskbarDa value is write-protected (UCPD).
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = 0 }
)
# Display scales Windows offers, in its own order; DisplayConfig addresses them as steps from the one
# it recommends for the display.
$ScaleSteps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)
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

<# The primary screen's current size, as "<width>x<height>". #>
function Get-DisplaySize {
    $mode = [DesktopNative]::Current()
    "$($mode.dmPelsWidth)x$($mode.dmPelsHeight)"
}

<#
Switch the primary screen to $Size ("<width>x<height>") for this session. Not persisted
(ChangeDisplaySettings flags 0), so a guest restart returns to the usual size.
#>
function Set-DisplaySize([string]$Size) {
    if ((Get-DisplaySize) -eq $Size) { return }
    $width, $height = $Size.Split('x')
    $mode = [DesktopNative]::Current()
    $mode.dmPelsWidth = [int]$width
    $mode.dmPelsHeight = [int]$height
    $mode.dmFields = 0x80000 -bor 0x100000   # DM_PELSWIDTH, DM_PELSHEIGHT
    $result = [DesktopNative]::ChangeDisplaySettings([ref]$mode, 0)
    if ($result -ne 0) { throw "Could not switch the screen to $Size (ChangeDisplaySettings returned $result)" }
    Start-Sleep -Seconds 3
}

<# The primary display's current scale, in percent (its effective DPI over 96). #>
function Get-DisplayScale {
    $point = New-Object DesktopNative+POINT
    $monitor = [DesktopNative]::MonitorFromPoint($point, 1)   # MONITOR_DEFAULTTOPRIMARY
    $x = [uint32]0; $y = [uint32]0
    $result = [DesktopNative]::GetDpiForMonitor($monitor, 0, [ref]$x, [ref]$y)   # MDT_EFFECTIVE_DPI
    if ($result -ne 0) { throw ("GetDpiForMonitor failed: 0x{0:X8}" -f $result) }
    [int][Math]::Round($x * 100 / 96)
}

<#
Set the primary display's scale to $Percent, as Settings > Display > Scale does, and wait until it
applies. Windows addresses scales as steps from the one it recommends for the display, which depends
on the screen size, so switch the screen size first. Throws when Windows does not offer $Percent at
the current size (200% needs at least 1600 x 1200 or so). Windows keeps the choice for the display
across restarts, so Restore sets the saved scale back.
#>
function Set-DisplayScale([int]$Percent) {
    $current = Get-DisplayScale
    if ($current -eq $Percent) { return }
    $currentStep = [array]::IndexOf($ScaleSteps, $current)
    $targetStep = [array]::IndexOf($ScaleSteps, $Percent)
    if ($currentStep -lt 0 -or $targetStep -lt 0) { throw "Display scale $current% or $Percent% is not one Windows offers" }

    $min, $now, $max = [DisplayScale]::Steps()
    $relative = $targetStep - ($currentStep - $now)
    if ($relative -lt $min -or $relative -gt $max) {
        $recommended = $currentStep - $now
        throw "Windows does not offer $Percent% at $(Get-DisplaySize): it offers $($ScaleSteps[$recommended + $min])% up to step $max from its recommended $($ScaleSteps[$recommended])%"
    }
    [DisplayScale]::Set($relative)

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-DisplayScale) -ne $Percent) {
        if ((Get-Date) -gt $deadline) { throw "The display scale is still $(Get-DisplayScale)% 15 seconds after setting $Percent%" }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2
}

<#
Restart this user's notification service (WpnUserService_<suffix>), so it rereads ToastEnabled: the
running service ignores a changed value, and a toast still appeared until it was restarted.
#>
function Restart-NotificationService {
    $service = Get-Service 'WpnUserService_*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($service) {
        Restart-Service $service.Name -Force
        Start-Sleep -Seconds 2
    }
}

<#
The shell's "Unpin from taskbar" verb text in the display language, without its "&" access-key marker:
shell32.dll string 5387, which the apps folder's items show as that verb (in German, "Von Taskleiste
loesen" with an umlaut). Falls back to the English text if the string cannot be read.
#>
function Get-UnpinVerbText {
    $text = [DesktopNative]::SystemString('shell32.dll', 5387)
    if (-not $text) { $text = 'Unpin from taskbar' }
    $text.Replace('&', '')
}

<#
Unpin every app whose shell item offers the shell's "Unpin from taskbar" verb, and return their
names. A shell item's verbs expose only their displayed text, so the verb is matched by the shell's
own text for the display language (Get-UnpinVerbText).
#>
function Remove-TaskbarPins {
    $unpin = Get-UnpinVerbText
    $apps = (New-Object -ComObject Shell.Application).NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}').Items()
    foreach ($app in $apps) {
        $verb = $app.Verbs() | Where-Object { $_.Name.Replace('&', '') -eq $unpin } | Select-Object -First 1
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
        DisplaySize = Get-DisplaySize
        DisplayScale = Get-DisplayScale
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
    # The size first: which scales Windows offers depends on it.
    Set-DisplaySize "$($Width * $Scale / 100)x$($Height * $Scale / 100)"
    Set-DisplayScale $Scale
    Restart-NotificationService
    Restart-Explorer
    Set-DesktopIcons $false
    Set-Wallpaper $wallpaperPath
    Send-ThemeChange

    Write-Output "prepared: wallpaper $Wallpaper, dark mode for Windows and apps, transparency on, screen $(Get-DisplaySize) at $(Get-DisplayScale)%, notifications off, desktop icons, search box and Widgets hidden"
    if ($unpinned) { Write-Output "unpinned: $($unpinned -join ', ')" }
    Write-EffectsStatus
}

<#
Put the taskbar pins back exactly as saved: the Taskband record replaced wholesale, and the pinned
shortcuts folder emptied and refilled. Pins a test added during the session go too; deleting only a
pin's shortcut leaves a dead button, because Windows 11 keeps the pin in the Taskband record.
Explorer rereads both when Restore restarts it.
#>
function Restore-TaskbarPins {
    Invoke-Reg 'delete', $TaskbandKey, '/f' -AllowFailure
    Invoke-Reg 'import', (Join-Path $State 'taskband.reg')
    New-Item -ItemType Directory -Force $PinnedFolder | Out-Null
    Get-ChildItem $PinnedFolder -Force | Remove-Item -Recurse -Force
    $pins = Join-Path $State 'pins'
    if (Test-Path $pins) {
        Copy-Item "$pins\*" $PinnedFolder -Recurse -Force
    }
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
    Restore-TaskbarPins
    # The scale first, while the larger screen still offers it; then the size.
    if ($saved.DisplayScale) { Set-DisplayScale ([int]$saved.DisplayScale) }
    if ($saved.DisplaySize) { Set-DisplaySize $saved.DisplaySize }
    Restart-NotificationService
    Restart-Explorer
    Set-DesktopIcons ([bool]$saved.DesktopIcons)
    if ($saved.Wallpaper) { Set-Wallpaper $saved.Wallpaper }
    Send-ThemeChange

    Remove-Item $State -Recurse -Force
    Write-Output 'restored the desktop settings saved before Prepare'
}

<#
Close any popup menu left open, for example by an earlier test run, so it cannot appear in a capture
or be taken for the menu a later test opens. Presses Escape once per open menu level; EndMenu would
only close a menu of this script's own thread.
#>
function Close-OpenMenus {
    for ($level = 0; $level -lt 5; $level++) {
        if ([DesktopNative]::FindWindow('#32768', [NullString]::Value) -eq [IntPtr]::Zero) { return }
        [DesktopNative]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)   # Escape down
        [DesktopNative]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)   # Escape up
        Start-Sleep -Milliseconds 300
    }
    Write-Output 'warning: a popup menu is still open after pressing Escape five times'
}

Close-OpenMenus
if ($Mode -eq 'Prepare') { Invoke-Prepare } else { Invoke-Restore }
