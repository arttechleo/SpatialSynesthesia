//
//  GazeInteractionManager.swift
//
//  Tracks which painting region is currently "active" (looked at or tapped).
//  Drives the color filter overlay. On visionOS, active region is set by tap (and
//  optionally by gaze/focus when supported). Designed for real device testing.
//

/// Manages the currently focused/gazed region and its color category for overlay feedback.
/// Single source of truth for "which region is active" and "what filter to show".
import QuartzCore
import Foundation

#if DEBUG
/// Debug-only; does not affect release builds.
private func spatialSynesthesiaDebugLog(_ message: String) {
    print("[SpatialSynesthesia] \(message)")
}
#endif

/// Gate / dwell trace lines — stripped in release (no console flood).
#if DEBUG
private func gazeInteractionTraceLog(_ message: @autoclosure () -> String) {
    print(message())
}
#else
@inline(__always)
private func gazeInteractionTraceLog(_ message: @autoclosure () -> String) {}
#endif

@MainActor
final class GazeInteractionManager {
    // MARK: - Focus model (VisionOS gaze/dwell MVP)

    /// Focus-state model for dwell-driven activation.
    /// - Note: Tap can force transitions for debugging.
    enum FocusState {
        case noFocus
        case preFocus(PaintingRegion)
        case focused(PaintingRegion)
        case released
    }

    /// The region currently "focused" for audio/primary feedback.
    /// Nil means no active solo (ensemble at base).
    private(set) var activeRegion: PaintingRegion?

    /// Current focus state used by overlay visuals (secondary).
    private(set) var focusState: FocusState = .noFocus

    /// Incremented whenever the audio-active region changes.
    /// The view can use this to trigger audio crossfades.
    private(set) var audioMixVersion: UInt64 = 0

    #if DEBUG
    /// DEBUG-only: which path last bumped `audioMixVersion` (gaze dwell vs tap/explicit `setActiveRegion`).
    /// Used so Xcode logs can attribute `setAudioMix` to gaze without changing runtime behavior.
    enum DebugAudioMixBumpSource: Equatable {
        case gaze
        case tapOrExplicit
    }

    private(set) var debugLastAudioMixBumpSource: DebugAudioMixBumpSource = .tapOrExplicit
    #endif

    /// Current color category derived from `activeRegion`.
    /// Kept for backwards compatibility with the older `GazeImmersiveView`.
    var activeCategory: KandinskyColorCategory? {
        activeRegion?.colorCategory
    }

    // MARK: - Sampled-color override (texture-driven)

    enum ColorSource: String {
        case manualRegion = "manual_region"
        case sampledTexture = "sampled_texture"
    }

    private(set) var activeColorSource: ColorSource = .manualRegion
    private var sampledStableCategory: KandinskyColorCategory?
    private var sampledPendingCategory: KandinskyColorCategory?
    private var sampledPendingCount: Int = 0

    // Debug/diagnostics for sampled classification.
    private(set) var sampledStableConfidence: Float = 0
    private(set) var sampledLastProposedCategory: KandinskyColorCategory?
    private(set) var sampledLastConfidence: Float = 0
    private(set) var sampledLastHSV: HSVColor?
    private(set) var sampledIsTransitioning: Bool = false

    /// The category used for *responses* (audio, overlay, surroundings tint).
    /// In sampled mode, this is a stabilized sampled category; otherwise the region category.
    var responseCategory: KandinskyColorCategory? {
        switch activeColorSource {
        case .sampledTexture:
            return sampledStableCategory ?? activeRegion?.colorCategory
        case .manualRegion:
            return activeRegion?.colorCategory
        }
    }

    /// Opacity of the full-canvas overlay (tap fallback + debug).
    private(set) var overlayOpacity: Float = 0

    // MARK: - Dwell timing

    private let dwellDuration: CFTimeInterval = 0.55
    private let preFocusOverlayTargetOpacity: Float = 0.50

    private var preFocusStartTime: CFTimeInterval?
    private var preFocusRegionId: String?

