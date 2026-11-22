---
name: deadlock-install-mods
description: Install, update, list, back up, restore or remove Deadlock mods (CompLock packs, GameBanana VPKs, custom overlays) with this repo's PowerShell scripts instead of a mod manager. Use when the user wants to install a new CompLock pack, add or remove a mod, re-apply mods after a Deadlock update, or check what is installed.
---

# Installing Deadlock mods

All commands run from the repo root with PowerShell 7 (`pwsh`). Background: `docs/how-mods-load.md`, `docs/complock.md`.

## Rules

- **Deadlock must be closed** (scripts refuse otherwise). Ask the user to close it; never kill the process yourself.
- Never edit `game\citadel\gameinfo.gi` or `addons\` by hand. Use the scripts, which back everything up to `backups\<timestamp>\` first.
- Mod managers (Grimoire, Deadlock Mod Manager) rewrite `gameinfo.gi` and `addons\` when they run. If the user still has one open or auto-launching, warn them.
- First time on a machine: `pwsh scripts\Setup-Tools.ps1` (downloads Source2Viewer-CLI into `tools\`).

## Look first

```powershell
pwsh scripts\Get-ModStatus.ps1      # build, search paths, loaded paks + titles, warnings
pwsh scripts\Find-ModConflicts.ps1  # files provided by more than one pak, and the winner
pwsh scripts\Restore-Backup.ps1     # list backups
```

## Normal path: loadout.json + Deploy

`loadout.json` describes the whole install:

```json
{
  "pack": "packs/complock",           // folder or zip laid out like the game (game\citadel\...)
  "overlays": ["hudpp-tweaks"],       // mods\<name> customizations, built and loaded first (they win)
  "extra": ["mods-bin/radio.vpk"],    // other standalone VPKs, loaded after the pack (they lose conflicts)
  "keepSearchPaths": []               // extra "Game <path>" lines to keep in gameinfo.gi
}
```

```powershell
pwsh scripts\Deploy.ps1 -WhatIf   # show the pak numbering plan
pwsh scripts\Deploy.ps1           # build overlays, back up, install
```

## Tasks

- **New CompLock pack downloaded:** replace `packs\complock` with the zip's contents (keep the `game\...` layout), then Deploy. Get the builder link with the user's options from `packs\complock\game\citadel\addons\mods.txt`.
- **Add a GameBanana / third-party VPK:** check it's really a `.vpk` (no exe/dll/bat). Put it in `mods-bin\` (gitignored), add it to `extra` (or to the front of the list if it must win), Deploy, then run `Find-ModConflicts.ps1` and tell the user what overrides what. Mods replacing the same HUD layouts as HUD++ will conflict all-or-nothing.
- **One-off install without loadout:** `pwsh scripts\Install-Pack.ps1 -Pack <zip|folder> [-Overlay a.vpk] [-Extra b.vpk] [-KeepSearchPath citadel/x]`.
- **After a Deadlock update** (status says the addons search path is missing): just `Deploy.ps1`. If it warns that `PGIVersion` differs from stock, the pack's `gameinfo.gi` is from another build, so tell the user to download a fresh CompLock pack (matchmaking may refuse otherwise).
- **Undo:** `pwsh scripts\Restore-Backup.ps1 -Name latest` (or a listed name). Restores back up the current state first.
- **Remove everything:** `pwsh scripts\Remove-Mods.ps1` (restores the saved stock `gameinfo.gi`, else asks the user to Verify integrity in Steam).

## Report back

State the final pak order (pak01 = highest priority), any warnings (dropped search paths, PGIVersion, conflicts) and that the game must be restarted to pick up changes.
