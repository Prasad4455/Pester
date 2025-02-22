﻿# build should provide '%system.teamcity.build.checkoutDir%'
param (
    [Parameter(Mandatory)]
    [String] $PsGalleryApiKey,
    [String] $NugetApiKey,
    [String] $ChocolateyApiKey,
    [String] $CertificateThumbprint = '2FCC9148EC2C9AB951C6F9654C0D2ED16AF27738',
    [Switch] $Force
)

$ErrorActionPreference = 'Stop'

$bin = "$PSScriptRoot/../bin"

# checking the path first because I want to fail the script when I fail to remove all files
if (Test-Path $bin) {
    Remove-Item $bin -Recurse -Force
}

pwsh -noprofile -c "$PSScriptRoot/../build.ps1 -Clean -Inline"
if ($LASTEXITCODE -ne 0) {
    throw "build failed!"
}

$m = Test-ModuleManifest $bin/Pester.psd1
$version = if ($m.PrivateData -and $m.PrivateData.PSData -and $m.PrivateData.PSData.PreRelease) {
    "$($m.Version)-$($m.PrivateData.PSData.PreRelease)"
}
else {
    $m.Version
}

$isPreRelease = $version -match '-'

if (-not $isPreRelease -or $Force) {
    if ([string]::IsNullOrWhiteSpace($NugetApiKey)) {
        throw "This is stable release NugetApiKey is needed."
    }

    if ([string]::IsNullOrWhiteSpace($ChocolateyApiKey)) {
        throw "This is stable release ChocolateyApiKey is needed."
    }
}

pwsh -noprofile -c "$PSSCriptRoot/../test.ps1 -nobuild"
if ($LASTEXITCODE -ne 0) {
    throw "test failed!"
}

pwsh -noprofile -c "$PSScriptRoot/../build.ps1 -Inline"
if ((Get-Item $bin/Pester.psm1).Length -lt 50KB) {
    throw "Module is too small, are you publishing non-inlined module?"
}

& "$PSScriptRoot/signModule.ps1" -Thumbprint $CertificateThumbprint -Path $bin

$files = @(
    'Pester.ps1'
    'Pester.psd1'
    'Pester.psm1'
    'Pester.Format.ps1xml'
    'PesterConfiguration.Format.ps1xml'
    'bin/net452/Pester.dll'
    'bin/net452/Pester.pdb'
    'bin/netstandard2.0/Pester.dll'
    'bin/netstandard2.0/Pester.pdb'
    'en-US/about_BeforeEach_AfterEach.help.txt'
    'en-US/about_Mocking.help.txt'
    'en-US/about_Pester.help.txt'
    'en-US/about_Should.help.txt'
    'en-US/about_TestDrive.help.txt'
    'schemas/JaCoCo/report.dtd'
    'schemas/JUnit4/junit_schema_4.xsd'
    'schemas/NUnit25/nunit_schema_2.5.xsd'
    'schemas/NUnit3/TestDefinitions.xsd'
    'schemas/NUnit3/TestFilterDefinitions.xsd'
    'schemas/NUnit3/TestResult.xsd'
)

$notFound = @()
foreach ($f in $files) {
    if (-not (Test-Path "$bin/$f")) {
        $notFound += $f
    }
}

if (0 -lt $notFound.Count) {
    throw "Did not find files:`n$($notFound -join "`n")"
}
else {
    'Found all files!'
}

# build psgallery module
$psGalleryDir = "$PSScriptRoot/../tmp/PSGallery/Pester/"
if (Test-Path $psGalleryDir) {
    Remove-Item -Recurse -Force $psGalleryDir
}
$null = New-Item -ItemType Directory -Path $psGalleryDir
Copy-Item "$PSScriptRoot/../bin/*" $psGalleryDir -Recurse


# build nuget for nuget.org and chocolatey
$nugetDir = "$PSScriptRoot/../tmp/nuget/"
if (Test-Path $nugetDir) {
    Remove-Item -Recurse -Force $nugetDir
}
$null = New-Item -ItemType Directory -Path $nugetDir
Copy-Item "$PSScriptRoot/../bin/*" $nugetDir -Recurse
Copy-Item "$PSScriptRoot/../LICENSE" $nugetDir -Recurse

Out-File "$nugetDir/VERIFICATION.txt" -InputObject @'
VERIFICATION
Verification is intended to assist the Chocolatey moderators and community
in verifying that this package's contents are trustworthy.

You can use one of the following methods to obtain the checksum
  - Use powershell function 'Get-Filehash'
  - Use chocolatey utility 'checksum.exe'

CHECKSUMS
'@

Get-ChildItem -Path $bin -Filter *.dll -Recurse | ForEach-Object {
    $path = $_.FullName
    $relativePath = ($path -replace [regex]::Escape($nugetDir.TrimEnd('/').TrimEnd('\'))).TrimStart('/').TrimStart('\')
    $hash = Get-FileHash -Path $path -Algorithm SHA256 | Select-Object -ExpandProperty Hash
    Out-File "$nugetDir/VERIFICATION.txt" -Append -InputObject @"
    file: $relativePath
    hash: $hash
    algorithm: sha256
"@
}

& nuget pack "$PSScriptRoot/Pester.nuspec" -OutputDirectory $nugetDir -NoPackageAnalysis -version $version
$nupkg = (Join-Path $nugetDir "Pester.$version.nupkg")
& nuget sign $nupkg -CertificateFingerprint $CertificateThumbprint -Timestamper "http://timestamp.digicert.com"

Publish-Module -Path $psGalleryDir -NuGetApiKey $PsGalleryApiKey -Verbose -Force

if (-not $isPreRelease -or $Force) {
    & nuget push $nupkg -Source https://api.nuget.org/v3/index.json -apikey $NugetApiKey
    & nuget push $nupkg -Source https://push.chocolatey.org/ -apikey $ChocolateyApiKey
}
else {
    Write-Host "This is pre-release $version, not pushing to Nuget and Chocolatey."
}
