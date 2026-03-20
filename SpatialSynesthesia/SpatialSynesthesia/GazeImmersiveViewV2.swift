//
//  GazeImmersiveViewV2.swift
//  SpatialSynesthesia
//
//  VisionOS prototype: gaze-responsive painting regions + tap fallback.
//
//  Gaze: ARKit `WorldTrackingProvider.queryDeviceAnchor` → device forward (−Z) ray vs painting plane
//  (analytic ray–plane intersection in world space, then `worldToLocal`). No scene raycast / spatial gesture.
//
//  MVP behavior:
//  - Full-canvas overlay is driven by `GazeInteractionManager` + authored region categories.
//  - Tap uses the same plane-local resolution (no per-region entities).
//

import ARKit
import RealityKit
import RealityKitContent
import SwiftUI
import UIKit
import QuartzCore
import simd

// MARK: - PaintingAndEasel loading (Phase 1: aligned interactive plane; Phase 2 prep: UV/submesh)

// Temporary visual orientation debug for the 3D easel-aligned interactive plane.
// Makes the aligned plane tint + adds explicit front/back markers.
// Keep this enabled while diagnosing upside-down / backfacing issues.
private let alignedPlaneOrientationDebugVisible: Bool = {
    #if DEBUG
    return true
    #else
    return false
    #endif
}()

private func loadPaintingAndEaselEntity() async -> Entity? {
    do {
        return try await Entity(named: "PaintingAndEasel", in: realityKitContentBundle)
    } catch {
        for bundle in [realityKitContentBundle, Bundle.main] {
            for subdir in ["3DAssets", "3D Assets", ""] {
                let subpath: String? = subdir.isEmpty ? nil : subdir
                guard let url = bundle.url(forResource: "PaintingAndEasel", withExtension: "usdz", subdirectory: subpath) else { continue }
                do {
                    return try await Entity(contentsOf: url)
                } catch {
                    continue
                }
            }
        }
        return nil
    }
}

/// Finds the painting surface entity in the easel hierarchy for aligning the interactive plane.
/// Names to try (Reality Composer / USD hierarchy); returns first match or root.
private func findPaintingSurface(in entity: Entity) -> Entity {
    let preferredNames = ["Canvas", "Painting", "PaintingSurface", "PaintingPlane", "CanvasPlane"]
    if preferredNames.contains(entity.name) { return entity }
    for child in entity.children {
        let found = findPaintingSurface(in: child)
        if found !== entity { return found }
    }
    return entity
}

@MainActor
final class PaintingSceneStateV2 {
    var overlayEntity: Entity?
    var regions: [PaintingRegion] = []
    var regionByEntityName: [String: PaintingRegion] = [:]
    var overlayEnabled: Bool = true
    /// Strongly-held subscription so per-frame overlay updates keep running.
    var sceneUpdateSubscription: EventSubscription?

    /// `Scene` from `SceneEvents.Update` (same frame as gaze logic). `Entity.scene` / `@Environment` are often nil here.
    var sceneFromUpdateLoop: RealityKit.Scene?

    /// Latest authored region id resolved from the painting plane hit (device-anchor ray + box test).
    var currentLookTargetRegionId: String?

    /// ARKit session driving `WorldTrackingProvider` for device-anchor gaze rays.
    var arSession: ARKitSession?
    var worldTracking: WorldTrackingProvider?

    /// Head anchor: intro veil / world tint wash (not used for gaze ray).
    var headAnchorEntity: AnchorEntity?

    // MARK: - Audio sync
    var lastAppliedAudioMixVersion: UInt64 = 0

    /// Where the current interaction is happening (for diagnostics and future 3D asset surface).
    enum InteractionSource: String {
        case flatPaintingPlane = "flat_painting_plane"
        case alignedPlaneOnEasel = "aligned_plane_on_easel"
        case threeDAssetSurface = "3d_asset_surface" // TODO: UV-based hit mapping; direct submesh interaction
    }
    var interactionSource: InteractionSource = .flatPaintingPlane

    // MARK: - Scene-level passthrough/world tint (broad wash)
    var worldTintWashEntity: ModelEntity?
    var worldTintOpacity: Float = 0
    var worldTintTargetOpacity: Float = 0
    var worldTintLastTickTime: CFTimeInterval?
    var lastAppliedTintFocusKey: String?
    var lastAppliedWorldTintIntensityForEffect: Float = -1
    /// Dedupes `[Gate3-Tint]` (update loop runs every frame).
    var gate3LastPrintedSignature: String = ""

    // MARK: - Region trust diagnostics
    /// `PaintingCanvas` root from `PaintingCanvasEntity.build` (plane, regions, overlay).
    var paintingCanvasRoot: Entity?
    var paintingPlaneEntity: Entity?
    var lastGazeNormalizedUV: (u: Float, v: Float)?
    var lastGazeHitEntityName: String?

    // MARK: - Intro veil (brand title dissolving away)
    var introOpacity: Float = 1
    var introIsActive: Bool = true
    var introFadeDuration: Float = 5.0
    var introElapsedTime: Float = 0
    var introLastTickTime: CFTimeInterval?
    var introVeilRoot: Entity?
    /// Inward-facing black sphere (spatial blackout); no collision/input.
    var introShellEntity: ModelEntity?
    var introTextEntity: ModelEntity?

    /// Gates initial ensemble + mix until intro veil has fully faded (exactly once).
    var hasStartedExperienceAudio: Bool = false

    #if DEBUG
    /// Dedupe gaze `[EyeTrack]` / `[Sound]` / `[Perception]` logs (one set per applied `audioMixVersion`).
    var lastGazeDebugLoggedMixVersion: UInt64?
    /// Carries color into `released` logs when `responseCategory` is already nil at mix time.
    var lastGazeColorForReleaseLog: String = ""

    /// Dedupe `[Raycast]` / spatial miss logs when hit stage changes (not per frame).
    var debugLastRaycastDedupeKey: String?
    /// Dedupe `[RegionCandidate]` when resolved region id changes.
    var debugLastRegionCandidateDedupeKey: String?
    /// Last gaze-resolved region id for `[Heartbeat]` (set each update from `currentGazeCandidateRegion()`).
    var debugLastGazeCandidateRegionId: String?
    /// `ray` | `none` — how the last gaze local point was obtained (DEBUG heartbeat).
    var debugLastGazeLocalSource: String = "none"
    /// ~1.0s `[Heartbeat]` cadence (diagnostics only).
    var debugLastHeartbeatTime: CFTimeInterval?
    /// Dedupe `[LookTarget]` when region id under pointer changes.
    var debugLastLookTargetLogId: String?
    /// World-space status indicator (no collision/input); mirrors gaze/focus for on-device troubleshooting.
    var debugSphereEntity: ModelEntity?

    /// One-shot `[PaintingPlaneReady]` after intro.
    var debugLoggedPaintingPlaneReadiness: Bool = false
    #endif
}

struct GazeImmersiveViewV2: View {
    @Environment(AppModel.self) private var appModel

    @State private var gazeManager = GazeInteractionManager()
    @State private var sceneState = PaintingSceneStateV2()

    @State private var lastTapMarker: ModelEntity?

    // Primary, supported passthrough tint via SurroundingsEffect.
    @State private var preferredSurroundingsEffectValue: SurroundingsEffect? = nil

    // Debug fallback: inverted-sphere wash proxy (kept for development / if SurroundingsEffect
    // can't be honored by the system for some reason).
    private let useInvertedSphereWashFallback: Bool = false

