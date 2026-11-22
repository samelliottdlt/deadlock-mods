#Requires -Version 7
<#
.SYNOPSIS
  Downloads Source2Viewer-CLI (extract, decompile and create VPKs) into tools\s2v.
.EXAMPLE
  pwsh scripts\Setup-Tools.ps1
#>
param([switch]$Force)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$tools = Join-Path (Get-RepoRoot) 'tools'
$exe = Join-Path $tools 's2v\Source2Viewer-CLI.exe'
if ((Test-Path $exe) -and -not $Force) { "Source2Viewer-CLI already installed: $exe"; & $exe --version; return }

$release = Invoke-RestMethod 'https://api.github.com/repos/ValveResourceFormat/ValveResourceFormat/releases/latest'
$asset = $release.assets | Where-Object name -EQ 'cli-windows-x64.zip'
if (-not $asset) { throw "cli-windows-x64.zip not found in release $($release.tag_name)" }
New-Item -ItemType Directory -Force $tools | Out-Null
$zip = Join-Path $tools 's2v.zip'
"Downloading Source2Viewer-CLI $($release.tag_name)..."
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest $asset.browser_download_url -OutFile $zip
Remove-Item -Recurse -Force (Join-Path $tools 's2v') -ErrorAction SilentlyContinue
Expand-Archive $zip -DestinationPath (Join-Path $tools 's2v')
Remove-Item $zip
"Installed: $exe"
