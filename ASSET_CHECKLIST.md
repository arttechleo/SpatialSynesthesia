# SpatialSynesthesia — Asset Checklist

Use this checklist to add your assets in Xcode. The project compiles; run from Xcode on your Apple Vision Pro after setting a development team for automatic signing.

## Before first run (Xcode)

1. **Development team:** Select your Apple ID / team in **Signing & Capabilities** (Target → General) for automatic signing.
2. Connect your Apple Vision Pro and choose it as the run destination. All references in code are placeholders until these are added.

---

## 1. USDZ Easel Model

| Where | Path in Xcode |
|-------|----------------|
| **Add to** | `Packages/RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/` |
| **Filename** | `Easel.usdz` |
| **Code hook** | `loadEasel(into:)` in `ImmersiveView.swift` |

**Steps:**  
1. Drag `Easel.usdz` into the RealityKitContent package’s `.rkassets` folder.  
2. Update `loadEasel(into:)` to load it, e.g. `Entity(named: "Easel", in: realityKitContentBundle)`.

---

## 2. Painting Plane / Mesh

| Where | Path in Xcode |
|-------|----------------|
| **Option A** | Programmatic plane in `createPaintingPlane()` |
| **Option B** | Add a mesh/USDZ for the canvas to `RealityKitContent.rkassets` |

**Code hook:** `createPaintingPlane()` in `ImmersiveView.swift` — currently returns `nil`; replace with your plane or loaded mesh.

---

## 3. Kandinsky Texture Image

| Where | Path in Xcode |
|-------|----------------|
| **Add to** | `SpatialSynesthesia/Assets.xcassets/` |
| **Name** | `KandinskyTexture` (or your chosen name) |
| **Code hook** | `applyPaintingTexture(to:)` in `ImmersiveView.swift` |

**Steps:**  
1. Add a new Image Set in Assets.xcassets.  
2. Add your image (PNG/JPG) to the set.  
3. In `applyPaintingTexture(to:)`, load `TextureResource(named: "KandinskyTexture")` and assign it to the entity’s material.

---

## 4. Intro Composition Audio

| Where | Path in Xcode |
|-------|----------------|
| **Add to** | `SpatialSynesthesia` target (Project Navigator → right‑click → Add Files) |
| **Filename** | e.g. `IntroComposition.m4a` |
| **Code hook** | `AudioManager.playIntroComposition()` |

**Steps:**  
1. Add the audio file to the app target.  
2. Import `AVFoundation` in `AudioManager.swift`.  
3. Load via `Bundle.main.url(forResource: "IntroComposition", withExtension: "m4a")` and play.

---

## Quick Reference

| Asset          | Location                          | Placeholder function      |
|----------------|-----------------------------------|---------------------------|
| Easel USDZ     | RealityKitContent.rkassets        | `loadEasel(into:)`        |
| Painting mesh  | Code or RealityKitContent         | `createPaintingPlane()`   |
| Kandinsky img  | Assets.xcassets                   | `applyPaintingTexture(to:)` |
| Intro audio    | App target (main bundle)          | `AudioManager` methods    |
