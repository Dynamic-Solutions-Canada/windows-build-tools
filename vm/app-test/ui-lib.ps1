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
