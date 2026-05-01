import Foundation
import AVFoundation
import Accelerate

struct MacScratchDetectionResult: Equatable {
    let scratchID: String
    let scratchName: String
    let accuracy: Double
    let confidence: Double
    let feedback: [String]
    let detectedAt: Date
}

final class MacScratchDetector {
    private struct AudioFeatures {
        let rmsEnergy: Float
        let peakCount: Int
        let dominantFrequency: Float
        let waveformSample: [Float]
    }

    private struct ReferencePattern {
        let waveformPattern: [Float]
        let expectedDuration: Double
        let peakCount: Int
        let rhythmPattern: [Double]
        let dominantFrequencyRange: ClosedRange<Float>
    }

    private struct BabyTrainingProfile {
        let expectedOnsetCount: Int
        let expectedGap: Double
        let expectedDuration: Double
    }

    private let analysisBufferSize = 2048
    private let hopSize = 1024
    private let sampleWindow = 6
    private let minimumAccuracy = 40.0
    private static let defaultTrainingProfile = BabyTrainingProfile(
        expectedOnsetCount: 2,
        expectedGap: 0.20,
        expectedDuration: 0.5
    )
    private let reference = ReferencePattern(
        waveformPattern: [0.0, 0.8, 0.0, 0.8, 0.0],
        expectedDuration: 0.5,
        peakCount: 2,
        rhythmPattern: [1.0, 1.0],
        dominantFrequencyRange: 200...2000
    )
    private var trainingProfile = MacScratchDetector.defaultTrainingProfile

    private var analysisBuffer: [Float] = []
    private var collectedFeatures: [AudioFeatures] = []
    private var lastDetectionDate: Date?
    private var awaitingPostDetectionReset = false
    private var quietFramesSinceDetection = 0
    private var lastObservedEnergy: Float = 0
    private var fftSetup: vDSP_DFT_Setup?

