---
name: deadlock-fix-mods
description: Diagnose Deadlock mod problems - mods not loading, crash on launch after an update, matchmaking refused because of gameinfo.gi, two mods overriding each other, a HUD element missing. Use when the user reports that mods stopped working or the game misbehaves with mods installed.
---

# Troubleshooting Deadlock mods

Start with facts, not guesses:

```powershell
pwsh scripts\Get-ModStatus.ps1
pwsh scripts\Find-ModConflicts.ps1 -Loadout -Vanilla   # conflicts, vanilla files Valve changed since the last Deploy, panel ids mod layouts lack
```

| Symptom | Likely cause | Fix |
|---|---|---|
| No mods apply | Update/Verify reset `gameinfo.gi` (status: "citadel/addons is NOT a search path") | `pwsh scripts\Deploy.ps1` |
| A mod doesn't apply | Wrong file name (status lists "Ignored by the game"), or another pak with a lower number replaces the same file | Rename via Deploy (it renumbers), reorder in `loadout.json` |
| Crash at launch: `Unable to find child 'X' in layout file 'Y'` | A HUD mod (or overlay) replaces a layout Valve changed (the audit lists it under VALVE CHANGED / missing panel ids) | Remove the HUD pak (`Restore-Backup` / edit loadout), `Update-Mods.ps1` for a mod update, or recreate the panel from the mod's JS |
| Overlay build stops with merge conflicts | The base mod updated a part we changed | `deadlock-customize-mods` skill: resolve the markers in `mods\<name>\src`, rebuild |
| Vanilla UI detail missing only with mods (e.g. a label) | A mod's layout copy is older than the game's | Audit: missing panel ids; restore from JS (see the tracker's `GoldPlusPrefix` fix) |
| Crash: `Unable to read default keybinding configuration` | `Mod citadel` / `Write citadel` missing from SearchPaths | Re-deploy a pack whose gameinfo has them |
| "Unable to enter matchmaking ... unsupported changes to ... gameinfo.gi" | Guarded sections (Engine2, MaterialSystem2, NetworkSystem, Particles, RenderSystem, SceneSystem, WorldRenderer) differ from stock / stale pack for this build, or `-tools` launch option | Get a fresh CompLock pack for the current build, Deploy; or `Remove-Mods.ps1` to confirm; remove `-tools` |
| HUD element/menu missing after update | Mod relies on a panel ID/API Valve changed | `-condebug`, read `game\citadel\console.log`; compare the vanilla file's history in GameTracking-Deadlock |
| An effect/aura/visual cue missing (only with mods) | Particle Pruning replaced the `.vpcf_c` with a slimmer copy | Find it (`docs/complock.md` → Particle Pruning), add its paths to `mods\vanilla-particles\mod.json`, Deploy |
| Damage numbers missing/merged | HUD++ hides per-hit numbers (`HudppDmg`) | `hudpp-damage-numbers` overlay (`docs/complock.md` → damage numbers) |
| Convar from gameinfo has no effect | Convar has `gameinfo_cannot_override` | Check `DumpSource2/convars.txt` in GameTracking-Deadlock; nothing to do |

## Diagnosing a specific file

```powershell
$s2v = 'tools\s2v\Source2Viewer-CLI.exe'
& $s2v -i <pak> -l -f panorama/layout/          # what a pak replaces
& $s2v -i <pak> --vpk_search "PanelId" -f panorama/
& $s2v -i steam:1422450/game/citadel/pak01_dir.vpk -f panorama/layout/hud.vxml_c -d -o work\vanilla\
```

Bisect by disabling paks: edit `loadout.json` (remove entries), Deploy, have the user test, then restore. Every Deploy is backed up, so it's reversible with `Restore-Backup.ps1`.

Ask the user to run Deadlock with `-condebug` (Steam → Deadlock → Properties → Launch options) when you need logs. Never use `-tools` for play.
