# Reality Composer Pro Asset Debugging Checklist

Use this checklist after running the instrumented ImmersiveView. Check the Xcode console for `[RealityKit Debug]` logs.

---

## 1. Runtime diagnostics (from console output)

| Log message | What it confirms |
|-------------|------------------|
| `LOAD SUCCESS: 'Immersive'` (or Scene) | Entity(named:in:) found and loaded the scene |
| `LOAD FAILED: 'PaintingScene'` | PaintingScene is not in the bundle or has broken references |
| `Entity hierarchy` output | Hierarchy exists; inspect for ModelComponent: true/false |
| `Entities with ModelComponent` | Which entities have visible geometry |
| `Total root entities: N` | Scene was added to RealityView content |
| Red debug box visible | RealityView rendering works; issue is asset-specific |

---

## 2. Xcode project structure

| Check | Where | Action |
|-------|-------|--------|
| **Scene inside .rkassets** | `Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/` | Reality Composer Pro scenes must live inside this folder to be loadable by `Entity(named:in:)` |
| **PaintingScene location** | Currently in `3DAssets/` | Move `PaintingScene.usda` into `RealityKitContent.rkassets/` (e.g. via Reality Composer Pro or drag into Xcode) |
| **Target membership** | File Inspector → Target Membership | Ensure RealityKitContent target is checked for all .usda / .usdc / .usdz |
| **Reality Composer Pro** | Package.realitycomposerpro/ProjectData/main.json | Only scenes listed here are part of the RC Pro project. PaintingScene is NOT listed; add it in Reality Composer Pro |

---

## 3. USD / USDA external references

| Check | Where | Action |
|-------|-------|--------|
| **Missing referenced file** | `PaintingScene.usda` contains `references = @PaintingAndEasel.usdc@` | **PaintingAndEasel.usdc does NOT exist** in the project. Re-export from Reality Composer Pro as a single file, or add PaintingAndEasel.usdc next to PaintingScene.usda and fix relative path |
| **Relative paths** | USDA references use `@File.usdc@` | Path is relative to the USDA file. Put referenced files in the same directory, or use correct relative path |
| **Verify textures** | Check for `@texture.png@` or similar in USDA | If textures reference external files, ensure they are in the bundle |

---

## 4. Reality Composer Pro

| Check | Where | Action |
|-------|-------|--------|
| **Scene name** | File name = load name | `Entity(named: "Immersive", …)` loads `Immersive.usda`. Use exact filename (no extension) |
| **defaultPrim** | USDA header: `defaultPrim = "Root"` | Entity(named:in:) returns the defaultPrim (often "Root"). Your hierarchy is under that |
| **Visibility** | Per-prim `active` | Ensure prims are `active = true` |
| **Re-export** | File → Export | If in doubt, re-export the scene from Reality Composer Pro to flatten references and fix paths |

---

## 5. Entity name and hierarchy

| Check | Console output | Action |
|-------|----------------|--------|
| **Root name** | Hierarchy shows "Root" at top | Common; child "PaintingAndEasel" or similar holds the easel |
| **ModelComponent** | `ModelComponent: true` on leaves | Only entities with ModelComponent render geometry |
| **Transform** | position, scale in log | Extreme values (e.g. scale 0.001 or position 1000) can make content invisible |

---

## Most likely causes (ranked)

### 1. **Missing external reference: PaintingAndEasel.usdc**

`PaintingScene.usda` references `@PaintingAndEasel.usdc@`, but that file is not in the project. The scene loads as a hierarchy, but the easel geometry comes from the referenced file. Without it, you get an empty or broken subtree.

**Fix:**  
- Re-export the easel+painting from Reality Composer Pro as a single USDA/USDZ (no external refs), or  
- Add `PaintingAndEasel.usdc` next to `PaintingScene.usda` and ensure the path resolves correctly.

### 2. **PaintingScene not in the correct bundle location**

`PaintingScene.usda` lives in `3DAssets/`, outside `RealityKitContent.rkassets/`. `Entity(named:in:)` loads from the RealityKitContent bundle, which typically only includes assets under `.rkassets`. `main.json` does not list PaintingScene.

**Fix:**  
- In Reality Composer Pro, create or move the PaintingScene into the project’s `.rkassets` folder, or  
- Drag the scene from Reality Composer Pro into the `RealityKitContent.rkassets` group in Xcode so it’s part of the bundle.

### 3. **Wrong entity name in Swift**

You may be loading `"Immersive"` or `"Scene"` (which exist) while your easel is in `PaintingScene`. If PaintingScene fails to load (see #1 and #2), you won’t see it. If you load `"Immersive"`, you get spheres, not the easel.

**Fix:**  
- After fixing #1 and #2, use `Entity(named: "PaintingScene", in: realityKitContentBundle)`.  
- Ensure the filename in `.rkassets` matches the string you pass to `Entity(named:in:)`.

---

## Quick verification steps

1. Run the app and confirm you see the **red debug box** at (0.2, 0, -1.5).  
2. Check the console for **LOAD SUCCESS** or **LOAD FAILED** for each scene name.  
3. If a scene loads, inspect the **entity hierarchy** output for `ModelComponent: true`.  
4. Move `PaintingScene` into `RealityKitContent.rkassets` and resolve the `PaintingAndEasel.usdc` reference.  
5. Rebuild and run again; the console will show whether the scene and geometry load correctly.
