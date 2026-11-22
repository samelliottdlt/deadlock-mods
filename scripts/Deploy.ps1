#Requires -Version 7
<#
.SYNOPSIS
  One command to (re)install everything described in loadout.json.
.DESCRIPTION
  Downloads the CompLock pack first if loadout.json has complock options and the pack folder is
  missing (fresh clone), builds (and reconciles) every overlay, then runs Install-Pack.ps1 with the
  pack, the built overlays (highest priority) and any extra VPKs. mods.txt in the game's addons
  folder gets the version date and credits. After installing, the audit runs and its vanilla
  baseline is saved (state\), so the next Update-Mods.ps1 can tell what Valve changed since.
  Re-run it after a Deadlock update resets gameinfo.gi, after updating a pack, or after editing an overlay.
.EXAMPLE
  pwsh scripts\Deploy.ps1
.EXAMPLE
  pwsh scripts\Deploy.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$Loadout)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force
$root = Get-RepoRoot
if (-not $Loadout) { $Loadout = Join-Path $root 'loadout.json' }
$cfg = Get-Loadout $Loadout

$whatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false  # overlays are built into build\ even on a dry run
$pack = Resolve-RepoPath $cfg['pack']
if (-not (Test-Path $pack) -and $cfg['complock']) {
    & (Join-Path $PSScriptRoot 'Update-CompLock.ps1') -Loadout $Loadout | Out-Host
}
$overlays = foreach ($o in @($cfg['overlays'])) {
    if (-not $o) { continue }
    & (Join-Path $PSScriptRoot 'Build-Overlay.ps1') -Name $o -Loadout $Loadout | Out-Host
    Join-Path $root "build\$o.vpk"
}
$extra = @($cfg['extra']) | Where-Object { $_ } | ForEach-Object { Resolve-RepoPath $_ }
$keep = @($cfg['keepSearchPaths']) | Where-Object { $_ }
$version = Get-LoadoutVersion $Loadout
$header = New-LoadoutHeader $Loadout $version

& (Join-Path $PSScriptRoot 'Install-Pack.ps1') -Pack $pack -Overlay @($overlays) -Extra @($extra) -KeepSearchPath @($keep) -Header $header -WhatIf:$whatIf
if ($whatIf) { return }
""
"Audit:"
& (Join-Path $PSScriptRoot 'Find-ModConflicts.ps1') -Loadout -LoadoutPath $Loadout -Vanilla -SaveBaseline
Write-JsonFile (Get-StatePath 'deploy.json') ([ordered]@{
    deployedAt = (Get-Date).ToString('o'); updatedOn = $version.UpdatedOn; gameBuild = Get-GameBuild
    complock = $(if ($version.CompLock) { $version.CompLock['updatedOn'] }); overlays = @($cfg['overlays']); extra = @($cfg['extra'])
})
""
"Deployed: Updated On $($version.Display). Restart Deadlock to load it."
