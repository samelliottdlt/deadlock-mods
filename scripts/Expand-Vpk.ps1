#Requires -Version 7
<#
.SYNOPSIS
  Unpacks a VPK into an editable workspace.
.DESCRIPTION
  Creates:
    <Out>\compiled\   the files exactly as stored in the VPK (used as build templates)
    <Out>\src\        decompiled, human-readable copies (.xml/.css/.js/.png/...) - edit these
    <Out>\workspace.json  bookkeeping for Build-Vpk.ps1 (source VPK, hashes of the pristine sources)
  Use -Game to pull files from Deadlock's own pak01 instead of a mod (always pass -Filter then).
.EXAMPLE
  pwsh scripts\Expand-Vpk.ps1 -Vpk packs\complock\game\citadel\addons\pak01_dir.vpk -Out work\hudpp
.EXAMPLE
  pwsh scripts\Expand-Vpk.ps1 -Game -Filter panorama/layout/hud.vxml_c,panorama/styles/hud.vcss_c -Out work\vanilla-hud
#>
param(
    [string]$Vpk,
    [switch]$Game,
    [Parameter(Mandatory)][string]$Out,
    [string[]]$Filter,
    [switch]$Force
)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

if ($Game) { $Vpk = Join-Path (Get-CitadelPath) 'pak01_dir.vpk'; if (-not $Filter) { throw '-Game needs -Filter (pak01 is several GB).' } }
if (-not $Vpk) { throw 'Pass -Vpk <file> or -Game.' }
$Vpk = (Resolve-Path $Vpk).Path
$Out = [IO.Path]::GetFullPath($Out)
if ((Test-Path $Out) -and -not $Force) { throw "$Out already exists (use -Force to overwrite)." }
Remove-Item -Recurse -Force $Out -ErrorAction SilentlyContinue

$filterArgs = if ($Filter) { @('-f', ($Filter -join ',')) } else { @() }
Invoke-S2V -i $Vpk -o "$Out\compiled\" -q @filterArgs | Out-Null
Invoke-S2V -i $Vpk -o "$Out\src\" -d -q @filterArgs | Out-Null

# The decompiler only writes the readable form; keep plain files (addoninfo.txt etc.) too.
Get-ChildItem -Recurse -File "$Out\compiled" | Where-Object Extension -NotMatch '_c$' | ForEach-Object {
    $dest = Join-Path "$Out\src" $_.FullName.Substring("$Out\compiled".Length + 1)
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null; Copy-Item $_.FullName $dest }
}

$hashes = [ordered]@{}
Get-ChildItem -Recurse -File "$Out\src" | Sort-Object FullName | ForEach-Object {
    $hashes[$_.FullName.Substring("$Out\src".Length + 1).Replace('\', '/')] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
}
[ordered]@{ sourceVpk = $Vpk; expandedAt = (Get-Date).ToString('o'); pristine = $hashes } |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Out 'workspace.json')

$n = (Get-ChildItem -Recurse -File "$Out\compiled").Count
"Expanded $n files from $Vpk"
"  edit:      $Out\src"
"  originals: $Out\compiled"
