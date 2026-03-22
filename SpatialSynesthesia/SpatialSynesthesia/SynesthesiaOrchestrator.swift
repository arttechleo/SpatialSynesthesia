//
//  SynesthesiaOrchestrator.swift
//  SpatialSynesthesia
//
//  Drives the Chapter 1 visual experience: score-based grade + region highlights.
//

import RealityKit
import SwiftUI
import UIKit

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
    private let sequencer = BeatColorSequencer()

    private var highlightEntities: [String: RegionHighlightEntity] = [:]
    private var didSetupHighlights = false
    private var didLogRegionIds = false

    /// Dedupes `[Ch1-Pipeline]` logs on even integer seconds of elapsed time.
    private var lastScoreLogSecond: Int = -1

    /// Tracks which score keyframe segment we have entered (for rhythmic pulse on phrase boundaries).
    private var lastKeyframeIndex: Int = -1

    /// Throttles `[Ch1-Diagnostic]` logs to every 3 seconds.
    private var diagnosticTimer: Float = 0

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
        #if DEBUG
        let t = frames[highestIndex].time
        print("[Rhythm] keyframe crossed index=\(highestIndex) time=\(t)")
        #endif
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

    /// Weighted mix of `vividTintColor` channels from score-driven intensities (threshold 0.001).
    static func additiveColorMix(intensities: [KandinskyColorCategory: Float]) -> (
        r: Float,
        g: Float,
        b: Float,
        energy: Float,
        totalEnergy: Float
    ) {
        var r: Float = 0
        var g: Float = 0
        var b: Float = 0
        var weightSum: Float = 0
        for (cat, intensity) in intensities {
            guard intensity > 0.001 else { continue }
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, a: CGFloat = 0
            cat.vividTintColor.getRed(&cr, green: &cg, blue: &cb, alpha: &a)
            let w = intensity
            r += Float(cr) * w
            g += Float(cg) * w
            b += Float(cb) * w
            weightSum += w
        }
        guard weightSum > 1e-5 else {
            return (0, 0, 0, 0, 0)
        }
        r /= weightSum
        g /= weightSum
        b /= weightSum
        let totalEnergy = min(1.0, weightSum)
        return (r, g, b, totalEnergy, totalEnergy)
    }

    /// Call every frame from SceneEvents.Update when `isActive` is true.
    func update(
        elapsed: TimeInterval,
        deltaTime: Float,
        paintingRegions _: [AuthoredPaintingRegion],
        applyAdditivePassthroughGrade: @escaping (Float, Float, Float, Float, KandinskyColorCategory?) -> Void
    ) {
        guard isActive else { return }
        _ = audioManager

        let keyframeCrossed = detectKeyframeCrossing(elapsed: elapsed)
        if keyframeCrossed {
            analyzer.forceTransientOnNextUpdate = true
        }

        analyzer.updateFromScore(elapsed: elapsed, deltaTime: deltaTime)

        let elapsedTime = elapsed
        #if DEBUG
        if Int(elapsedTime) % 2 == 0 && Int(elapsedTime) != lastScoreLogSecond {
            lastScoreLogSecond = Int(elapsedTime)
            let top = analyzer.intensities
                .filter { $0.value > 0.01 }
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key):\(String(format: "%.2f", $0.value))" }
                .joined(separator: " ")
            print("[Ch1-Pipeline] elapsed=\(String(format: "%.1f", elapsedTime)) intensities=[\(top)]")
        }
        #endif

        var modulation: [KandinskyColorCategory: Float] = [:]
        for cat in KandinskyColorCategory.allCases {
            let raw = analyzer.intensities[cat] ?? 0.0
            modulation[cat] = raw * chapterBlend
        }

        updateHighlights(intensities: modulation, deltaTime: deltaTime, displayMode: regionHighlightDisplayMode)

        #if DEBUG
        diagnosticTimer += deltaTime
        if diagnosticTimer >= 3.0 {
            diagnosticTimer = 0
            let active = analyzer.intensities
                .filter { $0.value > 0.02 }
                .sorted { $0.value > $1.value }
                .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
                .joined(separator: " ")
            let mixed = Self.additiveColorMix(intensities: modulation)
            print("[Ch1-Diagnostic] elapsed=\(String(format: "%.1f", elapsedTime)) active=[\(active.isEmpty ? "NONE" : active)] energy=\(String(format: "%.3f", mixed.totalEnergy))")
        }
        #endif

        let mixed = Self.additiveColorMix(intensities: modulation)
        sequencer.update(deltaTime: deltaTime, musicalEnergy: mixed.totalEnergy)
        let seqRGB = sequencer.blendedRGB
        applyAdditivePassthroughGrade(
            seqRGB.r,
            seqRGB.g,
            seqRGB.b,
            max(mixed.totalEnergy, 0.25),
            analyzer.dominantCategory
        )
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

}
