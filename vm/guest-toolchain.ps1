# Installs the bridge's Windows toolchain in the windows-dev guest. Run elevated over SSH:
#   scp vm/guest-toolchain.ps1 windows-dev:C:/OEM/guest-toolchain.ps1
#   ssh windows-dev powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\guest-toolchain.ps1
# Safe to re-run: each step skips work that is already done. Versions are pinned so a
# rebuilt VM matches; bump them deliberately (the .NET band must satisfy each repo's global.json).
param(
    [string]$PowerShellVersion = '7.6.9',
    [string]$DotnetSdkVersion = '10.0.403'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Phase 1: SSH stays key-only (no password or keyboard-interactive logins).
$config = 'C:\ProgramData\ssh\sshd_config'
$text = Get-Content $config -Raw
if ($text -notmatch '(?m)^KbdInteractiveAuthentication no') {
    $text = $text -replace '(?m)^PasswordAuthentication no', "PasswordAuthentication no`r`nKbdInteractiveAuthentication no"
    Set-Content $config $text -Encoding ascii
    Write-Output 'sshd: keyboard-interactive disabled (applies on next sshd start)'
}

# Phase 2: PowerShell 7, which the bridge requires for UTF-8-correct builds.
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (-not (Test-Path $pwsh) -or (& $pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') -ne $PowerShellVersion) {
    $msi = Join-Path $env:TEMP "PowerShell-$PowerShellVersion-win-x64.msi"
    Invoke-WebRequest "https://github.com/PowerShell/PowerShell/releases/download/v$PowerShellVersion/PowerShell-$PowerShellVersion-win-x64.msi" -OutFile $msi
    $install = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/quiet', '/norestart', 'ADD_PATH=1' -Wait -PassThru
    if ($install.ExitCode -ne 0) { throw "PowerShell MSI exited with $($install.ExitCode)" }
    Remove-Item $msi
}
Write-Output ('pwsh ' + (& $pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))

# Phase 3: .NET SDK, machine-wide so SSH sessions and SYSTEM tasks share it.
$dotnetRoot = 'C:\Program Files\dotnet'
$dotnet = Join-Path $dotnetRoot 'dotnet.exe'
$haveSdk = (Test-Path $dotnet) -and ((& $dotnet --list-sdks) -match "^$([regex]::Escape($DotnetSdkVersion)) ")
if (-not $haveSdk) {
    $installer = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
    & $installer -Version $DotnetSdkVersion -InstallDir $dotnetRoot -NoPath
    Remove-Item $installer
}
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (($machinePath -split ';') -notcontains $dotnetRoot) {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$dotnetRoot", 'Machine')
}
[Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetRoot, 'Machine')
[Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'Machine')
Write-Output ('dotnet SDKs: ' + ((& $dotnet --list-sdks) -join ', '))

# Phase 4: Visual Studio Build Tools (current stable channel) for Release packaging.
# The C++ workload's recommended components bring the Windows SDK (makeappx, makepri,
# signtool); NativeAOT needs the MSVC linker, plus ARM64 tools for ARM64 packages. The UWP
# build tools build a package's UWP companion app, such as ChatMixr's Xbox Game Bar widget
# (Game Bar hosts only UWP views); an existing install gets any of these it lacks.
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$components = @(
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
    'Microsoft.VisualStudio.ComponentGroup.UWP.BuildTools')
$haveAll = (Test-Path $vswhere) -and (& $vswhere -products * -requires $components -property installationPath)
if (-not $haveAll) {
    $bootstrapper = Join-Path $env:TEMP 'vs_buildtools.exe'
    Invoke-WebRequest 'https://aka.ms/vs/stable/vs_buildtools.exe' -OutFile $bootstrapper
    $existing = if (Test-Path $vswhere) { & $vswhere -products * -latest -property installationPath }
    $adds = @('--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended',
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
        '--add', 'Microsoft.VisualStudio.ComponentGroup.UWP.BuildTools')
    $arguments = if ($existing) {
        @('modify', '--installPath', "`"$existing`"") + $adds + @('--quiet', '--wait', '--norestart')
    } else {
        @('--quiet', '--wait', '--norestart', '--nocache') + $adds
    }
    $install = Start-Process $bootstrapper -ArgumentList $arguments -Wait -PassThru
    # 3010 means success with a reboot pending.
    if ($install.ExitCode -notin 0, 3010) { throw "Build Tools installer exited with $($install.ExitCode)" }
    Remove-Item $bootstrapper
}
$kits = 'C:\Program Files (x86)\Windows Kits\10\bin'
$sdk = Get-ChildItem $kits -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'x64\makeappx.exe') } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdk) { throw 'Windows SDK packaging tools were not installed' }
Write-Output ('Build Tools: ' + (& $vswhere -products * -latest -property catalog_productDisplayVersion) + '; Windows SDK ' + $sdk.Name)
