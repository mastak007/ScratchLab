// CrossfaderCalibrationStore — persistence for crossfader calibrations,
// shared by iOS and macOS.
//
// One calibration per MIDI address. Re-calibrating the same address replaces
// the entry; calibrating a different controller adds one, so a studio with two
// mixers does not have to recalibrate every time it swaps.
//
// Failure policy, deliberately asymmetric:
// - A store that cannot be READ yields an empty store. A corrupt file must not
//   prevent the operator from calibrating again.
// - A store that cannot be WRITTEN throws. Silently losing a calibration the
//   operator just performed would let them record a whole reference against a
//   calibration that is not on disk.
// - A calibration that does not pass `validationIssues()` is REFUSED at save
//   time, so an unusable calibration can never reach a take.

import Foundation

/// The persisted document.
struct CrossfaderCalibrationDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "scratchlab_crossfader_calibration_v1"

    let schemaVersion: String
    var calibrations: [CrossfaderCalibration]
    var updatedAt: Date

    init(
        schemaVersion: String = CrossfaderCalibrationDocument.currentSchemaVersion,
        calibrations: [CrossfaderCalibration],
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.calibrations = calibrations
        self.updatedAt = updatedAt
    }

    static let empty = CrossfaderCalibrationDocument(
        calibrations: [],
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

enum CrossfaderCalibrationStoreError: LocalizedError, Equatable {
    case calibrationRejected([CrossfaderCalibrationIssue])
    case couldNotWrite(String)

    var errorDescription: String? {
        switch self {
        case .calibrationRejected(let issues):
            return "This crossfader calibration cannot be saved. "
                + issues.map(\.message).joined(separator: " ")
        case .couldNotWrite(let detail):
            return "ScratchLab could not save the crossfader calibration: \(detail)"
        }
    }
}

/// Reads and writes the calibration document.
///
/// A value type over an injected directory so tests run against a temporary
/// folder and never touch the operator's real calibration.
struct CrossfaderCalibrationStore: Sendable {

    static let fileName = "CrossfaderCalibrations.json"

    let directoryURL: URL
    let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    var fileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Load the document. A missing or unreadable file yields the empty
    /// document rather than throwing — see the failure policy above.
    func load() -> CrossfaderCalibrationDocument {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? Self.decoder.decode(
                CrossfaderCalibrationDocument.self,
                from: data
              ),
              document.schemaVersion == CrossfaderCalibrationDocument.currentSchemaVersion else {
            return .empty
        }
        return document
    }

    /// Insert or replace `calibration`, keyed by its MIDI address.
    ///
    /// Throws when the calibration is unusable, or when the write fails.
    @discardableResult
    func save(
        _ calibration: CrossfaderCalibration,
        now: Date = Date()
    ) throws -> CrossfaderCalibrationDocument {
        let issues = calibration.validationIssues()
        guard issues.isEmpty else {
            throw CrossfaderCalibrationStoreError.calibrationRejected(issues)
        }

        var document = load()
        document.calibrations.removeAll { existing in
            existing.address.matches(
                deviceIdentifier: calibration.address.deviceIdentifier,
                channel: calibration.address.channel,
                controller: calibration.address.controller
            )
        }
        document.calibrations.append(calibration)
        document.calibrations.sort { $0.id < $1.id }
        document.updatedAt = now

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CrossfaderCalibrationStoreError.couldNotWrite(error.localizedDescription)
        }
        return document
    }

    /// The calibration for one address, or `nil`.
    ///
    /// Never returns a calibration measured on a different address, and never
    /// synthesizes a default — the absence of a calibration is a blocking
    /// condition the caller must surface, not paper over.
    func calibration(
        deviceIdentifier: String,
        channel: Int,
        controller: Int
    ) -> CrossfaderCalibration? {
        load().calibrations.first {
            $0.address.matches(
                deviceIdentifier: deviceIdentifier,
                channel: channel,
                controller: controller
            )
        }
    }

    /// Every calibration on file for one device, newest first.
    func calibrations(forDeviceIdentifier deviceIdentifier: String) -> [CrossfaderCalibration] {
        load().calibrations
            .filter { $0.address.deviceIdentifier == deviceIdentifier }
            .sorted { $0.calibratedAt > $1.calibratedAt }
    }

    /// Remove one calibration. Used by "recalibrate from scratch".
    @discardableResult
    func remove(
        deviceIdentifier: String,
        channel: Int,
        controller: Int,
        now: Date = Date()
    ) throws -> CrossfaderCalibrationDocument {
        var document = load()
        document.calibrations.removeAll {
            $0.address.matches(
                deviceIdentifier: deviceIdentifier,
                channel: channel,
                controller: controller
            )
        }
        document.updatedAt = now
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CrossfaderCalibrationStoreError.couldNotWrite(error.localizedDescription)
        }
        return document
    }
}
