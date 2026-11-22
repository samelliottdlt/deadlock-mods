#Requires -Version 7
<#
.SYNOPSIS
  Shows what is installed: game build, gameinfo.gi health, loaded paks and their titles.
.EXAMPLE
  pwsh scripts\Get-ModStatus.ps1
#>
param()
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$citadel = Get-CitadelPath
$gi = Join-Path $citadel 'gameinfo.gi'
"Deadlock:   $(Get-DeadlockPath)"
"Build:      $(Get-GameBuild)"
"Running:    $(Test-DeadlockRunning)"
""
"gameinfo.gi SearchPaths:"
Get-GameInfoSearchPaths $gi | ForEach-Object { "  {0,-18} {1}" -f $_.Key, $_.Value }
if (-not (Test-AddonsSearchPath $gi)) { Write-Warning 'citadel/addons is NOT a search path: mods will not load (a game update or Verify probably reset gameinfo.gi). Re-run Install-Pack.ps1.' }
$stock = Get-StockGameInfo
if ($stock) {
    $same = (Get-PGIVersion $gi) -eq (Get-PGIVersion $stock.FullName)
    "PGIVersion: $(if ($same) { 'matches' } else { 'DIFFERS from' }) stock $($stock.Name)"
    if ($stock.BaseName -ne "gameinfo-$(Get-GameBuild)") { "            (no stock copy for the current build yet)" }
}
""
"Loaded paks (pak01 wins conflicts):"
$paks = @(Get-AddonPaks)
if (-not $paks) { "  (none)" }
foreach ($p in $paks) {
    $size = (Get-PakChunks $p | Measure-Object Length -Sum).Sum
    "  {0}  {1,8:N1} MB  {2}" -f $p.Name, ($size / 1MB), (Get-AddonTitle $p.FullName)
}
$ignored = Get-ChildItem (Get-AddonsPath) -File -Filter *.vpk -ErrorAction SilentlyContinue | Where-Object Name -NotMatch '^pak(0[1-9]|[1-9]\d)_(dir|\d{3})\.vpk$'
if ($ignored) { ""; "Ignored by the game (wrong name):"; $ignored | ForEach-Object { "  $($_.Name)" } }