    init() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(analysisBufferSize), .FORWARD)
        trainingProfile = loadBabyTrainingProfile(fallback: Self.defaultTrainingProfile)
    }

    deinit {
        if let fftSetup {
            vDSP_DFT_DestroySetup(fftSetup)
        }
    }

    func reset() {
        analysisBuffer.removeAll()
        collectedFeatures.removeAll()
        lastDetectionDate = nil
        awaitingPostDetectionReset = false
        quietFramesSinceDetection = 0
        lastObservedEnergy = 0
    }

    func process(samples: [Float], sampleRate: Double) -> MacScratchDetectionResult? {
        guard !samples.isEmpty else { return nil }

        analysisBuffer.append(contentsOf: samples)
        var latestDetection: MacScratchDetectionResult?

        while analysisBuffer.count >= analysisBufferSize {
            let window = Array(analysisBuffer.prefix(analysisBufferSize))
            analysisBuffer.removeFirst(hopSize)

            let features = extractFeatures(from: window, sampleRate: sampleRate)
            if let detection = matchBabyScratch(features: features, sampleRate: sampleRate) {
                latestDetection = detection
            }
        }

        return latestDetection
    }

    private func matchBabyScratch(features: AudioFeatures, sampleRate: Double) -> MacScratchDetectionResult? {
        defer { lastObservedEnergy = features.rmsEnergy }

        if awaitingPostDetectionReset {
            if features.rmsEnergy <= 0.012 {
                quietFramesSinceDetection += 1
            } else {
                quietFramesSinceDetection = 0
            }

            if quietFramesSinceDetection >= 4 {
                awaitingPostDetectionReset = false
                quietFramesSinceDetection = 0
                collectedFeatures.removeAll()
            } else {
                return nil
            }
        }

        guard features.rmsEnergy > 0.005 else { return nil }

        if collectedFeatures.isEmpty && !hasFreshAttack(currentEnergy: features.rmsEnergy) {
            return nil
        }

        collectedFeatures.append(features)
        guard collectedFeatures.count >= sampleWindow else { return nil }

        if let lastDetectionDate, Date().timeIntervalSince(lastDetectionDate) < 0.55 {
            consumeCollectedFeatures(detected: false)
            return nil
        }

        let windowFeatures = Array(collectedFeatures.suffix(sampleWindow))
        guard let detection = analyze(windowFeatures: windowFeatures, sampleRate: sampleRate) else {
            consumeCollectedFeatures(detected: false)
            return nil
        }

        lastDetectionDate = Date()
        awaitingPostDetectionReset = true
        quietFramesSinceDetection = 0
        consumeCollectedFeatures(detected: true)
        return detection
    }

    private func consumeCollectedFeatures(detected: Bool) {
        if detected {
            collectedFeatures.removeAll()
            return
        }

        let stride = max(1, sampleWindow / 3)
        if collectedFeatures.count > stride {
            collectedFeatures.removeFirst(stride)
        } else {
            collectedFeatures.removeAll()
        }
    }

    private func hasFreshAttack(currentEnergy: Float) -> Bool {
        let rearmThreshold: Float = 0.009
        let attackThreshold: Float = 0.013
        let attackRiseThreshold: Float = 0.004
        let energyRise = currentEnergy - lastObservedEnergy
        return currentEnergy >= attackThreshold &&
            (lastObservedEnergy <= rearmThreshold || energyRise >= attackRiseThreshold)
    }

    private func analyze(windowFeatures: [AudioFeatures], sampleRate: Double) -> MacScratchDetectionResult? {
        let onsetData = detectOnsets(from: windowFeatures, sampleRate: sampleRate)
        let onsetTimes = onsetData.times
        let onsetStrengths = onsetData.strengths
        let onsetCount = onsetTimes.count

        guard (1...4).contains(onsetCount) else { return nil }

        let averageFrequency = windowFeatures.map(\.dominantFrequency).reduce(0, +) / Float(windowFeatures.count)
        let expectedPeakCount = trainingProfile.expectedOnsetCount
        let expectedDuration = trainingProfile.expectedDuration

        let peakAccuracy = 1.0 - min(1.0, Double(abs(onsetCount - expectedPeakCount)) / Double(max(1, expectedPeakCount)))

        let frequencyAccuracy: Double
        if reference.dominantFrequencyRange.contains(averageFrequency) {
            frequencyAccuracy = 100
        } else {
            let distance = averageFrequency < reference.dominantFrequencyRange.lowerBound
                ? reference.dominantFrequencyRange.lowerBound - averageFrequency
                : averageFrequency - reference.dominantFrequencyRange.upperBound
            frequencyAccuracy = max(40.0, 100.0 - (Double(distance) * 0.08))
        }

        let waveformAccuracy = calculateWaveformSimilarity(
            collected: windowFeatures.flatMap(\.waveformSample),
            reference: reference.waveformPattern
        )

        let rhythmAccuracy = calculateRhythmAccuracy(
            onsetTimes: onsetTimes,
            expectedRhythm: reference.rhythmPattern,
            expectedDuration: expectedDuration
        )

        let babyAssessment = assessBabyScratch(
            onsetTimes: onsetTimes,
            onsetStrengths: onsetStrengths,
            expectedDuration: expectedDuration
        )

        let accuracy = (peakAccuracy * 100 * 0.18) +
            (frequencyAccuracy * 0.12) +
            (waveformAccuracy * 0.20) +
            (rhythmAccuracy * 0.20) +
            (babyAssessment.score * 0.30)

        guard accuracy >= minimumAccuracy else { return nil }

        var feedback: [String] = []
        if peakAccuracy < 0.7 {
            feedback.append(onsetCount < expectedPeakCount
                ? "Make the forward and backward strokes more distinct."
                : "The motion is too busy. Simplify the movement.")
        }
        if waveformAccuracy < 70 {
            feedback.append("Keep the baby scratch motion clean and even.")
        }
        if rhythmAccuracy < 70 {
            feedback.append("Try to keep the forward and backward timing steadier.")
        }
        for message in babyAssessment.feedback where !feedback.contains(message) {
            feedback.append(message)
        }

        return MacScratchDetectionResult(
            scratchID: "baby_scratch",
            scratchName: "Baby Scratch",
            accuracy: accuracy,
            confidence: min(100, accuracy + 6),
            feedback: Array(feedback.prefix(3)),
            detectedAt: Date()
        )
    }

    private func extractFeatures(from buffer: [Float], sampleRate: Double) -> AudioFeatures {
        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))

        let envelopeFrameSize = 256
        var envelope: [Float] = []
        envelope.reserveCapacity(buffer.count / envelopeFrameSize + 1)
        var envelopeIndex = 0
        while envelopeIndex < buffer.count {
            let end = min(envelopeIndex + envelopeFrameSize, buffer.count)
            let segment = buffer[envelopeIndex..<end]
            let averageAmplitude = segment.reduce(0) { $0 + abs($1) } / Float(max(1, segment.count))
            envelope.append(averageAmplitude)
            envelopeIndex = end
        }

        let envelopeMean = envelope.isEmpty ? 0 : envelope.reduce(0, +) / Float(envelope.count)
        let envelopeVariance = envelope.isEmpty ? 0 : envelope.map { pow($0 - envelopeMean, 2) }.reduce(0, +) / Float(envelope.count)
        let envelopeStd = sqrt(envelopeVariance)
        let peakThreshold = max(0.03, envelopeMean + envelopeStd * 0.7)

        var peaks: [Int] = []
        var lastPeak = -3
        if envelope.count >= 3 {
            for index in 1..<(envelope.count - 1) {
                if envelope[index] > peakThreshold &&
                    envelope[index] > envelope[index - 1] &&
                    envelope[index] >= envelope[index + 1] &&
                    index - lastPeak >= 3 {
                    peaks.append(index)
                    lastPeak = index
                }
            }
        }

        let frequencies = performFFT(buffer)

        var spectralCentroid: Float = 0
        var totalMagnitude: Float = 0
        for (index, magnitude) in frequencies.enumerated() {
            let frequency = Float(index) * Float(sampleRate) / Float(frequencies.count * 2)
            spectralCentroid += frequency * magnitude
            totalMagnitude += magnitude
        }
        if totalMagnitude > 0 {
            spectralCentroid /= totalMagnitude
        }

        var maxMagnitude: Float = 0
        var maxIndex: vDSP_Length = 0
        if !frequencies.isEmpty {
            vDSP_maxvi(frequencies, 1, &maxMagnitude, &maxIndex, vDSP_Length(frequencies.count))
        }
        let dominantFrequency = Float(maxIndex) * Float(sampleRate) / Float(max(1, frequencies.count * 2))

        let waveformBins = 64
        let binSize = max(1, buffer.count / waveformBins)
        var waveformSample: [Float] = []
        waveformSample.reserveCapacity(waveformBins)

        for index in 0..<waveformBins {
            let start = index * binSize
            if start >= buffer.count {
                waveformSample.append(0)
                continue
            }
            let end = min(start + binSize, buffer.count)
            let segment = buffer[start..<end]
            let average = segment.reduce(0) { $0 + abs($1) } / Float(max(1, segment.count))
            waveformSample.append(average)
        }

        if let maxWave = waveformSample.max(), maxWave > 0 {
            waveformSample = waveformSample.map { $0 / maxWave }
        }

        return AudioFeatures(
            rmsEnergy: rms,
            peakCount: peaks.count,
            dominantFrequency: dominantFrequency,
            waveformSample: waveformSample
        )
    }

    private func performFFT(_ buffer: [Float]) -> [Float] {
        guard let fftSetup else { return [] }

        var realIn = buffer
        var imagIn = [Float](repeating: 0, count: buffer.count)
        var realOut = [Float](repeating: 0, count: buffer.count)
        var imagOut = [Float](repeating: 0, count: buffer.count)

        var window = [Float](repeating: 0, count: buffer.count)
        vDSP_hann_window(&window, vDSP_Length(buffer.count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(realIn, 1, window, 1, &realIn, 1, vDSP_Length(buffer.count))
        vDSP_DFT_Execute(fftSetup, &realIn, &imagIn, &realOut, &imagOut)

        var magnitudes = [Float](repeating: 0, count: buffer.count / 2)
        realOut.withUnsafeMutableBufferPointer { realPointer in
            imagOut.withUnsafeMutableBufferPointer { imagPointer in
                guard let realBase = realPointer.baseAddress,
                      let imagBase = imagPointer.baseAddress else {
                    return
                }
                var complex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_zvabs(&complex, 1, &magnitudes, 1, vDSP_Length(buffer.count / 2))
            }
        }

        return magnitudes
    }

    private func detectOnsets(from features: [AudioFeatures], sampleRate: Double) -> (times: [Double], strengths: [Float]) {
        guard !features.isEmpty else { return ([], []) }

        let analysisHopSeconds = Double(hopSize) / sampleRate
        let energies = features.map(\.rmsEnergy)
        let mean = energies.reduce(0, +) / Float(energies.count)
        let variance = energies.map { pow($0 - mean, 2) }.reduce(0, +) / Float(energies.count)
        let std = sqrt(variance)
        let threshold = max(0.04, mean + std * 0.6)

        var onsetTimes: [Double] = []
        var onsetStrengths: [Float] = []
        var lastOnsetIndex = -2

        if energies.count >= 3 {
            for index in 1..<(energies.count - 1) {
                if energies[index] >= threshold &&
                    energies[index] > energies[index - 1] &&
                    energies[index] >= energies[index + 1] &&
                    (index - lastOnsetIndex) >= 2 {
                    onsetTimes.append(Double(index) * analysisHopSeconds)
                    onsetStrengths.append(energies[index])
                    lastOnsetIndex = index
                }
            }
        }

        if onsetTimes.isEmpty, let maxEnergy = energies.max(), maxEnergy > 0.05,
           let maxIndex = energies.firstIndex(of: maxEnergy) {
            onsetTimes = [Double(maxIndex) * analysisHopSeconds]
            onsetStrengths = [maxEnergy]
        }

        return (onsetTimes, onsetStrengths)
    }

    private func calculateWaveformSimilarity(collected: [Float], reference: [Float]) -> Double {
        guard !collected.isEmpty && !reference.isEmpty else { return 50.0 }

        let targetCount = max(16, min(64, max(collected.count, reference.count)))
        let resampledCollected = resample(collected.map { abs($0) }, to: targetCount)
        let resampledReference = resample(reference.map { abs($0) }, to: targetCount)

        let collectedMax = max(resampledCollected.max() ?? 1, 0.0001)
        let referenceMax = max(resampledReference.max() ?? 1, 0.0001)

        let normalizedCollected = resampledCollected.map { $0 / collectedMax }
        let normalizedReference = resampledReference.map { $0 / referenceMax }

        let meanAbsError = zip(normalizedCollected, normalizedReference)
            .map { abs($0 - $1) }
            .reduce(0, +) / Float(targetCount)

        return max(0, Double((1 - meanAbsError) * 100))
    }

    private func calculateRhythmAccuracy(onsetTimes: [Double], expectedRhythm: [Double], expectedDuration: Double) -> Double {
        guard onsetTimes.count >= 2 else { return 35.0 }

        var actualIntervals: [Double] = []
        for index in 1..<onsetTimes.count {
            actualIntervals.append(onsetTimes[index] - onsetTimes[index - 1])
        }
        guard !actualIntervals.isEmpty else { return 40.0 }

        let expectedIntervalCount = max(1, expectedRhythm.count)
        let countScore = max(
            0,
            1 - (Double(abs(actualIntervals.count - expectedIntervalCount)) / Double(expectedIntervalCount))
        )

        let expectedIntervals: [Double]
        if expectedRhythm.count > 1 {
            expectedIntervals = expectedRhythm
        } else {
            expectedIntervals = Array(
                repeating: max(0.05, expectedDuration / Double(max(1, expectedIntervalCount))),
                count: expectedIntervalCount
            )
        }

        let normalizedActual = normalize(actualIntervals)
        let normalizedExpected = normalize(expectedIntervals)
        let alignedActual = resample(normalizedActual.map(Float.init), to: normalizedExpected.count).map(Double.init)

        var totalRhythmError = 0.0
        for (actual, expected) in zip(alignedActual, normalizedExpected) {
            totalRhythmError += abs(actual - expected)
        }
        let rhythmError = totalRhythmError / Double(max(1, normalizedExpected.count))
        let intervalScore = max(0, 1 - (rhythmError * 2.5))

        return (countScore * 0.45 + intervalScore * 0.55) * 100
    }

    private func assessBabyScratch(onsetTimes: [Double], onsetStrengths: [Float], expectedDuration: Double) -> (score: Double, feedback: [String]) {
        var feedback: [String] = []

        let onsetCount = onsetTimes.count
        let expectedEvents = trainingProfile.expectedOnsetCount
        let eventCountScore = max(0, 1 - (Double(abs(onsetCount - expectedEvents)) / Double(max(1, expectedEvents))))

        var strengthBalanceScore = 0.4
        if onsetStrengths.count >= 2 {
            let first = Double(onsetStrengths[0])
            let second = Double(onsetStrengths[1])
            let maxStrength = max(first, second, 0.0001)
            strengthBalanceScore = min(first, second) / maxStrength
        }

        var spacingScore = 0.4
        if onsetTimes.count >= 2 {
            let gap = onsetTimes[1] - onsetTimes[0]
            let expectedGap = max(0.08, trainingProfile.expectedGap)
            let relativeError = abs(gap - expectedGap) / expectedGap
            spacingScore = max(0, 1 - relativeError)
        } else if expectedDuration > 0 {
            spacingScore = 0.5
        }

        let score = ((eventCountScore * 0.45) + (strengthBalanceScore * 0.30) + (spacingScore * 0.25)) * 100

        if eventCountScore < 0.7 {
            feedback.append("Aim for one clean forward sound and one clean backward sound.")
        }
        if strengthBalanceScore < 0.7 {
            feedback.append("Balance the forward and backward strokes so they hit with similar energy.")
        }
        if spacingScore < 0.65 {
            feedback.append("Keep the push and pull closer together for a cleaner baby scratch.")
        }

        return (score, feedback)
    }

    private func loadBabyTrainingProfile(fallback: BabyTrainingProfile) -> BabyTrainingProfile {
        let audioFiles = findBabyTrainingFiles()
        guard !audioFiles.isEmpty else { return fallback }

        var durations: [Double] = []
        var onsetCounts: [Double] = []
        var gaps: [Double] = []

        for audioFile in audioFiles {
            guard let metrics = extractTrainingMetrics(from: audioFile) else { continue }
            durations.append(metrics.duration)
            onsetCounts.append(Double(metrics.onsetCount))
            if let gap = metrics.firstGap {
                gaps.append(gap)
            }
        }

        guard !durations.isEmpty, !onsetCounts.isEmpty else { return fallback }

        let rawExpectedDuration = median(durations)
        let rawExpectedOnsetCount = max(1, Int(round(median(onsetCounts))))
        let rawExpectedGap = gaps.isEmpty ? max(0.08, rawExpectedDuration * 0.45) : median(gaps)

        return BabyTrainingProfile(
            expectedOnsetCount: min(max(rawExpectedOnsetCount, 2), 3),
            expectedGap: min(max(rawExpectedGap, 0.08), 0.28),
            expectedDuration: min(max(rawExpectedDuration, 0.30), 0.80)
        )
    }

    static func bundledBabyTrainingFiles(in resourceRoot: URL?) -> [URL] {
        guard let resourceRoot, let trainingPath = babyTrainingFolderPath else { return [] }

        let bundledURL = resourceRoot.appendingPathComponent(trainingPath, isDirectory: true)
        var seen: Set<String> = []
        return trainingAudioFiles(in: bundledURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .filter { seen.insert($0.path).inserted }
    }

    private func findBabyTrainingFiles() -> [URL] {
        Self.bundledBabyTrainingFiles(in: Bundle.main.resourceURL)
    }

    private static var babyTrainingFolderPath: String? {
        #if DEBUG
        return "internal_training/baby_scratch"
        #else
        return nil
        #endif
    }

    private static func trainingAudioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }

        return files
            .filter(isTrainingAudioFile)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isTrainingAudioFile(_ url: URL) -> Bool {
        let supportedExtensions = ["wav", "mp3", "m4a", "aif", "aiff"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func extractTrainingMetrics(from url: URL) -> (duration: Double, onsetCount: Int, firstGap: Double?)? {
        guard let file = try? AVAudioFile(forReading: url),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: file.processingFormat.sampleRate,
                channels: file.processingFormat.channelCount,
                interleaved: false
              ) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        var samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        if Int(buffer.format.channelCount) > 1 {
            for channelIndex in 1..<Int(buffer.format.channelCount) {
                let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameLength)
                for index in 0..<frameLength {
                    samples[index] += channel[index]
                }
            }
            let scale = 1.0 / Float(buffer.format.channelCount)
            samples = samples.map { $0 * scale }
        }

        let trimmed = trimSilence(samples, threshold: 0.01)
        guard !trimmed.isEmpty else { return nil }

        let duration = Double(trimmed.count) / format.sampleRate
        let onsetTimes = detectOnsetTimes(in: trimmed, sampleRate: format.sampleRate)
        let firstGap = onsetTimes.count >= 2 ? (onsetTimes[1] - onsetTimes[0]) : nil

        return (duration: duration, onsetCount: onsetTimes.count, firstGap: firstGap)
    }

    private func trimSilence(_ samples: [Float], threshold: Float) -> [Float] {
        guard let start = samples.firstIndex(where: { abs($0) > threshold }),
              let end = samples.lastIndex(where: { abs($0) > threshold }),
              start <= end else {
            return []
        }

        return Array(samples[start...end])
    }

    private func detectOnsetTimes(in samples: [Float], sampleRate: Double) -> [Double] {
        let frameSize = 512
        var envelope: [Float] = []
        envelope.reserveCapacity(samples.count / frameSize + 1)

        var index = 0
        while index < samples.count {
            let end = min(index + frameSize, samples.count)
            let segment = samples[index..<end]
            let average = segment.reduce(0) { $0 + abs($1) } / Float(max(1, segment.count))
            envelope.append(average)
            index = end
        }

        guard !envelope.isEmpty else { return [] }

        let mean = envelope.reduce(0, +) / Float(envelope.count)
        let variance = envelope.map { pow($0 - mean, 2) }.reduce(0, +) / Float(envelope.count)
        let std = sqrt(variance)
        let threshold = max(0.03, mean + std * 0.7)

        var onsetTimes: [Double] = []
        var lastPeak = -3
        if envelope.count >= 3 {
            for envelopeIndex in 1..<(envelope.count - 1) {
                if envelope[envelopeIndex] >= threshold &&
                    envelope[envelopeIndex] > envelope[envelopeIndex - 1] &&
                    envelope[envelopeIndex] >= envelope[envelopeIndex + 1] &&
                    envelopeIndex - lastPeak >= 3 {
                    onsetTimes.append((Double(envelopeIndex) * Double(frameSize)) / sampleRate)
                    lastPeak = envelopeIndex
                }
            }
        }

        return onsetTimes
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private func normalize(_ values: [Double]) -> [Double] {
        let total = values.reduce(0, +)
        guard total > 0 else { return Array(repeating: 0, count: values.count) }
        return values.map { $0 / total }
    }

    private func resample(_ values: [Float], to count: Int) -> [Float] {
        guard !values.isEmpty, count > 0 else { return [] }
        if values.count == count { return values }

        if count == 1 {
            return [values.reduce(0, +) / Float(values.count)]
        }

        var output = [Float](repeating: 0, count: count)
        let scale = Float(values.count - 1) / Float(count - 1)

        for index in 0..<count {
            let position = Float(index) * scale
            let lower = Int(floor(position))
            let upper = min(values.count - 1, lower + 1)
            let weight = position - Float(lower)
            output[index] = (1 - weight) * values[lower] + weight * values[upper]
        }

        return output
    }
}