    /// Short nil-candidate hold so one dropped gaze frame does not reset dwell / flip to `released`.
    private var nilGazeCandidateStreak: Int = 0
    private var lastHeldGazeCandidate: PaintingRegion?
    private let nilGazeReleaseHoldFrames: Int = 5

    /// Requires this many consecutive frames with a *different* gaze candidate before abandoning dwell on the current `preFocus` / `focused` region (reduces boundary flicker).
    private let dwellCandidateSwitchDebounceFrames: Int = 3
    private var dwellSwitchStreakRegionId: String?
    private var dwellSwitchStreakCount: Int = 0

    /// Last resolved gaze region id (stable string — never compare `PaintingRegion` value identity).
    private var gate1PreviousResolvedRegionId: String?

    // Optional debug override so a tap doesn't immediately get overwritten
    // by transient gaze-ray jitter for the next few frames.
    private var gazeOverrideUntil: CFTimeInterval?
    private let gazeOverrideDuration: CFTimeInterval = 0.9

    /// Opacity mapping used for material updates.
    /// A non-linear curve improves perceived legibility during the fade.
    var overlayOpacityForMaterial: Float {
        let t = overlayOpacity
        guard t > 0 else { return 0 }
        // Accelerate toward 1 as it approaches visible state.
        let mapped = 1 - powf(1 - t, 1.6)
        // Keep overlay strong enough to be unmistakable (legibility-first),
        // but still let the textured painting remain visible.
        let strengthCap: Float = 0.90
        return min(strengthCap, mapped)
    }

    private var overlayTargetOpacity: Float = 0
    private var overlayCategoryForFade: KandinskyColorCategory?

    /// Current color category for overlay rendering (derived from fade state).
    var overlayCategoryForRendering: KandinskyColorCategory? {
        overlayOpacity > 0.001 ? overlayCategoryForFade : nil
    }

    /// When true, debug prints are enabled (entity hit, local position, region name, category).
    var isDebugMode: Bool = true

    /// Overlay tuning: faster attack into a focused color, slightly smoother release out.
    private let overlayAttackFadeSpeed: Float = 14.0
    private let overlayReleaseFadeSpeed: Float = 9.0

    private var lastTickTime: CFTimeInterval?

    // Throttle overlay fade debug logs.
    private var lastOverlayDebugPrintTime: CFTimeInterval = 0
    private var lastPrintedOverlayOpacity: Float = -1

    #if DEBUG
    /// Snapshot for change-only debug logs (no per-frame spam).
    private var debugPrevFocusLabel: String = "noFocus"
    private var debugPrevActiveRegionId: String?
    private var debugPrevResponseCategory: KandinskyColorCategory?

    private func focusStateDebugLabel(_ state: FocusState) -> String {
        switch state {
        case .noFocus: return "noFocus"
        case .released: return "released"
        case .preFocus(let r): return "preFocus(\(r.name))"
        case .focused(let r): return "focused(\(r.name))"
        }
    }

    /// Call from `defer` at the end of gaze/tap handlers; logs only when focus, region, or response category changes.
    private func logDebugGazeAndStateIfChanged() {
        let curFocus = focusStateDebugLabel(focusState)
        if curFocus != debugPrevFocusLabel {
            spatialSynesthesiaDebugLog("[State] \(debugPrevFocusLabel) → \(curFocus)")
            debugPrevFocusLabel = curFocus
        }

        let regionId = activeRegion?.id
        let regionName = activeRegion?.name ?? "nil"
        let cat = responseCategory
        if regionId != debugPrevActiveRegionId || cat != debugPrevResponseCategory {
            let colorStr = cat?.rawValue ?? "nil"
            if activeColorSource == .sampledTexture, let h = sampledLastHSV {
                spatialSynesthesiaDebugLog(
                    "[Gaze] region=\(regionName) color=\(colorStr) hsv=(H:\(Int(h.h)), S:\(String(format: "%.2f", h.s)), V:\(String(format: "%.2f", h.v)))"
                )
            } else {
                spatialSynesthesiaDebugLog("[Gaze] region=\(regionName) color=\(colorStr)")
            }
            debugPrevActiveRegionId = regionId
            debugPrevResponseCategory = cat
        }
    }

