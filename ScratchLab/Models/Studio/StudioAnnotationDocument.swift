import Foundation

// MARK: - StudioAnnotationKind

/// Neutral, observational tag for a single Studio annotation. The
/// vocabulary is deliberately small and devoid of grading verbs —
/// instructor / student-side surfaces never automate musical
/// interpretation per PROFILE.md and the Phase E silence rule.
///
/// Raw values are persisted as lowercase strings. Strict decoding:
/// an unknown raw value throws a `DecodingError`, never silently
/// falls back to a sentinel.
enum StudioAnnotationKind: String, Codable, Equatable, CaseIterable, Sendable {
    case note
    case timing
    case phrase
    case releaseTail
    case question
}

// MARK: - StudioAnnotation

/// One annotation inside a `StudioAnnotationDocument`. Pure value
/// type; no clock, no I/O, no UI.
///
/// `startTime` is the position on the take's timeline where the
/// annotation is anchored. `endTime` is `nil` for point-in-time
/// annotations and otherwise marks the end of a span. `note` is a
/// free-text string — neutral phrasing is enforced by code review
/// per the silence rule, not by this type.
///
/// **Invariants enforced at construction and decode time:**
///
/// - `startTime` is finite and ≥ 0.
/// - `endTime`, when present, is finite and ≥ `startTime`.
struct StudioAnnotation: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let kind: StudioAnnotationKind
    let note: String
    let createdBy: String?
    let createdAt: Date

    init?(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        kind: StudioAnnotationKind,
        note: String,
        createdBy: String? = nil,
        createdAt: Date
    ) {
        guard StudioAnnotation.isValidTime(startTime) else { return nil }
        if let endTime {
            guard StudioAnnotation.isValidTime(endTime) else { return nil }
            guard endTime >= startTime else { return nil }
        }
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.kind = kind
        self.note = note
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, kind, note, createdBy, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        guard StudioAnnotation.isValidTime(startTime) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startTime,
                in: container,
                debugDescription: "startTime must be finite and ≥ 0, got \(startTime)"
            )
        }
        let endTime = try container.decodeIfPresent(TimeInterval.self, forKey: .endTime)
        if let endTime {
            guard StudioAnnotation.isValidTime(endTime), endTime >= startTime else {
                throw DecodingError.dataCorruptedError(
                    forKey: .endTime,
                    in: container,
                    debugDescription: "endTime must be finite, ≥ 0, and ≥ startTime"
                )
            }
        }
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.kind = try container.decode(StudioAnnotationKind.self, forKey: .kind)
        self.note = try container.decode(String.self, forKey: .note)
        self.createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    private static func isValidTime(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0
    }
}

// MARK: - StudioAnnotationDocument

/// Additive sidecar that pairs with — but never modifies — a Phase D
/// session sidecar (`scratchlab_local_recording_sidecar_v1`). Carries
/// zero or more `StudioAnnotation`s authored from Studio Mode.
///
/// **Additive-sidecar discipline (Phase D principle):** Studio reads
/// the original session sidecar verbatim; this document is written to
/// its own file next to the original, never bundled into the original
/// sidecar's bytes. The original sidecar's `schemaVersion` string is
/// untouched.
///
/// **Sacred-original rule:** every method on this type and its
/// `Codec` peer is pure and operates only on this type's own
/// `Codable` representation. Nothing here can mutate the original
/// `LocalRecordingSidecar`.
struct StudioAnnotationDocument: Codable, Equatable, Sendable {

    /// Stable schema version string for the annotation sidecar.
    /// Changing this requires a new schema version, never an in-place
    /// edit. Phase D doc reserves this string for the additive
    /// annotation sidecar — D-A3.
    static let currentSchemaVersion = "scratchlab_studio_annotations_v1"

    let schemaVersion: String
    let sessionID: String
    let takeID: String?
    let createdAt: Date
    let updatedAt: Date
    let annotations: [StudioAnnotation]

    init(
        schemaVersion: String = StudioAnnotationDocument.currentSchemaVersion,
        sessionID: String,
        takeID: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        annotations: [StudioAnnotation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.takeID = takeID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.annotations = annotations
    }

    /// Convenience constructor for an empty document at a given clock
    /// instant. Pure factory — never reads the system clock itself so
    /// determinism stays under the caller's control.
    static func empty(
        sessionID: String,
        takeID: String? = nil,
        at instant: Date
    ) -> StudioAnnotationDocument {
        StudioAnnotationDocument(
            sessionID: sessionID,
            takeID: takeID,
            createdAt: instant,
            updatedAt: instant,
            annotations: []
        )
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionID, takeID, createdAt, updatedAt, annotations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.takeID = try container.decodeIfPresent(String.self, forKey: .takeID)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.annotations = try container.decodeIfPresent(
            [StudioAnnotation].self,
            forKey: .annotations
        ) ?? []
    }
}

// MARK: - StudioAnnotationSidecarCodec

/// Pure read/write helpers for `StudioAnnotationDocument`. Uses
/// deterministic JSON output (`iso8601` dates + sorted keys + pretty
/// printing) so the same logical document produces byte-identical
/// bytes across runs — the sidecar round-trip gate the Phase E
/// instructor exchange ultimately rests on.
///
/// **macOS-side IO discipline:** the codec is pure file I/O. No
/// cloud, no account, no roster, no instructor UI. Read / write APIs
/// are surface-agnostic so a future Phase E exchange workflow can
/// reuse them unchanged.
enum StudioAnnotationSidecarCodec {

    /// Deterministic encoder used for sidecar writes. Public so tests
    /// can re-use it when comparing byte-level output.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Deterministic decoder peer of `encoder`.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Encodes the document to deterministic JSON bytes.
    static func encode(_ document: StudioAnnotationDocument) throws -> Data {
        try encoder.encode(document)
    }

    /// Decodes JSON bytes into a `StudioAnnotationDocument`. Strict —
    /// rejects malformed or invalid invariants per the type's own
    /// Codable contract.
    static func decode(_ data: Data) throws -> StudioAnnotationDocument {
        try decoder.decode(StudioAnnotationDocument.self, from: data)
    }

    /// Reads the annotation sidecar at `url`. Throws on file-system
    /// failure or invalid contents.
    static func read(from url: URL) throws -> StudioAnnotationDocument {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    /// Writes the document to `url` with the deterministic encoder.
    /// Atomic write so a partially-written file never replaces the
    /// existing sidecar on disk.
    static func write(_ document: StudioAnnotationDocument, to url: URL) throws {
        let data = try encode(document)
        try data.write(to: url, options: [.atomic])
    }
}
