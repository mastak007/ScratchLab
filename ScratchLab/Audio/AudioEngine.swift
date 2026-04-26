// AudioEngine.swift
// ScratchLab - Core Audio Engine
// Handles audio input, playback, and scratch pattern analysis

import Foundation
import AVFoundation
import Accelerate
import Combine

// MARK: - Audio Input Source
enum AudioInputSource: String, CaseIterable {
    case microphone = "Microphone"
    case lineIn = "Line In"
    case djApp = "DJ App (Inter-App Audio)"
    
    var description: String {
        switch self {
        case .microphone: return "Use your device's microphone"
        case .lineIn: return "Connect via audio interface"
        case .djApp: return "Route audio from Serato, Traktor, etc."
        }
    }
}

// MARK: - Audio Engine
@MainActor
class AudioEngine: ObservableObject {
    // Audio engine components
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var playerNode: AVAudioPlayerNode?
    private var mixerNode: AVAudioMixerNode?
    
    // Analysis buffers
    private var analysisBuffer: [Float] = []
    private let analysisBufferSize = 4096
    private var fftSetup: vDSP_DFT_Setup?
    
    // Published state
    @Published var isRunning: Bool = false
    @Published var currentInputSource: AudioInputSource = .microphone
    @Published var inputLevel: Float = 0.0
    @Published var isAnalyzing: Bool = false
    @Published var lastAnalysisResult: ScratchAnalysisResult?
    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    
    // Backing track playback
    @Published var isBackingTrackPlaying: Bool = false
    @Published var backingTrackProgress: Double = 0.0
    private var backingTrackPlayer: AVAudioPlayer?
    
    // Sample playback (for scratch sounds)
    private var samplePlayers: [String: AVAudioPlayer] = [:]
    
    // Analysis callback
    var onScratchDetected: ((ScratchAnalysisResult) -> Void)?
    
    // Pattern matching
    private let patternMatcher = ScratchPatternMatcher()
    
    init() {
        setupAudioSession()
        setupFFT()
    }
    
    deinit {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        mixerNode?.removeTap(onBus: 0)
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        
        do {
            // Configure for playback and recording
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setPreferredSampleRate(44100)
            try session.setPreferredIOBufferDuration(0.005) // Low latency
            try session.setActive(true)
            
            // Get available inputs
            updateAvailableInputs()
            
            // Listen for route changes
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )
        } catch {
            print("Audio session setup error: \(error)")
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        Task { @MainActor in
            updateAvailableInputs()
        }
    }
    
    private func updateAvailableInputs() {
        let session = AVAudioSession.sharedInstance()
        availableInputs = session.availableInputs ?? []
    }
    
    // MARK: - FFT Setup
    
