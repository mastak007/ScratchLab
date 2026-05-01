//
//  ScratchAnalyzer.swift
//  ScratchLab
//
//  Compares user scratch attempts against reference samples (QBert, CXL, Karl)
//  to determine skill level and provide feedback.
//

import Foundation
import AVFoundation
import Accelerate

// MARK: - Reference Sample

/// A reference scratch sample with extracted features
struct ReferenceSample: Identifiable {
    let id: String
    let url: URL
    let tier: SkillTier
    let source: String // "qbert", "cxl", "karl"
    var features: ScratchFeatureSet?
    
    enum SkillTier: String, CaseIterable, Comparable {
        case legend = "Legend"      // QBert
        case champion = "Champion"  // CXL
        case beginner = "Beginner"  // Karl
        
        var rank: Int {
            switch self {
            case .legend: return 3
            case .champion: return 2
            case .beginner: return 1
            }
        }
        
        static func < (lhs: SkillTier, rhs: SkillTier) -> Bool {
            lhs.rank < rhs.rank
        }
    }
}

// MARK: - Feature Set

/// Extracted audio features from a scratch
struct ScratchFeatureSet {
    // Time-domain features
    let duration: Double
    let rmsEnvelope: [Float]           // Volume over time (normalized)
    let peakAmplitude: Float
    let attackTime: Double             // Time to reach peak
    let releaseTime: Double            // Time from peak to silence
    
    // Frequency-domain features
    let spectralCentroid: [Float]      // "Brightness" over time
    let spectralFlux: [Float]          // Rate of spectral change
    let dominantFrequencies: [Float]   // Top frequencies per frame
    
    // Rhythm features
    let onsetTimes: [Double]           // When sounds start
    let onsetStrengths: [Float]        // How strong each onset is
    let rhythmRegularity: Float        // 0-1, how consistent timing is
    
    // Computed properties
    var onsetCount: Int { onsetTimes.count }
    
    var averageOnsetInterval: Double {
        guard onsetTimes.count > 1 else { return 0 }
        var intervals: [Double] = []
        for i in 1..<onsetTimes.count {
            intervals.append(onsetTimes[i] - onsetTimes[i-1])
        }
        return intervals.reduce(0, +) / Double(intervals.count)
    }
    
    var energyProfile: [Float] {
        // Normalized RMS envelope
        guard let maxRMS = rmsEnvelope.max(), maxRMS > 0 else { return rmsEnvelope }
        return rmsEnvelope.map { $0 / maxRMS }
    }
}

// MARK: - Comparison Result

/// Result of comparing a user scratch to references
struct ScratchComparisonResult {
    let userFeatures: ScratchFeatureSet
    let closestMatch: ReferenceSample
    let similarityScores: [String: Float]  // Reference ID -> similarity %
    let overallScore: Float                 // 0-100
    let matchedTier: ReferenceSample.SkillTier
    let feedback: [FeedbackItem]
    
    struct FeedbackItem {
        let category: Category
        let message: String
        let priority: Int // 1 = most important
        
        enum Category: String {
            case timing = "Timing"
            case energy = "Energy"
            case technique = "Technique"
            case rhythm = "Rhythm"
            case positive = "Great!"
        }
    }
    
    /// User-friendly tier description
    var tierDescription: String {
        switch matchedTier {
        case .legend: return "Your scratch sounds like a legend! 🔥"
        case .champion: return "Champion level technique! 🏆"
        case .beginner: return "Keep practicing - you're learning! 💪"
        }
    }
}

// MARK: - Scratch Analyzer

@MainActor
class ScratchAnalyzer: ObservableObject {
    
    // MARK: - Configuration
    
    private let sampleRate: Double = 44100
    private let fftSize: Int = 2048
    private let hopSize: Int = 512
    private let onsetThreshold: Float = 0.1
    
    // FFT setup
    private var fftSetup: vDSP_DFT_Setup?
    
    // Reference samples
    @Published private(set) var referencesamples: [ReferenceSample] = []
    @Published private(set) var isLoaded: Bool = false
    @Published private(set) var loadingProgress: Float = 0
    
    // Analysis state
    @Published var isAnalyzing: Bool = false
    @Published var lastResult: ScratchComparisonResult?
    
    // MARK: - Initialization
    
