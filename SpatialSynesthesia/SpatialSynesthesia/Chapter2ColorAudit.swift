//
//  Chapter2ColorAudit.swift
//  SpatialSynesthesia
//
//  DEBUG-only Chapter 2 color ↔ passthrough audits (see task doc).
//

import UIKit

#if DEBUG
enum Chapter2ColorAudit {

    static func generateMismatchReport() {
        print("[MismatchReport] ════════════════════════════════")
        print("[MismatchReport] CHAPTER 2 COLOR MATCH AUDIT")
        print("[MismatchReport] ════════════════════════════════")

        for region in AuthoredPaintingRegion.kandinskyComposition {
            let hex = region.hexColor
            let cat = region.category

            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s = String(s.dropFirst()) }
            let hexRGB: (r: Float, g: Float, b: Float)
            if s.count == 6, let val = UInt64(s, radix: 16) {
                hexRGB = (
                    r: Float((val >> 16) & 0xFF) / 255.0,
                    g: Float((val >> 8) & 0xFF) / 255.0,
                    b: Float(val & 0xFF) / 255.0
                )
            } else {
                hexRGB = (0.5, 0.5, 0.5)
            }

            let classifiedCat = KandinskyColorCategory.classify(
                r: hexRGB.r, g: hexRGB.g, b: hexRGB.b
            )

            let overlayColor = cat.vividTintColor
            var or_: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 0
            overlayColor.getRed(&or_, green: &og, blue: &ob, alpha: &oa)

            let match = cat == classifiedCat
            let flag = match ? "✓" : "✗ MISMATCH — hex classifies as \(classifiedCat)"

            print("[MismatchReport] \(flag)")
            print("[MismatchReport]   id:          \(region.id)")
            print("[MismatchReport]   hexColor:    \(hex)")
            print("[MismatchReport]   hexRGB:      (\(String(format: "%.2f", hexRGB.r)),\(String(format: "%.2f", hexRGB.g)),\(String(format: "%.2f", hexRGB.b)))")
            print("[MismatchReport]   stored cat:  \(cat)")
            print("[MismatchReport]   HSL cat:     \(classifiedCat)")
            print("[MismatchReport]   overlay:     (\(String(format: "%.2f", or_)),\(String(format: "%.2f", og)),\(String(format: "%.2f", ob)))")
            print("[MismatchReport] ────────────────────────────")
        }
    }

    static func testPaintingHexClassification() {
        let cases: [(hex: String, expected: KandinskyColorCategory)] = [
            ("#405D87", .blue),
            ("#94A5B6", .blue),
            ("#D1B646", .yellow),
            ("#B1100F", .red),
            ("#4D594D", .green),
            ("#3C4419", .green),
            ("#CEC6B8", .gray),
            ("#EDE7C9", .white),
            ("#AC7674", .orange),
            ("#CEB493", .orange),
            ("#6A0DAD", .violet),
            ("#B8C2BE", .gray),
        ]

        print("[ClassifyTest] ════════════════════════════════")
        var failures = 0
        for tc in cases {
            var s = tc.hex
            if s.hasPrefix("#") { s = String(s.dropFirst()) }
            guard s.count == 6, let val = UInt64(s, radix: 16) else {
                continue
            }
            let r = Float((val >> 16) & 0xFF) / 255.0
            let g = Float((val >> 8) & 0xFF) / 255.0
            let b = Float(val & 0xFF) / 255.0
            let result = KandinskyColorCategory.classify(r: r, g: g, b: b)
            let pass = result == tc.expected
            if !pass { failures += 1 }
            print("[ClassifyTest] \(pass ? "✓" : "✗") \(tc.hex) expected=\(tc.expected) got=\(result)")
        }
        print("[ClassifyTest] \(failures) failures out of \(cases.count)")
        print("[ClassifyTest] ════════════════════════════════")
    }
}
#endif
