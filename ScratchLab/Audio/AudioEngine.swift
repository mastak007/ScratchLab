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
    case djApp = "DJ Software"
    
    var description: String {
        switch self {
        case .microphone: return "Use your device's microphone"
        case .lineIn: return "Use a USB, interface, or loopback cable"
        case .djApp: return "Route audio from Serato, Traktor, or rekordbox"
        }
    }

    var practiceLabel: String {
        switch self {
        case .microphone: return "Microphone"
        case .lineIn: return "Wired Input"
        case .djApp: return "DJ Software"
        }
    }
}

enum AudioMonitorState: Equatable {
    case micOff
    case micLive
    case listening
    case noSignal
}

enum BackingTrackStatus: Equatable {
    case idle
    case ready(name: String)
    case unavailable(name: String)
}

// MARK: - Audio Engine
@MainActor
class AudioEngine: ObservableObject {
    private struct InputAudioPacket {
        let samples: [Float]
        let sampleRate: Double
    }

    // Audio engine components
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var playerNode: AVAudioPlayerNode?
    private var isInputTapInstalled = false
    
    // Analysis buffers
    private var analysisBuffer: [Float] = []
    private let analysisBufferSize = 2048
    private var fftSetup: vDSP_DFT_Setup?
    
    // Published state
    @Published var isRunning: Bool = false
    @Published var currentInputSource: AudioInputSource = .microphone
    @Published var inputLevel: Float = 0.0
    @Published var isAnalyzing: Bool = false
    @Published var lastAnalysisResult: ScratchAnalysisResult?
    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    @Published var inputMonitorState: AudioMonitorState = .micOff
    @Published var activeInputName: String = "Microphone"
    @Published var scratchMotionDirection: ScratchMotionDirection = .neutral
    @Published var scratchMotionFeedback: ScratchMotionFeedback?

    // User-visible audio error surface. Set on every session/engine/
    // permission failure path so the UI can show something instead of a
    // silent "Microphone Ready" pill. Cleared on a successful `start()`.
    @Published var lastAudioError: String?

    #if DEBUG
    // Diagnostic-only raw-input recording. Captures the same float
    // samples the matcher consumes, writes a mono WAV to /tmp, and
    // surfaces the URL so the file can be exchanged with off-device
    // debugging tooling. Never wired into Release builds, never used
    // for analysis, never retained as a Practice artefact.
    @Published var isDebugRecording: Bool = false
    @Published var lastDebugRecordingURL: URL?
    private struct DebugInputCapture {
        var samples: [Float]
        let targetSampleCount: Int
        var sampleRate: Double
    }
    private var debugInputCapture: DebugInputCapture?
    #endif
    
    // Backing track playback
    @Published var isBackingTrackPlaying: Bool = false
    @Published var backingTrackProgress: Double = 0.0
    @Published var backingTrackStatus: BackingTrackStatus = .idle
    private var backingTrackPlayer: AVAudioPlayer?
    
    // Sample playback (for scratch sounds)
    private var samplePlayers: [String: AVAudioPlayer] = [:]
    
    // Analysis callback
    var onScratchDetected: ((ScratchAnalysisResult) -> Void)?

    // Pattern matching
    private let patternMatcher = ScratchPatternMatcher()
    private let scratchMotionAnalyzer = ScratchMotionAnalyzer()
    private var lastSignalDetectedAt: Date?
    private var analysisStartedAt: Date?
    private let signalDetectionThreshold: Float = 0.012
    private let recentSignalHoldDuration: TimeInterval = 0.8
    private let noSignalGraceDuration: TimeInterval = 1.2
    private var didConfigureAudioSession = false
    private var currentAnalysisSampleRate = 44100.0
    private var monitorRefreshTask: Task<Void, Never>?
    
    init() {
        setupFFT()
    }
    
