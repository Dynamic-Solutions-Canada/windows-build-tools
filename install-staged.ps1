# Update a signed package in place. Never uninstall or change package identity.
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Stage, [switch]$Interactive)
$ErrorActionPreference = 'Stop'

<# Processes running from a package's install folder (any of its executables). #>
function Get-PackageProcess([string]$InstallLocation) {
    $folder = $InstallLocation.TrimEnd('\') + '\'
    Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) }
}

<# True once a process runs from the install folder, checking every half second for up to $Seconds. #>
function Wait-PackageProcess([string]$InstallLocation, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (@(Get-PackageProcess $InstallLocation).Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
$request = Get-Content (Join-Path $Stage 'request.json') -Raw | ConvertFrom-Json
$packages = @(Get-ChildItem (Join-Path $Stage 'artifacts') -File | Where-Object { $_.Extension -in @('.msix', '.msixbundle') })
if ($packages.Count -ne 1) { throw 'Installation requires exactly one MSIX.' }
$package = $packages[0]
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($package.FullName)
try {
    if (-not $zip.GetEntry('AppxSignature.p7x')) { throw 'Unsigned packages cannot be installed.' }
    if ($package.Extension -eq '.msixbundle') {
        # A Store family distributed as a bundle must continue to use bundles.
        $reader = [IO.StreamReader]::new($zip.GetEntry('AppxMetadata/AppxBundleManifest.xml').Open())
        try { [xml]$bundleManifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $applicationPackages = @($bundleManifest.Bundle.Packages.Package | Where-Object {
            $_.Type -eq 'application' -and $_.Architecture -eq $request.platform.ToLowerInvariant()
        })
        if ($applicationPackages.Count -ne 1) { throw 'Bundle must contain one application package for the requested platform.' }
        # Read the launch entry point from the inner package without extracting its payload.
        $innerStream = [IO.MemoryStream]::new()
        $entryStream = $zip.GetEntry($applicationPackages[0].FileName).Open()
        try { $entryStream.CopyTo($innerStream) } finally { $entryStream.Dispose() }
        $innerStream.Position = 0
        $innerZip = [IO.Compression.ZipArchive]::new($innerStream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            $reader = [IO.StreamReader]::new($innerZip.GetEntry('AppxManifest.xml').Open())
            try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
            foreach ($field in @('Name', 'Publisher', 'Version')) {
                if ($bundleManifest.Bundle.Identity.$field -ne $manifest.Package.Identity.$field) {
                    throw 'Bundle identity does not match its application package.'
                }
            }
        } finally { $innerZip.Dispose(); $innerStream.Dispose() }
    } else {
        $reader = [IO.StreamReader]::new($zip.GetEntry('AppxManifest.xml').Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
} finally { $zip.Dispose() }
$identity = $manifest.Package.Identity
if ($request.PSObject.Properties['store_identity_mode'] -and $request.store_identity_mode -and
    ($identity.Name -ne $request.store_identity -or $identity.Publisher -ne $request.store_publisher)) {
    throw 'The test package does not match the requested Store identity.'
}
$existing = @(Get-AppxPackage -Name $identity.Name)
if ($existing | Where-Object { $_.Publisher -ne $identity.Publisher -and $_.SignatureKind -ne 'Store' }) {
    throw 'An installed package has a different publisher. Resolve the identity explicitly; this helper never removes it.'
}
if ($existing | Where-Object { $_.Publisher -eq $identity.Publisher -and [version]$_.Version -gt [version]$identity.Version }) {
    throw 'A newer package is installed. Build a fresh dev package instead of downgrading.'
}
$certificatePath = Join-Path $Stage 'artifacts/signing.cer'
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
if ($certificate.Subject -ne $identity.Publisher) { throw 'Signing certificate does not match the package publisher.' }
$result = @{ name = $identity.Name; version = $identity.Version; dry_run = [bool]$request.dry_run }
if ($request.dry_run) {
    Write-Host "Validated install: $($identity.Name) $($identity.Version), no Windows changes."
} else {
    if ((Get-Process -Id $PID).SessionId -eq 0) {
        if ($Interactive) { throw 'No interactive Windows session is available for installation.' }
        # SSH runs in session 0. Use a unique task and its explicit completion
        # file, so an old installed package can never masquerade as success.
        $taskName = 'WindowsAppInstall-' + [guid]::NewGuid().ToString('N')
        $taskName | Set-Content (Join-Path $Stage 'interactive-task.txt')
        $completion = Join-Path $Stage 'interactive-result.json'
        $runner = Join-Path $Stage 'interactive-install.ps1'
        @'
param([string]$Stage)
$ErrorActionPreference = 'Stop'
$completion = Join-Path $Stage 'interactive-result.json'
try {
    & (Join-Path $Stage 'install-staged.ps1') -Stage $Stage -Interactive
    @{ success = $true } | ConvertTo-Json | Set-Content $completion
} catch {
    @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json | Set-Content $completion
    exit 1
}
'@ | Set-Content $runner
        $command = '"' + (Get-Process -Id $PID).Path + '" -NoProfile -File "' + $runner + '" -Stage "' + $Stage + '"'
        & schtasks.exe /create /tn $taskName /tr $command /sc once /st 23:59 /it /f | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not create interactive installation task.' }
        try {
            & schtasks.exe /run /tn $taskName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not start interactive installation task.' }
            $deadline = (Get-Date).AddSeconds(180)
            while (-not (Test-Path $completion) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
            if (-not (Test-Path $completion)) { throw 'Interactive installation timed out.' }
            $outcome = Get-Content $completion -Raw | ConvertFrom-Json
            if (-not $outcome.success) { throw $outcome.error }
        } finally {
            if (-not (Test-Path $completion)) {
                & schtasks.exe /end /tn $taskName 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { 'Interactive task stop unconfirmed' | Set-Content (Join-Path $Stage 'cleanup-blocked') }
            }
            & schtasks.exe /delete /tn $taskName /f 2>&1 | Out-Null
        }
        Remove-Item (Join-Path $Stage 'interactive-task.txt') -Force
        return
    }
    $trusted = Test-Path "Cert:\LocalMachine\TrustedPeople\$($certificate.Thumbprint)"
    if (-not $trusted) {
        # Windows owns the consent prompt. Only the public certificate is trusted.
        $trustScript = Join-Path $Stage 'trust-certificate.ps1'
        @'
param([string]$CertificatePath)
$ErrorActionPreference = 'Stop'
try {
    Import-Certificate -FilePath $CertificatePath -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    exit 0
} catch { Write-Error $_; exit 1 }
'@ | Set-Content $trustScript
        $arguments = "-NoProfile -File `"$trustScript`" -CertificatePath `"$certificatePath`""
        $trust = Start-Process (Get-Process -Id $PID).Path -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($trust.ExitCode -ne 0) { throw 'Certificate trust was canceled or failed.' }
    }
    # Windows restarts an app that registered for restart (RegisterApplicationRestart) once a forced
    # update has closed it. Launching it as well, in the same second, fails in Windows with "the target
    # host was not in a valid state to receive process registrations" (0x80070BF7), shown as an error box.
    $previous = Get-AppxPackage -Name $identity.Name | Where-Object Publisher -eq $identity.Publisher
    $wasRunning = $previous -and @(Get-PackageProcess $previous.InstallLocation).Count -gt 0
    Add-AppxPackage -Path $package.FullName -ForceApplicationShutdown
    $installed = Get-AppxPackage -Name $identity.Name | Where-Object Publisher -eq $identity.Publisher
    if (-not $installed -or [version]$installed.Version -ne [version]$identity.Version) {
        throw 'Windows did not report the expected installed package version.'
    }
    if (-not $request.no_launch) {
        $appId = if ($request.PSObject.Properties['application_id']) {
            $request.application_id
        } else { @($manifest.Package.Applications.Application)[0].Id }
        if (-not (@($manifest.Package.Applications.Application) | Where-Object Id -eq $appId)) {
            throw 'Configured launch entry point is absent from the manifest.'
        }
        if ($wasRunning -and (Wait-PackageProcess $installed.InstallLocation 8)) {
            Write-Host 'Windows restarted the app after the update; not launching it again.'
        } else {
            & explorer.exe "shell:AppsFolder\$($installed.PackageFamilyName)!$appId"
        }
    }
    Write-Host "Installed $($installed.PackageFullName)"
}
$result | ConvertTo-Json | Set-Content (Join-Path $Stage 'install-result.json')
