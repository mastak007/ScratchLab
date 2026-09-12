import Foundation

/// Local review state, separate from capture sidecars and approved packages.
/// Files remain in the capture library; saving a draft never approves a take.
struct ReferenceSavedDraft: Codable, Equatable, Sendable, Identifiable {
    static let version = "scratchlab_saved_reference_draft_v1"
    let schemaVersion: String
    let savedAt: Date
    let mediaURL: URL
    let sidecarURL: URL
    let evidence: ReferenceTakeEvidence
    let autoDetectedTechnique: ReferenceTechnique?
    let sourceBinding: ReferenceTearEvidenceSourceBinding
    let tearReview: ReferenceTearSegmentationReview
    let projection: ReferenceTearCanonicalProjection
    let performedLimitations: [String: [CanonicalTearComparison.UnavailableReason]]
    let reviewNotes: String
    let artifacts: [Artifact]

    var id: String { evidence.metadata.referenceTakeID }

    struct Artifact: Codable, Equatable, Sendable {
        let url: URL
        let sha256: String
    }
}

struct ReferenceSavedDraftSummary: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let savedAt: Date
    let status: String
}

enum ReferenceDraftStoreError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): return "Saved draft: \(detail)" }
    }
}

/// Called only by the authoring worker's serial queue. Same storage contract
/// can be used by an iOS authoring host without duplicating review semantics.
final class ReferenceDraftStore {
    let directory: URL
    private var cached: [String: ReferenceSavedDraft] = [:]

    private struct Envelope: Codable {
        let payload: Data
        let sha256: String
    }

