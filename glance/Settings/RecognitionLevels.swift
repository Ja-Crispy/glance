//
//  RecognitionLevels.swift
//  glance
//
//  The selectable stops on the Recognition page's two sliders, and the only definition of what
//  "Default" means for each.
//
//  These lived as `private` enums inside `RecognitionSettingsPage.swift`, which meant
//  `GlanceSettings` could not see them and had to repeat their values as literals. The two copies
//  had already drifted: the stored default was 0.66 while `MatchConfidenceLevel.standard` is 0.63,
//  so a fresh install rendered as "More strict" and dragging the slider to the middle stop
//  *loosened* the gate by 0.03. Defaults are now derived from these cases, so there is one source
//  of truth and that class of drift cannot recur.
//

import Foundation

/// The three selectable points on the "Match confidence" slider — named rather than exposing the
/// raw cosine-similarity threshold directly.
enum MatchConfidenceLevel: Int, CaseIterable {
    case lessStrict, standard, moreStrict

    var title: String {
        switch self {
        case .lessStrict: return "Less strict"
        case .standard: return "Default"
        case .moreStrict: return "More strict"
        }
    }

    var threshold: Float {
        switch self {
        case .lessStrict: return 0.58
        case .standard: return 0.63
        case .moreStrict: return 0.68
        }
    }

    /// Position in `allCases` — same role as `AutoLockInterval.sliderIndex`.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to threshold: Float) -> Self {
        allCases.min { abs($0.threshold - threshold) < abs($1.threshold - threshold) } ?? .standard
    }

    /// Accepted band for a stored threshold, with a little slack around the stops so a value
    /// written by an older build isn't discarded. Anything outside this is treated as tampering —
    /// see `GlanceSettings.clamped(_:to:fallback:)`.
    static let acceptedRange: ClosedRange<Float> = 0.55...0.90
}

/// The three selectable points on the "Detection distance" slider.
enum DetectionDistanceLevel: Int, CaseIterable {
    case close, standard, far

    var title: String {
        switch self {
        case .close: return "Close"
        case .standard: return "Default"
        case .far: return "Far"
        }
    }

    var minimumFaceWidth: Float {
        switch self {
        case .close: return 0.24
        case .standard: return 0.2
        case .far: return 0.17
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to width: Float) -> Self {
        allCases.min { abs($0.minimumFaceWidth - width) < abs($1.minimumFaceWidth - width) } ?? .standard
    }

    /// Same role as `MatchConfidenceLevel.acceptedRange`. The floor matters most: a stored 0.0
    /// would make every distant bystander a candidate face.
    static let acceptedRange: ClosedRange<Float> = 0.15...0.40
}
