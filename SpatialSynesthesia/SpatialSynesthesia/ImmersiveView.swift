//
//  ImmersiveView.swift
//
//  Mixed reality entry: delegates to `GazeImmersiveViewV2` (gaze + painting).
//

import SwiftUI

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

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
