# Updating, reconciling and releasing

How this repo keeps a set of third-party mods plus our own fixes current. Scripts: `Update-Mods.ps1` (all of it), `Update-CompLock.ps1`, `Build-Overlay.ps1`, `Find-ModConflicts.ps1`, `Deploy.ps1`, `New-Release.ps1`.

```
Update-Mods.ps1 [-Check] [-Deploy]
  1. Update-CompLock.ps1      packs\complock  <- deadlockconfig.com, options from loadout.json
  2. GameBanana sources       mods-bin\*.vpk  <- newer files of overlay bases / extras
  3. Build-Overlay.ps1 (each) 3-way merge our edits onto changed base files, compile build\<name>.vpk
  4. Find-ModConflicts.ps1 -Loadout -Vanilla   conflicts between paks + what Valve changed under the mods
  5. Deploy.ps1 (-Deploy)     back up, install, save the audit baseline
```

## 1. CompLock from the Pack Builder

The Pack Builder page embeds `<script id="pack-data">` (JSON): every pak's number, size, CRC-32 and a URL to its raw-deflate bytes (`/dl/pack/hud.<hash>.z`, big paks split over several URLs), CompLock's full `gameinfo.gi`, each option's ConVar lines (`gameinfo`, `gameinfo_off`, `gameinfo_else`), choices, authors and `updated` dates with changelog anchors. `/docs/pack/pack.js` turns a selection into the zip. `scripts\CompLock.psm1` mirrors its `decode` / `resolve` / `gameinfo` / `modsTxt` / `encode`, and its output is byte-identical to the site's zip (checked against a downloaded pack).

