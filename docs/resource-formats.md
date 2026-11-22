# File formats (VPK v2 and compiled Panorama resources)

Everything here was verified by round-tripping real files (CompLock HUD++, Deadlock Radio): `Compile-Panorama.ps1` rebuilds 78 of HUD++'s 79 scripts/styles byte-for-byte from their decompiled sources. The 79th is semantically identical (see SrMa below).

## VPK v2

Packing, listing and extracting are done by **Source2Viewer-CLI** (`tools\s2v\`, installed by `scripts\Setup-Tools.ps1`):

```powershell
$s2v = 'tools\s2v\Source2Viewer-CLI.exe'
& $s2v -i mod.vpk -l                                  # list (path, CRC, size)
& $s2v -i mod.vpk -o out\ -q                          # extract as stored (compiled)
& $s2v -i mod.vpk -o out\ -d -q                       # extract + decompile (.xml/.css/.js/.png)
& $s2v -i mod.vpk -f panorama/styles/ -e vcss_c -l    # filter by path prefix / extension
& $s2v -i mod.vpk --vpk_search "SomeText"             # grep inside (compiled files searched decoded)
& $s2v -i folder --vpk_create pak01_dir.vpk -q        # pack a folder (paths lowercased)
& $s2v -i pak01_dir.vpk --vpk_verify                  # check checksums
& $s2v -i steam:1422450/game/citadel/pak01_dir.vpk -l # the game's own files, located via Steam
```

Layout, for reference (the earlier sessions wrote packers by hand; S2V's packer makes that unnecessary):
- Header (28 bytes): `u32 0x55AA1234`, `u32 2`, `u32 treeSize`, `u32 fileDataSize`, `u32 archiveMd5Size`, `u32 otherMd5Size (48)`, `u32 signatureSize`.
- Tree: `ext\0` { `dir\0` { `name\0` `u32 crc32` `u16 preloadBytes` `u16 archiveIndex (0x7FFF = data in this file)` `u32 offset` `u32 length` `u16 0xFFFF` } `\0` } `\0` ... `\0`. Root-dir files use `" "` as the dir.
- Data, then "other MD5" section: MD5(tree), MD5(archive-md5 section), MD5(everything before this last hash).
- Same-length in-place edits need the entry CRC32 and all three MD5s recomputed.

## Source 2 resource container (`*_c`)

```
u32 fileSize | u16 headerVersion (12) | u16 typeVersion | u32 8 (offset to block table) | u32 blockCount
blockCount x { char[4] type | u32 offset (relative to this field) | u32 size }
blocks, each 16-byte aligned
```

Blocks seen in Panorama files:
- `RED2`: compile metadata (input files, compiler versions), binary KV3. **Not checked by the game**: HUD++ ships files whose RED2 names other source files.
- `RERL`: external resource references (images used by a stylesheet).
- `DATA`: the payload.
- `SrMa`: source map (only when Valve's compiler minified the CSS).
- `LaCo`: layout content (vxml only).

## Per type

| Type | typeVersion | DATA | Buildable here |
|---|---|---|---|
| `.vjs_c` PanoramaScript | 4 | the raw JS text, nothing else | yes |
| `.vcss_c` PanoramaStyle | 3 | `u32 CRC32(source)` + `u16 0` + CSS text | yes |
| `.vxml_c` PanoramaLayout | 3 | `u32 CRC32` + `u16 0` (6 bytes); the layout is a binary KV3 AST in `LaCo` | **no** (needs resourcecompiler) |
| `.vts_c` | - | Valve's compiled TypeScript | no |

How `Compile-Panorama.ps1` builds a file: take a template `_c` of the same type (the original being replaced, or any one found in the game/mods, cached in `tools\templates\`), replace `DATA`, drop `SrMa`, fix sizes and offsets. `RED2`/`RERL` are copied unchanged.

- **SrMa / minified CSS:** Valve-compiled CSS is minified and has a source map; S2V decompiles it *prettified*. Recompiling the prettified text gives a larger but equivalent file (the source map is dropped).
- **RERL:** if you add a new `url("s2r://...vtex")` image to a stylesheet, it isn't listed in the copied RERL. Engines usually resolve paths at runtime anyway, but if an image doesn't show, that's the first suspect. Use a template that already references it, or reuse images the original file references.
