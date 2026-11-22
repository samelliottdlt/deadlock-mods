#Requires -Version 7
<#
.SYNOPSIS
  Lists files that more than one pak provides, and which pak wins (the lowest number).
.EXAMPLE
  pwsh scripts\Find-ModConflicts.ps1
.EXAMPLE
  pwsh scripts\Find-ModConflicts.ps1 -Vpk build\mine.vpk,packs\complock\game\citadel\addons\pak01_dir.vpk
#>
param([string[]]$Vpk)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$files = if ($Vpk) { $Vpk -split ',' | Where-Object { $_ } | ForEach-Object { Get-Item (Resolve-Path $_) } } else { Get-AddonPaks }
$exe = Get-S2V
$owners = @{}
foreach ($f in $files) {
    foreach ($line in & $exe -i $f.FullName -l 2>$null) {
        $path = ($line -split ' ')[0]
        if ($path -in 'addoninfo.txt', 'modinfo.json') { continue }
        if (-not $owners[$path]) { $owners[$path] = [Collections.Generic.List[string]]::new() }
        $owners[$path].Add($f.Name)
    }
}
$conflicts = $owners.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | Sort-Object Name
if (-not $conflicts) { 'No conflicts.'; return }
foreach ($c in $conflicts) { "{0}`n    wins: {1}   shadowed: {2}" -f $c.Name, $c.Value[0], ($c.Value[1..($c.Value.Count - 1)] -join ', ') }
"$(@($conflicts).Count) conflicting files."
