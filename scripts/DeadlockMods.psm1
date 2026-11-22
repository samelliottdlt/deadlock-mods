#Requires -Version 7
# Shared helpers for the deadlock-mods scripts: locating the game, the Source2Viewer CLI,
# CRC32, and reading/writing Source 2 compiled resource files (*_c).

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path $PSScriptRoot -Parent

function Get-RepoRoot { $script:RepoRoot }

function Get-DeadlockPath {
    <# Returns the Deadlock install root (the folder that contains game\citadel). #>
    if ($env:DEADLOCK_PATH -and (Test-Path (Join-Path $env:DEADLOCK_PATH 'game\citadel'))) { return $env:DEADLOCK_PATH }
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { throw 'Steam not found in the registry. Set $env:DEADLOCK_PATH to the Deadlock install folder.' }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $libs += Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $p = Join-Path $lib 'steamapps\common\Deadlock'
        if (Test-Path (Join-Path $p 'game\citadel\gameinfo.gi')) { return (Resolve-Path $p).Path }
    }
    throw 'Deadlock install not found in any Steam library. Set $env:DEADLOCK_PATH.'
}

function Get-CitadelPath { Join-Path (Get-DeadlockPath) 'game\citadel' }
function Get-AddonsPath { Join-Path (Get-CitadelPath) 'addons' }

function Test-DeadlockRunning { [bool](Get-Process -Name 'deadlock', 'project8' -ErrorAction SilentlyContinue) }

function Assert-DeadlockClosed {
    if (Test-DeadlockRunning) { throw 'Deadlock is running. Close it first: the game locks the VPKs and only reads gameinfo.gi at launch.' }
}

function Get-S2V {
    <# Path to Source2Viewer-CLI.exe; run scripts\Setup-Tools.ps1 to download it. #>
    $exe = Join-Path $script:RepoRoot 'tools\s2v\Source2Viewer-CLI.exe'
    if (Test-Path $exe) { return $exe }
    $onPath = Get-Command 'Source2Viewer-CLI' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    throw "Source2Viewer-CLI not found. Run: pwsh $script:RepoRoot\scripts\Setup-Tools.ps1"
}

function Invoke-S2V {
    $exe = Get-S2V
    & $exe @args
    if ($LASTEXITCODE -ne 0) { throw "Source2Viewer-CLI failed (exit $LASTEXITCODE): $($args -join ' ')" }
}

if (-not ('DlCrc32' -as [type])) {
    Add-Type -TypeDefinition @'
public static class DlCrc32 {
    static readonly uint[] T = Build();
    static uint[] Build() { var t = new uint[256]; for (uint i = 0; i < 256; i++) { uint c = i; for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1; t[i] = c; } return t; }
    public static uint Compute(byte[] b) { uint c = 0xFFFFFFFFu; foreach (var x in b) c = T[(c ^ x) & 0xFF] ^ (c >> 8); return c ^ 0xFFFFFFFFu; }
}
'@
}
function Get-Crc32([byte[]]$Bytes) { [DlCrc32]::Compute($Bytes) }

# ---- Source 2 resource files -------------------------------------------------------------------
# Layout (little endian):
#   u32 fileSize | u16 headerVersion (12) | u16 typeVersion | u32 blockTableOffset (8, relative to its own position) | u32 blockCount
#   blockCount x { char[4] type | u32 offset (relative to this field) | u32 size }
#   block data, each block starting on a 16-byte boundary

function Read-S2Resource([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $tableAt = 8 + [BitConverter]::ToUInt32($b, 8)
    $count = [BitConverter]::ToUInt32($b, 12)
    $blocks = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $count; $i++) {
        $e = $tableAt + $i * 12
        $type = [Text.Encoding]::ASCII.GetString($b, $e, 4)
        $off = $e + 4 + [BitConverter]::ToUInt32($b, $e + 4)
        $size = [BitConverter]::ToUInt32($b, $e + 8)
        $data = [byte[]]::new($size)
        [Array]::Copy($b, $off, $data, 0, $size)
        $blocks.Add([pscustomobject]@{ Type = $type; Data = $data })
    }
    [pscustomobject]@{
        HeaderVersion = [BitConverter]::ToUInt16($b, 4)
        TypeVersion   = [BitConverter]::ToUInt16($b, 6)
        Blocks        = $blocks
    }
}

