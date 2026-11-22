#Requires -Version 7
<#
.SYNOPSIS
  One entry point for the everyday jobs: install, update, plain CompLock, remove, undo, add/enable mods.
.DESCRIPTION
  A thin front end over the other scripts (they still do the work and make the backups). Run it as
  `.\mods <command>` from the repo root (mods.cmd), or `pwsh scripts\Mods.ps1 <command>`.
  `.\mods help` lists the commands. Commands that change the game accept -WhatIf.
.EXAMPLE
  .\mods status
.EXAMPLE
  .\mods complock -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Target,
    [string]$Name
)
$ErrorActionPreference = 'Stop'
# -WhatIf is passed on explicitly; left set, it would also dry-run the downloads and builds the scripts do into the repo.
$DryRun = [bool]$WhatIfPreference
$WhatIfPreference = $false
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force
$root = Get-RepoRoot
$loadoutPath = Join-Path $root 'loadout.json'

function Invoke-Script([string]$Script, [hashtable]$Arguments = @{}) { & (Join-Path $PSScriptRoot "$Script.ps1") @Arguments }
function Get-WhatIfArg { if ($DryRun) { @{ WhatIf = $true } } else { @{} } }
function Test-Proceed([string]$Action) { if ($DryRun) { Write-Host "What if: $Action"; $false } else { $true } }

function Show-Help {
    @'
Usage: .\mods <command> [target] [-WhatIf]

Look
  status              What is installed now (paks, gameinfo.gi health)
  list                What loadout.json installs, and overlays you could enable
  check               Updates available (CompLock, GameBanana mods), overlay merges, audit
  conflicts           Audit the loadout: conflicts, vanilla files Valve changed under the mods
  backups             List backups

Install
  install             Build and install the full loadout (CompLock + overlays + extras)
  update              Update everything, reconcile overlays, audit, install
  complock            Install plain CompLock only (your options, no overlays or extra VPKs)
  remove              Remove all mods: vanilla Deadlock (stock gameinfo.gi)
  undo                Restore the latest backup (each install/remove makes one)
  restore <name>      Restore a specific backup (see: backups)

Change the loadout (then run: .\mods install)
  add <id|url|vpk>    Add a GameBanana mod (id or URL) or a local .vpk as an extra; -Name <name>
  enable <overlay>    Add an overlay from mods\ to the loadout
  disable <name>      Take an overlay or extra out of the loadout (files are kept)
  options [<value>]   Show or change the CompLock options (?pack= value of a Pack Builder link)

Other
  release             Build the release zip in dist\ (publishing: scripts\New-Release.ps1 -Publish)
  setup               Download Source2Viewer-CLI into tools\ (once per machine)

Deadlock must be closed for install, update, complock, remove, undo and restore.
Restart Deadlock afterwards to load the change.
'@
}

function Save-Loadout($Cfg, [string]$Action) {
    if (-not (Test-Proceed "$Action (loadout.json)")) { return }
    Write-JsonFile $loadoutPath $Cfg
    "$Action. Run '.\mods install' to apply it."
}

function Show-Loadout {
    $cfg = Get-Loadout $loadoutPath
    "Pack:      $($cfg['pack'])$(if (-not (Test-Path (Resolve-RepoPath $cfg['pack']))) { '  (not downloaded yet)' })"
    if ($cfg['complock']) { "CompLock:  $($cfg['complock']['options'])" }
    ""
    "Overlays (win conflicts, in load order):"
    $on = @($cfg['overlays'] | Where-Object { $_ })
    if (-not $on) { "  (none)" }
    foreach ($n in $on) { "  {0,-26} {1}" -f $n, (Get-Overlay $n).Meta['description'] }
    ""
    "Extra VPKs (lose conflicts):"
    $extra = @($cfg['extra'] | Where-Object { $_ })
    if (-not $extra) { "  (none)" }
    foreach ($e in $extra) {
        $p = Resolve-RepoPath $e
        $src = Read-JsonFile "$p.source.json"
        "  {0,-26} {1}{2}" -f $e, $(if ($src) { "$($src['name']) by $($src['author'])" }), $(if (-not (Test-Path $p)) { '  (MISSING)' })
    }
    $off = @(Get-ChildItem (Join-Path $root 'mods') -Directory | Where-Object { (Test-Path "$($_.FullName)\mod.json") -and $on -notcontains $_.Name })
    if ($off) {
        ""
        "Available overlays (not enabled):"
        foreach ($d in $off) { "  {0,-26} {1}" -f $d.Name, (Get-Overlay $d.Name).Meta['description'] }
    }
}

