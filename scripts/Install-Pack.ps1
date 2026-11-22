#Requires -Version 7
<#
.SYNOPSIS
  Installs a mod pack (e.g. CompLock from deadlockconfig.com) plus optional extra VPKs.
.DESCRIPTION
  -Pack is a folder or .zip laid out like the game (game\citadel\gameinfo.gi, game\citadel\addons\pakNN_dir.vpk).
  Load order (lower number = higher priority, it wins conflicts):
    1. -Overlay VPKs, in the order given  (your customizations that patch files of the pack)
    2. the pack's paks, in their original order
    3. -Extra VPKs, in the order given    (unrelated mods; lose any conflict)
  Before anything changes, the current paks, gameinfo.gi and mods.txt go to backups\<timestamp>\
  (undo with Restore-Backup.ps1). Valve's stock gameinfo.gi is saved once per game build.
  -KeepSearchPath keeps extra "Game <path>" lines (e.g. citadel/deadworks_addons/vpks) from the
  current gameinfo.gi; they are inserted above citadel/addons.
.EXAMPLE
  pwsh scripts\Install-Pack.ps1 -Pack "$HOME\Downloads\CompLock-pack.zip"
.EXAMPLE
  pwsh scripts\Install-Pack.ps1 -Pack packs\complock -Overlay build\hudpp-tweaks.vpk -Extra mods\radio.vpk
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Pack,
    [string[]]$Overlay = @(),
    [string[]]$Extra = @(),
    [string[]]$KeepSearchPath = @(),
    [switch]$NoGameInfo
)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force
Assert-DeadlockClosed
# Values arrive comma-joined when the script is run via `pwsh -File`.
$Overlay = @($Overlay -split ',' | Where-Object { $_ })
$Extra = @($Extra -split ',' | Where-Object { $_ })
$KeepSearchPath = @($KeepSearchPath -split ',' | Where-Object { $_ })

