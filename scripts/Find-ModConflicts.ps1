#Requires -Version 7
<#
.SYNOPSIS
  Audits a set of paks: files several paks replace (and which wins), and vanilla files the mods
  replace that Valve has changed.
.DESCRIPTION
  Paks checked: -Vpk files, or with -Loadout the paks Deploy.ps1 would install (built overlays,
  the pack, extras), else the installed paks.
  Conflicts: a file in more than one pak; the lowest pak number wins. With -Loadout, an overlay
  replacing a file of its own base is expected and listed separately.
  -Vanilla also compares with Deadlock's own pak01:
    * vanilla files a mod replaces whose CRC changed since the baseline saved at the last Deploy
      (Valve updated the file; the mod's copy is outdated);
    * for replaced layouts (.vxml_c): panel ids the vanilla layout has and the mod's copy lacks.
      Game code looks panels up by id, so a missing id can crash the game ("Unable to find child")
      or silently drop a vanilla feature. Ids missing since the baseline are flagged NEW. Ids an overlay
      recreates from JS are listed in its mod.json "runtimeIds" and not reported.
  -SaveBaseline records the vanilla CRCs and missing ids as the new baseline (Deploy does this).
.EXAMPLE
  pwsh scripts\Find-ModConflicts.ps1
.EXAMPLE
  pwsh scripts\Find-ModConflicts.ps1 -Loadout -Vanilla
#>
param([string[]]$Vpk, [switch]$Loadout, [string]$LoadoutPath, [switch]$Vanilla, [switch]$SaveBaseline)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

# The paks, in load order: Name (label), Path, BaseOf (for overlays: the VPK they patch).
$paks = [Collections.Generic.List[object]]::new()
if ($Vpk) {
    foreach ($v in $Vpk -split ',' | Where-Object { $_ }) { $f = Get-Item (Resolve-Path $v); $paks.Add([pscustomobject]@{ Name = $f.Name; Path = $f.FullName; BaseOf = $null }) }
} elseif ($Loadout) {
    $cfg = Get-Loadout $LoadoutPath
    foreach ($n in @($cfg['overlays']) | Where-Object { $_ }) {
        $o = Get-Overlay $n
        $built = Join-Path (Get-RepoRoot) "build\$n.vpk"
        if (-not (Test-Path $built)) { throw "build\$n.vpk is missing; run Build-Overlay.ps1 -Name $n (or Deploy.ps1 -WhatIf)." }
        $paks.Add([pscustomobject]@{ Name = "overlay $n"; Path = $built; BaseOf = $(if ($o.Full) { $null } else { $o.BaseVpk }); RuntimeIds = @($o.Meta['runtimeIds'] | Where-Object { $_ }) })
    }
    if ($cfg['pack']) {
        $pc = Get-PackCitadel (Resolve-RepoPath $cfg['pack'])
        foreach ($p in Get-ChildItem "$pc\addons" -File | Where-Object Name -Match '^pak\d\d_dir\.vpk$' | Sort-Object Name) { $paks.Add([pscustomobject]@{ Name = "pack $($p.Name)"; Path = $p.FullName; BaseOf = $null }) }
    }
    foreach ($e in @($cfg['extra']) | Where-Object { $_ }) { $p = Resolve-RepoPath $e; $paks.Add([pscustomobject]@{ Name = "extra $(Split-Path $p -Leaf)"; Path = $p; BaseOf = $null }) }
} else {
    foreach ($p in Get-AddonPaks) { $paks.Add([pscustomobject]@{ Name = $p.Name; Path = $p.FullName; BaseOf = $null }) }
}
if (-not $paks) { 'No paks.'; return }

$owners = @{}
$lists = @{}
foreach ($p in $paks) {
    $lists[$p.Path] = Get-VpkListing $p.Path
    foreach ($path in $lists[$p.Path].Keys) {
        if ($path -in 'addoninfo.txt', 'modinfo.json') { continue }
        if (-not $owners[$path]) { $owners[$path] = [Collections.Generic.List[object]]::new() }
        $owners[$path].Add($p)
    }
}
$expected = [Collections.Generic.List[string]]::new()
$conflicts = [Collections.Generic.List[string]]::new()
foreach ($c in $owners.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | Sort-Object Name) {
    $win = $c.Value[0]; $rest = $c.Value | Select-Object -Skip 1
    $line = "{0}`n    wins: {1}   shadowed: {2}" -f $c.Name, $win.Name, (($rest | ForEach-Object Name) -join ', ')
    if ($win.BaseOf -and @($rest).Count -eq 1 -and $rest[0].Path -eq $win.BaseOf) { $expected.Add($c.Name) } else { $conflicts.Add($line) }
}
if ($expected) { "Overlay files replacing their base (expected): $($expected -join ', ')" }
if ($conflicts) { "CONFLICTS (only the winner's copy is used):"; $conflicts; "$($conflicts.Count) conflicting files." } else { 'No conflicts between paks.' }

if (-not $Vanilla -and -not $SaveBaseline) { return }

""
$gamePak = Join-Path (Get-CitadelPath) 'pak01_dir.vpk'
$build = Get-GameBuild
$vanillaList = Get-VpkListing $gamePak
$basePath = Get-StatePath 'vanilla-baseline.json'
$baseline = Read-JsonFile $basePath
if ($baseline) { "Vanilla check: game build $build; baseline from build $($baseline['gameBuild']), $($baseline['savedAt'])" }
else { "Vanilla check: game build $build; no baseline yet (saved by the next Deploy)" }

$replaced = [ordered]@{}   # path -> winning pak
foreach ($path in $owners.Keys | Sort-Object) { if ($vanillaList.ContainsKey($path)) { $replaced[$path] = $owners[$path][0] } }
foreach ($g in $replaced.GetEnumerator() | Group-Object { $_.Value.Name }) { "  $($g.Name) replaces $($g.Count) vanilla files" }

$changed = @(if ($baseline) { foreach ($path in $replaced.Keys) { $was = $baseline['crc'][$path]; if ($was -and $was -ne $vanillaList[$path]) { $path } } })
if ($changed) {
    "VALVE CHANGED $($changed.Count) file(s) that mods replace since the baseline (the mod's copy is based on the old file):"
    foreach ($path in $changed) {
        $risk = switch -Regex ($path) { '\.vxml_c$' { 'layout: may crash or hide new UI' } '\.(vcss_c|vjs_c|vts_c)$' { 'style/script' } default { 'asset: looks like the old version' } }
        "  $path  [$($replaced[$path].Name); $risk]"
    }
} elseif ($baseline) { "  None of the vanilla files the mods replace changed since the baseline." }

# Layout panel ids: vanilla vs the winning mod copy.
$layouts = @($replaced.Keys | Where-Object { $_ -like '*.vxml_c' })
$missing = [ordered]@{}
if ($layouts) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlaud_" + [guid]::NewGuid())
    try {
        $ids = { param($file) if (Test-Path $file) { @([regex]::Matches([IO.File]::ReadAllText($file), '\bid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) } }
        $okVanilla = Test-Path (Join-Path (Split-Path $gamePak) 'pak01_000.vpk')
        if ($okVanilla) { try { Invoke-S2V -i $gamePak -f ($layouts -join ',') -d -o "$tmp\vanilla\" -q | Out-Null } catch { $okVanilla = $false } }
        if (-not $okVanilla) { $missing = $null; Write-Warning "Couldn't read vanilla layouts (pak01 chunk files missing?); skipped the panel id check." }
        if ($okVanilla) {
            foreach ($g in $layouts | Group-Object { $replaced[$_].Path }) {
                $dir = "$tmp\mod$([Math]::Abs($g.Name.GetHashCode()))"
                Invoke-S2V -i $g.Name -f ($g.Group -join ',') -d -o "$dir\" -q | Out-Null
                foreach ($l in $g.Group) {
                    $src = ConvertTo-SourcePath $l
                    $v = & $ids (Join-Path "$tmp\vanilla" $src); $m = & $ids (Join-Path $dir $src)
                    $gone = @($v | Where-Object { $m -notcontains $_ -and $replaced[$l].RuntimeIds -notcontains $_ })
                    if ($gone) { $missing[$l] = $gone }
                }
            }
            if ($missing.Count) {
                "Mod layouts lacking panel ids that vanilla has (game code may look them up; NEW = not missing at the baseline):"
                foreach ($l in $missing.Keys) {
                    $was = if ($baseline -and $baseline['missingIds']) { @($baseline['missingIds'][$l]) } else { $null }
                    $new = if ($null -ne $was -and $baseline) { @($missing[$l] | Where-Object { $was -notcontains $_ }) } else { @() }
                    "  $(ConvertTo-SourcePath $l) [$($replaced[$l].Name)]: $($missing[$l] -join ', ')$(if ($new) { "   NEW: $($new -join ', ')" })"
                }
            } else { "All $($layouts.Count) replaced layouts keep every vanilla panel id." }
        }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

if ($SaveBaseline) {
    $crc = [ordered]@{}; foreach ($path in $replaced.Keys) { $crc[$path] = $vanillaList[$path] }
    Write-JsonFile $basePath ([ordered]@{ gameBuild = $build; savedAt = (Get-Date).ToString('o'); paks = @($paks | ForEach-Object Name); crc = $crc; missingIds = $missing })
    "Saved vanilla baseline -> $basePath"
}
