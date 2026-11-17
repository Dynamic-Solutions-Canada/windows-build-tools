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
#>
$ProgressPreference = 'SilentlyContinue'
$record = 'C:\apptest\installed.txt'
if (-not (Test-Path $record)) {
    Write-Output "nothing recorded in $record"
    return
}

$entries = @(Get-Content $record)
[array]::Reverse($entries)
foreach ($entry in $entries) {
    if ($entry -like 'cert:*') {
        $thumbprint = $entry.Substring(5)
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
        $store.Open("ReadWrite")
        $store.Certificates | Where-Object Thumbprint -eq $thumbprint | ForEach-Object { $store.Remove($_) }
        $store.Close()
        Write-Output "untrusted: $thumbprint"
        continue
    }
    try {
        Remove-AppxPackage $entry -ErrorAction Stop
        Write-Output "removed: $entry"
    }
    catch {
        Write-Output "could not remove ${entry}: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
    }
}
Remove-Item $record
