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

    /// Passthrough / party-light base (paired with neutral-lerp `colorMultiply` in `GazeImmersiveViewV2`).
    var vividTintColor: UIColor {
        switch self {
        case .red:
            return UIColor(red: 1.00, green: 0.00, blue: 0.00, alpha: 1)
        case .yellow:
            return UIColor(red: 1.00, green: 0.90, blue: 0.00, alpha: 1)
        case .blue:
            return UIColor(red: 0.00, green: 0.15, blue: 1.00, alpha: 1)
        case .green:
            return UIColor(red: 0.00, green: 1.00, blue: 0.00, alpha: 1)
        case .violet:
            return UIColor(red: 0.70, green: 0.00, blue: 1.00, alpha: 1)
        case .orange:
            return UIColor(red: 1.00, green: 0.45, blue: 0.00, alpha: 1)
        case .gray:
            return UIColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1)
        case .white:
            return UIColor(red: 1.00, green: 0.95, blue: 0.85, alpha: 1)
        case .black:
            return UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        case .brown:
            return UIColor(red: 0.80, green: 0.30, blue: 0.00, alpha: 1)
        }
    }

    var tintIntensity: Float {
        switch self {
        case .red:    return 0.92
        case .yellow: return 0.90
        case .blue:   return 0.92
        case .green:  return 0.92
        case .violet: return 0.92
        case .orange: return 0.88
        case .brown:  return 0.85
        case .gray:   return 0.35
        case .white:  return 0.22
        case .black:  return 0.60
        }
    }

    var overlayAlpha: CGFloat {
        switch self {
        case .black: return 0.45
        case .white: return 0.38
        case .gray: return 0.42
        case .brown: return 0.45
        case .yellow: return 0.85
        case .orange: return 0.80
        case .red: return 0.85
        case .green: return 0.75
        case .blue: return 0.85
        case .violet: return 0.80
        }
    }

    var overlayTint: UIColor {
        switch self {
        case .red:
            return UIColor(red: 1.00, green: 0.00, blue: 0.00, alpha: 1.0)
        case .yellow:
            return UIColor(red: 1.00, green: 0.90, blue: 0.00, alpha: 1.0)
        case .blue:
            return UIColor(red: 0.00, green: 0.15, blue: 1.00, alpha: 1.0)
        case .green:
            return UIColor(red: 0.00, green: 1.00, blue: 0.00, alpha: 1.0)
        case .violet:
            return UIColor(red: 0.70, green: 0.00, blue: 1.00, alpha: 1.0)
        case .orange:
            return UIColor(red: 1.00, green: 0.45, blue: 0.00, alpha: 1.0)
        case .gray:
            return UIColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1.0)
        case .white:
            return UIColor(red: 1.00, green: 0.95, blue: 0.85, alpha: 1.0)
        case .black:
            return UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
        case .brown:
            return UIColor(red: 0.80, green: 0.30, blue: 0.00, alpha: 1.0)
        }
    }

    func overlayColor(withAlpha alpha: CGFloat) -> UIColor {
        overlayTint.withAlphaComponent(alpha)
    }
}
