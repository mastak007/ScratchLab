//
//  ScratchClassLabel.swift
//  ScratchLab
//
//  Canonical enum of trained scratch classes. The raw value of each case is the
//  exact label string emitted by the trained Core ML classifier — it must stay
//  in lockstep with the directory names used as class folders during training.
//

import Foundation

public enum ScratchClassLabel: String, CaseIterable, Codable, Sendable, Hashable {
    case oneClickFlare      = "1clickflare"
    case baby               = "baby"
    case chirpFlare         = "chirpflare"
    case chirps             = "chirps"
    case cloverTears        = "clovertears"
    case crabs              = "crabs"
    case crescentFlare      = "cresentflare"
    case cutting            = "cutting"
    case dicing             = "dicing"
    case drags              = "drags"
    case lazers             = "lazers"
    case longShortTips      = "long_short_tips"
    case marches            = "marches"
    case needledropping     = "needledropping"
    case orbits             = "orbits"
    case originalFlare      = "originalflare"
    case reverseCutting     = "reversecutting"
    case swipes             = "swipes"
    case tears              = "tears"
    case tips               = "tips"
    case transformer        = "transformer"
    case waves              = "waves"
    case zigzags            = "zigzags"

    /// User-facing display name.
    public var displayName: String {
        switch self {
        case .oneClickFlare:    return "1-Click Flare"
        case .baby:             return "Baby"
        case .chirpFlare:       return "Chirp Flare"
        case .chirps:           return "Chirps"
        case .cloverTears:      return "Clover Tears"
        case .crabs:            return "Crabs"
        case .crescentFlare:    return "Crescent Flare"
        case .cutting:          return "Cutting"
        case .dicing:           return "Dicing"
        case .drags:            return "Drags"
        case .lazers:           return "Lazers"
        case .longShortTips:    return "Long-Short Tips"
        case .marches:          return "Marches"
        case .needledropping:   return "Needle Dropping"
        case .orbits:           return "Orbits"
        case .originalFlare:    return "Original Flare"
        case .reverseCutting:   return "Reverse Cutting"
        case .swipes:           return "Swipes"
        case .tears:            return "Tears"
        case .tips:             return "Tips"
        case .transformer:      return "Transformer"
        case .waves:            return "Waves"
        case .zigzags:          return "Zig Zags"
        }
    }

    /// Initialize from the model's raw output string. Returns nil for unknown
    /// labels (e.g. an older model that emits a label this build doesn't know).
    public init?(modelLabel: String) {
        self.init(rawValue: modelLabel)
    }
}
