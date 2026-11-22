#Requires -Version 7
# Shared helpers for the deadlock-mods scripts: locating the game, the Source2Viewer CLI,
# CRC32, and reading/writing Source 2 compiled resource files (*_c).

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path $PSScriptRoot -Parent

function Get-RepoRoot { $script:RepoRoot }

function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $script:RepoRoot $Path }
}

function Get-Loadout([string]$Path) {
    if (-not $Path) { $Path = Join-Path $script:RepoRoot 'loadout.json' }
    Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Read-JsonFile([string]$Path) { if (Test-Path $Path) { Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable } }

function Write-JsonFile([string]$Path, $Object) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    Set-Content $Path ($Object | ConvertTo-Json -Depth 10)
}

function Get-StatePath([string]$Name) {
    <# state\ holds machine-local bookkeeping (gitignored): version stamp, last deploy, vanilla baseline. #>
    Join-Path $script:RepoRoot "state\$Name"
}

function Read-Text([string]$Path) {
    <# UTF-8 text with LF line endings (decompiled files mix CRLF and LF; overlays always use LF). #>
    [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
}

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-FileSha([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash }
function Get-TextSha([string]$Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
}

$script:CompiledExt = @{ '.css' = '.vcss_c'; '.js' = '.vjs_c'; '.xml' = '.vxml_c' }
function ConvertTo-CompiledPath([string]$Rel) {
    <# panorama/scripts/x.js -> panorama/scripts/x.vjs_c (other files keep their name). #>
    $e = [IO.Path]::GetExtension($Rel).ToLowerInvariant()
    if ($script:CompiledExt[$e]) { [IO.Path]::ChangeExtension($Rel, $script:CompiledExt[$e]).Replace('\', '/') } else { $Rel.Replace('\', '/') }
}
function ConvertTo-SourcePath([string]$Rel) {
    foreach ($k in $script:CompiledExt.Keys) { if ($Rel.EndsWith($script:CompiledExt[$k])) { return $Rel.Substring(0, $Rel.Length - $script:CompiledExt[$k].Length) + $k } }
    $Rel
}

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

# ---- VPK contents -------------------------------------------------------------------------------

function Get-VpkListing([string]$Vpk) {
    <# path -> CRC (hex string) of every file in a VPK, from its directory tree only (fast). #>
    $exe = Get-S2V
    $out = @{}
    foreach ($line in & $exe -i $Vpk -l 2>$null) {
        if ($line -match '^(\S+) CRC:([0-9a-fA-F]+)') { $out[$Matches[1]] = $Matches[2].ToLowerInvariant() }
    }
    if ($LASTEXITCODE -ne 0) { throw "Source2Viewer-CLI couldn't list $Vpk" }
    $out
}

function Export-VpkSources([string]$Vpk, [string[]]$Compiled, [string]$Out) {
    <#
      Decompiles the given compiled paths from a VPK into $Out (source names: .js/.css/.xml) with LF
      line endings and no BOM, so they can be diffed and merged. Plain files are copied as-is.
    #>
    New-Item -ItemType Directory -Force $Out | Out-Null
    if (-not $Compiled) { return }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlsrc_" + [guid]::NewGuid())
    try {
        Invoke-S2V -i $Vpk -f ($Compiled -join ',') -d -o "$tmp\" -q | Out-Null
        foreach ($f in Get-ChildItem -Recurse -File $tmp -ErrorAction SilentlyContinue) {
            $rel = $f.FullName.Substring($tmp.Length + 1)
            $dest = Join-Path $Out $rel
            if ($f.Extension -in '.js', '.css', '.xml', '.txt', '.json', '.cfg') { Write-Text $dest (Read-Text $f.FullName) }
            else { New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null; Copy-Item $f.FullName $dest -Force }
        }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# ---- Downloads from GameBanana -----------------------------------------------------------------

function Get-GameBananaMod([int]$Id) {
    <# Name, author and files (newest first) of a GameBanana mod, from its public API. #>
    $r = Invoke-RestMethod "https://gamebanana.com/apiv11/Mod/$Id/ProfilePage"
    [pscustomobject]@{
        Id = $Id; Name = $r._sName; Author = $r._aSubmitter._sName; Url = "https://gamebanana.com/mods/$Id"
        Version = $r._sVersion
        License = ($r._sLicense -replace '<[^>]+>', '' -replace '\s+', ' ').Trim()
        Files = @($r._aFiles | ForEach-Object {
            [pscustomobject]@{ Id = $_._idRow; Name = $_._sFile; Size = $_._nFilesize; Url = $_._sDownloadUrl
                               Added = [DateTimeOffset]::FromUnixTimeSeconds($_._tsDateAdded).UtcDateTime }
        } | Sort-Object Added -Descending)
    }
}

function Save-GameBananaVpk([int]$Id, [string]$Dest, $File) {
    <#
      Downloads a GameBanana file (default: the newest), takes the single .vpk inside (or the file
      itself if it is a .vpk) and saves it as $Dest. Writes $Dest.source.json with what was fetched.
    #>
    $mod = Get-GameBananaMod $Id
    if (-not $File) { $File = $mod.Files | Select-Object -First 1 }
    if (-not $File) { throw "GameBanana mod $Id has no files" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlgb_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $dl = Join-Path $tmp $File.Name
        Invoke-WebRequest $File.Url -OutFile $dl -UseBasicParsing
        if ($dl -match '\.zip$') { Expand-Archive $dl "$tmp\x"; $vpks = @(Get-ChildItem -Recurse -File "$tmp\x" -Filter *.vpk) }
        elseif ($dl -match '\.vpk$') { $vpks = @(Get-Item $dl) }
        else { throw "$($File.Name): only .zip and .vpk downloads are supported (7z/rar: extract by hand into $Dest)" }
        $bad = Get-ChildItem -Recurse -File "$tmp\x" -ErrorAction SilentlyContinue | Where-Object Extension -In '.exe', '.dll', '.bat', '.cmd', '.ps1', '.vbs'
        if ($bad) { throw "$($File.Name) contains executables ($($bad.Name -join ', ')); not installing it." }
        if ($vpks.Count -ne 1) { throw "$($File.Name) has $($vpks.Count) .vpk files; pick one by hand." }
        New-Item -ItemType Directory -Force (Split-Path $Dest) | Out-Null
        Copy-Item $vpks[0].FullName $Dest -Force
        Write-JsonFile "$Dest.source.json" ([ordered]@{
            gamebanana = $Id; name = $mod.Name; author = $mod.Author; url = $mod.Url; version = $mod.Version; license = $mod.License
            fileId = $File.Id; file = $File.Name; added = $File.Added.ToString('o'); fetchedAt = (Get-Date).ToString('o'); sha256 = Get-FileSha $Dest
        })
        $File
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# ---- Overlays ----------------------------------------------------------------------------------
# mods\<name>\mod.json        tracked: base VPK, files, build mode, credits
# mods\<name>\changes.patch   tracked: our edits as a unified diff against the base files
# mods\<name>\base-hashes.json tracked: hash of each base file the patch was made against
# mods\<name>\base\, src\     local (gitignored): pristine base copies and the working copy you edit

function Get-Overlay([string]$Name) {
    $dir = Join-Path $script:RepoRoot "mods\$Name"
    $metaPath = Join-Path $dir 'mod.json'
    if (-not (Test-Path $metaPath)) { throw "No overlay mods\$Name (mod.json missing)" }
    $meta = Read-JsonFile $metaPath
    $vpk = if ($meta['base'] -eq 'game') { Join-Path (Get-CitadelPath) 'pak01_dir.vpk' } else { Resolve-RepoPath $meta['base'] }
    [pscustomobject]@{
        Name = $Name; Dir = $dir; Meta = $meta; MetaPath = $metaPath; BaseVpk = $vpk
        Patch = Join-Path $dir 'changes.patch'; HashesPath = Join-Path $dir 'base-hashes.json'
        BaseDir = Join-Path $dir 'base'; SrcDir = Join-Path $dir 'src'
        Files = @($meta['files'] | Where-Object { $_ })
        Full = $meta['build'] -eq 'full'
    }
}

function Save-OverlayMeta($Overlay) { Write-JsonFile $Overlay.MetaPath $Overlay.Meta }

function Initialize-OverlayBaseVpk($Overlay) {
    <# Makes sure the overlay's base VPK exists, downloading it when mod.json says where from. #>
    if (Test-Path $Overlay.BaseVpk) { return }
    $src = $Overlay.Meta['source']
    if ($src -and $src['gamebanana']) {
        "Base VPK missing; downloading GameBanana mod $($src['gamebanana']) -> $($Overlay.BaseVpk)"
        Save-GameBananaVpk $src['gamebanana'] $Overlay.BaseVpk | Out-Null
        return
    }
    throw "Base VPK not found: $($Overlay.BaseVpk)$(if ($Overlay.Meta['base'] -like 'packs/*') { ' (run scripts\Update-CompLock.ps1 to download the pack)' })"
}

function Get-OverlayPatchText($Overlay) {
    <# Unified diff base\ -> src\ (paths a/base/..., b/src/...; apply with -p2). Empty when nothing changed. #>
    Push-Location $Overlay.Dir
    try {
        $out = & git -c core.autocrlf=false -c core.quotepath=off diff --no-index --binary --no-color --no-ext-diff --no-renames -- base src 2>$null
        if ($LASTEXITCODE -gt 1) { throw "git diff failed for $($Overlay.Dir)" }
    } finally { Pop-Location }
    if (-not $out) { return '' }
    ($out -join "`n") + "`n"
}

function Invoke-OverlayPatch($Overlay, [string]$Target) {
    <# Applies changes.patch to $Target (a copy of base\). Throws with git's message if it doesn't apply. #>
    if (-not (Test-Path $Overlay.Patch) -or -not (Get-Item $Overlay.Patch).Length) { return }
    $Target = (Resolve-Path $Target).Path
    Push-Location $Target
    # Plain "patch" mode: inside this repo git would take the paths as relative to the repo root and
    # silently skip them. A ceiling above $Target stops it from finding the repo.
    $env:GIT_CEILING_DIRECTORIES = Split-Path $Target
    try {
        $msg = @(& git -c core.autocrlf=false apply -p2 --verbose --whitespace=nowarn $Overlay.Patch 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) { throw "changes.patch of $($Overlay.Name) doesn't apply to the current base:`n$($msg -join "`n")" }
        $files = @(Select-String -Path $Overlay.Patch -Pattern '^diff --git ').Count
        $applied = @($msg | Where-Object { $_ -match '^Applied patch .* cleanly' }).Count
        if ($applied -ne $files) { throw "changes.patch of $($Overlay.Name): git applied $applied of $files files:`n$($msg -join "`n")" }
    } finally { Remove-Item Env:GIT_CEILING_DIRECTORIES -ErrorAction SilentlyContinue; Pop-Location }
}

function Test-ConflictMarkers([string]$Path) {
    [bool](Select-String -Path $Path -Pattern '^(<<<<<<<|>>>>>>>) ' -Quiet)
}

# ---- Install plan ------------------------------------------------------------------------------

function Get-PackCitadel([string]$Pack) {
    <# The folder holding addons\ (and gameinfo.gi) inside a pack folder. #>
    $c = @("$Pack\game\citadel", "$Pack\citadel", $Pack) | Where-Object { Test-Path "$_\addons" } | Select-Object -First 1
    if (-not $c) { throw "Can't find an addons folder in $Pack (expected game\citadel\addons)." }
    $c
}

function New-PakPlan([string]$PackCitadel, [string[]]$Overlay = @(), [string[]]$Extra = @()) {
    <# Ordered list of paks to install: overlays, then the pack's paks, then extras (pak01 wins). #>
    $plan = [Collections.Generic.List[object]]::new()
    foreach ($o in $Overlay) { $f = Get-Item (Resolve-Path $o); $plan.Add([pscustomobject]@{ Files = @($f); Label = "overlay: $($f.Name)"; Kind = 'overlay' }) }
    if ($PackCitadel) {
        foreach ($p in Get-ChildItem "$PackCitadel\addons" -File | Where-Object Name -Match '^pak\d\d_dir\.vpk$' | Sort-Object Name) {
            $plan.Add([pscustomobject]@{ Files = @(Get-PakChunks $p); Label = "pack: $($p.Name)"; Kind = 'pack' })
        }
    }
    foreach ($e in $Extra) { $f = Get-Item (Resolve-Path $e); $plan.Add([pscustomobject]@{ Files = @($f); Label = "extra: $($f.Name)"; Kind = 'extra' }) }
    if ($plan.Count -gt 99) { throw "Too many paks ($($plan.Count)); the game loads pak01-pak99 only." }
    foreach ($item in $plan) {
        if ($item.Files[0].Name -notmatch '_dir\.vpk$' -and $item.Files.Count -gt 1) { throw "Chunked VPK must be named *_dir.vpk: $($item.Files[0].FullName)" }
    }
    for ($i = 0; $i -lt $plan.Count; $i++) { $plan[$i] | Add-Member Pak ('pak{0:d2}_dir.vpk' -f ($i + 1)) }
    $plan
}

function Copy-PakPlan($Plan, [string]$Addons) {
    New-Item -ItemType Directory -Force $Addons | Out-Null
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $n = '{0:d2}' -f ($i + 1)
        foreach ($f in $Plan[$i].Files) {
            $name = if ($f.Name -match '^pak\d\d_(\d{3})\.vpk$') { "pak${n}_$($Matches[1]).vpk" } else { "pak${n}_dir.vpk" }
            Copy-Item $f.FullName (Join-Path $Addons $name)
        }
    }
}

function Add-GameInfoSearchPaths([string]$Text, [string[]]$Keep = @()) {
    <# Ensures "Game citadel/addons" (and any $Keep paths above it) in a gameinfo.gi text. #>
    if (-not ($Text -match '(?m)^\s*Game\s+citadel/addons\s*$')) {
        $Text = [regex]::Replace($Text, '(?m)^(\s*)(Game\s+citadel\s*)$', '$1Game				citadel/addons' + "`n" + '$1$2', 1)
    }
    foreach ($sp in $Keep) {
        if ($Text -notmatch "(?m)^\s*Game\s+$([regex]::Escape($sp))\s*$") {
            $Text = [regex]::Replace($Text, '(?m)^(\s*)(Game\s+citadel/addons\s*)$', ('$1Game				' + $sp + "`n" + '$1$2'), 1)
        }
    }
    $Text
}

# ---- Version stamp ("Updated On") --------------------------------------------------------------

function Get-LoadoutVersion([string]$LoadoutPath, [switch]$NoSave) {
    <#
      The date the installed content last changed. Every input of the loadout (pack files, overlay
      sources, base and extra VPKs) is hashed; when the hash differs from state\version.json the
      date becomes today. Also returns the CompLock pack's own date (its newest component).
    #>
    $cfg = Get-Loadout $LoadoutPath
    $lines = [Collections.Generic.List[string]]::new()
    $pack = if ($cfg['pack']) { Resolve-RepoPath $cfg['pack'] }
    if ($pack -and (Test-Path $pack -PathType Container)) {
        foreach ($f in Get-ChildItem -Recurse -File $pack | Where-Object Name -NE 'complock.json' | Sort-Object FullName) { $lines.Add("pack $($f.FullName.Substring($pack.Length)) $(Get-FileSha $f.FullName)") }
    } elseif ($pack -and (Test-Path $pack)) { $lines.Add("pack $(Get-FileSha $pack)") }
    foreach ($name in @($cfg['overlays']) | Where-Object { $_ }) {
        $o = Get-Overlay $name
        $lines.Add("overlay $name meta $(Get-FileSha $o.MetaPath)")
        if (Test-Path $o.SrcDir) { foreach ($f in Get-ChildItem -Recurse -File $o.SrcDir | Sort-Object FullName) { $lines.Add("overlay $name $($f.FullName.Substring($o.SrcDir.Length)) $(Get-FileSha $f.FullName)") } }
        elseif (Test-Path $o.Patch) { $lines.Add("overlay $name patch $(Get-FileSha $o.Patch)") }
        if ((Test-Path $o.BaseVpk) -and -not ($pack -and $o.BaseVpk.StartsWith($pack, 'OrdinalIgnoreCase'))) { $lines.Add("overlay $name basevpk $(Get-FileSha $o.BaseVpk)") }
    }
    foreach ($e in @($cfg['extra']) | Where-Object { $_ }) { $p = Resolve-RepoPath $e; if (Test-Path $p) { $lines.Add("extra $e $(Get-FileSha $p)") } }
    $fingerprint = Get-TextSha ($lines -join "`n")

    $statePath = Get-StatePath 'version.json'
    $state = Read-JsonFile $statePath
    if (-not $state -or $state['fingerprint'] -ne $fingerprint) {
        $state = [ordered]@{ fingerprint = $fingerprint; updatedOn = (Get-Date).ToString('yyyy-MM-dd') }
        if (-not $NoSave) { Write-JsonFile $statePath $state }
    }
    $complock = if ($pack -and (Test-Path $pack -PathType Container)) { Read-JsonFile (Join-Path $pack 'complock.json') }
    $date = [datetime]::ParseExact($state['updatedOn'], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    [pscustomobject]@{
        UpdatedOn = $state['updatedOn']
        Display = $date.ToString('d MMM yyyy', [Globalization.CultureInfo]::InvariantCulture)
        Tag = 'v' + $date.ToString('yyyy.MM.dd')
        Fingerprint = $fingerprint
        CompLock = $complock
    }
}

function Get-LoadoutCredits([string]$LoadoutPath) {
    <# One line per mod in the loadout: what it is and who made it (for mods.txt, the menu footnote, releases). #>
    $cfg = Get-Loadout $LoadoutPath
    $pack = if ($cfg['pack']) { Resolve-RepoPath $cfg['pack'] }
    $manifest = if ($pack -and (Test-Path $pack -PathType Container)) { Read-JsonFile (Join-Path $pack 'complock.json') }
    $out = [Collections.Generic.List[object]]::new()
    if ($manifest) {
        foreach ($c in $manifest['components']) {
            $out.Add([pscustomobject]@{ Name = "$($c['title'])$(if ($c['choice']) { " ($($c['choice']))" })"; By = ($c['by'] -replace '^By ', ''); Url = $manifest['shareUrl']; Date = $c['updated']; Part = 'CompLock' })
        }
    } elseif ($pack) { $out.Add([pscustomobject]@{ Name = 'CompLock'; By = 'HoppCX and jcStani'; Url = 'https://deadlockconfig.com'; Date = $null; Part = 'CompLock' }) }
    foreach ($name in @($cfg['overlays']) | Where-Object { $_ }) {
        $o = Get-Overlay $name
        foreach ($c in @($o.Meta['credits'])) { if ($c) { $out.Add([pscustomobject]@{ Name = $c['name']; By = $c['by']; Url = $c['url']; Date = $null; Part = $name; License = $c['license'] }) } }
    }
    $out
}


function Get-RepoUrl {
    $u = & git -C $script:RepoRoot remote get-url origin 2>$null
    if ($u) { ($u -replace '\.git$', '' -replace '^git@github\.com:', 'https://github.com/') } else { 'https://github.com/samelliottdlt/deadlock-mods' }
}

function New-LoadoutHeader([string]$LoadoutPath, $Version, [string[]]$Exclude = @()) {
    <# Text for mods.txt / release notes: version date, what's in the loadout and who made it. #>
    if (-not $Version) { $Version = Get-LoadoutVersion $LoadoutPath -NoSave }
    $cfg = Get-Loadout $LoadoutPath
    $credits = @(Get-LoadoutCredits $LoadoutPath | Where-Object { $Exclude -notcontains $_.Part })
    $cl = @($credits | Where-Object Part -EQ 'CompLock')
    $clDate = if ($Version.CompLock -and $Version.CompLock['updatedOn']) { ([datetime]$Version.CompLock['updatedOn']).ToString('d MMM yyyy', [Globalization.CultureInfo]::InvariantCulture) }
    $l = [Collections.Generic.List[string]]::new()
    $l.Add("deadlock-mods loadout - Updated On: $($Version.Display)$(if ($clDate) { "  (CompLock $clDate)" })")
    $l.Add("Made with $(Get-RepoUrl)")
    $l.Add('')
    $l.Add('Credits - all mods belong to their authors:')
    if ($cl) {
        $url = if ($Version.CompLock -and $Version.CompLock['shareUrl']) { $Version.CompLock['shareUrl'] } else { 'https://deadlockconfig.com' }
        $l.Add("  CompLock by HoppCX and jcStani - $url")
        foreach ($c in $cl) { $l.Add("    $($c.Name)$(if ($c.By) { " - by $($c.By)" })$(if ($c.Date) { " ($($c.Date))" })") }
    }
    foreach ($c in $credits | Where-Object Part -NE 'CompLock') { $l.Add("  $($c.Name) by $($c.By) - $($c.Url)$(if ($c.License) { "`n    License: $($c.License)" })") }
    $ov = @($cfg['overlays'] | Where-Object { $_ -and $Exclude -notcontains $_ })
    if ($ov) {
        $l.Add('')
        $l.Add('Changes made by deadlock-mods (overlays):')
        foreach ($n in $ov) { $o = Get-Overlay $n; $l.Add("  $n - $($o.Meta['description'])") }
    }
    $l -join "`n"
}

Export-ModuleMember -Function *
