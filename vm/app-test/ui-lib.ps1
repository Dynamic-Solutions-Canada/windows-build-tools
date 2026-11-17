<#
Helpers for driving and capturing apps in the guest's desktop session (dot-source this file).
Run only through run-interactive.ps1: UI Automation and screen capture need the desktop session.
#>
Add-Type -AssemblyName UIAutomationClient, System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class UiNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct HIGHCONTRAST { public int cbSize; public int dwFlags; public string lpszDefaultScheme; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool SystemParametersInfo(int action, int param, ref HIGHCONTRAST hc, int winIni);
}
"@
[UiNative]::SetProcessDPIAware() | Out-Null
$UiA = [System.Windows.Automation.AutomationElement]
$UiRoot = $UiA::RootElement
$UiOut = "C:\apptest\out"

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

<# First descendant with this name, optionally of this control type (e.g. ListItem). #>
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

<# Choose an option in a combo box by a regex on its text. #>
function Select-ComboOption($Combo, [string]$Match) {
    $Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Start-Sleep -Seconds 1
    $cond = New-Object System.Windows.Automation.PropertyCondition($UiA::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    $item = $Combo.FindAll("Descendants", $cond) | Where-Object { $_.Current.Name -match $Match } | Select-Object -First 1
    if (-not $item) { throw "No option matching '$Match'" }
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
