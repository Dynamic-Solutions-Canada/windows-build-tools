# Shrinks a test VM's Windows install (windows-dev or windows10-test) so its sparse disk image on
# the host stays small. Run elevated over SSH, with nothing else using the guest (on windows-dev, hold
# app_test_lock), in three steps:
#   scp vm/guest-slim.ps1 windows-dev:C:/OEM/guest-slim.ps1
#   ssh windows-dev powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\guest-slim.ps1 -Step Clean
#   ssh windows-dev powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\guest-slim.ps1 -Step Deep
#   (shut down from inside the guest, `shutdown /s /t 0`, wait for the container to exit, start it again)
#   ssh windows-dev powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\guest-slim.ps1 -Step Trim
# Clean removes apps, OneDrive and caches and trims, so the host file shrinks before Deep's long
# servicing (CompactOS and the component store cleanup) temporarily writes new blocks; check the host
# file's size (du) after it. Deep can take most of an hour and logs to C:\OEM\guest-slim-deep.log;
# run it with SSH keepalives (ssh -o ServerAliveInterval=30). After Deep, shut Windows down from
# inside rather than with docker stop or vm/remote.sh down, whose two-minute limit can cut off a long
# servicing shutdown. Trim then hands back what the restart freed (the old page file, components
# removed at boot).
#
# Windows 10 refuses Remove-AppxPackage over SSH, so Clean reports "could not remove" for each app
# there. Remove them from the signed-in desktop session with vm/app-test, then run Trim:
#   app_test_use win10; app_test_put vm/app-test/run-interactive.ps1; app_test_put vm/guest-slim.ps1
#   printf '& C:\\apptest\\guest-slim.ps1 -Step Apps\n' > apps.ps1; app_test_put apps.ps1
#   app_test_ui 'C:\apptest\apps.ps1'; app_test_clean
#
# Safe to re-run. It keeps everything the bridge build and vm/app-test use: the build toolchain
# (guest-toolchain.ps1), MSIX installs (App Installer, Store and its purchase app), WebView2 and Edge,
# the Windows App Runtime and other frameworks, Notepad, Calculator and Terminal (used in captures),
# Paint, Clock and Clipchamp (Little Launcher's Store screenshots show their icons; restored on
# windows-dev with winget from the Store on November 26, 2026, which grew its disk image by about
# 0.75 GB after a trim),
# Snipping Tool (Repilot's "Screen snip" function opens it), Photos (Immich Drive's tests open photos
# from File Explorer), media extensions, Widgets (Persistent's widget, Repilot's Win+W), and Xbox
# Game Bar with the packages it needs (ChatMixr's widget, Repilot's Win+G, gamebar.ps1). It removes
# consumer apps and OneDrive, caches, update leftovers and the component store's superseded versions.
#
# The host file shrinks only because the image passes TRIM through (dockurr/windows' DISK_DISCARD
# default, "unmap"); the -Trim pass (Optimize-Volume -ReTrim) tells QEMU which blocks are free.
param(
    # Fixed page file size in MB. 1.5 GB beside a 3 to 4 GB guest; the automatic page file had
    # grown to 0.7 GB on windows-dev, so this leaves headroom for build peaks without a growing file.
    [int]$PageFileMB = 1536,
    # Clean: apps, OneDrive, caches, then trim. Deep: settings, CompactOS, component store.
    # Trim: only trim the free space. Apps: only the app removal, for Windows 10, which refuses
    # app removal over SSH ("Removal failed"); run that step in the desktop session (see below).
    [Parameter(Mandatory)]
    [ValidateSet('Clean', 'Deep', 'Trim', 'Apps')]
    [string]$Step
)
# Continue, not Stop: Windows PowerShell turns a native tool's stderr line into a terminating error
# under Stop, and reg.exe or dism.exe writing a harmless message would end the run halfway.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# Consumer apps a build or test guest never uses. Names missing on a given Windows version are skipped.
$RemovableApps = @(
    'Microsoft.BingNews'
    'Microsoft.BingSearch'
    'Microsoft.BingWeather'
    'Microsoft.Edge.GameAssist'
    'Microsoft.GamingApp'                 # the Xbox app; Game Bar (XboxGamingOverlay) is kept
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.Microsoft3DViewer'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MicrosoftStickyNotes'
    'Microsoft.MixedReality.Portal'
    'Microsoft.Office.OneNote'
    'Microsoft.OneDrive.Photos'
    'Microsoft.OutlookForWindows'
    'Microsoft.MSPaint'                   # Paint 3D; the current Paint (Microsoft.Paint) is kept
    'Microsoft.People'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.SkypeApp'
    'Microsoft.Todos'
    'Microsoft.Wallet'
    'Microsoft.Windows.DevHome'
    'Microsoft.WindowsCamera'
    'microsoft.windowscommunicationsapps'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.YourPhone'
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'
    'MicrosoftCorporationII.QuickAssist'
    'MicrosoftWindows.CrossDevice'
    'MSTeams'
)

