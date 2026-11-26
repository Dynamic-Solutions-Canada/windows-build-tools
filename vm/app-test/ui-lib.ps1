<#
Helpers for driving and capturing apps in the guest's desktop session (dot-source this file).
Run only through run-interactive.ps1: UI Automation and screen capture need the desktop session.
#>
Add-Type -AssemblyName UIAutomationClient, System.Drawing, System.Windows.Forms
Add-Type -ReferencedAssemblies Accessibility @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class UiMenu {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr h, uint id, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object obj);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern int GetMenuItemID(IntPtr menu, int position);

  // Position is the item's zero-based place in the menu, separators included. Id is its command
  // ID, the number the app gave it, which is the same in every display language; -1 for a submenu.
  public class Item { public int Index; public int Position; public int Id; public string Name; public bool Enabled; }

  // The topmost visible #32768 window, the most recently opened (sub)menu, or IntPtr.Zero.
  static IntPtr MenuWindow() {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      var name = new StringBuilder(16);
      GetClassName(h, name, 16);
      if (name.ToString() == "#32768" && IsWindowVisible(h)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  // The open popup menu's client accessible object (OBJID_CLIENT), or null when no menu is open.
  static Accessibility.IAccessible OpenMenu() {
    IntPtr found = MenuWindow();
    if (found == IntPtr.Zero) return null;
    Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");   // IID_IAccessible
    object acc;
    if (AccessibleObjectFromWindow(found, 0xFFFFFFFC, ref iid, out acc) != 0) return null;
    return acc as Accessibility.IAccessible;
  }

  // Whether a popup menu is open.
  public static bool IsOpen() { return OpenMenu() != null; }

  // The open menu's items, without separators (role 21); empty when no menu is open.
  // MSAA child N is the menu's item at position N - 1 (separators are children too), and a menu
  // handle (MN_GETHMENU) is valid in any process of the session, so the command IDs are read from it.
  public static List<Item> Items() {
    var items = new List<Item>();
    var menu = OpenMenu();
    if (menu == null) return items;
    IntPtr handle = SendMessage(MenuWindow(), 0x01E1, IntPtr.Zero, IntPtr.Zero);   // MN_GETHMENU
    for (int child = 1; child <= menu.accChildCount; child++) {
      if ((int)menu.get_accRole(child) != 12) continue;   // ROLE_SYSTEM_MENUITEM
      int state = (int)menu.get_accState(child);
      int id = handle == IntPtr.Zero ? -1 : GetMenuItemID(handle, child - 1);
      items.Add(new Item { Index = child, Position = child - 1, Id = id, Name = menu.get_accName(child), Enabled = (state & 0x1) == 0 });   // STATE_SYSTEM_UNAVAILABLE
    }
    return items;
  }

  // Run an item's default action (choose it). Returns false when no menu is open.
  public static bool Choose(int index) {
    var menu = OpenMenu();
    if (menu == null) return false;
    menu.accDoDefaultAction(index);
    return true;
  }
}
"@
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class UiNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attribute, out RECT r, int size);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct HIGHCONTRAST { public int cbSize; public int dwFlags; public string lpszDefaultScheme; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool SystemParametersInfo(int action, int param, ref HIGHCONTRAST hc, int winIni);
  [DllImport("kernel32.dll")] public static extern ushort GetUserDefaultUILanguage();
}
"@
# Per-monitor aware (v2), so every coordinate this script reads or sets is in physical pixels at any
# display scale. A system-aware process would see logical sizes after a scale change made in the same
# sign-in (screenshot-desktop.ps1 -Scale 200), since its system DPI is fixed at sign-in. Plain
# SetProcessDPIAware is the fallback for Windows builds without DPI awareness contexts.
if (-not [UiNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) {   # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    [UiNative]::SetProcessDPIAware() | Out-Null
}
$UiA = [System.Windows.Automation.AutomationElement]
$UiRoot = $UiA::RootElement
$UiOut = "C:\apptest\out"

<#
The signed-in user's Windows display language as a culture name, such as "ja-JP". Use it instead of
Get-UICulture: these scripts run in a console host, and for Chinese, Japanese and Korean Windows gives
a console thread English as its UI language, so Get-UICulture reports en-US there.
#>
function Get-DisplayLanguage {
    [Globalization.CultureInfo]::GetCultureInfo([int][UiNative]::GetUserDefaultUILanguage()).Name
}

<# Turn Windows high contrast on (with the given scheme) or off, for the whole guest session. #>
function Set-HighContrast([bool]$On, [string]$Scheme = "High Contrast Black") {
    $hc = New-Object UiNative+HIGHCONTRAST
    $hc.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($hc)
    $hc.dwFlags = if ($On) { 1 } else { 0 }   # HCF_HIGHCONTRASTON
    $hc.lpszDefaultScheme = $Scheme
    # SPI_SETHIGHCONTRAST, SPIF_SENDCHANGE; SPIF_UPDATEINIFILE is left off so it is not persisted.
    [UiNative]::SystemParametersInfo(0x43, $hc.cbSize, [ref]$hc, 2) | Out-Null
    Start-Sleep -Seconds 3
}

<# Save a PNG of the screen region an element covers (the whole screen when $Element is null). #>
function Save-Shot([string]$Name, $Element = $null) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($Element) {
        $r = $Element.Current.BoundingRectangle
        $b = New-Object System.Drawing.Rectangle ([int]$r.X), ([int]$r.Y), ([int]$r.Width), ([int]$r.Height)
    }
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save("$UiOut\$Name.png")
    $g.Dispose(); $bmp.Dispose()
    Write-Output "shot: $Name.png"
}

