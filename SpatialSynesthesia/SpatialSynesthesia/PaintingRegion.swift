//
//  PaintingRegion.swift
//
//  Model for a gaze/tap target region on the canvas. Each region has a color category
//  used for filter overlay. Region bounds are in normalized [0,1] or local space;
//  the canvas builder creates one Entity per region for hit-testing.
//

import Foundation

/// A single interactive region on the painting canvas (e.g. "top-left", "center-blue").
/// Used for region-based gaze/tap mapping; later replaceable by image-based color sampling.
struct PaintingRegion: Identifiable {
    let id: String
    let name: String
    let colorCategory: KandinskyColorCategory
    /// Authored paint hex (e.g. `#B1100F`) for passthrough tint; must match `AuthoredPaintingRegion.hexColor`.
    let hexColor: String

    /// Normalized rect (x, z in plane local: 0...1). Used to place sub-entity and overlay.
    /// x = 0 left, 1 right; z = 0 bottom, 1 top in local plane.
    let normalizedBounds: (xMin: Float, zMin: Float, xMax: Float, zMax: Float)

    /// Stable gaze/dwell key (matches `id` / entity name on region volumes).
    var entityName: String { id }

    init(
        id: String,
        name: String,
        colorCategory: KandinskyColorCategory,
        hexColor: String,
        normalizedBounds: (xMin: Float, zMin: Float, xMax: Float, zMax: Float)
    ) {
        self.id = id
        self.name = name
        self.colorCategory = colorCategory
        self.hexColor = hexColor
        self.normalizedBounds = normalizedBounds
    }
}
