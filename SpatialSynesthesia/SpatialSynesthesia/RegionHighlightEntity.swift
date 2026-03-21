//
//  RegionHighlightEntity.swift
//  SpatialSynesthesia
//
//  Optional Chapter 1 visuals: thin emissive boxes on the painting (one per region).
//  Positions use `PaintingPlaneCoordinateSpace` so meshes align with the textured plane (mesh local ≠ authored meters).
//  Toggle via `SynesthesiaOrchestrator.regionHighlightDisplayMode`.
//

import RealityKit
import UIKit

/// Invisible box that highlights a painting region with emissive color driven by the score.
/// Sits slightly in front of the painting surface in plane-local space.
@MainActor
final class RegionHighlightEntity {

    let region: AuthoredPaintingRegion
    let entity: ModelEntity

    private(set) var currentIntensity: Float = 0

    let highlightColor: UIColor

    /// Breathing animation rate (Hz). One full cycle ≈ 1 / breathFrequency seconds.
    static let breathFrequency: Float = 0.4

    private var breathPhase: Float = 0

    init(region: AuthoredPaintingRegion, paintingEntity: Entity) {
        self.region = region
        self.highlightColor = region.category.vividTintColor

        let meshSize = PaintingPlaneCoordinateSpace.authoredSizeToMeshLocal(region.localSize)
        // Thin emissive slab on the surface (Y is plane normal; do not use authored ySlab height).
        let mesh = MeshResource.generateBox(
            width: meshSize.x,
            height: 0.002,
            depth: meshSize.z
        )

        let material = UnlitMaterial(color: .clear)
        entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "RegionHighlight_\(region.id)"

        let meshCenter = PaintingPlaneCoordinateSpace.authoredPointToMeshLocal(region.localCenter)
        entity.position = SIMD3<Float>(
            meshCenter.x,
            meshCenter.y + 0.002,
            meshCenter.z
        )

        paintingEntity.addChild(entity)

        #if DEBUG
        print("[RegionHighlight] created for \(region.id) color=\(region.category)")
        #endif
    }

    func setIntensity(_ intensity: Float) {
        guard abs(intensity - currentIntensity) > 0.005 else { return }
        currentIntensity = intensity

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        highlightColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        let alpha = CGFloat(intensity * 0.70)

        let color = UIColor(red: r, green: g, blue: b, alpha: alpha)
        guard var model = entity.model else { return }
        model.materials = [UnlitMaterial(color: color)]
        entity.model = model
    }

    /// Breathing pulse layered on the base musical intensity.
    func updateWithBreathing(
        baseIntensity: Float,
        deltaTime: Float,
        breathStrength: Float = 0.20
    ) {
        breathPhase += Self.breathFrequency * 2.0 * .pi * deltaTime
        if breathPhase > 2.0 * .pi { breathPhase -= 2.0 * .pi }

        let breathOffset = sin(breathPhase) * breathStrength * baseIntensity
        let animatedIntensity = max(0, min(1, baseIntensity + breathOffset))
        setIntensity(animatedIntensity)
    }
}
