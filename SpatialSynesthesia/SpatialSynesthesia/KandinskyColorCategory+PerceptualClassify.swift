//
//  KandinskyColorCategory+PerceptualClassify.swift
//  SpatialSynesthesia
//
//  Single perceptual path: RGB → HSL → KandinskyColorCategory (no per-hex tables).
//

import Foundation
import UIKit

extension KandinskyColorCategory {

    /// Representative hex for passthrough / UI when no authored `hexColor` is available.
    var defaultHex: String {
        switch self {
        case .red: return "#B1100F"
        case .yellow: return "#D1B646"
        case .blue: return "#405D87"
        case .green: return "#4D594D"
        case .violet: return "#405D87"
        case .orange: return "#E67E22"
        case .gray: return "#CEC6B8"
        case .white: return "#F1ECE5"
        case .black: return "#1A1A1A"
        case .brown: return "#8D6E63"
        }
    }

    /// Wide HSL gates + hue families for painted variation; light reds → `.white` (pink/salmon).
    static func classify(r: Float, g: Float, b: Float) -> KandinskyColorCategory {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        let L = (maxC + minC) / 2.0

        let S: Float
        if delta < 0.001 {
            S = 0
        } else {
            let denom = 1.0 - abs(2.0 * L - 1.0)
            S = denom > 0.001 ? delta / denom : 0
        }

        var H: Float = 0
        if delta > 0.001 {
            if maxC == r {
                H = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
            } else if maxC == g {
                H = 60.0 * (((b - r) / delta) + 2.0)
            } else {
                H = 60.0 * (((r - g) / delta) + 4.0)
            }
            if H < 0 { H += 360 }
        }

        let cat: KandinskyColorCategory
        if S < 0.08 {
            if L > 0.88 { cat = .white }
            else if L > 0.18 { cat = .gray }
            else { cat = .black }
        } else if S < 0.25 {
            if L > 0.82 { cat = .white }
            else if L < 0.18 { cat = .black }
            else if H >= 195 && H < 270 { cat = .blue }
            else if H >= 270 && H < 330 { cat = .violet }
            else if H >= 330 || H < 18 { cat = .red }
            else if H >= 18 && H < 55 { cat = .orange }
            else if H >= 55 && H < 165 { cat = .green }
            else { cat = .gray }
        } else if S < 0.50 {
            if H >= 340 || H < 20 { cat = .red }
            else if H >= 20 && H < 50 { cat = .orange }
            else if H >= 50 && H < 80 { cat = .yellow }
            else if H >= 80 && H < 165 { cat = .green }
            else if H >= 165 && H < 200 { cat = .green }
            else if H >= 200 && H < 265 { cat = .blue }
            else if H >= 265 && H < 340 { cat = .violet }
            else { cat = .gray }
        } else if H >= 345 || H < 15 { cat = .red }
        else if H >= 15 && H < 40 { cat = .orange }
        else if H >= 40 && H < 75 { cat = .yellow }
        else if H >= 75 && H < 160 { cat = .green }
        else if H >= 160 && H < 200 { cat = .green }
        else if H >= 200 && H < 255 { cat = .blue }
        else if H >= 255 && H < 295 { cat = .violet }
        else if H >= 295 && H < 345 { cat = .violet }
        else { cat = .gray }

        if cat == .red && L > 0.72 { return .white }
        return cat
    }

    /// Parses `"#RRGGBB"` or `"RRGGBB"`; invalid input → `.gray`.
    static func classify(hex: String) -> KandinskyColorCategory {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return .gray }
        let r = Float((value >> 16) & 0xFF) / 255.0
        let g = Float((value >> 8) & 0xFF) / 255.0
        let b = Float(value & 0xFF) / 255.0
        return classify(r: r, g: g, b: b)
    }
}

#if DEBUG
/// Runs once at launch; prints `[ColorTest]` lines. Adjust HSL boundaries in `classify(r:g:b:)` only.
enum PerceptualColorClassificationSelfTest {

    /// Call from `ImmersiveView` / app entry so the suite runs a single time per process in DEBUG.
    static func runOnceAtLaunch() {
        struct Flag {
            static var didRun = false
        }
        guard !Flag.didRun else { return }
        Flag.didRun = true
        runColorClassificationTest()
    }

    static func runColorClassificationTest() {
        // Expected outputs match `classify(r:g:b:)` (wide gates + pink→white override).
        let testCases: [(String, KandinskyColorCategory)] = [
            ("#000000", .black), ("#1A1A1A", .black), ("#333333", .gray),
            ("#666666", .gray), ("#999999", .gray), ("#CCCCCC", .gray),
            ("#F2F2F2", .white), ("#FAF7E8", .yellow), ("#EDE3D1", .orange),
            ("#FF0000", .red), ("#D7262E", .red), ("#A61C1C", .red),
            ("#FF6B6B", .red), ("#C94C4C", .red),
            ("#FFD700", .yellow), ("#F4C430", .yellow), ("#FFF176", .yellow),
            ("#E6B800", .yellow),
            ("#1E5A8C", .blue), ("#0D3B66", .blue), ("#4A90E2", .blue),
            ("#87CEEB", .green), ("#2C3E50", .blue),
            ("#2E8B57", .green), ("#6B8E23", .green), ("#98FB98", .green),
            ("#3CB371", .green),
            ("#6A0DAD", .violet), ("#8A2BE2", .violet), ("#9370DB", .violet),
            ("#4B0082", .violet),
            ("#FF8C00", .orange), ("#E67E22", .orange), ("#FFA07A", .orange),
            ("#FFC0CB", .white), ("#F7CAC9", .white), ("#E8A598", .white),
            ("#B0BEC5", .blue), ("#C5CAE9", .blue), ("#D7CCC8", .white),
            ("#CFD8DC", .white), ("#DCDCDC", .gray), ("#BCAAA4", .red),
        ]

        var passed = 0
        var failed = 0
        for (hex, expected) in testCases {
            let result = KandinskyColorCategory.classify(hex: hex)
            if result == expected {
                passed += 1
            } else {
                print("[ColorTest] FAIL \(hex) expected=\(expected) got=\(result)")
                failed += 1
            }
        }
        print("[ColorTest] RESULTS passed=\(passed) failed=\(failed) total=\(testCases.count)")
    }
}
#endif