$citadel = Get-CitadelPath
$addons = Get-AddonsPath
$tmp = $null
try {
    $Pack = (Resolve-Path $Pack).Path
    if ($Pack -match '\.zip$') {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlpack_" + [guid]::NewGuid())
        Expand-Archive $Pack -DestinationPath $tmp
        $Pack = $tmp
    }
    $packCitadel = @("$Pack\game\citadel", "$Pack\citadel", $Pack) | Where-Object { Test-Path "$_\addons" } | Select-Object -First 1
    if (-not $packCitadel) { throw "Can't find an addons folder in $Pack (expected game\citadel\addons)." }
    $packPaks = @(Get-ChildItem "$packCitadel\addons" -File | Where-Object Name -Match '^pak\d\d_dir\.vpk$' | Sort-Object Name)
    $packGameInfo = Join-Path $packCitadel 'gameinfo.gi'
    $useGameInfo = (Test-Path $packGameInfo) -and -not $NoGameInfo

    # Build the plan: list of (source dir-vpk, chunk files, label).
    $plan = [Collections.Generic.List[object]]::new()
    foreach ($o in $Overlay) { $f = Get-Item (Resolve-Path $o); $plan.Add([pscustomobject]@{ Files = @($f); Label = "overlay: $($f.Name)" }) }
    foreach ($p in $packPaks) { $plan.Add([pscustomobject]@{ Files = Get-PakChunks $p; Label = "pack: $($p.Name)" }) }
    foreach ($e in $Extra) { $f = Get-Item (Resolve-Path $e); $plan.Add([pscustomobject]@{ Files = @($f); Label = "extra: $($f.Name)" }) }
    if ($plan.Count -gt 99) { throw "Too many paks ($($plan.Count)); the game loads pak01-pak99 only." }
    foreach ($item in $plan) {
        if ($item.Files[0].Name -notmatch '_dir\.vpk$' -and $item.Files.Count -gt 1) { throw "Chunked VPK must be named *_dir.vpk: $($item.Files[0].FullName)" }
    }

    "Install plan (pak01 wins conflicts):"
    for ($i = 0; $i -lt $plan.Count; $i++) { "  pak{0:d2}_dir.vpk  <- {1}" -f ($i + 1), $plan[$i].Label }
    "  gameinfo.gi        <- " + $(if ($useGameInfo) { $packGameInfo } else { 'current file (addons path ensured)' })
    if (-not $PSCmdlet.ShouldProcess($citadel, 'Install pack')) { return }

    Save-StockGameInfo
    $currentGameInfo = Get-Content (Join-Path $citadel 'gameinfo.gi') -Raw
    $backup = Backup-ModState "Install-Pack $Pack"
    "Backed up previous state -> $backup"

    New-Item -ItemType Directory -Force $addons | Out-Null
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $n = '{0:d2}' -f ($i + 1)
        foreach ($f in $plan[$i].Files) {
            $name = if ($f.Name -match '^pak\d\d_(\d{3})\.vpk$') { "pak${n}_$($Matches[1]).vpk" } else { "pak${n}_dir.vpk" }
            Copy-Item $f.FullName (Join-Path $addons $name)
        }
    }
    if (Test-Path "$packCitadel\addons\mods.txt") {
        $note = if ($Overlay -or $Extra) { "`n`nInstalled by deadlock-mods Install-Pack.ps1; pak numbers were reassigned:`n" + (($plan | ForEach-Object -Begin { $k = 0 } -Process { $k++; '  pak{0:d2}_dir.vpk  {1}' -f $k, $_.Label }) -join "`n") } else { '' }
        Set-Content "$addons\mods.txt" ((Get-Content "$packCitadel\addons\mods.txt" -Raw).TrimEnd() + $note)
    }

    $text = if ($useGameInfo) { Get-Content $packGameInfo -Raw } else { $currentGameInfo }
    if (-not ($text -match '(?m)^\s*Game\s+citadel/addons\s*$')) {
        # Insert the addons path right above the first "Game citadel" line.
        $text = [regex]::Replace($text, '(?m)^(\s*)(Game\s+citadel\s*)$', '$1Game				citadel/addons' + "`n" + '$1$2', 1)
    }
    foreach ($sp in $KeepSearchPath) {
        if ($text -notmatch "(?m)^\s*Game\s+$([regex]::Escape($sp))\s*$") {
            $text = [regex]::Replace($text, '(?m)^(\s*)(Game\s+citadel/addons\s*)$', ('$1Game				' + $sp + "`n" + '$1$2'), 1)
        }
    }
    Set-GameInfoText (Join-Path $citadel 'gameinfo.gi') $text
    if (-not (Test-AddonsSearchPath (Join-Path $citadel 'gameinfo.gi'))) { throw 'gameinfo.gi has no citadel/addons search path after install.' }

    $stock = Get-StockGameInfo
    $pgi = Get-PGIVersion (Join-Path $citadel 'gameinfo.gi')
    if ($stock -and (Get-PGIVersion $stock.FullName) -ne $pgi) {
        Write-Warning "PGIVersion differs from Valve's stock gameinfo.gi ($($stock.Name)). The pack was probably made for another game build; matchmaking may refuse to start. Get a fresh pack for this build."
    }
    $dropped = Get-GameInfoSearchPaths (Join-Path $backup 'gameinfo.gi') | Where-Object { $_.Key -eq 'Game' -and $_.Value -like 'citadel/*' -and $_.Value -ne 'citadel/addons' } |
        Where-Object { $text -notmatch "(?m)^\s*Game\s+$([regex]::Escape($_.Value))\s*$" }
    foreach ($d in $dropped) { Write-Warning "Search path 'Game $($d.Value)' from the previous gameinfo.gi is no longer present (pass -KeepSearchPath $($d.Value) to keep it)." }
    "Installed $($plan.Count) paks for game build $(Get-GameBuild). Launch Deadlock to apply."
} finally {
    if ($tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
