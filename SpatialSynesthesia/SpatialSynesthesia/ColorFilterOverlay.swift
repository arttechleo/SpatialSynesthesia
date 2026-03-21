//
//  ColorFilterOverlay.swift
//
//  Builds and updates a translucent overlay entity for the painting canvas.
//  One overlay plane per canvas; color is updated from the active KandinskyColorCategory.
//  Used for gaze/tap visual feedback on Vision Pro.
//

import RealityKit
import UIKit

/// Creates and configures the 3D overlay entity (translucent plane in front of the canvas).
enum ColorFilterOverlay {

    /// Creates a full-canvas overlay plane with the given size and initial color (optional).
    /// Place this entity slightly in front of the painting so it doesn't z-fight.
    /// Update material via `updateOverlay(_:category:opacity:)` during activation/deactivation.
    static func makeOverlayEntity(
        width: Float,
        height: Float,
        yOffset: Float = 0.002,
        initialCategory: KandinskyColorCategory? = nil
    ) -> ModelEntity {
        let mesh = MeshResource.generatePlane(width: width, depth: height)
        // Use a tint-only unlit material; actual translucency is driven by `OpacityComponent`.
        // This avoids cases where RealityKit treats material alpha as non-blending.
        // Also keep the material's alpha at 0 initially; this makes the overlay translucent
        // even if `OpacityComponent` does not apply as expected on a given device/build.
        let tintColor: UIColor = (initialCategory?.overlayTint ?? UIColor.white).withAlphaComponent(0)
        let material = UnlitMaterial(color: tintColor)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "ColorFilterOverlay"
        // Slight offset in local +Y (forward from canvas) to avoid z-fight.
        // Note: we intentionally do NOT generate collision shapes so the overlay
        // won't steal tap hits from region quads.
        entity.position = SIMD3<Float>(0, yOffset, 0)
        // Start fully transparent; fade is driven by `GazeInteractionManager`.
        entity.components.set(OpacityComponent(opacity: 0))
        return entity
    }

    /// Updates the overlay entity's unlit material tint.
    /// `color` should already include the desired alpha (for fade/strength).
    static func updateOverlay(_ overlayEntity: ModelEntity, color: UIColor) {
        guard var model = overlayEntity.components[ModelComponent.self] else { return }

        // RealityKit uses `OpacityComponent` for reliable blending on visionOS.
        // Treat the input UIColor's alpha as the desired opacity.
        let inputAlpha = Float(color.cgColor.alpha)
        let clampedAlpha = max(0 as Float, min(1 as Float, inputAlpha))
        // Keep tint alpha in the material too, so the overlay never becomes fully opaque
        // even if OpacityComponent blending is imperfect.
        let tintColor = color

        let material = UnlitMaterial(color: tintColor)
        model.materials = [material]
        overlayEntity.components.set(model)
        overlayEntity.components.set(OpacityComponent(opacity: clampedAlpha))
    }

    /// Backwards-compatible overload: overlay driven by category + opacity.
    static func updateOverlay(
        _ overlayEntity: ModelEntity,
        category: KandinskyColorCategory?,
        opacity: Float
    ) {
        let clampedOpacity = max(0, min(1, opacity))
        let color: UIColor
        if let category, clampedOpacity > 0 {
            color = category.overlayColor(withAlpha: CGFloat(clampedOpacity) * category.overlayAlpha)
        } else {
            color = UIColor.clear
        }
        updateOverlay(overlayEntity, color: color)
    }

    /// Backwards-compatible overload: snaps overlay opacity immediately.
    static func updateOverlay(_ overlayEntity: ModelEntity, category: KandinskyColorCategory?) {
        let opacity: Float = category == nil ? 0 : 1
        updateOverlay(overlayEntity, category: category, opacity: opacity)
    }
}
