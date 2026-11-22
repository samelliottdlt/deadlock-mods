# Agent notes

This repo installs and customizes Deadlock mods with PowerShell 7 scripts (no mod manager). Skills in `.github/skills/` cover the three common jobs: **install** (`deadlock-install-mods`), **customize** (`deadlock-customize-mods`), **troubleshoot** (`deadlock-fix-mods`). Background is in `docs/`.

Ground rules:
- Change the game install only through `scripts\*.ps1` (they back up to `backups\` first). Never hand-edit `gameinfo.gi` or `addons\`, and never touch the guarded gameinfo sections (Engine2, MaterialSystem2, NetworkSystem, Particles, RenderSystem, SceneSystem, WorldRenderer).
- Deadlock must be closed for installs; ask the user, don't kill it.
- Customizations live as overlays in `mods\<name>\src` (decompiled source files). Only CSS/JS can be rebuilt; layouts (`.vxml_c`) can't. Change them from JS at runtime instead.
- Third-party mod binaries (`packs\`, `mods-bin\`, `build\`, `tools\`, `backups\`) are gitignored; don't commit them.
- The game install is found via the Steam registry/library folders; set `$env:DEADLOCK_PATH` to point the scripts at a copy for testing.
- Verify script changes against a copied game folder (`$env:DEADLOCK_PATH`) before touching the real install, and verify mod changes in-game with the user (`-condebug`, `game\citadel\console.log`).
- A sibling clone `..\GameTracking-Deadlock`, if present, is a read-only reference (decompiled vanilla Panorama); don't modify it.
