# How Deadlock loads mods

Facts verified on game build 6864 (Nov 2026) unless marked otherwise. Deadlock is Source 2; its game folder is `game\citadel`.

## The two things that must be true

1. **`gameinfo.gi` lists the addons folder** in `SearchPaths`:
   ```
   SearchPaths
   {
       Game_UILanguage   citadel_*LANGUAGE*
       Game_LowViolence  citadel_lv
       Mod               citadel
       Write             citadel
       Game              citadel/addons     <- this line
       Game              citadel
       Game              core
   }
   ```
   Search paths are read top to bottom and the **first copy of a file wins**, so `citadel/addons` must be above `Game citadel` (the vanilla `pak01_dir.vpk`).
   - Stock Valve `gameinfo.gi` has **no** addons line and no `Mod`/`Write` lines. `Mod citadel`/`Write citadel` are reported to prevent a "Unable to read default keybinding configuration" crash.
   - Since 2026-09-29 the language key is `Game_UILanguage`. Guides that say `Game_Language`, `AddonRoot` or `AddonConfig` are outdated.
   - **Every game update and every Steam "Verify integrity" restores the stock file**, and mods silently stop loading. `scripts\Get-ModStatus.ps1` warns about this; `scripts\Deploy.ps1` re-applies it.

2. **Each mod is a file named exactly `pakNN_dir.vpk`** (`01`-`99`) directly in `game\citadel\addons\`.
   - Not loaded: `pak1_dir.vpk`, `pak00_dir.vpk`, `pak100_dir.vpk`, `cool.vpk`, anything in a subfolder (that is why Grimoire's `addons\.disabled\` works as a "disabled" folder).
   - A mod can be one self-contained `pakNN_dir.vpk`, or chunked: `pakNN_dir.vpk` + `pakNN_000.vpk`, `pakNN_001.vpk`, ... (same NN).

## Priority: lower number wins

`pak01` is searched first, so when two paks contain the same file path, **the lower-numbered pak's copy is used** and the other is ignored (for that file only). CompLock, deadlockmodding.pages.dev and Sqooky's guide all agree; ignore sources that say the opposite.

Consequences:
- A customization that replaces some files of a mod must load **before** it (lower number). That is what "overlays" in this repo are; `Install-Pack.ps1` numbers overlays first.
- Replacing a whole file is all-or-nothing. Two mods that both replace `panorama/layout/hud.vxml_c` can't be combined by ordering; one of them wins completely. Use `scripts\Find-ModConflicts.ps1` to see these.
- At most 99 paks. Merge VPKs if you ever need more.

## The `ConVars` block in gameinfo.gi

`gameinfo.gi` has a `ConVars { "name" "value" }` block whose values are applied at startup. Configs like CompLock use it because many of the convars they set are `cheat` or `developmentonly`/`defensive` and **can't** be set from the console or `autoexec.cfg` (e.g. `r_farz`, `r_aspectratio`, `panorama_panel_occlusion`, `cl_disable_ragdolls`). Ordinary user convars (`citadel_damage_text_cumulative_mode`) would work in `autoexec` too.

Valve's limits:
- 124 convars carry the flag `gameinfo_cannot_override` and ignore gameinfo values (outline/glow visibility, `citadel_player_glow_disabled`, enemy reveal durations, shadow distance, `lb_*` lighting debug). See `DumpSource2/convars.txt` in [GameTracking-Deadlock](https://github.com/SteamTracking/GameTracking-Deadlock).
- **Matchmaking guard.** The localization string `Citadel_StartMatchmaking_UnverifiedPGI` says: *"Unable to enter matchmaking while any party member is running Tools-mode, or has unsupported changes to the following sections of their 'gameinfo.gi': Engine2, MaterialSystem2, NetworkSystem, Particles, RenderSystem, SceneSystem, WorldRenderer."* `PGIVersion` at the top of the file is a hash tied to those sections. `SearchPaths` and `ConVars` are not in the list.
  - Rule for our own edits: only touch `SearchPaths` and `ConVars`. Never hand-edit the guarded sections.
  - A pack's `gameinfo.gi` is a full copy of Valve's file from the build it was made for. If Valve changes the file (new `PGIVersion`), an old pack's copy may block matchmaking. `Install-Pack.ps1` compares against the stock copy saved in `backups\stock\` and warns.

## What survives an update

| Thing | After a game update / Verify |
|---|---|
| `addons\pakNN_dir.vpk` | kept |
| `gameinfo.gi` | **reset to stock**, so mods stop loading |
| Panorama mods (HUD) | may **crash or break** if Valve changed the files they replace (`FATAL ERROR: Unable to find child '...' in layout file '...'`). Remove the HUD pak, wait for a mod update, or re-merge your overlay |

## Where things live

```
<Steam library>\steamapps\common\Deadlock\
  game\citadel\gameinfo.gi          search paths + convars (edit via scripts only)
  game\citadel\steam.inf            ClientVersion = game build number
  game\citadel\pak01_dir.vpk        vanilla game files (+ pak01_000.vpk ... chunks)
  game\citadel\addons\              mods: pak01_dir.vpk ... pak99_dir.vpk, mods.txt (notes, ignored by game)
  game\citadel\cfg\                 autoexec.cfg etc.
```

`citadel_mods_*.txt` localization files are about in-game item "mods" (upgrades), not about modding.
