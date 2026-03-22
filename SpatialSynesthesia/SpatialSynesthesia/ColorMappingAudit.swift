//
//  ColorMappingAudit.swift
//  SpatialSynesthesia
//
//  DEBUG-only startup audits for passthrough / category color mapping.
//

import UIKit

#if DEBUG
extension KandinskyColorCategory {
    /// Expected perceptual label after dominance-based audit simulation (startup table).
    var expectedOverlayDescription: String {
        switch self {
        case .red:    return "RED"
        case .yellow: return "YELLOW"
        case .blue:   return "BLUE"
        case .green:  return "GREEN"
        case .violet: return "MAGENTA-BLUE"
        case .orange: return "YELLOW-RED"
        case .gray:   return "GRAY"
        case .white:  return "GRAY"
        case .black:  return "GRAY"
        case .brown:  return "YELLOW-RED"
        }
    }
}

enum ColorMappingAudit {

    /// Full mapping table: vivid tint → simulated `colorMultiply` at full `tintIntensity` (lerp-from-white model).
    static func auditColorMappings() {
        print("[Audit] ─────────────────────────────────────────────")
        print("[Audit] COMPLETE COLOR MAPPING AUDIT")
        print("[Audit] ─────────────────────────────────────────────")

        for cat in KandinskyColorCategory.allCases {
            let tint = cat.vividTintColor
            var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
            tint.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)

            let intensity = CGFloat(cat.tintIntensity)
            let strength = intensity

            let neutralR: CGFloat = 1.0
            let neutralG: CGFloat = 1.0
            let neutralB: CGFloat = 1.0
            let finalR = neutralR + (tr - neutralR) * strength
            let finalG = neutralG + (tg - neutralG) * strength
            let finalB = neutralB + (tb - neutralB) * strength

            let minRGB = min(min(finalR, finalG), finalB)
            let maxRGB = max(max(finalR, finalG), finalB)
            let spread = maxRGB - minRGB

            let dominant: String
            if spread < 0.15 {
                dominant = "GRAY/WHITE — NOT VISIBLE AS COLOR"
            } else if finalR > 0.82 && finalG > 0.82 && finalB < 0.40 {
                // Lerp-from-white: yellow vivid reads as high R+G, suppressed B
                dominant = "YELLOW"
            } else if finalR > finalG && finalR > finalB {
                dominant = finalG > finalB + 0.2 ? "YELLOW-RED" : "RED"
            } else if finalG > finalR && finalG > finalB {
                dominant = finalR > finalB + 0.2 ? "YELLOW-GREEN" : "GREEN"
            } else if finalB > finalR && finalB > finalG {
                dominant = finalR > finalG + 0.2 ? "MAGENTA-BLUE" : "BLUE"
            } else if finalR > 0.8 && finalG > 0.8 {
                dominant = "YELLOW"
            } else if finalR > 0.8 && finalB > 0.8 {
                dominant = "MAGENTA"
            } else if finalG > 0.8 && finalB > 0.8 {
                dominant = "CYAN"
            } else {
                dominant = "MIXED"
            }

            let expected = cat.expectedOverlayDescription
            let pass = Self.passesAudit(category: cat, dominant: dominant, expected: expected)
            let passStr = pass ? "PASS" : "FAIL ← expected \(expected)"

            let label = cat.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            print("[Audit] \(label) | vividRGB=(\(String(format: "%.2f", tr)),\(String(format: "%.2f", tg)),\(String(format: "%.2f", tb))) | intensity=\(String(format: "%.2f", cat.tintIntensity)) | finalRGB=(\(String(format: "%.2f", finalR)),\(String(format: "%.2f", finalG)),\(String(format: "%.2f", finalB))) | dominantColor=\(dominant) | \(passStr)")
        }

        print("[Audit] ─────────────────────────────────────────────")
    }

    private static func passesAudit(category: KandinskyColorCategory, dominant: String, expected: String) -> Bool {
        if dominant == expected { return true }
        switch category {
        case .gray, .white, .black:
            return dominant.contains("GRAY") || dominant.contains("NOT VISIBLE")
        case .violet:
            return dominant == "MAGENTA-BLUE" || dominant == "MAGENTA" || dominant.contains("MAGENTA")
        case .orange, .brown:
            return dominant == "YELLOW-RED"
        case .yellow:
            return dominant == "YELLOW" || dominant == "YELLOW-GREEN" || dominant == "YELLOW-RED"
        case .green:
            return dominant == "GREEN" || dominant == "YELLOW-GREEN"
        case .blue:
            return dominant == "BLUE"
        case .red:
            return dominant == "RED"
        }
    }

    static func auditRegionMappings() {
        print("[RegionAudit] ─────────────────────────────────────────────")
        AuthoredPaintingRegion.kandinskyComposition.forEach { region in
            let tint = region.category.vividTintColor
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            tint.getRed(&r, green: &g, blue: &b, alpha: &a)
            print("[RegionAudit] id=\(region.id) category=\(region.category) hex=\(region.hexColor) overlayRGB=(\(String(format: "%.2f", r)),\(String(format: "%.2f", g)),\(String(format: "%.2f", b)))")
        }
        print("[RegionAudit] ─────────────────────────────────────────────")
    }
}
#endif
