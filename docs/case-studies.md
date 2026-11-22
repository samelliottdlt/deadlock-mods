# Case studies (earlier mod fixes)

Two earlier Copilot sessions customized mods by hand, before this repo existed. Their tooling and findings are folded into the scripts and docs here.

## Deadlock Radio (GameBanana 720163): YouTube browser broken

- **Mod shape:** `panorama/layout/base_hud.vxml_c` (adds a script include to Valve's base HUD), `panorama/scripts/custom/dlmusic_main_v1_2.vjs_c` (all logic, ~160 KB JS), `panorama/styles/custom/dlmusic_hud.vcss_c`, `.vsvg_c` icons.
- **Root cause:** since the 2026-10-01 game update, `CitadelHTMLPanel.SetURL('javascript:...')` blanks the page, so the mod could no longer inject its controller into youtube.com. `AsyncWebRequest` is also gone.
- **Fix pattern:** patch only the `.vjs_c` DATA block (raw JS) and repack. Playback moved to a page hosted on GitHub Pages ([samelliottdlt/deadlock-radio-helper](https://github.com/samelliottdlt/deadlock-radio-helper)) that embeds the YouTube player. The mod sends commands by changing the URL `#hash` and reads state back from the page title.
- **UX lessons:** the HTML panel eats Esc/Enter (re-bind with `$.RegisterKeyBind`, release focus with `DropInputFocus`); hide Esc-menu buttons to make room (`Player Feedback`); start hidden until the HUD is up; avoid creating a new player per song ("too many devices").
- **Not fixable in-mod:** Discord app-audio capture doesn't hear it, because audio plays in `steamwebhelper.exe`.
- The patched build was later sideloaded into Grimoire as `Deadlock Radio (patched).vpk`. A copy is in `addons\.disabled\deadlock_radio_patched_dir.vpk`.

## Sinners & Statues tracker: panel covering abilities / tooltips

- **Mod shape:** `panorama/scripts/buffs_log.vjs_c` + `panorama/styles/buffs_log.vcss_c`; the script reparents its root panel into the HUD.
- **Fix:** moved it (`const pos = {x, y}` defaults in JS, `#BuffsLogRoot { position: ... }` in CSS), narrowed it to fit left of the scoreboard (x 1.5 %, y 43 %, width 15.6 %), and added `z-index: -1` so item tooltips draw over it. Styles stay attached after reparenting, so CSS z-index works.
- Done as same-length in-place byte edits with CRC/MD5 fixups (`sinners_statues_tracker_left_v3_dir.vpk`, kept by Grimoire in `addons\.disabled\`).
- **Now the `sinners-statues-tracker` overlay** (`-Full` build of GameBanana 692472, by Xaohs, downloaded automatically). It reproduces v3 (x 0.5 %, y 43 %, z-index -1, width 15.6 %, compact stat cells; layout byte-identical, CSS equal ignoring whitespace, JS equal plus one addition) and restores the soul-pickup "+" (`GoldPlusPrefix`) that the mod's outdated copy of `hud_event_indicator.xml` drops; the audit found it (`updating.md`). The `Effectiveness` label still uses the mod's older text.

## Takeaways

- Most "fix/customize this mod" requests come down to editing JS constants or CSS rules, which is exactly what the overlay workflow supports.
- Build a new pak rather than editing the installed one, keep the original for rollback, and test in-game with `-condebug`.
