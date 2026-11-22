# CompLock

Competitive/performance pack for Deadlock by **HoppCX** (performance) and **jcStani** (competitive features). Site and Pack Builder: <https://deadlockconfig.com> (install guide `/docs/guide/`, CVAR index `/docs/cvars/`, changelog). Not on GameBanana; you build a zip in the browser.

> "Not compatible with QOL Lock or other types of mods." Other mods that replace the same files as HUD++ (HUD layouts) will conflict.

## What the pack contains

A `CompLock-pack.zip` laid out like the game folder:

```
game\citadel\gameinfo.gi            full gameinfo.gi: addons search path + ~260 ConVars
game\citadel\addons\pak01_dir.vpk   HUD++ (always included)
game\citadel\addons\pak02_dir.vpk   ...options you picked, in CompLock's fixed order
game\citadel\addons\mods.txt        what each pak is + a link back to the builder with your options
```

Pack Builder options (`?pack=` URL parameter, comma list; `id`, `id:choice`, `id:off`):

| Option | Ships as | Notes |
|---|---|---|
| HUD++ (always) | pak01 | damage numbers `cumulative` (default) / `vanilla` / `hidden` |
| gameinfo (always) | gameinfo.gi | engine settings, FOV slider |
| `particles` | pak02 | `stock` (stock tracers/hits) or `reduced` (fainter tracers, no impacts/blood) |
| `soundcap` | pak03 | sound stack update cap |
| `brighterlighting` | pak04 | by BreadRollius |
| `hpbars` | pak05 | jcStani's HP bars |
| `lowdetailmap` | pak06 | 414 textures / 676 materials swapped |
| `cloth` | pak07 | removes cloth from 17 heroes; conflicts with hero model mods |
| `ragdolls` | gameinfo only | `ragdolls:off` sets `cl_disable_ragdolls "false"` (ragdolls back on) |
| `ticklines` | gameinfo only | HP bar breakpoint lines |
| `fov:<n>` | gameinfo only | sets `r_aspectratio`; `fov:0` = stock, CompLock default 2.15, range 1.85-2.60 |

The current pack (`packs\complock`, built by `Update-CompLock.ps1`, CompLock 2026-11-21): `?pack=soundcap,particles:stock,ragdolls:off,fov:0` → HUD++, Particle Pruning (stock tracers), Sound stack cap, ragdolls on, stock FOV. The user keeps the game's look as intact as possible: cloth, low detail map, brighter lighting, HP bars and tick lines stay off, and new options are reported rather than enabled.

Each pak carries `addoninfo.txt` + `modinfo.json` (title, author, build date, written by the `deadlock-fpsmaxing` tool). The game ignores them; `Get-ModStatus.ps1` shows the title.

## Updating

```powershell
pwsh scripts\Update-CompLock.ps1 -Check   # what changed on the site
pwsh scripts\Update-Mods.ps1 -Deploy      # update, reconcile overlays, audit, install
```

`Update-CompLock.ps1` builds the pack from the Pack Builder's page data with the options in `loadout.json` (`complock.options`), byte-identical to the site's zip, downloading only changed paks. It reports changed paks, gameinfo.gi changes, the changelog since the last update, and new options (never enabled). Details: `updating.md`.

Re-run after every Deadlock update that changes `gameinfo.gi`, because the pack's copy is tied to a game build (see `how-mods-load.md`, matchmaking guard). `Install-Pack.ps1` warns when `PGIVersion` differs from Valve's stock file. The site's `pack-data.game` says which build CompLock's gameinfo.gi was made for.

By hand (if the site changes and the script breaks): open the link in `packs\complock\game\citadel\addons\mods.txt`, download the zip, replace `packs\complock` with its contents, `Deploy.ps1`.

## HUD++ internals (useful for customizing)

Decompile with `pwsh scripts\Expand-Vpk.ps1 -Vpk packs\complock\game\citadel\addons\pak01_dir.vpk -Out work\hudpp`.

