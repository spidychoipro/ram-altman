#requires -Version 5.1
<#
    Builds the Windows deliverables into dist\:

        ram-altman.exe                  .NET Framework console build
        ram-altman-<version>-portable.zip
        ram-altman-<version>.msi

    Requirements:
      - Windows with .NET Framework 4.x (csc.exe ships with it)
      - WiX Toolset 5.x for the MSI
        ("dotnet tool install --global wix --version 5.0.2"). WiX 6 and 7
        require accepting the Open Source Maintenance Fee EULA first.
      - PowerShell 7 for the tests (pwsh)

    Usage:
        pwsh -File windows\build.ps1
        pwsh -File windows\build.ps1 -Version 1.2.0 -SkipMsi
#>
[CmdletBinding()]
param(
    [string]$Version = '1.1.0',
    [switch]$SkipTests,
    [switch]$SkipMsi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repoRoot 'dist'
$obj = Join-Path $PSScriptRoot 'obj'
$exe = Join-Path $dist 'ram-altman.exe'
$zip = Join-Path $dist "ram-altman-$Version-portable.zip"
$msi = Join-Path $dist "ram-altman-$Version.msi"

New-Item -ItemType Directory -Force -Path $dist, $obj | Out-Null

# ----- compile the exe --------------------------------------------------------

$framework = 'Framework64'
$csc = Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) {
    $framework = 'Framework'
    $csc = Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe"
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw 'csc.exe not found; the .NET Framework 4.x is required to build the exe'
}

$assemblyInfoPath = Join-Path $obj 'AssemblyInfo.g.cs'
$assemblyInfo = @"
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("Ram Altman")]
[assembly: AssemblyDescription("Reports unused RAM to Sam Altman, at most once a day.")]
[assembly: AssemblyProduct("Ram Altman")]
[assembly: AssemblyCompany("Ram Altman contributors")]
[assembly: AssemblyCopyright("Unlicense")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]
[assembly: AssemblyInformationalVersion("$Version")]
[assembly: ComVisible(false)]
[assembly: Guid("d3f3f2f2-5e1f-4b0e-9a55-1a2b3c4d5e6f")]
"@
Set-Content -LiteralPath $assemblyInfoPath -Value $assemblyInfo -Encoding Ascii

Write-Output "Compiling $exe"
& $csc /nologo /target:exe /platform:anycpu /optimize+ /warn:4 /r:System.Management.dll `
    "/out:$exe" (Join-Path $PSScriptRoot 'src\RamAltman.cs') $assemblyInfoPath
if ($LASTEXITCODE -ne 0) { throw 'csc failed' }

# ----- tests ------------------------------------------------------------------

if (-not $SkipTests) {
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)
    if ($pwsh) {
        Write-Output 'Running tests'
        & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-ram-altman.ps1') -ExePath $exe
        if ($LASTEXITCODE -ne 0) { throw 'tests failed' }
    }
    else {
        Write-Warning 'pwsh not found; skipping the test suite'
    }
}

# ----- portable zip -----------------------------------------------------------

Write-Output "Building $zip"
$staging = Join-Path $obj 'portable'
Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Copy-Item -LiteralPath $exe -Destination $staging
Copy-Item -LiteralPath (Join-Path $repoRoot 'ram-altman.ps1') -Destination $staging
Copy-Item -LiteralPath (Join-Path $repoRoot 'ram-altman.bat') -Destination $staging
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $staging
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $staging
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $staging 'README-windows.md')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.example.ini') -Destination $staging

if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -CompressionLevel Optimal

# ----- MSI --------------------------------------------------------------------

if ($SkipMsi) {
    Write-Output 'Skipping MSI'
}
else {
    $wixExe = $null
    $wixCommand = Get-Command wix.exe -ErrorAction SilentlyContinue
    if (-not $wixCommand) { $wixCommand = Get-Command wix -ErrorAction SilentlyContinue }
    if ($wixCommand) {
        $wixExe = $wixCommand.Source
    }
    elseif (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe')) {
        $wixExe = Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe'
    }

    if (-not $wixExe) {
        throw 'WiX not found. Install it with: dotnet tool install --global wix --version 5.0.2'
    }

    Write-Output "Building $msi"
    if (Test-Path -LiteralPath $msi) { Remove-Item -LiteralPath $msi -Force }
    & $wixExe build -arch x64 `
        -d "Version=$Version" `
        -d "SourceDir=$dist" `
        -d "RepoRoot=$repoRoot" `
        -o $msi `
        (Join-Path $PSScriptRoot 'installer\RamAltman.wxs')
    if ($LASTEXITCODE -ne 0) { throw 'wix build failed' }
}

# ----- summary ----------------------------------------------------------------

Write-Output ''
Write-Output 'Artifacts:'
Get-ChildItem -LiteralPath $dist | Where-Object { $_.Extension -in @('.exe', '.msi', '.zip') } |
    Sort-Object Name |
    ForEach-Object { '{0,-40} {1,10:N0} bytes' -f $_.Name, $_.Length }
