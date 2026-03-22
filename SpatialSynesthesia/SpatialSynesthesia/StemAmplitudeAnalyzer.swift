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

    let attackSpeed: Float = 2.5
    let liveStemReleaseSpeed: Float = 0.8
    let silenceThreshold: Float = 0.02

    let transientAttackSpeed: Float = 18.0
    let sustainedAttackSpeed: Float = 4.0
    let releaseSpeed: Float = 5.0
    let categoryChangePunch: Float = 0.35
    let minimumActiveEnergy: Float = 0.15
    let minimumDominantDuration: Float = 1.2

    var forceTransientOnNextUpdate: Bool = false

    private var previousDominantCategory: KandinskyColorCategory?
    private var lockedDominantCategory: KandinskyColorCategory?
    /// Accumulates only while score wants a different dominant than `lockedDominantCategory`.
    private var dominantHeldTime: Float = 0

    private(set) var intensities: [KandinskyColorCategory: Float] = [:]
    private var smoothed: [KandinskyColorCategory: Float] = [:]

    init() {
        for cat in KandinskyColorCategory.allCases {
            intensities[cat] = 0.0
            smoothed[cat] = 0.0
        }
    }

    func update(audioManager: AudioManager, deltaTime: Float) {
        for cat in KandinskyColorCategory.allCases {
            let rawAmplitude = audioManager.currentStemAmplitude(for: cat)
            let gated = rawAmplitude < silenceThreshold ? Float(0) : rawAmplitude
            let current = smoothed[cat] ?? 0.0
            let speed = gated > current ? attackSpeed : liveStemReleaseSpeed
            smoothed[cat] = current + (gated - current) * speed * deltaTime
            intensities[cat] = min(1.0, max(0.0, smoothed[cat] ?? 0.0))
        }
    }

    func updateFromScore(elapsed: TimeInterval, deltaTime: Float) {
        let scoreProminences = Chapter1Score.prominences(at: elapsed)

        let scoreDominant = scoreProminences
            .filter { $0.value > 0.1 }
            .max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.rawValue < rhs.key.rawValue
            })?.key

        var acceptedDominantChange = false

        if let sd = scoreDominant {
            if let locked = lockedDominantCategory {
                if sd == locked {
                    dominantHeldTime = 0
                } else {
                    dominantHeldTime += deltaTime
                    if dominantHeldTime >= minimumDominantDuration {
                        lockedDominantCategory = sd
                        dominantHeldTime = 0
                        acceptedDominantChange = true
                        forceTransientOnNextUpdate = true
                        print("[Rhythm] dominant → \(sd) at \(String(format: "%.1f", elapsed))s")
                    }
                }
            } else {
                lockedDominantCategory = sd
                dominantHeldTime = 0
                acceptedDominantChange = true
                forceTransientOnNextUpdate = true
                print("[Rhythm] dominant → \(sd) at \(String(format: "%.1f", elapsed))s")
            }
        }

        let dominantChanged = acceptedDominantChange
        if dominantChanged, let nd = lockedDominantCategory {
            previousDominantCategory = nd
        }

        let forceAllTransient = forceTransientOnNextUpdate
        if forceTransientOnNextUpdate {
            forceTransientOnNextUpdate = false
        }

        let newDominant = scoreDominant

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

        let hasActiveScore = scoreProminences.values.contains { $0 > 0.3 }
        if hasActiveScore {
            if let top = intensities.max(by: { $0.value < $1.value }), top.value < minimumActiveEnergy {
                intensities[top.key] = minimumActiveEnergy
                smoothed[top.key] = minimumActiveEnergy
            }
        }
    }

    var dominantCategory: KandinskyColorCategory? {
        intensities.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.rawValue < rhs.key.rawValue
        })?.key
    }
}