- The selection is `loadout.json` → `complock.options`, the `?pack=` value of a builder link (`id`, `id:choice`, `id:off`, `fov:<n>`, `fov:0` = stock). `Update-CompLock.ps1 -Options "<value>"` changes and saves it.
- `packs\complock\complock.json` records what was built: options, link, the site's game build, newest component date (`updatedOn`), components with authors and dates, pak CRCs.
- `loadout.json` → `complock.knownOptions` / `knownChoices` (tracked) are the options and choices the site had at the last update, i.e. what the user has already been shown.
- On update: only paks whose CRC changed are downloaded (inflated and CRC-checked); it reports changed paks with their changelog link, `gameinfo.gi` changes (and a `PGIVersion` change = new game build), and the changelog entries since the last update.
- **New options are never enabled.** They are listed with their description. Options with `gameinfo_else` (like `ragdolls`) are ON when a link doesn't name them, so a new one of those is written into the options as `<id>:off`; with no `knownOptions` at all (old loadout), every default-on option the options don't name is treated that way. To turn one on, add it to `complock.options` and run again.
- The old pack is kept in `packs\.previous\` (last 3).

## 2. Overlays are patches

```
mods\<name>\mod.json          base VPK, files, build mode, credits, title, stamp, runtimeIds   (tracked)
mods\<name>\changes.patch     unified diff base\ -> src\ (paths a/base/..., b/src/...)        (tracked)
mods\<name>\base-hashes.json  hash of each base file the patch was made against                (tracked)
mods\<name>\base\             the mod's files as decompiled at the last reconcile               (local)
mods\<name>\src\              your working copy: edit these                                     (local)
```

Why: the repo is public and the mods aren't ours (CompLock has no license; the tracker is CC BY-NC-ND, which forbids sharing modified copies). A patch carries only our change and a few context lines, and it is exactly what a merge needs.

`mod.json` fields: `base` (`packs/...`, `mods-bin/...`, absolute, or `game`), `source` (`{ "gamebanana": <id> }`: download the base when missing, check for updates), `files` (source paths), `build` (`changed`: only our files, loaded ahead of the base; `full`: the whole base VPK with our files, loaded instead of it; `restore`: see below), `title` (pak title), `credits` (`name`, `by`, `url`, `license`), `stamp` (replace `{{DLM_UPDATED_ON}}`, `{{DLM_COMPLOCK_DATE}}`, `{{DLM_DETAILS}}` in JS/CSS at build time), `runtimeIds` (panel ids the overlay recreates from JS, so the audit doesn't report them), `release` (`false` keeps it out of release zips).

`"build": "restore"` overlays have no `src\`, `base\` or patch: `files` are compiled paths (wildcards allowed, e.g. `particles/environment/shop_open_ambient*.vpcf_c`) copied unchanged from the base on every build. With `"base": "game"` this brings back vanilla files another pak replaces (`vanilla-particles` undoes part of Particle Pruning), always from the installed game build. The audit lists them as "Restored (expected)", leaves them out of the vanilla-drift check, and names restored files no other pak replaces any more (drop them from `files`). Add files by editing `mod.json`; `New-Overlay.ps1` refuses restore overlays.

`Build-Overlay.ps1`:
1. Fresh clone: decompiles `base\` from the base VPK (downloading it first if `source` says where) and recreates `src\` = `base\` + `changes.patch` (`git apply`, checked file by file).
2. Reconcile: decompiled files are normalized (UTF-8, LF). If a file in the base VPK differs from `base\`, the mod was updated: `git merge-file src base new` merges our edits onto the new version. Clean → reported, `base\` updated. Conflicts → `<<<<<<< ours / ======= / >>>>>>> new base` in `src\` and the build stops (also on any leftover marker). Resolve by keeping upstream's change and re-applying ours, then build again.
3. Writes `changes.patch` and `base-hashes.json` (commit them).
4. Compiles: `.js`/`.css` via `Compile-Panorama.ps1` with the base's compiled file as template, other files copied, plus an `addoninfo.txt` title. Layouts (`.xml`) must stay unchanged.

Tested: simulated tracker update with one non-overlapping JS change (merged cleanly) and one CSS change on a line we edit (conflict, build stopped; resolved; rebuilt); deleting `base\`/`src\` regenerates identical files from the patch.

## 3. The audit

`Find-ModConflicts.ps1 -Loadout -Vanilla` (run by `Update-Mods` and after every `Deploy`):

- **Conflicts:** files more than one planned pak contains; pak01 wins. An overlay replacing a file of its own base is listed as expected.
- **Vanilla drift:** files the mods replace that also exist in Deadlock's `pak01`. `Deploy` saves their CRCs to `state\vanilla-baseline.json`; afterwards every file Valve changed is listed with its risk (layout: may crash or hide new UI; style/script; asset: looks old). This is the "HUD broke after a patch" early warning.
- **Panel ids:** for each replaced layout, ids in the vanilla layout that the mod's copy lacks. Game code finds panels by id; missing ones crash (`Unable to find child`) or drop a feature. Ids missing since the baseline are marked NEW. Needs the game's `pak01_*.vpk` chunks (skipped on a copied test folder).

Findings so far (build 6864):
- Sinners and Statues Tracker: its `hud_event_indicator.xml` predates Valve adding `GoldPlusPrefix` (the "+" before soul pickups) and changing `Effectiveness` (`{s:distance}m {s:effectiveness}%`, class `isEffectiveness`). The overlay recreates `GoldPlusPrefix` from JS (`runtimeIds`); the Effectiveness label still shows the tracker's older text.
- HUD++ `citadel_hud_hero_shop.xml` has no `GoldAPContainer` (vanilla has it). HUD++ works in game, so nothing depends on it hard; watch it if the shop misbehaves.

## 4. Version date ("Updated On")

`Get-LoadoutVersion` hashes every input of the loadout (pack files, overlay sources and `mod.json`, base and extra VPKs). When the hash differs from `state\version.json`, the date becomes today. It is stamped into the CompLock menu by the `complock-updated-on` overlay (hover for CompLock's date and the mod list), written to the game's `addons\mods.txt` with the credits, and used for release names (`v2026.11.21`).

## 5. Releases

`New-Release.ps1` builds the overlays and writes `dist\deadlock-mods-<date>\` + `.zip`: `game\citadel\gameinfo.gi`, `addons\pakNN_dir.vpk` in Deploy's order, `addons\mods.txt`, `README.txt` (install, after a Deadlock update, uninstall, credits) and `dist\release-notes.md`. `-Publish` runs `gh release create v<yyyy.MM.dd>` (`-Force` replaces an existing one).

Redistribution: credits and links are added automatically, but check each mod's terms first. CompLock publishes no license (get it from deadlockconfig.com when you can). The tracker's CC BY-NC-ND 4.0 allows sharing the unmodified mod non-commercially with credit, not modified copies, so a release with our tracker changes needs Xaohs' permission; otherwise `-Exclude sinners-statues-tracker`.
