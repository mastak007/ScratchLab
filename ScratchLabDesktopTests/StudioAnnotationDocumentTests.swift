import XCTest
@testable import ScratchLab

/// Phase D-A3 — locks the contract of `StudioAnnotationDocument` /
/// `StudioAnnotationSidecarCodec`: additive sidecar, deterministic
/// JSON round-trip, original local-recording sidecar bytes never
/// touched, no schema bumps to any other persisted contract.
final class StudioAnnotationDocumentTests: XCTestCase {

    // MARK: - Helpers

    private func fixedInstant(_ offset: TimeInterval = 0) -> Date {
        // 2026-01-01T00:00:00Z — deterministic clock for all fixtures.
        Date(timeIntervalSince1970: 1767225600 + offset)
    }

    private func annotation(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        startTime: TimeInterval = 0.5,
        endTime: TimeInterval? = nil,
        kind: StudioAnnotationKind = .note,
        note: String = "Steady pull-back motion across the bar.",
        createdBy: String? = nil
    ) -> StudioAnnotation {
        guard let value = StudioAnnotation(
            id: id,
            startTime: startTime,
            endTime: endTime,
            kind: kind,
            note: note,
            createdBy: createdBy,
            createdAt: fixedInstant()
        ) else {
            XCTFail("StudioAnnotation init unexpectedly rejected")
            return StudioAnnotation(
                id: id,
                startTime: 0, endTime: nil, kind: kind,
                note: note, createdBy: createdBy,
                createdAt: fixedInstant()
            )!
        }
        return value
    }

    // MARK: - 1. Default schemaVersion

    func testDefaultDocumentUsesSchemaVersion() {
        let document = StudioAnnotationDocument.empty(
            sessionID: "session-1",
            takeID: "take-1",
            at: fixedInstant()
        )
        XCTAssertEqual(document.schemaVersion, "scratchlab_studio_annotations_v1")
        XCTAssertEqual(
            StudioAnnotationDocument.currentSchemaVersion,
            "scratchlab_studio_annotations_v1"
        )
    }

    // MARK: - 2. Empty document round-trip

