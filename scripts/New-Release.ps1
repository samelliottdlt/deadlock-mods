#Requires -Version 7
<#
.SYNOPSIS
  Packages the loadout (pack + overlays + extras, numbered like Deploy installs them) as a zip
  friends can extract into their Deadlock folder, and optionally publishes it as a GitHub release.
.DESCRIPTION
  Builds every overlay, then writes dist\deadlock-mods-<date>\ and dist\deadlock-mods-<date>.zip:
    game\citadel\gameinfo.gi             the pack's gameinfo.gi (addons search path ensured)
    game\citadel\addons\pakNN_dir.vpk    overlays, pack paks, extras, in Deploy's order
    game\citadel\addons\mods.txt         version, credits, what each pak is
    README.txt                           install / update / uninstall steps and credits
  plus dist\release-notes.md. <date> is the loadout's "Updated On" date (the one in the CompLock menu).
  Overlays whose mod.json has "release": false, and names passed to -Exclude, are left out; the
  notes say where to get the original mod instead.
  -Publish runs `gh release create v<yyyy.MM.dd>` with the zip (needs the GitHub CLI, logged in).
  Only publish third-party mods you are allowed to share; credits are added automatically.
.EXAMPLE
  pwsh scripts\New-Release.ps1
.EXAMPLE
  pwsh scripts\New-Release.ps1 -Publish
#>
param([string]$Loadout, [string[]]$Exclude = @(), [switch]$Publish, [switch]$Force)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force
$root = Get-RepoRoot
if (-not $Loadout) { $Loadout = Join-Path $root 'loadout.json' }
$cfg = Get-Loadout $Loadout
$Exclude = @($Exclude -split ',' | Where-Object { $_ })

$pack = Resolve-RepoPath $cfg['pack']
if (-not (Test-Path $pack) -and $cfg['complock']) { & (Join-Path $PSScriptRoot 'Update-CompLock.ps1') -Loadout $Loadout | Out-Host }
$included = [Collections.Generic.List[string]]::new()
$left = [Collections.Generic.List[object]]::new()
foreach ($n in @($cfg['overlays']) | Where-Object { $_ }) {
    $o = Get-Overlay $n
    if ($Exclude -contains $n -or $o.Meta['release'] -eq $false) { $left.Add($o); continue }
    & (Join-Path $PSScriptRoot 'Build-Overlay.ps1') -Name $n -Loadout $Loadout | Out-Host
    $included.Add($n)
}
$extra = @($cfg['extra'] | Where-Object { $_ -and $Exclude -notcontains $_ } | ForEach-Object { Resolve-RepoPath $_ })
$version = Get-LoadoutVersion $Loadout
$name = "deadlock-mods-$($version.UpdatedOn)"
$dist = Join-Path $root 'dist'
$out = Join-Path $dist $name
$zip = "$out.zip"
Remove-Item -Recurse -Force $out, $zip -ErrorAction SilentlyContinue

$packCitadel = Get-PackCitadel $pack
$plan = New-PakPlan $packCitadel @($included | ForEach-Object { Join-Path $root "build\$_.vpk" }) $extra
$citadel = Join-Path $out 'game\citadel'
Copy-PakPlan $plan (Join-Path $citadel 'addons')
$gi = Join-Path $packCitadel 'gameinfo.gi'
if (-not (Test-Path $gi)) { throw "The pack has no gameinfo.gi; a release needs one (the addons search path)." }
Set-GameInfoText (Join-Path $citadel 'gameinfo.gi') (Add-GameInfoSearchPaths (Get-Content $gi -Raw))

# Version, credits and changes of what is shipped.
$header = New-LoadoutHeader $Loadout $version @($left | ForEach-Object Name)
$build = try { Get-GameBuild } catch { $null }
$numbering = ($plan | ForEach-Object { "  $($_.Pak)  $((Get-AddonTitle $_.Files[0].FullName) ?? $_.Label)" }) -join "`n"
$packTxt = if (Test-Path "$packCitadel\addons\mods.txt") { (Get-Content "$packCitadel\addons\mods.txt" -Raw).TrimEnd() }
Set-Content (Join-Path $citadel 'addons\mods.txt') (@($header, "Paks in this release (pak01 wins conflicts):`n$numbering", $packTxt) -join "`n`n")
$missing = foreach ($o in $left) {
    foreach ($c in @($o.Meta['credits'])) { if ($c) { "  - $($c['name']) by $($c['by']): download it from $($c['url']) and follow its install steps (not included in this zip$(if ($c['license']) { "; license: $($c['license'])" }))." } }
}
$readme = @"
deadlock-mods $($version.Display)
$('=' * (14 + $version.Display.Length))