    private var debugLastDwellLoggedElapsedBucket: Int = -1
    private var debugLastDwellLoggedRegionId: String?

    private func debugFocusColorLabel(for region: PaintingRegion) -> String {
        (responseCategory ?? region.colorCategory).rawValue
    }

    private func resetDwellDebugProgress() {
        debugLastDwellLoggedElapsedBucket = -1
        debugLastDwellLoggedRegionId = nil
    }

    private func logFocusAcquirePreFocus(region: PaintingRegion) {
        resetDwellDebugProgress()
        spatialSynesthesiaDebugLog("[FocusAcquire] state=preFocus region=\(region.id) color=\(debugFocusColorLabel(for: region))")
    }

    private func logFocusAcquireFocused(region: PaintingRegion) {
        resetDwellDebugProgress()
        spatialSynesthesiaDebugLog("[FocusAcquire] state=focused region=\(region.id) color=\(debugFocusColorLabel(for: region))")
    }

    private func logFocusLoseCandidateDropped(regionId: String, elapsed: CFTimeInterval) {
        spatialSynesthesiaDebugLog("[FocusLose] candidateDropped region=\(regionId) elapsed=\(String(format: "%.3f", elapsed))")
    }

    private func logFocusLoseReleased(region: PaintingRegion) {
        let c = (responseCategory ?? region.colorCategory).rawValue
        spatialSynesthesiaDebugLog("[FocusLose] released region=\(region.id) color=\(c)")
    }

    /// Meaningful dwell progress only: bucketed by 0.25s elapsed while staying on the same preFocus region.
    private func logDwellProgressIfMeaningful(regionId: String, elapsed: CFTimeInterval) {
        let bucket = Int(elapsed / 0.25)
        if debugLastDwellLoggedRegionId == regionId && debugLastDwellLoggedElapsedBucket == bucket {
            return
        }
        debugLastDwellLoggedRegionId = regionId
        debugLastDwellLoggedElapsedBucket = bucket
        spatialSynesthesiaDebugLog("[Dwell] region=\(regionId) elapsed=\(String(format: "%.3f", elapsed)) threshold=\(String(format: "%.3f", dwellDuration))")
    }
    #endif

    init() {}

    /// Call when the user taps or gaze targets an entity that maps to a region.
    /// - Parameters:
    ///   - region: The region that was hit (e.g. from entity name lookup).
    ///   - hitEntityName: Optional; logged in debug.
    ///   - localPosition: Optional local hit position; logged in debug.
    func setActiveRegion(
        _ region: PaintingRegion?,
        hitEntityName: String? = nil,
        localPosition: (x: Float, y: Float, z: Float)? = nil
    ) {
        #if DEBUG
        defer { logDebugGazeAndStateIfChanged() }
        #endif
        let now = CACurrentMediaTime()
        // `CACurrentMediaTime()` is `CFTimeInterval` (Double), so compute deadline via addition.
        gazeOverrideUntil = now + gazeOverrideDuration

        if let region {
            // Force focus immediately (tap debug).
            activeRegion = region
            focusState = .focused(region)
            preFocusStartTime = nil
            preFocusRegionId = nil

            overlayCategoryForFade = responseCategory ?? region.colorCategory
            overlayTargetOpacity = 1

            // Audio version bump.
            audioMixVersion += 1
            #if DEBUG
            debugLastAudioMixBumpSource = .tapOrExplicit
            #endif
        } else {
            // Force release immediately.
            let wasActive = activeRegion != nil
            activeRegion = nil
            focusState = .released
            preFocusStartTime = nil
            preFocusRegionId = nil

            sampledStableCategory = nil
            sampledPendingCategory = nil
            sampledPendingCount = 0
            overlayCategoryForFade = nil
            overlayTargetOpacity = 0

            if wasActive {
                audioMixVersion += 1
                #if DEBUG
                debugLastAudioMixBumpSource = .tapOrExplicit
                #endif
            }
        }
        if isDebugMode {
            if let region = region {
                print("[Gaze] entity: \(hitEntityName ?? "—")")
                if let pos = localPosition {
                    print("[Gaze] local hit position: x=\(pos.x), y=\(pos.y), z=\(pos.z)")
                }
                print("[Gaze] active region: \(region.name)")
                print("[Gaze] active color category: \(region.colorCategory.rawValue)")

                // Overlay diagnostics at the moment of activation.
                print("[Overlay] targetOpacity=\(overlayTargetOpacity)")
                print("[Overlay] currentOverlayOpacity=\(overlayOpacity)")
                print("[Overlay] mappedOverlayOpacityForMaterial=\(overlayOpacityForMaterial)")
                print("[Overlay] overlayCategoryForRendering=\(overlayCategoryForRendering?.rawValue ?? "nil")")
            } else {
                print("[Gaze] active region cleared")

                // Overlay diagnostics at the moment of deactivation.
                print("[Overlay] targetOpacity=\(overlayTargetOpacity)")
                print("[Overlay] currentOverlayOpacity=\(overlayOpacity)")
                print("[Overlay] mappedOverlayOpacityForMaterial=\(overlayOpacityForMaterial)")
                print("[Overlay] overlayCategoryForRendering=\(overlayCategoryForRendering?.rawValue ?? "nil")")
            }
        }
    }

