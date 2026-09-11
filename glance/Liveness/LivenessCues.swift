//
//  LivenessCues.swift
//  glance
//
//  Liveness decision model: five independent cues, no combined score. DENY
//  cues override CONFIRM cues unconditionally; a confirm cue's absence is never a failure.
//

import CoreGraphics

/// One cue's latest reading. `confidence` 0 is always an abstention, never a reading of
/// zero — a cue that can't see anything must not be able to convict or acquit.
struct CueReading: Equatable {
    /// 0...1 strength of this cue's own evidence, in the direction that
    /// cue argues for (spoof-ness for deny cues, liveness for confirm cues).
    let level: Float
    let confidence: Float

    nonisolated static let none = CueReading(level: 0, confidence: 0)
}

enum LivenessCueRole: Equatable {
    /// Evidence of a spoof. Firing fails the scan and overrides confirmation.
    case deny
    /// Evidence of a real face. Firing passes the liveness half of the scan.
    case confirm
}

enum LivenessCue: String, CaseIterable, Hashable, Identifiable {
    case glossGlare
    case deviceDetected
    case flatVs3D
    case depthPose
    case blink

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .glossGlare: return "Gloss/glare"
        case .deviceDetected: return "Device detected"
        case .flatVs3D: return "Flat vs 3D"
        case .depthPose: return "Depth/pose"
        case .blink: return "Blink"
        }
    }

    nonisolated var role: LivenessCueRole {
        switch self {
        case .glossGlare, .deviceDetected: return .deny
        case .flatVs3D, .depthPose, .blink: return .confirm
        }
    }

    /// One-line explanation of what firing actually means, for Face Lab.
    nonisolated var explanation: String {
        switch self {
        case .glossGlare: return "Large flat specular highlight — glass/screen glare rather than skin's small scattered shine."
        case .deviceDetected: return "A device-shaped rectangle overlaps the face — a phone or tablet held up."
        case .flatVs3D: return "Held-out nose points miss the plane fit — the face has real depth."
        case .depthPose: return "Nose offset tracks head yaw — the nose sits off the eye plane, so this isn't flat."
        case .blink: return "Eye aspect ratio dipped and recovered — a photo cannot blink."
        }
    }
}

/// How much liveness checking runs. Both modes always run the deny cues —
/// the difference is only whether a *positive* proof of life is also
/// required before unlocking.
enum LivenessMode: String, CaseIterable, Identifiable, Sendable {
    /// Deny-only: "confirmed unless proven wrong." Never blocks a user who sits still.
    ///
    /// Understand what this does and does not stop. The two deny cues look for screen glare and a
    /// device-shaped rectangle around the face, so Light rejects a phone or tablet held up to the
    /// camera. It does **not** stop a matte photographic print trimmed along the hairline: that
    /// produces no specular highlight and no rectangle, so neither cue ever fires and the scan is
    /// auto-confirmed. Light is "rejects a screen", not "rejects a photo".
    case light
    /// Deny cues plus at least one confirm cue must fire — the default. Can block a user who holds
    /// perfectly still and never blinks for the whole scan, which is the intended failure mode:
    /// they type their password instead.
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .heavy: return "Heavy"
        }
    }

    var summary: String {
        switch self {
        // Names the specific gap rather than the vague "obvious spoofs", which reads as though a
        // printed photo counts as obvious. It does not — see the case documentation above.
        case .light: return "Rejects a phone or tablet screen, but not a printed photo."
        case .heavy: return "Also requires proof of a real face — a blink or head turn."
        }
    }
}

/// Fire thresholds per cue: a cue counts a frame when its reading is confident and
/// at/above `level`, and fires once it has counted `frames` of them within the scan.
/// Seeded from real-device observation; retune from Face Lab.
struct LivenessTuning: Equatable {
    var glossLevel: Float = 0.04
    var glossFrames: Int = 3

    /// Deliberately lower than `glossLevel` — the device rectangle detector was already
    /// the one signal proven reliable in real-device testing.
    var deviceLevel: Float = 0.15
    var deviceFrames: Int = 3

