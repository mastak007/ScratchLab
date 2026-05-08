//
//  NotationCodec.swift
//  ScratchNotation
//
//  JSON encode/decode + sidecar read/write helpers. Output is pretty-printed
//  with sorted keys for deterministic, diff-friendly files.
//

import Foundation

public enum NotationCodecError: Error {
    case writeFailed(URL, underlying: String)
    case readFailed(URL, underlying: String)
}

public struct NotationCodec {

    public static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    public static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    public static func encode(_ timeline: DatasetNotationTimeline) throws -> Data {
        try encoder().encode(timeline)
    }

    public static func decode(_ data: Data) throws -> DatasetNotationTimeline {
        try decoder().decode(DatasetNotationTimeline.self, from: data)
    }

    public static func write(_ timeline: DatasetNotationTimeline, to url: URL) throws {
        let data = try encode(timeline)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw NotationCodecError.writeFailed(url, underlying: error.localizedDescription)
        }
    }

    public static func read(from url: URL) throws -> DatasetNotationTimeline {
        do {
            let data = try Data(contentsOf: url)
            return try decode(data)
        } catch {
            throw NotationCodecError.readFailed(url, underlying: error.localizedDescription)
        }
    }
}
