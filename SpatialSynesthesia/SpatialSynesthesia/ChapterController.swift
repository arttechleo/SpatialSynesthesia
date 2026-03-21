//
//  ChapterController.swift
//  SpatialSynesthesia
//
//  Manages the two-chapter arc of the experience.
//  Chapter 1: passive music-driven perception (no gaze interaction)
//  Chapter 2: gaze-driven synesthetic interaction (existing system)
//

import SwiftUI
import Combine

/// Manages the chapter lifecycle. Owns the fade-from-black intro and
/// the transition from Chapter 1 to Chapter 2.
@MainActor
final class ChapterController: ObservableObject {

    enum Chapter {
        case blackout          // pre-start, fully dark
        case fadingIn          // fade from black to passthrough
        case chapterOne        // music drives visual modulation
        case transitioning     // crossfade from ch1 to ch2
        case chapterTwo        // existing gaze interaction system
    }

    @Published var currentChapter: Chapter = .blackout
    @Published var fadeOpacity: Double = 1.0  // 1=black, 0=transparent

    // Chapter 1 duration before auto-transitioning to Chapter 2.
    // The symphony should complete at least one full musical phrase.
    let chapterOneDuration: TimeInterval = 90.0  // adjust to music length

    // Fade in from black duration
    let fadeInDuration: TimeInterval = 3.0

    // Crossfade from Chapter 1 modulation to Chapter 2 gaze system
    let transitionDuration: TimeInterval = 4.0

    private var chapterOneStartTime: Date?
    private var cancellables = Set<AnyCancellable>()
    private var transitionBlend: Float = 1.0

    func begin() {
        currentChapter = .fadingIn
        withAnimation(.easeIn(duration: fadeInDuration)) {
            fadeOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration) {
            self.currentChapter = .chapterOne
            self.chapterOneStartTime = Date()
            #if DEBUG
            print("[Chapter] chapterOne began at \(Date())")
            #endif
        }
    }

    /// Called every frame from SceneEvents.Update to check chapter timing.
    func tick() {
        guard currentChapter == .chapterOne,
              let start = chapterOneStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= chapterOneDuration {
            beginTransitionToChapterTwo()
        }
    }

    func beginTransitionToChapterTwo() {
        guard currentChapter == .chapterOne else { return }
        currentChapter = .transitioning
        transitionBlend = 1.0
        #if DEBUG
        print("[Chapter] transitioning to chapterTwo")
        #endif
    }

    /// Call every frame during .transitioning state to animate chapterOneBlend.
    func updateTransitionBlend(deltaTime: Float) {
        guard currentChapter == .transitioning else { return }
        transitionBlend = max(0, transitionBlend - deltaTime / Float(transitionDuration))
        if transitionBlend <= 0 {
            currentChapter = .chapterTwo
            #if DEBUG
            print("[Chapter] chapterTwo fully active")
            #endif
        }
    }

    /// Whether Chapter 1 modulation should be running.
    var isChapterOneActive: Bool {
        currentChapter == .chapterOne || currentChapter == .transitioning
    }

    /// Blend factor for Chapter 1 modulation (1.0=full, 0.0=none).
    /// Fades out during transition so Chapter 2 takes over cleanly.
    var chapterOneBlend: Float {
        switch currentChapter {
        case .chapterOne:    return 1.0
        case .transitioning: return transitionBlend
        case .chapterTwo:    return 0.0
        default:             return 0.0
        }
    }

    /// Seconds since Chapter 1 began (after fade-in). Used by `Chapter1Score`.
    var chapterOneElapsed: TimeInterval {
        guard let start = chapterOneStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }
}
