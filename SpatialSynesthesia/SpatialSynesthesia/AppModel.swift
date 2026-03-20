//
//  AppModel.swift
//  SpatialSynesthesia
//
//  Created by Student on 3/13/26.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    /// Enables extra visual debugging for region targeting + overlay visibility.
    /// This is evaluated when the immersive scene is created.
    var isDebugMode: Bool = true

    /// Temporary debug mode: disables the full-canvas overlay entirely.
    /// Useful to confirm the textured painting plane is visible underneath.
    var isOverlayDebugDisabled: Bool = false

    /// Intro composition playback (spatial audio) is noisy during prototype debugging.
    /// Keep off by default to avoid spatial-audio XPC spam and instability.
    var isAudioEnabled: Bool = false

    /// True after the user has triggered the intro composition (e.g. first tap on painting).
    var hasTriggeredIntroOnFirstInteraction = false

    /// If true, classify Kandinsky color from sampled texture RGB at gaze/tap UV.
    /// If false, use the manual region category mapping (known-good milestone behavior).
    var isSampledColorModeEnabled: Bool = false
}
