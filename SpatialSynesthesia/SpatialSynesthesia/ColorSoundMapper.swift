//
//  ColorSoundMapper.swift
//  SpatialSynesthesia
//
//  Maps RGB/HSV to Kandinsky-inspired sound categories.
//  Supports primary + optional secondary stems per KandinskyColorCategory,
//  with register/depth variants for blue and red.
//

import Foundation
import simd

// MARK: - Blue/Red variants (for future region-based depth/register)

/// Optional variant for blue (light/mid/dark) and red (bright/deep).
/// When nil, primary mapping is used. Pass from region when supported.
enum ColorSoundVariant: String, CaseIterable {
    case blueLight
    case blueMid
    case blueDark
    case redBright
    case redDeep
}

enum SoundCategory: String, CaseIterable {
    case trumpet
    case flute
    case cello
    case organ
    case violin
    case sustainedViolin
    case altoBell
    case bassoon
    case mutedPercussion
    case softPad
    case lowDrone
    case flatAmbience
    case `default`
}

struct HSVColor {
    let h: Float   // 0...360
    let s: Float   // 0...1
    let v: Float   // 0...1
}

enum ColorSoundMapper {

    static func map(rgb: SIMD3<Float>) -> SoundCategory {
        let hsv = rgbToHSV(rgb)
        return map(rgb: rgb, hsv: hsv)
    }

    static func map(rgb: SIMD3<Float>, hsv: HSVColor) -> SoundCategory {
        let h = hsv.h
        let s = hsv.s
        let v = hsv.v

        // 1. Very dark / black / deep neutral
        if v < 0.12 {
            return .lowDrone
        }

        // 2. Pale bright near-white / cream background
        if s < 0.18 && v > 0.82 {
            return .softPad
        }

        // 3. Gray / deadened midtone neutral zone
        if s < 0.12 && v >= 0.12 && v <= 0.82 {
            return .flatAmbience
        }

        // 4. Muted warm near-neutrals: keep them ambient unless strongly chromatic
        if (h >= 25 && h <= 70) && s < 0.22 && v < 0.88 {
            return .flatAmbience
        }

        // 5. Brown / ochre detection before broad red-orange buckets
        if (h >= 20 && h <= 50) && s >= 0.25 && v >= 0.20 && v <= 0.65 {
            if h >= 38 && h <= 50 {
                return .altoBell
            } else {
                return .mutedPercussion
            }
        }

        // 6. Yellow / gold
        if h >= 45 && h <= 70 {
            if s >= 0.22 {
                return .trumpet
            } else {
                return .flatAmbience
            }
        }

        // 7. Orange
        if h >= 20 && h < 45 {
            if v > 0.65 && s > 0.35 {
                return .altoBell
            } else {
                return .mutedPercussion
            }
        }

        // 8. Red / maroon / crimson
        if h >= 345 || h < 20 {
            return .violin
        }

        // 9. Green
        if h >= 70 && h < 150 {
            return .sustainedViolin
        }

        // 10. Blue / cyan
        if h >= 150 && h < 260 {
            if v > 0.72 {
                return .flute
            } else if v > 0.38 {
                return .cello
            } else {
                return .organ
            }
        }

        // 11. Violet / purple
        if h >= 260 && h < 345 {
            return .bassoon
        }

        return .default
    }

    static func rgbToHSV(_ rgb: SIMD3<Float>) -> HSVColor {
        let r = rgb.x
        let g = rgb.y
        let b = rgb.z

        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        let delta = maxVal - minVal

        var h: Float = 0

        if delta != 0 {
            if maxVal == r {
                h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxVal == g {
                h = 60 * (((b - r) / delta) + 2)
            } else {
                h = 60 * (((r - g) / delta) + 4)
            }
        }

        if h < 0 {
            h += 360
        }

        let s: Float = maxVal == 0 ? 0 : delta / maxVal
        let v: Float = maxVal

        return HSVColor(h: h, s: s, v: v)
    }

    // MARK: - SampledColor bridge

    static func category(for color: SampledColor) -> SoundCategory {
        map(rgb: SIMD3<Float>(color.r, color.g, color.b))
    }

    static func hsv(for color: SampledColor) -> HSVColor {
        rgbToHSV(SIMD3<Float>(color.r, color.g, color.b))
    }

    static func categoryReason(for color: SampledColor) -> String {
        let c = category(for: color)
        let hsv = Self.hsv(for: color)
        return "\(c.rawValue) (H=\(Int(hsv.h)) S=\(String(format: "%.2f", hsv.s)) V=\(String(format: "%.2f", hsv.v)))"
    }

    // MARK: - RGB -> KandinskyColorCategory (texture sampling classifier)

    struct KandinskyClassification {
        let category: KandinskyColorCategory
        /// 0...1 confidence based on separation between top two scores.
        let confidence: Float
        let hsv: HSVColor
    }

    /// Perceptual RGB → Kandinsky category (single path: `KandinskyColorCategory.classify`).
    /// `confidence` is a simple chroma proxy for diagnostics / future gating (HSV-based).
    static func kandinskyClassify(for sampled: SampledColor) -> KandinskyClassification {
        let hsv = Self.hsv(for: sampled)
        let category = KandinskyColorCategory.classify(r: sampled.r, g: sampled.g, b: sampled.b)
        func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }
        let chroma = hsv.s * (0.6 + 0.4 * hsv.v)
        let confidence = clamp01(0.4 + 0.6 * min(1, chroma / 0.65))
        return KandinskyClassification(category: category, confidence: confidence, hsv: hsv)
    }

    /// Back-compat helper where only a category is needed.
    static func kandinskyCategory(for sampled: SampledColor) -> KandinskyColorCategory {
        kandinskyClassify(for: sampled).category
    }

