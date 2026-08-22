// TransportState.swift
// ScratchLab - Shared Transport State Model
//
// Single shared source of truth for the "is the transport playing?" decision,
// so iOS and macOS can observe the same transport state without sharing
// playback engines. This is a state abstraction only — it owns no audio, no
// MIDI, no playback.

import Foundation

/// Platform-independent transport state. `isPlaying` is the single source of
/// truth for play/stop; the virtual platter, the iOS MIDI dispatch, and
/// (optionally) macOS transport paths read/write this instead of each keeping
/// their own flag.
///
/// Deliberately NOT `@MainActor`: macOS updates it from its audio queue and
/// creates it from a non-isolated playback controller, so it must be callable
/// from any thread. iOS writes it from its `@MainActor` dispatcher.
final class TransportState: ObservableObject {

    @Published private(set) var isPlaying: Bool = false

    func play() {
        isPlaying = true
    }

    func stop() {
        isPlaying = false
    }

    func toggle() {
        isPlaying.toggle()
    }
}
