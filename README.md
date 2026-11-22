# deadlock-mods

Scripts and notes for running Deadlock mods **without a mod manager**: build and update a [CompLock](https://deadlockconfig.com) pack straight from deadlockconfig.com (or install any VPKs), keep personal fixes to those mods as small, versioned patches ("overlays") that are re-merged when a mod updates, and rebuild everything with one command after a game or mod update. It can also package the whole setup as a zip for friends.

Windows + PowerShell 7 + git. The only external tool is [Source2Viewer-CLI](https://github.com/ValveResourceFormat/ValveResourceFormat), downloaded by `Setup-Tools.ps1`.

## Quick start

```powershell
pwsh scripts\Setup-Tools.ps1          # once: downloads Source2Viewer-CLI into tools\
pwsh scripts\Update-Mods.ps1 -Check   # what's new: CompLock, GameBanana mods, overlay conflicts
pwsh scripts\Update-Mods.ps1 -Deploy  # update, reconcile overlays, audit, install (Deadlock must be closed)
pwsh scripts\Get-ModStatus.ps1        # what's installed, is gameinfo.gi healthy
```

On a fresh clone `Deploy.ps1` downloads everything it needs (the CompLock pack with the options in `loadout.json`, GameBanana bases of overlays). After a Deadlock update, run `Deploy.ps1` again; updates reset `gameinfo.gi`.

In game, Esc → the CompLock menu shows **Updated On: &lt;date&gt;** at the bottom: the date the installed set last changed. Hover it for what's installed.

## Layout

```
loadout.json          what to install: pack + CompLock options, overlays (win conflicts), extra VPKs
packs\                CompLock pack built by Update-CompLock.ps1 (+ .previous\ copies)   (gitignored)
mods\<name>\          overlays: mod.json + changes.patch (tracked); base\ + src\ working copies (gitignored)
mods-bin\             third-party VPKs: overlay bases, loadout.extra                     (gitignored)
build\                compiled overlays                                                  (gitignored)
dist\                 release zips made by New-Release.ps1                               (gitignored)
state\                version date, last deploy, vanilla baseline for the audit          (gitignored)
backups\              automatic backups of addons\ + gameinfo.gi; backups\stock\ = Valve's file per build (gitignored)
tools\                Source2Viewer-CLI, compile templates                               (gitignored)
scripts\              the tooling (see below)
docs\                 how it all works
.github\skills\       agent skills: install, customize, fix
```

`loadout.json`:

```json
{
  "pack": "packs/complock",
  "complock": { "options": "soundcap,particles:stock,ragdolls:off,fov:0" },
  "overlays": ["complock-updated-on", "hudpp-damage-numbers", "vanilla-particles", "sinners-statues-tracker"],
  "extra": [],
  "keepSearchPaths": []
}
```

`complock.options` is the `?pack=` value of a [Pack Builder](https://deadlockconfig.com/#build) link. The current one keeps the game's look: HUD++, gameinfo.gi, Sound stack update cap, Particle Pruning with stock tracers and hit effects, ragdolls on, stock FOV; cloth, low detail map, brighter lighting, HP bars and tick lines off.

## Scripts

| Script | Does |
|---|---|
| `Update-Mods.ps1` | Update CompLock + GameBanana mods, reconcile overlays, audit; `-Check` reports only, `-Deploy` installs |
| `Update-CompLock.ps1` | Build/update `packs\complock` from deadlockconfig.com with your options; reports changes and new options (never enables them) |
| `Deploy.ps1` | Build overlays from `loadout.json` and install everything; saves the audit baseline |
| `Install-Pack.ps1` | Install a pack folder/zip + `-Overlay` / `-Extra` VPKs, renumbering paks; backs up first |
| `Get-ModStatus.ps1` | Game build, search paths, loaded paks and titles, warnings |
| `Find-ModConflicts.ps1` | Files several paks replace and which wins; `-Loadout -Vanilla`: vanilla files Valve changed under the mods, panel ids missing from mod layouts |
| `Restore-Backup.ps1` | List backups / restore one (`-Name latest`) |
| `Remove-Mods.ps1` | Remove all paks, restore stock `gameinfo.gi` |
| `New-Overlay.ps1` | Start customizing files of a mod (`-Base <vpk>`, `-GameBanana <id>`, or the base game) |
| `Build-Overlay.ps1` | 3-way merge an overlay onto its (updated) base, save `changes.patch`, compile `build\<name>.vpk` |
| `New-Release.ps1` | Zip the loadout for friends (game-folder layout, README, credits); `-Publish` makes a GitHub release |
| `Expand-Vpk.ps1` | Unpack + decompile any VPK into an editable workspace |
| `Build-Vpk.ps1` | Pack a workspace/folder back into a VPK (compiles edited CSS/JS) |
| `Compile-Panorama.ps1` | `.js` → `.vjs_c`, `.css` → `.vcss_c` without Valve's tools |
| `Setup-Tools.ps1` | Download Source2Viewer-CLI |

## Overlays (customizing a mod)

```powershell
pwsh scripts\New-Overlay.ps1 -Name hudpp-tweaks -Base packs\complock\game\citadel\addons\pak01_dir.vpk -File panorama/scripts/hudpp_settings.js
# edit mods\hudpp-tweaks\src\panorama\scripts\hudpp_settings.js, add "hudpp-tweaks" to loadout.json overlays
pwsh scripts\Deploy.ps1
```

`base\` is the mod's original file, `src\` your copy. Git tracks only `changes.patch` (the diff between them), so the repo never holds the mods' own files, and when a mod updates `Build-Overlay.ps1` merges your edits onto the new version: clean merges are reported, conflicts stop the build with `<<<<<<<` markers in `src\`. CSS and JS can be changed freely; layout XML can't be recompiled here, so change panels from JS. See [docs/updating.md](docs/updating.md) and [docs/panorama.md](docs/panorama.md).

Overlays in this repo:
- `complock-updated-on`: "Updated On: &lt;date&gt;" footnote in the CompLock menu (date stamped at build time).
- `hudpp-damage-numbers`: per-hit gun and spirit damage numbers in their vanilla colors, from the first hit (HUD++ hid them and showed only a white running total, which Valve starts at the second hit).
- `vanilla-particles`: vanilla copies of effects Particle Pruning strips that show game state: the open-shop effect and Celeste's Light Eater aura (visible on structures too). Copied from the installed game at build time (`"build": "restore"`).
- `sinners-statues-tracker`: the Sinners and Statues Tracker moved left of the open scoreboard, under item tooltips, with compact rows; also restores the "+" in front of soul pickups that the tracker's outdated layout drops.

## Sharing with friends

```powershell
pwsh scripts\New-Release.ps1            # dist\deadlock-mods-<date>.zip + release notes
pwsh scripts\New-Release.ps1 -Publish   # gh release create v<yyyy.MM.dd>
```

The zip extracts over the Deadlock folder (`game\citadel\gameinfo.gi` + `addons\pakNN_dir.vpk` + `mods.txt`) and has a README with install, update and uninstall steps and the credits. Only publish mods you may share: leave one out with `-Exclude <overlay>` or `"release": false` in its `mod.json`, and the notes link to the original instead.

## Credits

All mods belong to their authors; this repo only installs them and keeps small patches.

- **CompLock** (HUD++, gameinfo.gi, Particle Pruning, Sound stack update cap, Cloth simulation off, HP Bars, Low detail map, ...) by **HoppCX** and **jcStani**, <https://deadlockconfig.com>. Brighter lighting by **BreadRollius**. Please get CompLock from their site, where its options, benchmarks and changelog live (it's free and ad/Ko-fi supported).
- **Sinners and Statues Tracker** by **Xaohs**, <https://gamebanana.com/mods/692472> (CC BY-NC-ND 4.0).
- **Deadlock Radio** by **BubbleGumXD**, <https://gamebanana.com/mods/720163> (fixed in an earlier session; see docs/case-studies.md).
- **Source2Viewer / ValveResourceFormat** (decompiling, VPK creation), <https://github.com/ValveResourceFormat/ValveResourceFormat>.
- [SteamTracking/GameTracking-Deadlock](https://github.com/SteamTracking/GameTracking-Deadlock) (vanilla files, convars), [Sqooky's guide](https://github.com/Sqooky/Complete-Guide-to-the-Modding-Deadlock-Workflow), [Divine Skins wiki](https://wiki.divineskins.gg/en/docs/deadlock/), [Deadlock Modding Notes](https://deadlockmodding.pages.dev/).

## Docs

- [How mods load](docs/how-mods-load.md): gameinfo.gi, pak numbering/priority, ConVars, matchmaking guard, updates
- [CompLock](docs/complock.md): what's in the pack, Pack Builder options and data, HUD++ internals
- [Updating, reconciling, releasing](docs/updating.md): the update flow, overlays as patches, the audit, releases
- [Panorama](docs/panorama.md): layout/CSS/JS reference for Deadlock, gotchas, compiling layouts
- [File formats](docs/resource-formats.md): VPK v2 and compiled Panorama resources
- [Case studies](docs/case-studies.md): earlier fixes (Deadlock Radio, Sinners & Statues tracker)

## Caveats

- Valve has no official mod support or policy for Deadlock. Cosmetic mods aren't known to be banned, but timers/trackers, wider FOV, removed particles and brighter lighting are "advantage" territory; that risk is yours.
- Valve blocks matchmaking when protected `gameinfo.gi` sections differ from stock, or in Tools mode. Only change `SearchPaths`/`ConVars`, and refresh the CompLock pack when the game updates.
- HUD mods break when Valve changes the layouts they replace. `Update-Mods.ps1` points these out (audit); expect to wait for a mod update after big patches.