    // MARK: - VisionOS Audio MVP Mapping (expanded: primary + secondary + variants)

    /// Per-authored-region primary solo (nine distinct stems for the composition zones).
    /// Filenames must match bundled `.m4a` / `.mp3` resources (see `allMappedStemNames()`).
    private static func soloStemForAuthoredRegionId(_ id: String) -> String? {
        switch id {
        case "authored_top_left_circle":
            return "Oboe"
        case "authored_left_blue_triangle":
            return "FluteSolo"
        case "authored_bottom_left_yellow":
            return "TrumpetsSolo"
        case "authored_center_left_checker":
            return "ClarinetSolo"
        case "authored_central_cluster":
            return "TrombonesSolo"
        case "authored_upper_center_shapes":
            return "SteinwayGrandPianoSolo"
        case "authored_right_blue_circle":
            return "StringEnsembleVioloncelloSolo"
        case "authored_bottom_right_green":
            return "StringEnsembleViolaSolo"
        case "authored_background":
            return "BassoonSolo"
        case "authored_background_fallback":
            return "BassoonSolo"
        case "authored_upper_right":
            return "FluteSolo"
        case "authored_upper_center":
            return "SteinwayGrandPianoSolo"
        case "authored_right_mid":
            return "StringEnsembleVioloncelloSolo"
        default:
            return nil
        }
    }

    /// Primary solo stem for a Kandinsky color category.
    /// When `regionId` matches an `AuthoredPaintingRegion.id`, that region’s solo wins (unique stem per zone).
    /// Optional variant refines blue (light/mid/dark) or red (bright/deep) when no region id is provided.
    static func soloStem(for category: KandinskyColorCategory, variant: ColorSoundVariant? = nil, regionId: String? = nil) -> String? {
        if let regionId, let stem = soloStemForAuthoredRegionId(regionId) {
            return stem
        }

        switch category {
        case .yellow:
            return "TrumpetsSolo"

        case .blue:
            switch variant {
            case .blueLight: return "FluteSolo"
            case .blueMid:   return "StringEnsembleVioloncelloSolo"
            case .blueDark:  return "StringEnsembleContrabassSolo"
            case .none, .redBright, .redDeep:
                return "StringEnsembleVioloncelloSolo"
            }

        case .red:
            switch variant {
            case .redBright: return "TrumpetsSolo"
            case .redDeep:   return "TubaSolo"
            case .none, .blueLight, .blueMid, .blueDark:
                return "TrombonesSolo"
            }

        case .orange:
            return "FrenchHorns"

        case .violet:
            return "Oboe"

        case .green:
            return "StringEnsembleViolaSolo"

        case .brown:
            return "BassClarinetSolo"

        case .gray:
            return "ClarinetSolo"

        case .white:
            return "SteinwayGrandPianoSolo"

        case .black:
            return "BassoonSolo"
        }
    }

    /// Optional secondary/supporting stems for a category (subtle layer; mix at lower volume).
    /// Empty array when no secondaries are desired.
    static func secondaryMappings(for category: KandinskyColorCategory) -> [String] {
        switch category {
        case .yellow:
            return ["StringEnsembleViolin1Solo", "StringEnsembleViolin2Solo"] // bright edge accents
        case .blue:
            return ["StringEnsembleVioloncelloSolo", "StringEnsembleContrabassSolo"] // depth
        case .red:
            return ["TrombonesSolo", "TrumpetsSolo"] // brass support / bright accent
        case .orange:
            return ["TrombonesSolo"]
        case .violet:
            return ["BassClarinetSolo"]
        case .green:
            return ["ClarinetSolo"]
        case .brown:
            return []
        case .gray:
            return ["ClarinetSolo"] // very low level or none
        case .white:
            return ["Oboe", "StringEnsembleViolin1Solo", "SteinwayGrandPianoSolo"] // optional lyrical / airy
        case .black:
            return []
        }
    }

    /// All stem filenames (no extension) that may be used for any category.
    /// Use for preloading; missing files are skipped gracefully in AudioManager.
    static func allMappedStemNames() -> [String] {
        var names: Set<String> = []
        for category in KandinskyColorCategory.allCases {
            if let primary = soloStem(for: category) {
                names.insert(primary)
            }
            for secondary in secondaryMappings(for: category) {
                names.insert(secondary)
            }
        }
        for authored in AuthoredPaintingRegion.kandinskyComposition {
            if let stem = soloStemForAuthoredRegionId(authored.id) {
                names.insert(stem)
            }
        }
        // SoCalSolo: optional special texture; include for preload, use only if mapped
        names.insert("SoCalSolo")
        return Array(names).sorted()
    }

    // TODO: Multiple simultaneous color layers (e.g. primary + secondary at distinct levels per region).
}

extension ColorSoundMapper {

    /// Logs whether each category’s primary solo stem exists in the app bundle (`.m4a`, `.mp3`, `.wav`, `.caf`).
    static func verifyStemFiles() {
        #if DEBUG
        for cat in KandinskyColorCategory.allCases {
            let stem = soloStem(for: cat)
            let exists = stem.map { s in
                Bundle.main.url(forResource: s, withExtension: "m4a") != nil
                    || Bundle.main.url(forResource: s, withExtension: "mp3") != nil
                    || Bundle.main.url(forResource: s, withExtension: "wav") != nil
                    || Bundle.main.url(forResource: s, withExtension: "caf") != nil
            } ?? false
            print("[StemVerify] \(cat) → '\(stem ?? "NIL")' fileExists=\(exists)")
        }
        #endif
    }

    static func verifyStemFilesOnceAtLaunch() {
        struct Once {
            static var didRun = false
        }
        guard !Once.didRun else { return }
        Once.didRun = true
        verifyStemFiles()
    }
}
