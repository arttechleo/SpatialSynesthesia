//
//  PaintingColorSampler.swift
//  SpatialSynesthesia
//
//  Samples the Kandinsky texture image at UV coordinates. Uses the painting's
//  texture as the source of truth (no camera or passthrough).
//

import CoreGraphics
import UIKit

/// RGB in 0...1 range for mapping.
struct SampledColor {
    var r: Float
    var g: Float
    var b: Float
}

/// Loads the Kandinsky texture from app assets and samples pixel color at UV.
/// Coordinate assumptions:
/// - Plane is centered at origin; local X = [-halfWidth, +halfWidth], local Y = [-halfHeight, +halfHeight].
/// - U runs along local X: u=0 = left, u=1 = right.
/// - V runs along local Y: v=0 = bottom, v=1 = top.
/// - UV [0,1] is clamped so out-of-bounds hits still return a valid color.
final class PaintingColorSampler {

    static let shared = PaintingColorSampler()

    /// Asset name in the app bundle (no extension).
    private let textureName = "KandinskyTexture"
    private var cgImage: CGImage?

    private init() {
        loadTexture()
    }

    private func loadTexture() {
        // Try bundle URL first (raw .png/.jpg in app bundle)
        if let url = Bundle.main.url(forResource: textureName, withExtension: "png")
            ?? Bundle.main.url(forResource: textureName, withExtension: "jpg"),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            cgImage = image.cgImage
            return
        }
        // Fallback: asset catalog (e.g. Assets.xcassets image set named KandinskyTexture)
        if let image = UIImage(named: textureName) {
            cgImage = image.cgImage
        }
    }

    /// Whether the Kandinsky texture was loaded (for debug logging).
    var isTextureLoaded: Bool { cgImage != nil }

    /// Sample color at normalized UV in [0, 1]. Returns nil if texture not loaded.
    func sample(u: Float, v: Float) -> SampledColor? {
        guard let image = cgImage else { return nil }

        let uClamp = min(max(u, 0), 1)
        let vClamp = min(max(v, 0), 1)

        let width = image.width
        let height = image.height
        let x = Int(uClamp * Float(width - 1))
        let y = Int((1 - vClamp) * Float(height - 1))

        let pixelData = image.dataProvider?.data
        guard let data = pixelData else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = image.bytesPerRow
        let offset = y * bytesPerRow + x * bytesPerPixel

        guard offset + 3 < CFDataGetLength(data) else { return nil }

        let ptr = CFDataGetBytePtr(data).advanced(by: offset)
        let r = Float(ptr[0]) / 255
        let g = Float(ptr[1]) / 255
        let b = Float(ptr[2]) / 255

        return SampledColor(r: r, g: g, b: b)
    }
}
