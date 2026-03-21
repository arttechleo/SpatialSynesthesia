//
//  Chapter1Score.swift
//  SpatialSynesthesia
//
//  Time-based musical score driving Chapter 1 visuals (independent of stem mute state).
//

import Foundation

/// A keyframed musical score for Chapter 1.
/// Each entry defines which instruments are prominent at a given time.
/// Drives visual modulation independently of stem playback volume.
///
/// IMPORTANT: Adjust timestamps to match the actual symphony.
struct Chapter1ScoreEntry {
    let time: TimeInterval           // seconds from Chapter 1 start
    let prominences: [KandinskyColorCategory: Float]  // 0–1 per category
}

struct Chapter1Score {

    // MARK: Named keyframes (edit these to match the symphony)

    /// Opening beat: **empty prominences** on purpose — no chromatic bias until the first phrase
    /// keyframe (`kFirstPhraseStrings` @ 3s) interpolates in. Do not seed `.blue` / `.yellow` here.
    private static let kOpening = Chapter1ScoreEntry(time: 0.0, prominences: [:])

    private static let kFirstPhraseStrings = Chapter1ScoreEntry(
        time: 3.0,
        prominences: [.blue: 0.6, .violet: 0.4]
    )

    private static let kStringsBuild = Chapter1ScoreEntry(
        time: 8.0,
        prominences: [.blue: 0.9, .violet: 0.7]
    )

    private static let kWoodwindsJoin = Chapter1ScoreEntry(
        time: 14.0,
        prominences: [.blue: 0.5, .violet: 0.3, .yellow: 0.7, .green: 0.5]
    )

    private static let kFullTexture = Chapter1ScoreEntry(
        time: 22.0,
        prominences: [.blue: 0.4, .violet: 0.6, .yellow: 0.8, .green: 0.4, .red: 0.3]
    )

    private static let kBrassEnters = Chapter1ScoreEntry(
        time: 30.0,
        prominences: [.red: 0.9, .orange: 0.7, .yellow: 0.5]
    )

    private static let kClimaxTutti = Chapter1ScoreEntry(
        time: 42.0,
        prominences: [.red: 1.0, .orange: 0.8, .yellow: 0.9, .blue: 0.7, .violet: 0.8, .green: 0.6]
    )

    private static let kStringsRecede = Chapter1ScoreEntry(
        time: 56.0,
        prominences: [.blue: 0.7, .violet: 0.5]
    )

    private static let kPianoAlone = Chapter1ScoreEntry(
        time: 65.0,
        prominences: [.white: 0.8, .gray: 0.4, .blue: 0.3]
    )

    private static let kFinalFade = Chapter1ScoreEntry(
        time: 78.0,
        prominences: [.blue: 0.4, .violet: 0.3, .yellow: 0.4, .green: 0.3, .white: 0.5]
    )

    private static let kTransitionOut = Chapter1ScoreEntry(time: 88.0, prominences: [:])

    /// The full musical score as keyframes. Between keyframes, values are interpolated (smoothstep).
    static let keyframes: [Chapter1ScoreEntry] = [
        kOpening,
        kFirstPhraseStrings,
        kStringsBuild,
        kWoodwindsJoin,
        kFullTexture,
        kBrassEnters,
        kClimaxTutti,
        kStringsRecede,
        kPianoAlone,
        kFinalFade,
        kTransitionOut
    ]

    /// Returns interpolated prominences for the given elapsed time since Chapter 1 start.
    static func prominences(at elapsed: TimeInterval) -> [KandinskyColorCategory: Float] {
        let frames = keyframes
        guard frames.count >= 2 else { return [:] }

        if elapsed <= frames[0].time {
            return frames[0].prominences
        }
        if elapsed >= frames[frames.count - 1].time {
            return frames[frames.count - 1].prominences
        }

        var before = frames[0]
        var after = frames[1]
        for i in 0..<(frames.count - 1) {
            if frames[i].time <= elapsed && elapsed < frames[i + 1].time {
                before = frames[i]
                after = frames[i + 1]
                break
            }
        }

        let span = after.time - before.time
        guard span > 0 else { return before.prominences }

        let t = Float((elapsed - before.time) / span)
        let smooth = t * t * (3 - 2 * t)  // smoothstep

        var result: [KandinskyColorCategory: Float] = [:]
        let allKeys = Set(before.prominences.keys).union(after.prominences.keys)
        for cat in allKeys {
            let a = before.prominences[cat] ?? 0.0
            let b = after.prominences[cat] ?? 0.0
            let v = a + (b - a) * smooth
            if v > 0.01 { result[cat] = v }
        }
        return result
    }

    /// Returns the sequence of regions the user's attention is guided toward (top 3 by score).
    static func attentionSequence(at elapsed: TimeInterval) -> [(regionId: String, intensity: Float)] {
        let proms = prominences(at: elapsed)
        return proms
            .sorted { $0.value > $1.value }
            .prefix(3)
            .compactMap { cat, intensity in
                guard let regionId = primaryAuthoredRegionId(for: cat) else { return nil }
                return (regionId: regionId, intensity: intensity)
            }
    }

    /// Primary authored region id for each category (representative shape on the canvas).
    static func primaryAuthoredRegionId(for category: KandinskyColorCategory) -> String? {
        switch category {
        case .violet: return "authored_top_left_circle"
        case .blue:   return "authored_left_blue_triangle"
        case .yellow: return "authored_bottom_left_yellow"
        case .gray:   return "authored_center_left_checker"
        case .red:    return "authored_central_cluster"
        case .white:  return "authored_upper_center_shapes"
        case .green:  return "authored_bottom_right_green"
        case .orange: return nil
        case .black:  return nil
        case .brown:  return nil
        }
    }
}
