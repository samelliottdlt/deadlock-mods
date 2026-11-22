#Requires -Version 7
<#
.SYNOPSIS
  Starts a customization ("overlay") of a mod or of the base game, or adds files to one.
.DESCRIPTION
  Creates mods\<Name>\mod.json and puts the decompiled source of each -File in two local folders:
    mods\<Name>\base\   the pristine copy (what the mod ships)
    mods\<Name>\src\    your working copy: edit these
  Both are gitignored. Build-Overlay.ps1 compiles src\ and saves your edits as changes.patch (a
  diff against base\), which is what git tracks. That keeps third-party files out of the repo and
  lets an update of the base mod be merged with your edits (3-way merge).
  -Base is a VPK path (relative to the repo or absolute) or "game" for Deadlock's own pak01.
  -GameBanana <id> downloads the mod's newest file into mods-bin\<Name>.vpk and uses it as base;
  it is re-downloaded automatically on a new machine and checked for updates by Update-Mods.ps1.
  -File takes compiled paths as listed by `Source2Viewer-CLI -l` (panorama/styles/x.vcss_c) or source
  names (panorama/styles/x.css). A file that isn't in the base becomes a new file of the overlay.
  -Full builds a complete replacement of the base VPK (the base's other files included) instead of a
  small pak that only holds your changed files; use it for standalone mods you load instead of the original.
.EXAMPLE
  pwsh scripts\New-Overlay.ps1 -Name hudpp-tweaks -Base packs\complock\game\citadel\addons\pak01_dir.vpk -File panorama/styles/hudpp_menu.css
.EXAMPLE
  pwsh scripts\New-Overlay.ps1 -Name my-tracker -GameBanana 692472 -Full -File panorama/scripts/buffs_log.js
#>
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Base,
    [int]$GameBanana,
    [string[]]$File = @(),
    [string]$Description,
    [switch]$Full
)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$dir = Join-Path (Get-RepoRoot) "mods\$Name"
$metaPath = Join-Path $dir 'mod.json'
$meta = if (Test-Path $metaPath) { Read-JsonFile $metaPath } else { [ordered]@{ description = ''; base = $null; build = 'changed'; files = @() } }
if ($GameBanana) {
    $gb = Get-GameBananaMod $GameBanana
    $meta['base'] = "mods-bin/$Name.vpk"
    $meta['source'] = [ordered]@{ gamebanana = $GameBanana }
    $meta['credits'] = @([ordered]@{ name = $gb.Name; by = $gb.Author; url = $gb.Url; license = $gb.License })
    if (-not $meta['description']) { $meta['description'] = "Changes to $($gb.Name) by $($gb.Author)" }
    $dest = Resolve-RepoPath $meta['base']
    if (-not (Test-Path $dest)) { $f = Save-GameBananaVpk $GameBanana $dest; "Downloaded $($gb.Name) ($($f.Name)) -> $dest" }
}
if ($Base) {
    $meta['base'] = if ($Base -eq 'game') { 'game' } else {
        $abs = (Resolve-Path $Base).Path
        $root = (Get-RepoRoot) + '\'
        if ($abs.StartsWith($root, 'OrdinalIgnoreCase')) { $abs.Substring($root.Length).Replace('\', '/') } else { $abs }
    }
}
if (-not $meta['base']) { throw 'Pass -Base <vpk|game> or -GameBanana <id> for a new overlay.' }
if ($Description) { $meta['description'] = $Description }
if ($Full) {
    if ($meta['base'] -eq 'game') { throw '-Full with -Base game would copy all of Deadlock; drop -Full.' }
    $meta['build'] = 'full'
}
New-Item -ItemType Directory -Force $dir | Out-Null
Write-JsonFile $metaPath $meta
$o = Get-Overlay $Name
if ((Test-Path $o.Patch) -and (Get-Item $o.Patch).Length -and -not (Test-Path $o.SrcDir)) {
    throw "mods\$Name\src doesn't exist yet. Run: pwsh scripts\Build-Overlay.ps1 -Name $Name (recreates it from changes.patch), then add files."
}
Initialize-OverlayBaseVpk $o
$listing = Get-VpkListing $o.BaseVpk

$files = [Collections.Generic.List[string]]@($o.Files)
foreach ($f in ($File -split ',' | Where-Object { $_ })) {
    $rel = ConvertTo-SourcePath ($f.Replace('\', '/'))
    $compiled = ConvertTo-CompiledPath $rel
    $src = Join-Path $o.SrcDir $rel
    if (-not $files.Contains($rel)) { $files.Add($rel) }
    if (Test-Path $src) { "exists, kept your copy: src\$rel"; continue }
    if ($listing.ContainsKey($compiled)) {
        Export-VpkSources $o.BaseVpk @($compiled) $o.BaseDir
        Write-Text $src (Read-Text (Join-Path $o.BaseDir $rel))
        "added: mods\$Name\src\$rel"
        if ($rel -match '\.xml$') { Write-Warning "Layouts (.xml) can't be rebuilt by these scripts; keep it as a reference and change panels from JS (docs\panorama.md)." }
    } else {
        Write-Text $src ''
        "new file (not in the base): mods\$Name\src\$rel"
    }
}
$o.Meta['files'] = @($files)
Save-OverlayMeta $o
"Overlay: $dir (base: $($o.Meta['base'])). Edit src\, then: pwsh scripts\Build-Overlay.ps1 -Name $Name"
