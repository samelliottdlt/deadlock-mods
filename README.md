# deadlock-mods

Scripts and notes for running Deadlock mods **without a mod manager**: install a [CompLock](https://deadlockconfig.com) pack (or any VPKs), keep personal customizations of those mods as small, versioned source overlays, and rebuild everything with one command after a game or pack update.

Windows + PowerShell 7. The only external tool is [Source2Viewer-CLI](https://github.com/ValveResourceFormat/ValveResourceFormat), downloaded by `Setup-Tools.ps1`.

## Quick start

```powershell
pwsh scripts\Setup-Tools.ps1          # once: downloads Source2Viewer-CLI into tools\
# put the CompLock zip's contents in packs\complock (game\citadel\...)
pwsh scripts\Deploy.ps1 -WhatIf       # preview pak order
pwsh scripts\Deploy.ps1               # back up + install (Deadlock must be closed)
pwsh scripts\Get-ModStatus.ps1        # what's installed, is gameinfo.gi healthy
```

After a Deadlock update, run `Deploy.ps1` again; updates reset `gameinfo.gi`.

## Layout

```
loadout.json          what to install: pack, overlays (win conflicts), extra VPKs
packs\                downloaded packs, e.g. packs\complock\game\citadel\...   (gitignored)
mods\<name>\          overlays: mod.json + src\ with only the files you changed  (tracked)
mods-bin\             third-party VPKs referenced from loadout.extra              (gitignored)
build\                compiled overlays                                          (gitignored)
backups\              automatic backups of addons\ + gameinfo.gi; backups\stock\ = Valve's file per build (gitignored)
tools\                Source2Viewer-CLI, compile templates                       (gitignored)
scripts\              the tooling (see below)
docs\                 how it all works
.github\skills\       agent skills: install, customize, fix
```

## Scripts

| Script | Does |
|---|---|
| `Deploy.ps1` | Build overlays from `loadout.json` and install everything |
| `Install-Pack.ps1` | Install a pack folder/zip + `-Overlay` / `-Extra` VPKs, renumbering paks; backs up first |
| `Get-ModStatus.ps1` | Game build, search paths, loaded paks and titles, warnings |
| `Find-ModConflicts.ps1` | Files provided by several paks and which one wins |
| `Restore-Backup.ps1` | List backups / restore one (`-Name latest`) |
| `Remove-Mods.ps1` | Remove all paks, restore stock `gameinfo.gi` |
| `New-Overlay.ps1` | Start customizing files of a mod (or the base game) |
| `Build-Overlay.ps1` | Compile an overlay into `build\<name>.vpk` |
| `Expand-Vpk.ps1` | Unpack + decompile any VPK into an editable workspace |
| `Build-Vpk.ps1` | Pack a workspace/folder back into a VPK (compiles edited CSS/JS) |
| `Compile-Panorama.ps1` | `.js` → `.vjs_c`, `.css` → `.vcss_c` without Valve's tools |
| `Setup-Tools.ps1` | Download Source2Viewer-CLI |

## Customizing a mod (example)

```powershell
pwsh scripts\New-Overlay.ps1 -Name hudpp-tweaks -Base packs\complock\game\citadel\addons\pak01_dir.vpk -File panorama/scripts/hudpp_settings.js
# edit mods\hudpp-tweaks\src\panorama\scripts\hudpp_settings.js, add "hudpp-tweaks" to loadout.json overlays
pwsh scripts\Deploy.ps1
```

CSS and JS can be changed freely. Layout XML can't be recompiled here (binary format); change panels from JS instead. See [docs/panorama.md](docs/panorama.md).

## Docs

- [How mods load](docs/how-mods-load.md): gameinfo.gi, pak numbering/priority, ConVars, matchmaking guard, updates
- [CompLock](docs/complock.md): what's in the pack, Pack Builder options, HUD++ internals
- [Panorama](docs/panorama.md): layout/CSS/JS reference for Deadlock, gotchas, compiling layouts
- [File formats](docs/resource-formats.md): VPK v2 and compiled Panorama resources
- [Case studies](docs/case-studies.md): earlier fixes (Deadlock Radio, Sinners & Statues tracker)

## Caveats

- Valve has no official mod support or policy for Deadlock. Cosmetic mods aren't known to be banned, but timers/trackers, wider FOV, removed particles and brighter lighting are "advantage" territory; that risk is yours.
- Valve blocks matchmaking when protected `gameinfo.gi` sections differ from stock, or in Tools mode. Only change `SearchPaths`/`ConVars`, and refresh the CompLock pack when the game updates.
- HUD mods break when Valve changes the layouts they replace. Expect to wait for (or re-merge with) a pack update after big patches.
- Other references: [Sqooky's guide](https://github.com/Sqooky/Complete-Guide-to-the-Modding-Deadlock-Workflow), [Divine Skins wiki](https://wiki.divineskins.gg/en/docs/deadlock/), [Deadlock Modding Notes](https://deadlockmodding.pages.dev/), [GameTracking-Deadlock](https://github.com/SteamTracking/GameTracking-Deadlock).
