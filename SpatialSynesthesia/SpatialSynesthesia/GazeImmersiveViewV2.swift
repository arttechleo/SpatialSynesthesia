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

    /// Throttles `[ColorGrade]` logging (update loop runs every frame).
    var lastColorGradePrintTime: CFTimeInterval = 0

    // MARK: - Chapter 2 passthrough release fade (gaze leaves region)
    var ch2ReleaseTimer: Float = 0
    var ch2ReleasingFromRegion: PaintingRegion? = nil
    /// Previous focus state for edge detection (tint / ColorMatch / stage logs).
    var ch2PreviousFocusState: GazeInteractionManager.FocusState? = nil
    var ch2LastStageLogKey: String = ""
    /// Throttles `[Ch2-HexGrade]` (update loop runs every frame while focused).
    var lastCh2HexGradeLogTime: CFTimeInterval = 0

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
    /// One-shot `[PaintingPlaneReady]` after intro.
    var debugLoggedPaintingPlaneReadiness: Bool = false
    #endif
}

struct GazeImmersiveViewV2: View {
    @Environment(AppModel.self) private var appModel

    @State private var gazeManager = GazeInteractionManager()
    @State private var sceneState = PaintingSceneStateV2()
    @StateObject private var chapterController = ChapterController()
    @State private var orchestrator: SynesthesiaOrchestrator?

    /// Fast fade to neutral when gaze leaves a focused region (Chapter 2 only).
    private let ch2ReleaseDuration: Float = 0.35

    // Primary, supported passthrough tint via SurroundingsEffect.
    @State private var preferredSurroundingsEffectValue: SurroundingsEffect? = nil

    var body: some View {
        RealityView { content in
            await setupScene(content: content)
        }
        .overlay(
            Color.black.opacity(chapterController.fadeOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    handleTap(value: value)
                }
        )
        .preferredSurroundingsEffect(preferredSurroundingsEffectValue)
        .onAppear {
            orchestrator = SynesthesiaOrchestrator(audioManager: AudioManager.shared)
            orchestrator?.isActive = true
            chapterController.begin()
            #if DEBUG
            AuthoredPaintingRegion.kandinskyComposition.forEach { r in
                print("[RegionMap] \(r.id) category=\(r.category) hex=\(r.hexColor)")
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    ColorMappingAudit.auditColorMappings()
                    Chapter1Score.auditScore()
                    ColorMappingAudit.auditRegionMappings()
                    diagnoseColorGrade()
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    Chapter2ColorAudit.generateMismatchReport()
                    Chapter2ColorAudit.testPaintingHexClassification()
                }
            }
            #endif
        }
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

        // Hide interactive canvas until intro shell completes (no change to immersion style / startup order).
        result.root.isEnabled = false

        // Ensemble + mix start is deferred until intro veil completes (see SceneEvents.Update).

