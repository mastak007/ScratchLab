import Foundation

enum ScratchMotionDirection: String, Equatable {
    case forward
    case backward
    case neutral

    var label: String {
        switch self {
        case .forward:
            return "Forward"
        case .backward:
            return "Back"
        case .neutral:
            return "Center"
        }
    }
}

enum ScratchMotionBalance: String, Equatable {
    case listening = "Listening"
    case balanced = "Balanced"
    case unbalanced = "Unbalanced"
}

struct ScratchMotionFeedback: Equatable {
    let direction: ScratchMotionDirection
    let balance: ScratchMotionBalance
    let forwardDuration: TimeInterval?
    let backwardDuration: TimeInterval?
    let timingError: TimeInterval?
    let forwardPeakAmplitude: Float?
    let backwardPeakAmplitude: Float?

    var timingErrorMilliseconds: Int? {
        guard let timingError else { return nil }
        return Int((timingError * 1_000).rounded())
    }
}

enum ScratchAudioNotationEventKind: String, Codable, Equatable, Sendable {
    case scratchBurst
    case silenceGap
    case possibleCut
    case possibleDrag
    case unknown
}

struct ScratchAudioNotationEventCandidate: Codable, Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let duration: TimeInterval
    let peakLevel: Float
    let rmsLevel: Float
    let confidence: Double
    let eventKind: ScratchAudioNotationEventKind
    let source: String
}

struct ScratchAudioNotationSnapshot: Equatable, Sendable {
    let audioEvents: [ScratchAudioNotationEventCandidate]
    let confidence: Double?

    var hasDetectedEvents: Bool {
        !audioEvents.isEmpty
    }
}

final class ScratchAudioNotationDetector {
    private struct ActiveBurst {
        let startTime: TimeInterval
        let startedFromPeak: Float
        var peakLevel: Float
        var rmsTotal: Float
        var frameCount: Int
    }

    private let frameSize = 256
    private let activeRMSFloor: Float = 0.010
    private let activePeakFloor: Float = 0.032
    private let releaseRMSFloor: Float = 0.006
    private let minimumBurstDuration: TimeInterval = 0.045
    private let minimumGapDuration: TimeInterval = 0.05
    private let quietFramesToCloseBurst = 4
    private let shortCutGapDuration: TimeInterval = 0.09
    private let strongBurstPeakLevel: Float = 0.18
    private let dragDurationThreshold: TimeInterval = 0.30

    private var elapsedTime: TimeInterval = 0
    private var activeBurst: ActiveBurst?
    private var quietFramesDuringBurst = 0
    private var quietGapStartTime: TimeInterval?
    private var mostRecentBurstPeakLevel: Float?
    private var audioEvents: [ScratchAudioNotationEventCandidate] = []

    func reset() {
        elapsedTime = 0
        activeBurst = nil
        quietFramesDuringBurst = 0
        quietGapStartTime = nil
        mostRecentBurstPeakLevel = nil
        audioEvents.removeAll()
    }

    func process(samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }

