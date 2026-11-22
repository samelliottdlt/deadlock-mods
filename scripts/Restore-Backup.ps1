#Requires -Version 7
<#
.SYNOPSIS
  Restores paks + gameinfo.gi from a backup made by Install-Pack / Remove-Mods / Restore-Backup.
.DESCRIPTION
  The current state is backed up first, so a restore can itself be undone.
.EXAMPLE
  pwsh scripts\Restore-Backup.ps1            # lists backups
.EXAMPLE
  pwsh scripts\Restore-Backup.ps1 -Name latest
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$Name)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$root = Join-Path (Get-RepoRoot) 'backups'
$all = @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path "$($_.FullName)\backup.json" } | Sort-Object Name)
if (-not $Name) {
    if (-not $all) { 'No backups yet.'; return }
    foreach ($b in $all) {
        $m = Get-Content "$($b.FullName)\backup.json" -Raw | ConvertFrom-Json
        "{0}  build {1}  {2}" -f $b.Name, $m.gameBuild, $m.reason
        foreach ($p in $m.paks) { "      {0}  {1}" -f $p.file, $p.title }
    }
    return
}
$src = if ($Name -eq 'latest') { $all | Select-Object -Last 1 } else { $all | Where-Object Name -EQ $Name }
if (-not $src) { throw "Backup '$Name' not found in $root" }
Assert-DeadlockClosed
if (-not $PSCmdlet.ShouldProcess((Get-CitadelPath), "Restore $($src.Name)")) { return }

$snapshot = Backup-ModState "Before restoring $($src.Name)"
"Current state backed up -> $snapshot"
$addons = Get-AddonsPath
Get-ChildItem "$($src.FullName)\addons" -File | ForEach-Object { Copy-Item $_.FullName (Join-Path $addons $_.Name) }
Copy-Item "$($src.FullName)\gameinfo.gi" (Join-Path (Get-CitadelPath) 'gameinfo.gi')
"Restored $($src.Name)."