- Replaces Valve layouts (`hud.xml`, `citadel_hud_top_bar_player.xml`, `citadel_hud_hero_shop.xml`, `hud_escape_menu.xml`, per-hero `ability_hud_elements` styles, ...) and adds its own scripts and styles (`hudpp_*.js/css`, `clean_minimap.*`, `hud_grid_timers.js`).
- `hud.xml` includes its scripts: `hudpp_store`, `hudpp_settings`, `hudpp_crosshair`, `hudpp_hud`, `hudpp_stats`, `hudpp_rate`, `clean_minimap`.
- **Settings are CSS classes.** `hudpp_settings.js` has a `DEFAULTS` object (minimap size/position/opacity, crosshair style/gap/width/length/colors, old HP bars, show buys, ...). Toggles map to classes on the root `CitadelHud` panel (`HudppMissing`, `HudppOldBars`, `HudppXh`, ...); numeric steps become classes like `HudppMS100`. The CSS keys off those classes. Easiest customizations:
  - change a default: overlay `panorama/scripts/hudpp_settings.js` and edit `DEFAULTS`.
  - change a look: overlay the relevant `.css` and edit the rule.
- Settings are edited in an in-game menu (`hudpp_menu.js`, added to the Esc menu) and **persisted through a hidden HTML panel** that loads `https://deadlockconfig.com/docs/hudpp-store/store.html` and stores them in that page's `localStorage` (`hudpp_store.js`). Panorama itself has no file storage for mods.
- The menu panel is built in `hudpp_menu.js` → `build()`: a head (`HudppHead`: "COMPLOCK", authors, close), tabs, bodies, and a foot (`HudppFoot`: save status, reset). The `complock-updated-on` overlay adds its "Updated On" label to the foot, with a tooltip through the menu's own `tip()` helper (`UIShowTextTooltip`).
- The compiled HUD++ files reuse compile metadata (RED2) from other files. That is how CompLock's tool builds them without Valve's compiler, and it confirms the game doesn't check that metadata. This repo's compiler does the same (`resource-formats.md`).
- **Damage numbers** are drawn by Valve's `hud_event_indicator` panels; Valve's setting `citadel_damage_text_cumulative_mode` is 0 = per-hit numbers only, 1 = per-hit numbers + a running total, 2 = per-hit numbers + the final total ("Show cumulative damage" in the game's settings). CompLock's gameinfo sets 1 and `citadel_damage_text_batching_window_individual 2` (hits of one type within 2 s merge into one number), and `hudpp_hud.js` sends `cumulative_mode` = `HudppSettings.damageMode` (1) on HUD load. The default "Cumulative damage" HUD++ has class `HudppDmg` on the HUD root in `hud.xml`; `hud_event_indicator.css` then shrinks every per-hit number (`bullet_damage_new`, `ability_damage_new`, `damage_type_gun`, ...) to 0×0 and keeps only the total in white. Valve shows the total only from the second hit, so single hits showed nothing. The `hudpp-damage-numbers` overlay sends mode 0 and removes `HudppDmg`: per-hit gun/spirit numbers in vanilla colors, still batched, without the total panel. (The Pack Builder's `hud:vanilla` gives `hud_vanilla.vpk` instead, without the batching line.)

## Particle Pruning (pak02)

`particles:stock` replaces ~6400 `.vpcf_c` files (`particles/...`) with slimmer copies: children dropped, or emptied to a bare system. Some of them show game state. Found so far and restored by the `vanilla-particles` overlay (vanilla copies from the game, `"build": "restore"`):

- `particles/environment/shop_open_ambient*` (+ `winter_` variants, `shop_sign_magic`): the effect in front of an open shop was an empty system.
- `particles/abilities/unicorn/unicorn_radiant_blast_debuff` (Celeste's Light Eater, `ability_unicorn_radiantblast` → `m_DebuffModifier.m_strParticleEffect`): `_glow` and `_spark` children removed, only `_rope` left, so structures showed no aura.

To find another: look up the effect in `scripts/abilities.vdata` (GameTracking or decompiled `pak01`), check `Source2Viewer-CLI -i <pruning pak> -l` for it, decompile both copies (`-d`) and compare `m_Children` / operators; then add the paths to `mods\vanilla-particles\mod.json`.