    func testEmptyDocumentRoundTripsLosslessly() throws {
        let document = StudioAnnotationDocument.empty(
            sessionID: "session-2",
            takeID: nil,
            at: fixedInstant()
        )
        let bytes = try StudioAnnotationSidecarCodec.encode(document)
        let decoded = try StudioAnnotationSidecarCodec.decode(bytes)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.annotations, [])
        XCTAssertNil(decoded.takeID)
    }

    func testEmptyDocumentEncodesDeterministically() throws {
        // Same logical document → byte-identical encoded bytes across
        // calls. Guards the sorted-keys + iso8601 encoder contract.
        let document = StudioAnnotationDocument.empty(
            sessionID: "session-2",
            takeID: nil,
            at: fixedInstant()
        )
        let first = try StudioAnnotationSidecarCodec.encode(document)
        for _ in 0..<19 {
            let next = try StudioAnnotationSidecarCodec.encode(document)
            XCTAssertEqual(next, first)
        }
    }

    // MARK: - 3. Annotation with time range round-trips

    func testAnnotationWithTimeRangeRoundTrips() throws {
        let item = annotation(startTime: 1.25, endTime: 2.75, kind: .timing)
        let document = StudioAnnotationDocument(
            sessionID: "session-3",
            takeID: "take-1",
            createdAt: fixedInstant(),
            updatedAt: fixedInstant(),
            annotations: [item]
        )
        let bytes = try StudioAnnotationSidecarCodec.encode(document)
        let decoded = try StudioAnnotationSidecarCodec.decode(bytes)
        XCTAssertEqual(decoded.annotations.count, 1)
        XCTAssertEqual(decoded.annotations[0].startTime, 1.25)
        XCTAssertEqual(decoded.annotations[0].endTime, 2.75)
        XCTAssertEqual(decoded.annotations[0].kind, .timing)
    }

    func testPointInTimeAnnotationRoundTripsWithNilEnd() throws {
        let item = annotation(startTime: 3.5, endTime: nil, kind: .phrase)
        let document = StudioAnnotationDocument(
            sessionID: "session-3b",
            createdAt: fixedInstant(),
            updatedAt: fixedInstant(),
            annotations: [item]
        )
        let bytes = try StudioAnnotationSidecarCodec.encode(document)
        let decoded = try StudioAnnotationSidecarCodec.decode(bytes)
        XCTAssertNil(decoded.annotations[0].endTime)
    }

    // MARK: - 4. Multiple annotations preserve order

    func testMultipleAnnotationsPreserveInsertionOrder() throws {
        let items = (0..<5).map { index in
            annotation(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!,
                startTime: Double(index) * 0.5,
                kind: .note,
                note: "Annotation \(index)"
            )
        }
        let document = StudioAnnotationDocument(
            sessionID: "session-4",
            createdAt: fixedInstant(),
            updatedAt: fixedInstant(),
            annotations: items
        )
        let bytes = try StudioAnnotationSidecarCodec.encode(document)
        let decoded = try StudioAnnotationSidecarCodec.decode(bytes)
        XCTAssertEqual(decoded.annotations.map(\.note), items.map(\.note))
        XCTAssertEqual(decoded.annotations.map(\.startTime), items.map(\.startTime))
    }

    // MARK: - 5. Unknown / new optional fields don't break decoding

    func testMissingOptionalFieldsDecodeCleanly() throws {
        // Hand-rolled JSON omitting `takeID` and `annotations`. The
        // decoder must tolerate the missing optional and the missing
        // (empty) annotations array.
        let json = """
        {
          "createdAt": "2026-01-01T00:00:00Z",
          "schemaVersion": "scratchlab_studio_annotations_v1",
          "sessionID": "session-5",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoded = try StudioAnnotationSidecarCodec.decode(json)
        XCTAssertNil(decoded.takeID)
        XCTAssertEqual(decoded.annotations, [])
        XCTAssertEqual(decoded.schemaVersion, "scratchlab_studio_annotations_v1")
    }

    func testMissingAnnotationCreatedByDecodesAsNil() throws {
        // `createdBy` is optional. A JSON document omitting it must
        // decode with `createdBy == nil`.
        let json = """
        {
          "createdAt": "2026-01-01T00:00:00Z",
          "schemaVersion": "scratchlab_studio_annotations_v1",
          "sessionID": "session-5b",
          "updatedAt": "2026-01-01T00:00:00Z",
          "annotations": [
            {
              "createdAt": "2026-01-01T00:00:00Z",
              "id": "00000000-0000-0000-0000-000000000099",
              "kind": "note",
              "note": "Try the second phrase a touch slower.",
              "startTime": 1.5
            }
          ]
        }
        """.data(using: .utf8)!
        let decoded = try StudioAnnotationSidecarCodec.decode(json)
        XCTAssertEqual(decoded.annotations.count, 1)
        XCTAssertNil(decoded.annotations[0].createdBy)
        XCTAssertNil(decoded.annotations[0].endTime)
    }

    // MARK: - 6. Original session sidecar bytes are untouched

    func testAnnotationDocumentDoesNotCarrySessionSidecarSchemaString() throws {
        // Sacred-original gate: the annotation document must never
        // contain the original LocalRecordingSidecar schema string. If
        // it did, an instructor reading the annotation file might
        // mistake it for the session sidecar itself.
        let document = StudioAnnotationDocument.empty(
            sessionID: "session-6",
            takeID: "take-1",
            at: fixedInstant()
        )
        let bytes = try StudioAnnotationSidecarCodec.encode(document)
        let json = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("scratchlab_local_recording_sidecar_v1"))
        XCTAssertTrue(json.contains("scratchlab_studio_annotations_v1"))
    }

    func testWritingAnnotationSidecarDoesNotTouchSiblingFiles() throws {
        // Write an annotation sidecar into a temp directory that also
        // contains a fake "original" file. Confirm the original's
        // bytes are byte-identical before and after the annotation
        // write — the codec only touches its own URL.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchlab-da3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalURL = tempDir.appendingPathComponent("session.json")
        let originalBytes = Data("PRETEND_ORIGINAL_SIDECAR_BYTES".utf8)
        try originalBytes.write(to: originalURL)

        let annotationURL = tempDir.appendingPathComponent("session.studio_annotations.json")
        let document = StudioAnnotationDocument.empty(
            sessionID: "session-6b",
            takeID: nil,
            at: fixedInstant()
        )
        try StudioAnnotationSidecarCodec.write(document, to: annotationURL)

        let originalAfter = try Data(contentsOf: originalURL)
        XCTAssertEqual(originalAfter, originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: annotationURL.path))
    }

    // MARK: - 7. No export schema string changes

    func testAnnotationDocumentSchemaIsDistinctFromExportSchemas() {
        // Sentinel test that ties D-A3 to the unchanged-export
        // contract. Listing each known schema by hand makes the
        // failure mode loud if anyone bumps one in a future slice.
        XCTAssertNotEqual(
            StudioAnnotationDocument.currentSchemaVersion,
            "scratchlab_local_recording_sidecar_v1"
        )
        XCTAssertNotEqual(
            StudioAnnotationDocument.currentSchemaVersion,
            "scratchlab_session_replay_v1"
        )
        XCTAssertNotEqual(
            StudioAnnotationDocument.currentSchemaVersion,
            "scratchlab_review_metadata_v1"
        )
        XCTAssertEqual(
            StudioAnnotationDocument.currentSchemaVersion,
            "scratchlab_studio_annotations_v1"
        )
    }

    // MARK: - Construction invariants

    func testAnnotationRejectsInvalidTimes() {
        XCTAssertNil(StudioAnnotation(
            startTime: -1, endTime: nil, kind: .note,
            note: "", createdAt: fixedInstant()
        ))
        XCTAssertNil(StudioAnnotation(
            startTime: .nan, endTime: nil, kind: .note,
            note: "", createdAt: fixedInstant()
        ))
        XCTAssertNil(StudioAnnotation(
            startTime: .infinity, endTime: nil, kind: .note,
            note: "", createdAt: fixedInstant()
        ))
        XCTAssertNil(StudioAnnotation(
            startTime: 2, endTime: 1, kind: .note,
            note: "", createdAt: fixedInstant()
        ))
    }

    func testAnnotationAcceptsEqualStartAndEnd() {
        // endTime == startTime → zero-duration span, accepted.
        XCTAssertNotNil(StudioAnnotation(
            startTime: 1.5, endTime: 1.5, kind: .note,
            note: "", createdAt: fixedInstant()
        ))
    }
}
