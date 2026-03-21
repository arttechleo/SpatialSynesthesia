//
//  SynesthesiaOrchestrator.swift
//  SpatialSynesthesia
//
//  Drives the Chapter 1 visual experience: score-based grade + region highlights.
//

import RealityKit
import SwiftUI

/// How optional Chapter 1 region highlight meshes behave (thin emissive boxes on the painting plane).
/// Passthrough color grading is unchanged for all modes.
enum RegionHighlightDisplayMode: Equatable {
    /// No region meshes (default): clean easel + artwork + grade only.
    case off
    /// Only the **primary** authored region for the **dominant** score category lights up (one box, tied to the symphony).
    case followDominantCategory
    /// Every authored zone (except background); approximate shapes — still may not match brush strokes in the texture.
    case allAuthoredZones
}

/// Drives the Chapter 1 visual experience.
/// Score-driven passthrough color grade and per-region emissive highlights.
@MainActor
final class SynesthesiaOrchestrator {

    let maxBrightnessBoost: Float = 0.12
    let maxSaturationBoost: Float = 0.18
    let maxTemperatureShift: Float = 0.06

    var isActive: Bool = false
    var chapterBlend: Float = 1.0

    /// Optional emissive region meshes on the painting (see `RegionHighlightDisplayMode`).
    var regionHighlightDisplayMode: RegionHighlightDisplayMode = .off

    /// Backward-compatible alias: when `false`, highlights are off.
    var regionHighlightMeshesEnabled: Bool {
        get { regionHighlightDisplayMode != .off }
        set { regionHighlightDisplayMode = newValue ? .allAuthoredZones : .off }
    }

    private weak var audioManager: AudioManager?
    private let analyzer = StemAmplitudeAnalyzer()

    private var highlightEntities: [String: RegionHighlightEntity] = [:]
    private var didSetupHighlights = false
    private var didLogRegionIds = false

    private var lastScoreLogTime: TimeInterval = 0
    private var lastCh1GradeLogTime: TimeInterval = 0

    /// Tracks which score keyframe segment we have entered (for rhythmic pulse on phrase boundaries).
    private var lastKeyframeIndex: Int = -1

    init(audioManager: AudioManager) {
        self.audioManager = audioManager
    }

    /// Returns true once when `elapsed` advances into a new keyframe segment (Chapter 1 score).
    func detectKeyframeCrossing(elapsed: TimeInterval) -> Bool {
        let frames = Chapter1Score.keyframes
        var highestIndex = -1
        for i in frames.indices where elapsed >= frames[i].time {
            highestIndex = i
        }
        guard highestIndex > lastKeyframeIndex else { return false }
        lastKeyframeIndex = highestIndex
        let t = frames[highestIndex].time
        print("[Rhythm] keyframe crossed index=\(highestIndex) time=\(t)")
        return true
    }

    /// Call once the `PaintingPlane` entity exists (mesh-local space; highlights use `PaintingPlaneCoordinateSpace`).
    func setupHighlightEntities(regions: [AuthoredPaintingRegion], paintingEntity: Entity) {
        guard !didSetupHighlights else { return }
        didSetupHighlights = true

        guard regionHighlightDisplayMode != .off else {
            #if DEBUG
            print("[Ch1-Highlights] region highlight meshes disabled (clean painting surface)")
            #endif
            return
        }

        if !didLogRegionIds {
            didLogRegionIds = true
            #if DEBUG
            AuthoredPaintingRegion.kandinskyComposition.forEach {
                print("[RegionId] \($0.id) category=\($0.category)")
            }
            #endif
        }

        let primaryIds = Set(
            KandinskyColorCategory.allCases.compactMap { Chapter1Score.primaryAuthoredRegionId(for: $0) }
        )

        for region in regions {
            guard region.id != "authored_background",
                  region.id != "authored_background_fallback" else { continue }

            if regionHighlightDisplayMode == .followDominantCategory {
                guard primaryIds.contains(region.id) else { continue }
            }

            let highlight = RegionHighlightEntity(region: region, paintingEntity: paintingEntity)
            highlightEntities[region.id] = highlight
        }
        #if DEBUG
        print(
            "[Ch1-Highlights] mode=\(regionHighlightDisplayMode) created \(highlightEntities.count) region highlights"
        )
        #endif
    }