        // Drive fade + overlay updates from RealityKit's per-frame SceneEvents.Update
        // rather than RealityView's SwiftUI-driven `update:` callback.
        sceneState.sceneUpdateSubscription?.cancel()
        sceneState.sceneUpdateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
            Task { @MainActor in
                sceneState.sceneFromUpdateLoop = event.scene

                let deltaTime = Float(event.deltaTime)
                chapterController.tick(deltaTime: TimeInterval(deltaTime))
                if chapterController.currentChapter == .transitioning {
                    chapterController.updateTransitionBlend(deltaTime: deltaTime)
                }

                if chapterController.isChapterOneActive {
                    if let plane = sceneState.paintingPlaneEntity {
                        orchestrator?.setupHighlightEntities(
                            regions: AuthoredPaintingRegion.kandinskyComposition,
                            paintingEntity: plane
                        )
                    }
                    orchestrator?.chapterBlend = chapterController.chapterOneBlend
                    orchestrator?.update(
                        elapsed: chapterController.chapterOneElapsed,
                        deltaTime: deltaTime,
                        paintingRegions: AuthoredPaintingRegion.kandinskyComposition,
                        applyAdditivePassthroughGrade: { r, g, b, energy, dominant in
                            self.applyChapterOneAdditivePassthroughGrade(
                                r: r, g: g, b: b, energy: energy, dominantFallback: dominant
                            )
                        }
                    )
                }

                // 0) Fade the intro veil independently from gaze/audio/region logic.
                let introJustCompleted = tickIntroVeil()

                #if DEBUG
                logPaintingPlaneReadinessOnce()
                #endif

                if introJustCompleted {
                    AudioManager.shared.isIntroAudioGated = false
                    sceneState.hasStartedExperienceAudio = true
                    AudioManager.shared.setAudioMix(
                        focusState: gazeManager.focusState,
                        category: gazeManager.responseCategory
                    )
                    sceneState.lastAppliedAudioMixVersion = gazeManager.audioMixVersion
                }

                chapterController.tickSignifier(deltaTime: deltaTime)
                if let signifierColor = chapterController.signifierEffect {
                    assignPreferredSurroundingsEffect(.colorMultiply(signifierColor))
                    return
                }

                // Chapter 1 orchestrator runs above; this guard only skips gaze/Chapter 2 work.
                guard chapterController.isChapterTwoInteractionLive else { return }

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

                // 2b) Broad world tint wash driven by the same focus state machine.
                updateWorldTintFromFocusState(deltaTime: deltaTime)

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
                #if DEBUG
                print("[GazeImmersiveViewV2] WorldTrackingProvider started for device-anchor gaze")
                #endif
            } catch {
                #if DEBUG
                print("[GazeDiag-1] WorldTrackingProvider run failed: \(error)")
                #endif
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

    // MARK: - Passthrough color grade (SurroundingsEffect — single entry point)

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

    #if DEBUG
    private func diagnoseColorGrade() {
        for cat in KandinskyColorCategory.allCases {
            let color = cat.vividTintColor
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let strength = CGFloat(cat.tintIntensity)
            let neutralR: CGFloat = 1.0
            let neutralG: CGFloat = 1.0
            let neutralB: CGFloat = 1.0
            let fR = neutralR + (r - neutralR) * strength
            let fG = neutralG + (g - neutralG) * strength
            let fB = neutralB + (b - neutralB) * strength
            print("[GradeDiag] \(cat) intensity=\(cat.tintIntensity) finalRGB=(\(String(format: "%.2f", fR)),\(String(format: "%.2f", fG)),\(String(format: "%.2f", fB)))")
        }
    }
    #endif

    /// Boosts a painting color to its vivid equivalent for passthrough (preserves hue).
    private func boostToVivid(r: Float, g: Float, b: Float) -> (r: Float, g: Float, b: Float) {
        let maxC = max(r, g, b)
        let minC = min(min(r, g), b)
        let delta = maxC - minC
        guard delta > 0.08 else { return (r, g, b) }
        let scale = 1.0 / maxC
        let boostedR = min(1.0, r * scale * 1.2)
        let boostedG = min(1.0, g * scale * 1.2)
        let boostedB = min(1.0, b * scale * 1.2)
        return (boostedR, boostedG, boostedB)
    }

    /// Diagnostic: log every write to `preferredSurroundingsEffect` (via `preferredSurroundingsEffectValue`).
    private func assignPreferredSurroundingsEffect(_ newValue: SurroundingsEffect?, file: StaticString = #file, line: UInt = #line) {
        #if DEBUG
        print("[EffectSet] \(file):\(line) value=\(String(describing: newValue))")
        #endif
        preferredSurroundingsEffectValue = newValue
    }

    /// Chapter 1: neutral-lerp `colorMultiply` from score-mixed vivid RGB (`SynesthesiaOrchestrator.additiveColorMix`).
    private func applyChapterOneAdditivePassthroughGrade(
        r: Float,
        g: Float,
        b: Float,
        energy: Float,
        dominantFallback: KandinskyColorCategory?
    ) {
        let minimumChapter1Strength: Float = 0.25
        let effectiveStrength = max(minimumChapter1Strength, min(1.0, energy * 1.2))

        let vivid = boostToVivid(r: r, g: g, b: b)
        let isNearNeutral = vivid.r > 0.85 && vivid.g > 0.85 && vivid.b > 0.85
        if isNearNeutral, let fallback = dominantFallback {
            let color = fallback.vividTintColor
            var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
            color.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
            let s = CGFloat(minimumChapter1Strength)
            let neutralR: CGFloat = 1.0
            let neutralG: CGFloat = 1.0
            let neutralB: CGFloat = 1.0
            let fR = neutralR + (fr - neutralR) * s
            let fG = neutralG + (fg - neutralG) * s
            let fB = neutralB + (fb - neutralB) * s
            assignPreferredSurroundingsEffect(
                .colorMultiply(
                    Color(
                        red: Double(max(0, min(1, fR))),
                        green: Double(max(0, min(1, fG))),
                        blue: Double(max(0, min(1, fB)))
                    )
                )
            )
            #if DEBUG
            print("[Ch1-Fallback] near-neutral detected, using \(fallback)")
            #endif
            return
        }

        let strength = CGFloat(effectiveStrength)
        let neutralR: CGFloat = 1.0
        let neutralG: CGFloat = 1.0
        let neutralB: CGFloat = 1.0
        let tr = CGFloat(vivid.r)
        let tg = CGFloat(vivid.g)
        let tb = CGFloat(vivid.b)
        let finalR = neutralR + (tr - neutralR) * strength
        let finalG = neutralG + (tg - neutralG) * strength
        let finalB = neutralB + (tb - neutralB) * strength

        #if DEBUG
        print("[Ch1-Apply] strength=\(String(format: "%.2f", strength)) final=(\(String(format: "%.2f", finalR)),\(String(format: "%.2f", finalG)),\(String(format: "%.2f", finalB)))")
        print("[Ch1-Apply] energy=\(String(format: "%.3f", energy)) r=\(String(format: "%.2f", r)) g=\(String(format: "%.2f", g)) b=\(String(format: "%.2f", b)) willSet=\(energy > 0.01)")
        #endif

        assignPreferredSurroundingsEffect(
            .colorMultiply(
                Color(
                    red: Double(max(0, min(1, finalR))),
                    green: Double(max(0, min(1, finalG))),
                    blue: Double(max(0, min(1, finalB)))
                )
            )
        )
    }

    /// Chapter 2 gaze path: vivid `colorMultiply` (boosted like Chapter 1; no animation).
    private func applyPassthroughColorGrade(
        category: KandinskyColorCategory,
        intensity: Float,
        ch2LogGradeDiagnostics: Bool = false
    ) {
        guard intensity > 0.01 else {
            assignPreferredSurroundingsEffect(nil)
            return
        }

        let strength = min(1.0, CGFloat(category.tintIntensity) * CGFloat(intensity) * 1.15)

        let rawColor = category.vividTintColor
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        rawColor.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        let vivid = boostToVivid(r: Float(rr), g: Float(rg), b: Float(rb))
        let r = CGFloat(vivid.r)
        let g = CGFloat(vivid.g)
        let b = CGFloat(vivid.b)

        #if DEBUG
        if ch2LogGradeDiagnostics {
            let fs = min(1.0, category.tintIntensity * intensity * 1.15)
            print(
                "[Ch2-Grade] category=\(category) intensity=\(intensity) tintIntensity=\(category.tintIntensity) finalStrength=\(fs)"
            )
        }
        #endif

        let finalR = 1.0 + (r - 1.0) * strength
        let finalG = 1.0 + (g - 1.0) * strength
        let finalB = 1.0 + (b - 1.0) * strength

        let gradeColor = Color(
            red: Double(max(0, min(1, finalR))),
            green: Double(max(0, min(1, finalG))),
            blue: Double(max(0, min(1, finalB)))
        )

        assignPreferredSurroundingsEffect(.colorMultiply(gradeColor))

        let now = Date.timeIntervalSinceReferenceDate
        if now - sceneState.lastColorGradePrintTime > 1.0 {
            sceneState.lastColorGradePrintTime = now
            #if DEBUG
            print("[ColorGrade] cat=\(category) strength=\(String(format: "%.2f", intensity))")
            print(
                "[ColorGrade] dbg rgb=(\(String(format: "%.2f", finalR)),\(String(format: "%.2f", finalG)),\(String(format: "%.2f", finalB))) " +
                "materialStrength=\(String(format: "%.2f", strength))"
            )
            #endif
        }
    }
    /// Chapter 2: passthrough grade from the region's authored painting hex (boosted), not category→vivid alone.
    private func applyChapter2GradeFromRegion(_ region: PaintingRegion, intensity: Float) {
        guard intensity > 0.01 else {
            assignPreferredSurroundingsEffect(nil)
            return
        }

        let hex = region.hexColor
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }

        let rgb: (r: Float, g: Float, b: Float)
        if s.count == 6, let val = UInt64(s, radix: 16) {
            rgb = (
                r: Float((val >> 16) & 0xFF) / 255.0,
                g: Float((val >> 8) & 0xFF) / 255.0,
                b: Float(val & 0xFF) / 255.0
            )
        } else {
            applyPassthroughColorGrade(
                category: region.colorCategory,
                intensity: intensity,
                ch2LogGradeDiagnostics: false
            )
            return
        }

        let vivid = boostToVivid(r: rgb.r, g: rgb.g, b: rgb.b)
        let maxC = max(vivid.r, vivid.g, vivid.b)
        let minC = min(min(vivid.r, vivid.g), vivid.b)
        let saturation = maxC > 0 ? (maxC - minC) / maxC : 0

        let finalR: Float
        let finalG: Float
        let finalB: Float

        if saturation < 0.25 {
            let catColor = region.colorCategory.vividTintColor
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
            catColor.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
            finalR = Float(cr)
            finalG = Float(cg)
            finalB = Float(cb)
        } else {
            finalR = vivid.r
            finalG = vivid.g
            finalB = vivid.b
        }

        let strength = min(
            1.0,
            Float(region.colorCategory.tintIntensity) * intensity * 1.15
        )
        let sc = CGFloat(strength)

        let gradedR = 1.0 + (CGFloat(finalR) - 1.0) * sc
        let gradedG = 1.0 + (CGFloat(finalG) - 1.0) * sc
        let gradedB = 1.0 + (CGFloat(finalB) - 1.0) * sc

        assignPreferredSurroundingsEffect(
            .colorMultiply(
                Color(
                    red: Double(max(0, min(1, gradedR))),
                    green: Double(max(0, min(1, gradedG))),
                    blue: Double(max(0, min(1, gradedB)))
                )
            )
        )

        let nowHex = Date.timeIntervalSinceReferenceDate
        if nowHex - sceneState.lastCh2HexGradeLogTime > 0.35 {
            sceneState.lastCh2HexGradeLogTime = nowHex
            print(
                "[Ch2-HexGrade] region=\(region.id) hex=\(hex) vivid=(\(String(format: "%.2f", finalR)),\(String(format: "%.2f", finalG)),\(String(format: "%.2f", finalB))) strength=\(String(format: "%.2f", strength))"
            )
        }
    }


