//
//  ImmersiveView.swift
//
//  Mixed reality: generated DebugPaintingPlane with KandinskyTexture, tap → UV → color → sound.
//  UV mapping: X/Z (front face local axes). No USDZ; no gaze.
//

import ARKit
import RealityKit
import RealityKitContent
import SwiftUI
import UIKit

// MARK: - Constants

private let debugPlaneWidth: Float = 0.6
private let debugPlaneHeight: Float = 0.8
private let debugPlanePosition = SIMD3<Float>(0, 0.3, -0.8)
private let debugPlaneName = "DebugPaintingPlane"
private let debugBoxPosition = SIMD3<Float>(-0.5, 0.1, -0.8)
private let debugBoxSize: Float = 0.2
private let debugScale = SIMD3<Float>(1, 1, 1)

private var paintingUsesTexture = false
private weak var lastTapMarker: ModelEntity?

// MARK: - View

struct ImmersiveView: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        GazeImmersiveViewV2()
            .environment(appModel)
            .onAppear {
                ColorSoundMapper.verifyStemFilesOnceAtLaunch()
                #if DEBUG
                PerceptualColorClassificationSelfTest.runOnceAtLaunch()
                #endif
            }
            .onDisappear {
                if appModel.isAudioEnabled {
                    AudioManager.shared.fadeOutIntroComposition()
                }
            }
    }
}

// MARK: - Helpers: scene setup

private func makeDebugPaintingPlane() async -> Entity {
    let textureName = "KandinskyTexture"
    #if DEBUG
    let uiValid = UIImage(named: textureName) != nil
    print("[Texture] UIImage(named: \"\(textureName)\") valid: \(uiValid)")
    #endif

    let mesh = MeshResource.generatePlane(width: debugPlaneWidth, depth: debugPlaneHeight)
    var materials: [RealityKit.Material]
    do {
        let texture = try await TextureResource(named: textureName, in: Bundle.main)
        materials = [UnlitMaterial(texture: texture)]
        paintingUsesTexture = true
        #if DEBUG
        print("[Texture] TextureResource loaded: \(textureName)")
        #endif
    } catch {
        paintingUsesTexture = false
        #if DEBUG
        print("[Texture] Texture failed: \(error); using cyan fallback")
        #endif
        materials = [SimpleMaterial(color: UIColor.systemCyan, isMetallic: false)]
    }

    let plane = ModelEntity(mesh: mesh, materials: materials)
    if var model = plane.components[ModelComponent.self] {
        model.materials = materials
        plane.components.set(model)
    }
    return plane
}

private func makeDebugBox() -> Entity {
    let box = ModelEntity(
        mesh: .generateBox(size: debugBoxSize),
        materials: [SimpleMaterial(color: UIColor.systemOrange, isMetallic: false)]
    )
    box.name = "DebugBox"
    return box
}

private func configurePaintingInteraction(for entity: Entity) {
    entity.components.set(InputTargetComponent())
    entity.components.set(HoverEffectComponent())
    entity.generateCollisionShapes(recursive: false)
    #if DEBUG
    print("[ImmersiveView] Interaction configured on '\(entity.name)'")
    #endif
}

// MARK: - Helpers: UV and color

/// X/Z mapping: front face uses local X and Z. u from x, v from z; clamp [0,1].
private func computeUV(fromLocalPoint local: SIMD3<Float>) -> (u: Float, v: Float) {
    let u = (local.x / debugPlaneWidth) + 0.5
    let v = (local.z / debugPlaneHeight) + 0.5
    return (min(max(u, 0), 1), min(max(v, 0), 1))
}

private func sampleColor(at u: Float, _ v: Float) -> SampledColor? {
    PaintingColorSampler.shared.sample(u: u, v: v)
}

private func triggerSound(for category: SoundCategory) {
    AudioManager.shared.play(category: category)
}

// MARK: - Tap marker

private func updateTapMarker(on entity: Entity, localPosition: SIMD3<Float>) {
    lastTapMarker?.removeFromParent()
    let marker = ModelEntity(
        mesh: .generateSphere(radius: 0.015),
        materials: [SimpleMaterial(color: UIColor.systemRed, isMetallic: false)]
    )
    marker.name = "TapMarker"
    marker.position = localPosition
    entity.addChild(marker)
    lastTapMarker = marker
}

// MARK: - Tap handling

private func handlePaintingTap(value: EntityTargetValue<SpatialTapGesture.Value>, appModel: AppModel) {
    let entity = value.entity

    log("[Tap] entity: '\(entity.name)'")
    guard entity.name == debugPlaneName else { return }

    print("DebugPaintingPlane tapped")

    entity.scale = debugScale * 1.05
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 200_000_000)
        entity.scale = debugScale
    }

    if !appModel.hasTriggeredIntroOnFirstInteraction {
        appModel.hasTriggeredIntroOnFirstInteraction = true
        AudioManager.shared.playIntroComposition()
    }

    let positionInEntity = value.convert(value.location3D, from: .local, to: entity)
    let local = SIMD3<Float>(Float(positionInEntity.x), Float(positionInEntity.y), Float(positionInEntity.z))
    log("[Tap] local: \(local)")

    updateTapMarker(on: entity, localPosition: local)

    let (u, v) = computeUV(fromLocalPoint: local)
    log("[Tap] UV (X/Z): u=\(u), v=\(v)")

    let color: SampledColor
    if let sampled = sampleColor(at: u, v) {
        color = sampled
        let hsv = ColorSoundMapper.hsv(for: sampled)
        log("[Tap] rgb: r=\(sampled.r) g=\(sampled.g) b=\(sampled.b)")
        log("[Tap] hsv: H=\(Int(hsv.h)) S=\(String(format: "%.2f", hsv.s)) V=\(String(format: "%.2f", hsv.v))")
    } else {
        color = SampledColor(r: 0.5, g: 0.5, b: 0.5)
        log("[Tap] sampleColor returned nil; using fallback gray")
    }

    let category = ColorSoundMapper.category(for: color)
    let reason = ColorSoundMapper.categoryReason(for: color)
    log("[Tap] category: \(category.rawValue)")
    log("[Tap] \(reason)")
    print("[Tap] Color -> \(category.rawValue)")

    triggerSound(for: category)
}

private func log(_ message: String) {
    #if DEBUG
    print(message)
    #endif
}

// MARK: - Proximity

private func startProximityMonitoringIfAvailable(content: RealityViewContent, paintingEntity: Entity) {
    Task {
        let session = ARKitSession()
        let worldTracking = WorldTrackingProvider()
        do {
            try await session.run([worldTracking])
        } catch {
            #if DEBUG
            print("[ImmersiveView] WorldTracking not available: \(error)")
            #endif
            return
        }
        let closeThreshold: Float = 0.5
        _ = content.subscribe(to: SceneEvents.Update.self) { _ in
            guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return }
            let devicePosition = deviceAnchor.originFromAnchorTransform.columns.3
            let devicePos = SIMD3<Float>(devicePosition.x, devicePosition.y, devicePosition.z)
            let paintingWorld = paintingEntity.position(relativeTo: nil)
            let dx = devicePos.x - paintingWorld.x, dy = devicePos.y - paintingWorld.y, dz = devicePos.z - paintingWorld.z
            let distance = sqrt(dx * dx + dy * dy + dz * dz)
            if distance < closeThreshold {
                Task { @MainActor in AudioManager.shared.fadeOutIntroComposition() }
            }
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
