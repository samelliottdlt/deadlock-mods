---
name: deadlock-customize-mods
description: Customize or fix Deadlock UI mods (HUD++/CompLock, GameBanana Panorama mods) or the vanilla HUD by editing their Panorama CSS/JS and building an overlay VPK. Use when the user wants to move, resize, recolor, hide or change behavior of a HUD element, change a mod's defaults, or fix a broken Panorama mod.
---

# Customizing Deadlock mods (overlays)

Read `docs/panorama.md` (Panorama XML/CSS/JS, API, gotchas) before editing; `docs/resource-formats.md` explains why CSS/JS can be rebuilt but layouts can't. Prior worked examples: `docs/case-studies.md`.

## Model

An **overlay** is `mods\<name>\`:
- `mod.json`: `{ "base": "<vpk path relative to repo | absolute | game>", "description": "..." }`
- `src\panorama\...`: full copies of the decompiled files you changed (or new files)
- `base-hashes.json`: hash of each base file when copied (detects upstream changes)

`Build-Overlay.ps1` compiles only the changed/new files into `build\<name>.vpk`; `Deploy.ps1` loads overlays ahead of the pack, so their files win. The base mod stays untouched.

## Workflow

1. **Find the file.** Decompile the whole mod to a scratch folder and search it:
   ```powershell
   pwsh scripts\Expand-Vpk.ps1 -Vpk packs\complock\game\citadel\addons\pak01_dir.vpk -Out work\hudpp -Force
   ```
   Use grep on `work\hudpp\src`. For vanilla UI, search the GameTracking-Deadlock clone (`..\GameTracking-Deadlock\game\citadel\pak01_dir\panorama` if cloned next to this repo, `git pull` first; it's read-only for agents) or `Expand-Vpk.ps1 -Game -Filter <path>`. Ask the user for a screenshot if it's unclear which element they mean.
2. **Scaffold the overlay** with the files to change (compiled or source names both work):
   ```powershell
   pwsh scripts\New-Overlay.ps1 -Name hudpp-tweaks -Base packs\complock\game\citadel\addons\pak01_dir.vpk -File panorama/styles/hudpp_menu.css,panorama/scripts/hudpp_settings.js
   ```
   Then add `"hudpp-tweaks"` to `overlays` in `loadout.json` (order = priority).
3. **Edit** `mods\<name>\src\...`:
   - CSS: edit the existing rule rather than appending a duplicate; or add a more specific selector.
   - JS: ES5 style; guard panels with `IsValid()`; log with `$.Msg('[name] ...')`.
   - HUD++ options: change `DEFAULTS` in `hudpp_settings.js` (see `docs/complock.md`).
   - **Layouts (.xml) can't be rebuilt.** Make the change from JS at runtime (find panels, create panels, toggle classes) in a script the layout already includes, or use resourcecompiler from CSDK 12 and drop the resulting `.vxml_c` into `src\`.
   - Never rename/remove existing panel `id`s (native code looks them up → crash on load).
4. **Build and inspect:**
   ```powershell
   pwsh scripts\Build-Overlay.ps1 -Name hudpp-tweaks
   tools\s2v\Source2Viewer-CLI.exe -i build\hudpp-tweaks.vpk -l
   ```
5. **Install:** user closes Deadlock → `pwsh scripts\Deploy.ps1`. Suggest launch option `-condebug` and ask the user to verify in-game; read `game\citadel\console.log` for `[name]` lines or errors.
6. **Commit** the overlay (`mods\<name>` + `loadout.json`) with a message describing the visual change.

## After the base mod updates

`Build-Overlay.ps1` warns when a file you replaced changed upstream. Expand the new base, diff the new upstream file against your copy (`git diff --no-index`), port your edits onto the new version, then `Build-Overlay.ps1 -Name <name> -AcceptBase`.

## Fixing a broken mod (not just restyling)

Same workflow with the broken mod's VPK as `-Base`. Typical causes: a Deadlock update renamed panels/IDs the mod looks up (compare with GameTracking-Deadlock history), or an API Valve removed (`javascript:` URLs, `AsyncWebRequest`). Check `console.log` first.