<#
.SYNOPSIS
Report C: usage, so each run shows what it freed.
#>
function Write-DiskUse([string]$When) {
    $drive = Get-PSDrive C
    Write-Output ('{0}: C: {1:N1} GB used, {2:N1} GB free' -f $When, ($drive.Used / 1GB), ($drive.Free / 1GB))
}

<#
.SYNOPSIS
Delete a folder's contents, keeping the folder. Files in use are skipped silently: they are
the running system's own temporary files, and the next run gets them.
#>
function Clear-Folder([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        # Keep the folder's own desktop.ini: it gives a known folder such as Downloads its name in
        # the display language, and without it Explorer shows "Downloads" in every language.
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'desktop.ini' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "cleared $Path"
    }
}

<#
.SYNOPSIS
Remove consumer apps for every user and from the provisioned image, so new profiles do not get
them back. Frameworks and anything in use by a kept app stay, since only these names are removed.
#>
function Remove-ConsumerApps {
    $provisioned = Get-AppxProvisionedPackage -Online
    foreach ($name in $RemovableApps) {
        foreach ($package in @(Get-AppxPackage -AllUsers -Name $name)) {
            try {
                Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                Write-Output "removed app $($package.Name)"
            } catch {
                Write-Output "could not remove $($package.Name): $($_.Exception.Message)"
            }
        }
        # Removing an app for all users on Windows 11 often deprovisions it too, so a missing
        # provisioned package here is expected rather than a failure.
        foreach ($image in @($provisioned | Where-Object DisplayName -eq $name)) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $image.PackageName -ErrorAction Stop | Out-Null
                Write-Output "deprovisioned $name"
            } catch {
                Write-Output "already deprovisioned: $name"
            }
        }
    }
}

