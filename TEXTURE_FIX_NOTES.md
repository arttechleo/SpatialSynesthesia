# Fixing Missing Textures on PaintingScene

When USD/USDC models load without textures, it's usually a **path resolution** issue: the runtime can't find texture files relative to the scene.

## Option 1: Export as single USDZ (recommended)

1. Open the scene in **Reality Composer Pro**
2. **File → Export** and export as `.usdz`
3. Choose “embed assets” / flattened export if available
4. Replace `PaintingScene.usda` + `PaintingAndEasel.usdc` with this single `PaintingScene.usdz` in `3DAssets/`
5. The loader already tries `PaintingScene.usdz` first

A single USDZ embeds meshes and textures, so no relative paths are needed at runtime.

## Option 2: Move scene into RealityKitContent.rkassets

1. In Xcode, move or add `PaintingScene` (and its referenced assets) into  
   `Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/`
2. Add the scene to the Reality Composer Pro project (if using RC Pro)
3. Load with `Entity(named: "PaintingScene", in: realityKitContentBundle)`

`.rkassets` uses the Reality Composer Pro packaging pipeline, which handles texture paths correctly.

## Option 3: Texture paths in the USDC

`PaintingAndEasel.usdc` should reference textures with paths **relative to the USDC file**:

- Correct: `textures/Image_0.png`
- Incorrect: absolute paths or paths that don’t match the bundle layout

Ensure `3DAssets/textures/` contains all images and that paths in the USDC point into this folder.
