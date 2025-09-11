<#
LittleBigMouse build and package script

Usage examples
- Build UI + Hook + installer:
  pwsh ./build.ps1

- Build and sign using a PFX file:
  pwsh ./build.ps1 -Sign -PfxPath C:\certs\mycert.pfx -PfxPassword "secret" -TimestampUrl "http://timestamp.digicert.com"

- Build and sign using cert store thumbprint (CurrentUser\My):
  pwsh ./build.ps1 -Sign -CertThumbprint "THUMBPRINTHEX" -TimestampUrl "http://timestamp.digicert.com"

Parameters
-Configuration   Build configuration (Default: Release)
-Platform        Build platform (Default: x64)
-Sign            Enable code signing steps
-PfxPath         Path to .pfx certificate file
-PfxPassword     Password for .pfx
-CertThumbprint  SHA1 thumbprint to sign from cert store (CurrentUser\My by default)
-UseMachineStore Use LocalMachine store instead of CurrentUser when using thumbprint
-TimestampUrl    RFC3161 timestamp server URL (Default: http://timestamp.digicert.com)
-InstallBuildTools Attempt to install VS Build Tools if MSBuild is missing (requires admin)
-InstallInno     Attempt to install Inno Setup if ISCC.exe is missing (requires admin)
#>

[CmdletBinding()]
param(
  [ValidateSet('Debug','Release')]
  [string]$Configuration = 'Release',
  [ValidateSet('x64','x86','AnyCPU')]
  [string]$Platform = 'x64',
  [switch]$Sign,
  [string]$PfxPath,
  [string]$PfxPassword,
  [string]$CertThumbprint,
  [switch]$UseMachineStore,
  [string]$TimestampUrl = 'http://timestamp.digicert.com',
  [switch]$InstallBuildTools,
  [switch]$InstallInno
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-DotNet {
  param(
    [string]$Channel = '9.0',
    [string]$InstallDir
  )
  if (-not $InstallDir) {
    $InstallDir = Join-Path $PSScriptRoot '.dotnet9'
  }
  $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
  if ($dotnet) { return $dotnet.Source }
  $local = Join-Path $InstallDir 'dotnet.exe'
  if (Test-Path $local) { return $local }
  Write-Host "Installing .NET SDK $Channel locally..." -ForegroundColor Cyan
  $installer = Join-Path $env:TEMP 'dotnet-install.ps1'
  if (-not (Test-Path $installer)) {
    Invoke-WebRequest -UseBasicParsing https://dot.net/v1/dotnet-install.ps1 -OutFile $installer
  }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -Channel $Channel -InstallDir $InstallDir -Quality 'ga'
  if ($LASTEXITCODE -ne 0) { throw "Failed to install .NET SDK $Channel" }
  return $local
}

function Find-MSBuild {
  $vswhereCandidates = @(
    "$env:ProgramFiles(x86)\Microsoft Visual Studio\Installer\vswhere.exe",
    "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
  ) | Where-Object { Test-Path $_ }
  foreach ($vswhere in $vswhereCandidates) {
    $installPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath 2>$null
    if ($installPath) {
      $ms = Join-Path $installPath 'MSBuild\Current\Bin\MSBuild.exe'
      if (Test-Path $ms) { return $ms }
    }
  }
  $fallbacks = @(
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe'
  )
  foreach ($ms in $fallbacks) { if (Test-Path $ms) { return $ms } }
  return $null
}

function Install-BuildTools {
  Write-Host 'Installing Visual Studio Build Tools (C++ workload)...' -ForegroundColor Cyan
  & winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget --accept-package-agreements --accept-source-agreements --override "--passive --norestart --wait --includeRecommended --add Microsoft.VisualStudio.Workload.VCTools"
}

function Find-ISCC {
  $candidates = @(
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Install-Inno {
  Write-Host 'Installing Inno Setup 6...' -ForegroundColor Cyan
  & winget install --id JRSoftware.InnoSetup -e --source winget --accept-package-agreements --accept-source-agreements
}

function Find-SignTool {
  $paths = @()
  $kitsRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
  if (Test-Path $kitsRoot) {
    $paths += Get-ChildItem $kitsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $v = $_
      Get-ChildItem $v.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $archDir = $_
        Join-Path $archDir.FullName 'signtool.exe'
      }
    } | Where-Object { Test-Path $_ }
  }
  if ($paths.Count -gt 0) {
    $x64 = $paths | Where-Object { $_ -like '*\x64\signtool.exe' } | Select-Object -First 1
    if ($x64) { return $x64 }
    return ($paths | Select-Object -First 1)
  }
  # Fallbacks
  $fallbacks = @(
    'C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.8 Tools\signtool.exe'
  )
  foreach ($f in $fallbacks) { if (Test-Path $f) { return $f } }
  return $null
}

function Sign-File {
  param(
    [Parameter(Mandatory)] [string]$File,
    [Parameter(Mandatory)] [string]$SignToolPath,
    [string]$PfxPath,
    [string]$PfxPassword,
    [string]$CertThumbprint,
    [switch]$UseMachineStore,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
  )
  if (-not (Test-Path $File)) { throw "Sign-File: Missing file: $File" }
  $args = @('sign','/fd','sha256')
  if ($TimestampUrl) { $args += @('/tr',$TimestampUrl,'/td','sha256') }
  if ($PfxPath) {
    if (-not (Test-Path $PfxPath)) { throw "PFX not found: $PfxPath" }
    $args += @('/f',$PfxPath)
    if ($PfxPassword) { $args += @('/p',$PfxPassword) }
  }
  elseif ($CertThumbprint) {
    $args += @('/sha1',$CertThumbprint,'/s','My')
    if ($UseMachineStore) { $args += '/sm' }
  }
  else { throw 'No certificate specified for signing' }
  $args += $File
  Write-Host "Signing $File" -ForegroundColor Yellow
  & $SignToolPath @args
  if ($LASTEXITCODE -ne 0) { throw "signtool failed on $File" }
}

# Paths
$uiProj = Join-Path $PSScriptRoot 'LittleBigMouse.Ui\LittleBigMouse.Ui.Avalonia\LittleBigMouse.Ui.Avalonia.csproj'
$uiOutDir = Join-Path $PSScriptRoot "LittleBigMouse.Ui\LittleBigMouse.Ui.Avalonia\bin\$Platform\$Configuration\net8.0"
$uiExe = Join-Path $uiOutDir 'LittleBigMouse.Ui.Avalonia.exe'
$hookProj = Join-Path $PSScriptRoot 'LittleBigMouse.Hook\LittleBigMouse.Hook.vcxproj'
$hookOutDir = Join-Path $PSScriptRoot "LittleBigMouse.Hook\bin\$Platform\$Configuration"
$hookExe = Join-Path $hookOutDir 'LittleBigMouse.Hook.exe'
$iss = Join-Path $PSScriptRoot 'LittleBigMouse.Setup\LittleBigMouse.iss'

# 1) Find or install dotnet 9 for restore/build (repo references net9 in some libs)
$dotnet = Find-DotNet -Channel '9.0'
& $dotnet --info | Out-Null

# 2) Build UI
Write-Host "Building UI ($Configuration|$Platform)..." -ForegroundColor Cyan
& $dotnet restore $uiProj
& $dotnet build $uiProj -c $Configuration -p:Platform=$Platform
if (-not (Test-Path $uiExe)) { throw "UI exe not found: $uiExe" }

# 3) Build Hook (if MSBuild available)
$msbuild = Find-MSBuild
if (-not $msbuild -and $InstallBuildTools) {
  Install-BuildTools
  $msbuild = Find-MSBuild
}
if ($msbuild) {
  Write-Host "Building Hook ($Configuration|$Platform)..." -ForegroundColor Cyan
  & $msbuild $hookProj /p:Configuration=$Configuration /p:Platform=$Platform /m
  if (-not (Test-Path $hookExe)) { Write-Warning "Hook exe not found after build: $hookExe" }
} else {
  Write-Warning 'MSBuild not found. Skipping Hook build. Installer may still build without it.'
}

# 4) Optional: sign binaries before packaging
if ($Sign) {
  $signtool = Find-SignTool
  if (-not $signtool) { throw 'signtool.exe not found. Install Windows 10/11 SDK or Visual Studio Signing tools.' }
  Sign-File -File $uiExe -SignToolPath $signtool -PfxPath $PfxPath -PfxPassword $PfxPassword -CertThumbprint $CertThumbprint -UseMachineStore:$UseMachineStore -TimestampUrl $TimestampUrl
  if (Test-Path $hookExe) {
    Sign-File -File $hookExe -SignToolPath $signtool -PfxPath $PfxPath -PfxPassword $PfxPassword -CertThumbprint $CertThumbprint -UseMachineStore:$UseMachineStore -TimestampUrl $TimestampUrl
  }
}

# 5) Compile installer
$iscc = Find-ISCC
if (-not $iscc -and $InstallInno) {
  Install-Inno
  $iscc = Find-ISCC
}
if (-not $iscc) { throw 'Inno Setup compiler (ISCC.exe) not found. Install Inno Setup 6.' }
Write-Host 'Compiling Inno Setup installer...' -ForegroundColor Cyan
& $iscc $iss

# Find latest installer
$installer = Get-ChildItem (Join-Path $PSScriptRoot 'LittleBigMouse.Setup') -Filter 'LittleBigMouse_*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $installer) { throw 'Installer not found after compile.' }

# 6) Optional: sign installer
if ($Sign) {
  $signtool = $signtool ?? (Find-SignTool)
  if (-not $signtool) { throw 'signtool.exe not found for signing installer.' }
  Sign-File -File $installer.FullName -SignToolPath $signtool -PfxPath $PfxPath -PfxPassword $PfxPassword -CertThumbprint $CertThumbprint -UseMachineStore:$UseMachineStore -TimestampUrl $TimestampUrl
}

Write-Host 'Build complete.' -ForegroundColor Green
Write-Host ("UI:       {0}" -f $uiExe)
if (Test-Path $hookExe) { Write-Host ("Hook:     {0}" -f $hookExe) }
Write-Host ("Installer: {0}" -f $installer.FullName)