    /// Clear the active region (e.g. gaze left the canvas). Overlay can fade out.
    func clearActiveRegion() {
        setActiveRegion(nil)
    }

    // MARK: - Dwell-driven focus entry (gaze MVP)

    private func focusLabelForDiagnostics(_ state: FocusState) -> String {
        switch state {
        case .noFocus: return "noFocus"
        case .released: return "released"
        case .preFocus(let r): return "preFocus(\(r.id))"
        case .focused(let r): return "focused(\(r.id))"
        }
    }

    private func printDwellCheck(region: PaintingRegion) {
        gazeInteractionTraceLog("[DwellCheck] threshold=\(dwellDuration) region=\(region.id)")
    }

    private func categoryLabelForGate1(from state: FocusState) -> String {
        switch state {
        case .preFocus(let r), .focused(let r):
            return r.colorCategory.rawValue
        case .released, .noFocus:
            return "none"
        }
    }

    /// Submit the current look candidate region (head ray → `PaintingPlane` hit → authored box + priority).
    /// The manager converts sustained presence into `preFocus` -> `focused`.
    func submitGazeCandidate(_ candidate: PaintingRegion?) {
        #if DEBUG
        defer { logDebugGazeAndStateIfChanged() }
        #endif
        // All KandinskyColorCategory values are valid gaze candidates — no category filtering.
        // All 9 authored regions must be interactive.

        // Ignore gaze updates briefly after a tap override.
        let now = CACurrentMediaTime()

        gazeInteractionTraceLog(
            "[Gate1-Candidate] category=\(candidate.map { "\($0.colorCategory)" } ?? "nil") region=\(candidate?.name ?? "nil")"
        )
        gazeInteractionTraceLog(
            "[CandidateIn] region=\(candidate?.id ?? "nil") category=\(candidate.map { $0.colorCategory.rawValue } ?? "none")"
        )

        if let until = gazeOverrideUntil, now < until {
            gazeInteractionTraceLog("[CandidateIn] skipped gazeOverrideActive=true")
            return
        }

        let resolved: PaintingRegion?
        if let candidate {
            nilGazeCandidateStreak = 0
            lastHeldGazeCandidate = candidate
            resolved = candidate
        } else {
            nilGazeCandidateStreak += 1
            if nilGazeCandidateStreak < nilGazeReleaseHoldFrames, let held = lastHeldGazeCandidate {
                resolved = held
            } else {
                resolved = nil
                if nilGazeCandidateStreak >= nilGazeReleaseHoldFrames {
                    lastHeldGazeCandidate = nil
                }
            }
        }

        // Release if gaze left the canvas (no candidate, hold window exhausted).
        guard let resolved else {
            if case .noFocus = focusState {
                nilGazeCandidateStreak = 0
                return
            }

            #if DEBUG
            let regionForReleaseLog: PaintingRegion? = {
                switch focusState {
                case .preFocus(let r), .focused(let r): return r
                case .released, .noFocus: return activeRegion
                }
            }()
            if let r = regionForReleaseLog {
                logFocusLoseReleased(region: r)
            }
            #endif

            let oldFS = focusState
            gazeInteractionTraceLog("[StateTransition] \(focusLabelForDiagnostics(focusState)) → released region=nil")
            gazeInteractionTraceLog(
                "[Gate1-Transition] \(focusLabelForDiagnostics(oldFS)) → released category=\(categoryLabelForGate1(from: oldFS))"
            )

            if activeRegion != nil {
                activeRegion = nil
                audioMixVersion += 1
                #if DEBUG
                debugLastAudioMixBumpSource = .gaze
                #endif
                if isDebugMode {
                    print("[Gaze] released (gaze left canvas); ensemble back to base")
                }
            }
            focusState = .released
            dwellSwitchStreakRegionId = nil
            dwellSwitchStreakCount = 0
            gate1PreviousResolvedRegionId = nil
            preFocusStartTime = nil
            preFocusRegionId = nil
            nilGazeCandidateStreak = 0

            overlayCategoryForFade = nil
            overlayTargetOpacity = 0
            return
        }

        if gate1PreviousResolvedRegionId != resolved.id {
            gazeInteractionTraceLog("[Gate1-DwellReset] new region=\(resolved.entityName)")
            gate1PreviousResolvedRegionId = resolved.id
        }

        if case .preFocus(let pr) = focusState, preFocusStartTime == nil {
            preFocusStartTime = now
            gazeInteractionTraceLog("[Gate1-DwellRepair] reseeded preFocusStartTime region=\(pr.entityName)")
        }

        switch focusState {
        case .noFocus:
            dwellSwitchStreakRegionId = nil
            dwellSwitchStreakCount = 0
            gazeInteractionTraceLog("[StateTransition] \(focusLabelForDiagnostics(focusState)) → preFocus region=\(resolved.id)")
            let oldNF = focusState
            focusState = .preFocus(resolved)
            gazeInteractionTraceLog(
                "[Gate1-Transition] \(focusLabelForDiagnostics(oldNF)) → \(focusLabelForDiagnostics(focusState)) category=\(resolved.colorCategory.rawValue)"
            )
            preFocusStartTime = now
            preFocusRegionId = resolved.id

            // Make audio react immediately in preFocus so the contrast is obvious.
            activeRegion = resolved
            audioMixVersion += 1
            #if DEBUG
            debugLastAudioMixBumpSource = .gaze
            #endif

            overlayCategoryForFade = responseCategory ?? resolved.colorCategory
            overlayTargetOpacity = preFocusOverlayTargetOpacity

            printDwellCheck(region: resolved)
            #if DEBUG
            logFocusAcquirePreFocus(region: resolved)
            #endif

        case .preFocus(let region):
            // Stable candidate: clear debounce streak.
            if region.id == resolved.id {
                dwellSwitchStreakRegionId = nil
                dwellSwitchStreakCount = 0
            }

            // Candidate changed while dwelling: only restart after debounce frames (boundary flicker).
            if region.id != resolved.id {
                if resolved.id != dwellSwitchStreakRegionId {
                    dwellSwitchStreakRegionId = resolved.id
                    dwellSwitchStreakCount = 1
                } else {
                    dwellSwitchStreakCount += 1
                }

                if dwellSwitchStreakCount < dwellCandidateSwitchDebounceFrames {
                    // Ignore transient candidate; keep dwelling on the locked region.
                    guard let start = preFocusStartTime else { return }
                    let elapsed = now - start
                    if now - start >= dwellDuration {
                        let oldPF = focusState
                        gazeInteractionTraceLog("[StateTransition] preFocus(\(region.id)) → focused(\(region.id)) region=\(region.id)")
                        focusState = .focused(region)
                        gazeInteractionTraceLog(
                            "[Gate1-Transition] \(focusLabelForDiagnostics(oldPF)) → \(focusLabelForDiagnostics(focusState)) category=\(region.colorCategory.rawValue)"
                        )
                        preFocusStartTime = nil
                        preFocusRegionId = nil
                        dwellSwitchStreakRegionId = nil
                        dwellSwitchStreakCount = 0

                        activeRegion = region
                        audioMixVersion += 1
                        #if DEBUG
                        debugLastAudioMixBumpSource = .gaze
                        logFocusAcquireFocused(region: region)
                        #endif
                        if isDebugMode {
                            print("[Gaze][Dwell] focused: region=\(region.name), category=\(region.colorCategory.rawValue)")
                        }

                        overlayCategoryForFade = responseCategory ?? region.colorCategory
                        overlayTargetOpacity = 1
                    } else {
                        gazeInteractionTraceLog(
                            "[Gate1-Dwell] elapsed=\(elapsed) threshold=\(dwellDuration) region=\(region.entityName) category=\(region.colorCategory.rawValue)"
                        )
                        #if DEBUG
                        logDwellProgressIfMeaningful(regionId: region.id, elapsed: elapsed)
                        #endif
                        overlayCategoryForFade = responseCategory ?? region.colorCategory
                        overlayTargetOpacity = preFocusOverlayTargetOpacity
                    }
                    return
                }

                dwellSwitchStreakRegionId = nil
                dwellSwitchStreakCount = 0
                #if DEBUG
                let elapsedDrop = preFocusStartTime.map { now - $0 } ?? 0
                logFocusLoseCandidateDropped(regionId: region.id, elapsed: elapsedDrop)
                #endif
                gazeInteractionTraceLog("[StateTransition] preFocus(\(region.id)) → preFocus(\(resolved.id)) region=\(resolved.id)")
                let oldPF2 = focusState
                focusState = .preFocus(resolved)
                gazeInteractionTraceLog(
                    "[Gate1-Transition] \(focusLabelForDiagnostics(oldPF2)) → \(focusLabelForDiagnostics(focusState)) category=\(resolved.colorCategory.rawValue)"
                )
                preFocusStartTime = now
                preFocusRegionId = resolved.id

                activeRegion = resolved
                audioMixVersion += 1
                #if DEBUG
                debugLastAudioMixBumpSource = .gaze
                #endif

                overlayCategoryForFade = responseCategory ?? resolved.colorCategory
                overlayTargetOpacity = preFocusOverlayTargetOpacity

                printDwellCheck(region: resolved)
                #if DEBUG
                logFocusAcquirePreFocus(region: resolved)
                #endif
                return
            }

            guard let start = preFocusStartTime else { return }
            let elapsedPre = now - start
            if now - start >= dwellDuration {
                let oldPF3 = focusState
                gazeInteractionTraceLog("[StateTransition] preFocus(\(resolved.id)) → focused(\(resolved.id)) region=\(resolved.id)")
                focusState = .focused(resolved)
                gazeInteractionTraceLog(
                    "[Gate1-Transition] \(focusLabelForDiagnostics(oldPF3)) → \(focusLabelForDiagnostics(focusState)) category=\(resolved.colorCategory.rawValue)"
                )
                preFocusStartTime = nil
                preFocusRegionId = nil

                activeRegion = resolved
                audioMixVersion += 1
                #if DEBUG
                debugLastAudioMixBumpSource = .gaze
                logFocusAcquireFocused(region: resolved)
                #endif
                if isDebugMode {
                    print("[Gaze][Dwell] focused: region=\(resolved.name), category=\(resolved.colorCategory.rawValue)")
                }

                overlayCategoryForFade = responseCategory ?? resolved.colorCategory
                overlayTargetOpacity = 1
            } else {
                gazeInteractionTraceLog(
                    "[Gate1-Dwell] elapsed=\(elapsedPre) threshold=\(dwellDuration) region=\(resolved.entityName) category=\(resolved.colorCategory.rawValue)"
                )
                #if DEBUG
                logDwellProgressIfMeaningful(regionId: resolved.id, elapsed: elapsedPre)
                #endif
                overlayCategoryForFade = responseCategory ?? resolved.colorCategory
                overlayTargetOpacity = preFocusOverlayTargetOpacity
            }

        case .focused(let region):
            if region.id == resolved.id {
                dwellSwitchStreakRegionId = nil
                dwellSwitchStreakCount = 0
                return
            }

            if resolved.id != dwellSwitchStreakRegionId {
                dwellSwitchStreakRegionId = resolved.id
                dwellSwitchStreakCount = 1
            } else {
                dwellSwitchStreakCount += 1
            }
            if dwellSwitchStreakCount < dwellCandidateSwitchDebounceFrames {
                return
            }
            dwellSwitchStreakRegionId = nil
            dwellSwitchStreakCount = 0

            // Candidate differs: enter preFocus, but keep audio active
            // on the new preFocus candidate so the user hears the change immediately.
            gazeInteractionTraceLog("[StateTransition] focused(\(region.id)) → preFocus(\(resolved.id)) region=\(resolved.id)")
            let oldF = focusState
            focusState = .preFocus(resolved)
            gazeInteractionTraceLog(
                "[Gate1-Transition] \(focusLabelForDiagnostics(oldF)) → \(focusLabelForDiagnostics(focusState)) category=\(resolved.colorCategory.rawValue)"
            )
            preFocusStartTime = now
            preFocusRegionId = resolved.id

            activeRegion = resolved
            audioMixVersion += 1
            #if DEBUG
            debugLastAudioMixBumpSource = .gaze
            #endif

            overlayCategoryForFade = responseCategory ?? resolved.colorCategory
            overlayTargetOpacity = preFocusOverlayTargetOpacity

            printDwellCheck(region: resolved)
            #if DEBUG
            logFocusAcquirePreFocus(region: resolved)
            #endif

        case .released:
            // After release, restart dwell.
            dwellSwitchStreakRegionId = nil
            dwellSwitchStreakCount = 0
            gazeInteractionTraceLog("[StateTransition] released → preFocus region=\(resolved.id)")
            let oldR = focusState
            focusState = .preFocus(resolved)
            gazeInteractionTraceLog(
                "[Gate1-Transition] \(focusLabelForDiagnostics(oldR)) → \(focusLabelForDiagnostics(focusState)) category=\(resolved.colorCategory.rawValue)"
            )
            preFocusStartTime = now
            preFocusRegionId = resolved.id

            activeRegion = resolved
            audioMixVersion += 1
            #if DEBUG
            debugLastAudioMixBumpSource = .gaze
            #endif

            overlayCategoryForFade = responseCategory ?? resolved.colorCategory
            overlayTargetOpacity = preFocusOverlayTargetOpacity

            printDwellCheck(region: resolved)
            #if DEBUG
            logFocusAcquirePreFocus(region: resolved)
            #endif
        }
    }

