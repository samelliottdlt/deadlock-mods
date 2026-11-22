#Requires -Version 7
<#
.SYNOPSIS
  Starts a customization ("overlay") of a mod or of the base game.
.DESCRIPTION
  Creates mods\<Name>\mod.json and copies the decompiled source of each -File into mods\<Name>\src
  for you to edit. Only those files are tracked in git; Build-Overlay.ps1 compiles them into a
  small VPK that loads ahead of the base mod and replaces just those files.
  -Base is a VPK path (relative to the repo or absolute) or "game" for Deadlock's own pak01.
  -File takes compiled paths as listed by `Source2Viewer-CLI -l` (e.g. panorama/styles/hudpp_menu.vcss_c)
  or their source names (panorama/styles/hudpp_menu.css). Run again with more -File values to add files.
.EXAMPLE
  pwsh scripts\New-Overlay.ps1 -Name hudpp-tweaks -Base packs\complock\game\citadel\addons\pak01_dir.vpk -File panorama/styles/hudpp_menu.css
#>
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Base,
    [string[]]$File = @()
)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$dir = Join-Path (Get-RepoRoot) "mods\$Name"
$metaPath = Join-Path $dir 'mod.json'
$meta = if (Test-Path $metaPath) { Get-Content $metaPath -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
if ($Base) {
    $rel = if ($Base -eq 'game') { 'game' } else {
        $full = (Resolve-Path $Base).Path
        $root = (Get-RepoRoot) + '\'
        if ($full.StartsWith($root, 'OrdinalIgnoreCase')) { $full.Substring($root.Length) } else { $full }
    }
    $meta['base'] = $rel
}
if (-not $meta['base']) { throw 'Pass -Base <vpk|game> for a new overlay.' }
if (-not $meta['description']) { $meta['description'] = '' }
New-Item -ItemType Directory -Force "$dir\src" | Out-Null
$meta | ConvertTo-Json | Set-Content $metaPath

$basePath = if ($meta['base'] -eq 'game') { Join-Path (Get-CitadelPath) 'pak01_dir.vpk' }
            elseif ([IO.Path]::IsPathRooted($meta['base'])) { $meta['base'] } else { Join-Path (Get-RepoRoot) $meta['base'] }
$map = @{ '.css' = '.vcss_c'; '.js' = '.vjs_c'; '.xml' = '.vxml_c' }
foreach ($f in ($File -split ',' | Where-Object { $_ })) {
    $f = $f.Replace('\', '/')
    $ext = [IO.Path]::GetExtension($f)
    $compiled = if ($map[$ext]) { [IO.Path]::ChangeExtension($f, $map[$ext]) } else { $f }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlnew_" + [guid]::NewGuid())
    try {
        Invoke-S2V -i $basePath -f $compiled -d -o "$tmp\" -q | Out-Null
        $got = Get-ChildItem -Recurse -File $tmp
        if (-not $got) { throw "$compiled not found in $basePath" }
        foreach ($g in $got) {
            $rel = $g.FullName.Substring($tmp.Length + 1)
            $dest = Join-Path "$dir\src" $rel
            if (Test-Path $dest) { "exists, kept your copy: $rel"; continue }
            New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
            Move-Item $g.FullName $dest
            $hashesPath = Join-Path $dir 'base-hashes.json'
            $hashes = if (Test-Path $hashesPath) { Get-Content $hashesPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
            $hashes[$rel.Replace('\', '/')] = (Get-FileHash $dest -Algorithm SHA256).Hash
            $hashes | ConvertTo-Json | Set-Content $hashesPath
            "added: mods\$Name\src\$rel"
            if ($rel -match '\.xml$') { Write-Warning "Layouts (.xml) can't be rebuilt by these scripts; use it as a reference and change panels from JS (docs\panorama.md)." }
        }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
"Overlay: $dir (base: $($meta['base']))"