    deinit {
        Task { @MainActor [weak self] in
            guard let self else { return }
            teardownAudioEngine()
            NotificationCenter.default.removeObserver(
                self,
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )
            if let setup = fftSetup {
                vDSP_DFT_DestroySetup(setup)
            }
        }
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() {
        guard !didConfigureAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        
        do {
            // Configure for playback and recording
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setPreferredSampleRate(44100)
            try session.setPreferredIOBufferDuration(0.005) // Low latency
            try session.setActive(true)
            
            // Get available inputs
            updateAvailableInputs()
            syncInputRouteState()
            let activeInputs = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
            #if DEBUG
            print("Audio route input: \(activeInputs)")
            #endif
            
            // Listen for route changes
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )
            didConfigureAudioSession = true
        } catch {
            #if DEBUG
            print("Audio session setup error: \(error)")
            #endif
            lastAudioError = "Audio session could not start."
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        Task { @MainActor in
            updateAvailableInputs()
            syncInputRouteState()
        }
    }
    
    private func updateAvailableInputs() {
        let session = AVAudioSession.sharedInstance()
        availableInputs = session.availableInputs ?? []
    }

    private func syncInputRouteState() {
        let session = AVAudioSession.sharedInstance()
        let activePort = session.currentRoute.inputs.first
        activeInputName = displayName(for: activePort)

        guard let activePort else { return }

        switch activePort.portType {
        case .usbAudio, .lineIn:
            currentInputSource = .lineIn
        case .builtInMic, .headsetMic, .bluetoothHFP, .bluetoothLE:
            currentInputSource = .microphone
        default:
            break
        }
    }

    var hasExternalPracticeInput: Bool {
        availableInputs.contains { $0.portType == .usbAudio || $0.portType == .lineIn }
    }

    private func preferredInputPort(for source: AudioInputSource, in session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []

        switch source {
        case .microphone:
            return inputs.first(where: { $0.portType == .builtInMic })
                ?? inputs.first(where: { $0.portType == .headsetMic })
                ?? inputs.first(where: { $0.portType == .bluetoothHFP })
                ?? inputs.first(where: { $0.portType == .bluetoothLE })
        case .lineIn:
            return inputs.first(where: { $0.portType == .usbAudio })
                ?? inputs.first(where: { $0.portType == .lineIn })
        case .djApp:
            return nil
        }
    }

    private func displayName(for port: AVAudioSessionPortDescription?) -> String {
        guard let port else { return "Microphone" }

        switch port.portType {
        case .builtInMic:
            return "Microphone"
        default:
            return port.portName
        }
    }

    private func refreshInputMonitorState(now: Date = Date()) {
        guard isRunning else {
            inputMonitorState = .micOff
            return
        }

        guard isAnalyzing else {
            inputMonitorState = .micLive
            return
        }

        if let analysisStartedAt, now.timeIntervalSince(analysisStartedAt) < noSignalGraceDuration {
            inputMonitorState = .micLive
            return
        }

        if let lastSignalDetectedAt, now.timeIntervalSince(lastSignalDetectedAt) <= recentSignalHoldDuration {
            inputMonitorState = .listening
        } else {
            inputMonitorState = .noSignal
        }
    }
    
    // MARK: - FFT Setup
    
    private func setupFFT() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(analysisBufferSize), .FORWARD)
    }
    
    // MARK: - Engine Control
    
    func start() {
        guard !isRunning else { return }
        teardownAudioEngine()
        setupAudioSession()

        let session = AVAudioSession.sharedInstance()
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                break
            case .denied:
                #if DEBUG
                print("Microphone permission denied")
                #endif
                lastAudioError = "Microphone access is off. Enable it in Settings to use Practice."
                return
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    guard granted else {
                        #if DEBUG
                        print("Microphone permission denied")
                        #endif
                        Task { @MainActor in
                            self?.lastAudioError = "Microphone access is off. Enable it in Settings to use Practice."
                        }
                        return
                    }
                    Task { @MainActor in
                        self?.start()
                    }
                }
                return
            @unknown default:
                return
            }
        } else {
            switch session.recordPermission {
            case .granted:
                break
            case .denied:
                #if DEBUG
                print("Microphone permission denied")
                #endif
                lastAudioError = "Microphone access is off. Enable it in Settings to use Practice."
                return
            case .undetermined:
                session.requestRecordPermission { [weak self] granted in
                    guard granted else {
                        #if DEBUG
                        print("Microphone permission denied")
                        #endif
                        Task { @MainActor in
                            self?.lastAudioError = "Microphone access is off. Enable it in Settings to use Practice."
                        }
                        return
                    }
                    Task { @MainActor in
                        self?.start()
                    }
                }
                return
            @unknown default:
                return
            }
        }

        // The iOS system mic-permission alert (and route changes / interruptions /
        // backgrounding) can deactivate the audio session even after a successful
        // `setupAudioSession()`. Re-assert active state on every `start()` pass —
        // `setActive(true)` is idempotent when the session is already active.
        do {
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("Audio session re-activation error: \(error)")
            #endif
            lastAudioError = "Audio session could not start."
            return
        }
        
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        
        inputNode = engine.inputNode
        playerNode = AVAudioPlayerNode()
        
        guard let input = inputNode, let player = playerNode else { return }
        
        // Attach nodes
        engine.attach(player)
        
        // Get format
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            #if DEBUG
            print("No audio input channels available")
            #endif
            lastAudioError = "No audio input detected on this device."
            teardownAudioEngine()
            return
        }
        let analysisHopSeconds = Double(analysisBufferSize / 2) / inputFormat.sampleRate
        patternMatcher.configureAnalysis(hopSeconds: analysisHopSeconds)
        currentAnalysisSampleRate = inputFormat.sampleRate
        let processingFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        
        // Connect nodes
        engine.connect(player, to: engine.mainMixerNode, format: processingFormat)
        
        // Install tap for analysis
        let bufferSize: AVAudioFrameCount = 1024
        if isInputTapInstalled {
            input.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        isInputTapInstalled = true
        analysisBuffer.removeAll()
        
        // Start engine
        do {
            try engine.start()
            isRunning = true
            lastSignalDetectedAt = nil
            analysisStartedAt = nil
            lastAudioError = nil
            refreshInputMonitorState()
            startMonitorRefresh()
            #if DEBUG
            print("Audio engine started: \(inputFormat.sampleRate)Hz, channels=\(inputFormat.channelCount)")
            #endif
        } catch {
            #if DEBUG
            print("Audio engine start error: \(error)")
            #endif
            lastAudioError = "Audio engine could not start."
            teardownAudioEngine()
        }
    }
    
    func stop() {
        teardownAudioEngine()
    }

    private func teardownAudioEngine() {
        monitorRefreshTask?.cancel()
        monitorRefreshTask = nil

        #if DEBUG
        debugInputCapture = nil
        isDebugRecording = false
        #endif

        if let inputNode, isInputTapInstalled {
            inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        } else if let engine = audioEngine, isInputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }

        audioEngine?.stop()
        audioEngine?.reset()
        audioEngine = nil
        inputNode = nil
        playerNode = nil
        analysisBuffer.removeAll()
        lastSignalDetectedAt = nil
        analysisStartedAt = nil
        isRunning = false
        isAnalyzing = false
        inputLevel = 0
        inputMonitorState = .micOff
        backingTrackStatus = .idle
        scratchMotionAnalyzer.reset()
        scratchMotionDirection = .neutral
        scratchMotionFeedback = nil
    }
    
    // MARK: - Audio Processing
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let packet = Self.audioPacket(from: buffer) else { return }
        let samples = packet.samples
        guard !samples.isEmpty else { return }

        if abs(packet.sampleRate - currentAnalysisSampleRate) > 0.5 {
            currentAnalysisSampleRate = packet.sampleRate
            analysisBuffer.removeAll()
            let analysisHopSeconds = Double(analysisBufferSize / 2) / packet.sampleRate
            patternMatcher.configureAnalysis(hopSeconds: analysisHopSeconds)
        }
        
        let frames = samples.count
        
        // Calculate input level (RMS)
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frames))
        
        let now = Date()
        Task { @MainActor in
            self.inputLevel = (self.inputLevel * 0.7) + (rms * 0.3)
            if rms > self.signalDetectionThreshold {
                self.lastSignalDetectedAt = now
            }
            self.refreshInputMonitorState(now: now)
        }

        let motionFeedback = scratchMotionAnalyzer.process(samples: samples, sampleRate: packet.sampleRate)
        let motionDirection = scratchMotionAnalyzer.currentDirection
        Task { @MainActor in
            self.scratchMotionDirection = motionDirection
            if let motionFeedback {
                self.scratchMotionFeedback = motionFeedback
            }
        }

        #if DEBUG
        // Diagnostic input recorder — captures the exact float samples the
        // matcher will consume on the next analysis hop. Active only when
        // `startDebugRecording(durationSeconds:)` has been invoked from the
        // Practice DEBUG button. Zero overhead when no capture is active.
        appendDebugSamples(samples, sampleRate: packet.sampleRate)
        #endif

        // Add to analysis buffer
        analysisBuffer.append(contentsOf: samples)
        
        // When we have enough samples, analyze
        if analysisBuffer.count >= analysisBufferSize {
            let bufferToAnalyze = Array(analysisBuffer.prefix(analysisBufferSize))
            analysisBuffer.removeFirst(analysisBufferSize / 2) // 50% overlap
            
            analyzeBuffer(bufferToAnalyze, sampleRate: packet.sampleRate)
        }
    }
    
    private func analyzeBuffer(_ buffer: [Float], sampleRate: Double) {
        guard isAnalyzing else { return }

        let signpostID = ScratchLabPerformanceSignpost.begin("AudioAnalyze")
        defer { ScratchLabPerformanceSignpost.end("AudioAnalyze", signpostID) }
        
        // Perform FFT
        let frequencies = performFFT(buffer)
        
        // Extract features
        let features = extractFeatures(from: buffer, frequencies: frequencies, sampleRate: sampleRate)
        
        // Match against patterns
        if let result = patternMatcher.matchPattern(features: features) {
            Task { @MainActor in
                self.lastAnalysisResult = result
                self.onScratchDetected?(result)
                #if DEBUG
                print("Scratch detected: \(result.matchedScratchID ?? "unknown"), accuracy=\(Int(result.accuracy))")
                #endif
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
        realOut.withUnsafeMutableBufferPointer { realPtr in
            imagOut.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress,
                      let imagBase = imagPtr.baseAddress else {
                    return
                }
                var complex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_zvabs(&complex, 1, &magnitudes, 1, vDSP_Length(buffer.count / 2))
            }
        }
        
        return magnitudes
    }
    
    private func extractFeatures(from buffer: [Float], frequencies: [Float], sampleRate: Double) -> AudioFeatures {
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
        
        // Transient peak detection from a coarse amplitude envelope.
        // This is more stable than sample-level peaks for scratch-event counting.
        let envelopeFrameSize = 256
        var envelope: [Float] = []
        envelope.reserveCapacity(buffer.count / envelopeFrameSize + 1)
        var envelopeIndex = 0
        while envelopeIndex < buffer.count {
            let end = min(envelopeIndex + envelopeFrameSize, buffer.count)
            let segment = buffer[envelopeIndex..<end]
            let avgAmplitude = segment.reduce(0) { $0 + abs($1) } / Float(max(1, segment.count))
            envelope.append(avgAmplitude)
            envelopeIndex = end
        }
        
        let envelopeMean = envelope.isEmpty ? 0 : envelope.reduce(0, +) / Float(envelope.count)
        let envelopeVariance = envelope.isEmpty ? 0 : envelope.map { pow($0 - envelopeMean, 2) }.reduce(0, +) / Float(envelope.count)
        let envelopeStd = sqrt(envelopeVariance)
        let peakThreshold = max(0.03, envelopeMean + envelopeStd * 0.7)
        
        var peaks: [Int] = []
        var lastPeak = -3
        if envelope.count >= 3 {
            for i in 1..<(envelope.count - 1) {
                if envelope[i] > peakThreshold &&
                    envelope[i] > envelope[i - 1] &&
                    envelope[i] >= envelope[i + 1] &&
                    i - lastPeak >= 3 {
                    peaks.append(i)
                    lastPeak = i
                }
            }
        }
        
        // Spectral centroid
        var spectralCentroid: Float = 0
        var totalMagnitude: Float = 0
        let binScale = Float(sampleRate) / Float(max(1, frequencies.count * 2))
        for (i, mag) in frequencies.enumerated() {
            let freq = Float(i) * binScale
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
        let dominantFreq = Float(maxIndex) * binScale
        
        // Build a normalized 64-bin envelope sample for waveform comparison.
        let waveformBins = 64
        let binSize = max(1, buffer.count / waveformBins)
        var waveformSample: [Float] = []
        waveformSample.reserveCapacity(waveformBins)
        
        for i in 0..<waveformBins {
            let start = i * binSize
            if start >= buffer.count {
                waveformSample.append(0)
                continue
            }
            let end = min(start + binSize, buffer.count)
            let segment = buffer[start..<end]
            let avg = segment.reduce(0) { $0 + abs($1) } / Float(max(1, segment.count))
            waveformSample.append(avg)
        }
        
        if let maxWave = waveformSample.max(), maxWave > 0 {
            waveformSample = waveformSample.map { $0 / maxWave }
        }
        
        return AudioFeatures(
            rmsEnergy: rms,
            zeroCrossingRate: zeroCrossingRate,
            peakCount: peaks.count,
            spectralCentroid: spectralCentroid,
            dominantFrequency: dominantFreq,
            waveformSample: waveformSample
        )
    }

    private static func audioPacket(from buffer: AVAudioPCMBuffer) -> InputAudioPacket? {
        let asbd = buffer.format.streamDescription.pointee

        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        var channelSamples: [[Float]] = []

        for audioBuffer in buffers {
            guard let rawData = audioBuffer.mData else { continue }

            if isFloat && bitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                channelSamples.append(Array(UnsafeBufferPointer(start: samples, count: sampleCount)))
            } else if bitsPerChannel == 16 {
                let samples = rawData.assumingMemoryBound(to: Int16.self)
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                channelSamples.append((0..<sampleCount).map { Float(samples[$0]) / Float(Int16.max) })
            } else if bitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Int32.self)
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                channelSamples.append((0..<sampleCount).map { Float(samples[$0]) / Float(Int32.max) })
            }
        }

        guard !channelSamples.isEmpty else { return nil }

        let monoSamples: [Float]
        if buffers.count == 1 && channelCount > 1 && !isNonInterleaved {
            let interleaved = channelSamples[0]
            let frameCount = interleaved.count / channelCount
            guard frameCount > 0 else { return nil }

            var downmixed = [Float](repeating: 0, count: frameCount)
            for frameIndex in 0..<frameCount {
                var frameSum: Float = 0
                for channelIndex in 0..<channelCount {
                    let sampleIndex = (Int(frameIndex) * Int(channelCount)) + Int(channelIndex)
                    frameSum += interleaved[sampleIndex]
                }
                downmixed[frameIndex] = frameSum / Float(channelCount)
            }
            monoSamples = downmixed
        } else if channelSamples.count > 1 {
            let frameCount = channelSamples.map(\.count).min() ?? 0
            guard frameCount > 0 else { return nil }

            var downmixed = [Float](repeating: 0, count: frameCount)
            for frameIndex in 0..<frameCount {
                var frameSum: Float = 0
                for channel in channelSamples {
                    frameSum += channel[frameIndex]
                }
                downmixed[frameIndex] = frameSum / Float(channelSamples.count)
            }
            monoSamples = downmixed
        } else {
            monoSamples = channelSamples[0]
        }

        return InputAudioPacket(samples: monoSamples, sampleRate: buffer.format.sampleRate)
    }
    
    // MARK: - Analysis Control
    
    func startAnalyzing(for scratch: Scratch) {
        patternMatcher.loadPattern(for: scratch)
        isAnalyzing = true
        analysisBuffer.removeAll()
        lastSignalDetectedAt = nil
        analysisStartedAt = Date()
        scratchMotionAnalyzer.reset()
        scratchMotionDirection = .neutral
        scratchMotionFeedback = nil
        refreshInputMonitorState()
    }

    func stopAnalyzing() {
        isAnalyzing = false
        lastSignalDetectedAt = nil
        analysisStartedAt = nil
        scratchMotionDirection = .neutral
        scratchMotionFeedback = nil
        scratchMotionAnalyzer.reset()
        refreshInputMonitorState()
    }

    #if DEBUG
    // MARK: - Debug Input Recording (DEBUG-only)
    //
    // Captures the next `durationSeconds` of float samples from the input
    // tap and writes them as a mono PCM16 WAV to the app's tmp directory.
    // The capture path runs from the same callback as the matcher
    // (`processAudioBuffer → appendDebugSamples`), so the file represents
    // exactly what the matcher saw. Not retained, not analysed, not
    // exported via the Practice/Capture pipelines. Compiled out of
    // Release builds via `#if DEBUG`.

    func startDebugRecording(durationSeconds: TimeInterval = 20) {
        guard isRunning else { return }
        guard debugInputCapture == nil else { return }
        let sampleRate = currentAnalysisSampleRate > 0 ? currentAnalysisSampleRate : 44100
        let target = max(1, Int(sampleRate * durationSeconds))
        var capture = DebugInputCapture(samples: [], targetSampleCount: target, sampleRate: sampleRate)
        capture.samples.reserveCapacity(target)
        debugInputCapture = capture
        isDebugRecording = true
        print("[DEBUG] Input recording started: target \(target) samples at \(Int(sampleRate)) Hz")
    }

    private func appendDebugSamples(_ newSamples: [Float], sampleRate: Double) {
        guard var capture = debugInputCapture else { return }
        capture.sampleRate = sampleRate
        capture.samples.append(contentsOf: newSamples)
        guard capture.samples.count >= capture.targetSampleCount else {
            debugInputCapture = capture
            return
        }
        // Trim to exactly target, clear capture, write off the audio path.
        let finalSamples = Array(capture.samples.prefix(capture.targetSampleCount))
        let finalSampleRate = capture.sampleRate
        debugInputCapture = nil
        let outURL = Self.debugRecordingURL()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try Self.writeMonoWAV(samples: finalSamples,
                                      sampleRate: finalSampleRate,
                                      to: outURL)
                print("[DEBUG] Input recording saved: \(outURL.path)")
                Task { @MainActor in
                    self?.lastDebugRecordingURL = outURL
                    self?.isDebugRecording = false
                }
            } catch {
                print("[DEBUG] Input recording write error: \(error)")
                Task { @MainActor in
                    self?.isDebugRecording = false
                    self?.lastAudioError = "Debug recording failed to save."
                }
            }
        }
    }

    private static func debugRecordingURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return tmp.appendingPathComponent("scratchlab_input_\(stamp).wav")
    }

    nonisolated private static func writeMonoWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        let frameCount = samples.count
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample: UInt16 = bitsPerSample / 8
        let sampleRateU32 = UInt32(sampleRate.rounded())
        let byteRate = sampleRateU32 * UInt32(channels) * UInt32(bytesPerSample)
        let dataSize = UInt32(frameCount) * UInt32(channels) * UInt32(bytesPerSample)
        let riffSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(riffSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))               // fmt chunk size
        appendLE(UInt16(1))                // PCM
        appendLE(channels)
        appendLE(sampleRateU32)
        appendLE(byteRate)
        appendLE(UInt16(channels * bytesPerSample))  // block align
        appendLE(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        appendLE(dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767)
            appendLE(int16)
        }

        try data.write(to: url, options: .atomic)
    }
    #endif

    // Periodic tick that re-evaluates `inputMonitorState` so the UI pill
    // can leave `.micLive` and reach `.noSignal` when no buffers are
    // arriving. Without this, the pill is only refreshed from the tap
    // callback itself — meaning a silent tap leaves the pill stuck on
    // "Microphone Ready" forever. Owned by AudioEngine; started on a
    // successful `engine.start()` and cancelled in `teardownAudioEngine`.
    // No analysis or pattern-matching state is touched here.
    private func startMonitorRefresh() {
        monitorRefreshTask?.cancel()
        monitorRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.refreshInputMonitorState()
            }
        }
    }
    
    // MARK: - Backing Track Playback
    
    func loadBackingTrack(named name: String) {
        let extensions = ["mp3", "m4a", "wav"]
        let url = extensions.compactMap { Bundle.main.url(forResource: name, withExtension: $0) }.first
        guard let url else {
            backingTrackPlayer = nil
            backingTrackStatus = .unavailable(name: name)
            return
        }

        do {
            backingTrackPlayer = try AVAudioPlayer(contentsOf: url)
            backingTrackPlayer?.prepareToPlay()
            backingTrackPlayer?.numberOfLoops = -1 // Loop indefinitely
            backingTrackStatus = .ready(name: name)
        } catch {
            backingTrackPlayer = nil
            backingTrackStatus = .unavailable(name: name)
            #if DEBUG
            print("Error loading backing track: \(error)")
            #endif
        }
    }
    
    func playBackingTrack() {
        guard let backingTrackPlayer else {
            isBackingTrackPlaying = false
            return
        }
        backingTrackPlayer.play()
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
            #if DEBUG
            print("Sample not found: \(name)")
            #endif
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            samplePlayers[key] = player
        } catch {
            #if DEBUG
            print("Error loading sample: \(error)")
            #endif
        }
    }
    
    func playSample(key: String) {
        samplePlayers[key]?.currentTime = 0
        samplePlayers[key]?.play()
    }
    
    // MARK: - Input Source Selection
    
    func selectInputSource(_ source: AudioInputSource) {
        setupAudioSession()
        currentInputSource = source
        
        let session = AVAudioSession.sharedInstance()
        
        do {
            switch source {
            case .microphone:
                if let microphone = preferredInputPort(for: .microphone, in: session) {
                    try session.setPreferredInput(microphone)
                } else {
                    try session.setPreferredInput(nil)
                }
            case .lineIn:
                if let lineIn = preferredInputPort(for: .lineIn, in: session) {
                    try session.setPreferredInput(lineIn)
                } else {
                    try session.setPreferredInput(nil)
                }
            case .djApp:
                // Inter-app audio routing (requires additional setup)
                // This would use AudioUnit for inter-app audio
                #if DEBUG
                print("DJ App input requires Inter-App Audio setup")
                #endif
            }
            updateAvailableInputs()
            syncInputRouteState()
        } catch {
            #if DEBUG
            print("Error selecting input source: \(error)")
            #endif
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
    private var babyTrainingProfile: BabyTrainingProfile?
    
    // Collected samples for comparison
    private var collectedFeatures: [AudioFeatures] = []
    private let defaultRequiredSamples = 6
    // Baby Scratch buffer widened from 6 (~140 ms) → 12 (~280 ms) so the
    // matcher's rolling window can fit the two-onset Baby Scratch structure
    // it scores against (`expectedOnsetCount = 2` in `BabyTrainingProfile`).
    // At 6 samples a single Baby stroke produced one onset in the window;
    // `peakAccuracy`, `strengthBalanceScore` and `spacingScore` then fell
    // back to their "fewer than 2 onsets" placeholders and the multi-factor
    // accuracy total hovered just above the 38.0 floor (see cxl.mov real-
    // world sample diagnostic, May 2026). Other knobs — `hasFreshBabyAttack`
    // thresholds, `quietResetThreshold`, `quietFramesRequired`,
    // `detectionCooldown`, `minimumAccuracy`, FFT / waveform / frequency
    // scoring — are deliberately unchanged.
    private let babyRequiredSamples = 12
    private var analysisHopSeconds = 2048.0 / 44100.0
    private var lastDetectionDate: Date?
    private var lastDetectionScratchID: String?
    private var awaitingPostDetectionReset = false
    private var quietFramesSinceDetection = 0
    private var lastObservedEnergy: Float = 0
    
    private struct BabyTrainingProfile {
        let expectedOnsetCount: Int
        let expectedGap: Double
        let expectedDuration: Double
    }
    
    func loadPattern(for scratch: Scratch) {
        referenceScratch = scratch
        referencePattern = scratch.patternSignature
        collectedFeatures.removeAll()
        lastDetectionDate = nil
        lastDetectionScratchID = nil
        awaitingPostDetectionReset = false
        quietFramesSinceDetection = 0
        lastObservedEnergy = 0
        
        if scratch.id == "baby_scratch" {
            babyTrainingProfile = loadBabyTrainingProfile(fallback: defaultBabyTrainingProfile(for: scratch))
        } else {
            babyTrainingProfile = nil
        }
    }

    func configureAnalysis(hopSeconds: Double) {
        analysisHopSeconds = max(0.005, hopSeconds)
    }

    private func minimumSamples(for scratch: Scratch) -> Int {
        return scratch.id == "baby_scratch" ? babyRequiredSamples : defaultRequiredSamples
    }

    private func detectionCooldown(for scratch: Scratch) -> TimeInterval {
        if scratch.id == "baby_scratch" {
            return 0.55
        }
        let baseDuration = max(0.2, scratch.patternSignature.expectedDuration)
        return min(0.75, max(0.35, baseDuration * 0.9))
    }

    private func consumeCollectedFeatures(sampleWindow: Int, detected: Bool) {
        if detected {
            collectedFeatures.removeAll()
            return
        }

        let isBabyScratch = referenceScratch?.id == "baby_scratch"
        let stride = isBabyScratch ? max(1, sampleWindow / 3) : max(1, sampleWindow / 2)
        if collectedFeatures.count > stride {
            collectedFeatures.removeFirst(stride)
        } else {
            collectedFeatures.removeAll()
        }
    }

    private func isCoolingDown(for scratch: Scratch) -> Bool {
        guard let lastDetectionDate, lastDetectionScratchID == scratch.id else { return false }
        return Date().timeIntervalSince(lastDetectionDate) < detectionCooldown(for: scratch)
    }

    private func quietResetThreshold(for scratch: Scratch) -> Float {
        return scratch.id == "baby_scratch" ? 0.012 : 0.007
    }

    private func quietFramesRequired(for scratch: Scratch) -> Int {
        return scratch.id == "baby_scratch" ? 4 : 1
    }

    private func hasFreshBabyAttack(_ energy: Float) -> Bool {
        let rearmThreshold: Float = 0.009
        let attackThreshold: Float = 0.013
        let attackRiseThreshold: Float = 0.004
        let energyRise = energy - lastObservedEnergy
        return energy >= attackThreshold &&
            (lastObservedEnergy <= rearmThreshold || energyRise >= attackRiseThreshold)
    }
    
    func matchPattern(features: AudioFeatures) -> ScratchAnalysisResult? {
        guard let reference = referencePattern, let scratch = referenceScratch else { return nil }
        defer { lastObservedEnergy = features.rmsEnergy }

        if awaitingPostDetectionReset {
            if features.rmsEnergy <= quietResetThreshold(for: scratch) {
                quietFramesSinceDetection += 1
            } else {
                quietFramesSinceDetection = 0
            }

            if quietFramesSinceDetection >= quietFramesRequired(for: scratch) {
                awaitingPostDetectionReset = false
                quietFramesSinceDetection = 0
                collectedFeatures.removeAll()
            } else {
                return nil
            }
        }
        
        // Only analyze if there's significant audio
        guard features.rmsEnergy > 0.005 else { return nil }

        if scratch.id == "baby_scratch" && collectedFeatures.isEmpty && !hasFreshBabyAttack(features.rmsEnergy) {
            return nil
        }
        
        // Collect features
        collectedFeatures.append(features)

        let sampleWindow = minimumSamples(for: scratch)
        guard collectedFeatures.count >= sampleWindow else { return nil }

        if isCoolingDown(for: scratch) {
            consumeCollectedFeatures(sampleWindow: sampleWindow, detected: false)
            return nil
        }

        // Analyze a sliding window to keep detection responsive.
        let windowFeatures = Array(collectedFeatures.suffix(sampleWindow))
        guard let result = analyzeCollectedFeatures(reference: reference, scratch: scratch, features: windowFeatures) else {
            consumeCollectedFeatures(sampleWindow: sampleWindow, detected: false)
            return nil
        }

        lastDetectionDate = Date()
        lastDetectionScratchID = scratch.id
        awaitingPostDetectionReset = true
        quietFramesSinceDetection = 0
        consumeCollectedFeatures(sampleWindow: sampleWindow, detected: true)
        return result
    }
    
    private func analyzeCollectedFeatures(
        reference: PatternSignature,
        scratch: Scratch,
        features windowFeatures: [AudioFeatures]
    ) -> ScratchAnalysisResult? {
        // Calculate average features
        let avgFrequency = windowFeatures.map { $0.dominantFrequency }.reduce(0, +) / Float(windowFeatures.count)
        let onsetData = detectOnsets(from: windowFeatures)
        let onsetTimes = onsetData.times
        let onsetStrengths = onsetData.strengths
        let onsetCount = onsetTimes.count
        let expectedPeakCount = scratch.id == "baby_scratch"
            ? (babyTrainingProfile?.expectedOnsetCount ?? reference.peakCount)
            : reference.peakCount
        let expectedDuration = scratch.id == "baby_scratch"
            ? (babyTrainingProfile?.expectedDuration ?? reference.expectedDuration)
            : reference.expectedDuration

        if scratch.id == "baby_scratch" && !(1...4).contains(onsetCount) {
            return nil
        }
        
        // Calculate accuracy based on multiple factors
        var accuracyComponents: [Double] = []
        var weights: [Double] = []
        
        // 1. Onset count accuracy (how many sound events detected)
        let peakAccuracy = 1.0 - min(1.0, Double(abs(onsetCount - expectedPeakCount)) / Double(max(1, expectedPeakCount)))
        accuracyComponents.append(peakAccuracy * 100)
        weights.append(0.25)
        
        // 2. Frequency profile match
        let frequencyRange = reference.frequencyProfile.dominantFrequencyRange
        let freqInRange = avgFrequency >= frequencyRange.lowerBound && avgFrequency <= frequencyRange.upperBound
        let freqAccuracy: Double
        if freqInRange {
            freqAccuracy = 100.0
        } else {
            let distance = avgFrequency < frequencyRange.lowerBound
                ? frequencyRange.lowerBound - avgFrequency
                : avgFrequency - frequencyRange.upperBound
            // Gradual falloff instead of a hard pass/fail.
            freqAccuracy = max(40.0, 100.0 - (Double(distance) * 0.08))
        }
        accuracyComponents.append(freqAccuracy)
        weights.append(0.20)
        
        // 3. Waveform correlation (simplified)
        let waveformAccuracy = calculateWaveformSimilarity(
            collected: windowFeatures.flatMap { $0.waveformSample },
            reference: reference.waveformPattern
        )
        accuracyComponents.append(waveformAccuracy)
        weights.append(0.30)
        
        // 4. Rhythm accuracy
        let rhythmAccuracy = calculateRhythmAccuracy(
            onsetTimes: onsetTimes,
            expectedRhythm: reference.rhythmPattern,
            expectedDuration: expectedDuration
        )
        accuracyComponents.append(rhythmAccuracy)
        weights.append(0.25)
        
        var babyAssessment: (score: Double, feedback: [String])?
        if scratch.id == "baby_scratch" {
            let assessment = assessBabyScratch(
                onsetTimes: onsetTimes,
                onsetStrengths: onsetStrengths,
                expectedDuration: expectedDuration
            )
            babyAssessment = assessment
            
            // Baby scratch needs clear, balanced forward/backward motion.
            accuracyComponents.append(assessment.score)
            weights.append(0.30)
            // Reduce weighting of generic components when baby-specific scoring is available.
            weights[0] = 0.18
            weights[1] = 0.12
            weights[2] = 0.20
            weights[3] = 0.20
        }
        
        // Calculate overall accuracy (weighted average)
        var totalAccuracy: Double = 0
        for (i, accuracy) in accuracyComponents.enumerated() {
            totalAccuracy += accuracy * weights[i]
        }
        
        // Generate feedback
        var feedback: [String] = []
        
        if peakAccuracy < 0.7 {
            feedback.append(onsetCount < expectedPeakCount ?
                "Try to create more distinct sounds" :
                "Too many sounds - focus on clean execution")
        }
        
        if !freqInRange {
            feedback.append("Check your sound sample - frequency seems off")
        }
        
        if waveformAccuracy < 70 {
            feedback.append("Review the coach tips - your movement pattern needs adjustment")
        }
        
        if rhythmAccuracy < 70 {
            feedback.append("Focus on timing - try to stay on beat")
        }
        
        if let babyAssessment {
            for item in babyAssessment.feedback where !feedback.contains(item) {
                feedback.append(item)
            }
        }
        
        if totalAccuracy >= 90 {
            feedback = ["Excellent! You've got this scratch down! 🔥"]
        } else if totalAccuracy >= 80 {
            feedback.insert("Good work! Almost there!", at: 0)
        } else if totalAccuracy >= 70 {
            feedback.insert("Getting better! Keep practicing.", at: 0)
        }
        
        // Determine confidence (how sure we are this was the intended scratch)
        let confidence = min(100, totalAccuracy + (scratch.id == "baby_scratch" ? 6 : 10))
        let beatOffsetMs = calculateBeatOffsetMs(
            onsetTimes: onsetTimes,
            expectedDuration: expectedDuration,
            expectedEvents: max(1, expectedPeakCount)
        )

        let minimumAccuracy = scratch.id == "baby_scratch" ? 38.0 : 55.0
        guard totalAccuracy >= minimumAccuracy else {
            return nil
        }
        
        return ScratchAnalysisResult(
            matchedScratchID: scratch.id,
            confidence: confidence,
            accuracy: totalAccuracy,
            timing: .init(isOnBeat: rhythmAccuracy >= 70 && abs(beatOffsetMs) <= 80, beatOffset: beatOffsetMs),
            feedback: feedback
        )
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
        
        let actualIntervals = zip(onsetTimes.dropFirst(), onsetTimes).map(-)
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
        
        let actualNorm = normalize(actualIntervals)
        let expectedNorm = normalize(expectedIntervals)
        let alignedActual = resample(actualNorm.map(Float.init), to: expectedNorm.count).map(Double.init)
        
        var totalRhythmError = 0.0
        for (actual, expected) in zip(alignedActual, expectedNorm) {
            totalRhythmError += abs(actual - expected)
        }
        let rhythmError = totalRhythmError / Double(max(1, expectedNorm.count))
        let intervalScore = max(0, 1 - (rhythmError * 2.5))
        
        return (countScore * 0.45 + intervalScore * 0.55) * 100
    }
    
    private func assessBabyScratch(onsetTimes: [Double], onsetStrengths: [Float], expectedDuration: Double) -> (score: Double, feedback: [String]) {
        var feedback: [String] = []
        
        let onsetCount = onsetTimes.count
        let expectedEvents = babyTrainingProfile?.expectedOnsetCount ?? 2
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
            let expectedGap = max(0.08, babyTrainingProfile?.expectedGap ?? (expectedDuration * 0.45))
            let relativeError = abs(gap - expectedGap) / expectedGap
            spacingScore = max(0, 1 - relativeError)
        }
        
        let score = ((eventCountScore * 0.45) + (strengthBalanceScore * 0.30) + (spacingScore * 0.25)) * 100
        
        if eventCountScore < 0.7 {
            feedback.append("For baby scratch, make a clear forward push and backward pull (two clean sounds).")
        }
        if strengthBalanceScore < 0.7 {
            feedback.append("Balance your forward and backward strokes so both sounds are equally strong.")
        }
        if spacingScore < 0.65 {
            feedback.append("Keep the forward/backward motion steady - avoid rushing between directions.")
        }
        
        return (score, feedback)
    }
    
    private func detectOnsets(from features: [AudioFeatures]) -> (times: [Double], strengths: [Float]) {
        guard !features.isEmpty else { return ([], []) }
        
        let energies = features.map { $0.rmsEnergy }
        let mean = energies.reduce(0, +) / Float(energies.count)
        let variance = energies.map { pow($0 - mean, 2) }.reduce(0, +) / Float(energies.count)
        let std = sqrt(variance)
        let threshold = max(0.04, mean + std * 0.6)
        
        var onsetTimes: [Double] = []
        var onsetStrengths: [Float] = []
        var lastOnsetIndex = -2
        
        if energies.count >= 3 {
            for i in 1..<(energies.count - 1) {
                if energies[i] >= threshold &&
                    energies[i] > energies[i - 1] &&
                    energies[i] >= energies[i + 1] &&
                    (i - lastOnsetIndex) >= 2 {
                    onsetTimes.append(Double(i) * analysisHopSeconds)
                    onsetStrengths.append(energies[i])
                    lastOnsetIndex = i
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
    
    private func calculateBeatOffsetMs(onsetTimes: [Double], expectedDuration: Double, expectedEvents: Int) -> Double {
        guard onsetTimes.count >= 2 else { return 0 }
        
        let actualIntervals = zip(onsetTimes.dropFirst(), onsetTimes).map(-)
        let avgActualInterval = actualIntervals.reduce(0, +) / Double(actualIntervals.count)
        let expectedInterval = max(0.05, expectedDuration / Double(max(1, expectedEvents)))
        return (avgActualInterval - expectedInterval) * 1000
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
        
        for i in 0..<count {
            let position = Float(i) * scale
            let lower = Int(floor(position))
            let upper = min(values.count - 1, lower + 1)
            let weight = position - Float(lower)
            output[i] = (1 - weight) * values[lower] + weight * values[upper]
        }
        
        return output
    }
    
    // MARK: - Training Data

    private func defaultBabyTrainingProfile(for scratch: Scratch) -> BabyTrainingProfile {
        let expectedDuration = min(max(scratch.patternSignature.expectedDuration, 0.35), 0.8)
        return BabyTrainingProfile(
            expectedOnsetCount: min(max(scratch.patternSignature.peakCount, 2), 3),
            expectedGap: min(max(expectedDuration * 0.45, 0.10), 0.28),
            expectedDuration: expectedDuration
        )
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

        let expectedDuration = min(max(rawExpectedDuration, 0.30), 0.80)
        let expectedOnsetCount = min(max(rawExpectedOnsetCount, 2), 3)
        let expectedGap = min(max(rawExpectedGap, 0.08), 0.28)

        return BabyTrainingProfile(
            expectedOnsetCount: expectedOnsetCount,
            expectedGap: expectedGap,
            expectedDuration: expectedDuration
        )
    }

    static func bundledBabyTrainingFiles(in resourceRoot: URL?) -> [URL] {
        guard let resourceRoot, let trainingPath = babyTrainingFolderPath else { return [] }
        var seen: Set<String> = []
        return babyTrainingFiles(in: resourceRoot, trainingPath: trainingPath)
            .sorted {
                if $0.deletingLastPathComponent().lastPathComponent == $1.deletingLastPathComponent().lastPathComponent {
                    return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
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
    
    private static func babyTrainingFiles(in root: URL, trainingPath: String) -> [URL] {
        let folderURL = root.appendingPathComponent(trainingPath, isDirectory: true)
        return trainingAudioFiles(in: folderURL)
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
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        
        guard let channelData = buffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        guard !samples.isEmpty else { return nil }
        
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
        
        var idx = 0
        while idx < samples.count {
            let end = min(idx + frameSize, samples.count)
            let segment = samples[idx..<end]
            let avg = segment.reduce(0) { $0 + abs($1) } / Float(max(1, segment.count))
            envelope.append(avg)
            idx = end
        }
        
        guard !envelope.isEmpty else { return [] }
        
        let mean = envelope.reduce(0, +) / Float(envelope.count)
        let variance = envelope.map { pow($0 - mean, 2) }.reduce(0, +) / Float(envelope.count)
        let std = sqrt(variance)
        let threshold = max(0.03, mean + std * 0.7)
        
        var onsetTimes: [Double] = []
        var lastPeak = -3
        if envelope.count >= 3 {
            for i in 1..<(envelope.count - 1) {
                if envelope[i] >= threshold &&
                    envelope[i] > envelope[i - 1] &&
                    envelope[i] >= envelope[i + 1] &&
                    i - lastPeak >= 3 {
                    onsetTimes.append((Double(i) * Double(frameSize)) / sampleRate)
                    lastPeak = i
                }
            }
        }
        
        return onsetTimes
    }
    
    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
