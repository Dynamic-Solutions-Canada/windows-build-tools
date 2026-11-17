<#
.SYNOPSIS
Install a dev-signed MSIX in a test guest, trusting only its signer's public certificate.

.DESCRIPTION
Run it in the desktop session (app_test_run on the host): over SSH, Windows 11 refuses
Add-AppxPackage with 0x80070005 "Access is denied", for framework and app packages alike.

First installs every package in C:\apptest\deps (the Windows App Runtime MSIX files that
app_test_put_runtime copies there; Microsoft-signed, framework first), then takes the signer
certificate from the app package's own signature (nothing private enters the guest), adds it to
LocalMachine\TrustedPeople and installs or updates the app. Every package it adds is appended to
C:\apptest\installed.txt, so remove-packages.ps1 can undo exactly that.

A runtime package is skipped, and not recorded, when the guest already has the same package at
that version or higher: Add-AppxPackage refuses a downgrade with 0x80073D06, and the Store often
updates the guest's runtime past the version in the NuGet cache. Cleanup then leaves the guest's own
runtime alone. Progress output is off,
because Add-AppxPackage fails with "Access is denied ... reading the console output buffer" when
it cannot draw its progress bar.

.PARAMETER Msix Path in the guest of the app package to install. Without it, only the runtime
packages in -Deps are installed.
.PARAMETER Deps Folder of runtime packages to install first.
.PARAMETER Record Path of the install record that remove-packages.ps1 reads.
#>
param(
    [string]$Msix,
    [string]$Deps = 'C:\apptest\deps',
    [string]$Record = 'C:\apptest\installed.txt'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

<# Install one package unless that exact version is already there, and record what was added. #>
function Install-One([string]$Path) {
    $before = @(Get-AppxPackage | ForEach-Object PackageFullName)
    Add-AppxPackage -Path $Path -ForceApplicationShutdown
    $added = Get-AppxPackage | Where-Object { $before -notcontains $_.PackageFullName }
    foreach ($p in $added) {
        Add-Content $Record $p.PackageFullName
        Write-Output "installed: $($p.PackageFullName)"
    }
    if (-not $added) { Write-Output "already installed: $(Split-Path $Path -Leaf)" }
}

<# Read the Name, Publisher, Version and ProcessorArchitecture a package declares in its manifest. #>
function Get-PackageIdentity([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader = New-Object System.IO.StreamReader($zip.GetEntry('AppxManifest.xml').Open())
        try { $manifest = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally {
        $zip.Dispose()
    }
    $manifest.Package.Identity
}

<# Install a runtime package unless the guest already has it at this version or higher. #>
function Install-Dependency([string]$Path) {
    $identity = Get-PackageIdentity $Path
    $newer = Get-AppxPackage -PackageTypeFilter Main, Framework |
        Where-Object {
            $_.Name -eq $identity.Name -and $_.Publisher -eq $identity.Publisher -and
            "$($_.Architecture)" -eq $identity.ProcessorArchitecture -and
            [version]$_.Version -ge [version]$identity.Version
        } |
        Sort-Object { [version]$_.Version } -Descending |
        Select-Object -First 1
    if ($newer) {
        Write-Output "kept installed $($newer.Version): $($identity.Name) (offered $($identity.Version))"
        return
    }
    Install-One $Path
}

# ── Dependencies (the runtime framework before the packages that need it) ──
$depFiles = Get-ChildItem (Join-Path $Deps '*.msix') -ErrorAction SilentlyContinue |
    Sort-Object { if ($_.Name -match '^Microsoft\.WindowsAppRuntime\.\d') { 0 } else { 1 } }, Name
foreach ($dep in $depFiles) {
    Install-Dependency $dep.FullName
}
if (-not $Msix) { return }

# ── Signer certificate, then the app ─────────────────────────────────────
$cert = (Get-AuthenticodeSignature $Msix).SignerCertificate
if (-not $cert) { throw "$Msix is not signed" }

$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
$store.Open("ReadWrite")
try {
    $already = $store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint
    if (-not $already) {
        $store.Add($cert)
        Add-Content $Record "cert:$($cert.Thumbprint)"
    }
    Write-Output "trusted: $($cert.Subject) $($cert.Thumbprint)"
}
finally {
    $store.Close()
}

Install-One $Msix
