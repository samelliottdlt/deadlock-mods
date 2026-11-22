#Requires -Version 7
<#
.SYNOPSIS
  Compiles a Panorama .js or .css file into .vjs_c / .vcss_c.
.DESCRIPTION
  Deadlock's compiled scripts and styles store the source text almost verbatim, so no Valve
  resourcecompiler is needed: the DATA block is replaced and the other blocks (RED2 compile
  metadata) are copied from a template. The template is normally the original compiled file you
  are replacing; if none is given, one is taken from the game's own pak01.
  Layouts (.xml -> .vxml_c) are NOT supported: they are stored as a binary KV3 syntax tree.
  Change layouts at runtime from JavaScript instead (see docs\panorama.md).
.EXAMPLE
  pwsh scripts\Compile-Panorama.ps1 -Source src\panorama\styles\hud.css -Output build\panorama\styles\hud.vcss_c
#>
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Output,
    [string]$Template
)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$ext = [IO.Path]::GetExtension($Source).ToLowerInvariant()
$kind, $compiledExt = switch ($ext) {
    '.js' { 'js', '.vjs_c' }
    '.css' { 'css', '.vcss_c' }
    '.xml' { throw "Layouts can't be compiled by this script (vxml_c stores a binary KV3 AST). Change the layout from JavaScript instead; see docs\panorama.md." }
    default { throw "Unsupported source type '$ext' (expected .js or .css)" }
}

function Get-FallbackTemplate([string]$CompiledExt) {
    # Any compiled file of the same type works as a template (only its RED2 metadata is reused).
    # The base game ships styles but no .vjs_c (Valve uses TypeScript, .vts_c), so scripts come
    # from installed mods or the packs\ folder.
    $cache = Join-Path (Get-RepoRoot) "tools\templates\template$CompiledExt"
    if (Test-Path $cache) { return $cache }
    $candidates = @(Join-Path (Get-CitadelPath) 'pak01_dir.vpk') +
        @(Get-ChildItem (Get-AddonsPath) -Filter *.vpk -Recurse -ErrorAction SilentlyContinue).FullName +
        @(Get-ChildItem (Join-Path (Get-RepoRoot) 'packs') -Filter *.vpk -Recurse -ErrorAction SilentlyContinue).FullName
    foreach ($pak in $candidates | Where-Object { $_ }) {
        $exe = Get-S2V
        $line = & $exe -i $pak -l -f 'panorama/' 2>$null | Where-Object { ($_ -split ' ')[0].EndsWith($CompiledExt) } | Select-Object -First 1
        if (-not $line) { continue }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlt_" + [guid]::NewGuid())
        Invoke-S2V -i $pak -f ($line -split ' ')[0] -o "$tmp\" -q | Out-Null
        New-Item -ItemType Directory -Force (Split-Path $cache) | Out-Null
        Move-Item (Get-ChildItem -Recurse -File $tmp | Select-Object -First 1).FullName $cache
        Remove-Item -Recurse -Force $tmp
        return $cache
    }
    throw "No $CompiledExt found to use as a template. Pass -Template, or install any mod that contains one."
}

if (-not $Template) { $Template = Get-FallbackTemplate $compiledExt }
if ([IO.Path]::GetExtension($Template) -ne $compiledExt) { throw "Template $Template is not a $compiledExt file" }

$res = Read-S2Resource $Template
$data = $res.Blocks | Where-Object Type -EQ 'DATA'
if (-not $data) { throw "Template has no DATA block: $Template" }
$data.Data = New-PanoramaData $kind ([IO.File]::ReadAllBytes((Resolve-Path $Source)))
# SrMa holds a source map for the old text; it would be stale, so drop it.
$res.Blocks = [Collections.Generic.List[object]]@($res.Blocks | Where-Object Type -NE 'SrMa')

New-Item -ItemType Directory -Force (Split-Path ([IO.Path]::GetFullPath($Output))) | Out-Null
[IO.File]::WriteAllBytes([IO.Path]::GetFullPath($Output), (ConvertTo-S2ResourceBytes $res))
