#Requires -Version 7
<#
.SYNOPSIS
  Updates every mod in loadout.json, reconciles your overlays with the updates, audits, and
  optionally installs.
.DESCRIPTION
  1. CompLock: Update-CompLock.ps1 (new paks/gameinfo from deadlockconfig.com; new options are
     reported, never enabled).
  2. GameBanana mods (overlay bases with "source": { "gamebanana": <id> } and extra VPKs downloaded
     with a .source.json next to them): downloads a newer file if the author uploaded one. The old
     VPK is kept as <name>.vpk.previous.
  3. Overlays: Build-Overlay.ps1 for each, which 3-way merges your edits onto updated base files and
     stops on conflicts.
  4. Audit: Find-ModConflicts.ps1 -Loadout -Vanilla (files several paks replace, vanilla files Valve
     changed since the last Deploy, vanilla panel ids missing from mod layouts).
  5. -Deploy: Deploy.ps1 if nothing above failed (Deadlock must be closed).
.EXAMPLE
  pwsh scripts\Update-Mods.ps1 -Check
.EXAMPLE
  pwsh scripts\Update-Mods.ps1 -Deploy
#>
param([string]$Loadout, [switch]$Check, [switch]$Deploy)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force
if (-not $Loadout) { $Loadout = Join-Path (Get-RepoRoot) 'loadout.json' }
$cfg = Get-Loadout $Loadout
$problems = [Collections.Generic.List[string]]::new()
$checkArg = @{}; if ($Check) { $checkArg.Check = $true }

"== CompLock"
if ($cfg['complock']) {
    try { & (Join-Path $PSScriptRoot 'Update-CompLock.ps1') -Loadout $Loadout @checkArg } catch { $problems.Add("CompLock: $_"); Write-Warning "$_" }
} else { "  (no complock section in loadout.json; pack '$($cfg['pack'])' is managed by hand)" }

""
"== GameBanana mods"
$sources = [Collections.Generic.List[object]]::new()
foreach ($n in @($cfg['overlays']) | Where-Object { $_ }) {
    $o = Get-Overlay $n
    if ($o.Meta['source'] -and $o.Meta['source']['gamebanana']) { $sources.Add([pscustomobject]@{ Label = "overlay $n"; Vpk = $o.BaseVpk; Id = [int]$o.Meta['source']['gamebanana'] }) }
}
foreach ($e in @($cfg['extra']) | Where-Object { $_ }) {
    $p = Resolve-RepoPath $e; $s = Read-JsonFile "$p.source.json"
    if ($s -and $s['gamebanana']) { $sources.Add([pscustomobject]@{ Label = "extra $e"; Vpk = $p; Id = [int]$s['gamebanana'] }) }
}
if (-not $sources) { "  (none)" }
foreach ($s in $sources) {
    try {
        $mod = Get-GameBananaMod $s.Id
        $newest = $mod.Files | Select-Object -First 1
        $have = Read-JsonFile "$($s.Vpk).source.json"
        $line = "  $($mod.Name) by $($mod.Author) [$($s.Label)]: newest file $($newest.Name) ($($newest.Added.ToString('yyyy-MM-dd')))"
        if (-not (Test-Path $s.Vpk)) { $line += " - not downloaded yet" }
        elseif ($have -and [int]$have['fileId'] -eq $newest.Id) { $line += " - up to date"; $line; continue }
        else { $line += " - UPDATE AVAILABLE (have $(if ($have) { "$($have['file']) from $(([datetime]$have['added']).ToString('yyyy-MM-dd'))" } else { 'an unknown version' }))" }
        $line
        if ($Check) { continue }
        if (Test-Path $s.Vpk) { Copy-Item $s.Vpk "$($s.Vpk).previous" -Force }
        Save-GameBananaVpk $s.Id $s.Vpk $newest | Out-Null
        "    downloaded -> $($s.Vpk)"
    } catch { $problems.Add("$($s.Label): $_"); Write-Warning "$($s.Label): $_" }
}

""
"== Overlays"
$ov = @($cfg['overlays'] | Where-Object { $_ })
if (-not $ov) { "  (none)" }
foreach ($n in $ov) {
    if ($Check) {
        # Report only: compare base\ with the base VPK without touching src\.
        try {
            $o = Get-Overlay $n
            if (-not (Test-Path $o.BaseVpk) -or -not (Test-Path $o.BaseDir)) { "  ${n}: will be set up on the next build"; continue }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlchk_" + [guid]::NewGuid())
            $listing = Get-VpkListing $o.BaseVpk
            $present = @($o.Files | Where-Object { $listing.ContainsKey((ConvertTo-CompiledPath $_)) })
            Export-VpkSources $o.BaseVpk @($present | ForEach-Object { ConvertTo-CompiledPath $_ }) $tmp
            $changed = @($present | Where-Object { -not (Test-Path (Join-Path $o.BaseDir $_)) -or (Get-FileSha (Join-Path $o.BaseDir $_)) -ne (Get-FileSha (Join-Path $tmp $_)) })
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
            "  ${n}: $(if ($changed) { "base changed in $($changed -join ', ') -> will be merged on the next build" } else { 'base unchanged' })"
        } catch { $problems.Add("overlay ${n}: $_"); Write-Warning "${n}: $_" }
        continue
    }
    "  -- $n"
    try { & (Join-Path $PSScriptRoot 'Build-Overlay.ps1') -Name $n -Loadout $Loadout | ForEach-Object { "     $_" } }
    catch { $problems.Add("overlay ${n}: $_"); Write-Warning "${n}: $_" }
}

""
"== Audit"
try { & (Join-Path $PSScriptRoot 'Find-ModConflicts.ps1') -Loadout -LoadoutPath $Loadout -Vanilla | ForEach-Object { "  $_" } }
catch { Write-Warning "Audit skipped: $_" }

""
if ($problems) {
    "PROBLEMS:"; $problems | ForEach-Object { "  $_" }
    if ($Deploy) { 'Not deploying until these are fixed.' }
    exit 1
}
if ($Check) { 'Check done. Run without -Check to update, add -Deploy to install.'; return }
if ($Deploy) { "== Deploy"; & (Join-Path $PSScriptRoot 'Deploy.ps1') -Loadout $Loadout }
else { 'Updated and reconciled. Install with: pwsh scripts\Deploy.ps1 (Deadlock closed)' }
