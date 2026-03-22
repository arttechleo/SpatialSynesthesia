//
//  AuthoredPaintingRegion.swift
//  SpatialSynesthesia
//
//  Composition-based interaction volumes on the painting plane (logical boxes only).
//  One canvas collider; resolve by local hit point + priority.
//

import Foundation
import simd

/// Logical box on the painting surface (plane local space: X × Z span the image, +Y is the thin slab).
struct AuthoredPaintingRegion: Equatable {
    let id: String
    let localCenter: SIMD3<Float>
    let localSize: SIMD3<Float>
    let hexColor: String
    let category: KandinskyColorCategory
    let priority: Int

    func contains(localPoint p: SIMD3<Float>) -> Bool {
        let h = localSize * 0.5
        let e: Float = 1e-4
        return abs(p.x - localCenter.x) <= h.x + e
            && abs(p.y - localCenter.y) <= h.y + e
            && abs(p.z - localCenter.z) <= h.z + e
    }

    /// Among all regions whose box contains `localPoint`, returns the one with highest `priority`.
    static func resolve(localPoint: SIMD3<Float>, in regions: [AuthoredPaintingRegion]) -> AuthoredPaintingRegion? {
        let hits = regions.filter { $0.contains(localPoint: localPoint) }
        return hits.max(by: { $0.priority < $1.priority })
    }

    /// Composition zones only (`kandinskyComposition`); nil if no box contains the point.
    static func resolveAuthoredRegion(localPoint: SIMD3<Float>) -> AuthoredPaintingRegion? {
        resolve(localPoint: localPoint, in: kandinskyComposition)
    }

    /// Derives normalized UV bounds for overlay / legacy `PaintingRegion` wiring.
    func toPaintingRegion(canvasWidth: Float, canvasHeight: Float) -> PaintingRegion {
        let hx = localSize.x * 0.5
        let hz = localSize.z * 0.5
        let xMin = (localCenter.x - hx) / canvasWidth + 0.5
        let xMax = (localCenter.x + hx) / canvasWidth + 0.5
        let zMin = (localCenter.z - hz) / canvasHeight + 0.5
        let zMax = (localCenter.z + hz) / canvasHeight + 0.5
        return PaintingRegion(
            id: id,
            name: id,
            colorCategory: category,
            hexColor: hexColor,
            normalizedBounds: (xMin, zMin, xMax, zMax)
        )
    }