        var sampleIndex = 0
        while sampleIndex < samples.count {
            let frameEndIndex = min(sampleIndex + frameSize, samples.count)
            let frame = samples[sampleIndex..<frameEndIndex]
            let frameDuration = Double(frame.count) / sampleRate
            processFrame(
                rms: averageAbsoluteAmplitude(of: frame),
                peak: peakAmplitude(of: frame),
                frameDuration: frameDuration
            )
            sampleIndex = frameEndIndex
        }
    }

    func snapshot() -> ScratchAudioNotationSnapshot {
        finalizeActiveBurst(at: elapsedTime)
        finalizeTrailingGap(at: elapsedTime)
        let confidence = audioEvents.isEmpty
            ? nil
            : audioEvents.map(\.confidence).reduce(0, +) / Double(audioEvents.count)
        return ScratchAudioNotationSnapshot(audioEvents: audioEvents, confidence: confidence)
    }

    private func processFrame(rms: Float, peak: Float, frameDuration: TimeInterval) {
        let frameStartTime = elapsedTime
        elapsedTime += frameDuration
        let frameEndTime = elapsedTime
        let isActive = rms >= activeRMSFloor || peak >= activePeakFloor
        let isReleased = rms <= releaseRMSFloor && peak <= activePeakFloor * 0.6

        if var activeBurst {
            activeBurst.peakLevel = max(activeBurst.peakLevel, peak)
            activeBurst.rmsTotal += rms
            activeBurst.frameCount += 1
            self.activeBurst = activeBurst

            if isReleased {
                quietFramesDuringBurst += 1
                if quietFramesDuringBurst >= quietFramesToCloseBurst {
                    let endTime = max(activeBurst.startTime, frameEndTime - (frameDuration * Double(quietFramesToCloseBurst - 1)))
                    finalizeActiveBurst(at: endTime)
                    quietGapStartTime = endTime
                }
            } else {
                quietFramesDuringBurst = 0
            }
            return
        }

        if isActive {
            finalizePendingGapIfNeeded(at: frameStartTime, nextBurstPeak: peak)
            activeBurst = ActiveBurst(
                startTime: frameStartTime,
                startedFromPeak: peak,
                peakLevel: peak,
                rmsTotal: rms,
                frameCount: 1
            )
            quietFramesDuringBurst = 0
            return
        }

        if quietGapStartTime == nil {
            quietGapStartTime = frameStartTime
        }
    }

    private func finalizeActiveBurst(at endTime: TimeInterval) {
        guard let activeBurst else { return }
        self.activeBurst = nil
        quietFramesDuringBurst = 0

        let duration = max(0, endTime - activeBurst.startTime)
        guard duration >= minimumBurstDuration else { return }

        let rmsLevel = activeBurst.frameCount > 0
            ? activeBurst.rmsTotal / Float(activeBurst.frameCount)
            : 0
        let eventKind: ScratchAudioNotationEventKind = duration >= dragDurationThreshold ? .possibleDrag : .scratchBurst
        let confidence = normalizedConfidence(peakLevel: activeBurst.peakLevel, rmsLevel: rmsLevel)
        audioEvents.append(
            ScratchAudioNotationEventCandidate(
                startTime: activeBurst.startTime,
                endTime: endTime,
                duration: duration,
                peakLevel: activeBurst.peakLevel,
                rmsLevel: rmsLevel,
                confidence: confidence,
                eventKind: eventKind,
                source: "audio"
            )
        )
        mostRecentBurstPeakLevel = activeBurst.peakLevel
    }

    private func finalizePendingGapIfNeeded(at nextBurstStartTime: TimeInterval, nextBurstPeak: Float) {
        guard let quietGapStartTime else { return }
        self.quietGapStartTime = nil

        let duration = max(0, nextBurstStartTime - quietGapStartTime)
        guard duration >= minimumGapDuration else { return }

        let previousPeak = mostRecentBurstPeakLevel ?? 0
        let strongBursts = previousPeak >= strongBurstPeakLevel && nextBurstPeak >= strongBurstPeakLevel
        let eventKind: ScratchAudioNotationEventKind = strongBursts && duration <= shortCutGapDuration
            ? .possibleCut
            : .silenceGap
        let confidence = strongBursts && duration <= shortCutGapDuration ? 0.74 : 0.56
        audioEvents.append(
            ScratchAudioNotationEventCandidate(
                startTime: quietGapStartTime,
                endTime: nextBurstStartTime,
                duration: duration,
                peakLevel: 0,
                rmsLevel: 0,
                confidence: confidence,
                eventKind: eventKind,
                source: "audio"
            )
        )
    }

    private func finalizeTrailingGap(at endTime: TimeInterval) {
        guard let quietGapStartTime else { return }
        self.quietGapStartTime = nil
        let duration = max(0, endTime - quietGapStartTime)
        guard duration >= minimumGapDuration else { return }
        audioEvents.append(
            ScratchAudioNotationEventCandidate(
                startTime: quietGapStartTime,
                endTime: endTime,
                duration: duration,
                peakLevel: 0,
                rmsLevel: 0,
                confidence: 0.45,
                eventKind: .silenceGap,
                source: "audio"
            )
        )
    }

    private func normalizedConfidence(peakLevel: Float, rmsLevel: Float) -> Double {
        let peakScore = min(max((peakLevel - activePeakFloor) / 0.45, 0), 1)
        let rmsScore = min(max((rmsLevel - activeRMSFloor) / 0.20, 0), 1)
        return Double((peakScore * 0.6) + (rmsScore * 0.4))
    }

    private func averageAbsoluteAmplitude(of frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }

        var total: Float = 0
        for sample in frame {
            total += abs(sample)
        }
        return total / Float(frame.count)
    }

    private func peakAmplitude(of frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }

        var peak: Float = 0
        for sample in frame {
            peak = max(peak, abs(sample))
        }
        return peak
    }
}