<# Top-level windows of the processes with this name. #>
function Get-AppWindows([string]$ProcessName) {
    Get-Process $ProcessName -ErrorAction SilentlyContinue | ForEach-Object {
        $cond = New-Object System.Windows.Automation.PropertyCondition($UiA::ProcessIdProperty, $_.Id)
        $UiRoot.FindAll("Children", $cond)
    }
}

<#
File Explorer's open folder windows, as UI Automation elements: top-level windows of class
CabinetWClass owned by explorer.exe. Found by class and process, never by title, which is the folder's
translated display name ("This PC" is "Dieser PC" in German). With -Path, only windows that have a tab
showing that folder (compared as full paths, case-insensitively; read through Shell.Application, whose
paths do not depend on the display language). Waits up to -TimeoutSeconds for one to appear, then
returns what it found, possibly nothing.
#>
function Get-ExplorerWindows([string]$Path = $null, [int]$TimeoutSeconds = 0) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $isFolder = New-Object System.Windows.Automation.PropertyCondition($UiA::ClassNameProperty, 'CabinetWClass')
    while ($true) {
        $explorer = @(Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object Id)
        $windows = @($UiRoot.FindAll("Children", $isFolder) | Where-Object { $explorer -contains $_.Current.ProcessId })
        if ($Path) {
            $wanted = [IO.Path]::GetFullPath($Path).TrimEnd('\')
            $handles = @((New-Object -ComObject Shell.Application).Windows() | Where-Object {
                    try { [IO.Path]::GetFullPath($_.Document.Folder.Self.Path).TrimEnd('\') -eq $wanted } catch { $false }
                } | ForEach-Object { [int64]$_.HWND })
            $windows = @($windows | Where-Object { $handles -contains [int64]$_.Current.NativeWindowHandle })
        }
        if ($windows.Count -gt 0 -or (Get-Date) -ge $deadline) {
            return $windows
        }
        Start-Sleep -Milliseconds 500
    }
}

<#
First descendant with this AutomationId (x:Name or AutomationProperties.AutomationId in XAML),
optionally of this control type (e.g. Button), or $null. Prefer this to Find-ByName: an ID is the
same in every display language, so a drive script that uses IDs captures every Store locale.
#>
function Find-ById($Element, [string]$AutomationId, [string]$Type = $null) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($UiA::AutomationIdProperty, $AutomationId)
    $Element.FindAll("Descendants", $cond) |
        Where-Object { -not $Type -or $_.Current.ControlType.ProgrammaticName -eq "ControlType.$Type" } |
        Select-Object -First 1
}

<#
First descendant with this name, optionally of this control type (e.g. ListItem), or $null. Names
are the displayed, translated text, so a lookup by name works in one display language only: use it
only for an element with no AutomationId (give the element one in the app where you can), and pass
the name for the language being captured.
#>
function Find-ByName($Element, [string]$Name, [string]$Type = $null) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($UiA::NameProperty, $Name)
    $Element.FindAll("Descendants", $cond) |
        Where-Object { -not $Type -or $_.Current.ControlType.ProgrammaticName -eq "ControlType.$Type" } |
        Select-Object -First 1
}

