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

    /// Hex colors sampled from the Kandinsky painting (with semantic category for score/fallback).
    static let paintingPalette: [(hex: String, category: KandinskyColorCategory)] = [
        ("#3C4419", .green),
        ("#050507", .black),
        ("#F1ECE5", .white),
        ("#AC7674", .orange),
        ("#B1100F", .red),
        ("#D1B646", .yellow),
        ("#94A5B6", .blue),
        ("#CEC6B8", .gray),
        ("#EDE7C9", .white),
        ("#E0D1C0", .white),
        ("#E4DCC8", .white),
        ("#B8C2BE", .gray),
        ("#CEB493", .orange),
        ("#405D87", .blue),
        ("#171516", .black),
        ("#D1D3C7", .gray),
        ("#4D594D", .green),
        ("#0F0B0D", .black),
        ("#FF8C00", .orange),
        ("#6A0DAD", .violet),
        ("#2E8B57", .green),
    ]

    /// Converts a hex string to normalized RGB floats.
    static func rgbFromHex(_ hex: String) -> (r: Float, g: Float, b: Float) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let val = UInt64(s, radix: 16) else {
            return (0.5, 0.5, 0.5)
        }
        return (
            r: Float((val >> 16) & 0xFF) / 255.0,
            g: Float((val >> 8) & 0xFF) / 255.0,
            b: Float(val & 0xFF) / 255.0
        )
    }

    #if DEBUG
    /// Dedupes `[Ch1-Score]` prominence logs (once per integer second of `elapsed`).
    private static var lastProminenceLogSecond: Int = -1

    private static func debugLogProminence(elapsed: TimeInterval, result: [KandinskyColorCategory: Float]) {
        let sec = Int(floor(elapsed))
        guard sec != lastProminenceLogSecond else { return }
        lastProminenceLogSecond = sec
        print("[Ch1-Score] elapsed=\(String(format: "%.1f", elapsed)) keyframeCount=\(keyframes.count) result=\(result)")
    }
    #endif

    // MARK: Keyframes — dense coverage (≤6s without strong chromatic prominence)

    /// The full musical score as keyframes. Between keyframes, values are interpolated (smoothstep).
    static let keyframes: [Chapter1ScoreEntry] = [
        .init(time: 0.0, prominences: [:]),
        .init(time: 3.0, prominences: [.blue: 0.75]),
        .init(time: 6.0, prominences: [.blue: 0.90, .violet: 0.50]),
        .init(time: 9.0, prominences: [.blue: 0.70, .violet: 0.85]),
        .init(time: 12.0, prominences: [.blue: 0.40, .violet: 0.50, .green: 0.80]),
        .init(time: 15.0, prominences: [.green: 0.70, .yellow: 0.85, .blue: 0.20]),
        .init(time: 18.0, prominences: [.yellow: 0.95, .orange: 0.40]),
        .init(time: 21.0, prominences: [.yellow: 0.60, .orange: 0.90]),
        .init(time: 24.0, prominences: [.orange: 0.70, .red: 0.85]),
        .init(time: 27.0, prominences: [.red: 0.95, .violet: 0.30]),
        .init(time: 30.0, prominences: [.red: 0.80, .blue: 0.70, .violet: 0.60]),
        .init(time: 33.0, prominences: [.violet: 0.95, .blue: 0.50, .red: 0.40]),
        .init(time: 36.0, prominences: [.violet: 0.80, .green: 0.75, .blue: 0.40]),
        .init(time: 39.0, prominences: [.red: 0.85, .orange: 0.70, .yellow: 0.80, .green: 0.65, .blue: 0.75, .violet: 0.85]),
        .init(time: 43.0, prominences: [.red: 1.00, .yellow: 0.90, .blue: 0.90, .violet: 1.00, .green: 0.80, .orange: 0.75]),
        .init(time: 47.0, prominences: [.red: 0.75, .orange: 0.90, .yellow: 0.70]),
        .init(time: 51.0, prominences: [.blue: 0.85, .violet: 0.60, .orange: 0.20]),
        .init(time: 55.0, prominences: [.blue: 0.90, .green: 0.65]),
        .init(time: 59.0, prominences: [.green: 0.95, .blue: 0.30]),
        .init(time: 63.0, prominences: [.yellow: 0.80, .white: 0.50, .green: 0.20]),
        .init(time: 67.0, prominences: [.white: 0.70, .yellow: 0.40]),
        .init(time: 71.0, prominences: [.violet: 0.85, .blue: 0.55, .white: 0.30]),
        .init(time: 75.0, prominences: [.blue: 0.80, .violet: 0.70]),
        .init(time: 79.0, prominences: [.blue: 0.50, .violet: 0.40, .green: 0.30]),
        .init(time: 83.0, prominences: [.blue: 0.25, .violet: 0.20]),
        .init(time: 87.0, prominences: [:])
    ]

    /// Returns interpolated prominences for the given elapsed time since Chapter 1 start.
    static func prominences(at elapsed: TimeInterval) -> [KandinskyColorCategory: Float] {
        let frames = keyframes
        guard frames.count >= 2 else {
            let empty: [KandinskyColorCategory: Float] = [:]
            #if DEBUG
            debugLogProminence(elapsed: elapsed, result: empty)
            #endif
            return empty
        }

        let result: [KandinskyColorCategory: Float]
        if elapsed <= frames[0].time {
            result = frames[0].prominences
        } else if elapsed >= frames[frames.count - 1].time {
            result = frames[frames.count - 1].prominences
        } else {
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
            guard span > 0 else {
                result = before.prominences
                #if DEBUG
                debugLogProminence(elapsed: elapsed, result: result)
                #endif
                return result
            }

            let t = Float((elapsed - before.time) / span)
            let smooth = t * t * (3 - 2 * t)  // smoothstep

            var built: [KandinskyColorCategory: Float] = [:]
            let allKeys = Set(before.prominences.keys).union(after.prominences.keys)
            for cat in allKeys {
                let a = before.prominences[cat] ?? 0.0
                let b = after.prominences[cat] ?? 0.0
                let v = a + (b - a) * smooth
                if v > 0.01 { built[cat] = v }
            }
            result = built
        }

        #if DEBUG
        debugLogProminence(elapsed: elapsed, result: result)
        #endif
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

    #if DEBUG
    /// Maximum prominence each category reaches in any keyframe.
    static func auditScore() {
        var maxByCategory: [KandinskyColorCategory: Float] = [:]
        for frame in Chapter1Score.keyframes {
            for (cat, val) in frame.prominences {
                maxByCategory[cat] = max(maxByCategory[cat] ?? 0, val)
            }
        }
        print("[ScoreAudit] Maximum prominence per category:")
        for cat in KandinskyColorCategory.allCases {
            let maxV = maxByCategory[cat] ?? 0.0
            let flag = maxV < 0.5 ? " ← NEVER PROMINENT" : ""
            print("[ScoreAudit] \(cat): \(String(format: "%.2f", maxV))\(flag)")
        }
    }
    #endif

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
