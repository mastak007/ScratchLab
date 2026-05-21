import Foundation

// Call-and-response timing manifest for the practice Demo mode.
//
// A `PracticeReelTimeline` describes one demo-audio file as an ordered list of
// segments: `demo` segments are reference examples the app performs, `copy`
// segments are the beat-only windows where the user imitates the example just
// heard. Each segment is a typed span on the audio's absolute timeline; the
// flat `strokes` list places every reference stroke on that same timeline.
//
// This is the data foundation for the call-and-response Demo redesign: the
// manifest is the single source of truth for the demo/copy timeline that the
// (future) notation reel renders and that a (future) user-attempt overlay will
// be lined up against. The manifest is authored alongside its audio file so the
// two stay frame-aligned.
//
// Scope: pure model + JSON loader + validator. Decoupled from `ScratchNotation`
// so the schema stands alone — it reuses only the small shared stroke-vocabulary
// enums. Touches no capture, export, scoring, or ML code, and is isolated to the
// non-scored Demo mode.

// MARK: - Segment

/// Whether a segment is a reference example the app performs (`demo`) or a
/// copy window the user imitates (`copy`).
enum ReelSegmentKind: String, Decodable, Equatable, Sendable {
    case demo
    case copy
}

/// A typed time span on the audio timeline — a demo example or a copy window.
/// Times are seconds in the paired audio file.
struct ReelSegment: Decodable, Equatable, Sendable {
    let kind: ReelSegmentKind
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Optional display label, e.g. "Demo 1" or "Your turn".
    let label: String?

    var duration: TimeInterval { max(0, endTime - startTime) }

    /// Half-open containment: `[startTime, endTime)`.
    func contains(time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }
}

// MARK: - Stroke

/// One reference stroke on the manifest's absolute audio timeline. Mirrors a
/// `ScratchNotation.Stroke` but is a standalone schema type so the manifest
/// does not depend on the notation model; it reuses only the shared
/// stroke-vocabulary enums.
struct ReelStroke: Decodable, Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let direction: ScratchNotationDirection
    let speedClassification: ScratchNotationSpeedClassification
    let faderState: ScratchNotationFaderState

    var duration: TimeInterval { max(0, endTime - startTime) }
}

// MARK: - Timeline

/// A decoded call-and-response demo manifest: the ordered demo/copy segment
/// timeline plus the reference strokes, paired with one audio file.
struct PracticeReelTimeline: Decodable, Equatable, Sendable {
    let version: Int
    /// Stable identifier for this manifest revision.
    let timelineID: String
    /// The scratch this reel teaches, e.g. "baby".
    let scratchID: String
    /// Bundled audio file this manifest is authored against.
    let audioFile: String
    /// Authoring-declared duration of `audioFile`, in seconds. Cross-checked
    /// against the real file by `audioDurationIssue(actualDuration:)`.
    let audioDuration: TimeInterval
    /// Reference-beat tempo, when the audio carries a beat. `nil` for the
    /// no-beat interim asset.
    let bpm: Double?
    let segments: [ReelSegment]
    let strokes: [ReelStroke]

    /// The only manifest schema version this build understands.
    static let supportedVersion = 1

    /// Bundled manifest name for the Baby Scratch reel.
    static let babyReelManifestName = "baby_reel"

    var demoSegments: [ReelSegment] { segments.filter { $0.kind == .demo } }
    var copySegments: [ReelSegment] { segments.filter { $0.kind == .copy } }

    /// Strokes whose start falls within `segment` (half-open `[start, end)`).
    func strokes(in segment: ReelSegment) -> [ReelStroke] {
        strokes.filter { $0.startTime >= segment.startTime && $0.startTime < segment.endTime }
    }

    /// The segment active at `time`, if any.
    func segment(at time: TimeInterval) -> ReelSegment? {
        segments.first { $0.contains(time: time) }
    }

    /// The segment that follows `time`'s segment — the next one to begin.
    func segmentAfter(time: TimeInterval) -> ReelSegment? {
        segments.first { $0.startTime > time }
    }