    private func ch2FocusStateLogKey(_ state: GazeInteractionManager.FocusState) -> String {
        switch state {
        case .noFocus: return "noFocus"
        case .released: return "released"
        case .preFocus(let r): return "preFocus:\(r.id)"
        case .focused(let r): return "focused:\(r.id)"
        }
    }

    private func ch2LogStageLineIfChanged(_ key: String, _ emit: () -> Void) {
        if key != sceneState.ch2LastStageLogKey {
            sceneState.ch2LastStageLogKey = key
            emit()
        }
    }

    private func updateWorldTintFromFocusState(deltaTime: Float) {
        guard let wash = sceneState.worldTintWashEntity else { return }

        ColorFilterOverlay.updateOverlay(wash, color: .clear)

        let fs = gazeManager.focusState
        let prev = sceneState.ch2PreviousFocusState

        // Leaving focused for idle: begin fast release fade
        if case .focused(let oldRegion) = prev {
            switch fs {
            case .noFocus, .released:
                sceneState.ch2ReleasingFromRegion = oldRegion
                sceneState.ch2ReleaseTimer = 0
            default:
                break
            }
        }

        // Focused → different region (no idle): cancel release, no cross-fade between regions
        switch fs {
        case .preFocus(let rNew):
            if case .focused(let old)? = prev, old.id != rNew.id {
                sceneState.ch2ReleasingFromRegion = nil
                sceneState.ch2ReleaseTimer = 0
            }
        case .focused(let rNew):
            if case .focused(let old)? = prev, old.id != rNew.id {
                sceneState.ch2ReleasingFromRegion = nil
                sceneState.ch2ReleaseTimer = 0
            }
        default:
            break
        }

        // Dwelling again — cancel release fade
        switch fs {
        case .preFocus, .focused:
            sceneState.ch2ReleasingFromRegion = nil
            sceneState.ch2ReleaseTimer = 0
        default:
            break
        }

        // Release fade (only time-based transition in Chapter 2)
        if let releasingRegion = sceneState.ch2ReleasingFromRegion {
            sceneState.ch2ReleaseTimer += deltaTime
            let t = min(1.0, sceneState.ch2ReleaseTimer / ch2ReleaseDuration)
            let remainingIntensity = 1.0 - t
            if remainingIntensity > 0.01 {
                applyChapter2GradeFromRegion(releasingRegion, intensity: remainingIntensity)
            } else {
                assignPreferredSurroundingsEffect(nil)
                sceneState.ch2ReleasingFromRegion = nil
                sceneState.ch2ReleaseTimer = 0
                print("[Ch2-Stage] RELEASED fade complete")
            }
            sceneState.ch2PreviousFocusState = fs
            return
        }

        // Color match when focus is newly acquired (dwell complete or region switch)
        if case .focused(let region) = fs {
            let shouldLogMatch: Bool
            switch prev {
            case .none:
                shouldLogMatch = true
            case .some(.noFocus), .some(.released):
                shouldLogMatch = true
            case .some(.preFocus(let r)):
                shouldLogMatch = r.id == region.id
            case .some(.focused(let r)):
                shouldLogMatch = r.id != region.id
            }
            if shouldLogMatch {
                print(
                    "[Ch2-ColorMatch] region=\(region.id) category=\(region.colorCategory) hex=\(region.hexColor) overlayWillBe=\(region.colorCategory.vividTintColor)"
                )
            }
        }

        switch fs {
        case .noFocus, .released:
            assignPreferredSurroundingsEffect(nil)
            ch2LogStageLineIfChanged("NEUTRAL:\(ch2FocusStateLogKey(fs))") {
                print("[Ch2-Stage] NEUTRAL")
            }
        case .preFocus(let region):
            applyChapter2GradeFromRegion(region, intensity: 0.35)
            ch2LogStageLineIfChanged("PREFOCUS:\(region.id)") {
                print("[Ch2-Stage] PREFOCUS category=\(region.colorCategory) strength=0.35")
            }
        case .focused(let region):
            applyChapter2GradeFromRegion(region, intensity: 1.0)
            #if DEBUG
            let gradeFS = min(1.0, region.colorCategory.tintIntensity * 1.0 * 1.15)
            print(
                "[Ch2-Grade] category=\(region.colorCategory) intensity=1.0 tintIntensity=\(region.colorCategory.tintIntensity) finalStrength=\(gradeFS)"
            )
            #endif
            ch2LogStageLineIfChanged("FOCUSED:\(region.id)") {
                print("[Ch2-Stage] FOCUSED category=\(region.colorCategory) strength=1.0")
            }
        }

        sceneState.ch2PreviousFocusState = fs
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
            gazeRayDebugLog("[GazeDiag-1] DeviceAnchor unavailable")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        guard worldTrackingProvider.state == .running else {
            gazeRayDebugLog("[GazeDiag-1] WorldTrackingProvider not running: \(worldTrackingProvider.state)")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let time = CACurrentMediaTime()
        guard let deviceAnchor = worldTrackingProvider.queryDeviceAnchor(atTimestamp: time) else {
            gazeRayDebugLog("[GazeDiag-2] HeadAnchor unavailable")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        guard let painting = sceneState.paintingPlaneEntity else {
            gazeRayDebugLog("[GazeDiag-3] paintingEntity is nil")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let worldTransform = painting.transformMatrix(relativeTo: nil)
        guard worldTransform != matrix_identity_float4x4 else {
            gazeRayDebugLog("[GazeDiag-4] painting world transform is identity or invalid")
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
        gazeRayDebugLog("[GazeDiag-5] ray origin built: \(rayOrigin), dir: \(rayDir)")

        // `generatePlane(width:depth:)` lies in XZ; face normal is local +Y → world column 1.
        let col1 = worldTransform.columns.1
        var planeNormal = normalize(SIMD3<Float>(col1.x, col1.y, col1.z))
        guard simd_length(planeNormal) > 1e-6 else {
            gazeRayDebugLog("[GazeDiag-4] painting world transform is identity or invalid")
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
        gazeRayDebugLog("[GazeDiag-6] plane normal: \(planeNormal), planePoint: \(planePoint)")

        let denom = dot(planeNormal, rayDir)
        guard abs(denom) > 1e-6 else {
            gazeRayDebugLog("[GazeDiag-7] denom near zero = \(denom), ray parallel to plane")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let t = dot(planeNormal, planePoint - rayOrigin) / denom
        guard t > 0 else {
            gazeRayDebugLog("[GazeDiag-8] t value negative = \(t), intersection behind origin")
            #if DEBUG
            sceneState.debugLastGazeLocalSource = "none"
            #endif
            return nil
        }

        let worldHit = rayOrigin + rayDir * t
        gazeRayDebugLog("[GazeDiag-9] worldHit computed: \(worldHit)")

        let worldHit4 = SIMD4<Float>(worldHit.x, worldHit.y, worldHit.z, 1.0)
        let localHit4 = simd_mul(simd_inverse(worldTransform), worldHit4)

        // Mesh local ↔ authored logical space (see `PaintingPlaneCoordinateSpace`).
        let remappedLocal = PaintingPlaneCoordinateSpace.meshLocalPointToAuthored(
            SIMD3<Float>(localHit4.x, localHit4.y, localHit4.z)
        )

        gazeRayDebugLog("[LocalSpaceCheck] paintingScale=\(painting.scale(relativeTo: nil)) localRaw=(\(localHit4.x), \(localHit4.y), \(localHit4.z))")
        gazeRayDebugLog("[GazeDiag-10] localHit computed: \(remappedLocal)")

        if let firstRegion = AuthoredPaintingRegion.kandinskyComposition.first {
            gazeRayDebugLog("[RegionBoundsCheck] firstRegion center=\(firstRegion.localCenter) size=\(firstRegion.localSize)")
        }
        if AuthoredPaintingRegion.resolveAuthoredRegion(localPoint: remappedLocal) == nil {
            AuthoredPaintingRegion.kandinskyComposition.forEach {
                gazeRayDebugLog("[RegionDump] \($0.category) center=\($0.localCenter) size=\($0.localSize)")
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

        gazeRayDebugLog("[LocalPointSuccess] source=ray local=\(remappedLocal)")
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
            gazeRayDebugLog(
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
            gazeRayDebugLog(
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

#if DEBUG
fileprivate func gazeRayDebugLog(_ message: @autoclosure () -> String) {
    print(message())
}
#else
@inline(__always)
fileprivate func gazeRayDebugLog(_ message: @autoclosure () -> String) {}
#endif

#Preview(immersionStyle: .mixed) {
    GazeImmersiveViewV2()
        .environment(AppModel())
}

