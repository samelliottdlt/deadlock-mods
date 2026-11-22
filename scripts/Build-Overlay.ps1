#Requires -Version 7
<#
.SYNOPSIS
  Compiles an overlay (mods\<Name>) into build\<Name>.vpk.
.DESCRIPTION
  Expands the overlay's base VPK (only the files the overlay touches), drops the overlay's src
  files on top and packs the changed/new files. Warns when the base no longer has a file the
  overlay replaces, or when the base copy changed since you started editing (so you can re-merge).
.EXAMPLE
  pwsh scripts\Build-Overlay.ps1 -Name hudpp-tweaks
#>
param([Parameter(Mandatory)][string]$Name, [switch]$AcceptBase)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$dir = Join-Path (Get-RepoRoot) "mods\$Name"
$meta = Get-Content (Join-Path $dir 'mod.json') -Raw | ConvertFrom-Json -AsHashtable
$basePath = if ($meta['base'] -eq 'game') { Join-Path (Get-CitadelPath) 'pak01_dir.vpk' }
            elseif ([IO.Path]::IsPathRooted($meta['base'])) { $meta['base'] } else { Join-Path (Get-RepoRoot) $meta['base'] }
if (-not (Test-Path $basePath)) { throw "Base VPK not found: $basePath" }

$map = @{ '.css' = '.vcss_c'; '.js' = '.vjs_c'; '.xml' = '.vxml_c' }
$srcFiles = @(Get-ChildItem -Recurse -File "$dir\src")
if (-not $srcFiles) { throw "No files in $dir\src" }
$rels = $srcFiles | ForEach-Object { $_.FullName.Substring("$dir\src".Length + 1).Replace('\', '/') }
$filters = $rels | ForEach-Object { $e = [IO.Path]::GetExtension($_); if ($map[$e]) { [IO.Path]::ChangeExtension($_, $map[$e]) } else { $_ } }

$exe = Get-S2V
$inBase = @{}
& $exe -i $basePath -l 2>$null | ForEach-Object { $inBase[($_ -split ' ')[0]] = $true }
$present = @($filters | Where-Object { $inBase[$_] })

$ws = Join-Path ([IO.Path]::GetTempPath()) ("dlovl_" + [guid]::NewGuid())
try {
    if ($present) {
        & (Join-Path $PSScriptRoot 'Expand-Vpk.ps1') -Vpk $basePath -Out $ws -Filter $present | Out-Null
    } else {
        New-Item -ItemType Directory -Force "$ws\src", "$ws\compiled" | Out-Null
        @{ sourceVpk = $basePath; pristine = @{} } | ConvertTo-Json | Set-Content "$ws\workspace.json"
    }
    # Track which base files changed since the overlay copy was made.
    $basesPath = Join-Path $dir 'base-hashes.json'
    $known = if (Test-Path $basesPath) { Get-Content $basesPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $pristine = (Get-Content "$ws\workspace.json" -Raw | ConvertFrom-Json -AsHashtable).pristine
    for ($i = 0; $i -lt $rels.Count; $i++) {
        $rel = $rels[$i]
        if (-not $inBase[$filters[$i]]) { "new file (not in base): $rel" }
        elseif ($known[$rel] -and $pristine[$rel] -and $known[$rel] -ne $pristine[$rel] -and -not $AcceptBase) {
            Write-Warning "$rel changed in the base since this overlay was made. Compare with a fresh copy (Expand-Vpk.ps1 -Vpk <base> -Filter <file> -Out work\x), re-apply your edits, then build with -AcceptBase."
        }
        if ($pristine[$rel] -and ($AcceptBase -or -not $known[$rel])) { $known[$rel] = $pristine[$rel] }
        $dest = Join-Path "$ws\src" $rel
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item $srcFiles[$i].FullName $dest -Force
    }
    $known | ConvertTo-Json | Set-Content $basesPath
    $out = Join-Path (Get-RepoRoot) "build\$Name.vpk"
    & (Join-Path $PSScriptRoot 'Build-Vpk.ps1') -Workspace $ws -Out $out -ChangedOnly
} finally {
    Remove-Item -Recurse -Force $ws -ErrorAction SilentlyContinue
}
