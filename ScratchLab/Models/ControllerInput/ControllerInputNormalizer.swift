import Foundation

// Phase 1 normalizer seam.
//
// Defines the vocabulary and boundaries for turning raw input events into
// normalized `ScratchInputFrame`s, WITHOUT implementing any real device mapping.
// Concrete profiles (RANE ONE, REV7, REV5, FLX10, GRV6, RANE FOUR,
// RANE PERFORMER) are intentionally NOT implemented in this slice.

/// A decoded, device-independent meaning for a raw control change. A device
/// profile maps raw bytes onto these; this slice defines the vocabulary only.
enum SemanticControl: Sendable, Equatable, Hashable {
    /// Relative platter movement in encoder ticks (sign = direction).
    case platterDelta(deck: ScratchDeckID, ticks: Int)
    /// Absolute platter angle within a single turn, in revolutions (0..<1).
    case platterAbsolute(deck: ScratchDeckID, revolution: Double)
    /// Absolute crossfader position normalized to 0...1.
    case crossfaderAbsolute(position: Double)
}

/// Describes how a specific controller's raw events map to semantic controls,
/// plus the constants needed to normalize them. Concrete conformers are out of
/// scope for this slice; this protocol only fixes the shape future profiles take.
protocol DeviceProfile {
    /// Stable identifier for this profile (used as `ScratchInputSource.profileID`).
    var profileID: String { get }
    /// Transport this profile expects its events on.
    var transport: ScratchTransportKind { get }
    /// Encoder resolution in ticks per full revolution, used to normalize platter
    /// deltas into revolutions. Zero means unknown/unspecified.
    var platterTicksPerRevolution: Int { get }

    /// Decodes a single raw event into zero or more semantic controls. An empty
    /// result means "not recognized / nothing to emit".
    func decode(_ event: ScratchRawInputEvent) -> [SemanticControl]
}

/// Turns raw input events into normalized `ScratchInputFrame`s. The seam is
/// defined here; real normalization arrives later with real device profiles.
protocol ControllerInputNormalizer: AnyObject {
    /// The profile currently driving normalization, if any. With no profile the
    /// normalizer must not fabricate frames.
    var profile: DeviceProfile? { get }

    /// Offers a raw event for normalization. Returns a frame only when the event
    /// (in context) completes a meaningful state update; otherwise nil.
    func ingest(_ event: ScratchRawInputEvent) -> ScratchInputFrame?
}

/// Default normalizer that produces nothing until real mapping exists. This makes
/// "no profile ⇒ no frames" an explicit, testable guarantee and keeps all
/// real-device assumptions out of this slice.
final class StubControllerInputNormalizer: ControllerInputNormalizer {
    private(set) var profile: DeviceProfile?

    init(profile: DeviceProfile? = nil) {
        self.profile = profile
    }

    /// Attaches (or clears) the active profile. Mapping is still not implemented.
    func attach(_ profile: DeviceProfile?) {
        self.profile = profile
    }

    func ingest(_ event: ScratchRawInputEvent) -> ScratchInputFrame? {
        // No profile ⇒ raw bytes are uninterpretable ⇒ emit nothing.
        guard profile != nil else { return nil }
        // A profile may be attached, but real decoding/accumulation into frames
        // is deliberately out of scope for this slice, so still emit nothing.
        return nil
    }
}
