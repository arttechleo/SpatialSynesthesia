//
//  PaintingPlaneCoordinateSpace.swift
//  SpatialSynesthesia
//
//  `MeshResource.generatePlane` local units for our canvas do not match the logical meters used by
//  `AuthoredPaintingRegion` (and the collision box). Gaze converts mesh → authored with these factors;
//  region highlight meshes must convert authored → mesh so they sit on the visible texture.
//

import simd

enum PaintingPlaneCoordinateSpace {
    /// Same constants as gaze ray remap in `GazeImmersiveViewV2.localPointOnPaintingPlaneForGaze`.
    static let meshToAuthoredScaleX: Float = 1.0 / 5.446
    static let meshToAuthoredScaleZ: Float = 1.0 / 8.855

    static let authoredToMeshScaleX: Float = 5.446
    static let authoredToMeshScaleZ: Float = 8.855

    /// Raycast / analytic hit in PaintingPlane **mesh** local space → `AuthoredPaintingRegion` space.
    static func meshLocalPointToAuthored(_ meshLocal: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            meshLocal.x * meshToAuthoredScaleX,
            meshLocal.y,
            meshLocal.z * meshToAuthoredScaleZ
        )
    }

    /// `AuthoredPaintingRegion` center / size → PaintingPlane **mesh** local (child entity space).
    static func authoredPointToMeshLocal(_ authored: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            authored.x * authoredToMeshScaleX,
            authored.y,
            authored.z * authoredToMeshScaleZ
        )
    }

    static func authoredSizeToMeshLocal(_ size: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            size.x * authoredToMeshScaleX,
            size.y,
            size.z * authoredToMeshScaleZ
        )
    }
}
