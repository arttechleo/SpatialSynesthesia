//
//  KandinskyColorCategory.swift
//
//  Color categories for gaze-driven visual feedback (overlay/filter).
//  Used by region-based mapping; can later drive sound or image-based sampling.
//

import SwiftUI
import UIKit

/// Color category for region → filter mapping. One dominant category per region in MVP.
enum KandinskyColorCategory: String, CaseIterable, Identifiable {
    case yellow
    case blue
    case red
    case green
    case violet
    case black
    case white
    case gray
    case orange
    case brown

    var id: String { rawValue }

    /// Overlay color for this category (translucent tint).
    var overlayColor: UIColor {
        switch self {
        case .yellow:  return UIColor(red: 1.0, green: 1.0, blue: 0.4, alpha: 0.35)
        case .blue:    return UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 0.35)
        case .red:    return UIColor(red: 1.0, green: 0.25, blue: 0.25, alpha: 0.35)
        case .green:  return UIColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 0.35)
        case .violet: return UIColor(red: 0.6, green: 0.3, blue: 1.0, alpha: 0.35)
        case .black:  return UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.4)
        case .white:  return UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.25)
        case .gray:   return UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.3)
        case .orange: return UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 0.35)
        case .brown: return UIColor(red: 0.5, green: 0.35, blue: 0.2, alpha: 0.35)
        }
    }

    /// SwiftUI Color for any 2D debug UI.
    var swiftUIColor: Color {
        Color(uiColor: overlayColor)
    }
}
