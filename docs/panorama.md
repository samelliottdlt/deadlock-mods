# Panorama (Deadlock's UI) for modders

Panorama is Valve's HTML-like UI framework: **XML layouts + CSS styles + JavaScript**, rendered by the engine (not a browser). Everything in Deadlock's menus and HUD is Panorama; much of the HUD logic is native C++ panel classes (`<CitadelHud>`, `<Citadel_AbilityHUDElement_Gun>`, ...) that a layout instantiates.

## Files

| Source | Compiled (what the game loads) | Where | Notes |
|---|---|---|---|
| `.xml` layout | `.vxml_c` | `panorama/layout/**` | ~445 in vanilla |
| `.css` style | `.vcss_c` | `panorama/styles/**` | ~454 in vanilla |
| `.js` script | `.vjs_c` | `panorama/scripts/**` | used by mods; vanilla has none |
| `.ts` script | `.vts_c` | `panorama/scripts/**` | Valve's own (only 6, e.g. `async.vts_c`); decompiles to `.js` |
| `.png`/`.svg` | `.vtex_c` / `.vsvg_c` | `panorama/images/**` | |

**The game never loads raw `.xml/.css/.js`.** Only `_c` files in a VPK count. `scripts\Compile-Panorama.ps1` / `Build-Vpk.ps1` compile CSS and JS (see `resource-formats.md`); layouts need Valve's compiler (below).

### Reading vanilla sources

