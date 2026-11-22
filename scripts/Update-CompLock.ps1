#Requires -Version 7
<#
.SYNOPSIS
  Downloads/updates the CompLock pack in packs\complock from deadlockconfig.com, with your options.
.DESCRIPTION
  Does what the Pack Builder page does (same paks, gameinfo.gi and mods.txt, byte for byte) for the
  options in loadout.json -> complock.options (the ?pack= value of a Pack Builder link, e.g.
  "soundcap,particles:stock,ragdolls:off,fov:0"). Only paks whose CRC changed are downloaded.
  Reports what changed since the last update (paks, gameinfo.gi, CompLock changelog) and lists NEW
  options the site added. New options are never turned on: one that the site would enable by default
  (it writes ConVars while off, like "ragdolls") is added to your options as "<id>:off".
  The previous pack is kept in packs\.previous\. Nothing in the game folder changes: run Deploy.ps1
  (or Update-Mods.ps1, which also reconciles overlays) afterwards.
  loadout.json -> complock.gameinfo ({ "<convar>": "<value>" | null }) overrides CompLock's ConVar lines
  in the generated gameinfo.gi (null comments CompLock's line out); listed in mods.txt like the options' lines.
.PARAMETER Options
  Change the selection (and save it in loadout.json), e.g. -Options "soundcap,particles:stock,ragdolls:off,fov:0".
.PARAMETER Check
  Only report whether an update is available.
.EXAMPLE
  pwsh scripts\Update-CompLock.ps1 -Check
.EXAMPLE
  pwsh scripts\Update-CompLock.ps1
#>
param([string]$Loadout, [string]$Options, [switch]$Check, [switch]$Force)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CompLock.psm1') -Force

if (-not $Loadout) { $Loadout = Join-Path (Get-RepoRoot) 'loadout.json' }
$cfg = Get-Loadout $Loadout
if (-not $cfg['pack']) { throw "loadout.json has no 'pack'." }
$packDir = Resolve-RepoPath $cfg['pack']
if ($packDir -match '\.zip$') { throw "loadout.json 'pack' is a zip; Update-CompLock manages a folder (set it to packs/complock)." }
$manifestPath = Get-CompLockManifestPath $packDir
$old = Read-JsonFile $manifestPath

# The selection: -Options, else loadout.json, else the link in the current pack's mods.txt.
$sel = $Options
if (-not $sel -and $cfg['complock'] -and $null -ne $cfg['complock']['options']) { $sel = $cfg['complock']['options'] }
if (-not $sel) {
    $txt = Get-ChildItem $packDir -Recurse -Filter mods.txt -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($txt -and (Get-Content $txt.FullName -Raw) -match '\?pack=([^#\s]*)') { $sel = $Matches[1]; "Options taken from $($txt.FullName): $sel" }
}
if ($null -eq $sel) { throw "No CompLock options. Pass -Options '<?pack= value>' (e.g. 'soundcap,particles:stock,ragdolls:off,fov:0'; 'none' for HUD++ + gameinfo only)." }
if ($sel -eq 'none') { $sel = '' }

"Reading the Pack Builder at $(Get-CompLockSite) ..."
$D = Get-CompLockData
$dec = ConvertFrom-CompLockSelection $D $sel
foreach ($u in $dec.Unknown) { Write-Warning "Option '$u' is not on the Pack Builder any more; ignored." }

# New options / choices since the last update. Never enable them; keep default-on ones off.
# What the user has already seen is kept in loadout.json (complock.knownOptions / knownChoices), so a
# fresh clone knows it too. With no record at all, every default-on option the selection doesn't name
# counts as new (kept off); default-off ones are off anyway.
$siteOptions = @($D.option | ForEach-Object id)
$clCfg = $cfg['complock']
$known = if ($clCfg -and $clCfg['knownOptions']) { @($clCfg['knownOptions']) } elseif ($old -and $old['knownOptions']) { @($old['knownOptions']) } else { $null }
$knownChoices = if ($clCfg -and $clCfg['knownChoices']) { $clCfg['knownChoices'] } elseif ($old -and $old['knownChoices']) { $old['knownChoices'] } else { @{} }
$named = @($sel -split ',' | ForEach-Object { ($_ -split ':')[0].Trim() } | Where-Object { $_ })
if ($null -eq $known) { $known = @($D.option | Where-Object { -not $_.gameinfo_else -or $named -contains $_.id } | ForEach-Object id) }
$news = [Collections.Generic.List[string]]::new()
foreach ($o in $D.option | Where-Object { $known -notcontains $_.id }) {
    $line = "NEW OPTION: $($o.title) [$($o.id)] ($($o.group)$(if ($o.by) { ", $($o.by)" })): $($o.text)"
    if ($o.gameinfo_else -and $named -notcontains $o.id) {
        $dec.Sel[$o.id] = $false
        $line += " -> the site turns it on by default; kept OFF ($($o.id):off)."
    } else { $line += " -> not enabled." }
    $news.Add($line)
}
foreach ($x in @($D.base) + @($D.option) | Where-Object { $_.choice }) {
    $was = $knownChoices[$x.id]
    if (-not $was) { continue }
    foreach ($c in $x.choice | Where-Object { @($was) -notcontains $_.id }) { $news.Add("NEW CHOICE for $($x.title): $($c.title) [$($x.id):$($c.id)] -> not selected.") }
}
$kc = [ordered]@{}
foreach ($x in @($D.base) + @($D.option) | Where-Object { $_.choice }) { $kc[$x.id] = @($x.choice | ForEach-Object id) }
$encoded = ConvertTo-CompLockSelection $D $dec.Sel
$shareUrl = Get-CompLockShareUrl $D $dec.Sel
$res = Resolve-CompLockPack $D $dec.Sel
# Our own ConVar overrides (loadout.json -> complock.gameinfo): a value sets the line, null comments out CompLock's.
$overrides = if ($clCfg -and $clCfg['gameinfo']) { $clCfg['gameinfo'] } else { [ordered]@{} }
foreach ($k in $overrides.Keys) {
    $v = $overrides[$k]
    if ($null -eq $v) {
        $was = $res.Lines[$k]
        if ($null -eq $was -and $D.gameinfo -match ('(?m)^\s*"' + [regex]::Escape($k) + '"\s+"([^"\r\n]*)"')) { $was = $Matches[1] }
        $res.Lines.Remove($k); $res.Off[$k] = $was ?? ''
    }
    else { $res.Lines[$k] = "$v"; $res.Off.Remove($k) }
}
$gameinfo = New-CompLockGameInfo $D.gameinfo $res.Lines $res.Off
$modsTxt = New-CompLockModsTxt $res $shareUrl
$updatedOn = ($res.Components | ForEach-Object { $_.updated } | Where-Object { $_ } | Sort-Object | Select-Object -Last 1)

# Compare with what's in packs\complock now.
$citadel = Join-Path $packDir 'game\citadel'
$addons = Join-Path $citadel 'addons'
$want = [ordered]@{}
foreach ($p in $res.Paks) { foreach ($q in $p.Parts) { $want[$q.name] = [pscustomobject]@{ Pak = $p; Part = $q } } }
$have = @{}
if (Test-Path $addons) { foreach ($f in Get-ChildItem $addons -File -Filter *.vpk) { $have[$f.Name] = Get-Crc32 ([IO.File]::ReadAllBytes($f.FullName)) } }
$changes = [Collections.Generic.List[string]]::new()
$download = [Collections.Generic.List[object]]::new()
foreach ($name in $want.Keys) {
    $w = $want[$name]
    $comp = $res.Components | Where-Object { $_.file -eq $w.Pak.File } | Select-Object -First 1
    $when = if ($comp -and $comp.updated) { " (updated $($comp.updated): $(Get-CompLockSite)$($comp.changelog))" } else { '' }
    if (-not $have.ContainsKey($name)) { $changes.Add("  + $name  $($w.Pak.Title)$when"); $download.Add($w) }
    elseif ($have[$name] -ne [uint32]$w.Part.crc) { $changes.Add("  ~ $name  $($w.Pak.Title)$when"); $download.Add($w) }
}
foreach ($name in $have.Keys | Where-Object { -not $want.Contains($_) } | Sort-Object) { $changes.Add("  - $name  (no longer in the pack)") }
$giPath = Join-Path $citadel 'gameinfo.gi'
$oldGi = if (Test-Path $giPath) { [IO.File]::ReadAllText($giPath) } else { $null }
if ($oldGi -ne $gameinfo) {
    $diff = if ($oldGi) { @(Compare-Object ($oldGi -split "`n") ($gameinfo -split "`n")).Count } else { 'new' }
    $pgiOld = if ($oldGi -and $oldGi -match 'PGIVersion\s+"([0-9A-Fa-f]+)"') { $Matches[1] }
    $pgiNew = if ($gameinfo -match 'PGIVersion\s+"([0-9A-Fa-f]+)"') { $Matches[1] }
    $changes.Add("  ~ gameinfo.gi  ($diff changed lines$(if ($pgiOld -and $pgiOld -ne $pgiNew) { '; PGIVersion changed (new game build)' }))")
}
$optsChanged = $old -and $old['options'] -ne $encoded

""
"CompLock selection: $(if ($encoded) { $encoded } else { 'none' })"
"  " + (($res.Paks | ForEach-Object { "pak{0:d2} {1}" -f $_.Num, $_.Title }) -join ' | ')
"  Pack Builder link: $shareUrl"
if ($overrides.Count) { "  gameinfo.gi overrides (loadout.json complock.gameinfo): " + (($overrides.Keys | ForEach-Object { if ($null -eq $overrides[$_]) { "$_ commented out" } else { "$_ = $($overrides[$_])" } }) -join ', ') }
"CompLock newest change: $updatedOn$(if ($old -and $old['updatedOn']) { "   (installed pack: $($old['updatedOn']))" })"
$build = try { Get-GameBuild } catch { $null }
if ($D.game -and $build -and $D.game -ne $build) { "  CompLock's gameinfo.gi is from game build $($D.game); this install is build $build (Deploy warns if the protected sections differ)." }
if ($news) { ""; $news | ForEach-Object { $_ } }
if ($old -and $old['updatedOn']) {
    $log = @(Get-CompLockChangelog | Where-Object { $_.Date -gt $old['updatedOn'] })
    if ($log) { ""; "CompLock changelog since $($old['updatedOn']):"; $log | ForEach-Object { "  $($_.Date)  $($_.Title): $($_.Summary)" } }
}
""
if (-not $changes -and -not $optsChanged -and -not $Force) {
    "$(Split-Path $packDir -Leaf) is up to date."
} else {
    "Changes:"; if ($changes) { $changes } else { "  (options only)" }
}
if ($Check) { return }

if ($changes -or $Force -or -not $old) {
    $new = Join-Path (Split-Path $packDir) ('.' + (Split-Path $packDir -Leaf) + '-new')
    Remove-Item -Recurse -Force $new -ErrorAction SilentlyContinue
    $newAddons = Join-Path $new 'game\citadel\addons'
    New-Item -ItemType Directory -Force $newAddons | Out-Null
    foreach ($name in $want.Keys) {
        $w = $want[$name]
        if ($download -contains $w -or $Force) { "Downloading $name ($($w.Pak.Title), $(if ($w.Part.csize -ge 1MB) { "{0:N1} MB" -f ($w.Part.csize / 1MB) } else { "{0:N0} KB" -f ($w.Part.csize / 1KB) }))..."; Save-CompLockPart $w.Part (Join-Path $newAddons $name) }
        else { Copy-Item (Join-Path $addons $name) (Join-Path $newAddons $name) }
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $new 'game\citadel\gameinfo.gi'), $gameinfo, $utf8)
    [IO.File]::WriteAllText((Join-Path $newAddons 'mods.txt'), $modsTxt, $utf8)
    $manifest = [ordered]@{
        source = Get-CompLockSite; options = $encoded; shareUrl = $shareUrl; siteGameBuild = $D.game
        fetchedAt = (Get-Date).ToString('o'); updatedOn = $updatedOn
        components = @($res.Components)
        paks = @(foreach ($name in $want.Keys) { $w = $want[$name]; [ordered]@{ name = $name; file = $w.Pak.File; title = $w.Pak.Title; crc = [uint32]$w.Part.crc; size = $w.Part.size } })
        knownOptions = $siteOptions
        knownChoices = $kc
        gameinfoOverrides = $overrides
    }
    Write-JsonFile (Join-Path $new 'complock.json') $manifest
    if (Test-Path $packDir) {
        $prevRoot = Join-Path (Split-Path $packDir) '.previous'
        New-Item -ItemType Directory -Force $prevRoot | Out-Null
        $prev = Join-Path $prevRoot ("$(Split-Path $packDir -Leaf)-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
        Move-Item $packDir $prev
        Get-ChildItem $prevRoot -Directory | Sort-Object Name -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force
        "Previous pack -> $prev"
    }
    Move-Item $new $packDir
    "Updated $packDir"
} elseif ($old) {
    $old['knownOptions'] = $siteOptions
    $old['options'] = $encoded; $old['shareUrl'] = $shareUrl
    Write-JsonFile $manifestPath $old
}

$newCfg = [ordered]@{ options = $encoded; knownOptions = $siteOptions; knownChoices = $kc }
if ($clCfg -and $clCfg.Contains('gameinfo')) { $newCfg['gameinfo'] = $clCfg['gameinfo'] }
if (-not $clCfg -or ($clCfg | ConvertTo-Json -Depth 5 -Compress) -ne ($newCfg | ConvertTo-Json -Depth 5 -Compress)) {
    $cfg['complock'] = $newCfg
    Write-JsonFile $Loadout $cfg
    "Saved in $(Split-Path $Loadout -Leaf): complock.options = '$encoded' (+ the options/choices seen so far)"
}
if ($changes -or $optsChanged) { "Next: pwsh scripts\Update-Mods.ps1 (reconciles overlays, audits) or pwsh scripts\Deploy.ps1" }