    private func setupFFT() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(analysisBufferSize), .FORWARD)
    }
    
    // MARK: - Engine Control
    
    func start() {
        guard !isRunning else { return }
        
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        
        inputNode = engine.inputNode
        mixerNode = AVAudioMixerNode()
        playerNode = AVAudioPlayerNode()
        
        guard let input = inputNode, let mixer = mixerNode, let player = playerNode else { return }
        
        // Attach nodes
        engine.attach(mixer)
        engine.attach(player)
        
        // Get format
        let inputFormat = input.outputFormat(forBus: 0)
        let processingFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        
        // Connect nodes
        engine.connect(input, to: mixer, format: inputFormat)
        engine.connect(player, to: engine.mainMixerNode, format: processingFormat)
        
        // Install tap for analysis
        let bufferSize: AVAudioFrameCount = 1024
        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
        
        // Start engine
        do {
            try engine.start()
            isRunning = true
        } catch {
            print("Audio engine start error: \(error)")
        }
    }
    
    func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        mixerNode?.removeTap(onBus: 0)
        audioEngine = nil
        isRunning = false
        isAnalyzing = false
    }
    
    // MARK: - Audio Processing
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frames = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        
        // Calculate input level (RMS)
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frames))
        
        Task { @MainActor in
            self.inputLevel = rms
        }
        
        // Add to analysis buffer
        analysisBuffer.append(contentsOf: samples)
        
        // When we have enough samples, analyze
        if analysisBuffer.count >= analysisBufferSize {
            let bufferToAnalyze = Array(analysisBuffer.prefix(analysisBufferSize))
            analysisBuffer.removeFirst(analysisBufferSize / 2) // 50% overlap
            
            analyzeBuffer(bufferToAnalyze)
        }
    }
    
    private func analyzeBuffer(_ buffer: [Float]) {
        guard isAnalyzing else { return }
        
        // Perform FFT
        let frequencies = performFFT(buffer)
        
        // Extract features
        let features = extractFeatures(from: buffer, frequencies: frequencies)
        
        // Match against patterns
        if let result = patternMatcher.matchPattern(features: features) {
            Task { @MainActor in
                self.lastAnalysisResult = result
                self.onScratchDetected?(result)
            }
        }
    }
    
    private func performFFT(_ buffer: [Float]) -> [Float] {
        guard let setup = fftSetup else { return [] }
        
        var realIn = buffer
        var imagIn = [Float](repeating: 0, count: buffer.count)
        var realOut = [Float](repeating: 0, count: buffer.count)
        var imagOut = [Float](repeating: 0, count: buffer.count)
        
        // Apply Hanning window
        var window = [Float](repeating: 0, count: buffer.count)
        vDSP_hann_window(&window, vDSP_Length(buffer.count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(realIn, 1, window, 1, &realIn, 1, vDSP_Length(buffer.count))
        
        // Perform FFT
        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)
        
        // Calculate magnitudes
        var magnitudes = [Float](repeating: 0, count: buffer.count / 2)
        var complex = DSPSplitComplex(realp: &realOut, imagp: &imagOut)
        vDSP_zvabs(&complex, 1, &magnitudes, 1, vDSP_Length(buffer.count / 2))
        
        return magnitudes
    }
    
    private func extractFeatures(from buffer: [Float], frequencies: [Float]) -> AudioFeatures {
        // Calculate various audio features for pattern matching
        
        // RMS energy
        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(buffer.count))
        
        // Zero crossing rate
        var zeroCrossings = 0
        for i in 1..<buffer.count {
            if (buffer[i] >= 0 && buffer[i-1] < 0) || (buffer[i] < 0 && buffer[i-1] >= 0) {
                zeroCrossings += 1
            }
        }
        let zeroCrossingRate = Float(zeroCrossings) / Float(buffer.count)
        
        // Peak detection
        var peaks: [Int] = []
        for i in 1..<(buffer.count - 1) {
            if buffer[i] > buffer[i-1] && buffer[i] > buffer[i+1] && abs(buffer[i]) > 0.1 {
                peaks.append(i)
            }
        }
        
        // Spectral centroid
        var spectralCentroid: Float = 0
        var totalMagnitude: Float = 0
        for (i, mag) in frequencies.enumerated() {
            let freq = Float(i) * 44100 / Float(frequencies.count * 2)
            spectralCentroid += freq * mag
            totalMagnitude += mag
        }
        if totalMagnitude > 0 {
            spectralCentroid /= totalMagnitude
        }
        
        // Dominant frequency
        var maxMag: Float = 0
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(frequencies, 1, &maxMag, &maxIndex, vDSP_Length(frequencies.count))
        let dominantFreq = Float(maxIndex) * 44100 / Float(frequencies.count * 2)
        
        return AudioFeatures(
            rmsEnergy: rms,
            zeroCrossingRate: zeroCrossingRate,
            peakCount: peaks.count,
            spectralCentroid: spectralCentroid,
            dominantFrequency: dominantFreq,
            waveformSample: Array(buffer.prefix(64)) // Downsampled waveform
        )
    }
    
    // MARK: - Analysis Control
    
    func startAnalyzing(for scratch: Scratch) {
        patternMatcher.loadPattern(for: scratch)
        isAnalyzing = true
        analysisBuffer.removeAll()
    }
    
    func stopAnalyzing() {
        isAnalyzing = false
    }
    
    // MARK: - Backing Track Playback
    
    func loadBackingTrack(named name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            print("Backing track not found: \(name)")
            return
        }
        
        do {
            backingTrackPlayer = try AVAudioPlayer(contentsOf: url)
            backingTrackPlayer?.prepareToPlay()
            backingTrackPlayer?.numberOfLoops = -1 // Loop indefinitely
        } catch {
            print("Error loading backing track: \(error)")
        }
    }
    
    func playBackingTrack() {
        backingTrackPlayer?.play()
        isBackingTrackPlaying = true
    }
    
    func pauseBackingTrack() {
        backingTrackPlayer?.pause()
        isBackingTrackPlaying = false
    }
    
    func stopBackingTrack() {
        backingTrackPlayer?.stop()
        backingTrackPlayer?.currentTime = 0
        isBackingTrackPlaying = false
    }
    
    // MARK: - Sample Playback
    
    func loadSample(named name: String, key: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            print("Sample not found: \(name)")
            return
        }
        
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            samplePlayers[key] = player
        } catch {
            print("Error loading sample: \(error)")
        }
    }
    
    func playSample(key: String) {
        samplePlayers[key]?.currentTime = 0
        samplePlayers[key]?.play()
    }
    
    // MARK: - Input Source Selection
    
    func selectInputSource(_ source: AudioInputSource) {
        currentInputSource = source
        
        let session = AVAudioSession.sharedInstance()
        
        do {
            switch source {
            case .microphone:
                // Use built-in mic
                if let builtInMic = availableInputs.first(where: { $0.portType == .builtInMic }) {
                    try session.setPreferredInput(builtInMic)
                }
            case .lineIn:
                // Use external input if available
                if let lineIn = availableInputs.first(where: { $0.portType == .lineIn || $0.portType == .usbAudio }) {
                    try session.setPreferredInput(lineIn)
                }
            case .djApp:
                // Inter-app audio routing (requires additional setup)
                // This would use AudioUnit for inter-app audio
                print("DJ App input requires Inter-App Audio setup")
            }
        } catch {
            print("Error selecting input source: \(error)")
        }
    }
}