    /// Severance-style: one dominant color owns the room; optional secondary at reduced weight.
    /// Tie-break uses `rawValue` so `.yellow` / `.blue` do not win arbitrarily from enum order.
    func applyDominantColorGrade(
        intensities: [KandinskyColorCategory: Float],
        applyGrade: (KandinskyColorCategory, Float) -> Void
    ) {
        let sorted = intensities
            .filter { $0.value > 0.05 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            }

        guard let dominant = sorted.first else {
            // Clear passthrough — category unused at intensity 0; `.gray` avoids vivid default bias.
            applyGrade(.gray, 0.0)
            return
        }

        if let secondary = sorted.dropFirst().first {
            let secondaryContribution = secondary.value * 0.30
            let blendedCategory = dominant.value > secondaryContribution
                ? dominant.key
                : secondary.key
            let blendedIntensity = min(1.0, dominant.value + secondaryContribution * 0.3)
            applyGrade(blendedCategory, blendedIntensity)
        } else {
            applyGrade(dominant.key, dominant.value)
        }

        let now = Date().timeIntervalSinceReferenceDate
        if now - lastCh1GradeLogTime > 2.0 {
            lastCh1GradeLogTime = now
            #if DEBUG
            print("[Ch1-Grade] dominant=\(dominant.key) intensity=\(String(format: "%.2f", dominant.value))")
            #endif
        }
    }

    /// Call every frame from SceneEvents.Update when `isActive` is true.
    func update(
        elapsed: TimeInterval,
        deltaTime: Float,
        paintingRegions _: [AuthoredPaintingRegion],
        applyColorGrade: (KandinskyColorCategory, Float) -> Void
    ) {
        guard isActive else { return }
        _ = audioManager

        let keyframeCrossed = detectKeyframeCrossing(elapsed: elapsed)
        if keyframeCrossed {
            analyzer.forceTransientOnNextUpdate = true
        }

        analyzer.updateFromScore(elapsed: elapsed, deltaTime: deltaTime)

        var modulation: [KandinskyColorCategory: Float] = [:]
        for cat in KandinskyColorCategory.allCases {
            let raw = analyzer.intensities[cat] ?? 0.0
            modulation[cat] = raw * chapterBlend
        }

        updateHighlights(intensities: modulation, deltaTime: deltaTime, displayMode: regionHighlightDisplayMode)

        logScoreIfNeeded(elapsed: elapsed)

        applyDominantColorGrade(intensities: modulation, applyGrade: applyColorGrade)
    }

    func modulationColor(for region: AuthoredPaintingRegion,
                         intensities: [KandinskyColorCategory: Float]) -> (
        brightnessBoost: Float,
        saturationBoost: Float,
        hueShift: Float
    ) {
        let intensity = intensities[region.category] ?? 0.0
        let breathe = sin(intensity * .pi * 0.5)
        let brightness = breathe * maxBrightnessBoost
        let saturation = breathe * maxSaturationBoost
        let hueShift = breathe * maxTemperatureShift
        return (brightness, saturation, hueShift)
    }

    private func updateHighlights(
        intensities: [KandinskyColorCategory: Float],
        deltaTime: Float,
        displayMode: RegionHighlightDisplayMode
    ) {
        let dominant = intensities
            .filter { $0.value > 0.05 }
            .max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            })

        let dominantPrimaryId: String? = {
            guard let cat = dominant?.key else { return nil }
            return Chapter1Score.primaryAuthoredRegionId(for: cat)
        }()

        for (_, highlight) in highlightEntities {
            var base = baseHighlightTarget(
                region: highlight.region,
                intensities: intensities
            )
            if displayMode == .followDominantCategory {
                if let pid = dominantPrimaryId {
                    base = highlight.region.id == pid ? base : 0
                } else {
                    base = 0
                }
            }
            highlight.updateWithBreathing(
                baseIntensity: base,
                deltaTime: deltaTime,
                breathStrength: 0.20
            )
        }
    }

    /// Primary regions get full score; secondary same-category regions get a softer share.
    private func baseHighlightTarget(
        region: AuthoredPaintingRegion,
        intensities: [KandinskyColorCategory: Float]
    ) -> Float {
        let base = intensities[region.category] ?? 0
        guard base > 0.001 else { return 0 }

        if let primaryId = Chapter1Score.primaryAuthoredRegionId(for: region.category) {
            if region.id == primaryId {
                return base
            }
            return base * 0.4
        }
        return base * 0.5
    }

    private func logScoreIfNeeded(elapsed: TimeInterval) {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastScoreLogTime > 2.0 else { return }
        lastScoreLogTime = now
        #if DEBUG
        if let dominant = analyzer.dominantCategory {
            let intensity = analyzer.intensities[dominant] ?? 0
            print("[Ch1-Score] elapsed=\(String(format: "%.1f", elapsed)) dominant=\(dominant) intensity=\(String(format: "%.2f", intensity))")
        }
        #endif
    }
}