    /// Not the 0.5 you might expect: real-world Vision jitter alone measures ~0.21-0.46
    /// in the self-test, so 0.5 would mean this cue essentially never fires.
    var flatVs3DLevel: Float = 0.25
    var flatVs3DFrames: Int = 2

    /// Deliberately high: this level is a remapped correlation `(r + 1) / 2`, so 0.5 is
    /// zero correlation (evidence of nothing) — 0.8 requires r >= 0.6.
    var depthPoseLevel: Float = 0.8
    var depthPoseFrames: Int = 2

    /// A blink is already a discrete dip-and-recover event (see `LivenessScoring.blinkDynamics`),
    /// not a ramping level, so one firing frame is the event itself.
    var blinkFrames: Int = 1

    /// How many frames a *confirm* cue's firing stays valid after its evidence was last seen.
    ///
    /// Deny and confirm cues latch asymmetrically, deliberately. A deny cue latches for the whole
    /// scan so a spoof tell cannot be waited out. A confirm cue must not, because the same
    /// permanence is exploitable in the opposite direction: earn a blink or a head turn with a real
    /// face, then substitute a photo of an enrolled user into the same scan window, and the match
    /// half is re-evaluated per frame while the liveness half is still holding a confirmation the
    /// live face earned. Confirmation now expires, so proof of life has to be contemporaneous with
    /// the face being matched.
    ///
    /// Sized a little above `LivenessAnalyzer.windowDuration` (~2s, ~60 frames at 30fps): while the
    /// evidence is still inside the rolling window the cue keeps re-counting and stays fresh on its
    /// own, so this only decides the grace period after it ages out. Frames rather than seconds
    /// because the evaluator is fed readings, not timestamps; that ties it loosely to frame rate,
    /// which is acceptable for a grace period and keeps the type free of a clock.
    var confirmFreshnessFrames: Int = 70

    /// Frames Light mode waits before auto-confirming, so deny cues get a fair chance to
    /// fire first — otherwise a first-frame match could unlock before glare/device ever ran.
    ///
    /// Must stay comfortably **above** `glossFrames` and `deviceFrames`, not equal to them. At the
    /// previous value of 3 the deny cues had a budget of exactly 3 frames to accumulate 3 counted
    /// frames, so they had to fire on every single observation: one dropped Vision detection, one
    /// frame where `renderCrop` returned nil, and the spoof won on a technicality. 8 gives them
    /// room for the dropouts that actually happen, and costs ~0.27s at 30fps inside a 3-10s window.
    var lightModeMinimumFrames: Int = 8

    /// Frames on which at least one enabled deny cue actually produced a *confident* reading,
    /// required before Light mode will auto-confirm.
    ///
    /// Light mode's contract is "confirmed unless proven wrong", which is only meaningful if the
    /// proving machinery ran at all. Frame count alone does not establish that: `glossGlare`
    /// abstains outright when `renderCrop` returned no crop, and discounts to zero confidence
    /// below ~50 native pixels of face — so a face too small or a crop that failed to rasterize
    /// produced *no* spoof evidence, and Light would still confirm on the strength of having
    /// counted to three. This makes the absence of evidence fail closed rather than open.
    var lightModeMinimumDenyEvidenceFrames: Int = 3

    nonisolated static let `default` = LivenessTuning()

    nonisolated func level(for cue: LivenessCue) -> Float {
        switch cue {
        case .glossGlare: return glossLevel
        case .deviceDetected: return deviceLevel
        case .flatVs3D: return flatVs3DLevel
        case .depthPose: return depthPoseLevel
        // Any confident blink reading is the event; see `blinkFrames`.
        case .blink: return 0.5
        }
    }

    nonisolated func frames(for cue: LivenessCue) -> Int {
        switch cue {
        case .glossGlare: return glossFrames
        case .deviceDetected: return deviceFrames
        case .flatVs3D: return flatVs3DFrames
        case .depthPose: return depthPoseFrames
        case .blink: return blinkFrames
        }
    }
}