    /// Reference ("ghost") strokes to draw inside each copy window.
    ///
    /// A copy segment carries no strokes of its own — it is the silent window
    /// the user fills. To keep the reel from showing dead space there, the
    /// renderer echoes the strokes of the demo segment the copy window answers:
    /// the nearest preceding demo segment, time-shifted forward so its rhythm
    /// lines up with the copy window. Ghosts that would fall outside the copy
    /// window (a copy window shorter than its demo) are dropped.
    ///
    /// Pure and derived — the manifest's own `strokes` are never mutated. These
    /// are computed targets the Demo reel draws as outlines, distinct from the
    /// solid reference strokes inside demo segments.
    func derivedCopyGhostStrokes() -> [ReelStroke] {
        let epsilon = 1e-6
        var ghosts: [ReelStroke] = []
        for copySegment in segments where copySegment.kind == .copy {
            // The demo segment this copy window answers: the last demo segment
            // that begins before it.
            guard let source = segments.last(where: {
                $0.kind == .demo && $0.startTime < copySegment.startTime
            }) else { continue }
            let shift = copySegment.startTime - source.startTime
            for stroke in strokes(in: source) {
                let start = stroke.startTime + shift
                let end = stroke.endTime + shift
                guard start >= copySegment.startTime - epsilon,
                      end <= copySegment.endTime + epsilon else { continue }
                ghosts.append(ReelStroke(
                    startTime: start,
                    endTime: end,
                    direction: stroke.direction,
                    speedClassification: stroke.speedClassification,
                    faderState: stroke.faderState))
            }
        }
        return ghosts
    }
}

// MARK: - Future audio assets
//
// The bundled interim asset is `baby_noBeat.wav` — a dry, beat-free Baby
// Scratch take — described by `baby_reel.json` with `bpm` omitted. The
// call-and-response model is already shaped for the planned over-beat asset,
// so swapping it in is a manifest change with no code change:
//
//   • Author one audio file alternating <baby scratch over beat> and
//     <beat-only copy break>, e.g. demo / copy / demo / copy.
//   • Point a manifest's `audioFile` at it and set `bpm` to the beat tempo —
//     the Demo reel then renders a beat grid automatically.
//   • Mark each "scratch over beat" span as a `demo` segment and each
//     "beat-only" span as a `copy` segment; place reference `strokes` only
//     inside the demo segments (copy windows derive their ghost targets via
//     `derivedCopyGhostStrokes()`).
//   • Keep `audioDuration` frame-accurate; `audioDurationIssue(actualDuration:)`
//     cross-checks it against the real file.
//
// The loader resolves audio purely from the manifest's `audioFile` field — no
// filename is hardcoded — so a new asset needs only a new or edited manifest.

// MARK: - Loading

extension PracticeReelTimeline {

    /// Decodes a manifest from raw JSON data.
    static func decoded(from data: Data) throws -> PracticeReelTimeline {
        try JSONDecoder().decode(PracticeReelTimeline.self, from: data)
    }

    /// Resolves a bundled manifest JSON URL. Searches the `CoachDemoAudio`
    /// resource folder (where the paired audio lives), then the bundle root.
    static func bundledManifestURL(named name: String, in bundle: Bundle = .main) -> URL? {
        let base = (name as NSString).deletingPathExtension
        return bundle.url(forResource: base, withExtension: "json", subdirectory: "CoachDemoAudio")
            ?? bundle.url(forResource: base, withExtension: "json")
    }

    /// Loads and decodes a bundled manifest. Returns `nil` when the manifest is
    /// absent or malformed — Demo mode then falls back to the legacy
    /// single-file demo-audio path.
    static func loadBundled(named name: String, in bundle: Bundle = .main) -> PracticeReelTimeline? {
        guard let url = bundledManifestURL(named: name, in: bundle),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoded(from: data)
    }
}

// MARK: - Validation

/// One problem found while validating a `PracticeReelTimeline`.
struct ReelTimelineIssue: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        /// Makes the manifest unusable — Demo mode must not drive from it.
        case error
        /// An authoring smell; the manifest still loads.
        case warning
    }

    let severity: Severity
    let message: String
}