    /// ~9 authored boxes tuned for a 0.7m × 0.9m plane; slightly oversized for forgiving targeting.
    static let kandinskyComposition: [AuthoredPaintingRegion] = {
        // Canvas local: x ∈ [-0.35, 0.35], z ∈ [-0.45, 0.45], y ≈ 0 (surface).
        // Generous Y slab so plane hits with slight numerical error still match a volume.
        let ySlab: Float = 0.12
        return [
            AuthoredPaintingRegion(
                id: "authored_top_left_circle",
                localCenter: SIMD3(-0.20, 0, 0.28),
                localSize: SIMD3(0.32, ySlab, 0.36),
                hexColor: "#405D87",
                category: KandinskyColorCategory.classify(hex: "#405D87"),
                priority: 52
            ),
            AuthoredPaintingRegion(
                id: "authored_left_blue_triangle",
                localCenter: SIMD3(-0.26, 0, 0.02),
                localSize: SIMD3(0.24, ySlab, 0.38),
                hexColor: "#94A5B6",
                category: KandinskyColorCategory.classify(hex: "#94A5B6"),
                priority: 48
            ),
            AuthoredPaintingRegion(
                id: "authored_bottom_left_yellow",
                localCenter: SIMD3(-0.22, 0, -0.30),
                localSize: SIMD3(0.28, ySlab, 0.26),
                hexColor: "#D1B646",
                category: KandinskyColorCategory.classify(hex: "#D1B646"),
                priority: 50
            ),
            AuthoredPaintingRegion(
                id: "authored_center_left_checker",
                localCenter: SIMD3(-0.12, 0, 0.06),
                localSize: SIMD3(0.22, ySlab, 0.30),
                hexColor: "#CEC6B8",
                category: KandinskyColorCategory.classify(hex: "#CEC6B8"),
                priority: 56
            ),
            AuthoredPaintingRegion(
                id: "authored_central_cluster",
                localCenter: SIMD3(0.02, 0, 0.08),
                localSize: SIMD3(0.30, ySlab, 0.34),
                hexColor: "#B1100F",
                category: KandinskyColorCategory.classify(hex: "#B1100F"),
                priority: 72
            ),
            AuthoredPaintingRegion(
                id: "authored_upper_center_shapes",
                localCenter: SIMD3(0.08, 0, 0.30),
                localSize: SIMD3(0.32, ySlab, 0.24),
                hexColor: "#F1ECE5",
                category: KandinskyColorCategory.classify(hex: "#F1ECE5"),
                priority: 54
            ),
            AuthoredPaintingRegion(
                id: "authored_right_blue_circle",
                localCenter: SIMD3(0.24, 0, 0.04),
                localSize: SIMD3(0.26, ySlab, 0.34),
                hexColor: "#405D87",
                category: KandinskyColorCategory.classify(hex: "#405D87"),
                priority: 49
            ),
            AuthoredPaintingRegion(
                id: "authored_bottom_right_green",
                localCenter: SIMD3(0.20, 0, -0.28),
                localSize: SIMD3(0.30, ySlab, 0.26),
                hexColor: "#4D594D",
                category: KandinskyColorCategory.classify(hex: "#4D594D"),
                priority: 47
            ),
            // Gap-fillers (priority 2): upper canvas + far right; specific regions above override via higher priority.
            AuthoredPaintingRegion(
                id: "authored_upper_right",
                localCenter: SIMD3(0.30, 0.0, 0.45),
                localSize: SIMD3(0.40, ySlab, 0.40),
                hexColor: "#94A5B6",
                category: KandinskyColorCategory.classify(hex: "#94A5B6"),
                priority: 2
            ),
            AuthoredPaintingRegion(
                id: "authored_upper_center",
                localCenter: SIMD3(0.02, 0.0, 0.50),
                localSize: SIMD3(0.25, ySlab, 0.30),
                hexColor: "#F1ECE5",
                category: KandinskyColorCategory.classify(hex: "#F1ECE5"),
                priority: 2
            ),
            AuthoredPaintingRegion(
                id: "authored_right_mid",
                localCenter: SIMD3(0.44, 0.0, 0.08),
                localSize: SIMD3(0.30, ySlab, 0.35),
                hexColor: "#405D87",
                category: KandinskyColorCategory.classify(hex: "#405D87"),
                priority: 2
            ),
            AuthoredPaintingRegion(
                id: "authored_background",
                localCenter: SIMD3(0, 0, 0),
                localSize: SIMD3(1.20, ySlab, 1.40),
                hexColor: "#EDE7C9",
                category: KandinskyColorCategory.classify(hex: "#EDE7C9"),
                priority: 0
            )
        ]
    }()

    /// Fallback when no authored box contains the gaze point (defense in depth; not part of `kandinskyComposition`).
    static let backgroundFallback = AuthoredPaintingRegion(
        id: "authored_background_fallback",
        localCenter: SIMD3(0.0, 0.0, 0.0),
        localSize: SIMD3(2.0, 0.12, 2.0),
        hexColor: "#EDE7C9",
        category: KandinskyColorCategory.classify(hex: "#EDE7C9"),
        priority: 0
    )

    static func paintingRegions(canvasWidth: Float, canvasHeight: Float) -> [PaintingRegion] {
        kandinskyComposition.map { $0.toPaintingRegion(canvasWidth: canvasWidth, canvasHeight: canvasHeight) }
    }
}

#if DEBUG
extension AuthoredPaintingRegion {
    /// Text grid of `resolveAuthoredRegion` across the canvas (once per call). Use to find remaining gaps.
    static func logRegionCoverageGrid() {
        let xSteps: [Float] = [-0.35, -0.20, -0.05, 0.10, 0.25, 0.40, 0.55]
        let zSteps: [Float] = [-0.45, -0.30, -0.15, 0.00, 0.15, 0.30, 0.45, 0.60]
        for zVal in zSteps {
            var row = "[CoverageGrid] z=\(String(format: "%.2f", zVal)) | "
            for xVal in xSteps {
                let pt = SIMD3<Float>(xVal, 0, zVal)
                let r = resolveAuthoredRegion(localPoint: pt)
                let cell: String
                if let r {
                    cell = String(r.category.rawValue.prefix(3))
                } else {
                    cell = "---"
                }
                row += cell + " "
            }
            print(row)
        }
    }
}
#endif
