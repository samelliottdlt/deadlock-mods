---
name: deadlock-customize-mods
description: Customize or fix Deadlock UI mods (HUD++/CompLock, GameBanana Panorama mods) or the vanilla HUD by editing their Panorama CSS/JS and building an overlay VPK. Use when the user wants to move, resize, recolor, hide or change behavior of a HUD element, change a mod's defaults, fix a broken Panorama mod, or resolve an overlay merge conflict after a mod update.
---

# Customizing Deadlock mods (overlays)

Read `docs/panorama.md` (Panorama XML/CSS/JS, API, gotchas) before editing; `docs/resource-formats.md` explains why CSS/JS can be rebuilt but layouts can't; `docs/updating.md` covers how overlays are stored and merged. Worked examples: `docs/case-studies.md`, `mods\complock-updated-on`, `mods\sinners-statues-tracker`.

## Model

An **overlay** is `mods\<name>\`:
- `mod.json` (tracked): `base` (VPK path relative to repo | absolute | `game`), `files`, `build` (`changed` | `full`), `description`, `title`, optional `source` (`{ "gamebanana": <id> }`), `credits`, `stamp`, `runtimeIds`, `release`
- `changes.patch` (tracked): our edits as a diff from `base\` to `src\`
- `base-hashes.json` (tracked): which base version the patch was made against
- `base\`, `src\` (gitignored): the mod's files and your working copy. Third-party files never go into git.

`Build-Overlay.ps1` recreates `src\` from the patch on a fresh clone, 3-way merges your edits when the base mod changed, rewrites `changes.patch`, and compiles `build\<name>.vpk` (only your files, or with `build: full` the whole base VPK). `Deploy.ps1` loads overlays ahead of the pack, so their files win.

## Workflow

1. **Find the file.** Decompile the whole mod to a scratch folder and search it:
   ```powershell
   pwsh scripts\Expand-Vpk.ps1 -Vpk packs\complock\game\citadel\addons\pak01_dir.vpk -Out work\hudpp -Force
   ```
   Use grep on `work\hudpp\src`. For vanilla UI, search the GameTracking-Deadlock clone (`..\GameTracking-Deadlock\game\citadel\pak01_dir\panorama` if cloned next to this repo, `git pull` first; it's read-only for agents) or `Expand-Vpk.ps1 -Game -Filter <path>`. Ask the user for a screenshot if it's unclear which element they mean.
2. **Scaffold the overlay** with the files to change (compiled or source names both work):
   ```powershell
   pwsh scripts\New-Overlay.ps1 -Name hudpp-tweaks -Base packs\complock\game\citadel\addons\pak01_dir.vpk -File panorama/styles/hudpp_menu.css,panorama/scripts/hudpp_settings.js
   pwsh scripts\New-Overlay.ps1 -Name some-mod-fix -GameBanana 692472 -Full -File panorama/scripts/x.js   # a GameBanana mod, shipped as a fixed copy
   ```
   Then add the name to `overlays` in `loadout.json` (order = priority).
3. **Edit** `mods\<name>\src\...` (LF line endings):
   - CSS: edit the existing rule rather than appending a duplicate; or add a more specific selector.
   - JS: ES5 style in HUD++ (the tracker uses ES6 `const`, which works); guard panels with `IsValid()`; wrap new code in `try {}`; log with `$.Msg('[name] ...')`. Mark our additions with a `// deadlock-mods:` comment.
   - HUD++ options: change `DEFAULTS` in `hudpp_settings.js` (see `docs/complock.md`).
   - **Layouts (.xml) can't be rebuilt.** Make the change from JS at runtime (find panels, `$.CreatePanel`, toggle classes, `style.*`) in a script the layout already includes. If you recreate vanilla panel ids from JS, list them in `runtimeIds` so the audit knows.
   - Never rename/remove existing panel `id`s (native code looks them up → crash on load).
   - Build-time values: with `"stamp": true`, `{{DLM_UPDATED_ON}}`, `{{DLM_COMPLOCK_DATE}}`, `{{DLM_DETAILS}}` in JS/CSS are replaced (JS-string escaped).
4. **Build and inspect:**
   ```powershell
   pwsh scripts\Build-Overlay.ps1 -Name hudpp-tweaks
   tools\s2v\Source2Viewer-CLI.exe -i build\hudpp-tweaks.vpk -l
   git diff mods\hudpp-tweaks\changes.patch
   ```
   When reproducing an existing hand-made mod, decompile both and compare (`git diff --no-index`), ignoring whitespace.
5. **Install:** user closes Deadlock → `pwsh scripts\Deploy.ps1`. Suggest launch option `-condebug` and ask the user to verify in-game; read `game\citadel\console.log` for `[name]` lines or errors.
6. **Commit** `mods\<name>\{mod.json,changes.patch,base-hashes.json}` + `loadout.json` with a message describing the visual change.

## After the base mod updates (reconcile)

`Build-Overlay.ps1` (also run by `Update-Mods.ps1` and `Deploy.ps1`) prints `UPSTREAM CHANGED, merged cleanly: <file>` or stops with `N conflict(s) in mods\<name>\src\<file>`. For conflicts: open the file, find `<<<<<<< ours` / `=======` / `>>>>>>> new base`, keep upstream's new code and re-apply our intent (the `// deadlock-mods:` comments and `changes.patch` history in git show what ours was), remove the markers, build again, and tell the user what upstream changed. Then re-verify in game.

## Fixing a broken mod (not just restyling)

Same workflow with the broken mod's VPK as base (`-Full` if you ship the whole fixed mod). Typical causes: a Deadlock update renamed panels/IDs the mod looks up (`Find-ModConflicts.ps1 -Loadout -Vanilla` lists vanilla ids missing from mod layouts; compare with GameTracking-Deadlock history), or an API Valve removed (`javascript:` URLs, `AsyncWebRequest`). Check `console.log` first.
