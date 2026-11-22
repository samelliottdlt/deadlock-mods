#Requires -Version 7
<#
.SYNOPSIS
  Reconciles an overlay (mods\<Name>) with its base and compiles it into build\<Name>.vpk.
.DESCRIPTION
  1. Sets up the local working copies when missing (fresh clone): base\ is decompiled from the base
     VPK (downloaded first if mod.json has a source) and src\ = base\ + changes.patch.
  2. Reconciles: for every file whose copy in the base VPK differs from base\ (the mod was updated),
     your edits are 3-way merged onto the new version (git merge-file: src\ = ours, base\ = old,
     VPK = new). Clean merges are reported; conflicts are left in src\ as <<<<<<< markers and the
     build stops until you resolve them.
  3. Saves your edits as changes.patch (+ base-hashes.json), the tracked form of the overlay.
  4. Compiles src\ (.js/.css; other files copied) into build\<Name>.vpk: only your files, or with
     "build": "full" in mod.json the whole base VPK with your files replacing its own.
  JS/CSS files can contain {{DLM_UPDATED_ON}}, {{DLM_COMPLOCK_DATE}} and {{DLM_DETAILS}} when mod.json
  has "stamp": true; they are replaced by the loadout's version date and contents at build time.
  With "build": "restore" none of the above happens: the listed compiled paths (wildcards allowed) are
  copied unchanged from the base VPK, e.g. "base": "game" to bring back vanilla files another pak replaces.
.EXAMPLE
  pwsh scripts\Build-Overlay.ps1 -Name hudpp-tweaks
#>
param([Parameter(Mandatory)][string]$Name, [string]$Loadout, [switch]$AllowEmptyPatch)
Import-Module (Join-Path $PSScriptRoot 'DeadlockMods.psm1') -Force

