import Foundation

// MARK: - TimecodeDirection

/// Direction of timecode motion decoded from a phase progression.
///
/// **Batch 2:** Prototype decoder only. Does not claim compatibility with any
/// commercial timecode format.
public enum TimecodeDirection: String, Equatable, Sendable, CaseIterable {
    /// Phase is advancing — forward record/playback motion.
    case forward

    /// Phase is regressing — backward record/playback motion.
    case backward

    /// Direction could not be determined (e.g. first frame, or phase delta
    /// below the noise floor).
    case unknown
}

// MARK: - TimecodeDecoderState

/// Lock state of the prototype timecode decoder.
///
/// **Batch 2:** Informational only. The decoder always attempts to extract
/// phase from every input buffer regardless of lock state. Lock tracking is
/// reserved for Batch 3 live streaming.
public enum TimecodeDecoderState: String, Equatable, Sendable, CaseIterable {
    /// Decoder has established a consistent phase track across multiple
    /// consecutive buffers.
    case locked

    /// Decoder has not yet seen enough consistent phase data to establish
    /// a track.
    case unlocked

    /// Decoder sees some phase structure but it is not yet stable (e.g.
    /// after a dropout or direction change).
    case searching
}
