#Requires -Version 7
# Builds CompLock packs the way the Pack Builder on deadlockconfig.com does, without a browser.
# The site embeds its data in <script id="pack-data"> (every pak's number, size, CRC-32 and a URL to
# its raw-deflated bytes, CompLock's gameinfo.gi and each option's ConVar lines); /docs/pack/pack.js
# turns a selection (the ?pack= link) into a zip. The functions below mirror pack.js (decode,
# resolve, gameinfo, modsTxt, encode) so the result is byte-identical to the zip the site makes.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1')
$script:Site = 'https://deadlockconfig.com'

function Get-CompLockSite { $script:Site }

function Get-CompLockData {
    <# Downloads the Pack Builder page and returns its pack-data (ordered hashtables). #>
    $html = (Invoke-WebRequest "$script:Site/" -UseBasicParsing).Content
    $m = [regex]::Match($html, '(?s)<script id="pack-data" type="application/json">(.*?)</script>')
    if (-not $m.Success) { throw "No pack-data on $script:Site; the Pack Builder page changed. Download the pack by hand from $script:Site/#build." }
    $data = $m.Groups[1].Value | ConvertFrom-Json -AsHashtable
    foreach ($k in 'base', 'option', 'files', 'gameinfo') { if (-not $data[$k]) { throw "pack-data has no '$k'; the Pack Builder changed. Download the pack by hand." } }
    $data
}

function Get-DefaultChoice($Item) { $c = @($Item.choice); ($c | Where-Object { $_.default } | Select-Object -First 1) ?? $c[0] }

function Get-CompLockFov($Data) {
    $b = $Data.base | Where-Object { $_.fov } | Select-Object -First 1
    if (-not $b) { return $null }
    $f = $b.fov
    $values = [Collections.Generic.List[string]]@('0')
    for ($i = 0; $f.from + $i * $f.by -le $f.to + 1e-9; $i++) { $values.Add(($f.from + $i * $f.by).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) }
    @{ cvar = $f.cvar; default = $f.default; values = $values }
}

function Test-SelOn($Sel, [string]$Id) { $Sel.Contains($Id) -and $null -ne $Sel[$Id] -and $Sel[$Id] -ne $false }

