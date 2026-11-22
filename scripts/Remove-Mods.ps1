#Requires -Version 7
<#
.SYNOPSIS
  Removes all installed paks (backed up first) and puts back Valve's gameinfo.gi when a stock copy
  for the current build is available.
.EXAMPLE
  pwsh scripts\Remove-Mods.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force
Assert-DeadlockClosed
if (-not $PSCmdlet.ShouldProcess((Get-CitadelPath), 'Remove all mods')) { return }

Save-StockGameInfo
$backup = Backup-ModState 'Remove-Mods'
"Backed up -> $backup"
$stock = Join-Path (Get-RepoRoot) "backups\stock\gameinfo-$(Get-GameBuild).gi"
if (Test-Path $stock) {
    Copy-Item $stock (Join-Path (Get-CitadelPath) 'gameinfo.gi')
    "Restored stock gameinfo.gi (build $(Get-GameBuild))."
} else {
    Write-Warning 'No stock gameinfo.gi for this build. In Steam: Deadlock > Properties > Installed Files > Verify integrity.'
}
