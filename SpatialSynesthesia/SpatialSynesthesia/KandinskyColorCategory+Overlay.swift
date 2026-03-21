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

    /// Stage / party-light hues for passthrough color grade (Severance-style), not painting-matched tones.
    var vividTintColor: UIColor {
        switch self {
        case .red:
            return UIColor(red: 1.00, green: 0.00, blue: 0.05, alpha: 1)
        case .yellow:
            return UIColor(red: 1.00, green: 0.92, blue: 0.00, alpha: 1)
        case .blue:
            return UIColor(red: 0.00, green: 0.20, blue: 1.00, alpha: 1)
        case .green:
            return UIColor(red: 0.00, green: 0.85, blue: 0.10, alpha: 1)
        case .violet:
            return UIColor(red: 0.55, green: 0.00, blue: 1.00, alpha: 1)
        case .orange:
            return UIColor(red: 1.00, green: 0.45, blue: 0.00, alpha: 1)
        case .gray:
            return UIColor(red: 0.70, green: 0.72, blue: 0.75, alpha: 1)
        case .white:
            return UIColor(red: 1.00, green: 0.95, blue: 0.80, alpha: 1)
        case .black:
            return UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        case .brown:
            return UIColor(red: 0.78, green: 0.38, blue: 0.05, alpha: 1)
        }
    }

    /// Drives how strongly the passthrough grade reads (paired with `applyPassthroughColorGrade`).
    var tintIntensity: Float {
        switch self {
        case .red:    return 0.82
        case .yellow: return 0.78
        case .blue:   return 0.80
        case .green:  return 0.80
        case .violet: return 0.82
        case .orange: return 0.75
        case .gray:   return 0.30
        case .white:  return 0.20
        case .black:  return 0.60
        case .brown:  return 0.72
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