<#
.SYNOPSIS
Uninstall OneDrive (a per-user Win32 install, not an app package) and stop it coming back for
new users.
#>
function Remove-OneDrive {
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
    $setups = @(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\OneDrive\*\OneDriveSetup.exe", 'C:\Program Files\Microsoft OneDrive\*\OneDriveSetup.exe', "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe" -ErrorAction SilentlyContinue)
    if ($setups.Count -gt 0) {
        Start-Process $setups[0].FullName -ArgumentList '/uninstall', '/allusers' -Wait
        Start-Process $setups[0].FullName -ArgumentList '/uninstall' -Wait
        Write-Output 'uninstalled OneDrive'
    }
    # The default profile's Run entry reinstalls it for each new user.
    & reg.exe load HKU\SlimDefault C:\Users\Default\NTUSER.DAT 2>&1 | Out-Null
    & reg.exe delete 'HKU\SlimDefault\Software\Microsoft\Windows\CurrentVersion\Run' /v OneDriveSetup /f 2>&1 | Out-Null
    [GC]::Collect()
    & reg.exe unload HKU\SlimDefault 2>&1 | Out-Null
}

<#
.SYNOPSIS
Clear caches and leftovers: temp folders, Windows Update downloads, Delivery Optimization,
package caches and old app-test installs.
#>
function Clear-Caches {
    Clear-Folder $env:TEMP
    Clear-Folder "$env:SystemRoot\Temp"
    foreach ($profile in Get-ChildItem C:\Users -Directory -Force -ErrorAction SilentlyContinue) {
        Clear-Folder (Join-Path $profile.FullName 'AppData\Local\Temp')
        Clear-Folder (Join-Path $profile.FullName 'Downloads')
        Clear-Folder (Join-Path $profile.FullName 'AppData\Local\npm-cache')
        Clear-Folder (Join-Path $profile.FullName 'AppData\Local\pip\Cache')
    }

    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Clear-Folder "$env:SystemRoot\SoftwareDistribution\Download"
    Start-Service wuauserv, bits -ErrorAction SilentlyContinue
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        Delete-DeliveryOptimizationCache -Force
        Write-Output 'cleared the Delivery Optimization cache'
    }

    # NuGet's package caches refill from nuget.org on the next build's restore.
    $dotnet = 'C:\Program Files\dotnet\dotnet.exe'
    if (Test-Path $dotnet) {
        $env:DOTNET_NOLOGO = '1'
        & $dotnet nuget locals all --clear | Out-Null
        Write-Output 'cleared NuGet caches'
    }

    # A test session left behind (vm/app-test); app_test_clean is the normal way to end one.
    if (Test-Path C:\apptest) {
        Write-Output 'left C:\apptest in place: end its session with app_test_clean, which also removes its packages'
    }
    # vm/win10-update.sh's working folder, left behind if a run stopped early.
    if (Test-Path C:\win10-update) {
        Remove-Item C:\win10-update -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output 'removed C:\win10-update'
    }
}

<#
.SYNOPSIS
Windows settings that hold disk space: hibernation, reserved storage, the page file and
uncompressed system files.
#>
function Set-SlimSettings {
    & powercfg.exe /h off
    Write-Output 'hibernation off'

    & dism.exe /Online /Set-ReservedStorageState /State:Disabled /NoRestart | Out-Null
    Write-Output 'reserved storage disabled'

    $system = Get-CimInstance Win32_ComputerSystem
    if ($system.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $system -Property @{ AutomaticManagedPagefile = $false }
    }
    $setting = Get-CimInstance Win32_PageFileSetting -Filter "Name='C:\\pagefile.sys'"
    if ($null -eq $setting) {
        $setting = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'C:\pagefile.sys' }
    }
    Set-CimInstance -InputObject $setting -Property @{ InitialSize = [uint32]$PageFileMB; MaximumSize = [uint32]$PageFileMB }
    Write-Output "page file fixed at $PageFileMB MB (applies after a restart)"

    & compact.exe /CompactOS:always | Out-Null
    Write-Output 'system files compressed (CompactOS)'
}

<#
.SYNOPSIS
Drop superseded component versions. /ResetBase makes installed updates permanent, which is fine
for a VM that is rebuilt rather than rolled back.
#>
function Clear-ComponentStore {
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
    if ($LASTEXITCODE -ne 0) { Write-Output "DISM component cleanup exited with $LASTEXITCODE" }
}

<#
.SYNOPSIS
Tell the virtual disk which blocks are free, so the host's sparse image gives them back.
#>
function Invoke-Trim {
    Optimize-Volume -DriveLetter C -ReTrim -Verbose 4>&1 | Select-Object -Last 3 | ForEach-Object { "$_" }
}

Write-DiskUse 'before'
switch ($Step) {
    'Clean' {
        Remove-ConsumerApps
        Remove-OneDrive
        Clear-Caches
        Invoke-Trim
    }
    'Deep' {
        Start-Transcript -Path C:\OEM\guest-slim-deep.log -Force | Out-Null
        Set-SlimSettings
        Clear-ComponentStore
        Invoke-Trim
        Stop-Transcript | Out-Null
    }
    'Trim' {
        Invoke-Trim
    }
    'Apps' {
        Remove-ConsumerApps
    }
}
Write-DiskUse 'after'
