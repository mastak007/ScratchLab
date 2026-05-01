// ScratchFormulaCatalog.swift
// ScratchLab
// Independent symbol catalog for scratch formula rendering.

import Foundation

enum ScratchDirection: String, Codable {
    case forward
    case reverse
}

struct ScratchCatalogEntry: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let aliases: Set<String>
    let defaultBeats: Double
}

final class ScratchFormulaCatalog {
    static let mvp = ScratchFormulaCatalog(entries: [
        entry(id: "baby_scratch", displayName: "Baby Scratch", aliases: ["baby", "babyscratch", "b"]),
        entry(id: "forward_scratch", displayName: "Forward Scratch", aliases: ["forward", "forwardscratch", "fwd"]),
        entry(id: "backward_scratch", displayName: "Backward Scratch", aliases: ["backward", "backwardscratch", "back", "bwd"]),
        entry(id: "release_scratch", displayName: "Release Scratch", aliases: ["release", "releasescratch", "rel"]),
        entry(id: "tear", displayName: "Tear", aliases: ["tear"]),
        entry(id: "chirp", displayName: "Chirp", aliases: ["chirp", "chirps"]),
        entry(id: "scribble", displayName: "Scribble", aliases: ["scribble", "scribbles", "scrib"]),
        entry(id: "stab", displayName: "Stab", aliases: ["stab", "stabs"]),
        entry(id: "transform", displayName: "Transform", aliases: ["transform", "transformer", "transformers"]),
        entry(id: "crab", displayName: "Crab", aliases: ["crab", "crabs"]),
        entry(id: "flare_1click", displayName: "1-Click Flare", aliases: ["flare", "flare1", "oneclickflare", "one_click_flare", "ocf", "oc_flare"]),
        entry(id: "orbit", displayName: "Orbit", aliases: ["orbit"]),
        entry(id: "flare_2click", displayName: "2-Click Flare", aliases: ["flare2", "twoclickflare", "two_click_flare", "tcf", "two_click"]),
        entry(id: "twiddle", displayName: "Twiddle", aliases: ["twiddle"]),
        entry(id: "boomerang", displayName: "Boomerang", aliases: ["boomerang", "boomer"]),
        entry(id: "hydroplane", displayName: "Hydroplane", aliases: ["hydroplane", "hydro"]),
        entry(id: "flare_3click", displayName: "3-Click Flare", aliases: ["flare3", "threeclickflare", "three_click_flare", "thcf", "three_click"]),
        entry(id: "autobahn", displayName: "Autobahn", aliases: ["autobahn"]),
        entry(id: "military", displayName: "Military", aliases: ["military"]),
        entry(id: "prizm", displayName: "Prizm", aliases: ["prizm", "prism"]),
    ])

    private let orderedEntries: [ScratchCatalogEntry]
    private let entriesByID: [String: ScratchCatalogEntry]
    private let idByAlias: [String: String]

    init(entries: [ScratchCatalogEntry]) {
        orderedEntries = entries
        var byID: [String: ScratchCatalogEntry] = [:]
        var byAlias: [String: String] = [:]

        for entry in entries {
            byID[entry.id] = entry
            byAlias[Self.aliasKey(entry.id)] = entry.id
            byAlias[Self.aliasKey(entry.displayName)] = entry.id
            for alias in entry.aliases {
                byAlias[Self.aliasKey(alias)] = entry.id
            }
        }

        self.entriesByID = byID
        self.idByAlias = byAlias
    }

    func resolve(_ symbol: String) -> ScratchCatalogEntry? {
        guard let entryID = idByAlias[Self.aliasKey(symbol)] else { return nil }
        return entriesByID[entryID]
    }

    var entries: [ScratchCatalogEntry] {
        orderedEntries
    }

    private static func entry(
        id: String,
        displayName: String,
        aliases: Set<String>,
        defaultBeats: Double? = nil
    ) -> ScratchCatalogEntry {
        let resolvedDefaultBeats = defaultBeats
            ?? ScratchLibrary.shared.scratch(byID: id)?.formulaDefaultBeats
            ?? 1.0
        return ScratchCatalogEntry(
            id: id,
            displayName: displayName,
            aliases: aliases,
            defaultBeats: resolvedDefaultBeats
        )
    }

    private static func aliasKey(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