<# Click the centre of an element with the real mouse. #>
function Invoke-Click($Element) {
    $r = $Element.Current.BoundingRectangle
    [UiNative]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)) | Out-Null
    Start-Sleep -Milliseconds 150
    [UiNative]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [UiNative]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

<#
Choose an option in a combo box: by a regex on its text ($Match), or by its zero-based place in the
list (-Index), which is the same in every display language. Text matches one language only.
#>
function Select-ComboOption($Combo, [string]$Match, [int]$Index = -1) {
    if ([string]::IsNullOrEmpty($Match) -eq ($Index -lt 0)) { throw "Select-ComboOption: pass either a text match or -Index" }
    $Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Start-Sleep -Seconds 1
    $cond = New-Object System.Windows.Automation.PropertyCondition($UiA::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $options = @($Combo.FindAll("Descendants", $cond))
    if ($Index -ge 0) {
        if ($Index -ge $options.Count) { throw "No option at index $Index (the list has $($options.Count))" }
        $item = $options[$Index]
    }
    else {
        $item = $options | Where-Object { $_.Current.Name -match $Match } | Select-Object -First 1
        if (-not $item) { throw "No option matching '$Match'" }
    }
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Seconds 2
}

<#
Place a window at the top left of the work area, at most $Width wide and as tall as the work area.
Test VMs have small screens (windows-dev is 1280 x 800): a window that runs under the taskbar hides
its lower navigation items, and clicks meant for them land on the taskbar.
#>
function Set-WindowFitted($Window, [int]$Width = 1100) {
    $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    Set-WindowBounds $Window ($work.X + 10) ($work.Y + 10) ([Math]::Min($Width, $work.Width - 20)) ($work.Height - 20)
}

<# Move and resize a window (physical pixels). #>
function Set-WindowBounds($Window, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    [UiNative]::MoveWindow([IntPtr]$Window.Current.NativeWindowHandle, $X, $Y, $Width, $Height, $true) | Out-Null
    Start-Sleep -Seconds 2
}

<#
Make a window the active, foreground window, and throw if Windows will not allow it. Captures of an
inactive window show a dimmed title bar and no Mica, so a drive script calls this before each shot.

Plain SetForegroundWindow has worked in the test guests, even from a background process, since
nobody types there. Windows can still refuse it (it lets a process take the foreground only when it
received the last input event), so every attempt is checked with GetForegroundWindow, and retries
first tap F24, a key no app uses, which should make this process that recipient. That fallback has
not been seen to run. Not Alt, the usual trick: Alt shows access-key badges in the captured app.
#>
function Set-WindowActive($Window, [int]$Attempts = 5) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    if ([UiNative]::IsIconic($handle)) {
        [UiNative]::ShowWindow($handle, 9) | Out-Null   # SW_RESTORE
    }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) {
            [UiNative]::AllowSetForegroundWindow(-1) | Out-Null   # ASFW_ANY
            [UiNative]::keybd_event(0x87, 0, 0, [UIntPtr]::Zero)  # F24 down
            [UiNative]::keybd_event(0x87, 0, 2, [UIntPtr]::Zero)  # F24 up (KEYEVENTF_KEYUP)
        }
        [UiNative]::BringWindowToTop($handle) | Out-Null
        [UiNative]::SetForegroundWindow($handle) | Out-Null
        Start-Sleep -Milliseconds 500
        if ([UiNative]::GetForegroundWindow() -eq $handle) {
            return
        }
    }
    throw "Could not make '$($Window.Current.Name)' the foreground window after $Attempts attempts"
}