    /// Back-compat: submit a category without confidence.
    /// Prefer `submitSampledClassification(_:enabled:)` for perceptual stability.
    func submitSampledCategory(_ category: KandinskyColorCategory?, enabled: Bool) {
        guard enabled else {
            submitSampledClassification(nil, enabled: false)
            return
        }
        if let category {
            submitSampledClassification(
                ColorSoundMapper.KandinskyClassification(category: category, confidence: 0.55, hsv: HSVColor(h: 0, s: 0, v: 0)),
                enabled: true
            )
        }
    }

    private func areAdjacentHues(_ a: KandinskyColorCategory, _ b: KandinskyColorCategory) -> Bool {
        // Adjacent categories that commonly oscillate in painted gradients.
        switch (a, b) {
        case (.blue, .violet), (.violet, .blue):
            return true
        case (.red, .orange), (.orange, .red):
            return true
        case (.orange, .yellow), (.yellow, .orange):
            return true
        case (.yellow, .green), (.green, .yellow):
            return true
        default:
            return false
        }
    }

    /// Confidence-adaptive sampled classification update.
    /// - Fast switch when confidence is high.
    /// - Slower switch when confidence is low (prevents flicker on noise/gradients).
    /// - Extra stickiness for adjacent hue oscillation (blue↔violet, red↔orange, etc).
    func submitSampledClassification(_ c: ColorSoundMapper.KandinskyClassification?, enabled: Bool) {
        guard enabled else {
            submitSampledCategory(nil, enabled: false)
            return
        }
        activeColorSource = .sampledTexture

        guard let c else { return }
        sampledLastProposedCategory = c.category
        sampledLastConfidence = c.confidence
        sampledLastHSV = c.hsv

        // If confidence is extremely low, hold state.
        if c.confidence < 0.28 {
            sampledIsTransitioning = false
            return
        }

        if sampledStableCategory == nil {
            sampledStableCategory = c.category
            sampledStableConfidence = c.confidence
            sampledPendingCategory = nil
            sampledPendingCount = 0
            sampledIsTransitioning = false
            return
        }

        guard let stable = sampledStableCategory else { return }
        if c.category == stable {
            sampledStableConfidence = max(sampledStableConfidence * 0.85, c.confidence)
            sampledPendingCategory = nil
            sampledPendingCount = 0
            sampledIsTransitioning = false
            return
        }

        // Dynamic confirmation frames.
        var required: Int
        switch c.confidence {
        case 0.86...:
            required = 1
        case 0.72..<0.86:
            required = 2
        case 0.56..<0.72:
            required = 3
        default:
            required = 5
        }

        // If this is an adjacent hue oscillation and confidence isn't strongly higher than current, add stickiness.
        if areAdjacentHues(stable, c.category), c.confidence < (sampledStableConfidence + 0.12) {
            required += 1
        }

        // If stable confidence is still quite high and the new one isn't much higher, resist switching.
        if sampledStableConfidence >= 0.75, c.confidence < (sampledStableConfidence + 0.08) {
            required = max(required, 4)
        }

        if sampledPendingCategory == c.category {
            sampledPendingCount += 1
        } else {
            sampledPendingCategory = c.category
            sampledPendingCount = 1
        }

        sampledIsTransitioning = sampledPendingCount < required

        if sampledPendingCount >= required {
            sampledStableCategory = c.category
            sampledStableConfidence = c.confidence
            sampledPendingCategory = nil
            sampledPendingCount = 0
            sampledIsTransitioning = false
        }
    }