function Install-PlainCompLock {
    <# The CompLock pack exactly as built by Update-CompLock.ps1, without overlays, extras or kept search paths. #>
    $cfg = Get-Loadout $loadoutPath
    if (-not $cfg['pack']) { throw "loadout.json has no 'pack'." }
    $pack = Resolve-RepoPath $cfg['pack']
    if (-not (Test-Path $pack)) {
        if (-not $cfg['complock']) { throw "Pack $($cfg['pack']) is missing." }
        Invoke-Script 'Update-CompLock' @{ Loadout = $loadoutPath } | Out-Host
    }
    $credits = @(Get-LoadoutCredits $loadoutPath | Where-Object Part -EQ 'CompLock')
    $header = @(
        "CompLock only (no deadlock-mods overlays or extra VPKs) - installed $((Get-Date).ToString('d MMM yyyy', [Globalization.CultureInfo]::InvariantCulture))"
        "Made with $(Get-RepoUrl)"
        ''
        'Credits - all mods belong to their authors:'
        '  CompLock by HoppCX and jcStani - https://deadlockconfig.com'
        $credits | ForEach-Object { "    $($_.Name)$(if ($_.By) { " - by $($_.By)" })$(if ($_.Date) { " ($($_.Date))" })" }
    ) -join "`n"
    Invoke-Script 'Install-Pack' (@{ Pack = $pack; Header = $header } + (Get-WhatIfArg))
    if (-not $DryRun) { ""; "Installed plain CompLock. '.\mods install' brings back the full loadout. Restart Deadlock to load it." }
}