// MARK: - Audio Features
struct AudioFeatures {
    let rmsEnergy: Float
    let zeroCrossingRate: Float
    let peakCount: Int
    let spectralCentroid: Float
    let dominantFrequency: Float
    let waveformSample: [Float]
}

// MARK: - Scratch Analysis Result
struct ScratchAnalysisResult {
    let matchedScratchID: String?
    let confidence: Double
    let accuracy: Double
    let timing: TimingResult
    let feedback: [String]
    
    struct TimingResult {
        let isOnBeat: Bool
        let beatOffset: Double // milliseconds off from perfect
    }
}

// MARK: - Pattern Matcher
class ScratchPatternMatcher {
    private var referencePattern: PatternSignature?
    private var referenceScratch: Scratch?
    
    // Collected samples for comparison
    private var collectedFeatures: [AudioFeatures] = []
    private let requiredSamples = 10
    
    func loadPattern(for scratch: Scratch) {
        referenceScratch = scratch
        referencePattern = scratch.patternSignature
        collectedFeatures.removeAll()
    }
    
    func matchPattern(features: AudioFeatures) -> ScratchAnalysisResult? {
        guard let reference = referencePattern, let scratch = referenceScratch else { return nil }
        
        // Only analyze if there's significant audio
        guard features.rmsEnergy > 0.05 else { return nil }
        
        // Collect features
        collectedFeatures.append(features)
        
        // Don't analyze until we have enough samples
        guard collectedFeatures.count >= requiredSamples else { return nil }
        
        // Analyze the collected features
        let result = analyzeCollectedFeatures(reference: reference, scratch: scratch)
        
        // Reset for next scratch
        collectedFeatures.removeAll()
        
        return result
    }
    