    /// Call once per frame from the immersive RealityView.
    ///
    /// Important: this intentionally does not rely on SwiftUI-observed state. The view
    /// should only call into this manager and then mutate RealityKit entities/materials.
    func tickOverlayFade() {
        let now = CACurrentMediaTime()
        let dtFloat: Float

        if let last = lastTickTime {
            dtFloat = Float(max(0, now - last))
        } else {
            // First tick: assume a small frame delta so the overlay responds immediately.
            dtFloat = 1.0 / 60.0
        }
        lastTickTime = now

        guard abs(overlayTargetOpacity - overlayOpacity) > 0.0001 else { return }

        // Smooth approach with asymmetric attack/release speeds for coherence.
        let speed = overlayTargetOpacity > overlayOpacity ? overlayAttackFadeSpeed : overlayReleaseFadeSpeed
        let blendFactor = min(1, speed * dtFloat)
        overlayOpacity = overlayOpacity + (overlayTargetOpacity - overlayOpacity) * blendFactor

        if overlayOpacity < 0.001, overlayTargetOpacity == 0 {
            overlayOpacity = 0
            overlayCategoryForFade = nil
        }

        // Debug: log fade updates (category + opacity/alpha) at a controlled cadence.
        guard isDebugMode else { return }
        let shouldPrintByTime = (now - lastOverlayDebugPrintTime) > 0.25
        let shouldPrintByDelta = abs(overlayOpacity - lastPrintedOverlayOpacity) > 0.05
        guard shouldPrintByTime || shouldPrintByDelta else { return }

        lastOverlayDebugPrintTime = now
        lastPrintedOverlayOpacity = overlayOpacity

        let mappedOpacity = overlayOpacityForMaterial
        let categoryName = overlayCategoryForRendering?.rawValue ?? "nil"
        let effectiveAlpha = overlayCategoryForRendering.map { $0.overlayAlpha * CGFloat(mappedOpacity) } ?? 0

        print(
            "[Overlay] fade update: overlayOpacity=\(String(format: "%.3f", overlayOpacity)), " +
            "mappedOpacity=\(String(format: "%.3f", mappedOpacity)), " +
            "category=\(categoryName), " +
            "effectiveAlpha=\(String(format: "%.3f", Float(effectiveAlpha)))"
        )
    }
}