    init(directory: URL) { self.directory = directory }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScratchLab/ReferenceDrafts", isDirectory: true)
    }

    func refresh() throws -> [ReferenceSavedDraftSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { cached = [:]; return [] }
        var loaded: [String: ReferenceSavedDraft] = [:]
        var failures: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            do {
                let draft = try decode(url)
                guard url.lastPathComponent == fileURL(for: draft.id).lastPathComponent, loaded[draft.id] == nil else {
                    throw ReferenceDraftStoreError.invalid("duplicate or mismatched draft identity")
                }
                loaded[draft.id] = draft
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        cached = loaded
        if !failures.isEmpty { throw ReferenceDraftStoreError.invalid(failures.joined(separator: "\n")) }
        return summaries
    }

    var summaries: [ReferenceSavedDraftSummary] {
        cached.values.map { draft in
            let m = draft.evidence.metadata
            return ReferenceSavedDraftSummary(id: draft.id,
                title: "\(m.performerName) · \(m.technique.displayName) · \(m.bpm) BPM · Take \(m.takeNumber)",
                savedAt: draft.savedAt,
                status: m.lifecycleState == .rejected ? "Rejected" : (m.lifecycleState == .approvedCanonical ? "Approved" :
                    (m.captureIntent?.isMovementCheck == true ? "Movement check" : "Awaiting review")))
        }.sorted { $0.savedAt > $1.savedAt }
    }

    @discardableResult
    func save(take: ReferenceAuthoringTake, mediaURL: URL, reviewNotes: String) throws -> ReferenceSavedDraft {
        guard let sidecarURL = take.rawSidecarURL, let binding = take.tearEvidenceSourceBinding,
              mediaURL.isFileURL, sidecarURL.isFileURL,
              take.id == take.tearReview.referenceTakeID,
              mediaURL.lastPathComponent == take.evidence.actualMediaFileName,
              sidecarURL.lastPathComponent == binding.rawSidecarFileName,
              sidecarURL.deletingLastPathComponent() == mediaURL.deletingLastPathComponent() else {
            throw ReferenceDraftStoreError.invalid("the finalized take has no matching media and sidecar identity")
        }
        let old: ReferenceSavedDraft?
        if let existing = cached[take.id] { old = existing }
        else if FileManager.default.fileExists(atPath: fileURL(for: take.id).path) {
            old = try decode(fileURL(for: take.id))
        } else { old = nil }
        if let old {
            guard old.mediaURL == mediaURL, old.sidecarURL == sidecarURL,
                  old.sourceBinding.capturedSessionID == binding.capturedSessionID,
                  old.sourceBinding.capturedTakeID == binding.capturedTakeID else {
                throw ReferenceDraftStoreError.invalid("the draft ID already belongs to another recording")
            }
            if old.evidence == take.evidence, old.tearReview == take.tearReview,
               old.sourceBinding == binding, old.reviewNotes == reviewNotes,
               old.projection == take.tearProjection, old.performedLimitations == take.tearPerformedLimitations,
               FileManager.default.fileExists(atPath: fileURL(for: take.id).path) {
                cached[old.id] = old
                return old
            }
        }
        // Retain the original media fingerprints across all review edits.
        let artifacts = try old?.artifacts ?? [mediaURL, mediaURL.deletingPathExtension().appendingPathExtension("wav")]
            .map { ReferenceSavedDraft.Artifact(url: $0, sha256: try Self.hash($0)) }
        let draft = ReferenceSavedDraft(schemaVersion: ReferenceSavedDraft.version, savedAt: Date(),
            mediaURL: mediaURL, sidecarURL: sidecarURL, evidence: take.evidence,
            autoDetectedTechnique: take.autoDetectedTechnique, sourceBinding: binding,
            tearReview: take.tearReview, projection: take.tearProjection,
            performedLimitations: take.tearPerformedLimitations, reviewNotes: reviewNotes, artifacts: artifacts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(draft)
        let data = try encoder.encode(Envelope(payload: payload, sha256: ReferencePackageIO.sha256Hex(payload)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: draft.id), options: .atomic)
        cached[draft.id] = draft
        return draft
    }

    func load(id: String) throws -> ReferenceSavedDraft {
        let draft = try decode(fileURL(for: id))
        guard draft.id == id else { throw ReferenceDraftStoreError.invalid("recording identity mismatch") }
        for artifact in draft.artifacts {
            guard try Self.hash(artifact.url) == artifact.sha256 else {
                throw ReferenceDraftStoreError.invalid("\(artifact.url.lastPathComponent) changed after saving")
            }
        }
        cached[id] = draft
        return draft
    }

    func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(ReferencePackageIO.sha256Hex(Data(id.utf8)) + ".json")
    }

    private func decode(_ url: URL) throws -> ReferenceSavedDraft {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
        guard ReferencePackageIO.sha256Hex(envelope.payload) == envelope.sha256 else {
            throw ReferenceDraftStoreError.invalid("review data failed its integrity check")
        }
        let draft = try decoder.decode(ReferenceSavedDraft.self, from: envelope.payload)
        guard draft.schemaVersion == ReferenceSavedDraft.version,
              draft.id == draft.tearReview.referenceTakeID,
              draft.mediaURL.isFileURL, draft.sidecarURL.isFileURL,
              draft.mediaURL.lastPathComponent == draft.evidence.actualMediaFileName,
              draft.sidecarURL.lastPathComponent == draft.sourceBinding.rawSidecarFileName,
              draft.mediaURL.deletingLastPathComponent() == draft.sidecarURL.deletingLastPathComponent(),
              draft.artifacts.count == 2,
              Set(draft.artifacts.map(\.url)) == Set([draft.mediaURL,
                draft.mediaURL.deletingPathExtension().appendingPathExtension("wav")]) else {
            throw ReferenceDraftStoreError.invalid("unsupported version or inconsistent recording identity")
        }
        // Reuse the existing strict companion validator, including correction
        // provenance and projection checks. No decoder bypass on reopening.
        let companion = try ReferenceTearEvidenceCodec.encode(sourceBinding: draft.sourceBinding,
            review: draft.tearReview, projection: draft.projection, performedLimitations: draft.performedLimitations)
        _ = try ReferenceTearEvidenceCodec.decode(companion, expectedSource: draft.sourceBinding,
            expectedReferenceTakeID: draft.id)
        return draft
    }

    private static func hash(_ url: URL) throws -> String {
        guard url.isFileURL else { throw ReferenceDraftStoreError.invalid("recording must be a local file") }
        do { return ReferencePackageIO.sha256Hex(try Data(contentsOf: url, options: .mappedIfSafe)) }
        catch { throw ReferenceDraftStoreError.invalid("\(url.lastPathComponent) is missing or unreadable") }
    }
}