function Add-ExtraMod([string]$Source) {
    if (-not $Source) { throw "Usage: .\mods add <gamebanana id|url|path to .vpk> [-Name <name>]" }
    $cfg = Get-Loadout $loadoutPath
    $id = if ($Source -match '^\d+$') { [int]$Source } elseif ($Source -match 'gamebanana\.com/mods/(\d+)') { [int]$Matches[1] }
    if ($id) {
        $mod = Get-GameBananaMod $id
        $slug = if ($Name) { $Name } else { ($mod.Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
        "$($mod.Name) by $($mod.Author) ($($mod.Url))"
        if ($mod.License) { "  License: $($mod.License)" }
    } else {
        if (-not (Test-Path $Source -PathType Leaf) -or $Source -notmatch '\.vpk$') { throw "$Source is not a GameBanana id/URL or an existing .vpk file." }
        $slug = if ($Name) { $Name } else { [IO.Path]::GetFileNameWithoutExtension($Source) -replace '_dir$', '' }
    }
    $rel = "mods-bin/$slug.vpk"
    $dest = Resolve-RepoPath $rel
    if (@($cfg['extra']) -contains $rel) { throw "$rel is already in the loadout. Pick another -Name, or 'disable' it first." }
    if (-not (Test-Proceed "Save $rel and add it to the loadout")) { return }
    if ($id) { $f = Save-GameBananaVpk $id $dest; "  Downloaded $($f.Name) -> $rel" }
    else { New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null; Copy-Item $Source $dest -Force; "  Copied -> $rel" }
    $cfg['extra'] = @(@($cfg['extra'] | Where-Object { $_ }) + $rel)
    Save-Loadout $cfg "Added $rel to the loadout's extra VPKs"
}

function Enable-Overlay([string]$Overlay) {
    if (-not $Overlay) { throw "Usage: .\mods enable <overlay>  (see: .\mods list)" }
    $null = Get-Overlay $Overlay
    $cfg = Get-Loadout $loadoutPath
    $on = @($cfg['overlays'] | Where-Object { $_ })
    if ($on -contains $Overlay) { "$Overlay is already enabled."; return }
    $cfg['overlays'] = @($on + $Overlay)
    Save-Loadout $cfg "Enabled overlay $Overlay"
}

function Disable-Mod([string]$Mod) {
    if (-not $Mod) { throw "Usage: .\mods disable <overlay|extra>  (see: .\mods list)" }
    $cfg = Get-Loadout $loadoutPath
    $on = @($cfg['overlays'] | Where-Object { $_ })
    if ($on -contains $Mod) {
        $cfg['overlays'] = @($on | Where-Object { $_ -ne $Mod })
        return Save-Loadout $cfg "Disabled overlay $Mod"
    }
    $extra = @($cfg['extra'] | Where-Object { $_ })
    $hit = @($extra | Where-Object { $_ -eq $Mod -or [IO.Path]::GetFileNameWithoutExtension($_) -eq $Mod })
    if ($hit.Count -ne 1) { throw "'$Mod' is not an enabled overlay or extra VPK (see: .\mods list)." }
    $cfg['extra'] = @($extra | Where-Object { $_ -ne $hit[0] })
    Save-Loadout $cfg "Removed $($hit[0]) from the loadout (the file stays in mods-bin\)"
}

try {
    switch ($Command.ToLowerInvariant()) {
        { $_ -in 'help', '-h', '--help', '/?' } { Show-Help }
        'status' { Invoke-Script 'Get-ModStatus' }
        'list' { Show-Loadout }
        'check' { Invoke-Script 'Update-Mods' @{ Check = $true } }
        'conflicts' { Invoke-Script 'Find-ModConflicts' @{ Loadout = $true; Vanilla = $true } }
        'backups' { Invoke-Script 'Restore-Backup' }
        { $_ -in 'install', 'deploy' } { Invoke-Script 'Deploy' (Get-WhatIfArg) }
        'update' {
            if ($DryRun) { Invoke-Script 'Update-Mods' @{ Check = $true } }
            else { Invoke-Script 'Update-Mods' @{ Deploy = $true } }
        }
        { $_ -in 'complock', 'vanilla-complock' } { Install-PlainCompLock }
        { $_ -in 'remove', 'uninstall', 'vanilla' } { Invoke-Script 'Remove-Mods' (Get-WhatIfArg) }
        'undo' { Invoke-Script 'Restore-Backup' (@{ Name = 'latest' } + (Get-WhatIfArg)) }
        'restore' {
            if (-not $Target) { Invoke-Script 'Restore-Backup'; ""; "Usage: .\mods restore <name|latest>"; break }
            Invoke-Script 'Restore-Backup' (@{ Name = $Target } + (Get-WhatIfArg))
        }
        'add' { Add-ExtraMod $Target }
        'enable' { Enable-Overlay $Target }
        'disable' { Disable-Mod $Target }
        'options' {
            if (-not $Target) { $cl = (Get-Loadout $loadoutPath)['complock']; "CompLock options: $(if ($cl) { $cl['options'] } else { '(none; pack managed by hand)' })"; break }
            if (-not (Test-Proceed "Set CompLock options to '$Target' and rebuild packs\complock")) { break }
            Invoke-Script 'Update-CompLock' @{ Options = $Target }
            ""; "Run '.\mods install' to apply them."
        }
        'release' { Invoke-Script 'New-Release' }
        'setup' { Invoke-Script 'Setup-Tools' }
        default { Write-Host "Unknown command '$Command'." -ForegroundColor Red; Show-Help; exit 2 }
    }
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
