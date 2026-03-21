//
//  AudioManager.swift
//  SpatialSynesthesia
//
//  Intro composition + per-category sound playback. Fails gracefully if assets are missing.
//

import AVFoundation
import Foundation

#if DEBUG
/// Debug-only; does not affect release builds.
private func spatialSynesthesiaDebugLog(_ message: String) {
    print("[SpatialSynesthesia] \(message)")
}

private func audioGateDebugLog(_ message: @autoclosure () -> String) {
    print(message())
}
#else
@inline(__always)
private func audioGateDebugLog(_ message: @autoclosure () -> String) {}
#endif

@MainActor
final class AudioManager: NSObject, AVAudioPlayerDelegate {

    static let shared = AudioManager()

    // MARK: - Ensemble + Solo (VisionOS Audio MVP)

    /// Base volume for the ensemble bed when no region is focused.
    static let ensembleBaseVolume: Float = 0.95
    /// Volume for the ensemble bed during `preFocus` (aggressive ducking).
    static let ensemblePrefocusVolume: Float = 0.02
    /// Volume for the ensemble bed during `focused` (near-zero / full mute).
    static let ensembleFocusedVolume: Float = 0.0
    /// Volume for any non-active solo stem.
    static let soloMutedVolume: Float = 0.0
    /// Volume for the solo stem during `preFocus` (dwell warming).
    static let soloPrefocusVolume: Float = 0.65
    /// Requested volume for the active solo stem when `focused`.
    ///
    /// Note: `AVAudioPlayer.volume` is effectively clamped to [0, 1]. We still expose the
    /// tuning value here for intent, but we clamp when applying.
    static let soloActiveVolume: Float = 1.0
    /// Volume for optional secondary stems (supporting layer).
    ///
    /// In solo isolation mode, secondary stems are generally muted to keep focus legible.
    /// `setAudioMix` may allow a single fallback secondary stem for categories with no primary.
    static let soloSecondaryVolume: Float = 0.0
    /// Crossfade duration for ensemble/solo transitions.
    /// Used for preFocus and release/noFocus fades.
    static let fadeDuration: TimeInterval = 0.22

    /// Near-silence factor for `.black` focus (no dominant solo).
    private static let ensembleNearSilenceFactorForBlack: Float = 0.05

    private var ensemblePlayer: AVAudioPlayer?
    private var soloPlayersByStem: [String: AVAudioPlayer] = [:]
    private var activeSoloStem: String?
    private var activeSecondaryStems: [String] = []
    private var activeSoloTargetVolume: Float = 0
    private var mixFadeTask: Task<Void, Never>?

    /// Hard-legibility tuning:
    /// - In `.focused`, we switch to an isolation mode and force volumes immediately:
    ///   ensemble -> 0, all non-target solo stems -> 0, only mapped target solo -> audible.
    private let isSoloIsolationModeEnabled = true

    /// Safety floor to avoid perceptual "dropouts" when there is no available solo stem
    /// (e.g. neutral categories or missing bundle audio).

    /// During preFocus, if there is no available solo stem, keep ensemble clearly audible
    /// so the experience never feels like it "cuts out" while the system is deciding.

    private var introPlayer: AVAudioPlayer?
    private var activeCategoryPlayers: [AVAudioPlayer] = []
    private var isFadingOut = false

    private static func clampVolume(_ volume: Float) -> Float {
        max(0, min(1, volume))
    }

    #if DEBUG
    var debugEnsembleVolume: Float { ensemblePlayer?.volume ?? 0 }
    var debugActiveSoloStem: String? { activeSoloStem }
    var debugActiveSoloVolume: Float {
        guard let stem = activeSoloStem, let p = soloPlayersByStem[stem] else { return 0 }
        return p.volume
    }
    #endif

    /// When `true`, immersive intro has not finished: do not start ensemble, preload solos, or apply gaze mix.
    /// Cleared by `GazeImmersiveViewV2` when the intro shell completes (before first `setAudioMix`).
    var isIntroAudioGated: Bool = false