    var body: some View {
        RealityView { content in
            await setupScene(content: content)
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    handleTap(value: value)
                }
        )
        .preferredSurroundingsEffect(preferredSurroundingsEffectValue)
    }

    private func setupScene(content: RealityViewContent) async {
        gazeManager.isDebugMode = appModel.isDebugMode

        let root = AnchorEntity(.world(transform: matrix_identity_float4x4))
        content.add(root)

        // Broad primary visual cue: a surrounding world-tint wash driven by focus state.
        // Limitation: this tints the immersive view via a camera-anchored proxy entity
        // (supported RealityKit), not a system-level passthrough tint.
        // Use a head-anchored proxy so the wash stays stable while the user moves gaze.
        let headAnchor = AnchorEntity(.head)
        content.add(headAnchor)
        sceneState.headAnchorEntity = headAnchor
        let wash = makeWorldTintWashEntity()
        headAnchor.addChild(wash)
        sceneState.worldTintWashEntity = wash

        // Intro: spatial black shell (inverted sphere) + 3D title; fades to reveal the scene.
        // No collision shapes and no InputTarget/hover — does not affect painting raycasts.
        sceneState.introOpacity = 1
        sceneState.introIsActive = true
        sceneState.introFadeDuration = 5.0
        sceneState.introElapsedTime = 0
        sceneState.introLastTickTime = nil
        sceneState.hasStartedExperienceAudio = false
        // Block ensemble + preload + setAudioMix until intro shell completes (defense in depth vs. stray calls).
        AudioManager.shared.isIntroAudioGated = true
        let introVeil = makeIntroVeilEntities(introOpacityStart: 1)
        sceneState.introVeilRoot = introVeil.root
        sceneState.introShellEntity = introVeil.shell
        sceneState.introTextEntity = introVeil.text
        headAnchor.addChild(introVeil.root)

        // Phase 1: Try to load 3D PaintingAndEasel and align interactive plane to its painting surface.
        // Fallback: standalone flat canvas (current behavior).
        let easelEntity = await loadPaintingAndEaselEntity()
        let result: PaintingCanvasResult
        if let easel = easelEntity {
            let surface = findPaintingSurface(in: easel)

            // Scale down the authored easel model uniformly.
            // Applied exactly once at the easel root so the attached interactive plane
            // inherits the same transform and stays aligned.
            easel.scale = SIMD3<Float>(repeating: 0.25)
            #if DEBUG
            if appModel.isDebugMode {
                print("[Easel] scale applied: (0.25, 0.25, 0.25)")
            }
            #endif

            // Place the easel roughly where the standalone flat canvas used to be,
            // but preserve the asset's authored orientation (avoids double-rotation).
            easel.position = SIMD3<Float>(0, 0.2, -1.0)
            root.addChild(easel)

            #if DEBUG
            if appModel.isDebugMode {
                print("[Easel] final position: x=\(String(format: "%.3f", easel.position.x)), y=\(String(format: "%.3f", easel.position.y)), z=\(String(format: "%.3f", easel.position.z))")
            }
            #endif

            #if DEBUG
            if appModel.isDebugMode {
                let worldMatrix = easel.transformMatrix(relativeTo: nil)
                print("[Easel] world transform matrix=\(worldMatrix)")
            }
            #endif

            #if DEBUG
            if appModel.isDebugMode {
                print(
                    """
                    [AlignmentDebug] easel root local:
                      name=\(easel.name) position=\(easel.position)
                      orientation=\(easel.orientation)
                    """
                )
                print(
                    """
                    [AlignmentDebug] detected painting surface:
                      name=\(surface.name) position=\(surface.position)
                      orientation=\(surface.orientation)
                    """
                )
            }
            #endif

            result = await PaintingCanvasEntity.build(
                debugMode: appModel.isDebugMode,
                alignedToEaselSurface: true,
                alignedPlaneDebugVisible: alignedPlaneOrientationDebugVisible
            )
            surface.addChild(result.root)
            sceneState.interactionSource = .alignedPlaneOnEasel

            #if DEBUG
            if appModel.isDebugMode {
                print(
                    """
                    [AlignmentDebug] attached interactive plane:
                      planeRoot position=\(result.root.position)
                      planeRoot orientation=\(result.root.orientation)
                      interactionSource=\(sceneState.interactionSource.rawValue)
                      surfaceName=\(surface.name)
                    """
                )
            }
            #endif

            #if DEBUG
            if appModel.isDebugMode {
                print("[GazeImmersiveViewV2] PaintingAndEasel loaded; interactive plane aligned to surface '\(surface.name)'")
            }
            #endif
        } else {
            result = await PaintingCanvasEntity.build(debugMode: appModel.isDebugMode)
            root.addChild(result.root)
            sceneState.interactionSource = .flatPaintingPlane
            #if DEBUG
            if appModel.isDebugMode {
                print("[GazeImmersiveViewV2] PaintingAndEasel not found; using flat painting plane")
            }
            #endif
        }

        sceneState.overlayEntity = result.overlayEntity
        sceneState.regions = result.regions
        sceneState.regionByEntityName = result.regionByEntityName
        sceneState.overlayEnabled = !appModel.isOverlayDebugDisabled

        // Keep a reference to the painting plane for gaze hit-point -> UV mapping.
        sceneState.paintingCanvasRoot = result.root
        sceneState.paintingPlaneEntity = findEntity(in: result.root, named: "PaintingPlane")

        #if DEBUG
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                AuthoredPaintingRegion.logRegionCoverageGrid()
            }
        }
        #endif

        #if DEBUG
        if let plane = sceneState.paintingPlaneEntity as? ModelEntity {
            let dims = PaintingCanvasEntity.canvasDimensions()
            let hasCollision = plane.components[CollisionComponent.self] != nil
            let worldMatrix = plane.transformMatrix(relativeTo: nil)
            let worldPos = SIMD3<Float>(worldMatrix.columns.3.x, worldMatrix.columns.3.y, worldMatrix.columns.3.z)
            let extents = SIMD3<Float>(dims.width, 0.02, dims.height)
            print(
                "[SpatialSynesthesia] [RaycastFix] entity=\(plane.name) collision=\(hasCollision) " +
                "worldPos=(\(String(format: "%.3f", worldPos.x)),\(String(format: "%.3f", worldPos.y)),\(String(format: "%.3f", worldPos.z))) " +
                "extents=(\(String(format: "%.3f", extents.x)),\(String(format: "%.3f", extents.y)),\(String(format: "%.3f", extents.z)))"
            )
        }
        #endif

        #if DEBUG
        let debugSphere = makeDebugInteractionSphereEntity()
        result.root.addChild(debugSphere)
        sceneState.debugSphereEntity = debugSphere
        #endif

        // Hide interactive canvas until intro shell completes (no change to immersion style / startup order).
        result.root.isEnabled = false

        // Ensemble + mix start is deferred until intro veil completes (see SceneEvents.Update).

        // Drive fade + overlay updates from RealityKit's per-frame SceneEvents.Update
        // rather than RealityView's SwiftUI-driven `update:` callback.
        sceneState.sceneUpdateSubscription?.cancel()
        sceneState.sceneUpdateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
            Task { @MainActor in
                sceneState.sceneFromUpdateLoop = event.scene

                // 0) Fade the intro veil independently from gaze/audio/region logic.
                let introJustCompleted = tickIntroVeil()

                #if DEBUG
                logPaintingPlaneReadinessOnce()
                #endif

                // 1) Update focus state: spatial pointer on `PaintingPlane` or head-ray fallback → authored zones.
                let gazeCandidate = currentGazeCandidateRegion()
                #if DEBUG
                sceneState.debugLastGazeCandidateRegionId = gazeCandidate?.id
                let hbNow = CACurrentMediaTime()
                let shouldHeartbeat: Bool = {
                    if let t = sceneState.debugLastHeartbeatTime {
                        return hbNow - t >= 1.0
                    }
                    return true
                }()
                if shouldHeartbeat {
                    sceneState.debugLastHeartbeatTime = hbNow
                    let focusShort = gazeFocusStateShortLabel(gazeManager.focusState)
                    spatialSynesthesiaDebugLog(
                        "[Heartbeat] appAlive=true introActive=\(sceneState.introIsActive) focusState=\(focusShort) " +
                        "localSource=\(sceneState.debugLastGazeLocalSource) hitEntity=\(sceneState.lastGazeHitEntityName ?? "nil") " +
                        "candidateRegion=\(sceneState.debugLastGazeCandidateRegionId ?? "nil")"
                    )
                }
                #endif
                gazeManager.submitGazeCandidate(gazeCandidate)

                // Sample texture color at gaze UV (if enabled) to drive the response category.
                // Rollback behavior: when disabled, do nothing and keep manual region mapping.
                if appModel.isSampledColorModeEnabled, let uv = sceneState.lastGazeNormalizedUV {
                    // TODO: Sample from the actual 3D painting mesh UVs (instead of a plane proxy).
                    let sampled = PaintingColorSampler.shared.sample(u: uv.u, v: uv.v)
                    let classified = sampled.map { ColorSoundMapper.kandinskyClassify(for: $0) }
                    gazeManager.submitSampledClassification(classified, enabled: true)
                }

                // 2) Smooth overlay fade (overlay application is gated separately).
                gazeManager.tickOverlayFade()
                applyOverlayNow()

                #if DEBUG
                updateDebugInteractionSphereVisual()
                #endif

                // 2b) Broad world tint wash driven by the same focus state machine.
                updateWorldTintFromFocusState()

                // 3) Audio mix: apply every frame after intro so `.focused` / `.preFocus` stays in sync even when
                //    `audioMixVersion` does not change (e.g. relaunch already focused). No category filtering.
                if sceneState.hasStartedExperienceAudio, !sceneState.introIsActive {
                    let versionChanged = gazeManager.audioMixVersion != sceneState.lastAppliedAudioMixVersion
                    if versionChanged {
                        #if DEBUG
                        spatialSynesthesiaDebugLogAudioGateContext(
                            introJustCompleted: introJustCompleted,
                            willCallSetAudioMix: true
                        )
                        if appModel.isDebugMode {
                            print("[AudioUpdateGate] switched=YES audioMixVersion=\(gazeManager.audioMixVersion)")
                        }
                        if appModel.isDebugMode {
                            let src = sceneState.interactionSource.rawValue
                            let uvStr: String = {
                                if let uv = sceneState.lastGazeNormalizedUV {
                                    return "u=\(String(format: "%.3f", uv.u)) v=\(String(format: "%.3f", uv.v))"
                                }
                                return "u=nil v=nil"
                            }()
                            let hitName = sceneState.lastGazeHitEntityName ?? "nil"
                            let regionName = gazeManager.activeRegion?.name ?? "nil"
                            let cat = gazeManager.responseCategory?.rawValue ?? "nil"
                            let mode = gazeManager.activeColorSource.rawValue
                            if appModel.isSampledColorModeEnabled, let uv = sceneState.lastGazeNormalizedUV {
                                let sampled = PaintingColorSampler.shared.sample(u: uv.u, v: uv.v)
                                let rgbStr: String = sampled.map { "r=\(String(format: "%.3f", $0.r)) g=\(String(format: "%.3f", $0.g)) b=\(String(format: "%.3f", $0.b))" } ?? "r=nil g=nil b=nil"
                                let hsvStr: String = {
                                    guard let hsv = gazeManager.sampledLastHSV else { return "H=nil S=nil V=nil" }
                                    return "H=\(Int(hsv.h)) S=\(String(format: "%.2f", hsv.s)) V=\(String(format: "%.2f", hsv.v))"
                                }()
                                let conf = String(format: "%.2f", gazeManager.sampledLastConfidence)
                                let stable = gazeManager.sampledIsTransitioning ? "transitioning" : "stable"
                                print("[RegionSelect] mode=\(mode) state=\(stable) conf=\(conf) source=\(src) gazeHitEntity=\(hitName) region=\(regionName) category=\(cat) uv=\(uvStr) rgb=\(rgbStr) hsv=\(hsvStr)")
                            } else {
                                print("[RegionSelect] mode=\(mode) source=\(src) gazeHitEntity=\(hitName) region=\(regionName) category=\(cat) uv=\(uvStr)")
                            }
                        }
                        if gazeManager.debugLastAudioMixBumpSource == .gaze {
                            logGazeConfirmedEyeTrackSoundPerceptionIfChanged(
                                sceneState: sceneState,
                                gazeManager: gazeManager
                            )
                        } else {
                            logInteractionAudioDebugChain()
                        }
                        #endif
                        sceneState.lastAppliedAudioMixVersion = gazeManager.audioMixVersion
                    }
                    AudioManager.shared.setAudioMix(
                        focusState: gazeManager.focusState,
                        category: gazeManager.responseCategory
                    )
                    #if DEBUG
                    if appModel.isDebugMode, versionChanged, let cat = gazeManager.responseCategory {
                        let primary = ColorSoundMapper.soloStem(for: cat, regionId: gazeManager.activeRegion?.id)
                            .map { "\($0).m4a" } ?? "nil"
                        let secondaries = ColorSoundMapper.secondaryMappings(for: cat)
                        let conf = String(format: "%.2f", gazeManager.sampledLastConfidence)
                        let stable = gazeManager.sampledIsTransitioning ? "transitioning" : "stable"
                        let ensVol = String(format: "%.2f", AudioManager.shared.debugEnsembleVolume)
                        let soloVol = String(format: "%.2f", AudioManager.shared.debugActiveSoloVolume)
                        let soloStem = AudioManager.shared.debugActiveSoloStem ?? "nil"
                        print(
                            "[AudioMix] mode=\(gazeManager.activeColorSource.rawValue) sampled=\(stable) conf=\(conf) " +
                            "interactionSource=\(sceneState.interactionSource.rawValue) category=\(cat.rawValue) primary=\(primary) secondaries=\(secondaries) " +
                            "ensembleVol=\(ensVol) activeSoloStem=\(soloStem) activeSoloVol=\(soloVol)"
                        )
                    }
                    #endif
                } else if introJustCompleted {
                    // First audio start: after intro is gone, once — then existing mix behavior applies.
                    // `setAudioMix` calls `startEnsembleLoop()` internally — do not call twice (avoids duplicate preload).
                    #if DEBUG
                    spatialSynesthesiaDebugLogAudioGateContext(
                        introJustCompleted: true,
                        willCallSetAudioMix: true
                    )
                    #endif
                    AudioManager.shared.isIntroAudioGated = false
                    sceneState.hasStartedExperienceAudio = true
                    #if DEBUG
                    logInteractionAudioDebugChain()
                    // Match main `setAudioMix` branch: gaze-driven first mix after intro should emit `[Perception]` too.
                    if gazeManager.debugLastAudioMixBumpSource == .gaze {
                        logGazeConfirmedEyeTrackSoundPerceptionIfChanged(
                            sceneState: sceneState,
                            gazeManager: gazeManager
                        )
                    }
                    #endif
                    AudioManager.shared.setAudioMix(
                        focusState: gazeManager.focusState,
                        category: gazeManager.responseCategory
                    )
                    sceneState.lastAppliedAudioMixVersion = gazeManager.audioMixVersion
                }
            }
        }

        // World tracking for `queryDeviceAnchor` (gaze ray origin/direction). Same pattern as `ImmersiveView` proximity.
        Task { @MainActor in
            let session = ARKitSession()
            let provider = WorldTrackingProvider()
            sceneState.arSession = session
            sceneState.worldTracking = provider
            do {
                try await session.run([provider])
                print("[GazeImmersiveViewV2] WorldTrackingProvider started for device-anchor gaze")
            } catch {
                print("[GazeDiag-1] WorldTrackingProvider run failed: \(error)")
            }
        }

        if appModel.isDebugMode {
            // One-time verification logs to confirm entity separation and initial transparency.
            if let paintingPlane = findEntity(in: result.root, named: "PaintingPlane") as? ModelEntity {
                let materials = paintingPlane.components[ModelComponent.self]?.materials ?? []
                let matTypes = materials.map { String(describing: type(of: $0)) }.joined(separator: ", ")
                print(
                    "[GazeImmersiveViewV2] Verified PaintingPlane: name=\(paintingPlane.name), localPosition=\(paintingPlane.position), materialTypes=[\(matTypes)]"
                )
            } else {
                print("[GazeImmersiveViewV2] WARNING: Could not find PaintingPlane entity under canvas root.")
            }

            if let overlayModel = result.overlayEntity as? ModelEntity {
                let overlayOpacityStart = overlayModel.components[OpacityComponent.self]?.opacity ?? -1
                print(
                    "[GazeImmersiveViewV2] Verified Overlay entity: name=\(overlayModel.name), localPosition=\(overlayModel.position), opacityComponentStart=\(String(format: "%.3f", overlayOpacityStart))"
                )
            } else {
                print("[GazeImmersiveViewV2] WARNING: overlayEntity was not a ModelEntity.")
            }
        }

        // Ensure overlay starts invisible even if a previous category sneaked in.
        if let overlayModel = sceneState.overlayEntity as? ModelEntity {
            ColorFilterOverlay.updateOverlay(overlayModel, category: nil, opacity: 0)
        }

        if appModel.isOverlayDebugDisabled {
            print("[GazeImmersiveViewV2] Overlay debug disabled: overlay will not be updated; texture should be visible underneath.")
        }

        if appModel.isDebugMode {
            print("[GazeImmersiveViewV2] Canvas ready; \(result.regions.count) regions")
        }
    }

    #if DEBUG
    private func spatialSynesthesiaDebugLog(_ message: String) {
        print("[SpatialSynesthesia] \(message)")
    }

    private func spatialSynesthesiaDebugLogAudioGateContext(introJustCompleted: Bool, willCallSetAudioMix: Bool) {
        let focusStr: String = {
            switch gazeManager.focusState {
            case .noFocus: return "noFocus"
            case .released: return "released"
            case .preFocus(let r): return "preFocus(\(r.name))"
            case .focused(let r): return "focused(\(r.name))"
            }
        }()
        spatialSynesthesiaDebugLog(
            "[AudioGate] hasStarted=\(sceneState.hasStartedExperienceAudio) introActive=\(sceneState.introIsActive) " +
            "introElapsed=\(String(format: "%.2f", sceneState.introElapsedTime)) introJustCompleted=\(introJustCompleted) " +
            "introGate=\(AudioManager.shared.isIntroAudioGated) focus=\(focusStr) willCallSetAudioMix=\(willCallSetAudioMix)"
        )
    }

    /// Full chain when gaze-driven mix is applied (same conditions as `setAudioMix` calls).
    private func logInteractionAudioDebugChain() {
        let cat = gazeManager.responseCategory?.rawValue ?? "nil"
        let stateStr: String = {
            switch gazeManager.focusState {
            case .noFocus: return "noFocus"
            case .released: return "released"
            case .preFocus: return "preFocus"
            case .focused: return "focused"
            }
        }()
        let stem = gazeManager.responseCategory
            .flatMap { ColorSoundMapper.soloStem(for: $0, regionId: gazeManager.activeRegion?.id) } ?? "none"
        let file = stem == "none" ? "none" : "\(stem).m4a"
        spatialSynesthesiaDebugLog("[Interaction] color=\(cat) → state=\(stateStr) → solo=\(stem) → file=\(file)")
    }

    /// Gaze-confirmed path only: `SceneEvents.Update` → `submitGazeCandidate` → `audioMixVersion` bump from `.gaze`.
    /// One log set per applied mix version; matches `AudioManager.setAudioMix(category:)` mapping.
    private func logGazeConfirmedEyeTrackSoundPerceptionIfChanged(
        sceneState: PaintingSceneStateV2,
        gazeManager: GazeInteractionManager
    ) {
        let v = gazeManager.audioMixVersion
        if sceneState.lastGazeDebugLoggedMixVersion == v { return }

        let focus = gazeManager.focusState
        let category = gazeManager.responseCategory

        switch focus {
        case .released:
            let prevColor = sceneState.lastGazeColorForReleaseLog.isEmpty
                ? (category?.rawValue ?? "nil")
                : sceneState.lastGazeColorForReleaseLog
            spatialSynesthesiaDebugLog("[EyeTrack] released color=\(prevColor) state=released")
            spatialSynesthesiaDebugLog("[Sound] returningToEnsemble=true")
            sceneState.lastGazeColorForReleaseLog = ""

        case .preFocus(let r):
            let colorStr = category?.rawValue ?? r.colorCategory.rawValue
            let stem = ColorSoundMapper.soloStem(for: category ?? r.colorCategory, regionId: r.id)
            let stemStr = stem ?? "nil"
            let file = stem.map { "\($0).m4a" } ?? "nil"
            let hexStr = AuthoredPaintingRegion.kandinskyComposition.first(where: { $0.id == r.id })?.hexColor ?? "nil"
            spatialSynesthesiaDebugLog("[EyeTrack] lookedAtColor=\(colorStr) region=\(r.id) state=preFocus")
            spatialSynesthesiaDebugLog("[Sound] color=\(colorStr) stem=\(stemStr) file=\(file)")
            spatialSynesthesiaDebugLog("[Perception] \(hexStr) -> \(colorStr) -> \(file)")
            sceneState.lastGazeColorForReleaseLog = colorStr

        case .focused(let r):
            let colorStr = category?.rawValue ?? r.colorCategory.rawValue
            let stem = ColorSoundMapper.soloStem(for: category ?? r.colorCategory, regionId: r.id)
            let stemStr = stem ?? "nil"
            let file = stem.map { "\($0).m4a" } ?? "nil"
            let hexStr = AuthoredPaintingRegion.kandinskyComposition.first(where: { $0.id == r.id })?.hexColor ?? "nil"
            spatialSynesthesiaDebugLog("[EyeTrack] lookedAtColor=\(colorStr) region=\(r.id) state=focused")
            spatialSynesthesiaDebugLog("[Sound] color=\(colorStr) stem=\(stemStr) file=\(file)")
            spatialSynesthesiaDebugLog("[Perception] \(hexStr) -> \(colorStr) -> \(file)")
            sceneState.lastGazeColorForReleaseLog = colorStr

        case .noFocus:
            return
        }

        sceneState.lastGazeDebugLoggedMixVersion = v
    }

    /// Dedupe: logs only when ray stage / hit entity changes (not per frame).
    private func logRaycastRawHitIfChanged(dedupeKey: String, hitEntityName: String?, distance: Float?, hitPoint: SIMD3<Float>?) {
        if sceneState.debugLastRaycastDedupeKey == dedupeKey { return }
        sceneState.debugLastRaycastDedupeKey = dedupeKey
        let e = hitEntityName ?? "nil"
        let dStr = distance.map { String(format: "%.4f", $0) } ?? "nil"
        let pStr: String
        if let p = hitPoint {
            pStr = String(format: "(%.3f,%.3f,%.3f)", p.x, p.y, p.z)
        } else {
            pStr = "nil"
        }
        spatialSynesthesiaDebugLog("[Raycast] hitEntity=\(e) distance=\(dStr) hitPoint=\(pStr)")
    }

    /// Dedupe: logs when resolved `PaintingRegion` id changes; only emits a line when a non-nil region is found.
    private func logRegionCandidateIfChanged(region: PaintingRegion?, localPoint: SIMD3<Float>) {
        let key = region?.id ?? "nil"
        if sceneState.debugLastRegionCandidateDedupeKey == key { return }
        sceneState.debugLastRegionCandidateDedupeKey = key
        guard let region else { return }
        let lp = String(format: "(%.3f,%.3f,%.3f)", localPoint.x, localPoint.y, localPoint.z)
        spatialSynesthesiaDebugLog("[RegionCandidate] region=\(region.id) color=\(region.colorCategory.rawValue) localPoint=\(lp)")
    }

    private func gazeFocusStateShortLabel(_ state: GazeInteractionManager.FocusState) -> String {
        switch state {
        case .noFocus: return "noFocus"
        case .released: return "released"
        case .preFocus: return "preFocus"
        case .focused: return "focused"
        }
    }

    /// Dedupe `[LookTarget]` when the resolved authored region changes (`appModel.isDebugMode`).
    private func logLookTargetIfChanged(regionId: String?) {
        guard appModel.isDebugMode else { return }
        let key = regionId ?? "nil"
        if sceneState.debugLastLookTargetLogId == key { return }
        sceneState.debugLastLookTargetLogId = key
        if let id = regionId,
           let authored = AuthoredPaintingRegion.kandinskyComposition.first(where: { $0.id == id }) {
            spatialSynesthesiaDebugLog(
                "[LookTarget] region=\(id) hex=\(authored.hexColor) category=\(authored.category.rawValue)"
            )
        } else {
            spatialSynesthesiaDebugLog("[LookTarget] region=nil hex=nil category=nil")
        }
    }

    /// After intro, once: confirms `PaintingPlane` interaction components (`appModel.isDebugMode`).
    private func logPaintingPlaneReadinessOnce() {
        guard appModel.isDebugMode else { return }
        guard !sceneState.introIsActive else { return }
        guard !sceneState.debugLoggedPaintingPlaneReadiness, let plane = sceneState.paintingPlaneEntity else { return }
        sceneState.debugLoggedPaintingPlaneReadiness = true
        let hasInput = plane.components[InputTargetComponent.self] != nil
        let hasCollision = plane.components[CollisionComponent.self] != nil
        let sceneAttached = plane.scene != nil
        let updateLoop = sceneState.sceneFromUpdateLoop != nil
        spatialSynesthesiaDebugLog(
            "[PaintingPlaneReady] name=\(plane.name) isEnabled=\(plane.isEnabled) InputTarget=\(hasInput) " +
                "Collision=\(hasCollision) sceneAttached=\(sceneAttached) updateLoopScene=\(updateLoop)"
        )
    }

    private func uiColorFromAuthoredHex(_ hex: String) -> UIColor? {
        UIColor(hex: hex)
    }

    private func sphereTintForAuthoredRegion(id: String, fallback: KandinskyColorCategory) -> UIColor {
        if let authored = AuthoredPaintingRegion.kandinskyComposition.first(where: { $0.id == id }) {
            return authored.category.vividTintColor
        }
        return fallback.vividTintColor
    }

    /// DEBUG-only world-space indicator beside the painting: mirrors gaze hit + `GazeInteractionManager` focus (does not drive behavior).
    /// No `CollisionComponent` / `InputTargetComponent` / `HoverEffectComponent` — does not participate in raycasts.
    private func makeDebugInteractionSphereEntity() -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 1.0)
        let material = UnlitMaterial(color: UIColor.white.withAlphaComponent(0))
        let sphere = ModelEntity(mesh: mesh, materials: [material])
        sphere.name = "DebugInteractionSphere"
        // Local space of `PaintingCanvas` root: right of artwork, slightly above mid, slightly forward.
        sphere.position = SIMD3<Float>(0.45, 0.15, 0.02)
        sphere.scale = SIMD3<Float>(repeating: 0.028)
        sphere.components.set(OpacityComponent(opacity: 0))
        return sphere
    }

    /// Updates debug sphere from existing state only (after `submitGazeCandidate` + `tickOverlayFade`).
    private func updateDebugInteractionSphereVisual() {
        guard let sphere = sceneState.debugSphereEntity else { return }
        guard let canvasRoot = sceneState.paintingCanvasRoot,
              canvasRoot.isEnabled,
              !sceneState.introIsActive else {
            sphere.components.set(OpacityComponent(opacity: 0))
            return
        }

        let baseRadius: Float = 0.028
        let focus = gazeManager.focusState

        func apply(color: UIColor, opacity: Float, uniformScale: Float) {
            guard var model = sphere.components[ModelComponent.self] else { return }
            model.materials = [UnlitMaterial(color: color)]
            sphere.components.set(model)
            sphere.components.set(OpacityComponent(opacity: opacity))
            sphere.scale = SIMD3<Float>(repeating: uniformScale)
        }

        switch focus {
        case .released:
            apply(color: .white, opacity: 0, uniformScale: baseRadius)

        case .noFocus:
            if let id = sceneState.currentLookTargetRegionId {
                let cat = sceneState.regionByEntityName[id]?.colorCategory ?? .gray
                let c = sphereTintForAuthoredRegion(id: id, fallback: cat)
                apply(color: c, opacity: 0.72, uniformScale: baseRadius * 0.88)
            } else {
                apply(color: .white, opacity: 0, uniformScale: baseRadius)
            }

        case .preFocus(let region):
            let cat = gazeManager.responseCategory ?? region.colorCategory
            let c = sphereTintForAuthoredRegion(id: region.id, fallback: cat)
            apply(color: c, opacity: 0.92, uniformScale: baseRadius * 1.0)

        case .focused(let region):
            let cat = gazeManager.responseCategory ?? region.colorCategory
            let c = sphereTintForAuthoredRegion(id: region.id, fallback: cat)
            apply(color: c, opacity: 1.0, uniformScale: baseRadius * 1.22)
        }
    }
    #endif

    /// Applies the overlay tint immediately based on the current fade state.
    private func applyOverlayNow() {
        guard sceneState.overlayEnabled else { return }
        guard let overlayModel = sceneState.overlayEntity as? ModelEntity else { return }

        let cat = gazeManager.overlayCategoryForRendering
        let opacity = gazeManager.overlayOpacityForMaterial

        if let cat, opacity > 0.001,
           let region = gazeManager.activeRegion,
           !region.hexColor.isEmpty,
           let base = UIColor(hex: region.hexColor) {
            let a = CGFloat(opacity) * cat.overlayAlpha
            ColorFilterOverlay.updateOverlay(overlayModel, color: base.withAlphaComponent(a))
            return
        }

        ColorFilterOverlay.updateOverlay(
            overlayModel,
            category: cat,
            opacity: opacity
        )
    }

    // MARK: - Intro veil (spatial black shell)

    private func makeIntroVeilEntities(introOpacityStart: Float) -> (root: Entity, shell: ModelEntity, text: ModelEntity) {
        // Head-anchored root: viewer sits inside the shell (environmental blackout, not a flat card).
        let root = Entity()
        root.name = "IntroVeilRoot"
        root.position = SIMD3<Float>(0, 0, 0)

        // Large inward-facing sphere: negate X so interior faces render (same pattern as WorldTintWash).
        let shellRadius: Float = 18.0
        let shellMesh = MeshResource.generateSphere(radius: shellRadius)
        let shellMaterial = UnlitMaterial(color: .black)
        let shell = ModelEntity(mesh: shellMesh, materials: [shellMaterial])
        shell.name = "IntroBlackShell"
        shell.scale = SIMD3<Float>(-1, 1, 1)
        shell.components.set(OpacityComponent(opacity: introOpacityStart))
        // Intentionally no generateCollisionShapes / InputTarget / HoverEffect.
        root.addChild(shell)

        // Option A: 3D title inside the shell; fades with the shell (no cutout shader).
        let font = UIFont.systemFont(ofSize: 0.14, weight: .bold)
        let textMesh = MeshResource.generateText(
            "synesthesia",
            extrusionDepth: 0.01,
            font: font
        )
        let textMaterial = SimpleMaterial(color: .white, isMetallic: false)
        let text = ModelEntity(mesh: textMesh, materials: [textMaterial])
        text.name = "IntroVeilText"
        text.components.set(OpacityComponent(opacity: introOpacityStart))
        root.addChild(text)

        // Center title in front of the viewer (head space: -Z forward).
        let bounds = text.visualBounds(relativeTo: root)
        let center = SIMD3<Float>(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
        let titleZ: Float = -2.6
        text.position = SIMD3<Float>(-center.x, -center.y, titleZ - center.z)

        return (root, shell, text)
    }

    /// - Returns: `true` when the intro veil finished this frame (fade complete or failed-safe removal).
    private func tickIntroVeil() -> Bool {
        guard sceneState.introIsActive else { return false }
        guard
            let shell = sceneState.introShellEntity,
            let text = sceneState.introTextEntity
        else {
            // If something went missing, disable the veil to avoid blocking the experience.
            sceneState.introIsActive = false
            sceneState.paintingCanvasRoot?.isEnabled = true
            #if DEBUG
            print("[SpatialSynesthesia] [CanvasEnabled] introFinished=true canvasEnabled=true")
            #endif
            sceneState.introVeilRoot?.removeFromParent()
            sceneState.introVeilRoot = nil
            sceneState.introShellEntity = nil
            sceneState.introTextEntity = nil
            return true
        }

        let now = CACurrentMediaTime()
        if let last = sceneState.introLastTickTime {
            sceneState.introElapsedTime += Float(max(0, now - last))
        } else {
            // First tick: start at current time without skipping duration.
            sceneState.introElapsedTime = 0
        }
        sceneState.introLastTickTime = now

        let denom = max(sceneState.introFadeDuration, 0.0001)
        let progress = min(1, sceneState.introElapsedTime / denom)
        let nextOpacity = max(0, 1 - progress)
        sceneState.introOpacity = nextOpacity

        shell.components.set(OpacityComponent(opacity: nextOpacity))
        text.components.set(OpacityComponent(opacity: nextOpacity))

        if progress >= 1 {
            sceneState.introIsActive = false
            sceneState.paintingCanvasRoot?.isEnabled = true
            #if DEBUG
            print("[SpatialSynesthesia] [CanvasEnabled] introFinished=true canvasEnabled=true")
            #endif
            sceneState.introVeilRoot?.removeFromParent()
            sceneState.introVeilRoot = nil
            sceneState.introShellEntity = nil
            sceneState.introTextEntity = nil
            return true
        }
        return false
    }

    // MARK: - World tint wash (broad immersive visual cue)

    /// Passthrough tint fade timing (world multiply envelope — not `AudioManager` crossfades).
    private let tintFadeInDuration: TimeInterval = 0.20
    private let tintFadeOutDuration: TimeInterval = 0.70
    /// First-order step toward target each frame: tuned from `tintFadeInDuration` / `tintFadeOutDuration`.
    private let worldTintAttackBlendSpeed: Float = Float(4.0 / 0.20)
    private let worldTintReleaseBlendSpeed: Float = Float(4.0 / 0.70)
    private let worldTintPreFocusIntensity: Float = 0.45
    private let worldTintFocusedIntensity: Float = 0.90

    private let surroundingsTintPreFocusIntensity: Float = 0.45
    private let surroundingsTintFocusedIntensity: Float = 0.90

    private func makeWorldTintWashEntity() -> ModelEntity {
        // Large sphere around the camera so the whole immersive view appears tinted.
        // We invert the sphere by scaling to [-1, 1, 1] so inside faces render.
        let radius: Float = 20.0
        let mesh = MeshResource.generateSphere(radius: radius)
        let initialMaterial = UnlitMaterial(color: UIColor.white.withAlphaComponent(0))
        let entity = ModelEntity(mesh: mesh, materials: [initialMaterial])
        entity.name = "WorldTintWash"
        entity.scale = SIMD3<Float>(-1, 1, 1)
        entity.components.set(OpacityComponent(opacity: 0))
        // No collisions: must not affect taps/region hit testing.
        return entity
    }

    private func neutralTintMultiplier(for category: KandinskyColorCategory) -> Float {
        // Keep neutrals perceptible but controlled.
        switch category {
        case .black: return 0.55
        case .gray: return 0.50
        case .white: return 0.35
        case .brown: return 0.65
        default: return 1.0
        }
    }

    /// Builds a multiply color whose "distance from white" controls tint intensity.
    /// - Note: this is an approximation for intensity because SurroundingsEffect
    ///   `colorMultiply` does not expose a separate intensity parameter.
    private func surroundingsMultiplyColor(category: KandinskyColorCategory?, intensity: Float) -> Color {
        guard let cat = category else { return .white }
        let tintIntensityMultiplier: Float = 1.8
        let finalIntensity = min(1.0, cat.tintIntensity * tintIntensityMultiplier)
        let isChromatic: Bool = {
            switch cat {
            case .red, .yellow, .blue, .green, .violet, .orange, .brown:
                return true
            case .gray, .white, .black:
                return false
            }
        }()
        let chromaticMultiplyBoost: CGFloat = isChromatic ? 1.22 : 1.0

        let rawColor = cat.vividTintColor
        let boosted = rawColor.withMinSaturation(0.80)

        let env = max(0, min(1, CGFloat(intensity)))
        let t = min(1, env * CGFloat(finalIntensity) * chromaticMultiplyBoost)

        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        _ = boosted.getRed(&r, green: &g, blue: &b, alpha: &a)

        let rr = 1 * (1 - t) + r * t
        let gg = 1 * (1 - t) + g * t
        let bb = 1 * (1 - t) + b * t

        return Color(red: rr, green: gg, blue: bb)
    }

    private func updateWorldTintFromFocusState() {
        guard let wash = sceneState.worldTintWashEntity else { return }

        let (focusKey, focusStateName, targetTintIntensity, targetCategory, targetRegionName, targetPaintingRegion): (String, String, Float, KandinskyColorCategory?, String, PaintingRegion?) = {
            switch gazeManager.focusState {
            case .noFocus:
                return ("noFocus", "noFocus", 0, nil, "nil", nil)
            case .released:
                return ("released", "released", 0, nil, "nil", nil)
            case .preFocus(let region):
                let cat = gazeManager.responseCategory ?? region.colorCategory
                let mult = neutralTintMultiplier(for: cat)
                return (
                    "preFocus:\(region.id)",
                    "preFocus",
                    surroundingsTintPreFocusIntensity * mult,
                    cat,
                    region.name,
                    region
                )
            case .focused(let region):
                let cat = gazeManager.responseCategory ?? region.colorCategory
                let mult = neutralTintMultiplier(for: cat)
                return (
                    "focused:\(region.id)",
                    "focused",
                    surroundingsTintFocusedIntensity * mult,
                    cat,
                    region.name,
                    region
                )
            }
        }()

        let hexLog: String = {
            if let c = targetCategory { return "vividTint:\(c.rawValue)" }
            return "none"
        }()
        let catLog = targetCategory?.rawValue ?? "nil"
        let gate3Sig = "\(focusStateName)|\(targetPaintingRegion?.id ?? "nil")|\(catLog)|\(hexLog)"
        if gate3Sig != sceneState.gate3LastPrintedSignature {
            sceneState.gate3LastPrintedSignature = gate3Sig
            print(
                "[Gate3-Tint] focusState=\(focusStateName) region=\(targetPaintingRegion?.name ?? "nil") category=\(catLog) hex=\(hexLog)"
            )
            print(
                "[TintEntry] focusState=\(focusStateName) category=\(catLog) region=\(targetPaintingRegion?.entityName ?? "nil")"
            )
        }

        // Smooth intensity continuously (attack/release) so audio + overlay + world tint stay coherent.
        let now = CACurrentMediaTime()
        let dt: Float = {
            guard let last = sceneState.worldTintLastTickTime else { return 1.0 / 60.0 }
            return Float(max(0, now - last))
        }()
        sceneState.worldTintLastTickTime = now

        sceneState.worldTintTargetOpacity = targetTintIntensity
        let speed = sceneState.worldTintTargetOpacity > sceneState.worldTintOpacity ? worldTintAttackBlendSpeed : worldTintReleaseBlendSpeed
        let blendFactor = min(1, speed * dt)
        sceneState.worldTintOpacity = sceneState.worldTintOpacity
            + (sceneState.worldTintTargetOpacity - sceneState.worldTintOpacity) * blendFactor

        // Fallback proxy wash (inverted sphere) - ONLY for debug/development.
        if useInvertedSphereWashFallback {
            if let cat = targetCategory, sceneState.worldTintOpacity > 0.001 {
                let tintUIColor = cat.overlayTint.withAlphaComponent(CGFloat(sceneState.worldTintOpacity))
                ColorFilterOverlay.updateOverlay(wash, color: tintUIColor)
            } else {
                ColorFilterOverlay.updateOverlay(wash, color: .clear)
            }
        } else {
            ColorFilterOverlay.updateOverlay(wash, color: .clear)
        }

        // Primary world tint: real SurroundingsEffect tint (colorMultiply).
        if !useInvertedSphereWashFallback {
            let effectIntensity = sceneState.worldTintOpacity
            let effectActive = targetCategory != nil && effectIntensity > 0.001

            if effectActive {
                // Avoid spamming the preferredSurroundingsEffect when intensity changes minimally.
                let shouldUpdateEffect =
                    abs(effectIntensity - sceneState.lastAppliedWorldTintIntensityForEffect) > 0.01 ||
                    sceneState.lastAppliedTintFocusKey != focusKey

                if shouldUpdateEffect, let cat = targetCategory {
                    let vivid = cat.vividTintColor
                    print(
                        "[TintColorResolve] willUseVivid=true color=\(vivid)"
                    )
                    let multiplyColor = surroundingsMultiplyColor(
                        category: cat,
                        intensity: effectIntensity
                    )
                    print(
                        "[Gate3-TintAssign] color=\(multiplyColor) intensity=\(effectIntensity)"
                    )
                    preferredSurroundingsEffectValue = .colorMultiply(multiplyColor)
                    sceneState.lastAppliedWorldTintIntensityForEffect = effectIntensity
                    let uiTint = UIColor(multiplyColor)
                    var tr: CGFloat = 0
                    var tg: CGFloat = 0
                    var tb: CGFloat = 0
                    var ta: CGFloat = 0
                    _ = uiTint.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
                    print(
                        "[TintApplied] intensity=\(effectIntensity) rgb=\(tr),\(tg),\(tb)"
                    )
                }
            } else {
                preferredSurroundingsEffectValue = nil
                sceneState.lastAppliedWorldTintIntensityForEffect = 0
            }
        } else {
            preferredSurroundingsEffectValue = nil
            sceneState.lastAppliedWorldTintIntensityForEffect = 0
        }

        // Trust-check logging: only when focus identity changes.
        if sceneState.lastAppliedTintFocusKey != focusKey {
            sceneState.lastAppliedTintFocusKey = focusKey

            let overlayIntensity = gazeManager.overlayOpacityForMaterial

            let activeColor = targetCategory?.rawValue ?? "nil"
            let activeSoloStem = gazeManager.responseCategory.flatMap {
                ColorSoundMapper.soloStem(for: $0, regionId: gazeManager.activeRegion?.id)
            }
            let activeSoloFile = activeSoloStem.map { "\($0).m4a" } ?? "nil"

            let ensembleNearSilenceFactorForBlack: Float = 0.05
            let ensembleWhiteGrayFactor: Float = 0.85
            let categoryFactor: Float = {
                guard let c = targetCategory else { return 1.0 }
                switch c {
                case .black: return ensembleNearSilenceFactorForBlack
                case .white, .gray: return ensembleWhiteGrayFactor
                default: return 1.0
                }
            }()

            let ensembleTargetVolume: Float = {
                switch gazeManager.focusState {
                case .noFocus, .released:
                    return AudioManager.ensembleBaseVolume
                case .preFocus:
                    return AudioManager.ensemblePrefocusVolume * categoryFactor
                case .focused:
                    return AudioManager.ensembleFocusedVolume * categoryFactor
                }
            }()

            let effectIntensity = sceneState.worldTintOpacity
            let effectActive = (!useInvertedSphereWashFallback) && targetCategory != nil && effectIntensity > 0.001
            var multR: CGFloat = 1
            var multG: CGFloat = 1
            var multB: CGFloat = 1
            var multA: CGFloat = 1
            if effectActive, let c = targetCategory {
                let ui = UIColor(surroundingsMultiplyColor(
                    category: c,
                    intensity: effectIntensity
                ))
                _ = ui.getRed(&multR, green: &multG, blue: &multB, alpha: &multA)
            }

            print(
                "[TrustSyncTint] focusState=\(focusStateName) region=\(targetRegionName) responseCategory=\(activeColor) " +
                "tintIntensity(target)=\(String(format: "%.2f", targetTintIntensity)) tintIntensity(current)=\(String(format: "%.2f", sceneState.worldTintOpacity)) " +
                "surroundingsEffect=\(effectActive ? "ACTIVE" : "neutral") multiplyRGB=\(String(format: "%.2f", multR)),\(String(format: "%.2f", multG)),\(String(format: "%.2f", multB)) " +
                "overlayOpacity=\(String(format: "%.2f", gazeManager.overlayOpacity)) overlayIntensity=\(String(format: "%.2f", overlayIntensity)) " +
                "activeSoloStem=\(activeSoloFile) ensembleTargetVol=\(String(format: "%.2f", ensembleTargetVolume))"
            )
        }
    }

    private func handleTap(value: EntityTargetValue<SpatialTapGesture.Value>) {
        let tappedEntity = value.entity
        let tappedName = tappedEntity.name

        // Single collider on the textured plane; authored regions are resolved in plane local space.
        if tappedName == "PaintingPlane" {
            #if DEBUG
            if appModel.isDebugMode {
                print("[GazeImmersiveViewV2] Tap on PaintingPlane interactionSource=\(sceneState.interactionSource.rawValue)")
            }
            #endif
            let localPoint = value.convert(value.location3D, from: .local, to: tappedEntity)
            let localPosition = (Float(localPoint.x), Float(localPoint.y), Float(localPoint.z))

            // Visual tap marker for debug readability (same style as region taps).
            if appModel.isDebugMode {
                updateTapMarker(on: tappedEntity, localPosition: localPosition)
            }

            if let mappedRegion = regionForLocalPoint(localPoint) {
                if gazeManager.activeRegion?.id == mappedRegion.id {
                    gazeManager.clearActiveRegion()
                } else {
                    gazeManager.setActiveRegion(
                        mappedRegion,
                        hitEntityName: tappedName,
                        localPosition: localPosition
                    )
                }
            } else {
                // If UV mapping fails (shouldn't), fall back to clearing.
                gazeManager.clearActiveRegion()
            }

            // Start fade/update immediately so the UI responds on this tap.
            gazeManager.tickOverlayFade()
            applyOverlayNow()

            #if DEBUG
            if appModel.isDebugMode {
                let uv = normalizedUVForPaintingPlaneLocalPoint(localPoint)
                let rName = gazeManager.activeRegion?.name ?? "nil"
                let cat = gazeManager.responseCategory?.rawValue ?? "nil"
                let mode = gazeManager.activeColorSource.rawValue
                if appModel.isSampledColorModeEnabled {
                    let sampled = PaintingColorSampler.shared.sample(u: uv.u, v: uv.v)
                    let rgbStr: String = sampled.map { "r=\(String(format: "%.3f", $0.r)) g=\(String(format: "%.3f", $0.g)) b=\(String(format: "%.3f", $0.b))" } ?? "r=nil g=nil b=nil"
                    print("[TapPlane] mode=\(mode) source=\(sceneState.interactionSource.rawValue) region=\(rName) category=\(cat) uv=u=\(String(format: "%.3f", uv.u)) v=\(String(format: "%.3f", uv.v)) rgb=\(rgbStr)")
                } else {
                    print("[TapPlane] mode=\(mode) source=\(sceneState.interactionSource.rawValue) region=\(rName) category=\(cat) uv=u=\(String(format: "%.3f", uv.u)) v=\(String(format: "%.3f", uv.v))")
                }
            }
            #endif

            if sceneState.hasStartedExperienceAudio, !sceneState.introIsActive {
                if gazeManager.audioMixVersion != sceneState.lastAppliedAudioMixVersion {
                    sceneState.lastAppliedAudioMixVersion = gazeManager.audioMixVersion
                    #if DEBUG
                    spatialSynesthesiaDebugLogAudioGateContext(introJustCompleted: false, willCallSetAudioMix: true)
                    logInteractionAudioDebugChain()
                    #endif
                }
                AudioManager.shared.setAudioMix(
                    focusState: gazeManager.focusState,
                    category: gazeManager.responseCategory
                )
            }
        }
    }

    // MARK: - Plane local point (device-anchor ray) → `resolveAuthoredRegion` → `PaintingRegion`

    /// Gaze hit on `PaintingPlane` via ARKit device anchor + analytic ray–plane intersection (`MeshResource.generatePlane` → local +Y face normal).
    private func localPointOnPaintingPlaneForGaze() -> SIMD3<Float>? {
        guard let worldTrackingProvider = sceneState.worldTracking else {
            print("[GazeDiag-1] DeviceAnchor unavailable")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        guard worldTrackingProvider.state == .running else {
            print("[GazeDiag-1] WorldTrackingProvider not running: \(worldTrackingProvider.state)")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let time = CACurrentMediaTime()
        guard let deviceAnchor = worldTrackingProvider.queryDeviceAnchor(atTimestamp: time) else {
            print("[GazeDiag-2] HeadAnchor unavailable")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        guard let painting = sceneState.paintingPlaneEntity else {
            print("[GazeDiag-3] paintingEntity is nil")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let worldTransform = painting.transformMatrix(relativeTo: nil)
        guard worldTransform != matrix_identity_float4x4 else {
            print("[GazeDiag-4] painting world transform is identity or invalid")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let deviceTransform = deviceAnchor.originFromAnchorTransform
        let rayOrigin = SIMD3<Float>(
            deviceTransform.columns.3.x,
            deviceTransform.columns.3.y,
            deviceTransform.columns.3.z
        )
        let rayDir = normalize(
            SIMD3<Float>(
                -deviceTransform.columns.2.x,
                -deviceTransform.columns.2.y,
                -deviceTransform.columns.2.z
            )
        )
        print("[GazeDiag-5] ray origin built: \(rayOrigin), dir: \(rayDir)")

        // `generatePlane(width:depth:)` lies in XZ; face normal is local +Y → world column 1.
        let col1 = worldTransform.columns.1
        var planeNormal = normalize(SIMD3<Float>(col1.x, col1.y, col1.z))
        guard simd_length(planeNormal) > 1e-6 else {
            print("[GazeDiag-4] painting world transform is identity or invalid")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let planePoint = SIMD3<Float>(
            worldTransform.columns.3.x,
            worldTransform.columns.3.y,
            worldTransform.columns.3.z
        )
        if dot(planeNormal, rayDir) > 0 { planeNormal = -planeNormal }
        print("[GazeDiag-6] plane normal: \(planeNormal), planePoint: \(planePoint)")

        let denom = dot(planeNormal, rayDir)
        guard abs(denom) > 1e-6 else {
            print("[GazeDiag-7] denom near zero = \(denom), ray parallel to plane")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let t = dot(planeNormal, planePoint - rayOrigin) / denom
        guard t > 0 else {
            print("[GazeDiag-8] t value negative = \(t), intersection behind origin")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let worldHit = rayOrigin + rayDir * t
        print("[GazeDiag-9] worldHit computed: \(worldHit)")

        let worldHit4 = SIMD4<Float>(worldHit.x, worldHit.y, worldHit.z, 1.0)
        let localHit4 = simd_mul(simd_inverse(worldTransform), worldHit4)

        // Empirically calibrated from device boundary samples (two separate runs).
        // Mesh local x half-extent (~2.015) maps to region x half-extent (0.37).
        // Mesh local z half-extent (~4.162) maps to region z half-extent (0.47).
        // These are fixed geometric constants of PaintingCanvasEntity's mesh.
        let kScaleX: Float = 5.446
        let kScaleZ: Float = 8.855

        let remappedLocal = SIMD3<Float>(
            localHit4.x / kScaleX,
            localHit4.y,
            localHit4.z / kScaleZ
        )

        print("[LocalSpaceCheck] paintingScale=\(painting.scale(relativeTo: nil)) localRaw=(\(localHit4.x), \(localHit4.y), \(localHit4.z))")
        print("[GazeDiag-10] localHit computed: \(remappedLocal)")

        if let firstRegion = AuthoredPaintingRegion.kandinskyComposition.first {
            print("[RegionBoundsCheck] firstRegion center=\(firstRegion.localCenter) size=\(firstRegion.localSize)")
        }
        if AuthoredPaintingRegion.resolveAuthoredRegion(localPoint: remappedLocal) == nil {
            AuthoredPaintingRegion.kandinskyComposition.forEach {
                print("[RegionDump] \($0.category) center=\($0.localCenter) size=\($0.localSize)")
            }
        }

        #if DEBUG
        sceneState.debugLastGazeLocalSource = "ray"
        logRaycastRawHitIfChanged(
            dedupeKey: "hit:PaintingPlane:deviceRay",
            hitEntityName: "PaintingPlane",
            distance: t,
            hitPoint: worldHit
        )
        #endif

        print("[LocalPointSuccess] source=ray local=\(remappedLocal)")
        return remappedLocal
    }

    /// Resolves `PaintingRegion` for an authored zone, including synthetic regions not backed by scene entities.
    private func paintingRegion(for authored: AuthoredPaintingRegion) -> PaintingRegion {
        if let r = sceneState.regionByEntityName[authored.id] {
            return r
        }
        let dims = PaintingCanvasEntity.canvasDimensions()
        return authored.toPaintingRegion(canvasWidth: dims.width, canvasHeight: dims.height)
    }

    private func currentGazeCandidateRegion() -> PaintingRegion? {
        let canvasReady = sceneState.paintingCanvasRoot?.isEnabled == true && !sceneState.introIsActive
        guard canvasReady else {
            sceneState.currentLookTargetRegionId = nil
            sceneState.lastGazeHitEntityName = nil
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            logLookTargetIfChanged(regionId: nil)
            logRaycastRawHitIfChanged(dedupeKey: "canvas_disabled_or_intro", hitEntityName: nil, distance: nil, hitPoint: nil)
            #endif
            return nil
        }

        guard let localOnPlane = localPointOnPaintingPlaneForGaze() else {
            sceneState.currentLookTargetRegionId = nil
            sceneState.lastGazeHitEntityName = nil
            #if DEBUG
            logLookTargetIfChanged(regionId: nil)
            logRaycastRawHitIfChanged(dedupeKey: "no_local_point", hitEntityName: nil, distance: nil, hitPoint: nil)
            #endif
            return nil
        }

        sceneState.lastGazeHitEntityName = "PaintingPlane"
        sceneState.lastGazeNormalizedUV = normalizedUVForPaintingPlaneLocalPoint(localOnPlane)

        let resolvedAuthored = AuthoredPaintingRegion.resolveAuthoredRegion(localPoint: localOnPlane)
        if resolvedAuthored == nil {
            print(
                "[RegionFallback] no authored region matched localPt=\(localOnPlane) using background fallback"
            )
        }
        let authored = resolvedAuthored ?? AuthoredPaintingRegion.backgroundFallback
        let region = paintingRegion(for: authored)

        sceneState.currentLookTargetRegionId = region.id
        #if DEBUG
        logLookTargetIfChanged(regionId: region.id)
        logRegionCandidateIfChanged(region: region, localPoint: localOnPlane)
        #endif

        return region
    }

    private func regionForLocalPoint(_ localPoint: SIMD3<Float>) -> PaintingRegion? {
        let resolvedAuthored = AuthoredPaintingRegion.resolveAuthoredRegion(localPoint: localPoint)
        if resolvedAuthored == nil {
            print(
                "[RegionFallback] no authored region matched localPt=\(localPoint) using background fallback"
            )
        }
        let authored = resolvedAuthored ?? AuthoredPaintingRegion.backgroundFallback
        return paintingRegion(for: authored)
    }

    private func normalizedUVForPaintingPlaneLocalPoint(_ localPoint: SIMD3<Float>) -> (u: Float, v: Float) {
        let dims = PaintingCanvasEntity.canvasDimensions()
        let canvasW = dims.width
        let canvasH = dims.height
        let u = (localPoint.x / canvasW) + 0.5
        let v = (localPoint.z / canvasH) + 0.5
        return (min(1, max(0, u)), min(1, max(0, v)))
    }

    private func worldToLocal(_ entity: Entity, worldPosition: SIMD3<Float>) -> SIMD3<Float> {
        let m = entity.transformMatrix(relativeTo: nil)
        let inv = simd_inverse(m)
        let p = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1)
        let lp = inv * p
        return SIMD3<Float>(lp.x, lp.y, lp.z)
    }

    private func updateTapMarker(on entity: Entity, localPosition: (x: Float, y: Float, z: Float)) {
        lastTapMarker?.removeFromParent()

        let marker = ModelEntity(
            mesh: .generateSphere(radius: 0.012),
            materials: [SimpleMaterial(color: UIColor.systemRed, isMetallic: false)]
        )
        marker.name = "TapMarker"
        marker.position = SIMD3<Float>(localPosition.x, localPosition.y, localPosition.z)
        entity.addChild(marker)
        lastTapMarker = marker
    }

    private func findEntity(in root: Entity, named name: String) -> Entity? {
        if root.name == name { return root }
        for child in root.children {
            if let found = findEntity(in: child, named: name) {
                return found
            }
        }
        return nil
    }
}

#Preview(immersionStyle: .mixed) {
    GazeImmersiveViewV2()
        .environment(AppModel())
}