<#
The window's visible frame in physical screen pixels (DWMWA_EXTENDED_FRAME_BOUNDS): what the user
sees as the window, without its shadow or the invisible resize borders that GetWindowRect includes.
Returns an object with X, Y, Width and Height.
#>
function Get-WindowFrame($Window) {
    $rect = New-Object UiNative+RECT
    $result = [UiNative]::DwmGetWindowAttribute([IntPtr]$Window.Current.NativeWindowHandle, 9, [ref]$rect, 16)
    if ($result -ne 0) { throw "DwmGetWindowAttribute failed: 0x{0:X8}" -f $result }
    [pscustomobject]@{ X = $rect.Left; Y = $rect.Top; Width = $rect.Right - $rect.Left; Height = $rect.Bottom - $rect.Top }
}

<#
Centre a window's visible frame in the work area (the screen minus the taskbar), optionally resizing
its frame to $Width x $Height first (physical pixels). Store screenshot crops are taken around the
window and kept inside the work area, so a centred window keeps wallpaper on every side.
#>
function Set-WindowCentered($Window, [int]$Width = 0, [int]$Height = 0) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $outer = New-Object UiNative+RECT
    [UiNative]::GetWindowRect($handle, [ref]$outer) | Out-Null
    $frame = Get-WindowFrame $Window

    # MoveWindow positions the outer rectangle, which is wider than the frame by the invisible borders.
    $left = $frame.X - $outer.Left
    $top = $frame.Y - $outer.Top
    $right = $outer.Right - ($frame.X + $frame.Width)
    $bottom = $outer.Bottom - ($frame.Y + $frame.Height)
    if ($Width -le 0) { $Width = $frame.Width }
    if ($Height -le 0) { $Height = $frame.Height }

    $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $work.X + [int](($work.Width - $Width) / 2)
    $y = $work.Y + [int](($work.Height - $Height) / 2)
    Set-WindowBounds $Window ($x - $left) ($y - $top) ($Width + $left + $right) ($Height + $top + $bottom)
}

<#
Save a whole-screen capture of $Window's desktop as C:\apptest\out\<Name>.png, 1:1, with a
<Name>.json sidecar describing it, for Store screenshots that are cropped later on the host (the
winui-app-kit render script reads the sidecar). Makes the window active first, so its title bar and
Mica are drawn as the user sees them.

