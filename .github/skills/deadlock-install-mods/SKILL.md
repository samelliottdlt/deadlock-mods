---
name: deadlock-install-mods
description: Install, update, list, back up, restore, remove or share Deadlock mods (CompLock packs, GameBanana VPKs, custom overlays) with this repo's PowerShell scripts instead of a mod manager. Use when the user wants to update CompLock or other mods, change CompLock options, add or remove a mod, re-apply mods after a Deadlock update, check what is installed, or make a release zip for friends.
---

# Installing and updating Deadlock mods

All commands run from the repo root with PowerShell 7 (`pwsh`). Background: `docs/how-mods-load.md`, `docs/complock.md`, `docs/updating.md`.

## Rules

- **Deadlock must be closed** for installs (scripts refuse otherwise). Ask the user to close it; never kill the process yourself.
- Never edit `game\citadel\gameinfo.gi` or `addons\` by hand. Use the scripts, which back everything up to `backups\<timestamp>\` first.
- Test script changes on a copied game folder first: `$env:DEADLOCK_PATH = '<copy>'` (needs `game\citadel\{gameinfo.gi,steam.inf,pak01_dir.vpk,addons\}`).
- Mod managers (Grimoire, Deadlock Mod Manager) rewrite `gameinfo.gi` and `addons\` when they run. If the user still has one open or auto-launching, warn them.
- **Never turn on a new CompLock option yourself.** The user keeps the game's look as intact as possible; report new options (Update-CompLock lists them) and let the user choose.
- First time on a machine: `pwsh scripts\Setup-Tools.ps1` (downloads Source2Viewer-CLI into `tools\`).

## Look first

```powershell
pwsh scripts\Get-ModStatus.ps1                     # build, search paths, loaded paks + titles, warnings
pwsh scripts\Update-Mods.ps1 -Check                # updates available, overlay merges pending, audit
pwsh scripts\Find-ModConflicts.ps1 -Loadout -Vanilla   # conflicts + vanilla files Valve changed under the mods
pwsh scripts\Restore-Backup.ps1                    # list backups
```

## Normal path: loadout.json + Update-Mods / Deploy

```json
{
  "pack": "packs/complock",                                        // built by Update-CompLock.ps1
  "complock": { "options": "soundcap,particles:stock,ragdolls:off,fov:0" },  // ?pack= value of a Pack Builder link
  "overlays": ["complock-updated-on", "sinners-statues-tracker"],  // mods\<name>, built and loaded first (they win)
  "extra": ["mods-bin/radio.vpk"],                                 // other standalone VPKs, loaded after the pack
  "keepSearchPaths": []                                            // extra "Game <path>" lines to keep in gameinfo.gi
}
```

```powershell
pwsh scripts\Update-Mods.ps1 -Deploy   # update CompLock + GameBanana mods, reconcile overlays, audit, install
pwsh scripts\Deploy.ps1 -WhatIf        # show the pak numbering plan
pwsh scripts\Deploy.ps1                # build overlays, back up, install, save audit baseline
```

## Tasks

- **Update CompLock:** `Update-CompLock.ps1` (or `Update-Mods.ps1`). Tell the user what changed (paks, gameinfo.gi, changelog) and list any NEW options with what they do; don't enable them.
- **Change CompLock options:** `pwsh scripts\Update-CompLock.ps1 -Options "<?pack= value>"` (saved in loadout.json), then Deploy. Grammar: `id`, `id:choice`, `id:off`, `fov:<n>` (`fov:0` = stock); see `docs/complock.md`.
- **Add a GameBanana mod:** check it's really a `.vpk` (no exe/dll/bat). `Save-GameBananaVpk <id> mods-bin\<name>.vpk` (module function; writes `.source.json` so Update-Mods checks for updates) or download by hand into `mods-bin\`, add it to `extra` (loses conflicts) or make it an overlay (`New-Overlay.ps1 -GameBanana <id> -Full`) if it needs changes. Deploy, then tell the user what the audit says. Mods replacing the same HUD layouts as HUD++ conflict all-or-nothing.
- **One-off install without loadout:** `pwsh scripts\Install-Pack.ps1 -Pack <zip|folder> [-Overlay a.vpk] [-Extra b.vpk] [-KeepSearchPath citadel/x]`.
- **After a Deadlock update** (status says the addons search path is missing): `Update-Mods.ps1 -Deploy`. If it warns that `PGIVersion` differs from stock, CompLock hasn't caught up with the build yet: tell the user (matchmaking may refuse).
- **Release for friends:** `pwsh scripts\New-Release.ps1` builds `dist\deadlock-mods-<date>.zip` + notes. **Ask the user before `-Publish`** whether every included mod may be redistributed; `-Exclude <overlay>` leaves one out (the notes link to the original). The tracker is CC BY-NC-ND (no modified copies without Xaohs' permission).
- **Undo:** `pwsh scripts\Restore-Backup.ps1 -Name latest` (or a listed name). Restores back up the current state first.
- **Remove everything:** `pwsh scripts\Remove-Mods.ps1` (restores the saved stock `gameinfo.gi`, else asks the user to Verify integrity in Steam).

## Report back

State the final pak order (pak01 = highest priority), the "Updated On" date, any warnings (dropped search paths, PGIVersion, conflicts, audit findings, new CompLock options) and that the game must be restarted to pick up changes.
