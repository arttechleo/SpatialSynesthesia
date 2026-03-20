# SpatialSynesthesia – Setup & Test Checklist

---

## Simulator testing (visionOS Simulator)

1. **Run in Simulator** — Choose “Apple Vision Pro” (or visionOS) simulator and run. Open the immersive space when the app launches.
2. **Confirm scene** — You should see an **orange test box** and either the **painting model** or a **purple fallback plane** in front of you. If you see the box, the scene is rendering.
3. **Console logs** — In Xcode console, check for:
   - `[ImmersiveView] Scene loading…` / `Root anchor added` / `Test box added`
   - `Painting model loaded successfully` or `Painting model failed to load — using fallback plane`
   - `Painting position (world)` / `scale` / `orientation` / `Texture loaded: true/false`
   - `[setupInteractionComponents] Applied to '…'`
4. **Tap interaction** — Tap the orange box or the painting. You should see `[Tap] Entity tapped: '…'`. First tap triggers intro; later taps log `Local hit`, `UV`, `Color … -> instrument`.
5. **If nothing visible** — Ensure you’re in the mixed immersive space and look forward; content is placed ~1.2 m in front. If the USDZ doesn’t load, the purple fallback plane should still appear.
6. **Texture** — If `Texture loaded: false`, add **KandinskyTexture** (png/jpg) to the app bundle; then color sampling will work on tap.

---

## Apple Vision Pro (device) testing later

1. **Build for device** — Select your Apple Vision Pro and build/run.
2. **Table anchor (optional)** — If you want the painting on a table again, you can switch the root from `AnchorEntity(.world(transform:))` to `AnchorEntity(.plane(.horizontal, classification: .table, ...))` and position the painting relative to that anchor.
3. **Proximity** — On device, world tracking runs; moving very close to the root anchor will fade out the intro.
4. **Gaze** — Hover effect is already on the painting/box. To add gaze-driven triggering later, keep using `handlePaintingTap`’s pipeline (localPointToUV → sampleColorAtUV → mapColorToInstrument → playMappedSound) and call it from a gaze/input API instead of (or in addition to) the tap gesture.

---

## 1. Texture asset (color sampling)

- **Where:** App target’s asset catalog or bundle (e.g. **Assets.xcassets** or a resource folder).
- **Name:** The image must be loadable as **`KandinskyTexture`** (e.g. `KandinskyTexture.png` or `KandinskyTexture.jpg` in the app bundle).
- **Used by:** `PaintingColorSampler.shared` loads this image to sample pixel color at UV when you tap the painting.

## 2. Audio assets (mapped sounds)

- **Where:** Add audio files to the **app target** so they are in the main bundle (e.g. drag into the project and ensure “Add to targets: SpatialSynesthesia” is checked).
- **Names (without extension):**  
  `trumpet`, `trombone`, `violin`, `softPad`, `lowDrone`, `default`  
  (e.g. `trumpet.m4a`, `violin.mp3`). Supported extensions: `.m4a`, `.mp3`.
- **Used by:** `AudioManager.playMappedSound(category:)` looks up the file by category and plays it when a color is mapped to that instrument.

## 3. What to test first on Apple Vision Pro

1. **Build & run** from Xcode on the device (mixed immersive space).
2. **First tap on the painting** → Intro (Schoenberg) composition should play once; `hasTriggeredIntroOnFirstInteraction` ensures it only triggers on first interaction.
3. **Later taps on the painting** → Texture is sampled at tap location (UV), color is mapped to a sound category, and the corresponding sound plays if that asset exists (e.g. tap yellow area → trumpet, blue → trombone).
4. **Proximity** → Moving very close to the painting (within ~0.5 m) should fade out the intro (existing behavior).
5. **Gaze** → Hover effect on the painting confirms input targeting; gaze-based triggering can be added later using the same UV → color → sound pipeline.

## Optional: Painting plane size

- If tap positions feel offset, the painting mesh size may differ from the default **1.0 × 1.0 m**. Adjust `paintingPlaneWidth` and `paintingPlaneHeight` in **ImmersiveView.swift** to match your **PaintingAndEasel** canvas size in local space.