Sidecar fields: screen (the PNG's own size), scale (the window's display scale, percent), window (the
visible frame, Get-WindowFrame), workArea, theme (apps and system, "dark" or "light"), wallpaper
(file name), effects (DWM effects forced on by app_test_effects), os ("10.0.<build>") and capturedUtc.
Sizes are physical pixels.
#>
function Save-DesktopCapture([string]$Name, $Window) {
    Set-WindowActive $Window
    Start-Sleep -Milliseconds 500

    # Capture first, so the metadata describes the pixels as close in time as possible.
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $bmp = New-Object System.Drawing.Bitmap $screen.Bounds.Width, $screen.Bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)
    $captured = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $bmp.Save("$UiOut\$Name.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $size = @{ width = $bmp.Width; height = $bmp.Height }
    $g.Dispose(); $bmp.Dispose()

    # Theme, wallpaper, effects and build as they are now.
    $personalize = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $themeName = { param($light) if ($light -eq 0) { 'dark' } else { 'light' } }
    $dwm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -ErrorAction SilentlyContinue
    $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $frame = Get-WindowFrame $Window
    $work = $screen.WorkingArea

    $sidecar = [ordered]@{
        screen = $size
        scale = [int]([UiNative]::GetDpiForWindow([IntPtr]$Window.Current.NativeWindowHandle) * 100 / 96)
        window = [ordered]@{ x = $frame.X; y = $frame.Y; width = $frame.Width; height = $frame.Height }
        workArea = [ordered]@{ x = $work.X; y = $work.Y; width = $work.Width; height = $work.Height }
        theme = [ordered]@{ apps = (& $themeName $personalize.AppsUseLightTheme); system = (& $themeName $personalize.SystemUsesLightTheme) }
        wallpaper = Split-Path -Leaf (Get-ItemProperty 'HKCU:\Control Panel\Desktop').WallPaper
        effects = ($dwm -and $dwm.ForceEffectMode -eq 2)
        os = "$($version.CurrentMajorVersionNumber).$($version.CurrentMinorVersionNumber).$($version.CurrentBuild)"
        capturedUtc = $captured
    }
    # UTF-8 without a byte order mark, which Set-Content in Windows PowerShell 5.1 would add.
    [IO.File]::WriteAllText("$UiOut\$Name.json", ($sidecar | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding $false))
    Save-ElementDump $Name $Window
    Write-Output "capture: $Name.png, $Name.json"
}

<#
Write $UiOut\<Name>.uia.json beside a capture: every element of the window that has a name, with its
control type, automation ID, name and bounding rectangle in physical pixels, in tree order. Automated
localization checks compare these between languages (English left over, text that no longer fits,
layout changes) without reading pixels. Never fails the capture: an error is recorded in the file.
#>
function Save-ElementDump([string]$Name, $Window) {
    $elements = New-Object System.Collections.ArrayList
    $errorText = $null
    try {
        $all = $Window.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($element in $all) {
            $current = $element.Current
            if ([string]::IsNullOrWhiteSpace($current.Name)) { continue }
            $r = $current.BoundingRectangle
            $rect = $null
            if (-not $r.IsEmpty) { $rect = [ordered]@{ x = [int]$r.X; y = [int]$r.Y; width = [int]$r.Width; height = [int]$r.Height } }
            $entry = [ordered]@{
                type = $current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
                id = $current.AutomationId
                name = $current.Name
                rect = $rect
                offscreen = $current.IsOffscreen
            }
            [void]$elements.Add($entry)
        }
    } catch {
        $errorText = "$_"
    }
    $frame = Get-WindowFrame $Window
    $dump = [ordered]@{
        window = [ordered]@{ x = $frame.X; y = $frame.Y; width = $frame.Width; height = $frame.Height }
        elements = $elements
        error = $errorText
    }
    [IO.File]::WriteAllText("$UiOut\$Name.uia.json", ($dump | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
}

<#
Find an app's notification-area (tray) icon by the start of its tooltip, such as "Little Launcher:",
and return it as a UI Automation element (click it with Invoke-Click), or $null. Matches only tray
icons (AutomationId NotifyItemIcon): a search for a Button named after the app finds its taskbar
button first. Looks in the visible tray, then opens "Show Hidden Icons" and looks in the overflow,
which stays open when the icon is found there and is closed again when it is not.
A tray icon's menu is a standard Win32 popup menu (a top-level #32768 window), which the managed
UI Automation client used here shows as an empty pane; read and choose its items with Get-MenuItems
and Invoke-MenuItem instead.
#>
function Find-TrayIcon([string]$TooltipPrefix) {
    $isIcon = New-Object System.Windows.Automation.PropertyCondition($UiA::AutomationIdProperty, 'NotifyItemIcon')
    $taskbar = $UiRoot.FindFirst('Children', (New-Object System.Windows.Automation.PropertyCondition($UiA::ClassNameProperty, 'Shell_TrayWnd')))
    $icon = $taskbar.FindAll('Descendants', $isIcon) | Where-Object { $_.Current.Name -like "$TooltipPrefix*" } | Select-Object -First 1
    if ($icon) { return $icon }

    # Not in the visible tray: open the overflow flyout and look there.
    $chevron = $taskbar.FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition($UiA::AutomationIdProperty, 'SystemTrayIcon'))) |
        Where-Object { $_.Current.ClassName -eq 'SystemTray.NormalButton' } | Select-Object -First 1
    if (-not $chevron) { return $null }
    Invoke-Click $chevron
    Start-Sleep -Seconds 1
    $overflow = $UiRoot.FindFirst('Children', (New-Object System.Windows.Automation.PropertyCondition($UiA::ClassNameProperty, 'TopLevelWindowForOverflowXamlIsland')))
    $icon = $null
    if ($overflow) {
        $icon = $overflow.FindAll('Descendants', $isIcon) | Where-Object { $_.Current.Name -like "$TooltipPrefix*" } | Select-Object -First 1
    }
    if (-not $icon) {
        # Close the flyout again, so it is not left over a later screenshot.
        Invoke-Click $chevron
        Start-Sleep -Seconds 1
    }
    $icon
}