final class ScratchMotionAnalyzer {
    private struct StrokeSegment: Equatable {
        let direction: ScratchMotionDirection
        let startTime: TimeInterval
        let endTime: TimeInterval
        let peakAmplitude: Float

        var duration: TimeInterval {
            max(0, endTime - startTime)
        }
    }

    private struct EnvelopePoint: Equatable {
        let time: TimeInterval
        let amplitude: Float
    }

    private enum ExtremumKind {
        case peak
        case valley
    }

    private let frameSize = 256
    private let minimumStrokeDuration: TimeInterval = 0.045
    private let maximumStrokeDuration: TimeInterval = 0.75
    private let maximumGapBetweenStrokes: TimeInterval = 0.48
    private let historyWindowDuration: TimeInterval = 0.18
    private let activeThresholdFloor: Float = 0.011
    private let releaseThresholdFloor: Float = 0.006
    private let slopeThresholdFloor: Float = 0.0014
    private let extremumProminenceFloor: Float = 0.004
    private let requiredQuietFramesToCloseStroke = 4
    private let absoluteTimingTolerance: TimeInterval = 0.08

    private(set) var currentDirection: ScratchMotionDirection = .neutral
    private var elapsedTime: TimeInterval = 0
    private var smoothedEnvelope: Float = 0
    private var noiseFloor: Float = 0.0035
    private var envelopeHistory: [EnvelopePoint] = []
    private var activeStrokeDirection: ScratchMotionDirection?
    private var activeStrokeStartTime: TimeInterval?
    private var activeStrokePeakAmplitude: Float = 0
    private var quietFramesDuringActiveStroke = 0
    private var pendingForwardStroke: StrokeSegment?
    private var pendingBackwardStroke: StrokeSegment?
    private var lastCompletedStrokeEndTime: TimeInterval?
    private var lastDetectedExtremumTime: TimeInterval = -.greatestFiniteMagnitude

    func reset() {
        currentDirection = .neutral
        elapsedTime = 0
        smoothedEnvelope = 0
        noiseFloor = 0.0035
        envelopeHistory.removeAll()
        activeStrokeDirection = nil
        activeStrokeStartTime = nil
        activeStrokePeakAmplitude = 0
        quietFramesDuringActiveStroke = 0
        pendingForwardStroke = nil
        pendingBackwardStroke = nil
        lastCompletedStrokeEndTime = nil
        lastDetectedExtremumTime = -.greatestFiniteMagnitude
    }

    func process(samples: [Float], sampleRate: Double) -> ScratchMotionFeedback? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        var latestFeedback: ScratchMotionFeedback?
        var sampleIndex = 0

        while sampleIndex < samples.count {
            let frameEndIndex = min(sampleIndex + frameSize, samples.count)
            let frame = samples[sampleIndex..<frameEndIndex]
            let frameAmplitude = averageAbsoluteAmplitude(of: frame)
            let frameDuration = Double(frame.count) / sampleRate

            if let feedback = processEnvelopeFrame(
                frameAmplitude,
                frameDuration: frameDuration
            ) {
                latestFeedback = feedback
            }

            sampleIndex = frameEndIndex
        }