    private override init() {
        super.init()
    }

    // MARK: - Intro composition

    func playIntroComposition() {
        if introPlayer?.isPlaying == true { return }

        guard let url = Bundle.main.url(forResource: "Kandinsky Composition VIII", withExtension: "mp3") else {
            log("[AudioManager] Intro: Kandinsky Composition VIII.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = 1.0
            player.play()
            introPlayer = player
            log("[AudioManager] Intro: playing")
        } catch {
            log("[AudioManager] Intro: failed to play — \(error)")
        }
    }

    func stopIntroComposition() {
        introPlayer?.stop()
        introPlayer = nil
        isFadingOut = false
        log("[AudioManager] Intro: stopped")
    }

    func fadeOutIntroComposition(duration: TimeInterval = 1.5) {
        guard !isFadingOut, let player = introPlayer, player.isPlaying else {
            if !isFadingOut { stopIntroComposition() }
            return
        }

        isFadingOut = true
        let steps = 30
        let stepDuration = duration / Double(steps)
        let volumeStep = 1.0 / Float(steps)

        Task { @MainActor in
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))

                guard let currentPlayer = self.introPlayer else {
                    self.isFadingOut = false
                    return
                }

                currentPlayer.volume = max(0, 1.0 - volumeStep * Float(i))

                if i == steps {
                    self.stopIntroComposition()
                    self.isFadingOut = false
                }
            }
        }
    }

    // MARK: - Category-based playback

    /// Map category to bundle filename (no extension). Tries .m4a then .mp3.
    private static func filename(for category: SoundCategory) -> String {
        switch category {
        case .trumpet:         return "trumpet"
        case .flute:           return "flute"
        case .cello:           return "cello"
        case .organ:           return "organ"
        case .violin:          return "violin"
        case .sustainedViolin: return "sustainedViolin"
        case .altoBell:        return "altoBell"
        case .bassoon:         return "bassoon"
        case .mutedPercussion: return "mutedPercussion"
        case .softPad:         return "softPad"
        case .lowDrone:        return "lowDrone"
        case .flatAmbience:    return "flatAmbience"
        case .default:         return "default"
        }
    }

    /// Play sound for category if asset exists; otherwise log and do nothing.
    /// Retains players so playback is not cut off immediately.
    func play(category: SoundCategory) {
        cleanupFinishedCategoryPlayers()

        let name = Self.filename(for: category)
        let url = Bundle.main.url(forResource: name, withExtension: "m4a")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3")

        guard let url else {
            log("[AudioManager] play(\(category.rawValue)): '\(name).m4a' / '\(name).mp3' not in bundle — no playback")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.volume = 1.0

            let success = player.play()
            if success {
                activeCategoryPlayers.append(player)
                log("[AudioManager] play(\(category.rawValue)): started '\(url.lastPathComponent)'")
            } else {
                log("[AudioManager] play(\(category.rawValue)): play() returned false")
            }
        } catch {
            log("[AudioManager] play(\(category.rawValue)): failed — \(error)")
        }
    }

    /// Backward compatibility: same as play(category:).
    func playMappedSound(category: SoundCategory) {
        play(category: category)
    }

    func stopAllCategorySounds() {
        activeCategoryPlayers.forEach { $0.stop() }
        activeCategoryPlayers.removeAll()
        log("[AudioManager] All category sounds stopped")
    }

    // MARK: - VisionOS Audio MVP (ensemble + solo crossfading)

    /// Starts the ensemble bed loop and preloads solo stems (at volume 0).
    /// Safe to call multiple times.
    func startEnsembleLoop() {
        if isIntroAudioGated {
            #if DEBUG
            spatialSynesthesiaDebugLog("[AudioTrace] startEnsembleLoop SKIPPED introGate=true (no ensemble/preload)")
            #endif
            return
        }
        #if DEBUG
        spatialSynesthesiaDebugLog("[AudioTrace] startEnsembleLoop ENTER introGate=false ensembleExists=\(ensemblePlayer != nil)")
        #endif
        // Ensemble
        if ensemblePlayer == nil {
            guard let url = Bundle.main.url(forResource: "CompositionFullEnsemble", withExtension: "m4a") else {
                log("[AudioManager] Ensemble: CompositionFullEnsemble.m4a not found in bundle")
                return
            }

            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.volume = Self.ensembleBaseVolume
                player.prepareToPlay()
                player.play()
                ensemblePlayer = player
                log("[AudioManager] Ensemble: playing loop CompositionFullEnsemble.m4a")
                #if DEBUG
                spatialSynesthesiaDebugLog("[Audio] ensemble started")
                #endif
            } catch {
                log("[AudioManager] Ensemble: failed to play — \(error)")
            }
        } else if let player = ensemblePlayer, !player.isPlaying {
            // Keep ensemble bed running continuously.
            ensemblePlayer?.volume = Self.ensembleBaseVolume
            ensemblePlayer?.play()
        }

        // Preload solo stems (without changing activeSoloStem).
        preloadAllSoloStemsAtZeroVolume()
    }

    /// Updates audio mix for the currently focused region.
    /// - Parameter category: nil means no focus (solo out, ensemble back to base).
    func setFocusedCategory(_ category: KandinskyColorCategory?) {
        // Ensure ensemble is running.
        startEnsembleLoop()

        let ensembleTargetVolume: Float
        if let category {
            switch category {
            case .black:
                ensembleTargetVolume = Self.ensembleFocusedVolume * Self.ensembleNearSilenceFactorForBlack
            case .white:
                // "Airy ensemble" without a dominant solo.
                ensembleTargetVolume = Self.ensembleFocusedVolume * 0.85
            case .gray:
                // Neutral/gray: keep ensemble lightly ducked, no solo.
                ensembleTargetVolume = Self.ensembleFocusedVolume * 0.85
            default:
                ensembleTargetVolume = Self.ensembleFocusedVolume
            }
        } else {
            ensembleTargetVolume = Self.ensembleBaseVolume
        }

        // Primary + optional secondary stems (focused only)
        let newSoloStem = category.flatMap { ColorSoundMapper.soloStem(for: $0) }
        let newSecondaryStems: [String] = category.map { ColorSoundMapper.secondaryMappings(for: $0) } ?? []
        let appliedSoloActiveVolume = Self.clampVolume(Self.soloActiveVolume)
        let soloTargetVolume: Float = newSoloStem != nil ? appliedSoloActiveVolume : Self.soloMutedVolume

        fadeToTargets(
            ensembleTargetVolume: ensembleTargetVolume,
            soloStem: newSoloStem,
            secondaryStems: newSecondaryStems,
            soloTargetVolume: soloTargetVolume,
            duration: Self.fadeDuration,
            gate2FocusStateLabel: "setFocusedCategory"
        )
    }

    /// Strong-contrast audio mixer driven by gaze dwell focus state.
    /// - Parameters:
    ///   - focusState: whether we are in `preFocus`, `focused`, or `released`.
    ///   - category: the associated Kandinsky color category for the focused region.
    func setAudioMix(
        focusState: GazeInteractionManager.FocusState,
        category: KandinskyColorCategory?
    ) {
        let activeRegionIdForLog: String? = {
            switch focusState {
            case .preFocus(let r), .focused(let r): return r.id
            case .noFocus, .released: return nil
            }
        }()
        let focusStateLog: String = {
            switch focusState {
            case .noFocus: return "noFocus"
            case .released: return "released"
            case .preFocus(let r): return "preFocus(\(r.name))"
            case .focused(let r): return "focused(\(r.name))"
            }
        }()
        audioGateDebugLog(
            "[AudioEntry] focusState=\(focusStateLog) category=\(category?.rawValue ?? "nil") regionId=\(activeRegionIdForLog ?? "nil")"
        )

        if isIntroAudioGated {
            #if DEBUG
            let fs: String = {
                switch focusState {
                case .noFocus: return "noFocus"
                case .released: return "released"
                case .preFocus(let r): return "preFocus(\(r.name))"
                case .focused(let r): return "focused(\(r.name))"
                }
            }()
            spatialSynesthesiaDebugLog("[AudioTrace] setAudioMix SKIPPED introGate=true category=\(category?.rawValue ?? "nil") focus=\(fs)")
            #endif
            return
        }
        #if DEBUG
        let fsEnter: String = {
            switch focusState {
            case .noFocus: return "noFocus"
            case .released: return "released"
            case .preFocus(let r): return "preFocus(\(r.name))"
            case .focused(let r): return "focused(\(r.name))"
            }
        }()
        spatialSynesthesiaDebugLog("[AudioTrace] setAudioMix ENTER introGate=false category=\(category?.rawValue ?? "nil") focus=\(fsEnter)")
        #endif

        startEnsembleLoop()

        let (stateName, regionName): (String, String?) = {
            switch focusState {
            case .noFocus:
                return ("noFocus", nil)
            case .released:
                return ("released", nil)
            case .preFocus(let region):
                return ("preFocus", region.name)
            case .focused(let region):
                return ("focused", region.name)
            }
        }()

        let activeRegionId = activeRegionIdForLog

        // Primary + secondary stem mapping (secondary used only for debug in this hard-pass).
        let mappedSoloStem = category.flatMap { ColorSoundMapper.soloStem(for: $0, regionId: activeRegionId) }
        audioGateDebugLog(
            "[StemResolve] category=\(category?.rawValue ?? "nil") regionId=\(activeRegionId ?? "nil") resolved=\(mappedSoloStem ?? "NIL")"
        )
        audioGateDebugLog(
            "[Gate2-AudioMix] focusState=\(stateName) category=\(category?.rawValue ?? "nil") resolvedStem=\(mappedSoloStem ?? "nil")"
        )
        let mappedSecondaryStems: [String] = category.map { ColorSoundMapper.secondaryMappings(for: $0) } ?? []
        let mappedSoloFile = mappedSoloStem.map { "\($0).m4a" } ?? "nil"

        let categoryFactor: Float = {
            guard let category else { return 1.0 }
            switch category {
            case .black:
                return Self.ensembleNearSilenceFactorForBlack
            case .white, .gray:
                return 0.85
            default:
                return 1.0
            }
        }()

        let ensembleTargetVolume: Float
        let soloTargetVolume: Float

        switch focusState {
        case .noFocus, .released:
            ensembleTargetVolume = Self.ensembleBaseVolume
            soloTargetVolume = Self.soloMutedVolume

        case .preFocus:
            ensembleTargetVolume = Self.ensemblePrefocusVolume * categoryFactor
            soloTargetVolume = mappedSoloStem != nil ? Self.soloPrefocusVolume : Self.soloMutedVolume

        case .focused:
            ensembleTargetVolume = Self.ensembleFocusedVolume * categoryFactor
            let appliedSoloActiveVolume = Self.clampVolume(Self.soloActiveVolume)
            soloTargetVolume = mappedSoloStem != nil ? appliedSoloActiveVolume : Self.soloMutedVolume
        }

        let isolationModeActive = isSoloIsolationModeEnabled
        let categoryStr = category?.rawValue ?? "nil"
        let secondariesStr = mappedSecondaryStems.isEmpty ? "none" : mappedSecondaryStems.joined(separator: ", ")
        let ensembleMuted = ensembleTargetVolume <= 0.001

        let nonTargetSoloStemsCount = soloPlayersByStem.keys.filter { $0 != mappedSoloStem }.count

        let willPromoteStemIdentity = mappedSoloStem != nil && isPreFocusOrFocused(focusState)
        audioGateDebugLog(
            "[StemPromotion] focusState=\(stateName) resolved=\(mappedSoloStem ?? "nil") " +
            "playerLoaded=\(mappedSoloStem.map { soloPlayersByStem[$0] != nil } ?? false) " +
            "willPromote=\(willPromoteStemIdentity)"
        )

        #if DEBUG
        print(
            "[AudioMix] SOLO_ISOLATION=\(isolationModeActive ? "ON" : "OFF") " +
            "focusState=\(stateName) region=\(regionName ?? "nil") " +
            "category=\(categoryStr) activeSolo=\(mappedSoloFile) " +
            "ensembleTargetVol=\(String(format: "%.2f", ensembleTargetVolume)) " +
            "soloTargetVol=\(String(format: "%.2f", soloTargetVolume)) " +
            "secondaryStemsMapped=[\(secondariesStr)] secondaryTargetVol=\(String(format: "%.2f", Self.soloSecondaryVolume)) " +
            "nonTargetSoloStemsCount=\(nonTargetSoloStemsCount) nonTargetSoloTargetVol=\(String(format: "%.2f", Self.soloMutedVolume)) " +
            "ensembleMuted=\(ensembleMuted)"
        )
        #endif

        if isolationModeActive, case .focused = focusState {
            applySoloIsolationNow(
                ensembleTargetVolume: ensembleTargetVolume,
                soloStem: mappedSoloStem,
                soloTargetVolume: soloTargetVolume
            )
            return
        }

        // PreFocus / Release / NoFocus: fade into the forced mix.
        let duration: TimeInterval = {
            switch focusState {
            case .preFocus: return 0.15
            default: return Self.fadeDuration
            }
        }()
        fadeToTargets(
            ensembleTargetVolume: ensembleTargetVolume,
            soloStem: mappedSoloStem,
            secondaryStems: [],
            soloTargetVolume: soloTargetVolume,
            duration: duration,
            gate2FocusStateLabel: stateName
        )
    }

    private func isPreFocusOrFocused(_ focusState: GazeInteractionManager.FocusState) -> Bool {
        switch focusState {
        case .preFocus, .focused:
            return true
        case .noFocus, .released:
            return false
        }
    }

    private func preloadAllSoloStemsAtZeroVolume() {
        #if DEBUG
        spatialSynesthesiaDebugLog("[AudioTrace] preloadAllSoloStemsAtZeroVolume ENTER introGate=\(isIntroAudioGated) existingStemCount=\(soloPlayersByStem.count)")
        #endif
        let stemsToLoad = ColorSoundMapper.allMappedStemNames()
        var loaded: [String] = []
        var missing: [String] = []

        for stem in stemsToLoad {
            guard soloPlayersByStem[stem] == nil else { continue }
            let url = Bundle.main.url(forResource: stem, withExtension: "m4a")
                ?? Bundle.main.url(forResource: stem, withExtension: "mp3")

            guard let url else {
                missing.append(stem)
                log("[AudioManager] Solo preload: '\(stem).m4a' / '\(stem).mp3' not found in bundle")
                continue
            }

            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = -1
                player.volume = 0
                player.prepareToPlay()
                player.play()
                soloPlayersByStem[stem] = player
                loaded.append(url.lastPathComponent)
                log("[AudioManager] Solo preload: playing loop '\(url.lastPathComponent)' at 0 volume")
            } catch {
                missing.append(stem)
                log("[AudioManager] Solo preload: failed to load '\(stem)' — \(error)")
            }
        }

        #if DEBUG
        print("[AudioManager] Preload summary: \(loaded.count) loaded, \(missing.count) missing. Loaded: \(loaded.joined(separator: ", "))")
        if !missing.isEmpty {
            print("[AudioManager] Missing stems (not in bundle): \(missing.joined(separator: ", "))")
        }
        #endif
    }

    private func fadeToTargets(
        ensembleTargetVolume: Float,
        soloStem: String?,
        secondaryStems: [String] = [],
        soloTargetVolume: Float,
        duration: TimeInterval,
        gate2FocusStateLabel: String = ""
    ) {
        #if DEBUG
        spatialSynesthesiaDebugLog("[AudioTrace] fadeToTargets ENTER introGate=\(isIntroAudioGated) soloStem=\(soloStem ?? "nil")")
        #endif
        // Snapshot current volumes so crossfades are smooth even if updates arrive quickly.
        let fromEnsembleVolume = Self.clampVolume(ensemblePlayer?.volume ?? Self.ensembleBaseVolume)
        let oldSoloStem = activeSoloStem
        let oldSoloPlayer = oldSoloStem.flatMap { soloPlayersByStem[$0] }
        let fromOldSoloVolume = Self.clampVolume(oldSoloPlayer?.volume ?? 0)

        let newSoloPlayer = soloStem.flatMap { soloPlayersByStem[$0] }
        let fromNewSoloVolume = Self.clampVolume(newSoloPlayer?.volume ?? 0)

        let secondaryVolume = soloTargetVolume > 0 ? Self.clampVolume(Self.soloSecondaryVolume) : Self.soloMutedVolume

        // Nothing changed: avoid restarting fades.
        if abs(fromEnsembleVolume - ensembleTargetVolume) < 0.0001,
           oldSoloStem == soloStem,
           activeSecondaryStems == secondaryStems,
           abs(activeSoloTargetVolume - soloTargetVolume) < 0.0001 {
            return
        }

        // Set intent immediately so `debugActiveSoloStem` / mix state cannot stay stale when a prior
        // `Task` was cancelled before its completion handler assigned `activeSoloStem`.
        audioGateDebugLog(
            "[Gate2-StemAssign] willAssign=\(soloStem ?? "nil") currentActive=\(activeSoloStem ?? "nil") focusState=\(gate2FocusStateLabel)"
        )
        activeSoloStem = soloStem
        activeSecondaryStems = secondaryStems
        activeSoloTargetVolume = soloTargetVolume
        audioGateDebugLog(
            "[StemAssigned] activeSoloStem=\(activeSoloStem ?? "NIL") focusState=\(gate2FocusStateLabel)"
        )

        #if DEBUG
        spatialSynesthesiaDebugLog(
            "[Mix] ensemble=\(String(format: "%.2f", ensembleTargetVolume)) solo=\(String(format: "%.2f", soloTargetVolume)) activeSolo=\(soloStem ?? "none")"
        )
        if oldSoloStem != soloStem {
            let file = soloStem.map { "\($0).m4a" } ?? "none"
            spatialSynesthesiaDebugLog("[Audio] solo=\(soloStem ?? "none") file=\(file)")
        }
        #endif

        mixFadeTask?.cancel()

        mixFadeTask = Task { @MainActor in
            let steps = max(1, Int(duration * 30))
            for i in 1...steps {
                if Task.isCancelled { return }

                let t = Float(i) / Float(steps)
                let eased = t * t * (3 - 2 * t)

                let ensembleVol = fromEnsembleVolume + (ensembleTargetVolume - fromEnsembleVolume) * eased
                ensemblePlayer?.volume = Self.clampVolume(ensembleVol)

                if let oldSoloPlayer {
                    let toOld: Float = (soloStem == oldSoloStem) ? soloTargetVolume : Self.soloMutedVolume
                    let oldSoloVol = fromOldSoloVolume + (toOld - fromOldSoloVolume) * eased
                    oldSoloPlayer.volume = Self.clampVolume(oldSoloVol)
                }

                if let newSoloPlayer {
                    let newSoloVol = fromNewSoloVolume + (soloTargetVolume - fromNewSoloVolume) * eased
                    newSoloPlayer.volume = Self.clampVolume(newSoloVol)
                }

                for (stem, player) in soloPlayersByStem {
                    if stem == soloStem { continue }
                    let isSecondary = secondaryStems.contains(stem)
                    let targetSec: Float = isSecondary ? secondaryVolume : Self.soloMutedVolume
                    let fromSec = player.volume
                    let secVol = fromSec + (targetSec - fromSec) * eased
                    player.volume = Self.clampVolume(secVol)
                }
            }

            // Finalize exact volumes: primary, secondaries, rest muted.
            ensemblePlayer?.volume = Self.clampVolume(ensembleTargetVolume)
            for (stem, player) in soloPlayersByStem {
                if stem == soloStem {
                    player.volume = Self.clampVolume(soloTargetVolume)
                } else if secondaryStems.contains(stem) {
                    player.volume = Self.clampVolume(secondaryVolume)
                } else {
                    player.volume = Self.soloMutedVolume
                }
            }
            activeSoloStem = soloStem
            activeSecondaryStems = secondaryStems
            activeSoloTargetVolume = soloTargetVolume
        }
    }

    /// Hard-legibility "solo isolation mode".
    /// Forces all volumes immediately (no fade) so ensemble bleed cannot be perceived.
    private func applySoloIsolationNow(
        ensembleTargetVolume: Float,
        soloStem: String?,
        soloTargetVolume: Float
    ) {
        #if DEBUG
        spatialSynesthesiaDebugLog("[AudioTrace] applySoloIsolationNow ENTER introGate=\(isIntroAudioGated) soloStem=\(soloStem ?? "nil")")
        #endif
        if soloStem == activeSoloStem,
           abs(Self.clampVolume(ensemblePlayer?.volume ?? 0) - Self.clampVolume(ensembleTargetVolume)) < 0.02,
           let stem = soloStem,
           let p = soloPlayersByStem[stem],
           abs(p.volume - soloTargetVolume) < 0.03 {
            return
        }
        audioGateDebugLog(
            "[Gate2-StemAssign] willAssign=\(soloStem ?? "nil") currentActive=\(activeSoloStem ?? "nil") focusState=focused"
        )
        mixFadeTask?.cancel()

        ensemblePlayer?.volume = Self.clampVolume(ensembleTargetVolume)

        for (stem, player) in soloPlayersByStem {
            if stem == soloStem {
                player.volume = Self.clampVolume(soloTargetVolume)
            } else {
                player.volume = Self.soloMutedVolume
            }
        }

        // Secondary stems are intentionally disabled for clarity.
        activeSoloStem = soloStem
        activeSecondaryStems = []
        activeSoloTargetVolume = soloTargetVolume
        audioGateDebugLog(
            "[StemAssigned] activeSoloStem=\(activeSoloStem ?? "NIL") focusState=focused"
        )

        audioGateDebugLog(
            "[StemPromotion] focusState=focused resolved=\(soloStem ?? "nil") " +
            "playerLoaded=\(soloStem.map { soloPlayersByStem[$0] != nil } ?? false) willPromote=true isolation=1"
        )

        #if DEBUG
        spatialSynesthesiaDebugLog(
            "[Mix] ensemble=\(String(format: "%.2f", ensemblePlayer?.volume ?? 0)) solo=\(String(format: "%.2f", soloStem.flatMap { soloPlayersByStem[$0] }?.volume ?? 0)) activeSolo=\(soloStem ?? "none")"
        )
        if let s = soloStem {
            spatialSynesthesiaDebugLog("[Audio] solo=\(s) file=\(s).m4a")
        }
        #endif
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.activeCategoryPlayers.removeAll { $0 === player }
        }
    }

    // MARK: - Helpers

    private func cleanupFinishedCategoryPlayers() {
        activeCategoryPlayers.removeAll { !$0.isPlaying }
    }

    private func log(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }

    /// Returns the current playback amplitude (0–1) for the stem
    /// associated with the given color category.
    /// Used exclusively by StemAmplitudeAnalyzer for Chapter 1.
    func currentStemAmplitude(for category: KandinskyColorCategory) -> Float {
        guard let stemName = ColorSoundMapper.soloStem(for: category),
              let player = soloPlayersByStem[stemName] else {
            return 0.0
        }
        return player.isPlaying ? Float(player.volume) : 0.0
    }

    // TODO: Spatial audio placement of stems around the painting (RealityKit spatial audio).
}
