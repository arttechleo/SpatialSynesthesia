//
//  UIColor+Hex.swift
//  SpatialSynesthesia
//
//  Shared hex parsing for passthrough tint (with or without "#").
//

import UIKit

extension UIColor {

    /// Parses `#RRGGBB` or `RRGGBB` into sRGB.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt64(s, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255
        let g = CGFloat((val >> 8) & 0xFF) / 255
        let b = CGFloat(val & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }

    /// Boosts saturation for passthrough multiply (weak sRGB hex → vivid world tint).
    func withMinSaturation(_ minSat: CGFloat) -> UIColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let boosted = max(s, minSat)
        return UIColor(hue: h, saturation: boosted, brightness: max(b, 0.55), alpha: a)
    }
}
