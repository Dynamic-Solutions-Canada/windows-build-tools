<#
.SYNOPSIS
Undo install-package.ps1: remove every package it added and untrust any certificate it trusted.

.DESCRIPTION
Reads C:\apptest\installed.txt and works through it newest first, so apps go before the runtime
packages they depend on and the framework goes last. Entries that were already in the guest before
the test were never recorded, so they stay. An install that updated a package already in the guest
records the new version, so removal takes the app away entirely rather than restoring the older
version; that suits these disposable test guests. Run it in the desktop session (app_test_run), like the
install. Safe to run after a failed install: it removes whatever was recorded.

Each recorded package is matched by its family and architecture, not its exact version: the Store can
update a package in place during a session (App Installer updating the Windows App Runtime, for
example), and the newer version is still the one this test added. A package that another installed
package still depends on is kept and reported as "kept ..., in use by ...", since removing it would
break that package (App Installer needs the runtime framework it updated).

.PARAMETER Record Path of the install record; tests point it at a scratch file.
#>
param(
    [string]$Record = 'C:\apptest\installed.txt'
)
$ProgressPreference = 'SilentlyContinue'

<#
Split a recorded package full name (Name_Version_Architecture_ResourceId_PublisherId) into the family
name (Name_PublisherId) and architecture that identify it across version updates.
#>
function Get-RecordedIdentity([string]$FullName) {
    $parts = $FullName.Split('_')
    if ($parts.Count -ne 5) { return $null }
    [pscustomobject]@{ Family = "$($parts[0])_$($parts[4])"; Architecture = $parts[2] }
}

<# The installed packages of this family and architecture, whatever their version. #>
function Find-InstalledVersions($Identity) {
    Get-AppxPackage -PackageTypeFilter Main, Framework, Optional |
        Where-Object { $_.PackageFamilyName -eq $Identity.Family -and "$($_.Architecture)" -eq $Identity.Architecture }
}

<# Names of other installed packages that declare a dependency on this exact package. #>
function Find-Dependents([string]$FullName) {
    Get-AppxPackage -PackageTypeFilter Main, Framework, Optional |
        Where-Object { $_.PackageFullName -ne $FullName -and @($_.Dependencies | ForEach-Object PackageFullName) -contains $FullName } |
        ForEach-Object Name
}

<# Remove the certificate install-package.ps1 trusted, by thumbprint. #>
function Remove-TrustedCertificate([string]$Thumbprint) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
    $store.Open("ReadWrite")
    try {
        $store.Certificates | Where-Object Thumbprint -eq $Thumbprint | ForEach-Object { $store.Remove($_) }
    }
    finally {
        $store.Close()
    }
    Write-Output "untrusted: $Thumbprint"
}

<# Remove whatever version of a recorded package is installed now, unless something depends on it. #>
function Remove-RecordedPackage([string]$Entry) {
    $identity = Get-RecordedIdentity $Entry
    if (-not $identity) {
        Write-Output "could not read record entry: $Entry"
        return
    }
    $installed = @(Find-InstalledVersions $identity)
    if (-not $installed) {
        Write-Output "already gone: $Entry"
        return
    }
    foreach ($package in $installed) {
        $dependents = @(Find-Dependents $package.PackageFullName)
        if ($dependents) {
            Write-Output "kept $($package.PackageFullName), in use by $($dependents -join ', ')"
            continue
        }
        try {
            Remove-AppxPackage $package.PackageFullName -ErrorAction Stop
            Write-Output "removed: $($package.PackageFullName)"
        }
        catch {
            Write-Output "could not remove $($package.PackageFullName): $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        }
    }
}

# ── Undo the record, newest first ────────────────────────────────────────
if (-not (Test-Path $Record)) {
    Write-Output "nothing recorded in $Record"
    return
}
$entries = @(Get-Content $Record | Where-Object { $_ })
[array]::Reverse($entries)
foreach ($entry in $entries) {
    if ($entry -like 'cert:*') {
        Remove-TrustedCertificate $entry.Substring(5)
    }
    else {
        Remove-RecordedPackage $entry
    }
}
Remove-Item $Record
