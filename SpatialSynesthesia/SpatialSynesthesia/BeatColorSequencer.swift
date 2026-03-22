//
//  BeatColorSequencer.swift
//  SpatialSynesthesia
//
//  Cycles through painting palette colors in musical time (Chapter 1).
//

import Foundation

/// Cycles through painting palette colors in musical time.
/// Driven by elapsed time and musical energy from the score.
@MainActor
final class BeatColorSequencer {

    let baseColorHoldDuration: Float = 1.8
    let minimumColorHoldDuration: Float = 0.4
    let transitionDuration: Float = 0.25

    /// Minimum sum of channel deltas required before accepting the next palette color.
    let minimumColorDistance: Float = 0.30

    private(set) var currentRGB: (r: Float, g: Float, b: Float) = (0.5, 0.5, 0.5)
    private(set) var nextRGB: (r: Float, g: Float, b: Float) = (0.5, 0.5, 0.5)
    private(set) var blendFactor: Float = 0.0

    private var heldTime: Float = 0
    private var inTransition: Bool = false
    private var transitionTime: Float = 0
    private var paletteIndex: Int = 0
    private(set) var lastEnergy: Float = 0

    private let palette = Chapter1Score.paintingPalette

    private var visiblePalette: [(r: Float, g: Float, b: Float)] {
        palette.compactMap { entry in
            let rgb = Chapter1Score.rgbFromHex(entry.hex)
            let maxC = max(rgb.r, rgb.g, rgb.b)
            let minC = min(min(rgb.r, rgb.g), rgb.b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            guard maxC > 0.25 && saturation > 0.20 else { return nil }
            return rgb
        }
    }

    func update(deltaTime: Float, musicalEnergy: Float) {
        lastEnergy = musicalEnergy

        let holdDuration = baseColorHoldDuration
            - (baseColorHoldDuration - minimumColorHoldDuration) * musicalEnergy

        if inTransition {
            transitionTime += deltaTime
            blendFactor = min(1.0, transitionTime / transitionDuration)

            if blendFactor >= 1.0 {
                currentRGB = nextRGB
                blendFactor = 0
                inTransition = false
                transitionTime = 0
                heldTime = 0
            }
        } else {
            heldTime += deltaTime

            if heldTime >= holdDuration {
                let visible = visiblePalette
                guard !visible.isEmpty else { return }

                var attempts = 0
                repeat {
                    paletteIndex = (paletteIndex + 1) % visible.count
                    attempts += 1
                } while isTooSimilar(visible[paletteIndex], currentRGB)
                    && attempts < visible.count

                nextRGB = visible[paletteIndex]
                inTransition = true
                transitionTime = 0

                print(
                    "[Sequencer] → \(String(format: "(%.2f,%.2f,%.2f)", nextRGB.r, nextRGB.g, nextRGB.b)) " +
                    "holdWas=\(String(format: "%.2f", heldTime))s energy=\(String(format: "%.2f", musicalEnergy))"
                )
            }
        }
    }

    var blendedRGB: (r: Float, g: Float, b: Float) {
        (
            r: currentRGB.r + (nextRGB.r - currentRGB.r) * blendFactor,
            g: currentRGB.g + (nextRGB.g - currentRGB.g) * blendFactor,
            b: currentRGB.b + (nextRGB.b - currentRGB.b) * blendFactor
        )
    }

    private func isTooSimilar(
        _ a: (r: Float, g: Float, b: Float),
        _ b: (r: Float, g: Float, b: Float)
    ) -> Bool {
        let diff = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
        return diff < minimumColorDistance
    }
}
