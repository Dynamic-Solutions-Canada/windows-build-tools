<#
.SYNOPSIS
Install a dev-signed MSIX in a test guest, trusting only its signer's public certificate.

.DESCRIPTION
Takes the signer certificate from the package's own signature (nothing private enters the guest),
adds it to LocalMachine\TrustedPeople, then installs or updates the package. Progress output is off
because Add-AppxPackage fails over SSH with "Access is denied ... reading the console output buffer"
when it tries to draw its progress bar. Remove the certificate afterwards with -Untrust.

.PARAMETER Msix    Path in the guest of the package to install.
.PARAMETER Untrust Remove the certificate that signed -Msix from TrustedPeople instead of installing.
#>
param(
    [Parameter(Mandatory)] [string]$Msix,
    [switch]$Untrust
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$cert = (Get-AuthenticodeSignature $Msix).SignerCertificate
if (-not $cert) { throw "$Msix is not signed" }

$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
$store.Open("ReadWrite")
try {
    if ($Untrust) {
        $store.Remove($cert)
        Write-Output "untrusted: $($cert.Subject) $($cert.Thumbprint)"
        return
    }
    $store.Add($cert)
    Write-Output "trusted: $($cert.Subject) $($cert.Thumbprint)"
}
finally {
    $store.Close()
}

Add-AppxPackage -Path $Msix -ForceApplicationShutdown
Get-AppxPackage | Where-Object { $_.SignatureKind -eq 'Developer' } | ForEach-Object { "installed: " + $_.PackageFullName }
