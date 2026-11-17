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
C:\apptest\installed.txt, so remove-packages.ps1 can undo exactly that. Progress output is off,
because Add-AppxPackage fails with "Access is denied ... reading the console output buffer" when
it cannot draw its progress bar.

.PARAMETER Msix Path in the guest of the app package to install.
#>
param(
    [Parameter(Mandatory)] [string]$Msix
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$record = 'C:\apptest\installed.txt'

<# Install one package unless that exact version is already there, and record what was added. #>
function Install-One([string]$Path) {
    $before = @(Get-AppxPackage | ForEach-Object PackageFullName)
    Add-AppxPackage -Path $Path -ForceApplicationShutdown
    $added = Get-AppxPackage | Where-Object { $before -notcontains $_.PackageFullName }
    foreach ($p in $added) {
        Add-Content $record $p.PackageFullName
        Write-Output "installed: $($p.PackageFullName)"
    }
    if (-not $added) { Write-Output "already installed: $(Split-Path $Path -Leaf)" }
}

# ── Dependencies (the runtime framework before the packages that need it) ──
$deps = Get-ChildItem 'C:\apptest\deps\*.msix' -ErrorAction SilentlyContinue |
    Sort-Object { if ($_.Name -match '^Microsoft\.WindowsAppRuntime\.\d') { 0 } else { 1 } }, Name
foreach ($dep in $deps) {
    Install-One $dep.FullName
}

# ── Signer certificate, then the app ─────────────────────────────────────
$cert = (Get-AuthenticodeSignature $Msix).SignerCertificate
if (-not $cert) { throw "$Msix is not signed" }

$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
$store.Open("ReadWrite")
try {
    $already = $store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint
    if (-not $already) {
        $store.Add($cert)
        Add-Content $record "cert:$($cert.Thumbprint)"
    }
    Write-Output "trusted: $($cert.Subject) $($cert.Thumbprint)"
}
finally {
    $store.Close()
}

Install-One $Msix