    init() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }
    
    // MARK: - Load Reference Samples
    
    /// Load all reference samples from the bundle
    func loadReferenceSamples() async throws {
        isLoaded = false
        loadingProgress = 0
        referencesamples.removeAll()
        
        // Find reference folders in bundle
        guard let bundlePath = Bundle.main.resourcePath else {
            throw AnalyzerError.resourceNotFound
        }
        
        let basePath = URL(fileURLWithPath: bundlePath)
        let referencePaths: [(String, ReferenceSample.SkillTier, String)] = [
            ("reference_pro", .legend, "qbert"),
            ("reference_champ", .champion, "cxl"),
            ("reference_beginner", .beginner, "karl")
        ]
        
        var allSamples: [ReferenceSample] = []
        var discoveredReferenceFolder = false
        var processed = 0
        let totalExpected = 31 // Known count from dataset
        
        for (folder, tier, source) in referencePaths {
            let folderURL = basePath.appendingPathComponent(folder)
            
            guard FileManager.default.fileExists(atPath: folderURL.path) else {
                print("Warning: Reference folder not found: \(folder)")
                continue
            }

            discoveredReferenceFolder = true
            
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil
            )
            
            for url in contents where url.pathExtension == "wav" {
                let id = url.deletingPathExtension().lastPathComponent
                var sample = ReferenceSample(id: id, url: url, tier: tier, source: source)
                
                // Extract features
                if let features = try? await extractFeatures(from: url) {
                    sample.features = features
                    allSamples.append(sample)
                }
                
                processed += 1
                loadingProgress = Float(processed) / Float(totalExpected)
            }
        }

        guard discoveredReferenceFolder, !allSamples.isEmpty else {
            isLoaded = false
            loadingProgress = 0
            throw AnalyzerError.resourceNotFound
        }
        
        referencesamples = allSamples
        isLoaded = true
        loadingProgress = 1.0
        
        print("Loaded \(allSamples.count) reference samples")
    }
    
    /// Load references from a custom directory (for testing)
    func loadReferenceSamples(from directory: URL) async throws {
        isLoaded = false
        referencesamples.removeAll()
        
        let subfolders = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        
        var allSamples: [ReferenceSample] = []
        
        for subfolder in subfolders {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: subfolder.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            
            let folderName = subfolder.lastPathComponent
            let tier: ReferenceSample.SkillTier
            let source: String
            
            if folderName.contains("pro") {
                tier = .legend
                source = "qbert"
            } else if folderName.contains("champ") {
                tier = .champion
                source = "cxl"
            } else if folderName.contains("beginner") {
                tier = .beginner
                source = "karl"
            } else {
                continue
            }
            
            let files = try FileManager.default.contentsOfDirectory(
                at: subfolder,
                includingPropertiesForKeys: nil
            )
            
            for url in files where url.pathExtension == "wav" {
                let id = url.deletingPathExtension().lastPathComponent
                var sample = ReferenceSample(id: id, url: url, tier: tier, source: source)
                
                if let features = try? await extractFeatures(from: url) {
                    sample.features = features
                    allSamples.append(sample)
                }
            }
        }
        
        referencesamples = allSamples
        isLoaded = true
        print("Loaded \(allSamples.count) reference samples from \(directory.path)")
    }
    
    // MARK: - Feature Extraction
    
    /// Extract features from an audio file
    func extractFeatures(from url: URL) async throws -> ScratchFeatureSet {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AnalyzerError.bufferCreationFailed
        }
        
        try file.read(into: buffer)
        
        guard let channelData = buffer.floatChannelData else {
            throw AnalyzerError.noAudioData
        }
        
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(frameCount)))
        let duration = Double(frameCount) / format.sampleRate
        
        return extractFeatures(from: samples, sampleRate: format.sampleRate, duration: duration)
    }
    
    /// Extract features from raw audio samples
    func extractFeatures(from samples: [Float], sampleRate: Double, duration: Double) -> ScratchFeatureSet {
        // Calculate frame-by-frame features
        let frameCount = (samples.count - fftSize) / hopSize + 1
        guard frameCount > 0 else {
            return emptyFeatureSet(duration: duration)
        }
        
        var rmsEnvelope: [Float] = []
        var spectralCentroid: [Float] = []
        var spectralFlux: [Float] = []
        var dominantFrequencies: [Float] = []
        var prevMagnitudes: [Float] = []
        
        for frameIdx in 0..<frameCount {
            let startIdx = frameIdx * hopSize
            let endIdx = min(startIdx + fftSize, samples.count)
            let frame = Array(samples[startIdx..<endIdx])
            
            // Pad if necessary
            let paddedFrame = frame.count < fftSize ?
                frame + [Float](repeating: 0, count: fftSize - frame.count) : frame
            
            // RMS energy
            var rms: Float = 0
            vDSP_rmsqv(paddedFrame, 1, &rms, vDSP_Length(paddedFrame.count))
            rmsEnvelope.append(rms)
            
            // FFT
            let magnitudes = performFFT(paddedFrame)
            
            // Spectral centroid
            let centroid = calculateSpectralCentroid(magnitudes: magnitudes, sampleRate: Float(sampleRate))
            spectralCentroid.append(centroid)
            
            // Spectral flux
            if !prevMagnitudes.isEmpty {
                let flux = calculateSpectralFlux(current: magnitudes, previous: prevMagnitudes)
                spectralFlux.append(flux)
            }
            prevMagnitudes = magnitudes
            
            // Dominant frequency
            if let maxIdx = magnitudes.enumerated().max(by: { $0.element < $1.element })?.offset {
                let freq = Float(maxIdx) * Float(sampleRate) / Float(fftSize)
                dominantFrequencies.append(freq)
            }
        }
        
        // Onset detection
        let (onsetTimes, onsetStrengths) = detectOnsets(
            spectralFlux: spectralFlux,
            rmsEnvelope: rmsEnvelope,
            hopSize: hopSize,
            sampleRate: sampleRate
        )
        
        // Calculate rhythm regularity
        let rhythmRegularity = calculateRhythmRegularity(onsetTimes: onsetTimes)
        
        // Attack and release times
        let (attackTime, releaseTime) = calculateAttackRelease(
            rmsEnvelope: rmsEnvelope,
            hopSize: hopSize,
            sampleRate: sampleRate
        )
        
        // Peak amplitude
        let peakAmplitude = samples.map { abs($0) }.max() ?? 0
        
        return ScratchFeatureSet(
            duration: duration,
            rmsEnvelope: rmsEnvelope,
            peakAmplitude: peakAmplitude,
            attackTime: attackTime,
            releaseTime: releaseTime,
            spectralCentroid: spectralCentroid,
            spectralFlux: spectralFlux,
            dominantFrequencies: dominantFrequencies,
            onsetTimes: onsetTimes,
            onsetStrengths: onsetStrengths,
            rhythmRegularity: rhythmRegularity
        )
    }
    
    // MARK: - Comparison
    
    /// Compare a user recording against all references
    func compare(userAudio url: URL) async throws -> ScratchComparisonResult {
        guard isLoaded, !referencesamples.isEmpty else {
            throw AnalyzerError.referencesNotLoaded
        }
        
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        let userFeatures = try await extractFeatures(from: url)
        return compare(userFeatures: userFeatures)
    }
    
    /// Compare extracted features against references
    func compare(userFeatures: ScratchFeatureSet) -> ScratchComparisonResult {
        var similarityScores: [String: Float] = [:]
        var bestMatch: ReferenceSample?
        var bestScore: Float = 0
        
        for reference in referencesamples {
            guard let refFeatures = reference.features else { continue }
            
            let score = calculateSimilarity(user: userFeatures, reference: refFeatures)
            similarityScores[reference.id] = score
            
            if score > bestScore {
                bestScore = score
                bestMatch = reference
            }
        }
        
        // Determine matched tier based on which tier has highest average score
        let tierScores = calculateTierScores(similarityScores: similarityScores)
        let matchedTier = tierScores.max(by: { $0.value < $1.value })?.key ?? .beginner
        
        // Generate feedback
        let feedback = generateFeedback(
            userFeatures: userFeatures,
            bestMatch: bestMatch,
            overallScore: bestScore
        )
        
        let result = ScratchComparisonResult(
            userFeatures: userFeatures,
            closestMatch: bestMatch ?? referencesamples[0],
            similarityScores: similarityScores,
            overallScore: bestScore,
            matchedTier: matchedTier,
            feedback: feedback
        )
        
        lastResult = result
        return result
    }
    
    /// Compare live audio buffer
    func compare(buffer: AVAudioPCMBuffer) -> ScratchComparisonResult? {
        guard isLoaded, !referencesamples.isEmpty else { return nil }
        guard let channelData = buffer.floatChannelData else { return nil }
        
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))
        
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let features = extractFeatures(from: samples, sampleRate: buffer.format.sampleRate, duration: duration)
        
        return compare(userFeatures: features)
    }
    
    // MARK: - Similarity Calculation
    
    private func calculateSimilarity(user: ScratchFeatureSet, reference: ScratchFeatureSet) -> Float {
        var scores: [(Float, Float)] = [] // (score, weight)
        
        // 1. Duration similarity (weight: 0.1)
        let durationRatio = Float(min(user.duration, reference.duration) / max(user.duration, reference.duration))
        scores.append((durationRatio * 100, 0.1))
        
        // 2. Energy envelope correlation (weight: 0.25)
        let energyScore = correlateArrays(user.energyProfile, reference.energyProfile) * 100
        scores.append((energyScore, 0.25))
        
        // 3. Onset count similarity (weight: 0.15)
        let onsetRatio = Float(min(user.onsetCount, reference.onsetCount)) /
                         Float(max(user.onsetCount, reference.onsetCount, 1))
        scores.append((onsetRatio * 100, 0.15))
        
        // 4. Rhythm regularity similarity (weight: 0.15)
        let rhythmDiff = abs(user.rhythmRegularity - reference.rhythmRegularity)
        let rhythmScore = (1 - rhythmDiff) * 100
        scores.append((rhythmScore, 0.15))
        
        // 5. Spectral centroid correlation (weight: 0.2)
        let spectralScore = correlateArrays(user.spectralCentroid, reference.spectralCentroid) * 100
        scores.append((spectralScore, 0.2))
        
        // 6. Attack/release profile (weight: 0.15)
        let attackDiff = abs(Float(user.attackTime - reference.attackTime))
        let releaseDiff = abs(Float(user.releaseTime - reference.releaseTime))
        let profileScore = max(0, 100 - (attackDiff + releaseDiff) * 200)
        scores.append((profileScore, 0.15))
        
        // Weighted average
        let totalWeight = scores.reduce(0) { $0 + $1.1 }
        let weightedSum = scores.reduce(0) { $0 + $1.0 * $1.1 }
        
        return weightedSum / totalWeight
    }
    
    private func calculateTierScores(similarityScores: [String: Float]) -> [ReferenceSample.SkillTier: Float] {
        var tierTotals: [ReferenceSample.SkillTier: (sum: Float, count: Int)] = [
            .legend: (0, 0),
            .champion: (0, 0),
            .beginner: (0, 0)
        ]
        
        for reference in referencesamples {
            guard let score = similarityScores[reference.id] else { continue }
            let current = tierTotals[reference.tier] ?? (0, 0)
            tierTotals[reference.tier] = (current.sum + score, current.count + 1)
        }
        
        var averages: [ReferenceSample.SkillTier: Float] = [:]
        for (tier, data) in tierTotals {
            averages[tier] = data.count > 0 ? data.sum / Float(data.count) : 0
        }
        
        return averages
    }
    
    // MARK: - Feedback Generation
    
    private func generateFeedback(
        userFeatures: ScratchFeatureSet,
        bestMatch: ReferenceSample?,
        overallScore: Float
    ) -> [ScratchComparisonResult.FeedbackItem] {
        var feedback: [ScratchComparisonResult.FeedbackItem] = []
        
        guard let match = bestMatch, let refFeatures = match.features else {
            return [.init(category: .technique, message: "Could not analyze - try recording again", priority: 1)]
        }
        
        // Positive feedback for high scores
        if overallScore >= 85 {
            feedback.append(.init(
                category: .positive,
                message: "Excellent technique! Your scratch closely matches \(match.source.capitalized)'s style.",
                priority: 1
            ))
        } else if overallScore >= 70 {
            feedback.append(.init(
                category: .positive,
                message: "Good work! You're getting the feel of it.",
                priority: 1
            ))
        }
        
        // Timing feedback
        let rhythmDiff = abs(userFeatures.rhythmRegularity - refFeatures.rhythmRegularity)
        if rhythmDiff > 0.3 {
            feedback.append(.init(
                category: .timing,
                message: userFeatures.rhythmRegularity < refFeatures.rhythmRegularity ?
                    "Try to keep a more consistent rhythm between scratches." :
                    "Good rhythm! Maybe add a bit more variation.",
                priority: 2
            ))
        }
        
        // Energy feedback
        let energyRatio = userFeatures.peakAmplitude / max(refFeatures.peakAmplitude, 0.001)
        if energyRatio < 0.7 {
            feedback.append(.init(
                category: .energy,
                message: "Push the record a bit harder - more energy!",
                priority: 2
            ))
        } else if energyRatio > 1.4 {
            feedback.append(.init(
                category: .energy,
                message: "Ease up slightly - you're pushing too hard.",
                priority: 3
            ))
        }
        
        // Onset/technique feedback
        let onsetDiff = abs(userFeatures.onsetCount - refFeatures.onsetCount)
        if onsetDiff > 2 {
            feedback.append(.init(
                category: .technique,
                message: userFeatures.onsetCount < refFeatures.onsetCount ?
                    "Try to create more distinct sound events in your scratch." :
                    "Simplify - too many sounds. Focus on clean execution.",
                priority: 2
            ))
        }
        
        // Attack time feedback
        let attackDiff = userFeatures.attackTime - refFeatures.attackTime
        if abs(attackDiff) > 0.05 {
            feedback.append(.init(
                category: .technique,
                message: attackDiff > 0 ?
                    "Start your scratch more aggressively - quicker attack." :
                    "Slightly softer start - ease into the scratch.",
                priority: 3
            ))
        }
        
        // Sort by priority
        feedback.sort { $0.priority < $1.priority }
        
        // Limit to top 3 feedback items
        return Array(feedback.prefix(3))
    }
    
    // MARK: - Helper Functions
    
    private func performFFT(_ samples: [Float]) -> [Float] {
        guard let setup = fftSetup else { return [] }
        
        var realIn = samples
        var imagIn = [Float](repeating: 0, count: samples.count)
        var realOut = [Float](repeating: 0, count: samples.count)
        var imagOut = [Float](repeating: 0, count: samples.count)
        
        // Apply Hanning window
        var window = [Float](repeating: 0, count: samples.count)
        vDSP_hann_window(&window, vDSP_Length(samples.count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(realIn, 1, window, 1, &realIn, 1, vDSP_Length(samples.count))
        
        // Perform FFT
        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)
        
        // Calculate magnitudes
        var magnitudes = [Float](repeating: 0, count: samples.count / 2)
        for i in 0..<magnitudes.count {
            magnitudes[i] = sqrt(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
        }
        
        return magnitudes
    }
    
    private func calculateSpectralCentroid(magnitudes: [Float], sampleRate: Float) -> Float {
        var weightedSum: Float = 0
        var totalMagnitude: Float = 0
        
        for (i, mag) in magnitudes.enumerated() {
            let freq = Float(i) * sampleRate / Float(fftSize)
            weightedSum += freq * mag
            totalMagnitude += mag
        }
        
        return totalMagnitude > 0 ? weightedSum / totalMagnitude : 0
    }
    
    private func calculateSpectralFlux(current: [Float], previous: [Float]) -> Float {
        var flux: Float = 0
        let count = min(current.count, previous.count)
        
        for i in 0..<count {
            let diff = current[i] - previous[i]
            if diff > 0 {
                flux += diff * diff
            }
        }
        
        return sqrt(flux)
    }
    
    private func detectOnsets(
        spectralFlux: [Float],
        rmsEnvelope: [Float],
        hopSize: Int,
        sampleRate: Double
    ) -> (times: [Double], strengths: [Float]) {
        var onsetTimes: [Double] = []
        var onsetStrengths: [Float] = []
        
        guard spectralFlux.count > 2 else { return ([], []) }
        
        // Adaptive threshold
        let mean = spectralFlux.reduce(0, +) / Float(spectralFlux.count)
        let threshold = mean + onsetThreshold
        
        // Find peaks in spectral flux
        for i in 1..<(spectralFlux.count - 1) {
            if spectralFlux[i] > threshold &&
               spectralFlux[i] > spectralFlux[i-1] &&
               spectralFlux[i] > spectralFlux[i+1] {
                let time = Double(i * hopSize) / sampleRate
                onsetTimes.append(time)
                onsetStrengths.append(spectralFlux[i])
            }
        }
        
        return (onsetTimes, onsetStrengths)
    }
    
    private func calculateRhythmRegularity(onsetTimes: [Double]) -> Float {
        guard onsetTimes.count > 2 else { return 0.5 }
        
        var intervals: [Double] = []
        for i in 1..<onsetTimes.count {
            intervals.append(onsetTimes[i] - onsetTimes[i-1])
        }
        
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.map { pow($0 - mean, 2) }.reduce(0, +) / Double(intervals.count)
        let stdDev = sqrt(variance)
        
        // Coefficient of variation (lower = more regular)
        let cv = mean > 0 ? stdDev / mean : 1.0
        
        // Convert to 0-1 scale (1 = perfectly regular)
        return Float(max(0, 1 - cv))
    }
    
    private func calculateAttackRelease(
        rmsEnvelope: [Float],
        hopSize: Int,
        sampleRate: Double
    ) -> (attack: Double, release: Double) {
        guard !rmsEnvelope.isEmpty else { return (0, 0) }
        
        let maxIdx = rmsEnvelope.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let threshold = (rmsEnvelope.max() ?? 0) * 0.1
        
        // Find attack start
        var attackStart = 0
        for i in 0..<maxIdx {
            if rmsEnvelope[i] > threshold {
                attackStart = i
                break
            }
        }
        
        // Find release end
        var releaseEnd = rmsEnvelope.count - 1
        for i in stride(from: rmsEnvelope.count - 1, through: maxIdx, by: -1) {
            if rmsEnvelope[i] > threshold {
                releaseEnd = i
                break
            }
        }
        
        let attackTime = Double(maxIdx - attackStart) * Double(hopSize) / sampleRate
        let releaseTime = Double(releaseEnd - maxIdx) * Double(hopSize) / sampleRate
        
        return (attackTime, releaseTime)
    }
    
    private func correlateArrays(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        
        // Resample to same length
        let targetLength = min(a.count, b.count, 100)
        let resampledA = resample(a, to: targetLength)
        let resampledB = resample(b, to: targetLength)
        
        // Normalize
        let normalizedA = normalize(resampledA)
        let normalizedB = normalize(resampledB)
        
        // Pearson correlation
        var correlation: Float = 0
        vDSP_dotpr(normalizedA, 1, normalizedB, 1, &correlation, vDSP_Length(targetLength))
        
        return max(0, correlation / Float(targetLength))
    }
    
    private func resample(_ array: [Float], to targetLength: Int) -> [Float] {
        guard array.count != targetLength else { return array }
        
        var result = [Float](repeating: 0, count: targetLength)
        let ratio = Float(array.count - 1) / Float(targetLength - 1)
        
        for i in 0..<targetLength {
            let srcIdx = Float(i) * ratio
            let lower = Int(srcIdx)
            let upper = min(lower + 1, array.count - 1)
            let frac = srcIdx - Float(lower)
            result[i] = array[lower] * (1 - frac) + array[upper] * frac
        }
        
        return result
    }
    
    private func normalize(_ array: [Float]) -> [Float] {
        let mean = array.reduce(0, +) / Float(array.count)
        var variance: Float = 0
        vDSP_measqv(array.map { $0 - mean }, 1, &variance, vDSP_Length(array.count))
        let stdDev = sqrt(variance)
        
        guard stdDev > 0 else { return array }
        return array.map { ($0 - mean) / stdDev }
    }
    
    private func emptyFeatureSet(duration: Double) -> ScratchFeatureSet {
        ScratchFeatureSet(
            duration: duration,
            rmsEnvelope: [],
            peakAmplitude: 0,
            attackTime: 0,
            releaseTime: 0,
            spectralCentroid: [],
            spectralFlux: [],
            dominantFrequencies: [],
            onsetTimes: [],
            onsetStrengths: [],
            rhythmRegularity: 0
        )
    }
    
    // MARK: - Errors
    
    enum AnalyzerError: Error, LocalizedError {
        case resourceNotFound
        case bufferCreationFailed
        case noAudioData
        case referencesNotLoaded
        
        var errorDescription: String? {
            switch self {
            case .resourceNotFound: return "Reference samples not found in bundle"
            case .bufferCreationFailed: return "Failed to create audio buffer"
            case .noAudioData: return "No audio data in file"
            case .referencesNotLoaded: return "Reference samples not loaded"
            }
        }
    }
}
