# Agent notes

This repo installs and customizes Deadlock mods with PowerShell 7 scripts (no mod manager). Skills in `.github/skills/` cover the three common jobs: **install/update/release** (`deadlock-install-mods`), **customize** (`deadlock-customize-mods`), **troubleshoot** (`deadlock-fix-mods`). Background is in `docs/` (`docs/updating.md` for the update/reconcile/audit/release flow).

Ground rules:
- Change the game install only through `scripts\*.ps1` (they back up to `backups\` first). Never hand-edit `gameinfo.gi` or `addons\`, and never touch the guarded gameinfo sections (Engine2, MaterialSystem2, NetworkSystem, Particles, RenderSystem, SceneSystem, WorldRenderer).
- Deadlock must be closed for installs; ask the user, don't kill it.
- Customizations live as overlays in `mods\<name>`: git tracks `mod.json` + `changes.patch` (+ `base-hashes.json`); `base\` and `src\` are local working copies of third-party files (gitignored). Edit `src\`, then `Build-Overlay.ps1` merges onto updated bases and rewrites the patch. Only CSS/JS can be rebuilt; layouts (`.vxml_c`) can't. Change them from JS at runtime instead.
- Updates go through `scripts\Update-Mods.ps1` / `Update-CompLock.ps1`. Never enable a new CompLock option on your own: the user keeps the game's look intact, so report new options and let them decide.
- Third-party mod binaries and files (`packs\`, `mods-bin\`, `build\`, `dist\`, `tools\`, `backups\`, `state\`, overlay `base\`/`src\`) are gitignored; don't commit them. Before publishing a release (`New-Release.ps1 -Publish`), confirm with the user that each included mod may be redistributed (the tracker is CC BY-NC-ND: no modified copies without the author's permission).
- The game install is found via the Steam registry/library folders; set `$env:DEADLOCK_PATH` to point the scripts at a copy for testing.
- Verify script changes against a copied game folder (`$env:DEADLOCK_PATH`) before touching the real install, and verify mod changes in-game with the user (`-condebug`, `game\citadel\console.log`).
- A sibling clone `..\GameTracking-Deadlock`, if present, is a read-only reference (decompiled vanilla Panorama); don't modify it.
