//
//  ContentView.swift
//
//  Main window: painting only, no UI. Immersive space opens automatically.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        RealityView { content in
            guard let entity = await loadPaintingAndEasel() else { return }
            entity.scale = [0.15, 0.15, 0.15]
            entity.position = [0, -0.5, -0.8]
            content.add(entity)
            if appModel.isAudioEnabled {
                await MainActor.run { AudioManager.shared.playIntroComposition() }
            }
        } update: { _ in }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await openImmersiveSpaceOnAppear()
        }
    }

    private func openImmersiveSpaceOnAppear() async {
        guard appModel.immersiveSpaceState == .closed else { return }
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                break
            case .userCancelled, .error:
                fallthrough
            @unknown default:
                appModel.immersiveSpaceState = .closed
        }
    }
}

private func loadPaintingAndEasel() async -> Entity? {
    do {
        return try await Entity(named: "PaintingAndEasel", in: realityKitContentBundle)
    } catch {
        for bundle in [realityKitContentBundle, Bundle.main] {
            for subdir in ["3DAssets", "3D Assets", ""] {
                let subpath: String? = subdir.isEmpty ? nil : subdir
                guard let url = bundle.url(forResource: "PaintingAndEasel", withExtension: "usdz", subdirectory: subpath) else { continue }
                do {
                    return try await Entity(contentsOf: url)
                } catch {
                    continue
                }
            }
        }
        return nil
    }
}

#Preview(windowStyle: .volumetric) {
    ContentView()
        .environment(AppModel())
}
