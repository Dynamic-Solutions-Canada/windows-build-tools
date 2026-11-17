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

Each recorded package is matched by its family and architecture. The installed version is removed
when it is the recorded version, or when the record says the family was new to the guest
("preexisting=no"): then a newer version is still ours, updated in place by the Store during the
session (App Installer updating the Windows App Runtime, for example). Otherwise it belongs to the
guest and is kept, reported as "kept <name> <version>: not ours". Records written before the
preexisting field existed are treated the same way, removing only the exact recorded version. A package that another installed
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

<#
Remove the installed version of a recorded package when it is ours, unless something depends on it.
An entry is "<full name> preexisting=yes|no"; older entries are just the full name.
#>
function Remove-RecordedPackage([string]$Entry) {
    $fields = $Entry.Split(' ')
    $recorded = $fields[0]
    $familyWasNew = $fields -contains 'preexisting=no'
    $identity = Get-RecordedIdentity $recorded
    if (-not $identity) {
        Write-Output "could not read record entry: $Entry"
        return
    }
    $installed = @(Find-InstalledVersions $identity)
    if (-not $installed) {
        Write-Output "already gone: $recorded"
        return
    }
    foreach ($package in $installed) {
        if ($package.PackageFullName -ne $recorded -and -not $familyWasNew) {
            Write-Output "kept $($package.Name) $($package.Version): not ours"
            continue
        }
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
