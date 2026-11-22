#Requires -Version 7
<#
.SYNOPSIS
  Builds a VPK from a workspace created by Expand-Vpk.ps1 (or from a hand-made folder).
.DESCRIPTION
  For every file in <Workspace>\compiled the matching file in <Workspace>\src is checked:
    - unchanged            -> the original compiled file is packed as-is
    - edited .js / .css    -> recompiled with Compile-Panorama.ps1 (original used as the template)
    - edited anything else -> error (layouts, textures etc. need Valve's tools; see docs\panorama.md)
  New .js/.css files in src are compiled too; new files that are already compiled (*_c) or plain
  (txt/json) are copied. With -ChangedOnly only edited/new files are packed, which gives an
  overlay pak that you load with a lower number than (i.e. ahead of) the mod it patches.
  A folder without workspace.json is treated as a plain tree of game files and packed verbatim
  (after compiling any .js/.css in it).
.EXAMPLE
  pwsh scripts\Build-Vpk.ps1 -Workspace work\hudpp -Out build\hudpp-tweaks.vpk -ChangedOnly
#>
param(
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Out,
    [switch]$ChangedOnly
)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force
$compile = Join-Path $PSScriptRoot 'Compile-Panorama.ps1'

$Workspace = (Resolve-Path $Workspace).Path
$Out = [IO.Path]::GetFullPath($Out)
$stage = Join-Path ([IO.Path]::GetTempPath()) ("dlbuild_" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $stage | Out-Null
$srcToCompiled = @{ '.js' = '.vjs_c'; '.css' = '.vcss_c'; '.xml' = '.vxml_c' }

function Add-Staged([string]$From, [string]$Rel) {
    $dest = Join-Path $stage $Rel
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item $From $dest
}

try {
    $meta = Join-Path $Workspace 'workspace.json'
    $changed = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path $meta)) {
        # Plain folder: compile sources, pack everything else verbatim.
        Get-ChildItem -Recurse -File $Workspace | ForEach-Object {
            $rel = $_.FullName.Substring($Workspace.Length + 1)
            if ($_.Extension -in '.js', '.css') {
                & $compile -Source $_.FullName -Output (Join-Path $stage ([IO.Path]::ChangeExtension($rel, $srcToCompiled[$_.Extension])))
            } elseif ($_.Extension -eq '.xml') { throw "Can't compile layout $rel (see docs\panorama.md)" }
            else { Add-Staged $_.FullName $rel }
            $changed.Add($rel)
        }
    } else {
        $pristine = (Get-Content $meta -Raw | ConvertFrom-Json -AsHashtable).pristine
        $compiledDir = Join-Path $Workspace 'compiled'
        $srcDir = Join-Path $Workspace 'src'
        $claimed = @{}

        foreach ($c in Get-ChildItem -Recurse -File $compiledDir) {
            $rel = $c.FullName.Substring($compiledDir.Length + 1)
            $base = [IO.Path]::ChangeExtension($rel, $null).TrimEnd('.')
            $src = if ($c.Extension -notmatch '_c$') { Join-Path $srcDir $rel }
                   else { Get-ChildItem (Join-Path $srcDir (Split-Path $base)) -File -Filter "$(Split-Path $base -Leaf).*" -ErrorAction SilentlyContinue |
                          Where-Object Extension -NotMatch '_c$' | Select-Object -First 1 -ExpandProperty FullName }
            if (-not $src -or -not (Test-Path $src)) { if (-not $ChangedOnly) { Add-Staged $c.FullName $rel }; continue }
            $srcRel = $src.Substring($srcDir.Length + 1)
            $claimed[$srcRel.Replace('\', '/')] = $true
            $same = $pristine[$srcRel.Replace('\', '/')] -eq (Get-FileHash $src -Algorithm SHA256).Hash
            if ($same) { if (-not $ChangedOnly) { Add-Staged $c.FullName $rel }; continue }
            $ext = [IO.Path]::GetExtension($src).ToLowerInvariant()
            if ($ext -in '.js', '.css' -and $c.Extension -eq $srcToCompiled[$ext]) {
                & $compile -Source $src -Template $c.FullName -Output (Join-Path $stage $rel)
            } elseif ($c.Extension -notmatch '_c$') {
                Add-Staged $src $rel
            } else {
                throw "Edited $srcRel, but $($c.Extension) files can't be rebuilt by these scripts. Revert it, or put a compiled replacement in compiled\ (see docs\panorama.md)."
            }
            $changed.Add($rel)
        }

        # New files that have no compiled original.
        foreach ($s in Get-ChildItem -Recurse -File $srcDir) {
            $srcRel = $s.FullName.Substring($srcDir.Length + 1)
            if ($claimed.ContainsKey($srcRel.Replace('\', '/')) -or $pristine.ContainsKey($srcRel.Replace('\', '/'))) { continue }
            $ext = $s.Extension.ToLowerInvariant()
            if ($ext -in '.js', '.css') {
                $outRel = [IO.Path]::ChangeExtension($srcRel, $srcToCompiled[$ext])
                & $compile -Source $s.FullName -Output (Join-Path $stage $outRel)
                $changed.Add($outRel); continue
            }
            elseif ($ext -eq '.xml') { throw "New layout $srcRel can't be compiled; create the panels from JavaScript instead (docs\panorama.md)." }
            else { Add-Staged $s.FullName $srcRel }
            $changed.Add($srcRel)
        }
    }

    if (-not (Get-ChildItem -Recurse -File $stage)) { throw 'Nothing to pack (no changes found).' }
    New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
    Remove-Item $Out -ErrorAction SilentlyContinue
    Invoke-S2V -i $stage --vpk_create $Out -q | Out-Null
    $count = (Get-ChildItem -Recurse -File $stage).Count
    "Built $Out ($count files)"
    if ($changed.Count) { "Rebuilt / added:"; $changed | ForEach-Object { "  $_" } }
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