enum LivenessDecision: Equatable {
    /// Nothing decided yet. Not a failure — the scan should keep going.
    case pending
    /// Cue is `nil` when Light mode auto-confirmed rather than any cue firing.
    case confirmed(by: LivenessCue?)
    case denied(by: LivenessCue)

    var isConfirmed: Bool { if case .confirmed = self { return true }; return false }
    var isDenied: Bool { if case .denied = self { return true }; return false }

    /// User-facing explanation for a denial, matching the tone of the
    /// coordinator's other outcome strings.
    var denialReason: String? {
        guard case .denied(let cue) = self else { return nil }
        switch cue {
        case .glossGlare: return "Screen glare detected — this looks like a photo on a display."
        case .deviceDetected: return "A device-shaped rectangle was detected around the face — this looks like a photo or screen."
        default: return "Liveness check failed."
        }
    }
}

/// Running state for one cue across a scan.
struct LivenessCueState: Equatable {
    var reading: CueReading = .none
    /// Cumulative, not consecutive — forgiving of one-frame dropouts Vision produces mid-scan.
    var framesCounted: Int = 0
    var hasFired: Bool = false
    /// `framesObserved` when this cue last saw a confident at-level reading, or 0 if never.
    /// Only consulted for confirm cues — see `LivenessTuning.confirmFreshnessFrames`.
    var lastCountedFrame: Int = 0

    /// 0...1 progress toward firing, for Face Lab's progress bars.
    func progress(threshold: Int) -> Float {
        guard threshold > 0 else { return hasFired ? 1 : 0 }
        return min(1, Float(framesCounted) / Float(threshold))
    }
}

struct LivenessSnapshot: Equatable {
    let decision: LivenessDecision
    let mode: LivenessMode
    let cueStates: [LivenessCue: LivenessCueState]
    let frameCount: Int

    nonisolated static let empty = LivenessSnapshot(
        decision: .pending, mode: .light, cueStates: [:], frameCount: 0
    )

    func state(for cue: LivenessCue) -> LivenessCueState {
        cueStates[cue] ?? LivenessCueState()
    }
}

/// The stateful decision core, kept as a plain `struct` rather than folded
/// into `LivenessAnalyzer` so `tools/liveness_selftest.swift` can drive the
/// real firing/latching logic frame by frame with no actor or camera.
struct LivenessEvaluator {
    var mode: LivenessMode
    var tuning: LivenessTuning
    /// Face Lab can switch individual cues off to isolate one; the unlock
    /// path leaves this at "all enabled."
    var enabledCues: Set<LivenessCue>

    private(set) var states: [LivenessCue: LivenessCueState] = [:]
    private(set) var framesObserved: Int = 0
    /// Frames on which at least one enabled deny cue reported with non-zero confidence — i.e. the
    /// spoof detectors had real data to judge, rather than abstaining. Gates Light mode's
    /// auto-confirm; see `LivenessTuning.lightModeMinimumDenyEvidenceFrames`.
    private(set) var denyEvidenceFrames: Int = 0

    init(
        mode: LivenessMode = .light,
        tuning: LivenessTuning = .default,
        enabledCues: Set<LivenessCue> = Set(LivenessCue.allCases)
    ) {
        self.mode = mode
        self.tuning = tuning
        self.enabledCues = enabledCues
    }

    mutating func reset() {
        states = [:]
        framesObserved = 0
        denyEvidenceFrames = 0
    }

    /// Firing is latched: a cue that has fired stays fired for the rest of the scan.
    mutating func observe(_ readings: [LivenessCue: CueReading]) -> LivenessSnapshot {
        framesObserved += 1

        // Counted before the per-cue loop so it reflects this frame's readings regardless of
        // whether any cue crossed its fire level — the question is "did a spoof detector get to
        // look", not "did it convict".
        let denyCueReported = LivenessCue.allCases.contains { cue in
            cue.role == .deny && enabledCues.contains(cue) && (readings[cue] ?? .none).confidence > 0
        }
        if denyCueReported { denyEvidenceFrames += 1 }

        for cue in LivenessCue.allCases {
            var state = states[cue] ?? LivenessCueState()
            let reading = readings[cue] ?? .none
            state.reading = reading
            if reading.confidence > 0, reading.level >= tuning.level(for: cue) {
                state.framesCounted += 1
                state.lastCountedFrame = framesObserved
                if state.framesCounted >= tuning.frames(for: cue) {
                    state.hasFired = true
                }
            }
            states[cue] = state
        }

        return LivenessSnapshot(
            decision: currentDecision(), mode: mode, cueStates: states, frameCount: framesObserved
        )
    }

