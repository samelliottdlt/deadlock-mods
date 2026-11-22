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
  -Header is written at the top of addons\mods.txt (Deploy.ps1 puts the version date and credits there).
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
    [string]$Header,
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
    $packCitadel = Get-PackCitadel $Pack
    $packGameInfo = Join-Path $packCitadel 'gameinfo.gi'
    $useGameInfo = (Test-Path $packGameInfo) -and -not $NoGameInfo
    $plan = New-PakPlan $packCitadel $Overlay $Extra

    "Install plan (pak01 wins conflicts):"
    foreach ($p in $plan) { "  $($p.Pak)  <- $($p.Label)" }
    "  gameinfo.gi        <- " + $(if ($useGameInfo) { $packGameInfo } else { 'current file (addons path ensured)' })
    if (-not $PSCmdlet.ShouldProcess($citadel, 'Install pack')) { return }

    Save-StockGameInfo
    $currentGameInfo = Get-Content (Join-Path $citadel 'gameinfo.gi') -Raw
    $backup = Backup-ModState "Install-Pack $Pack"
    "Backed up previous state -> $backup"

    Copy-PakPlan $plan $addons
    $txt = @()
    if ($Header) { $txt += $Header.TrimEnd() }
    if (Test-Path "$packCitadel\addons\mods.txt") { $txt += (Get-Content "$packCitadel\addons\mods.txt" -Raw).TrimEnd() }
    if ($Overlay -or $Extra -or $Header) { $txt += "Installed by deadlock-mods Install-Pack.ps1; pak numbers were reassigned:`n" + (($plan | ForEach-Object { "  $($_.Pak)  $($_.Label)" }) -join "`n") }
    if ($txt) { Set-Content "$addons\mods.txt" ($txt -join "`n`n") }

    $text = Add-GameInfoSearchPaths $(if ($useGameInfo) { Get-Content $packGameInfo -Raw } else { $currentGameInfo }) $KeepSearchPath
    Set-GameInfoText (Join-Path $citadel 'gameinfo.gi') $text
    if (-not (Test-AddonsSearchPath (Join-Path $citadel 'gameinfo.gi'))) { throw 'gameinfo.gi has no citadel/addons search path after install.' }

    $stock = Get-StockGameInfo
    $pgi = Get-PGIVersion (Join-Path $citadel 'gameinfo.gi')
    if ($stock -and (Get-PGIVersion $stock.FullName) -ne $pgi) {
        Write-Warning "PGIVersion differs from Valve's stock gameinfo.gi ($($stock.Name)). The pack was probably made for another game build; matchmaking may refuse to start. Get a fresh pack for this build (Update-CompLock.ps1)."
    }
    $dropped = Get-GameInfoSearchPaths (Join-Path $backup 'gameinfo.gi') | Where-Object { $_.Key -eq 'Game' -and $_.Value -like 'citadel/*' -and $_.Value -ne 'citadel/addons' } |
        Where-Object { $text -notmatch "(?m)^\s*Game\s+$([regex]::Escape($_.Value))\s*$" }
    foreach ($d in $dropped) { Write-Warning "Search path 'Game $($d.Value)' from the previous gameinfo.gi is no longer present (pass -KeepSearchPath $($d.Value) to keep it)." }
    "Installed $($plan.Count) paks for game build $(Get-GameBuild). Launch Deadlock to apply."
} finally {
    if ($tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