$o = Get-Overlay $Name
Initialize-OverlayBaseVpk $o
if (-not $o.Files) { throw "mods\$Name\mod.json lists no files." }
if ($o.Restore) {
    # Unchanged copies of base files (e.g. vanilla files another pak replaces), taken fresh on every build.
    $paths = @(Resolve-OverlayRestoreFiles $o)
    if (-not $paths) { throw "mods\$Name\mod.json: no file matches in $($o.BaseVpk)." }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlovl_" + [guid]::NewGuid())
    try {
        Invoke-S2V -i $o.BaseVpk -f ($paths -join ',') -o "$tmp\" -q | Out-Null
        $got = @(Get-ChildItem -Recurse -File $tmp -ErrorAction SilentlyContinue).Count
        if ($got -ne $paths.Count) { throw "Extracted $got of $($paths.Count) files from $($o.BaseVpk)." }
        $out = New-OverlayVpk $o $tmp
        "Built $out ($($paths.Count) files restored from $(if ($o.Meta['base'] -eq 'game') { 'the game' } else { $o.BaseVpk }))"
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    return
}
$listing = Get-VpkListing $o.BaseVpk
$inBase = @{}
foreach ($f in $o.Files) { $inBase[$f] = $listing.ContainsKey((ConvertTo-CompiledPath $f)) }
$present = @($o.Files | Where-Object { $inBase[$_] })
$hashes = (Read-JsonFile $o.HashesPath) ?? @{}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("dlovl_" + [guid]::NewGuid())
$up = Join-Path $tmp 'upstream'

try {
    Export-VpkSources $o.BaseVpk @($present | ForEach-Object { ConvertTo-CompiledPath $_ }) $up

    # 1. Local working copies.
    if (-not (Test-Path $o.SrcDir)) {
        if (-not (Test-Path $o.BaseDir)) {
            foreach ($f in $present) { Write-Text (Join-Path $o.BaseDir $f) (Read-Text (Join-Path $up $f)) }
            $stale = @($present | Where-Object { $hashes[$_] -and $hashes[$_] -ne (Get-FileSha (Join-Path $up $_)) })
            if ($stale) { Write-Warning "The base changed since changes.patch was made ($($stale -join ', ')); trying to apply it anyway." }
        }
        New-Item -ItemType Directory -Force $o.BaseDir | Out-Null
        # Patch a temporary copy, so a failed apply never leaves an unpatched src\ behind.
        $work = Join-Path $tmp 'src'
        Copy-Item -Recurse $o.BaseDir $work
        Invoke-OverlayPatch $o $work
        Move-Item $work $o.SrcDir
        "Set up mods\$Name\src from base + changes.patch"
    } elseif (-not (Test-Path $o.BaseDir)) {
        $stale = @($present | Where-Object { -not $hashes[$_] -or $hashes[$_] -ne (Get-FileSha (Join-Path $up $_)) })
        if ($stale) { throw "mods\$Name\base is missing and the base VPK changed since the overlay was made ($($stale -join ', ')), so your edits can't be merged automatically. Move src\ away, run Build-Overlay again (it recreates src\ from changes.patch) and compare." }
        foreach ($f in $present) { Write-Text (Join-Path $o.BaseDir $f) (Read-Text (Join-Path $up $f)) }
    }

    # 2. Reconcile with the current base.
    $conflicts = [Collections.Generic.List[string]]::new()
    foreach ($f in $o.Files) {
        $old = Join-Path $o.BaseDir $f; $new = Join-Path $up $f; $ours = Join-Path $o.SrcDir $f
        if (-not $inBase[$f]) {
            if (Test-Path $old) { Write-Warning "$f is no longer in the base VPK; the overlay now adds it as a new file."; Remove-Item $old }
            continue
        }
        if (-not (Test-Path $old)) {
            Write-Warning "$f is now also in the base VPK; your copy replaces it. Compare: git diff --no-index `"$new`" `"$ours`""
            Write-Text $old (Read-Text $new); continue
        }
        if ((Get-FileSha $old) -eq (Get-FileSha $new)) { continue }
        if (-not (Test-Path $ours)) { Write-Text $old (Read-Text $new); continue }
        $merged = Join-Path $tmp 'merged'
        Copy-Item $ours $merged -Force
        & git merge-file -L "ours (mods\$Name\src)" -L 'old base' -L 'new base' $merged $old $new 2>$null
        $n = $LASTEXITCODE
        if ($n -lt 0 -or $n -gt 127) { throw "git merge-file failed on $f" }
        Write-Text $ours (Read-Text $merged)
        Write-Text $old (Read-Text $new)
        if ($n -eq 0) { "UPSTREAM CHANGED, merged cleanly: $f" }
        else { $conflicts.Add($f); Write-Warning "UPSTREAM CHANGED, $n conflict(s) in mods\$Name\src\$($f.Replace('/', '\'))" }
    }
    $marked = @($o.Files | Where-Object { (Test-Path (Join-Path $o.SrcDir $_)) -and (Test-ConflictMarkers (Join-Path $o.SrcDir $_)) })
    if ($marked) {
        throw "Overlay $Name has unresolved merge conflicts in: $($marked -join ', '). Edit the <<<<<<< / ======= / >>>>>>> blocks in mods\$Name\src (keep upstream's change and re-apply ours), then build again."
    }

    # 3. The tracked form of the overlay.
    $gone = @($o.Files | Where-Object { -not (Test-Path (Join-Path $o.SrcDir $_)) })
    if ($gone) { throw "mods\$Name\src is missing $($gone -join ', ') (listed in mod.json). Restore them, or delete src\ to recreate it from changes.patch; changes.patch was not touched." }
    $patch = Get-OverlayPatchText $o
    $oldPatch = if (Test-Path $o.Patch) { Read-Text $o.Patch } else { $null }
    if (-not $patch -and $oldPatch -and -not $AllowEmptyPatch) {
        throw "src\ now equals base\, which would empty changes.patch and drop all edits of $Name. If that's intended, build with -AllowEmptyPatch; otherwise delete src\ to recreate it from changes.patch."
    }
    if ($patch -ne $oldPatch) { Write-Text $o.Patch $patch; "changes.patch updated" }
    $newHashes = [ordered]@{}
    foreach ($f in $present) { $newHashes[$f] = Get-FileSha (Join-Path $o.BaseDir $f) }
    Write-JsonFile $o.HashesPath $newHashes

    # 4. Compile.
    $stage = Join-Path $tmp 'stage'; $tpl = Join-Path $tmp 'templates'
    New-Item -ItemType Directory -Force $stage, $tpl | Out-Null
    if ($o.Full) { Invoke-S2V -i $o.BaseVpk -o "$stage\" -q | Out-Null }
    if ($present) { Invoke-S2V -i $o.BaseVpk -f (($present | ForEach-Object { ConvertTo-CompiledPath $_ }) -join ',') -o "$tpl\" -q | Out-Null }
    $stamp = $null
    if ($o.Meta['stamp']) {
        $v = Get-LoadoutVersion $Loadout
        $credits = Get-LoadoutCredits $Loadout
        $cl = @($credits | Where-Object Part -EQ 'CompLock')
        $details = @("Updated On $($v.Display)")
        $clDate = if ($v.CompLock -and $v.CompLock['updatedOn']) { ([datetime]$v.CompLock['updatedOn']).ToString('d MMM yyyy', [Globalization.CultureInfo]::InvariantCulture) }
        if ($cl) { $details += "CompLock$(if ($clDate) { " $clDate" }): " + (($cl | ForEach-Object Name) -join ', ') }
        $details += @($credits | Where-Object Part -NE 'CompLock' | ForEach-Object { "$($_.Name) by $($_.By)" })
        $js = { param($s) $s.Replace('\', '\\').Replace('"', '\"').Replace("'", "\'").Replace("`n", '\n') }
        $stamp = @{ '{{DLM_UPDATED_ON}}' = & $js $v.Display; '{{DLM_COMPLOCK_DATE}}' = & $js ($clDate ?? ''); '{{DLM_DETAILS}}' = & $js ($details -join "`n") }
        "Stamped: Updated On $($v.Display)$(if ($clDate) { ", CompLock $clDate" })"
    }
    foreach ($f in $o.Files) {
        $src = Join-Path $o.SrcDir $f
        if (-not (Test-Path $src)) { Write-Warning "src\$f is missing; skipped"; continue }
        $compiled = ConvertTo-CompiledPath $f
        $ext = [IO.Path]::GetExtension($f).ToLowerInvariant()
        if ($ext -in '.js', '.css') {
            $srcIn = $src
            if ($stamp) {
                $text = Read-Text $src
                foreach ($k in $stamp.Keys) { $text = $text.Replace($k, $stamp[$k]) }
                $srcIn = Join-Path $tmp ("stamped" + $ext); Write-Text $srcIn $text
            }
            $template = Join-Path $tpl $compiled
            $tplArgs = if (Test-Path $template) { @{ Template = $template } } else { @{} }
            & (Join-Path $PSScriptRoot 'Compile-Panorama.ps1') -Source $srcIn -Output (Join-Path $stage $compiled) @tplArgs
        } elseif ($ext -eq '.xml') {
            $old = Join-Path $o.BaseDir $f
            if ((Test-Path $old) -and (Get-FileSha $old) -eq (Get-FileSha $src)) { continue }
            throw "src\$f (a layout) was edited, but layouts can't be compiled here. Revert it and change the panels from JS (docs\panorama.md)."
        } else {
            New-Item -ItemType Directory -Force (Split-Path (Join-Path $stage $f)) | Out-Null
            Copy-Item $src (Join-Path $stage $f) -Force
        }
    }
    if (-not (Get-ChildItem -Recurse -File $stage)) { throw 'Nothing to pack.' }
    $out = New-OverlayVpk $o $stage
    "Built $out ($((Get-ChildItem -Recurse -File $stage).Count) files$(if ($o.Full) { ', full copy of the base' }))"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
