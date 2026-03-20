//
//  KandinskyColorCategory+Overlay.swift
//  SpatialSynesthesia
//
//  Adds overlay rendering helpers (tint + alpha) without changing the base enum.
//

import UIKit

extension KandinskyColorCategory {
    /// Fallback tint / UI color when no authored `PaintingRegion.hexColor` is available (passthrough path).
    var defaultUIColor: UIColor {
        switch self {
        case .red: return UIColor(hex: "#B1100F") ?? overlayTint
        case .yellow: return UIColor(hex: "#D1B646") ?? overlayTint
        case .blue: return UIColor(hex: "#405D87") ?? overlayTint
        case .green: return UIColor(hex: "#4D594D") ?? overlayTint
        case .violet: return UIColor(hex: "#6A0DAD") ?? overlayTint
        case .orange: return UIColor(hex: "#E67E22") ?? overlayTint
        case .gray: return UIColor(hex: "#CEC6B8") ?? overlayTint
        case .white: return UIColor(hex: "#F1ECE5") ?? overlayTint
        case .black: return UIColor(hex: "#1A1A1A") ?? overlayTint
        case .brown: return UIColor(hex: "#8D6E63") ?? overlayTint
        }
    }

    /// Strong passthrough multiply tint for “which color family am I looking at?” (not the painting’s literal hex).
    var vividTintColor: UIColor {
        switch self {
        case .red: return UIColor(hex: "#CC0000")!
        case .yellow: return UIColor(hex: "#FFD700")!
        case .blue: return UIColor(hex: "#1A4A8C")!
        case .green: return UIColor(hex: "#1A6B3C")!
        case .violet: return UIColor(hex: "#5B0DAD")!
        case .orange: return UIColor(hex: "#E65C00")!
        case .gray: return UIColor(hex: "#888888")!
        case .white: return UIColor(hex: "#E8E0D0")!
        case .black: return UIColor(hex: "#1A1A1A")!
        case .brown: return UIColor(hex: "#6D4C41")!
        }
    }

    /// Base cap for multiply blend; combined with `tintIntensityMultiplier` in the passthrough path.
    var tintIntensity: Float {
        switch self {
        case .red, .yellow, .blue, .green, .violet, .orange:
            return 0.55
        case .gray, .white:
            return 0.22
        case .black:
            return 0.35
        case .brown:
            return 0.55
        }
    }

    /// Maximum overlay alpha used for visual feedback.
    var overlayAlpha: CGFloat {
        switch self {
        // Muted categories: keep them clearly intentional (avoid muddy desaturation).
        case .black: return 0.45
        case .white: return 0.38
        case .gray: return 0.42
        case .brown: return 0.45

        // Chromatic categories: slightly higher alpha so the color reads strongly
        // through the painting without looking washed out.
        case .yellow: return 0.85
        case .orange: return 0.80
        case .red: return 0.85
        case .green: return 0.75
        case .blue: return 0.85
        case .violet: return 0.80
        }
    }

    /// Opaque tint used for overlay rendering.
    var overlayTint: UIColor {
        switch self {
        // Keep tints vivid/saturated so colors remain legible through alpha blending.
        case .yellow:  return UIColor(red: 1.0, green: 0.98, blue: 0.35, alpha: 1.0)
        case .orange:  return UIColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1.0)
        case .red:     return UIColor(red: 1.0, green: 0.18, blue: 0.18, alpha: 1.0)
        case .green:   return UIColor(red: 0.22, green: 0.88, blue: 0.38, alpha: 1.0)
        case .blue:    return UIColor(red: 0.12, green: 0.48, blue: 1.0, alpha: 1.0)
        case .violet:  return UIColor(red: 0.72, green: 0.28, blue: 1.0, alpha: 1.0)

        // Muted categories: neutral, lower alpha (set by overlayAlpha above).
        case .black:   return UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        case .white:   return UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        case .gray:    return UIColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1.0)
        case .brown:   return UIColor(red: 0.45, green: 0.26, blue: 0.14, alpha: 1.0)
        }
    }

    /// Overlay color with custom alpha.
    func overlayColor(withAlpha alpha: CGFloat) -> UIColor {
        overlayTint.withAlphaComponent(alpha)
    }
}

