//
//  StemAmplitudeAnalyzer.swift
//  SpatialSynesthesia
//
//  Reads stem amplitudes from AudioManager and produces per-category
//  modulation intensities. Bridge between music and vision.
//

import Foundation
import AVFoundation

/// Reads stem amplitudes from AudioManager and produces per-category
/// modulation intensities. This is the bridge between music and vision.
@MainActor
final class StemAmplitudeAnalyzer {

    // Smoothing: how fast modulation responds to amplitude changes (Chapter 2 / live stems).
    // Higher = more responsive. Lower = more gradual/organic.
    let attackSpeed: Float = 2.5   // fast attack (instrument enters)
    let liveStemReleaseSpeed: Float = 0.8   // slow release (instrument fades)

    // Minimum amplitude threshold to start modulating.
    // Prevents noise from silent/quiet stems.
    let silenceThreshold: Float = 0.02

    // MARK: - Chapter 1 score — rhythmic punch + sustain (named tuning constants)

    let transientAttackSpeed: Float = 12.0  // fast punch on new color / keyframe
    let sustainedAttackSpeed: Float = 2.5   // slow build within same dominant color
    let releaseSpeed: Float = 3.5           // moderately fast release (Chapter 1 score-driven)
    let categoryChangePunch: Float = 0.25   // minimum instant jump when dominant changes

    /// When true, next `updateFromScore` uses `transientAttackSpeed` for all rising edges, then resets.
    var forceTransientOnNextUpdate: Bool = false

    private var previousDominantCategory: KandinskyColorCategory?

    // Current smoothed modulation intensity per category.
    // These are the values that drive the visual system.
    private(set) var intensities: [KandinskyColorCategory: Float] = [:]

    // Internal smoothed values
    private var smoothed: [KandinskyColorCategory: Float] = [:]

    init() {
        for cat in KandinskyColorCategory.allCases {
            intensities[cat] = 0.0
            smoothed[cat] = 0.0
        }
    }

    /// Call this every frame from SceneEvents.Update.
    /// audioManager: the existing AudioManager instance.
    /// deltaTime: seconds since last frame.
    func update(audioManager: AudioManager, deltaTime: Float) {

        for cat in KandinskyColorCategory.allCases {

            // Get raw amplitude from the stem player for this category.
            let rawAmplitude = audioManager.currentStemAmplitude(for: cat)

            // Apply silence gate
            let gated = rawAmplitude < silenceThreshold ? Float(0) : rawAmplitude

            // Smooth with asymmetric attack/release
            let current = smoothed[cat] ?? 0.0
            let speed = gated > current ? attackSpeed : liveStemReleaseSpeed
            smoothed[cat] = current + (gated - current) * speed * deltaTime

            // Clamp to [0, 1]
            intensities[cat] = min(1.0, max(0.0, smoothed[cat] ?? 0.0))
        }
    }

    /// Chapter 1: uses the keyframed musical score instead of live stem amplitudes.
    func updateFromScore(elapsed: TimeInterval, deltaTime: Float) {

        let scoreProminences = Chapter1Score.prominences(at: elapsed)

        let newDominant = scoreProminences
            .filter { $0.value > 0.1 }
            .max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            })?.key

        let dominantChanged = newDominant != previousDominantCategory && newDominant != nil
        if dominantChanged, let nd = newDominant {
            print("[Rhythm] dominant changed → \(nd) elapsed=\(String(format: "%.1f", elapsed))")
        }

        let forceAllTransient = forceTransientOnNextUpdate
        if forceTransientOnNextUpdate {
            forceTransientOnNextUpdate = false
        }

        for cat in KandinskyColorCategory.allCases {
            let target = scoreProminences[cat] ?? 0.0
            let current = smoothed[cat] ?? 0.0

            let speed: Float
            if target > current {
                if forceAllTransient {
                    speed = transientAttackSpeed
                } else {
                    let isNewDominant = dominantChanged && cat == newDominant
                    speed = isNewDominant ? transientAttackSpeed : sustainedAttackSpeed
                }
            } else {
                speed = releaseSpeed
            }

            var next = current + (target - current) * speed * deltaTime

            if dominantChanged, cat == newDominant, next < categoryChangePunch {
                next = categoryChangePunch
            }

            smoothed[cat] = next
            intensities[cat] = min(1.0, max(0.0, next))
        }

        previousDominantCategory = newDominant
    }

    /// Returns a "musical moment" description for debug logging.
    var dominantCategory: KandinskyColorCategory? {
        intensities.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.rawValue < rhs.key.rawValue
        })?.key
    }
}
