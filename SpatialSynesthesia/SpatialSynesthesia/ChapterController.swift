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

    /// Seconds since Chapter 1 began; incremented in `tick(deltaTime:)` while in `.chapterOne` or `.transitioning`.
    private(set) var chapterOneElapsed: TimeInterval = 0

    private var cancellables = Set<AnyCancellable>()
    private var transitionBlend: Float = 1.0

    /// Chapter 2 entry signifier: 0 = inactive, 1 = complete.
    private(set) var signifierPhase: Float = 0
    private var signifierActive: Bool = false
    private var signifierElapsed: Float = 0

    let signifierFlashDuration: Float = 0.15
    let signifierBlackDuration: Float = 0.40
    let signifierFadeInDuration: Float = 1.20
    let signifierTotalDuration: Float = 1.75

    #if DEBUG
    /// Dedupes `[Ch1-Elapsed]` logs (once per integer second).
    private var lastElapsedLogSecond: Int = -1
    #endif

    func begin() {
        currentChapter = .fadingIn
        withAnimation(.easeIn(duration: fadeInDuration)) {
            fadeOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration) {
            self.currentChapter = .chapterOne
            self.chapterOneElapsed = 0
            #if DEBUG
            self.lastElapsedLogSecond = -1
            print("[Chapter] chapterOne began at \(Date())")
            #endif
        }
    }

    /// Called every frame from SceneEvents.Update to advance Chapter 1 time and check duration.
    func tick(deltaTime: TimeInterval) {
        if currentChapter == .chapterOne || currentChapter == .transitioning {
            chapterOneElapsed += deltaTime
            #if DEBUG
            let sec = Int(floor(chapterOneElapsed))
            if sec != lastElapsedLogSecond {
                lastElapsedLogSecond = sec
                print("[Ch1-Elapsed] \(String(format: "%.1f", chapterOneElapsed))s chapter=\(currentChapter)")
            }
            #endif
        }

        guard currentChapter == .chapterOne else { return }
        if chapterOneElapsed >= chapterOneDuration {
            beginTransitionToChapterTwo()
        }
    }

    func beginTransitionToChapterTwo() {
        guard currentChapter == .chapterOne else { return }
        currentChapter = .transitioning
        transitionBlend = 1.0
        beginChapterTwoSignifier()
        #if DEBUG
        print("[Chapter] transitioning to chapterTwo")
        #endif
    }

    func beginChapterTwoSignifier() {
        signifierActive = true
        signifierElapsed = 0
        signifierPhase = 0
        print("[Signifier] chapter two entry signifier began")
    }

    func tickSignifier(deltaTime: Float) {
        guard signifierActive else { return }
        signifierElapsed += deltaTime
        signifierPhase = min(1.0, signifierElapsed / signifierTotalDuration)
        if signifierPhase >= 1.0 {
            signifierActive = false
            print("[Signifier] complete")
        }
    }

    /// `colorMultiply` during the signifier; `nil` when inactive.
    var signifierEffect: Color? {
        guard signifierActive else { return nil }
        let t = signifierElapsed

        if t < signifierFlashDuration {
            let p = t / signifierFlashDuration
            let v = Double(p)
            return Color(red: v, green: v, blue: v)
        } else if t < signifierFlashDuration + signifierBlackDuration {
            return Color(red: 0.03, green: 0.03, blue: 0.05)
        } else {
            let fadeElapsed = t - signifierFlashDuration - signifierBlackDuration
            let p = Double(min(1.0, fadeElapsed / signifierFadeInDuration))
            let v = 0.03 + 0.97 * p
            return Color(red: v, green: v, blue: v)
        }
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

    /// Whether Chapter 1 modulation should be running (stops once the Ch2 entry signifier completes).
    var isChapterOneActive: Bool {
        switch currentChapter {
        case .chapterOne: return true
        case .transitioning: return signifierPhase < 1.0
        default: return false
        }
    }

    /// Chapter 2 gaze path runs after the signifier completes, even while the Ch1→Ch2 crossfade continues.
    var isChapterTwoInteractionLive: Bool {
        switch currentChapter {
        case .chapterTwo: return true
        case .transitioning: return signifierPhase >= 1.0
        default: return false
        }
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
}