    /// Deny is evaluated first and is unconditional — it overrides any confirmation already reached.
    private func currentDecision() -> LivenessDecision {
        for cue in LivenessCue.allCases
        where cue.role == .deny && enabledCues.contains(cue) && (states[cue]?.hasFired ?? false) {
            return .denied(by: cue)
        }

        if mode == .light {
            // Both conditions, not just the frame count: enough frames for the deny cues to have
            // accumulated a firing streak, AND enough frames on which they actually had data to
            // judge. Staying `.pending` is not a failure — the scan keeps running until either a
            // deny cue fires or both budgets are met.
            guard framesObserved >= tuning.lightModeMinimumFrames,
                  denyEvidenceFrames >= tuning.lightModeMinimumDenyEvidenceFrames
            else { return .pending }
            return .confirmed(by: nil)
        }

        // Confirm cues expire; deny cues above do not. See `LivenessTuning.confirmFreshnessFrames`
        // for why the asymmetry is deliberate rather than an oversight.
        for cue in LivenessCue.allCases
        where cue.role == .confirm && enabledCues.contains(cue) && isFreshlyConfirmed(cue) {
            return .confirmed(by: cue)
        }

        return .pending
    }

    /// Whether `cue` has fired *and* its evidence is recent enough to still vouch for the face
    /// currently in frame.
    private func isFreshlyConfirmed(_ cue: LivenessCue) -> Bool {
        guard let state = states[cue], state.hasFired else { return false }
        return framesObserved - state.lastCountedFrame <= tuning.confirmFreshnessFrames
    }
}

/// Turns a rolling window into this frame's reading for every cue. Deny cues read only
/// the latest frame (per-frame appearance); confirm cues read the whole window (cross-frame motion).
nonisolated enum LivenessCues {
    nonisolated static func readings(
        window: [LivenessFrame], geometry: GeometryLivenessResult
    ) -> [LivenessCue: CueReading] {
        [
            .glossGlare: glossGlare(window.last),
            .deviceDetected: deviceDetected(window.last),
            .flatVs3D: geometry.planarReading,
            .depthPose: LivenessScoring.poseDepthConsistency(window),
            .blink: LivenessScoring.blinkDynamics(window),
        ]
    }

    /// Skin gives many small scattered specular points; glass gives one big
    /// flat blob. `specularFraction` alone would fire on a bright forehead,
    /// so it's gated by how concentrated that glare is.
    nonisolated static func glossGlare(_ frame: LivenessFrame?) -> CueReading {
        guard let glare = frame?.glare else { return .none }
        let fractionScore = ramp(glare.specularFraction, floor: 0.01, ceiling: 0.08)
        let clusterFactor = ramp(glare.specularClusterRatio, floor: 0.3, ceiling: 1.0)
        let level = fractionScore * (0.3 + 0.7 * clusterFactor)
        // Below ~50 native px of face there isn't enough detail to tell a
        // glare blob from a bright patch; ramps to full trust by ~130px.
        let confidence = ramp(Float(glare.cropPixelWidth), floor: 50, ceiling: 130)
        return CueReading(level: level, confidence: confidence)
    }

    /// Raw overlap fraction from `DeviceBezelDetector`, used directly rather than re-scaled.
    nonisolated static func deviceDetected(_ frame: LivenessFrame?) -> CueReading {
        guard let overlap = frame?.deviceOverlapFraction else { return .none }
        return CueReading(level: Float(min(max(overlap, 0), 1)), confidence: 1)
    }

    nonisolated static func ramp(_ value: Float, floor: Float, ceiling: Float) -> Float {
        min(max((value - floor) / max(ceiling - floor, 0.0001), 0), 1)
    }
}
