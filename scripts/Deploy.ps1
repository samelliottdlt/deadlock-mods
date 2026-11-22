#Requires -Version 7
<#
.SYNOPSIS
  One command to (re)install everything described in loadout.json.
.DESCRIPTION
  Builds every overlay listed in loadout.json, then runs Install-Pack.ps1 with the pack, the built
  overlays (highest priority) and any extra VPKs. Re-run it after a Deadlock update resets
  gameinfo.gi, after downloading a new pack, or after editing an overlay.
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
$cfg = Get-Content $Loadout -Raw | ConvertFrom-Json
function Resolve-RepoPath([string]$p) { if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p } }

$whatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false  # overlays are built into build\ even on a dry run
$overlays = foreach ($o in @($cfg.overlays)) {
    if (-not $o) { continue }
    & (Join-Path $PSScriptRoot 'Build-Overlay.ps1') -Name $o | Out-Host
    Join-Path $root "build\$o.vpk"
}
$extra = @($cfg.extra) | Where-Object { $_ } | ForEach-Object { Resolve-RepoPath $_ }
$keep = @($cfg.keepSearchPaths) | Where-Object { $_ }

& (Join-Path $PSScriptRoot 'Install-Pack.ps1') -Pack (Resolve-RepoPath $cfg.pack) -Overlay @($overlays) -Extra @($extra) -KeepSearchPath @($keep) -WhatIf:$whatIf