function ConvertTo-S2ResourceBytes($Resource) {
    $ms = [IO.MemoryStream]::new()
    $w = [IO.BinaryWriter]::new($ms)
    $count = $Resource.Blocks.Count
    $w.Write([uint32]0)
    $w.Write([uint16]$Resource.HeaderVersion)
    $w.Write([uint16]$Resource.TypeVersion)
    $w.Write([uint32]8)
    $w.Write([uint32]$count)
    $tableAt = 16
    $pos = $tableAt + 12 * $count
    $offsets = @()
    foreach ($blk in $Resource.Blocks) {
        $pos = [int]([Math]::Ceiling($pos / 16) * 16)
        $offsets += $pos
        $pos += $blk.Data.Length
    }
    for ($i = 0; $i -lt $count; $i++) {
        $e = $tableAt + $i * 12
        $w.Write([Text.Encoding]::ASCII.GetBytes($Resource.Blocks[$i].Type))
        $w.Write([uint32]($offsets[$i] - ($e + 4)))
        $w.Write([uint32]$Resource.Blocks[$i].Data.Length)
    }
    for ($i = 0; $i -lt $count; $i++) {
        while ($ms.Position -lt $offsets[$i]) { $w.Write([byte]0) }
        $w.Write($Resource.Blocks[$i].Data)
    }
    $w.Flush()
    $bytes = $ms.ToArray()
    [BitConverter]::GetBytes([uint32]$bytes.Length).CopyTo($bytes, 0)
    $bytes
}

function New-PanoramaData([string]$Kind, [byte[]]$Source) {
    <# Builds the DATA block payload for a compiled Panorama script/style. #>
    switch ($Kind) {
        'js' { return , $Source }  # vjs_c v4: the DATA block is the raw script text
        'css' {
            # vcss_c v3: u32 CRC32 of the source | u16 name count (0) | source text
            $out = [byte[]]::new(6 + $Source.Length)
            [BitConverter]::GetBytes([uint32](Get-Crc32 $Source)).CopyTo($out, 0)
            [Array]::Copy($Source, 0, $out, 6, $Source.Length)
            return , $out
        }
        default { throw "Unsupported Panorama kind '$Kind'" }
    }
}

function Get-PanoramaSource([string]$CompiledPath) {
    <# Returns the source text bytes embedded in a compiled vjs_c / vcss_c. #>
    $data = ((Read-S2Resource $CompiledPath).Blocks | Where-Object Type -EQ 'DATA').Data
    if ($CompiledPath -match '\.vjs_c$') { return , $data }
    if ($CompiledPath -match '\.vcss_c$') {
        $names = [BitConverter]::ToUInt16($data, 4)
        if ($names -ne 0) { throw "vcss_c with $names embedded names is not supported: $CompiledPath" }
        $src = [byte[]]::new($data.Length - 6)
        [Array]::Copy($data, 6, $src, 0, $src.Length)
        return , $src
    }
    throw "Not a vjs_c / vcss_c: $CompiledPath"
}

# ---- Install state ------------------------------------------------------------------------------

function Get-GameBuild {
    $inf = Join-Path (Get-CitadelPath) 'steam.inf'
    (Select-String -Path $inf -Pattern '^ClientVersion=(\d+)').Matches[0].Groups[1].Value
}

function Get-GameInfoSearchPaths([string]$GameInfoPath) {
    <# Returns the uncommented lines of the SearchPaths block as objects (Key, Value). #>
    $text = Get-Content $GameInfoPath -Raw
    $m = [regex]::Match($text, '(?s)SearchPaths\s*\{(.*?)\}')
    if (-not $m.Success) { throw "No SearchPaths block in $GameInfoPath" }
    foreach ($line in $m.Groups[1].Value -split '\r?\n') {
        $l = ($line -replace '//.*$', '').Trim()
        if ($l -match '^(\S+)\s+(\S+)') { [pscustomobject]@{ Key = $Matches[1]; Value = $Matches[2] } }
    }
}

function Test-AddonsSearchPath([string]$GameInfoPath) {
    [bool](Get-GameInfoSearchPaths $GameInfoPath | Where-Object { $_.Key -eq 'Game' -and $_.Value -eq 'citadel/addons' })
}

function Get-PGIVersion([string]$GameInfoPath) {
    $m = Select-String -Path $GameInfoPath -Pattern 'PGIVersion\s+"([0-9A-Fa-f]+)"'
    if ($m) { $m.Matches[0].Groups[1].Value }
}