<#
The items of the open popup menu (a tray icon's menu, a window's Alt+Space menu, or any other
standard Win32 menu), as objects with Index (the MSAA child), Position (zero-based, counting
separators), Id (the command ID, -1 for a submenu), Name and Enabled; separators are left out. Returns an
empty list when no menu is open. Reads them through MSAA, because the managed UI Automation client
shows a #32768 menu as an empty pane; native UI Automation and Narrator read them through the
system's menu proxy, so this is a limit of this script's client, not of the app.
#>
function Get-MenuItems {
    [UiMenu]::Items()
}

<#
Choose an item of the open popup menu. -Id (the item's command ID, as Get-MenuItems lists it) and
-Position (its zero-based place, separators included) are the same in every display language; a
name, compared without the "&" access-key marker and any shortcut text after a tab, is the
translated text and works in one language only. Throws when no menu is open, or no enabled item
matches. Open the menu yourself immediately before calling this: it acts on whichever popup menu is
open, which could be one left by something else.
#>
function Invoke-MenuItem([string]$Name, [int]$Id = -1, [int]$Position = -1) {
    $given = @(@([bool]$Name, ($Id -ge 0), ($Position -ge 0)) | Where-Object { $_ })
    if ($given.Count -ne 1) { throw "Invoke-MenuItem: pass exactly one of a name, -Id or -Position" }
    if (-not [UiMenu]::IsOpen()) { throw "No popup menu is open" }
    $items = @(Get-MenuItems)
    if ($Id -ge 0) {
        $item = $items | Where-Object { $_.Enabled -and $_.Id -eq $Id } | Select-Object -First 1
        $wanted = "with ID $Id"
    }
    elseif ($Position -ge 0) {
        $item = $items | Where-Object { $_.Enabled -and $_.Position -eq $Position } | Select-Object -First 1
        $wanted = "at position $Position"
    }
    else {
        $item = $items | Where-Object { $_.Enabled -and $_.Name.Replace('&', '').Split("`t")[0] -eq $Name } | Select-Object -First 1
        $wanted = "'$Name'"
    }
    if (-not $item) { throw "The open menu has no enabled item $wanted (items: $(($items | ForEach-Object { "$($_.Position):$($_.Id):$($_.Name)" }) -join ', '))" }
    [UiMenu]::Choose($item.Index) | Out-Null
    Start-Sleep -Milliseconds 500
}
