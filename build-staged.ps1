# Build only inside this invocation's Windows TEMP staging directory.
# All source paths come from a validated repository manifest. ASCII only.
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Stage)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$stageRoot = [IO.Path]::GetFullPath($Stage)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'WindowsAppBuilds'))
if (-not $stageRoot.StartsWith($allowedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Build stage must be underneath the current user Windows TEMP/WindowsAppBuilds.'
}

$source = Join-Path $stageRoot 'source'
$request = Get-Content -LiteralPath (Join-Path $stageRoot 'request.json') -Raw | ConvertFrom-Json
$artifactRoot = Join-Path $stageRoot 'artifacts'
$result = @{ success = $false; platform = $request.platform; configuration = $request.configuration }
$code = 1
$mutex = $null
$mutexAcquired = $false
# Older callers and fixtures default to build-only behavior for new policy fields.
foreach ($field in @('dev', 'install', 'skip_build', 'dry_run', 'no_launch', 'store_identity_mode')) {
    if (-not $request.PSObject.Properties[$field]) { $request | Add-Member $field $false }
}
$result.dev = [bool]$request.dev
$result.store_identity = [bool]$request.store_identity_mode
$PID | Set-Content -LiteralPath (Join-Path $stageRoot 'windows.pid') -Encoding UTF8
Start-Transcript -Path (Join-Path $stageRoot 'build.log') | Out-Null
try {
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    Set-Location -LiteralPath $source
    $env:MSBUILDDISABLENODEREUSE = '1'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

    if ($request.dev) {
        # Serialize this app's version allocation and installation on this Windows host.
        $mutexName = 'Global\WindowsAppBuild-' + ($request.project -replace '[^a-zA-Z0-9]', '_')
        $mutex = [Threading.Mutex]::new($false, $mutexName)
        try { $mutexAcquired = $mutex.WaitOne() }
        catch [Threading.AbandonedMutexException] { $mutexAcquired = $true }
    }
    if ($request.dev -and -not $request.skip_build) {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (Join-Path $source $request.certificate), $request.certificate_password)
        if ($request.store_identity_mode -and $certificate.Subject -ne $request.store_publisher) {
            throw 'Store-identity testing requires a signing certificate matching the Store publisher.'
        }
        $installed = @(Get-AppxPackage -Name $request.dev_identity | Where-Object Publisher -eq $certificate.Subject)
        [xml]$props = Get-Content (Join-Path $source $request.version_file) -Raw
        $versionNode = $props.SelectSingleNode('//Version')
        $version = [version]$versionNode.InnerText
        $baseline = [version]::new($version.Major, $version.Minor, $version.Build, [Math]::Max(0, $version.Revision))
        foreach ($old in $installed) {
            if ([version]$old.Version -gt $baseline) { $baseline = [version]$old.Version }
        }
        if ($baseline.Revision -ge 65535) { throw 'Dev revision exhausted; choose a new release version explicitly.' }
        $devVersion = [version]::new($baseline.Major, $baseline.Minor, $baseline.Build, $baseline.Revision + 1)
        $versionNode.InnerText = $devVersion.ToString()
        $props.Save((Join-Path $source $request.version_file))
        $result.version = $devVersion.ToString()
        Write-Host "Staging-only dev version: $devVersion"
    }
    if ($request.skip_build) {
        Write-Host 'Using the most recent successful dev package.'
    } elseif ($request.build_only) {
        # Serial MSBuild avoids the parallel-process cancellation seen in this setup.
        & dotnet build $request.project -c $request.configuration "-p:Platform=$($request.platform)" -m:1 -nodeReuse:false
        if ($LASTEXITCODE -ne 0) { throw "dotnet build exited with $LASTEXITCODE" }
        $projectDirectory = Split-Path (Join-Path $source $request.project) -Parent
        Copy-Item -LiteralPath (Join-Path $projectDirectory 'bin') -Destination (Join-Path $artifactRoot 'bin') -Recurse
    } else {
        # Run packaging in a child process because existing scripts use exit on error.
        # This lets the outer process finish its log and failure result reliably.
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $source $request.package_script),
            '-Platform', $request.platform)
        if (-not $request.PSObject.Properties['supports_configuration'] -or $request.supports_configuration) {
            $arguments += @('-Configuration', $request.configuration)
        } elseif ($request.configuration -ne 'Release') {
            throw 'This packaging script supports Release only; use --build-only for Debug.'
        }
        if (-not $request.no_sign -and $request.PSObject.Properties['certificate_switch']) {
            $arguments += @($request.certificate_switch, (Join-Path $source $request.certificate),
                $request.password_switch, $request.certificate_password)
        } elseif (-not $request.no_sign -and $request.PSObject.Properties['trusted_certificate'] -and $request.trusted_certificate) {
            $arguments += @('-TrustedPfxPath', (Join-Path $source $request.certificate),
                '-TrustedPfxPassword', $request.certificate_password)
        }
        if ($request.store_identity_mode) {
            $arguments += $request.store_identity_switch
        }
        if ($request.no_sign) {
            $arguments += $(if ($request.PSObject.Properties['unsigned_switch']) { $request.unsigned_switch } else { '-NoSign' })
        }
        if ($request.PSObject.Properties['prepare_script']) {
            & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $source $request.prepare_script)
            if ($LASTEXITCODE -ne 0) { throw 'Package asset generation failed.' }
        }
        # Reuse the driver's PowerShell 7 executable, including UTF-8 file defaults.
        & (Get-Process -Id $PID).Path @arguments
        if ($LASTEXITCODE -ne 0) { throw "MSIX packaging exited with $LASTEXITCODE" }
        $packages = @(Get-ChildItem -LiteralPath (Join-Path $source $request.package_output) -File | Where-Object { $_.Extension -in @('.msix', '.msixbundle') })
        if ($packages.Count -eq 0) { throw 'Packaging returned success without producing an MSIX.' }
        foreach ($package in $packages) {
            Copy-Item -LiteralPath $package.FullName -Destination $artifactRoot
        }
    }
    if (-not $request.build_only -and -not $request.no_sign -and -not $request.skip_build -and
        $request.PSObject.Properties['certificate_password']) {
        $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            (Join-Path $source $request.certificate), $request.certificate_password)
        [IO.File]::WriteAllBytes((Join-Path $artifactRoot 'signing.cer'),
            $publicCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    }
    if ($request.install) {
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $stageRoot 'install-staged.ps1') -Stage $stageRoot
        if ($LASTEXITCODE -ne 0) { throw 'Installation failed; see the build log.' }
    }
    $result.success = $true
    $code = 0
} catch {
    $result.error = $_.Exception.Message
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
    $result.exit_code = $code
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stageRoot 'result.json') -Encoding UTF8
    Stop-Transcript | Out-Null
}
exit $code
