//
//  InteractionManager.swift
//  SpatialSynesthesia
//
//  Placeholder logic for gaze, proximity, and interactive zones. Wire up when APIs are ready.
//

import Foundation

/// Handles interaction events: first gaze on painting, proximity, and future tap zones.
@MainActor
final class InteractionManager {

    static let shared = InteractionManager()

    var hasReceivedFirstGaze = false
    var hasUserMovedCloser = false

    private init() {}

    /// Called when the user first gazes at the painting.
    func onFirstGazeOnPainting() {
        hasReceivedFirstGaze = true
        // TODO: Trigger reaction (e.g. subtle highlight, audio cue)
    }

    /// Check if the user has moved closer to the painting.
    /// TODO: Use head tracking or anchor distance; visionOS head position API TBD.
    func checkUserProximity(distanceToPainting: Float) {
        // Comfortable "close" threshold ~1.0m
        if distanceToPainting < 1.0 && !hasUserMovedCloser {
            hasUserMovedCloser = true
            // TODO: Trigger reaction (e.g. detail mode, spatial audio shift)
        }
    }

    /// Register a tap/pinch on an interactive zone.
    /// TODO: Attach to InputTargetComponent or gesture handlers on painting zones.
    func onInteractiveZoneTapped(zoneID: String) {
        // TODO: Handle zone-specific actions
    }
}