A ready-to-extract set of Deadlock mods: CompLock (HUD++ and the options below) plus small fixes
made with $(Get-RepoUrl). Made for Deadlock build $build.

INSTALL (Windows)
  1. Close Deadlock. Close any mod manager (Grimoire, Deadlock Mod Manager): they rewrite the same files.
  2. Steam > Deadlock > right click > Manage > Browse local files. This opens the Deadlock folder.
  3. If you have other mods: delete the pakNN_dir.vpk files in game\citadel\addons (they would mix with these).
  4. Extract this zip into that folder so its "game" folder merges with Deadlock's. Replace files when asked
     (game\citadel\gameinfo.gi and the paks).
  5. Start Deadlock. Esc > the CompLock menu shows "Updated On: $($version.Display)" at the bottom.

AFTER A DEADLOCK UPDATE
  Updates reset game\citadel\gameinfo.gi, so the mods stop loading. Extract the newest release again.
  If a release is older than the game update, matchmaking may refuse to start (gameinfo.gi is tied to a
  game build) or the HUD may break; remove the mods until a new release is out.

UNINSTALL
  Delete the pakNN_dir.vpk files in game\citadel\addons, then Steam > Deadlock > Properties >
  Installed Files > Verify integrity of game files (restores gameinfo.gi).
$(if ($missing) { "`nNOT INCLUDED`n$($missing -join "`n")`n" })
$header

Valve has no official mod policy for Deadlock. Cosmetic mods aren't known to be banned; use at your own risk.
"@
Set-Content (Join-Path $out 'README.txt') $readme
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip
$notes = Join-Path $dist 'release-notes.md'
$md = @"
Deadlock mods as of **$($version.Display)**$(if ($version.CompLock) { " (CompLock $(([datetime]$version.CompLock['updatedOn']).ToString('d MMM yyyy', [Globalization.CultureInfo]::InvariantCulture)))" }), for Deadlock build $build.

**Install:** close Deadlock, extract ``$name.zip`` into the Deadlock folder (Steam > Manage > Browse local files) so ``game`` merges, replace files. Full steps, update and uninstall notes: ``README.txt`` in the zip.

| pak | contents |
|---|---|
$(($plan | ForEach-Object { "| $($_.Pak) | $((Get-AddonTitle $_.Files[0].FullName) ?? $_.Label) |" }) -join "`n")
$(if ($missing) { "`n**Not included:**`n$(($missing | ForEach-Object { $_ -replace '^  ', '' }) -join "`n")`n" })
### Credits
All mods belong to their authors; this release only packages them with small fixes.
- **CompLock** (HUD++, gameinfo.gi, Particle Pruning, Sound stack cap, ...) by **HoppCX** and **jcStani**: <https://deadlockconfig.com>$(if ($version.CompLock) { " ([these options]($($version.CompLock['shareUrl'])))" })
$((Get-LoadoutCredits $Loadout | Where-Object { $_.Part -ne 'CompLock' -and $included -contains $_.Part } | ForEach-Object { "- **$($_.Name)** by **$($_.By)**: <$($_.Url)>$(if ($_.License) { " - $($_.License)" })" }) -join "`n")

### Changes in this release
$(($included | ForEach-Object { "- ``$_``: $((Get-Overlay $_).Meta['description'])" }) -join "`n")
"@
Set-Content $notes $md
"Release folder: $out"
"Zip:            $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
"Notes:          $notes"
"Tag:            $($version.Tag)"

if (-not $Publish) { "Publish with: pwsh scripts\New-Release.ps1 -Publish   (or gh release create $($version.Tag) `"$zip`" --notes-file `"$notes`")"; return }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) not found.' }
$exists = $false
& gh release view $version.Tag 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { $exists = $true }
if ($exists -and -not $Force) { throw "Release $($version.Tag) already exists. Use -Force to replace its zip and notes." }
if ($exists) {
    & gh release upload $version.Tag $zip --clobber
    & gh release edit $version.Tag --notes-file $notes
} else {
    & gh release create $version.Tag $zip --title "deadlock-mods $($version.Display)" --notes-file $notes
}
if ($LASTEXITCODE -ne 0) { throw 'gh failed' }
"Published $($version.Tag)"
