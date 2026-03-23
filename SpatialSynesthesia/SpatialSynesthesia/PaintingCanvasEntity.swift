//
//  PaintingCanvasEntity.swift
//
//  Builds the 3D painting canvas: textured plane (single collider). Passthrough tint is view-level only.
//  Interaction regions are logical only (`AuthoredPaintingRegion`); resolve from plane local hit point.
//

import RealityKit
import UIKit

// MARK: - Canvas layout constants

/// Canvas size in meters (local plane: width = X, height = Z).
private let canvasWidth: Float = 0.7
private let canvasHeight: Float = 0.9
/// Distance in front of user (world Z).
private let canvasDistance: Float = -1.35
private let canvasHeightFromOrigin: Float = 0.2
private func defaultRegions() -> [PaintingRegion] {
    AuthoredPaintingRegion.paintingRegions(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
}

// MARK: - Builder result

struct PaintingCanvasResult {
    let root: Entity
    let regions: [PaintingRegion]
    /// Map from region entity name (region.id) to PaintingRegion.
    var regionByEntityName: [String: PaintingRegion] {
        Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
    }
}

// MARK: - Builder

enum PaintingCanvasEntity {
    /// Current interactive canvas dimensions in meters.
    /// Used for mapping taps on `PaintingPlane` back into normalized UVs.
    static func canvasDimensions() -> (width: Float, height: Float) {
        (canvasWidth, canvasHeight)
    }

    /// When true, root is built with zero position and identity orientation for attaching to an easel surface.
    /// When false, root uses the default world position/orientation (standalone flat canvas).
    static func build(
        regions: [PaintingRegion]? = nil,
        textureName: String = "KandinskyTexture",
        debugMode: Bool = false,
        alignedToEaselSurface: Bool = false,
        alignedPlaneDebugVisible: Bool = false
    ) async -> PaintingCanvasResult {
        let resolvedRegions = regions ?? defaultRegions()

        let root = Entity()
        root.name = "PaintingCanvas"
        if alignedToEaselSurface {
            root.position = .zero
            // When attached under the easel's painting surface, do not apply the standalone
            // rotation again (prevents double-rotation / upside-down issues).
            root.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        } else {
            root.position = SIMD3<Float>(0, canvasHeightFromOrigin, canvasDistance)
            root.orientation = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        }

        // 1. Main visible plane with texture
        let plane = await makeTexturedPlane(
            width: canvasWidth,
            height: canvasHeight,
            textureName: textureName,
            debugMode: debugMode
        )
        plane.name = "PaintingPlane"
        // Enable tap/collision across the whole textured plane.
        // Without this, taps near edges can miss region quads and appear constrained.
        plane.components.set(InputTargetComponent())
        // Helps visionOS associate spatial pointer / gaze with this surface for `SpatialEventGesture`.
        plane.components.set(HoverEffectComponent())
        // Mesh-derived collision from `generatePlane` can be too thin/unreliable for `Scene.raycast`
        // (head-direction proxy). Use an explicit box that matches the visible surface in local X/Z.
        let collisionThickness: Float = 0.02
        let boxShape = ShapeResource.generateBox(
            size: SIMD3<Float>(canvasWidth, collisionThickness, canvasHeight)
        )
        plane.components.set(CollisionComponent(shapes: [boxShape]))
        root.addChild(plane)

        // Temporary alignment debug: make the interactive plane root orientation obvious.
        // This is only for diagnosing front/back and upside-down issues on the 3D easel.
        if alignedToEaselSurface && alignedPlaneDebugVisible {
            // Swap plane material to a tint so it is detectable even if the texture is hard to see.
            // Collision is unchanged; only visibility is affected.
            let debugPlaneMaterial = SimpleMaterial(
                color: UIColor.systemTeal.withAlphaComponent(0.25),
                isMetallic: false
            )
            if var model = plane.components[ModelComponent.self] {
                model.materials = [debugPlaneMaterial]
                plane.components.set(model)
            }
        }

        // REMOVING: ColorFilterOverlay plane — passthrough filters use `preferredSurroundingsEffect` only.

        return PaintingCanvasResult(root: root, regions: resolvedRegions)
    }

    private static func makeTexturedPlane(
        width: Float,
        height: Float,
        textureName: String,
        debugMode: Bool
    ) async -> ModelEntity {
        let mesh = MeshResource.generatePlane(width: width, depth: height)
        var materials: [RealityKit.Material]

        if debugMode {
            // Confirms the asset catalog has an image set with this name.
            let uiImageExists = UIImage(named: textureName) != nil
            print("[PaintingCanvasEntity] Texture asset existence check: UIImage(named: \"\(textureName)\") exists=\(uiImageExists)")
        }

        do {
            let texture = try await TextureResource(named: textureName, in: Bundle.main)
            materials = [UnlitMaterial(texture: texture)]
            if debugMode {
                print("[PaintingCanvasEntity] TextureResource loaded successfully: textureName=\(textureName), bundlePath=\(Bundle.main.bundleURL.path)")
            }
        } catch {
            if debugMode {
                print("[PaintingCanvasEntity] TextureResource FAILED to load: textureName=\(textureName), bundlePath=\(Bundle.main.bundleURL.path). Error: \(error). Falling back to cyan.")
            }
            materials = [SimpleMaterial(color: UIColor.systemCyan, isMetallic: false)]
        }
        let plane = ModelEntity(mesh: mesh, materials: materials)
        if var model = plane.components[ModelComponent.self] {
            model.materials = materials
            plane.components.set(model)
        }

        if debugMode {
            let matTypes = materials.map { String(describing: type(of: $0)) }.joined(separator: ", ")
            print("[PaintingCanvasEntity] PaintingPlane created with materials=[\(matTypes)]")
        }

        return plane
    }
}