function Get-AddonPaks {
    <# The pakNN_dir.vpk files the game will load, in load (priority) order. #>
    $addons = Get-AddonsPath
    if (-not (Test-Path $addons)) { return }
    Get-ChildItem $addons -File | Where-Object Name -Match '^pak(\d\d)_dir\.vpk$' |
        Where-Object { [int]($_.Name.Substring(3, 2)) -ge 1 } | Sort-Object Name
}

function Get-PakChunks([IO.FileInfo]$DirVpk) {
    <# pakNN_dir.vpk plus any pakNN_000.vpk ... chunk files that belong to it. #>
    $n = $DirVpk.Name.Substring(0, 5)
    @($DirVpk) + @(Get-ChildItem $DirVpk.DirectoryName -File -Filter "${n}_*.vpk" | Where-Object Name -Match '^pak\d\d_\d{3}\.vpk$')
}

function Get-AddonTitle([string]$Vpk) {
    $exe = Get-S2V
    $info = & $exe -i $Vpk -f addoninfo.txt -d -o - 2>$null | Out-String
    if ($info -match 'addontitle\s+"([^"]*)"') { return $Matches[1] }
    $null
}

function Save-StockGameInfo {
    <#
      Keeps a copy of Valve's gameinfo.gi per game build. Taken from the install when it is
      unmodified, otherwise downloaded from SteamTracking/GameTracking-Deadlock if that repo
      tracks the same build.
    #>
    $gi = Join-Path (Get-CitadelPath) 'gameinfo.gi'
    $build = Get-GameBuild
    $dir = Join-Path (Get-RepoRoot) 'backups\stock'
    $dest = Join-Path $dir "gameinfo-$build.gi"
    if (Test-Path $dest) { return }
    New-Item -ItemType Directory -Force $dir | Out-Null
    if (-not (Test-AddonsSearchPath $gi)) { Copy-Item $gi $dest; "Saved stock gameinfo.gi for build $build -> $dest"; return }
    try {
        $base = 'https://raw.githubusercontent.com/SteamTracking/GameTracking-Deadlock/master/game/citadel'
        $inf = (Invoke-WebRequest "$base/steam.inf" -UseBasicParsing).Content
        if ($inf -match 'ClientVersion=(\d+)' -and $Matches[1] -eq $build) {
            Invoke-WebRequest "$base/gameinfo.gi" -OutFile $dest -UseBasicParsing
            "Saved stock gameinfo.gi for build $build from GameTracking-Deadlock -> $dest"
        } else {
            Write-Warning "No stock gameinfo.gi saved: the install is modded and GameTracking-Deadlock is on build $($Matches[1]), not $build."
        }
    } catch { Write-Warning "Couldn't download stock gameinfo.gi: $_" }
}

function Get-StockGameInfo {
    <# Latest saved stock gameinfo.gi, if any. #>
    Get-ChildItem (Join-Path (Get-RepoRoot) 'backups\stock') -Filter 'gameinfo-*.gi' -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.BaseName -replace '\D', '') } | Select-Object -Last 1
}

function Backup-ModState([string]$Reason) {
    <#
      Moves the current paks (and copies gameinfo.gi / mods.txt) into backups\<timestamp>\ and
      returns that folder. After this the addons folder holds no loadable paks.
    #>
    $citadel = Get-CitadelPath
    $addons = Get-AddonsPath
    $dest = Join-Path (Get-RepoRoot) ("backups\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force "$dest\addons" | Out-Null
    Copy-Item (Join-Path $citadel 'gameinfo.gi') $dest
    if (Test-Path "$addons\mods.txt") { Move-Item "$addons\mods.txt" "$dest\addons\" }
    $paks = @()
    foreach ($p in Get-AddonPaks) {
        $title = Get-AddonTitle $p.FullName
        foreach ($f in Get-PakChunks $p) { Move-Item $f.FullName "$dest\addons\" }
        $paks += [ordered]@{ file = $p.Name; title = $title }
    }
    [ordered]@{ reason = $Reason; createdAt = (Get-Date).ToString('o'); gameBuild = Get-GameBuild; paks = $paks } |
        ConvertTo-Json -Depth 5 | Set-Content "$dest\backup.json"
    $dest
}

function Set-GameInfoText([string]$Path, [string]$Text) {
    # Write without a BOM and without changing the line endings the text already uses.
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

Export-ModuleMember -Function *