    private func analyzeCollectedFeatures(reference: PatternSignature, scratch: Scratch) -> ScratchAnalysisResult {
        // Calculate average features
        let avgPeakCount = collectedFeatures.map { $0.peakCount }.reduce(0, +) / collectedFeatures.count
        let avgFrequency = collectedFeatures.map { $0.dominantFrequency }.reduce(0, +) / Float(collectedFeatures.count)
        let avgZCR = collectedFeatures.map { $0.zeroCrossingRate }.reduce(0, +) / Float(collectedFeatures.count)
        
        // Calculate accuracy based on multiple factors
        var accuracyComponents: [Double] = []
        
        // 1. Peak count accuracy (how many sound events detected)
        let peakAccuracy = 1.0 - min(1.0, Double(abs(avgPeakCount - reference.peakCount)) / Double(max(1, reference.peakCount)))
        accuracyComponents.append(peakAccuracy * 100)
        
        // 2. Frequency profile match
        let freqInRange = avgFrequency >= reference.frequencyProfile.dominantFrequencyRange.lowerBound &&
                         avgFrequency <= reference.frequencyProfile.dominantFrequencyRange.upperBound
        let freqAccuracy = freqInRange ? 100.0 : 60.0
        accuracyComponents.append(freqAccuracy)
        
        // 3. Waveform correlation (simplified)
        let waveformAccuracy = calculateWaveformSimilarity(
            collected: collectedFeatures.flatMap { $0.waveformSample },
            reference: reference.waveformPattern
        )
        accuracyComponents.append(waveformAccuracy)
        
        // 4. Rhythm accuracy
        let rhythmAccuracy = calculateRhythmAccuracy(
            peaks: collectedFeatures.map { $0.peakCount },
            expectedRhythm: reference.rhythmPattern
        )
        accuracyComponents.append(rhythmAccuracy)
        
        // Calculate overall accuracy (weighted average)
        let weights = [0.25, 0.20, 0.30, 0.25]
        var totalAccuracy: Double = 0
        for (i, accuracy) in accuracyComponents.enumerated() {
            totalAccuracy += accuracy * weights[i]
        }
        
        // Generate feedback
        var feedback: [String] = []
        
        if peakAccuracy < 0.7 {
            feedback.append(avgPeakCount < reference.peakCount ?
                "Try to create more distinct sounds" :
                "Too many sounds - focus on clean execution")
        }
        
        if !freqInRange {
            feedback.append("Check your sound sample - frequency seems off")
        }
        
        if waveformAccuracy < 70 {
            feedback.append("Watch the tutorial video - your movement pattern needs adjustment")
        }
        
        if rhythmAccuracy < 70 {
            feedback.append("Focus on timing - try to stay on beat")
        }
        
        if totalAccuracy >= 90 {
            feedback = ["Excellent! You've got this scratch down! 🔥"]
        } else if totalAccuracy >= 80 {
            feedback.insert("Good work! Almost there!", at: 0)
        } else if totalAccuracy >= 70 {
            feedback.insert("Getting better! Keep practicing.", at: 0)
        }
        
        // Determine confidence (how sure we are this was the intended scratch)
        let confidence = min(100, totalAccuracy + 10) // Slightly higher confidence than accuracy
        
        return ScratchAnalysisResult(
            matchedScratchID: scratch.id,
            confidence: confidence,
            accuracy: totalAccuracy,
            timing: .init(isOnBeat: rhythmAccuracy > 70, beatOffset: Double.random(in: -50...50)),
            feedback: feedback
        )
    }
    
    private func calculateWaveformSimilarity(collected: [Float], reference: [Float]) -> Double {
        // Normalize and downsample collected waveform to match reference length
        guard !collected.isEmpty && !reference.isEmpty else { return 50.0 }
        
        let step = collected.count / reference.count
        var downsampledCollected: [Float] = []
        
        for i in 0..<reference.count {
            let startIdx = i * step
            let endIdx = min(startIdx + step, collected.count)
            if startIdx < collected.count {
                let segment = Array(collected[startIdx..<endIdx])
                let avg = segment.reduce(0, +) / Float(segment.count)
                downsampledCollected.append(avg)
            }
        }
        
        // Normalize both arrays
        let collectedMax = downsampledCollected.map { abs($0) }.max() ?? 1
        let referenceMax = reference.map { abs($0) }.max() ?? 1
        
        let normalizedCollected = downsampledCollected.map { $0 / collectedMax }
        let normalizedReference = reference.map { $0 / referenceMax }
        
        // Calculate correlation
        var correlation: Float = 0
        let count = min(normalizedCollected.count, normalizedReference.count)
        
        for i in 0..<count {
            let diff = abs(normalizedCollected[i] - normalizedReference[i])
            correlation += 1.0 - min(1.0, diff)
        }
        
        return Double(correlation / Float(count)) * 100
    }
    
    private func calculateRhythmAccuracy(peaks: [Int], expectedRhythm: [Double]) -> Double {
        // Simplified rhythm accuracy - compares timing ratios
        guard peaks.count >= 2 && expectedRhythm.count >= 2 else { return 70.0 }
        
        // Calculate actual rhythm ratios from peak timing
        // This is simplified - real implementation would use actual timestamps
        return Double.random(in: 65...95) // Placeholder for real rhythm analysis
    }
}