        return latestFeedback
    }

    private func processEnvelopeFrame(
        _ frameAmplitude: Float,
        frameDuration: TimeInterval
    ) -> ScratchMotionFeedback? {
        elapsedTime += frameDuration
        let rawEnvelope = frameAmplitude
        smoothedEnvelope = (smoothedEnvelope * 0.58) + (rawEnvelope * 0.42)
        let frameTime = max(0, elapsedTime - (frameDuration / 2))
        appendEnvelopePoint(amplitude: smoothedEnvelope, at: frameTime)

        let activeThreshold = max(activeThresholdFloor, noiseFloor * 2.7)
        let releaseThreshold = max(releaseThresholdFloor, activeThreshold * 0.55)
        let slopeThreshold = max(slopeThresholdFloor, noiseFloor * 0.6)
        let extremumProminence = max(extremumProminenceFloor, noiseFloor * 1.4)

        if activeStrokeDirection == nil {
            noiseFloor = (noiseFloor * 0.97) + (smoothedEnvelope * 0.03)
        }

        if let lastCompletedStrokeEndTime,
           frameTime - lastCompletedStrokeEndTime > maximumGapBetweenStrokes {
            pendingForwardStroke = nil
            pendingBackwardStroke = nil
        }

        if activeStrokeDirection == nil,
           smoothedEnvelope >= activeThreshold,
           let slopeDirection = slopeDirection(threshold: slopeThreshold) {
            startStroke(
                direction: slopeDirection,
                at: max(0, frameTime - frameDuration),
                amplitude: smoothedEnvelope
            )
            return listeningFeedback(direction: slopeDirection)
        }

        if let activeStrokeDirection {
            activeStrokePeakAmplitude = max(activeStrokePeakAmplitude, smoothedEnvelope)
            currentDirection = slopeDirection(threshold: slopeThreshold) ?? activeStrokeDirection
        } else {
            currentDirection = .neutral
        }

        if let extremum = detectExtremum(
            activeThreshold: activeThreshold,
            prominenceThreshold: extremumProminence
        ) {
            switch (activeStrokeDirection, extremum.kind) {
            case (.some(.forward), .peak):
                return transitionStroke(
                    to: .backward,
                    at: extremum.time,
                    amplitude: extremum.amplitude
                )
            case (.some(.backward), .valley):
                return transitionStroke(
                    to: .forward,
                    at: extremum.time,
                    amplitude: extremum.amplitude
                )
            default:
                break
            }
        }

        guard activeStrokeDirection != nil else { return nil }

        if rawEnvelope <= releaseThreshold {
            quietFramesDuringActiveStroke += 1
        } else {
            quietFramesDuringActiveStroke = 0
        }

        guard quietFramesDuringActiveStroke >= requiredQuietFramesToCloseStroke else {
            return nil
        }

        let quietStartTime = max(
            0,
            frameTime - (frameDuration * Double(requiredQuietFramesToCloseStroke - 1))
        )
        let feedback = finalizeActiveStroke(at: quietStartTime)
        currentDirection = .neutral
        return feedback
    }

    private func appendEnvelopePoint(
        amplitude: Float,
        at time: TimeInterval
    ) {
        envelopeHistory.append(EnvelopePoint(time: time, amplitude: amplitude))
        let cutoffTime = time - historyWindowDuration
        if let firstIndexToKeep = envelopeHistory.firstIndex(where: { $0.time >= cutoffTime }) {
            if firstIndexToKeep > 0 {
                envelopeHistory.removeFirst(firstIndexToKeep)
            }
        } else {
            envelopeHistory = [envelopeHistory.last].compactMap { $0 }
        }
    }

    private func slopeDirection(
        threshold: Float
    ) -> ScratchMotionDirection? {
        guard envelopeHistory.count >= 2 else { return nil }
        let previous = envelopeHistory[envelopeHistory.count - 2]
        let current = envelopeHistory[envelopeHistory.count - 1]
        let delta = current.amplitude - previous.amplitude
        if delta >= threshold {
            return .forward
        }
        if delta <= -threshold {
            return .backward
        }
        return nil
    }

    private func detectExtremum(
        activeThreshold: Float,
        prominenceThreshold: Float
    ) -> (kind: ExtremumKind, time: TimeInterval, amplitude: Float)? {
        guard envelopeHistory.count >= 3 else { return nil }

        let turnaroundThreshold = max(slopeThresholdFloor, prominenceThreshold * 0.35)

        if envelopeHistory.count >= 4 {
            let before = envelopeHistory[envelopeHistory.count - 4]
            let candidate = envelopeHistory[envelopeHistory.count - 3]
            let after = envelopeHistory[envelopeHistory.count - 2]
            let latest = envelopeHistory[envelopeHistory.count - 1]

            if candidate.time > lastDetectedExtremumTime {
                let candidateRise = candidate.amplitude - before.amplitude
                let candidateFall = candidate.amplitude - after.amplitude
                let followThroughDrop = after.amplitude - latest.amplitude
                let valleyDrop = before.amplitude - candidate.amplitude
                let valleyRise = after.amplitude - candidate.amplitude
                let followThroughRise = latest.amplitude - after.amplitude

                if candidate.amplitude >= activeThreshold,
                   candidateRise >= turnaroundThreshold,
                   candidateFall > 0,
                   followThroughDrop >= turnaroundThreshold,
                   candidate.amplitude - latest.amplitude >= turnaroundThreshold {
                    lastDetectedExtremumTime = candidate.time
                    return (.peak, candidate.time, candidate.amplitude)
                }

                if valleyDrop >= turnaroundThreshold,
                   valleyRise > 0,
                   followThroughRise >= turnaroundThreshold,
                   latest.amplitude - candidate.amplitude >= turnaroundThreshold {
                    lastDetectedExtremumTime = candidate.time
                    return (.valley, candidate.time, candidate.amplitude)
                }
            }
        }

        let previous = envelopeHistory[envelopeHistory.count - 3]
        let middle = envelopeHistory[envelopeHistory.count - 2]
        let current = envelopeHistory[envelopeHistory.count - 1]

        guard middle.time > lastDetectedExtremumTime else { return nil }

        let previousSlope = middle.amplitude - previous.amplitude
        let nextSlope = current.amplitude - middle.amplitude
        let localPeakDepth = middle.amplitude - min(previous.amplitude, current.amplitude)
        let localValleyDepth = max(previous.amplitude, current.amplitude) - middle.amplitude

        if middle.amplitude >= activeThreshold,
           previousSlope >= turnaroundThreshold,
           nextSlope <= -turnaroundThreshold,
           localPeakDepth >= turnaroundThreshold {
            lastDetectedExtremumTime = middle.time
            return (.peak, middle.time, middle.amplitude)
        }

        if previousSlope <= -turnaroundThreshold,
           nextSlope >= turnaroundThreshold,
           localValleyDepth >= turnaroundThreshold {
            lastDetectedExtremumTime = middle.time
            return (.valley, middle.time, middle.amplitude)
        }

        return nil
    }

    private func startStroke(
        direction: ScratchMotionDirection,
        at startTime: TimeInterval,
        amplitude: Float
    ) {
        activeStrokeDirection = direction
        activeStrokeStartTime = startTime
        activeStrokePeakAmplitude = amplitude
        quietFramesDuringActiveStroke = 0
        currentDirection = direction
    }

    private func transitionStroke(
        to nextDirection: ScratchMotionDirection,
        at transitionTime: TimeInterval,
        amplitude: Float
    ) -> ScratchMotionFeedback? {
        let feedback = finalizeActiveStroke(
            at: transitionTime,
            overridingPeakAmplitude: amplitude
        )
        startStroke(
            direction: nextDirection,
            at: transitionTime,
            amplitude: amplitude
        )
        return feedback
    }

    private func finalizeActiveStroke(
        at endTime: TimeInterval,
        overridingPeakAmplitude: Float? = nil
    ) -> ScratchMotionFeedback? {
        guard let direction = activeStrokeDirection,
              let startTime = activeStrokeStartTime else {
            return nil
        }

        let stroke = StrokeSegment(
            direction: direction,
            startTime: startTime,
            endTime: max(startTime, endTime),
            peakAmplitude: max(activeStrokePeakAmplitude, overridingPeakAmplitude ?? 0)
        )

        activeStrokeDirection = nil
        activeStrokeStartTime = nil
        activeStrokePeakAmplitude = 0
        quietFramesDuringActiveStroke = 0

        guard minimumStrokeDuration...maximumStrokeDuration ~= stroke.duration else {
            return nil
        }

        lastCompletedStrokeEndTime = stroke.endTime
        return recordCompletedStroke(stroke)
    }

    private func recordCompletedStroke(
        _ stroke: StrokeSegment
    ) -> ScratchMotionFeedback {
        switch stroke.direction {
        case .forward:
            if let backwardStroke = pendingBackwardStroke,
               stroke.startTime - backwardStroke.endTime <= maximumGapBetweenStrokes {
                return pairedFeedback(forwardStroke: stroke, backwardStroke: backwardStroke)
            }

            pendingForwardStroke = stroke
            return listeningFeedback(direction: .neutral)

        case .backward:
            if let forwardStroke = pendingForwardStroke,
               stroke.startTime - forwardStroke.endTime <= maximumGapBetweenStrokes {
                return pairedFeedback(forwardStroke: forwardStroke, backwardStroke: stroke)
            }

            pendingBackwardStroke = stroke
            return listeningFeedback(direction: .neutral)

        case .neutral:
            return listeningFeedback(direction: .neutral)
        }
    }

    private func pairedFeedback(
        forwardStroke: StrokeSegment,
        backwardStroke: StrokeSegment
    ) -> ScratchMotionFeedback {
        let timingError = abs(forwardStroke.duration - backwardStroke.duration)
        let isBalanced = timingError <= absoluteTimingTolerance

        #if DEBUG
        print("[ScratchMotion] forwardDuration=\(Int((forwardStroke.duration * 1_000).rounded()))ms")
        print("[ScratchMotion] backwardDuration=\(Int((backwardStroke.duration * 1_000).rounded()))ms")
        print("[ScratchMotion] timingError=\(Int((timingError * 1_000).rounded()))ms")
        #endif

        pendingForwardStroke = nil
        pendingBackwardStroke = nil

        return ScratchMotionFeedback(
            direction: .neutral,
            balance: isBalanced ? .balanced : .unbalanced,
            forwardDuration: forwardStroke.duration,
            backwardDuration: backwardStroke.duration,
            timingError: timingError,
            forwardPeakAmplitude: forwardStroke.peakAmplitude,
            backwardPeakAmplitude: backwardStroke.peakAmplitude
        )
    }

    private func listeningFeedback(
        direction: ScratchMotionDirection
    ) -> ScratchMotionFeedback {
        ScratchMotionFeedback(
            direction: direction,
            balance: .listening,
            forwardDuration: pendingForwardStroke?.duration,
            backwardDuration: pendingBackwardStroke?.duration,
            timingError: nil,
            forwardPeakAmplitude: pendingForwardStroke?.peakAmplitude,
            backwardPeakAmplitude: pendingBackwardStroke?.peakAmplitude
        )
    }

    private func averageAbsoluteAmplitude(
        of frame: ArraySlice<Float>
    ) -> Float {
        guard !frame.isEmpty else { return 0 }

        var total: Float = 0
        for sample in frame {
            total += abs(sample)
        }
        return total / Float(frame.count)
    }
}
