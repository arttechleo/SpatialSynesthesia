//
//  GazeImmersiveView.swift
//
//  Gaze/tap-driven painting canvas with color filter overlay. Uses region-based hit-testing;
//  tap (and when available, gaze/focus) sets the active region and overlay color.
//  Designed for Vision Pro testing. Fallback: tap to select region.
//

import ARKit
import RealityKit
import RealityKitContent
import SwiftUI

// MARK: - Scene state (holds entity refs for update closure)

/// Holds references to canvas entities so RealityView update can refresh the overlay.
@Observable
final class GazeImmersiveSceneState {
    var overlayEntity: Entity?
    var regionByEntityName: [String: PaintingRegion] = [:]
}

// MARK: - View

struct GazeImmersiveView: View {

    @Environment(AppModel.self) private var appModel
    @State private var gazeManager = GazeInteractionManager()
    @State private var sceneState = GazeImmersiveSceneState()

    var body: some View {
        RealityView { content in
            await setupScene(content: content)
        } update: { content in
            updateOverlayIfNeeded()
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    handleTap(value: value)
                }
        )
    }

    private func setupScene(content: RealityViewContent) async {
        let result = await PaintingCanvasEntity.build()
        let root = AnchorEntity(.world(transform: matrix_identity_float4x4))
        content.add(root)
        root.addChild(result.root)

        sceneState.overlayEntity = result.overlayEntity
        sceneState.regionByEntityName = result.regionByEntityName

        #if DEBUG
        print("[GazeImmersiveView] Canvas ready; \(result.regions.count) regions")
        #endif
    }

    private func updateOverlayIfNeeded() {
        guard let overlay = sceneState.overlayEntity as? ModelEntity else { return }
        ColorFilterOverlay.updateOverlay(overlay, category: gazeManager.activeCategory)
    }

    private func handleTap(value: EntityTargetValue<SpatialTapGesture.Value>) {
        let entity = value.entity
        let name = entity.name

        if let region = sceneState.regionByEntityName[name] {
            let loc = value.convert(value.location3D, from: .local, to: entity)
            gazeManager.setActiveRegion(
                region,
                hitEntityName: name,
                localPosition: (Float(loc.x), Float(loc.y), Float(loc.z))
            )
            return
        }

        // Tap on painting plane or other: clear or ignore
        if name == "PaintingPlane" {
            gazeManager.setActiveRegion(nil)
        }
    }
}

#Preview(immersionStyle: .mixed) {
    GazeImmersiveView()
        .environment(AppModel())
}