function ConvertFrom-CompLockSelection {
    <#
      Parses a ?pack= value ("soundcap,particles:stock,ragdolls:off,fov:0") like pack.js decode().
      Returns @{ Sel = ordered selection; Unknown = ids the site doesn't know }.
      Note: an option with gameinfo_else (e.g. ragdolls) is ON when the link doesn't name it.
    #>
    param($Data, [string]$Text)
    $sel = [ordered]@{}
    $unknown = [Collections.Generic.List[string]]::new()
    $fov = Get-CompLockFov $Data
    foreach ($o in $Data.option) { if ($o.gameinfo_else) { $sel[$o.id] = $true } }
    foreach ($part in ($Text -split ',')) {
        if (-not $part.Trim()) { continue }
        $bits = $part.Trim() -split ':'
        $id = $bits[0]; $cid = if ($bits.Count -gt 1) { $bits[1] } else { $null }
        if ($id -eq 'fov') { if ($fov -and $fov.values -contains $cid -and $cid -ne $fov.default) { $sel['fov'] = $cid }; continue }
        $o = ($Data.option + $Data.base) | Where-Object { $_.id -ceq $id -and ($Data.option -contains $_ -or $_.choice) } | Select-Object -First 1
        if (-not $o) { $unknown.Add($id); continue }
        if ($o.gameinfo_else) { $sel[$id] = $cid -ne 'off' -and $cid -ne 'false' }
        elseif ($o.choice) { $sel[$id] = (@($o.choice | Where-Object { $_.id -ceq $cid }) + @(Get-DefaultChoice $o))[0].id }
        else { $sel[$id] = $true }
    }
    foreach ($b in $Data.base | Where-Object { $_.choice }) {
        if (-not (@($b.choice.id) -ccontains $sel[$b.id])) { $sel[$b.id] = (Get-DefaultChoice $b).id }
    }
    @{ Sel = $sel; Unknown = $unknown }
}

function ConvertTo-CompLockSelection($Data, $Sel) {
    <# The ?pack= value for a selection, like pack.js encode(). #>
    $fov = Get-CompLockFov $Data
    $parts = @(
        foreach ($b in $Data.base | Where-Object { $_.choice }) { if ($Sel[$b.id] -cne (Get-DefaultChoice $b).id) { "$($b.id):$($Sel[$b.id])" } }
        foreach ($o in $Data.option) { if ((Test-SelOn $Sel $o.id) -and -not $o.gameinfo_else) { if ($Sel[$o.id] -is [bool]) { $o.id } else { "$($o.id):$($Sel[$o.id])" } } }
        foreach ($o in $Data.option) { if ($o.gameinfo_else -and -not (Test-SelOn $Sel $o.id)) { "$($o.id):off" } }
        if ($fov -and $Sel['fov']) { "fov:$($Sel['fov'])" }
    )
    $parts -join ','
}

function Get-CompLockShareUrl($Data, $Sel) {
    $enc = ConvertTo-CompLockSelection $Data $Sel
    "$script:Site/?pack=$(if ($enc) { $enc } else { 'none' })#build"
}

function Resolve-CompLockPack($Data, $Sel) {
    <# Which paks, ConVar lines and commented-out lines a selection gives (pack.js resolve()). #>
    $files = [Collections.Generic.List[string]]::new()
    $lines = [ordered]@{}; $off = [ordered]@{}
    $flags = [Collections.Generic.List[string]]::new()
    $add = { param($f) if (-not $files.Contains($f)) { $files.Add($f) } }
    $merge = { param($into, $from) if ($from) { foreach ($k in $from.Keys) { $into[$k] = $from[$k] } } }
    $components = [Collections.Generic.List[object]]::new()
    foreach ($o in $Data.option) { if ($o.flag -and (Test-SelOn $Sel $o.id)) { $flags.Add($o.flag) } }
    foreach ($b in $Data.base | Where-Object { $_.choice }) {
        $c = @($b.choice | Where-Object { $_.id -ceq $Sel[$b.id] })[0] ?? (Get-DefaultChoice $b)
        if ($c.flag) { $flags.Add($c.flag) }
        & $merge $lines $c.gameinfo
        & $merge $off $c.gameinfo_off
    }
    foreach ($b in $Data.base) {
        & $merge $lines $b.gameinfo
        $key = ($flags | Sort-Object -CaseSensitive) -join '+'
        $pak = $null
        if ($b.pak) { $pak = if ($key -and $b.variants -and $b.variants[$key]) { $b.variants[$key] } else { $b.pak }; & $add $pak }
        foreach ($p in @($b.paks)) { if ($p) { & $add $p } }
        $choice = if ($b.choice) { @($b.choice | Where-Object { $_.id -ceq $Sel[$b.id] })[0] ?? (Get-DefaultChoice $b) }
        $components.Add([ordered]@{ id = $b.id; title = $b.title; choice = $choice.title; by = $b.by; updated = $b.updated.date; changelog = $b.updated.href; file = $pak })
    }
    $fov = Get-CompLockFov $Data
    if ($fov -and $Sel['fov']) { $lines[$fov.cvar] = $Sel['fov'] }
    foreach ($o in $Data.option) {
        $on = Test-SelOn $Sel $o.id
        if (-not $on) { & $merge $lines $o.gameinfo_else }
        if (-not $on -or ($o.included -and (Test-SelOn $Sel $o.included))) { continue }
        $c = if ($o.choice) { @($o.choice | Where-Object { $_.id -ceq $Sel[$o.id] })[0] }
        $pak = $null
        foreach ($x in @($o, $c)) {
            if (-not $x) { continue }
            if ($x.pak) { & $add $x.pak; $pak = $x.pak }
            foreach ($p in @($x.paks)) { if ($p) { & $add $p } }
            & $merge $lines $x.gameinfo
            & $merge $off $x.gameinfo_off
        }
        $components.Add([ordered]@{ id = $o.id; title = $o.title; choice = $c.title; by = $o.by; updated = $o.updated.date; changelog = $o.updated.href; file = $pak })
    }
    foreach ($k in @($lines.Keys)) { $off.Remove($k) }
    $paks = @(foreach ($f in $files) {
        $info = $Data.files[$f]
        if (-not $info) { throw "pack-data has no file '$f'" }
        [pscustomobject]@{ File = $f; Num = [int]$info.num; Title = $info.title; Parts = @($info.parts) }
    }) | Sort-Object Num -Stable
    $nums = @($paks.Num)
    if (@($nums | Select-Object -Unique).Count -ne $nums.Count) { throw "Two paks with the same number: $($paks.File -join ', ')" }
    [pscustomobject]@{ Paks = @($paks); Lines = $lines; Off = $off; Components = $components }
}

function New-CompLockGameInfo([string]$Text, $Convars, $Off) {
    <# CompLock's gameinfo.gi with the picked options' lines (pack.js gameinfo()). #>
    $m = [regex]::Match($Text, '(?m)^(\t*)ConVars[ \t]*\r?\n\1\{[ \t]*\r?\n')
    if (-not $m.Success) { throw 'No ConVars block in the pack gameinfo.gi' }
    $indent = $m.Groups[1].Value
    $start = $m.Index + $m.Length
    $end = $Text.IndexOf("`n$indent}", $start, [StringComparison]::Ordinal)
    $block = $Text.Substring($start, $end - $start)
    $add = [Collections.Generic.List[string]]::new()
    $name = { param($k) '"' + [regex]::Escape($k) + '"' }
    foreach ($k in $Convars.Keys) {
        $v = $Convars[$k]
        $re = [regex]::new('^(\s*' + (& $name $k) + '\s+)"[^"\r\n]*"', 'Multiline')
        if ($re.IsMatch($block)) { $block = $re.Replace($block, { param($mm) $mm.Groups[1].Value + '"' + $v + '"' }, 1) }
        else { $add.Add("$indent`t`"$k`" `"$v`"`n") }
    }
    foreach ($k in $Off.Keys) {
        if ($Convars.Contains($k)) { continue }
        $re = [regex]::new('^([ \t]*)(' + (& $name $k) + '\s+"[^"\r\n]*")', 'Multiline')
        if ($re.IsMatch($block)) { $block = $re.Replace($block, { param($mm) $mm.Groups[1].Value + '// ' + $mm.Groups[2].Value }, 1) }
        else { $add.Add("$indent`t// `"$k`" `"$($Off[$k])`"`n") }
    }
    $head = if ($add.Count) { "$indent`t// CompLock Pack Builder`n" + ($add -join '') + "`n" } else { '' }
    $Text.Substring(0, $start) + $head + $block + $Text.Substring($end)
}

function New-CompLockModsTxt($Resolved, [string]$ShareUrl) {
    $l = [Collections.Generic.List[string]]@(
        'CompLock pack, made with the Pack Builder. pak01 loads first, and a lower number wins when two paks',
        'change the same file. Delete these files to remove it, then verify the game files in Steam.', '')
    foreach ($p in $Resolved.Paks) { $l.Add((($p.Parts | ForEach-Object name) -join ' + ') + "  $($p.Title)  ($($p.File))") }
    $l.Add('')
    $l.Add("gameinfo.gi: CompLock's" + $(if ($Resolved.Lines.Count + $Resolved.Off.Count) { ', with' } else { '' }))
    foreach ($k in $Resolved.Lines.Keys) { $l.Add("  `"$k`" `"$($Resolved.Lines[$k])`"") }
    foreach ($k in $Resolved.Off.Keys) { $l.Add("  // `"$k`" `"$($Resolved.Off[$k])`"  (commented out)") }
    $l.Add(''); $l.Add("This pack in the Pack Builder: $ShareUrl"); $l.Add('')
    $l -join "`r`n"
}

function Save-CompLockPart($Part, [string]$Dest) {
    <# Downloads one pak (raw deflate, maybe split over several URLs), inflates it and checks size + CRC-32. #>
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlz_" + [guid]::NewGuid())
    try {
        $raw = [IO.File]::Create($tmp)
        try {
            foreach ($u in @($Part.url)) {
                $resp = Invoke-WebRequest "$script:Site$u" -UseBasicParsing
                $raw.Write($resp.Content, 0, $resp.Content.Length)
            }
        } finally { $raw.Dispose() }
        if ((Get-Item $tmp).Length -ne $Part.csize) { throw "Got $((Get-Item $tmp).Length) bytes of $($Part.csize) for $($Part.url)" }
        $in = [IO.File]::OpenRead($tmp)
        $out = [IO.MemoryStream]::new([int]$Part.size)
        try { $z = [IO.Compression.DeflateStream]::new($in, [IO.Compression.CompressionMode]::Decompress); $z.CopyTo($out); $z.Dispose() } finally { $in.Dispose() }
        $bytes = $out.ToArray()
        if ($bytes.Length -ne $Part.size) { throw "$($Part.name): inflated to $($bytes.Length) bytes, expected $($Part.size)" }
        if ((Get-Crc32 $bytes) -ne [uint32]$Part.crc) { throw "$($Part.name): CRC-32 mismatch" }
        New-Item -ItemType Directory -Force (Split-Path $Dest) | Out-Null
        [IO.File]::WriteAllBytes($Dest, $bytes)
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Get-CompLockManifestPath([string]$PackDir) { Join-Path $PackDir 'complock.json' }

function Get-CompLockChangelog {
    <# Releases from /docs/changelog/: Date (yyyy-MM-dd), Title, Summary. Empty if the page can't be read. #>
    try { $html = (Invoke-WebRequest "$script:Site/docs/changelog/" -UseBasicParsing).Content } catch { return @() }
    $dec = { param($s) [Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', '' -replace '\s+', ' ').Trim()) }
    foreach ($m in [regex]::Matches($html, '(?s)<li class="cl-rel[^"]*" id="cl-(\d{4}-\d\d-\d\d)">(.*?)</li>\s*(?=<li class="cl-rel|</ol>)')) {
        $body = $m.Groups[2].Value
        [pscustomobject]@{
            Date = $m.Groups[1].Value
            Title = & $dec ([regex]::Match($body, '(?s)<h2>(.*?)</h2>').Groups[1].Value)
            Summary = & $dec ([regex]::Match($body, '(?s)<p class="cl-sum">(.*?)</p>').Groups[1].Value)
            Url = "$script:Site/docs/changelog/#cl-$($m.Groups[1].Value)"
        }
    }
}

Export-ModuleMember -Function *
