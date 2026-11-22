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

The current pack (`packs\complock`, from `CompLock-pack (1).zip`, 2026-11-21): `?pack=soundcap,particles:stock,ragdolls:off,fov:0` → HUD++, Particle Pruning (stock tracers), Sound stack cap, ragdolls on, stock FOV.

Each pak carries `addoninfo.txt` + `modinfo.json` (title, author, build date, written by the `deadlock-fpsmaxing` tool). The game ignores them; `Get-ModStatus.ps1` shows the title.

## Updating

1. Open the link in `packs\complock\game\citadel\addons\mods.txt` (it restores your options), download the new zip.
2. Replace `packs\complock` with the new zip's contents (or point `loadout.json` at the zip).
3. `pwsh scripts\Deploy.ps1`. Your overlays are rebuilt against the new HUD++ and warn if a file you customized changed upstream.

Re-download after every Deadlock update that changes `gameinfo.gi`, because the pack's copy is tied to a game build (see `how-mods-load.md`, matchmaking guard). `Install-Pack.ps1` warns when `PGIVersion` differs from Valve's stock file.

## HUD++ internals (useful for customizing)

Decompile with `pwsh scripts\Expand-Vpk.ps1 -Vpk packs\complock\game\citadel\addons\pak01_dir.vpk -Out work\hudpp`.

- Replaces Valve layouts (`hud.xml`, `citadel_hud_top_bar_player.xml`, `citadel_hud_hero_shop.xml`, `hud_escape_menu.xml`, per-hero `ability_hud_elements` styles, ...) and adds its own scripts and styles (`hudpp_*.js/css`, `clean_minimap.*`, `hud_grid_timers.js`).
- `hud.xml` includes its scripts: `hudpp_store`, `hudpp_settings`, `hudpp_crosshair`, `hudpp_hud`, `hudpp_stats`, `hudpp_rate`, `clean_minimap`.
- **Settings are CSS classes.** `hudpp_settings.js` has a `DEFAULTS` object (minimap size/position/opacity, crosshair style/gap/width/length/colors, old HP bars, show buys, ...). Toggles map to classes on the root `CitadelHud` panel (`HudppMissing`, `HudppOldBars`, `HudppXh`, ...); numeric steps become classes like `HudppMS100`. The CSS keys off those classes. Easiest customizations:
  - change a default: overlay `panorama/scripts/hudpp_settings.js` and edit `DEFAULTS`.
  - change a look: overlay the relevant `.css` and edit the rule.
- Settings are edited in an in-game menu (`hudpp_menu.js`, added to the Esc menu) and **persisted through a hidden HTML panel** that loads `https://deadlockconfig.com/docs/hudpp-store/store.html` and stores them in that page's `localStorage` (`hudpp_store.js`). Panorama itself has no file storage for mods.
- The compiled HUD++ files reuse compile metadata (RED2) from other files. That is how CompLock's tool builds them without Valve's compiler, and it confirms the game doesn't check that metadata. This repo's compiler does the same (`resource-formats.md`).