- **[SteamTracking/GameTracking-Deadlock](https://github.com/SteamTracking/GameTracking-Deadlock)** has every vanilla layout/style decompiled at `game/citadel/pak01_dir/panorama/{layout,styles,scripts}`, updated each build. Commit messages list the changed files, so you can see what an update broke. Clone it next to this repo (`..\GameTracking-Deadlock`); `git pull` it first, because it may be many builds old.
- Or extract from your install: `pwsh scripts\Expand-Vpk.ps1 -Game -Filter panorama/layout/hud.vxml_c,panorama/styles/hud.vcss_c -Out work\vanilla`.
- Search inside VPKs: `tools\s2v\Source2Viewer-CLI.exe -i <vpk> --vpk_search "HudppHud" -f panorama/`.

## Layout XML

```xml
<root>
  <styles>
    <include src="s2r://panorama/styles/citadel_base_styles.vcss" />
    <include src="s2r://panorama/styles/my_mod.vcss" />
  </styles>
  <scripts>
    <include src="s2r://panorama/scripts/my_mod.vjs" />
  </scripts>
  <snippets>
    <snippet name="Row"><Panel class="Row"><Label id="Text" text="{s:value}" /></Panel></snippet>
  </snippets>
  <Panel class="MyRoot" hittest="false">
    <Label text="#Some_Localization_Token" />
    <Image src="s2r://panorama/images/hud/foo_psd.vtex" />
  </Panel>
</root>
```

- Includes reference the compiled resource name **without `_c`** (`.vcss`, `.vjs`); `s2r://` = "resource path". HUD++ also writes `..._c`, which works too.
- Every script in `<scripts>` runs in **the same JS context** (top-level `var`s are shared). HUD++ defines `HudppSettings` in one file and uses it in another.
- `{s:name}` / `{d:name}` are dialog variables set from code (`panel.SetDialogVariable('name', v)`); `#Token` is localization.
- Common attributes: `id`, `class`, `hittest="false"` (clicks pass through), `hittestchildren`, `acceptsfocus`, `src`, `text`.
- Changing **IDs or structure** that native code looks up crashes the game on load (`FATAL ERROR: Unable to find child 'X' in layout file 'Y'`). Keep every existing `id` when restyling.

## CSS dialect (not web CSS)

- Layout: `flow-children: right | down | none`, `width: fit-children | fill-parent-flow(1) | 100% | 20px`, `horizontal-align` / `vertical-align: left|center|right / top|center|bottom`, `margin`, `padding`, `position: x y z` (e.g. `position: 1.5% 43% 0px`), `x`/`y`, `z-index` (siblings only), `overflow: noclip | clip | render`.
- Visuals: `background-color`, `background-image: url("s2r://...vtex")`, `wash-color`, `opacity`, `opacity-mask`, `box-shadow`, `border`, `border-radius`, `blur`, `saturation`, `brightness`, `transform: translatex() scale3d() rotateZ()`, `pre-transform-scale2d`.
- Text: `font-family`, `font-size`, `font-weight`, `color`, `text-transform`, `letter-spacing`, `text-overflow: shrink | ellipsis`.
- State: `visibility: visible | collapse` (collapse = takes no space), pseudo-classes `:hover`, `:active`, `:selected`, `:focus`, `:disabled`, `.SomeClass` toggled from JS.
- Animation: `transition-property/-duration/-timing-function/-delay`, `animation-name` + `@keyframes`.
- Units: `px` are at 1080p reference height and scale with resolution; `%` of parent.
- Full list: run `dump_panorama_css_properties` in the console (release command).
- Reported: when the same property appears twice the **first** value read can win in compiled panorama. Edit the existing rule instead of appending an override. An override rule with **higher specificity** (e.g. `.HudppHud .Foo`) is the safe way to add one.

## JavaScript API (what mods actually use)

Panorama runs V8. Mods are written in ES5 style (`var`, IIFEs) for safety. Patterns from HUD++ and the Deadlock Radio fix:

```js
(function () {
  "use strict";
  var root = $.GetContextPanel();                       // root panel of the layout that included this script
  var hud = root.FindChildTraverse("SomeId");           // search descendants by id
  var list = root.FindChildrenWithClassTraverse("Foo"); // by class
  var p = $.CreatePanel("Panel", root, "MyPanel", { class: "MyClass", hittest: "false" });
  p.BLoadLayoutSnippet("Row");                          // instantiate a <snippet> from this layout
  p.SetHasClass("Active", true); p.BHasClass("Active"); p.AddClass("X"); p.RemoveClass("X");
  p.style.width = "120px";                              // inline style
  p.SetPanelEvent("onactivate", function () { /* click */ });
  var h = $.Schedule(0.5, function tick() { h = $.Schedule(0.5, tick); }); // timers; $.CancelScheduled(h)
  $.RegisterForUnhandledEvent("SomeGameEvent", function () {});
  $.RegisterEventHandler("HTMLTitle", htmlPanel, function (panel, title) {});
  $.DispatchEvent("CitadelConCommand", "citadel_damage_text_cumulative_mode 1"); // run a console command
  $.DispatchEvent("CitadelToggleEscapeMenu");
  $.Msg("[mymod] hello");                               // console / -condebug log
  if (p && p.IsValid && p.IsValid()) p.DeleteAsync(0);  // panels die when the HUD reloads: always IsValid()
})();
```

- Panel types: `Panel`, `Label`, `Image`, `Button`, `TextEntry`, `Slider`, `ToggleButton`, `DropDown`, `CitadelHTMLPanel` (embedded Chromium).
- Events seen in mods: `onactivate`, `onvaluechanged`, `oninputsubmit`, `HTMLTitle`, `HTMLLoadPage`, `HTMLURLChanged`, `UIShowTextTooltip` / `UIHideTextTooltip`, `DropInputFocus`, `CitadelResumePlaying`.
- Keys: `$.RegisterKeyBind(panel, 'key_escape', fn)` (also `key_enter`, `key_pad_enter`).
- Focus: `panel.SetFocus()`, `panel.SetAcceptsFocus(bool)`, `$.DispatchEvent('DropInputFocus', panel)`.
- List all events: `dump_panorama_events` (console).

### Things that don't work anymore / gotchas

- **No HTTP from Panorama JS**: `AsyncWebRequest has been removed`. The only way to reach the web is a `CitadelHTMLPanel` (hidden if needed) loading a page you host. Read results back through its page **title** (`HTMLTitle` event), and send commands by changing the URL `#hash` (no reload). HUD++ stores settings this way (deadlockconfig.com `localStorage`), and so does the radio fix (GitHub Pages).
- **`javascript:` URLs in `SetURL` blank the page** since the 2026-10-01 update; you can't inject scripts into a page.
- **`CitadelHTMLPanel` swallows Esc and Enter.** Re-bind them with `$.RegisterKeyBind` on the HTML panel, and give focus back (`DropInputFocus`) after clicks, otherwise Esc won't close menus and the mouse stays free.
- **Embedded browser audio** plays from `steamwebhelper.exe`, not `deadlock.exe` (matters for per-app capture such as Discord streaming).
- **Persistence**: there is no file API. Use the HTML-panel + `localStorage` trick, or convars via `CitadelConCommand`.
- HUD panels are rebuilt (map load, reconnect); keep references weak and re-find with `IsValid()` checks.
- Placing a panel into the HUD from script keeps its stylesheet. `z-index` only orders siblings, so to draw under tooltips, make it a sibling under them with a lower `z-index`.

## Compiling layouts (.xml → .vxml_c)

`vxml_c` v3 stores the layout as a binary KV3 syntax tree (`LaCo` block), so the scripts here can't build it. Options, easiest first:

1. **Don't change the XML; change panels from JS.** Overlay a script the layout already includes (or one of your own via a CSS/JS-only change), then `FindChildTraverse` + `$.CreatePanel` / `SetHasClass` / `style.*` at runtime. Most HUD tweaks can be done this way plus CSS.
2. **Valve's `resourcecompiler.exe`** from the community **Reduced CSDK 12** (<https://deadlockmodding.pages.dev/modding-tools/csdk-12>, docs <https://wiki.divineskins.gg/en/docs/deadlock/tools/csdk-12>). Put sources in `content\citadel_addons\<addon>\panorama\layout\x.xml` and run `resourcecompiler.exe -f -game <csdk>\game\citadel <file>`; the output lands in `game\citadel_addons\<addon>\panorama\...\x.vxml_c`. Drop that file into an overlay's `src\` folder (Build-Vpk copies already-compiled files as-is). Needs Steam running. **Never launch the game with `-tools`** for normal play, because Tools mode blocks matchmaking.

## Debugging

- Launch option `-condebug` writes the console to `game\citadel\console.log`; `$.Msg` lines show up there. Prefix your messages (`[mymod]`) and search the log.
- `panorama_toggledebugger_mode` / the Panorama debugger exist (hidden). The debugger key and `-dev` workflow are unverified.
- HUD changes need a **full game restart**; leaving a match doesn't reload VPKs.
- Syntax-check JS before building. With no Node here, the earlier radio fix parse-checked scripts with Windows' built-in JScript engine (`cscript`). It only understands ES3/ES5, so it doubles as a check that you didn't use newer syntax. Wrap the code in a function you never call so it parses without running.