extension PracticeReelTimeline {

    /// Internal-consistency check. `error` issues make the manifest unusable;
    /// `warning` issues flag authoring smells that still load. Pure: it reads
    /// only the manifest, never the audio file (see `audioDurationIssue`).
    func validate() -> [ReelTimelineIssue] {
        var issues: [ReelTimelineIssue] = []
        let epsilon = 1e-6

        func error(_ message: String) {
            issues.append(ReelTimelineIssue(severity: .error, message: message))
        }
        func warning(_ message: String) {
            issues.append(ReelTimelineIssue(severity: .warning, message: message))
        }

        if version != Self.supportedVersion {
            error("Unsupported manifest version \(version); this build expects \(Self.supportedVersion).")
        }
        if audioFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("Manifest declares no audioFile.")
        }
        if audioDuration <= 0 {
            error("audioDuration must be positive (got \(audioDuration)).")
        }
        if segments.isEmpty {
            error("Manifest has no segments.")
        }

        // Per-segment bounds.
        for (index, segment) in segments.enumerated() {
            if segment.startTime < -epsilon {
                error("Segment \(index) starts before zero (\(segment.startTime)).")
            }
            if segment.endTime <= segment.startTime + epsilon {
                error("Segment \(index) has a non-positive duration (\(segment.startTime)–\(segment.endTime)).")
            }
            if segment.endTime > audioDuration + epsilon {
                error("Segment \(index) ends past audioDuration (\(segment.endTime) > \(audioDuration)).")
            }
        }

        // Segment ordering and overlap.
        if segments.count > 1 {
            for index in 1..<segments.count {
                let previous = segments[index - 1]
                let current = segments[index]
                if current.startTime < previous.startTime - epsilon {
                    error("Segment \(index) is out of start-time order.")
                } else if current.startTime < previous.endTime - epsilon {
                    error("Segment \(index) overlaps segment \(index - 1).")
                }
            }
        }

        // Per-stroke bounds.
        for (index, stroke) in strokes.enumerated() {
            if stroke.startTime < -epsilon {
                error("Stroke \(index) starts before zero (\(stroke.startTime)).")
            }
            if stroke.endTime <= stroke.startTime + epsilon {
                error("Stroke \(index) has a non-positive duration.")
            }
            if stroke.endTime > audioDuration + epsilon {
                error("Stroke \(index) ends past audioDuration (\(stroke.endTime) > \(audioDuration)).")
            }
        }

        // Stroke ordering.
        if strokes.count > 1 {
            for index in 1..<strokes.count where strokes[index].startTime < strokes[index - 1].startTime - epsilon {
                error("Stroke \(index) is out of start-time order.")
            }
        }

        // Authoring warnings.
        if let first = segments.first, first.kind != .demo {
            warning("First segment is a copy window; a call-and-response reel usually opens with a demo example.")
        }
        if !segments.isEmpty, copySegments.isEmpty {
            warning("Manifest has no copy windows; the reel will give the user nothing to imitate.")
        }
        for (index, stroke) in strokes.enumerated()
        where segment(at: stroke.startTime) == nil {
            warning("Stroke \(index) at \(stroke.startTime)s lies outside every segment.")
        }

        return issues
    }

    /// The `error`-severity subset of `validate()`.
    var validationErrors: [ReelTimelineIssue] {
        validate().filter { $0.severity == .error }
    }

    /// Whether the manifest is safe to drive Demo mode from (no errors).
    var isValid: Bool { validationErrors.isEmpty }

    /// Cross-checks the declared `audioDuration` against the real decoded
    /// duration of the paired audio file. Pure — the caller measures the file
    /// and passes the result in. Returns `nil` when they agree.
    func audioDurationIssue(
        actualDuration: TimeInterval,
        tolerance: TimeInterval = 0.05
    ) -> ReelTimelineIssue? {
        guard abs(actualDuration - audioDuration) > tolerance else { return nil }
        return ReelTimelineIssue(
            severity: .error,
            message: "audioDuration \(audioDuration)s disagrees with the measured \(audioFile) duration (\(actualDuration)s)."
        )
    }
}
